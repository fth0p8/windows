# Dockerfile for Northflank - QEMU + noVNC image
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC

# Install required packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    qemu-utils \
    qemu-system-x86 \
    qemu-kvm \
    python3 \
    python3-pip \
    wget \
    curl \
    git \
    xvfb \
    x11vnc \
    socat \
    net-tools \
    unzip \
    ca-certificates \
    procps \
    iproute2 \
    bash-completion \
 && rm -rf /var/lib/apt/lists/*

# Install websockify and clone noVNC
RUN pip3 install --no-cache-dir websockify==0.10.0 \
 && git clone https://github.com/novnc/noVNC.git /opt/noVNC \
 && git clone https://github.com/novnc/websockify /opt/noVNC/utils/websockify

WORKDIR /root

# Copy start script
COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

# Northflank sets PORT env automatically; default 8080
ENV PORT 8080

CMD ["/usr/local/bin/start.sh"]
