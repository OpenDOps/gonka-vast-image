#!/bin/bash
set -e

# Client ID is a number from 01 to 99
if [[ ! "$CLIENT_ID" =~ ^[0-9]{2}$ ]]; then
    echo "CLIENT_ID must be a two-digit number between 01 and 99." >&2
    exit 1
fi

CLIENT_ID_NUM=$((10#$CLIENT_ID))
if [ "$CLIENT_ID_NUM" -lt 1 ] || [ "$CLIENT_ID_NUM" -gt 99 ]; then
    echo "CLIENT_ID must be between 01 and 99." >&2
    exit 1
fi

if [ -z "$SECRET_FRP_TOKEN" ] || [ -z "$FRP_SERVER_IP" ] || [ -z "$FRP_SERVER_PORT" ]; then
    echo "Missing FRP configuration: SECRET_FRP_TOKEN, FRP_SERVER_IP, and FRP_SERVER_PORT are required." >&2
    exit 1
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
remote_port = 50${CLIENT_ID}

[client-mlnode-${CLIENT_ID}]
type = tcp
local_ip = 127.0.0.1
local_port = 8081
remote_port = 80${CLIENT_ID}
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

    //TODO: Start parallel task to download model weights and start the inference server

    echo "Starting uvicorn application..."

    source /app/packages/api/.venv/bin/activate
    exec uvicorn api.app:app --host=0.0.0.0 --port=8080
fi

