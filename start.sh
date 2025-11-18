#!/usr/bin/env bash
set -euo pipefail

# ---------------- Configurable via env ----------------
PORT="${PORT:-8080}"            # Railway will set PORT automatically
ISO_URL="${ISO_URL:-}"          # direct ISO link (optional)
VM_IMG="${VM_IMG:-win.qcow2}"
VM_RAM="${VM_RAM:-512}"         # in MB (set to 1024 or more if available)
VM_SMP="${VM_SMP:-1}"
VNC_PORT="${VNC_PORT:-5901}"    # qemu VNC listening port (local)
VNC_DISPLAY="${VNC_DISPLAY:-:1}"
DISK_SIZES=("10G" "6G" "3G")    # fallback sizes if create fails
QEMU_LOG="/tmp/qemu.log"
# -----------------------------------------------------

echo "Starting Container"
echo "[*] PORT=${PORT} VM_RAM=${VM_RAM}MB ISO_URL=${ISO_URL:+(provided)}"

# Ensure qemu-img available (try to install at runtime if missing)
ensure_qemu() {
  if ! command -v qemu-img >/dev/null 2>&1; then
    echo "[*] qemu-img not found. Attempting runtime install of qemu-utils..."
    if command -v apt-get >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
      apt-get update -y || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qemu-utils qemu-system-x86 || {
        echo "ERROR: failed to install qemu-utils at runtime. You should rebuild the image with qemu packages in Dockerfile."
        return 1
      }
      echo "[*] qemu-utils installed."
    else
      echo "ERROR: cannot install packages at runtime (no apt or not root). Please rebuild the image with qemu packages."
      return 1
    fi
  fi
  return 0
}

# Try ensure qemu-img; if fails, continue but qemu-img will be missing
if ! ensure_qemu; then
  echo "Continuing but qemu-img may be missing. qemu-img required to create disk images."
fi

# Function: attempt to create qcow2 disk with fallback sizes
create_disk_with_fallbacks() {
  if [ -f "${VM_IMG}" ]; then
    echo "[*] Disk ${VM_IMG} already exists."
    return 0
  fi

  for size in "${DISK_SIZES[@]}"; do
    echo "[*] Creating disk ${VM_IMG} size=${size} ..."
    if qemu-img create -f qcow2 "${VM_IMG}" "${size}"; then
      echo "[*] Created disk ${VM_IMG} (${size})"
      return 0
    else
      echo "[!] Failed to create ${size}. Trying smaller size..."
    fi
  done

  echo "ERROR: Failed to create any disk size. Check host storage/quota."
  return 1
}

# Download ISO if ISO_URL provided and win.iso not present
download_iso_if_needed() {
  if [ -f win.iso ]; then
    echo "[*] win.iso already present locally."
    return 0
  fi
  if [ -n "${ISO_URL}" ]; then
    echo "[*] Downloading ISO from ISO_URL..."
    # prefer curl then wget
    if command -v curl >/dev/null 2>&1; then
      curl -L --fail --retry 5 --retry-delay 5 "${ISO_URL}" -o win.iso || {
        echo "ERROR: ISO download failed (curl)."
        return 1
      }
    elif command -v wget >/dev/null 2>&1; then
      wget --tries=5 -O win.iso "${ISO_URL}" || {
        echo "ERROR: ISO download failed (wget)."
        return 1
      }
    else
      echo "ERROR: neither curl nor wget available to download ISO."
      return 1
    fi
    echo "[*] ISO downloaded to win.iso (size: $(du -h win.iso | cut -f1))."
    return 0
  fi

  echo "No ISO present and no ISO_URL provided. Place win.iso in project root or set ISO_URL env var."
  return 2
}

# Check for /dev/kvm (KVM availability). If missing, remove -enable-kvm later.
KVM_AVAILABLE() {
  [ -c /dev/kvm ] 2>/dev/null && return 0 || return 1
}

# Start QEMU with dynamic options (no -enable-kvm if unavailable)
start_qemu() {
  # Build qemu command in variable
  QEMU_CMD=(qemu-system-x86_64
    -m "${VM_RAM}"
    -smp "${VM_SMP}"
    -cpu qemu64
    -drive "file=${VM_IMG},format=qcow2,if=virtio"
    -cdrom win.iso
    -boot d
    -vnc 127.0.0.1:1
    -device virtio-net-pci,netdev=net0
    -netdev user,id=net0,hostfwd=tcp::3389-:3389
    -nographic
    -monitor none
  )

  if KVM_AVAILABLE; then
    QEMU_CMD+=(-enable-kvm)
    echo "[*] KVM available; starting qemu with -enable-kvm"
  else
    echo "[*] KVM not available on this host; starting qemu in software emulation (slower)."
  fi

  echo "[*] Launching QEMU..."
  # Start qemu in background, redirect stdout/stderr to log
  nohup "${QEMU_CMD[@]}" >"${QEMU_LOG}" 2>&1 &
  QEMU_PID=$!
  echo "[*] qemu pid=${QEMU_PID}"
  sleep 3
}

# Start websockify to expose noVNC
start_websockify() {
  # Ensure websockify is available (installed in Dockerfile via pip)
  if ! command -v websockify >/dev/null 2>&1; then
    # try python -m websockify fallback
    if python3 -m websockify --help >/dev/null 2>&1; then
      WEBSOCKIFY_CMD=(python3 -m websockify)
    elif [ -x /usr/local/bin/websockify ]; then
      WEBSOCKIFY_CMD=("/usr/local/bin/websockify")
    else
      echo "ERROR: websockify not found. noVNC won't work."
      return 1
    fi
  else
    WEBSOCKIFY_CMD=(websockify)
  fi

  echo "[*] Starting websockify to bridge websocket -> 127.0.0.1:${VNC_PORT}"
  # serve noVNC static files and bridge to VNC
  nohup "${WEBSOCKIFY_CMD[@]}" --web /opt/noVNC "${PORT}" 127.0.0.1:${VNC_PORT} > /tmp/websockify.log 2>&1 &
  WEBSOCKIFY_PID=$!
  echo "[*] websockify pid=${WEBSOCKIFY_PID}"
  return 0
}

# Trap to stop processes gracefully
cleanup() {
  echo "[*] Cleaning up..."
  pkill -P $$ || true
  if [ -n "${QEMU_PID:-}" ]; then
    kill "${QEMU_PID}" >/dev/null 2>&1 || true
  fi
  if [ -n "${WEBSOCKIFY_PID:-}" ]; then
    kill "${WEBSOCKIFY_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# MAIN
# 1) ensure qemu-img present (attempt if not)
ensure_qemu || true

# 2) download ISO or wait for local win.iso
download_iso_if_needed || {
  code=$?
  if [ "$code" -eq 2 ]; then
    echo "[*] Waiting for win.iso to appear in project root. Container will stay alive."
    tail -f /dev/null
    exit 0
  else
    echo "ERROR: ISO download failed. Exiting."
    exit 1
  fi
}

# 3) create qcow2 disk with fallbacks
create_disk_with_fallbacks || exit 1

# 4) start QEMU
start_qemu

# 5) start websockify / noVNC
start_websockify || {
  echo "ERROR: failed to start websockify/noVNC. Check logs."
  exit 1
}

# 6) print helpful hints and tail logs
echo "===================================================================="
echo "noVNC should be available at: http://<deployment-host>:${PORT}/vnc.html"
echo "If needed: http://<deployment-host>:${PORT}/v
