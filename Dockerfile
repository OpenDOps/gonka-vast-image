FROM ghcr.io/product-science/mlnode:3.0.10

# Install nginx, pkg-config and wireguard userspace tools (without resolvconf)
RUN apt update && \
    apt install -y --no-install-recommends nginx nano wget pkg-config && \
    apt clean && \
    rm -rf /var/lib/apt/lists/*

# Install FRP client (frpc)
ARG FRP_VERSION=0.65.0
RUN mkdir -p /tmp/frp && \
    cd /tmp/frp && \
    wget -q "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_amd64.tar.gz" && \
    tar -xzf "frp_${FRP_VERSION}_linux_amd64.tar.gz" && \
    install -m 0755 "frp_${FRP_VERSION}_linux_amd64/frpc" /usr/bin/frpc && \
    rm -rf /tmp/frp && \
    mkdir -p /etc/frp /var/frp

# Install compressa-perf and Python dependencies, for benchmarking
RUN pip install --no-cache-dir pycparser secp256k1 \
    && pip install --no-cache-dir git+https://github.com/product-science/compressa-perf.git

# Configure nginx (single container version)
COPY nginx-single.conf /etc/nginx/nginx.conf

# Copy start script
COPY start.sh /start.sh
RUN chmod +x /start.sh

ENV HF_HOME=/data/hf-cache

WORKDIR /app

# Use start script as entrypoint
ENTRYPOINT ["/start.sh"]

