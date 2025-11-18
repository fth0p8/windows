# Dockerfile - build image with qemu, noVNC, websockify, and helpers
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC

# Install required packages (qemu, python, websockify deps, git, curl, wget)
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
    bash-completion \
 && rm -rf /var/lib/apt/lists/*

# Install websockify via pip and clone noVNC
RUN pip3 install --no-cache-dir websockify==0.10.0 \
 && git clone https://github.com/novnc/noVNC.git /opt/noVNC \
 && git clone https://github.com/novnc/websockify /opt/noVNC/utils/websockify

WORKDIR /root

# Copy start script
COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

# Expose the HTTP port (Railway will map $PORT). We use runtime PORT env to start websockify.
ENV PORT 8080

CMD ["/usr/local/bin/start.sh"]
