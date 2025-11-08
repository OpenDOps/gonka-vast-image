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

# Determine FRP version and archive destination
FRP_VERSION=${FRP_VERSION:-0.65.0}
FRP_DOWNLOAD_DIR=/data
FRP_ARCHIVE="frp_${FRP_VERSION}_linux_amd64.tar.gz"
FRP_ARCHIVE_PATH="${FRP_DOWNLOAD_DIR}/${FRP_ARCHIVE}"
FRP_EXTRACT_DIR="${FRP_DOWNLOAD_DIR}/frp_${FRP_VERSION}_linux_amd64"

mkdir -p "${FRP_DOWNLOAD_DIR}"

if [ ! -f "${FRP_ARCHIVE_PATH}" ]; then
    FRP_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_ARCHIVE}"
    echo "Downloading FRP ${FRP_VERSION} from ${FRP_URL}..."
    wget -q -O "${FRP_ARCHIVE_PATH}" "${FRP_URL}"
else
    echo "FRP archive ${FRP_ARCHIVE} already present in ${FRP_DOWNLOAD_DIR}; skipping download."
fi

echo "Extracting FRP archive..."
tar -xzf "${FRP_ARCHIVE_PATH}" -C "${FRP_DOWNLOAD_DIR}"

if [ ! -x "${FRP_EXTRACT_DIR}/frpc" ] || [ ! -x "${FRP_EXTRACT_DIR}/frps" ]; then
    echo "Extracted FRP archive does not contain frpc/frps binaries." >&2
    exit 1
fi

echo "Installing FRP binaries to /usr/bin..."
install -m 0755 "${FRP_EXTRACT_DIR}/frpc" /usr/bin/frpc
install -m 0755 "${FRP_EXTRACT_DIR}/frps" /usr/bin/frps

echo "Preparing FRP configuration directories..."
mkdir -p /etc/frp
mkdir -p /var/frp

echo "Writing /etc/frp/frpc.ini..."
cat > /etc/frp/frpc.ini <<EOF
[common]
server_addr = ${FRP_SERVER_IP}
server_port = ${FRP_SERVER_PORT}
token = ${SECRET_FRP_TOKEN}

[client-mlnode-port5000-${CLIENT_ID}]
type = tcp
local_ip = 127.0.0.1
local_port = 5001
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
    python3 /http_server.py --port 5000 &
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

    echo "Starting uvicorn application..."

    source /app/packages/api/.venv/bin/activate
    exec uvicorn api.app:app --host=0.0.0.0 --port=8080
fi

