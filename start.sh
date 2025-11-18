#!/usr/bin/env bash
set -euo pipefail

# ---------------- Configurable via env ----------------
PORT="${PORT:-8080}"            # Railway sets this
ISO_URL="${ISO_URL:-}"          # direct ISO link (optional)
VM_IMG="${VM_IMG:-win.qcow2}"
VM_RAM="${VM_RAM:-512}"         # in MB (increase if available)
VM_SMP="${VM_SMP:-1}"
VNC_PORT="${VNC_PORT:-5901}"
VNC_DISPLAY="${VNC_DISPLAY:-:1}"
DISK_SIZES=("10G" "6G" "3G")
QEMU_LOG="/tmp/qemu.log"
# -----------------------------------------------------

echo "Starting Container"
echo "[*] PORT=${PORT} VM_RAM=${VM_RAM}MB ISO_URL=${ISO_URL:+(provided)}"

QEMU_PID=""
WEBSOCKIFY_PID=""

# Helper: attempt to run command, return 0 if OK
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# Try to ensure qemu-img (attempt runtime install only if apt exists and we are root)
ensure_qemu() {
  if ! cmd_exists qemu-img; then
    echo "[*] qemu-img not found. Attempting runtime install..."
    if cmd_exists apt-get && [ "$(id -u)" = "0" ]; then
      apt-get update -y || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qemu-utils qemu-system-x86 || {
        echo "ERROR: runtime apt install failed. Please rebuild image with qemu packages in Dockerfile."
        return 1
      }
      echo "[*] qemu-utils installed."
    else
      echo "WARN: qemu-img missing and cannot install at runtime."
      return 1
    fi
  fi
  return 0
}

# Download using curl/wget or Python fallback
download_iso() {
  if [ -f win.iso ]; then
    echo "[*] win.iso already present."
    return 0
  fi
  if [ -z "${ISO_URL}" ]; then
    echo "[*] No ISO_URL provided and win.iso not found."
    return 2
  fi

  echo "[*] Attempting ISO download from ISO_URL..."

  if cmd_exists curl; then
    if curl -L --fail --retry 5 --retry-delay 5 "${ISO_URL}" -o win.iso; then
      echo "[*] ISO downloaded with curl (size: $(du -h win.iso | cut -f1))."
      return 0
    else
      echo "WARN: curl download failed."
    fi
  fi

  if cmd_exists wget; then
    if wget --tries=5 -O win.iso "${ISO_URL}"; then
      echo "[*] ISO downloaded with wget (size: $(du -h win.iso | cut -f1))."
      return 0
    else
      echo "WARN: wget download failed."
    fi
  fi

  # Python fallback (works if python3 available and network allowed)
  if cmd_exists python3; then
    echo "[*] Trying Python fallback downloader..."
    if python3 - "${ISO_URL}" <<'PY'
import sys, urllib.request
url = sys.argv[1]
out = "win.iso"
try:
    with urllib.request.urlopen(url) as r, open(out, "wb") as f:
        block = 1024*1024
        while True:
            chunk = r.read(block)
            if not chunk:
                break
            f.write(chunk)
    # success
    sys.exit(0)
except Exception as e:
    print("PY_DOWNLOAD_ERROR:", e, file=sys.stderr)
    sys.exit(2)
PY
    then
      echo "[*] ISO downloaded with Python fallback (size: $(du -h win.iso | cut -f1))."
      return 0
    else
      echo "WARN: Python fallback failed (maybe network blocked)."
    fi
  fi

  echo "ERROR: ISO download failed. Neither curl/wget nor Python succeeded."
  return 1
}

# Create qcow2 disk with fallback sizes
create_disk_with_fallbacks() {
  if [ -f "${VM_IMG}" ]; then
    echo "[*] Disk ${VM_IMG} exists."
    return 0
  fi
  if ! cmd_exists qemu-img; then
    echo "ERROR: qemu-img not available; cannot create disk."
    return 1
  fi
  for size in "${DISK_SIZES[@]}"; do
    echo "[*] Creating disk ${VM_IMG} size=${size} ..."
    if qemu-img create -f qcow2 "${VM_IMG}" "${size}"; then
      echo "[*] Created disk ${VM_IMG} (${size})"
      return 0
    else
      echo "WARN: creating ${size} failed; trying smaller."
    fi
  done
  echo "ERROR: failed to create any disk size; check host quota."
  return 1
}

KVM_AVAILABLE() { [ -c /dev/kvm ] 2>/dev/null && return 0 || return 1; }

start_qemu() {
  if ! cmd_exists qemu-system-x86_64; then
    echo "ERROR: qemu-system-x86_64 missing; cannot start qemu."
    return 1
  fi

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
    -nographic -monitor none
  )

  if KVM_AVAILABLE; then
    QEMU_CMD+=(-enable-kvm)
    echo "[*] KVM available; using -enable-kvm"
  else
    echo "[*] KVM not available; running in software emulation (slow)."
  fi

  echo "[*] Launching QEMU..."
  nohup "${QEMU_CMD[@]}" >"${QEMU_LOG}" 2>&1 &
  QEMU_PID=$!
  echo "[*] qemu pid=${QEMU_PID}"
  sleep 3
  # quick check if it's still alive
  if ! kill -0 "${QEMU_PID}" >/dev/null 2>&1; then
    echo "ERROR: qemu process died shortly after start. Check ${QEMU_LOG}."
    return 2
  fi
  return 0
}

start_websockify() {
  # prefer installed websockify, else python -m websockify
  if cmd_exists websockify; then
    WS_CMD=(websockify)
  elif python3 -m websockify --help >/dev/null 2>&1; then
    WS_CMD=(python3 -m websockify)
  elif [ -x /opt/noVNC/utils/websockify/run ]; then
    WS_CMD=(/opt/noVNC/utils/websockify/run)
  else
    echo "ERROR: websockify not available; cannot serve noVNC."
    return 1
  fi

  echo "[*] Starting websockify -> 127.0.0.1:${VNC_PORT} via port ${PORT}"
  nohup "${WS_CMD[@]}" --web /opt/noVNC "${PORT}" 127.0.0.1:${VNC_PORT} > /tmp/websockify.log 2>&1 &
  WEBSOCKIFY_PID=$!
  echo "[*] websockify pid=${WEBSOCKIFY_PID}"
  sleep 1
  if ! kill -0 "${WEBSOCKIFY_PID}" >/dev/null 2>&1; then
    echo "ERROR: websockify died shortly after start. See /tmp/websockify.log"
    return 2
  fi
  return 0
}

# Cleanup: kill known procs only (avoid pkill)
cleanup() {
  echo "[*] Cleaning up..."
  if [ -n "${WEBSOCKIFY_PID}" ]; then
    echo "[*] Killing websockify pid ${WEBSOCKIFY_PID}..."
    kill "${WEBSOCKIFY_PID}" >/dev/null 2>&1 || true
  fi
  if [ -n "${QEMU_PID}" ]; then
    echo "[*] Killing qemu pid ${QEMU_PID}..."
    kill "${QEMU_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# MAIN
ensure_qemu || true

download_iso || {
  rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "[*] No ISO available. Place win.iso in project root or set ISO_URL. Container will wait."
    tail -f /dev/null
    exit 0
  else
    echo "ERROR: ISO download failed. Exiting."
    exit 1
  fi
}

create_disk_with_fallbacks || exit 1

start_qemu || exit 1

start_websockify || {
  echo "ERROR: failed to start websockify/noVNC. Exiting."
  exit 1
}

echo "===================================================================="
echo "noVNC should be available at: http://<deployment-host>:${PORT}/vnc.html"
echo "If needed: http://<deployment-host>:${PORT}/vnc.html?host=<deployment-host>&port=${PORT}"
echo "During install: use the attached CD (win.iso) to install Windows 8.1 onto ${VM_IMG}."
echo "After install: shut down VM from within Windows and restart without -cdrom to boot from disk."
echo "To enable RDP inside Windows: enable Remote Desktop inside Windows and set a user password."
echo "===================================================================="
echo ""

tail -f "${QEMU_LOG}"
