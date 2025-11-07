#!/bin/bash
set -e

# Generate wireguard keys and config if environment variables are provided
if [ -n "$SECRET_FRP_TOKEN" ] && [ -n "$FRP_SERVER_IP" ] && [ -n "$FRP_SERVER_PORT" ]; then
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
    else
        echo "FRP archive ${FRP_ARCHIVE} already present in ${FRP_DOWNLOAD_DIR}; skipping download."
    fi

    echo "Writing /etc/frp/frpc.ini..."
    cat > /etc/frp/frpc.ini <<EOF
[common]
server_addr = ${FRP_SERVER_IP}
server_port = ${FRP_SERVER_PORT}
token = ${SECRET_FRP_TOKEN}

[client-web]
type = tcp
local_ip = 127.0.0.1
local_port = 5000
remote_port = 15000
EOF

    echo "Creating systemd unit /etc/systemd/system/frpc.service..."
    cat > /etc/systemd/system/frpc.service <<'EOF'
[Unit]
Description=Frp Client Service
After=network.target

[Service]
Type=simple
User=nobody
Restart=on-failure
RestartSec=5s
ExecStart=/usr/bin/frpc -c /etc/frp/frpc.ini
ExecReload=/usr/bin/frpc reload -c /etc/frp/frpc.ini
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        echo "Starting FRP client service via systemd..."
        systemctl daemon-reload
        systemctl enable frpc
        systemctl restart frpc
    else
        echo "systemctl not found; starting frpc in background..."
        /usr/bin/frpc -c /etc/frp/frpc.ini &
    fi
fi

# Start nginx in background
nginx &
NGINX_PID=$!

# Wait a moment for nginx to start
sleep 1

# Start the appropriate service based on UBUNTU_TEST flag
if [ "${UBUNTU_TEST}" = "true" ]; then
    echo "UBUNTU_TEST is true; starting test HTTP server..."
    exec python3 /http_server.py --port 8080
else
    echo "Starting uvicorn application..."
    exec uvicorn api.app:app --host=0.0.0.0 --port=8080
fi

