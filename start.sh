#!/bin/bash
set -e

# Validate API_NODES format and parse
if [ -z "$API_NODES" ]; then
    echo "API_NODES is required. It must be a comma-separated list of ip:port (e.g., '192.168.1.1:8080' or '192.168.1.1:8080,192.168.1.2:8081')." >&2
    exit 1
fi

echo "API_NODES: $API_NODES"

# Transform API_NODES into an array
# Remove spaces, split by comma
IFS=',' read -ra API_NODES_ARRAY <<< "${API_NODES// /}"

# Validate each API node entry format (ip:port)
for node in "${API_NODES_ARRAY[@]}"; do
    if [ -z "$node" ]; then
        echo "API_NODES contains empty elements. Use format like '192.168.1.1:8080,192.168.1.2:8081'." >&2
        exit 1
    fi
    if [[ ! "$node" =~ ^[^:]+:[0-9]+$ ]]; then
        echo "Invalid API node format: '$node'. Expected format: 'ip:port' (e.g., '192.168.1.1:8080')." >&2
        exit 1
    fi
    # Extract and validate port
    port="${node##*:}"
    port_num=$((10#$port))
    if [ "$port_num" -lt 1 ] || [ "$port_num" -gt 65535 ]; then
        echo "Port $port in '$node' is out of valid range (1-65535)." >&2
        exit 1
    fi
done


if [ -z "$TENSOR_PARALLEL_SIZE" ]; then
    TENSOR_PARALLEL_SIZE=1
fi

if ! [[ "$TENSOR_PARALLEL_SIZE" =~ ^[1-4]$ ]]; then
    echo "TENSOR_PARALLEL_SIZE must be an integer from 1 to 4." >&2
    exit 1
fi

# Client ID is a number from 01 to 99
if [[ ! "$CLIENT_ID" =~ ^[0-9]{4}$ ]]; then
    echo "CLIENT_ID must be a four-digit number between 0001 and 9999." >&2
    exit 1
fi

CLIENT_ID_NUM=$((10#$CLIENT_ID))
if [ "$CLIENT_ID_NUM" -lt 1 ] || [ "$CLIENT_ID_NUM" -gt 9999 ]; then
    echo "CLIENT_ID must be between 0001 and 9999." >&2
    exit 1
fi

# Validate FRP_SERVERS format and parse
if [ -z "$FRP_SERVERS" ]; then
    echo "FRP_SERVERS is required. It must be a comma-separated list of host:port (e.g., '192.168.1.1:7000' or '192.168.1.1:7000,192.168.1.2:7000')." >&2
    exit 1
fi

if [ -z "$SECRET_FRP_TOKEN" ]; then
    echo "SECRET_FRP_TOKEN is required." >&2
    exit 1
fi

# Transform FRP_SERVERS into an array
# Remove spaces, split by comma
IFS=',' read -ra FRP_SERVERS_ARRAY <<< "${FRP_SERVERS// /}"

# Validate each server entry format (host:port)
for server in "${FRP_SERVERS_ARRAY[@]}"; do
    if [ -z "$server" ]; then
        echo "FRP_SERVERS contains empty elements. Use format like '192.168.1.1:7000,192.168.1.2:7000'." >&2
        exit 1
    fi
    if [[ ! "$server" =~ ^[^:]+:[0-9]+$ ]]; then
        echo "Invalid FRP server format: '$server'. Expected format: 'host:port' (e.g., '192.168.1.1:7000')." >&2
        exit 1
    fi
    # Extract and validate port
    port="${server##*:}"
    port_num=$((10#$port))
    if [ "$port_num" -lt 1 ] || [ "$port_num" -gt 65535 ]; then
        echo "Port $port in '$server' is out of valid range (1-65535)." >&2
        exit 1
    fi
done

if [ -z "$NODE_ID" ]; then
    NODE_ID="$CLIENT_ID"
fi

# Set FRP config directory (default to /etc/frp, can be overridden via FRP_CONFIG_DIR env var)
FRP_CONFIG_DIR="${FRP_CONFIG_DIR:-/etc/frp}"

# Ensure FRP config directory exists and is writable
mkdir -p "$FRP_CONFIG_DIR"
if [ ! -w "$FRP_CONFIG_DIR" ]; then
    echo "Error: $FRP_CONFIG_DIR directory is not writable." >&2
    exit 1
fi

# Create frpc config files for each FRP server
echo "Writing FRP client configuration files..."
for i in "${!FRP_SERVERS_ARRAY[@]}"; do
    server="${FRP_SERVERS_ARRAY[$i]}"
    FRP_SERVER_IP="${server%%:*}"
    FRP_SERVER_PORT="${server##*:}"
    
    echo "Writing ${FRP_CONFIG_DIR}/frpc${i}.ini for server ${FRP_SERVER_IP}:${FRP_SERVER_PORT}..."
    cat > "${FRP_CONFIG_DIR}/frpc${i}.ini" <<EOF
[common]
server_addr = ${FRP_SERVER_IP}
server_port = ${FRP_SERVER_PORT}
token = ${SECRET_FRP_TOKEN}

[client-mlnode-port5000-${CLIENT_ID}]
type = tcp
local_ip = 127.0.0.1
local_port = 5050
remote_port = 1${CLIENT_ID}

[client-mlnode-${CLIENT_ID}]
type = tcp
local_ip = 127.0.0.1
local_port = 8081
remote_port = 2${CLIENT_ID}
EOF
done

# Start frpc processes for each config file
echo "Starting frpc processes in background..."
for i in "${!FRP_SERVERS_ARRAY[@]}"; do
    echo "Starting frpc with config ${FRP_CONFIG_DIR}/frpc${i}.ini..."
    /usr/bin/frpc -c "${FRP_CONFIG_DIR}/frpc${i}.ini" &
done

# Start nginx in background
nginx &
NGINX_PID=$!

# Wait a moment for nginx to start
sleep 1

# Start the appropriate service based on UBUNTU_TEST flag
if [ "${UBUNTU_TEST}" = "true" ]; then
    echo "First we try to register the mlnode with the servers..."
    # If $REGISTRATION_ENDPOINT is empty, set it to '/admin/v1/nodes'
    if [ -z "$REGISTRATION_ENDPOINT" ]; then
      REGISTRATION_ENDPOINT="/admin/v1/nodes"
    fi

    # If $REGISTRATION_JSON is empty, set it to the default registration JSON
    if [ -z "$REGISTRATION_JSON" ]; then
      REGISTRATION_JSON='{
       "id": "'${ID_PREFIX}${NODE_ID}'",
       "host": "frps",
       "inference_port": 1'${CLIENT_ID}',
       "poc_port": 2'${CLIENT_ID}',
       "max_concurrent": 500,
       "models": {
         "'$MODEL_NAME'": {
           "args": ["--tensor-parallel-size","'$TENSOR_PARALLEL_SIZE'"]
         }
       }
     }'
    fi

    echo "Registering new mlnode with server"
    for API_NODE in "${API_NODES_ARRAY[@]}"; do
      echo "Registering with API node at ${API_NODE}"
      echo "curl -X POST http://${API_NODE}${REGISTRATION_ENDPOINT} \
       -H \"Content-Type: application/json\" \
       -d \"${REGISTRATION_JSON}\""

      echo "${REGISTRATION_JSON}" | curl -X POST http://${API_NODE}${REGISTRATION_ENDPOINT} \
       -H "Content-Type: application/json" \
       -d @-
    done

    echo "UBUNTU_TEST is true; starting test HTTP servers on 8080 and 5050..."
    
    # Create log directory (configurable via LOG_DIR env var, defaults to /tmp/logs)
    LOG_DIR="${LOG_DIR:-/tmp/logs}"
    mkdir -p "$LOG_DIR"
    
    # Start Python server on port 8080
    # Using -u flag for unbuffered output so errors appear immediately in Docker logs
    # Output goes to stdout/stderr (captured by Docker logs) and also saved to log file
    echo "Starting HTTP server on port 8080..."
    python3 -u /http_server.py --port 8080 > "$LOG_DIR/http_server_8080.log" 2>&1 &
    SERVER_8080_PID=$!
    echo "HTTP server 8080 started with PID: $SERVER_8080_PID (logs: $LOG_DIR/http_server_8080.log)"
    
    # Start Python server on port 5050
    echo "Starting HTTP server on port 5050..."
    python3 -u /http_server.py --port 5050 > "$LOG_DIR/http_server_5050.log" 2>&1 &
    SERVER_5050_PID=$!
    echo "HTTP server 5050 started with PID: $SERVER_5050_PID (logs: $LOG_DIR/http_server_5050.log)"
    
    # Also tail the log files to stdout so they appear in Docker logs
    tail -f "$LOG_DIR/http_server_8080.log" | sed 's/^/[HTTP-8080] /' &
    tail -f "$LOG_DIR/http_server_5050.log" | sed 's/^/[HTTP-5050] /' &
    
    # Wait a moment and check if processes are still running
    sleep 2
    if ! kill -0 $SERVER_8080_PID 2>/dev/null; then
        echo "ERROR: HTTP server on port 8080 crashed immediately!" >&2
        echo "Last 50 lines of log:" >&2
        [ -f "$LOG_DIR/http_server_8080.log" ] && tail -50 "$LOG_DIR/http_server_8080.log" >&2 || echo "No log file found" >&2
        echo "--- End of log for port 8080 ---" >&2
    else
        echo "HTTP server 8080 is running (PID: $SERVER_8080_PID)"
        # Show initial log output
        [ -f "$LOG_DIR/http_server_8080.log" ] && cat "$LOG_DIR/http_server_8080.log"
    fi
    
    if ! kill -0 $SERVER_5050_PID 2>/dev/null; then
        echo "ERROR: HTTP server on port 5050 crashed immediately!" >&2
        echo "Last 50 lines of log:" >&2
        [ -f "$LOG_DIR/http_server_5050.log" ] && tail -50 "$LOG_DIR/http_server_5050.log" >&2 || echo "No log file found" >&2
        echo "--- End of log for port 5050 ---" >&2
    else
        echo "HTTP server 5050 is running (PID: $SERVER_5050_PID)"
        # Show initial log output
        [ -f "$LOG_DIR/http_server_5050.log" ] && cat "$LOG_DIR/http_server_5050.log"
    fi
    
    # Set up a background process to monitor and output logs to stdout
    (
        while true; do
            sleep 5
            if ! kill -0 $SERVER_8080_PID 2>/dev/null; then
                echo "WARNING: HTTP server 8080 (PID: $SERVER_8080_PID) has died!" >&2
                [ -f "$LOG_DIR/http_server_8080.log" ] && tail -20 "$LOG_DIR/http_server_8080.log" >&2
            fi
            if ! kill -0 $SERVER_5050_PID 2>/dev/null; then
                echo "WARNING: HTTP server 5050 (PID: $SERVER_5050_PID) has died!" >&2
                [ -f "$LOG_DIR/http_server_5050.log" ] && tail -20 "$LOG_DIR/http_server_5050.log" >&2
            fi
        done
    ) &
    MONITOR_PID=$!
    
    echo "Monitoring background processes. Logs saved to $LOG_DIR/"
    echo "To view logs: docker exec <container> tail -f $LOG_DIR/http_server_*.log"
    echo "Or check Docker logs: docker logs <container>"
    
    # Wait for all background processes to keep container running
    echo "Waiting for background processes..."
    wait
else
    echo "Creating user and group 'appuser' and 'appgroup'..."
    HOST_UID=${HOST_UID:-1000}
    HOST_GID=${HOST_GID:-1001}

    if ! getent group appgroup >/dev/null; then
      echo "Creating group 'appgroup'"
      groupadd -g "$HOST_GID" appgroup
    else
      echo "Group 'appgroup' already exists"
    fi

    if ! id -u appuser >/dev/null 2>&1; then
      echo "Creating user 'appuser'"
      useradd -m -u "$HOST_UID" -g appgroup appuser
    else
      echo "User 'appuser' already exists"
    fi

    mkdir -p $HF_HOME
    huggingface-cli download $MODEL_NAME

    # If $REGISTRATION_ENDPOINT is empty, set it to '/admin/v1/nodes'
    if [ -z "$REGISTRATION_ENDPOINT" ]; then
      REGISTRATION_ENDPOINT="/admin/v1/nodes"
    fi

    # If $REGISTRATION_JSON is empty, set it to the default registration JSON
    if [ -z "$REGISTRATION_JSON" ]; then
      REGISTRATION_JSON='{
       "id": "'${ID_PREFIX}${NODE_ID}'",
       "host": "frps",
       "inference_port": 1'${CLIENT_ID}',
       "poc_port": 2'${CLIENT_ID}',
       "max_concurrent": 500,
       "models": {
         "'$MODEL_NAME'": {
           "args": ["--tensor-parallel-size","'$TENSOR_PARALLEL_SIZE'"]
         }
       }
     }'
    fi

    echo "Registering new mlnode with server"
    for API_NODE in "${API_NODES_ARRAY[@]}"; do
      echo "Registering with API node at ${API_NODE}"
      echo "curl -X POST http://${API_NODE}${REGISTRATION_ENDPOINT} \
       -H \"Content-Type: application/json\" \
       -d \"${REGISTRATION_JSON}\""

      echo "${REGISTRATION_JSON}" | curl -X POST http://${API_NODE}${REGISTRATION_ENDPOINT} \
       -H "Content-Type: application/json" \
       -d @-
    done

    echo "Starting uvicorn application..."

    source /app/packages/api/.venv/bin/activate
    exec uvicorn api.app:app --host=0.0.0.0 --port=8080
fi

