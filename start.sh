#!/usr/bin/env bash
set -euo pipefail

# ---------------- Configurable via env ----------------
PORT="${PORT:-8080}"                      # Northflank will set this
ISO_URL="${ISO_URL:-}"                    # direct ISO link (or worker proxy)
VM_IMG="${VM_IMG:-/data/win.qcow2}"       # persistent mountpoint on Northflank
VM_RAM="${VM_RAM:-2048}"                  # MB (default 2048 = 2GB)
VM_SMP="${VM_SMP:-1}"
VNC_PORT="${VNC_PORT:-5901}"
DISK_SIZES=("20G" "10G" "6G")             # sizes to try (adjust per your volume)
QEMU_LOG="/tmp/qemu.log"
# -----------------------------------------------------

echo "Starting Container"
echo "[*] PORT=${PORT} VM_RAM=${VM_RAM}MB VM_IMG=${VM_IMG} ISO_URL=${ISO_URL:+(provided)}"

QEMU_PID=""
WEBSOCKIFY_PID=""

# helper
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# ensure qemu-img available (should be baked into image)
ensure_qemu() {
  if ! cmd_exists qemu-img; then
    echo "WARN: qemu-img not found. Rebuild image with qemu-utils in Dockerfile."
    return 1
  fi
  return 0
}

# download ISO with browser headers fallback and python fallback
download_iso() {
  if [ -f win.iso ]; then
    echo "[*] win.iso already present."
    return 0
  fi
  if [ -z "${ISO_URL}" ]; then
    echo "[*] No ISO_URL provided and win.iso not found."
    return 2
  fi

  echo "[*] Attempting ISO download from ISO_URL with browser headers..."
  UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36"
  REFERER="${REFERER:-https://yatoo.tualbola.workers.dev/}"

  if cmd_exists curl; then
    echo "[*] Trying curl..."
    if curl -L --fail --retry 5 --retry-delay 5 -A "${UA}" -e "${REFERER}" "${ISO_URL}" -o win.iso; then
      echo "[*] ISO downloaded with curl (size: $(du -h win.iso | cut -f1))."
      return 0
    else
      echo "WARN: curl download failed."
    fi
  fi

  if cmd_exists wget; then
    echo "[*] Trying wget..."
    if wget --tries=5 --user-agent="${UA}" --referer="${REFERER}" -O win.iso "${ISO_URL}"; then
      echo "[*] ISO downloaded with wget (size: $(du -h win.iso | cut -f1))."
      return 0
    else
      echo "WARN: wget download failed."
    fi
  fi

  if cmd_exists python3; then
    echo "[*] Trying Python downloader..."
    python3 - <<'PY' - "${ISO_URL}" "${UA}" "${REFERER}"
import sys, urllib.request, shutil
url = sys.argv[1]
ua = sys.argv[2]
referer = sys.argv[3]
req = urllib.request.Request(url, headers={'User-Agent': ua,
