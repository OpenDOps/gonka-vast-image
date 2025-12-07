#!/bin/bash
set -e

if [ -z "$API_NODE_PORT" ]; then
    echo "API_NODE_PORT is a required environment variable." >&2
    exit 1
fi

if [ -z "$API_NODE_IP" ]; then
    API_NODE_IP="$FRP_SERVER_IP"
fi

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

if [ -z "$SECRET_FRP_TOKEN" ] || [ -z "$FRP_SERVER_IP" ] || [ -z "$FRP_SERVER_PORT" ]; then
    echo "Missing FRP configuration: SECRET_FRP_TOKEN, FRP_SERVER_IP, and FRP_SERVER_PORT are required." >&2
    exit 1
fi

if [ -z "$NODE_ID" ]; then
    NODE_ID="$CLIENT_ID"
fi


echo "Writing /etc/frp/frpc.ini..."
cat > /etc/frp/frpc.ini <<EOF
[common]
server_addr = ${FRP_SERVER_IP}
server_port = ${FRP_SERVER_PORT}
token = ${SECRET_FRP_TOKEN}

[client-mlnode-port5000-${CLIENT_ID}]
type = tcp
local_ip = 127.0.0.1
local_port = 5050
remote_port = 5${CLIENT_ID}

[client-mlnode-${CLIENT_ID}]
type = tcp
local_ip = 127.0.0.1
local_port = 8081
remote_port = 8${CLIENT_ID}
EOF

echo "Starting frpc in background..."
/usr/bin/frpc -c /etc/frp/frpc.ini &

# Start nginx in background
nginx &
NGINX_PID=$!

# Wait a moment for nginx to start
sleep 1

# Start the appropriate service based on UBUNTU_TEST flag
if [ "${UBUNTU_TEST}" = "true" ]; then
    echo "UBUNTU_TEST is true; starting test HTTP servers on 8080 and 5000..."
    python3 /http_server.py --port 8080 &
    python3 /http_server.py --port 5050 &
    wait -n
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
       "id": "'$NODE_ID'",
       "host": "frps",
       "inference_port": 5'${CLIENT_ID}',
       "poc_port": 8'${CLIENT_ID}',
       "max_concurrent": 500,
       "models": {
         "'$MODEL_NAME'": {
           "args": ["--tensor-parallel-size","'$TENSOR_PARALLEL_SIZE'"]
         }
       }
     }'
    fi

    echo "Registering new mlnode with server"
    echo "curl -X POST http://${API_NODE_IP}:${API_NODE_PORT}${REGISTRATION_ENDPOINT} \
     -H "Content-Type: application/json" \
     -d '$REGISTRATION_JSON'"

    #TODO: Register new mlnode with server (API_NODE_IP, API_NODE_PORT)
    curl -X POST http://${API_NODE_IP}:${API_NODE_PORT}${REGISTRATION_ENDPOINT} \
     -H "Content-Type: application/json" \
     -d '$REGISTRATION_JSON'

    echo "Starting uvicorn application..."

    source /app/packages/api/.venv/bin/activate
    exec uvicorn api.app:app --host=0.0.0.0 --port=8080
fi

