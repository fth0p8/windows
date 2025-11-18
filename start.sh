#!/usr/bin/env bash
set -e

# Default values (change via env)
PORT="${PORT:-8080}"
ISO_URL="${ISO_URL:-}"
VM_IMG="win.qcow2"
VM_RAM="${VM_RAM:-1024}"      # in MB; lower if you have only 512
VM_SMP="${VM_SMP:-1}"
VNC_PORT="5901"              # internal vnc port (we'll websockify it)
VNC_DISPLAY=":1"

echo "[*] Starting container, PORT=${PORT}, VM_RAM=${VM_RAM}MB"

# Create disk if not exists
if [ ! -f "${VM_IMG}" ]; then
  echo "[*] Creating disk ${VM_IMG} (10G)"
  qemu-img create -f qcow2 "${VM_IMG}" 10G
fi

# Download ISO if ISO_URL provided and not present
if [ -n "${ISO_URL}" ] && [ ! -f win.iso ]; then
  echo "[*] Downloading ISO from ISO_URL..."
  # try curl then wget
  if command -v curl >/dev/null 2>&1; then
    curl -L "${ISO_URL}" -o win.iso || { echo "Download failed"; exit 1; }
  else
    wget -O win.iso "${ISO_URL}" || { echo "Download failed"; exit 1; }
  fi
  echo "[*] ISO downloaded to win.iso"
fi

# If no ISO is present, advise the user and wait
if [ ! -f win.iso ]; then
  echo "ERROR: No ISO found. Set ISO_URL env var to a direct-download link or upload win.iso to project root."
  echo "Exiting."
  tail -f /dev/null
fi

# Start QEMU
echo "[*] Starting QEMU (headless) with VNC on 127.0.0.1:${VNC_PORT}"
# Use -vnc to listen only on localhost for security
qemu-system-x86_64 \
  -m "${VM_RAM}" \
  -smp "${VM_SMP}" \
  -cpu qemu64 \
  -drive file="${VM_IMG}",format=qcow2,if=virtio \
  -cdrom win.iso \
  -boot d \
  -vnc 127.0.0.1:1 \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::3389-:3389 \
  -nographic \
  -enable-kvm \
  -monitor none \
  >/tmp/qemu.log 2>&1 &

QEMU_PID=$!
echo "[*] qemu pid=${QEMU_PID}"
sleep 3

# Start websockify to expose VNC via websocket (noVNC)
echo "[*] Starting websockify to bridge websocket -> 127.0.0.1:${VNC_PORT}"
/usr/local/bin/websockify --web /opt/noVNC "${PORT}" 127.0.0.1:${VNC_PORT} &

WEBSOCKIFY_PID=$!
echo "[*] websockify pid=${WEBSOCKIFY_PID}"

echo "===================================================================="
echo "noVNC should be available at: http://<railway-host>:${PORT}/vnc.html?host=<railway-host>&port=${PORT}"
echo "If your browser has CORS/host issues, open: http://<railway-host>:${PORT}/vnc.html"
echo "During install: use the mounted CD (win.iso) to install Windows 8.1 onto the qcow2 disk."
echo "After install: shut down VM and restart without -cdrom (or change boot order) to boot from disk."
echo "To enable RDP inside Windows: enable Remote Desktop from System settings, set a password, and ensure port 3389 is reachable or use SSH tunneling."
echo "===================================================================="

# Keep container alive and tail qemu log
tail -f /tmp/qemu.log
