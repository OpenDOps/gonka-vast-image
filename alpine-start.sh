#!/bin/bash
set -e

# Start SSH service if available (e.g., in Alpine test image)
SSH_USERNAME=${SSH_USERNAME:-frpuser}
if command -v sshd >/dev/null 2>&1; then
    mkdir -p /run/sshd
    if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
        ssh-keygen -A
    fi

    if id -u "$SSH_USERNAME" >/dev/null 2>&1 && [ -n "$SSH_PASSWORD" ]; then
        echo "$SSH_USERNAME:$SSH_PASSWORD" | chpasswd
    fi

    echo "Starting sshd..."
    /usr/sbin/sshd -D -e &
fi

/start.sh