FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
# install required packages
RUN apt-get update && apt-get install -y \
    qemu-system-x86 \
    qemu-utils \
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
    && rm -rf /var/lib/apt/lists/*

# Install websockify and noVNC
RUN pip3 install websockify==0.10.0
RUN git clone https://github.com/novnc/noVNC.git /opt/noVNC \
    && git clone https://github.com/novnc/websockify /opt/noVNC/utils/websockify

WORKDIR /root

# Copy start script
COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

# Expose port used by web UI (Railway expects HTTP port)
# We'll use $PORT (Railway sets the env var), default 8080 if missing
ENV PORT 8080

CMD ["/usr/local/bin/start.sh"]
