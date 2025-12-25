#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --clean                  Rebuild from scratch
  --usb <device>           Burn final ISO to this USB and create ENV/PERSIST
                           (recommended: /dev/disk/by-id/usb-...)
  --env-size-mib <MiB>     ENV size (default: 256)
  --no-persist             Do not create PERSIST
  --force                  Required when using --usb (dangerous)
  --help
EOF
}

# Guardrail
if [[ "$(id -u)" -eq 0 ]]; then
  echo "ERROR: Do not run this script with sudo."
  exit 1
fi

CLEAN=false
USB_DEV=""
ENV_SIZE_MIB=1024
NO_PERSIST=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) CLEAN=true; shift;;
    --usb) USB_DEV="${2:-}"; shift 2;;
    --env-size-mib) ENV_SIZE_MIB="${2:-}"; shift 2;;
    --no-persist) NO_PERSIST=true; shift;;
    --force) FORCE=true; shift;;
    --help) usage; exit 0;;
    *)
      echo "Unknown arg: $1"
      usage
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

ISO_VM="/tmp/autoinstall-build/alpine-autoprovision.iso"
ISO_HOST="$ROOT_DIR/out/alpine-autoprovision.iso"

# 🔑 CORRECT PATH (THIS WAS WRONG BEFORE)
ENV_FILE_HOST="$ROOT_DIR/overlay/opt/autorun/default.env"

echo "[+] Project root: $ROOT_DIR"
echo "[+] Starting Vagrant VM…"
( cd "$ROOT_DIR" && vagrant up )

echo "[+] Running ISO build inside VM…"

INNER_ARGS=()
$CLEAN && INNER_ARGS+=(--clean)
INNER_ARGS+=(--out "$ISO_VM")

( cd "$ROOT_DIR" && vagrant ssh -c "
  set -e
  cd /work
  chmod +x build/build-usb.sh
  sudo build/build-usb.sh ${INNER_ARGS[*]}
  sudo mkdir -p /work/out
  sudo cp -f '$ISO_VM' /work/out/alpine-autoprovision.iso
  ls -lah /work/out/alpine-autoprovision.iso
" )

mkdir -p "$ROOT_DIR/out"

if [[ ! -f "$ISO_HOST" ]]; then
  echo "❌ ERROR: ISO not found at $ISO_HOST"
  exit 1
fi

echo "✅ ISO ready: $ISO_HOST"

# -----------------------------
# Optional burn + partitions
# -----------------------------
if [[ -n "$USB_DEV" ]]; then
  [[ -b "$USB_DEV" ]] || { echo "❌ Not a block device: $USB_DEV"; exit 1; }
  [[ "$FORCE" == true ]] || { echo "❌ --usb requires --force"; exit 1; }
  [[ -f "$ENV_FILE_HOST" ]] || { echo "❌ Env file not found: $ENV_FILE_HOST"; exit 1; }

  echo "[+] Burning ISO to USB: $USB_DEV"
  echo "[+] ENV file: $ENV_FILE_HOST"

  sudo bash "$ROOT_DIR/build/lib/burn.sh" \
    --iso "$ISO_HOST" \
    --dev "$USB_DEV" \
    --env-size-mib "$ENV_SIZE_MIB" \
    $([[ "$NO_PERSIST" == true ]] && echo "--no-persist") \
    --env-file "$ENV_FILE_HOST" \
    --force

  echo "✅ USB ready."
else
  echo "[i] No --usb provided, skipping burn."
fi
