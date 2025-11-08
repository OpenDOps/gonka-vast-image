FROM ghcr.io/product-science/mlnode:3.0.10

# Install nginx and wireguard userspace tools (without resolvconf)
RUN apt update && \
    apt install -y --no-install-recommends nginx nano wget && \
    apt clean && \
    rm -rf /var/lib/apt/lists/*

# Configure nginx (single container version)
COPY nginx-single.conf /etc/nginx/nginx.conf

# Copy start script
COPY start.sh /start.sh
RUN chmod +x /start.sh

WORKDIR /app

# Use start script as entrypoint
ENTRYPOINT ["/start.sh"]

