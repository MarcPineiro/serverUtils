#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: burn.sh --iso <path.iso> --dev <blockdev> --force [options]

Required:
  --iso <path>                 Hybrid ISO to write
  --dev <device>               Target disk (recommended: /dev/disk/by-id/usb-...)
  --force                      Actually write (otherwise abort)

Options:
  --env-size-mib <MiB>         Size of ENV partition (default: 256)
  --no-persist                 Do not create PERSIST partition
  --persist-min-mib <MiB>      Minimum remaining MiB to create PERSIST (default: 256)
  --env-file <file>            Copy this file into ENV as /default.env (default: ./overlay/default.env)
  --yes-i-know                 Skip interactive "type YES" confirmation (still requires --force)
  --help

Notes:
- This will ERASE the entire target disk.
EOF
}

log() { echo "[+] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

ISO=""
DEV=""
FORCE=false
ENV_SIZE_MIB=1024
NO_PERSIST=false
PERSIST_MIN_MIB=1024
ENV_FILE="./overlay/default.env"
SKIP_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso) ISO="${2:-}"; shift 2;;
    --dev) DEV="${2:-}"; shift 2;;
    --force) FORCE=true; shift;;
    --env-size-mib) ENV_SIZE_MIB="${2:-}"; shift 2;;
    --no-persist) NO_PERSIST=true; shift;;
    --persist-min-mib) PERSIST_MIN_MIB="${2:-}"; shift 2;;
    --env-file) ENV_FILE="${2:-}"; shift 2;;
    --yes-i-know) SKIP_YES=true; shift;;
    --help) usage; exit 0;;
    *) die "Unknown arg: $1 (use --help)";;
  esac
done

[[ -n "$ISO" ]] || die "Missing --iso"
[[ -n "$DEV" ]] || die "Missing --dev"
[[ -f "$ISO" ]] || die "ISO not found: $ISO"
[[ -b "$DEV" ]] || die "Not a block device: $DEV"
$FORCE || die "Refusing to burn without --force"

REAL_DEV="$(readlink -f "$DEV")"
[[ -b "$REAL_DEV" ]] || die "Resolved device is not block: $REAL_DEV"

# Decide partition naming: /dev/sdc2 vs /dev/nvme0n1p2
part_path() {
  local disk="$1"
  local n="$2"
  if [[ "$(basename "$disk")" =~ ^nvme ]]; then
    echo "${disk}p${n}"
  else
    echo "${disk}${n}"
  fi
}

# Reintenta obtener la línea de la partición 1 con parted (evita race tras dd)
retry_pt_line() {
  local disk="$1"
  local tries="${2:-30}"
  local sleep_s="${3:-0.2}"
  local line=""

  for _ in $(seq 1 "$tries"); do
    partprobe "$disk" >/dev/null 2>&1 || true
    udevadm settle >/dev/null 2>&1 || true

    line="$(parted -ms "$disk" unit MiB print 2>/dev/null | awk -F: '$1=="1"{print; exit}')"
    if [[ -n "$line" ]]; then
      echo "$line"
      return 0
    fi
    sleep "$sleep_s"
  done
  return 1
}

BASE="$(basename "$REAL_DEV")"
REMOVABLE="0"
if [[ -r "/sys/block/$BASE/removable" ]]; then
  REMOVABLE="$(cat "/sys/block/$BASE/removable" || echo 0)"
fi

log "Target device: $DEV -> $REAL_DEV"
log "ISO: $ISO"
log "ENV size: ${ENV_SIZE_MIB} MiB"
log "PERSIST: $([[ "$NO_PERSIST" == true ]] && echo disabled || echo enabled)"

if [[ "$REMOVABLE" != "1" ]]; then
  log "WARNING: $REAL_DEV does not report removable=1."
  log "If this is not your USB, STOP NOW."
fi

if [[ "$SKIP_YES" != true ]]; then
  echo
  echo "ABOUT TO ERASE: $REAL_DEV"
  lsblk -o NAME,MODEL,SIZE,TRAN,RM,MOUNTPOINT "$REAL_DEV" || true
  echo
  read -r -p "Type YES to continue: " ans
  [[ "$ans" == "YES" ]] || die "Aborted"
fi

# Unmount anything mounted from this disk
log "Unmounting any mounted partitions on $REAL_DEV (if any)..."
while read -r mp; do
  [[ -n "$mp" ]] || continue
  log "umount $mp"
  umount "$mp" || true
done < <(lsblk -nrpo MOUNTPOINT "$REAL_DEV" | sed '/^$/d' | sort -r)

# Write ISO to disk start
log "Writing ISO with dd..."
dd if="$ISO" of="$REAL_DEV" bs=4M status=progress conv=fsync
sync

log "Re-reading partition table..."
partprobe "$REAL_DEV" >/dev/null 2>&1 || true
udevadm settle >/dev/null 2>&1 || true

# Detect ISO end: prefer partition table (part 1), fallback to ISO file size
log "Detecting ISO end..."
ISO_END_MIB=""

PT_LINE=""
if PT_LINE="$(retry_pt_line "$REAL_DEV" 30 0.2)"; then
  ISO_END_MIB_RAW="$(echo "$PT_LINE" | awk -F: '{print $3}')"
  ISO_END_MIB="${ISO_END_MIB_RAW%MiB}"
  [[ -n "$ISO_END_MIB" ]] || die "Failed to parse partition 1 end"
  log "ISO end from partition table: ~${ISO_END_MIB} MiB"
else
  ISO_SIZE_BYTES="$(stat -c%s "$ISO")"
  ISO_END_MIB="$(python3 - <<PY
import math
print(int(math.ceil($ISO_SIZE_BYTES / (1024*1024))))
PY
)"
  log "WARNING: Could not read partition 1 via parted yet; using ISO file size as end: ~${ISO_END_MIB} MiB"
fi

# Disk size MiB (robust)
DISK_SIZE_BYTES="$(blockdev --getsize64 "$REAL_DEV")"
DISK_SIZE_MIB="$(python3 - <<PY
import math
print(int(math.floor($DISK_SIZE_BYTES / (1024*1024))))
PY
)"

# Align: start next partition a bit after ISO end
ENV_START_MIB="$(python3 - <<PY
import math
end=float("$ISO_END_MIB")
print(int(math.ceil(end+1.0)))
PY
)"
ENV_END_MIB="$((ENV_START_MIB + ENV_SIZE_MIB))"

log "Creating ENV: ${ENV_START_MIB} MiB -> ${ENV_END_MIB} MiB"

# Create ENV partition #2 after the ISO
parted -s "$REAL_DEV" mkpart primary fat32 "${ENV_START_MIB}MiB" "${ENV_END_MIB}MiB"
partprobe "$REAL_DEV" >/dev/null 2>&1 || true
udevadm settle >/dev/null 2>&1 || true

ENV_PART="$(part_path "$REAL_DEV" 2)"
[[ -b "$ENV_PART" ]] || die "ENV partition not found: $ENV_PART"

mkfs.vfat -F 32 -n ENV "$ENV_PART"

# Create PERSIST partition #3 (optional)
PERSIST_PART=""
if [[ "$NO_PERSIST" != true ]]; then
  PERSIST_START_MIB="$((ENV_END_MIB + 1))"
  REMAIN_MIB="$(python3 - <<PY
disk=float("$DISK_SIZE_MIB")
start=float("$PERSIST_START_MIB")
print(int(disk - start))
PY
)"
  if (( REMAIN_MIB < PERSIST_MIN_MIB )); then
    log "Not enough space for PERSIST (remaining ~${REMAIN_MIB} MiB, min ${PERSIST_MIN_MIB} MiB). Skipping."
  else
    log "Creating PERSIST: ${PERSIST_START_MIB} MiB -> 100%"
    parted -s "$REAL_DEV" mkpart primary ext4 "${PERSIST_START_MIB}MiB" 100%
    partprobe "$REAL_DEV" >/dev/null 2>&1 || true
    udevadm settle >/dev/null 2>&1 || true

    PERSIST_PART="$(part_path "$REAL_DEV" 3)"
    [[ -b "$PERSIST_PART" ]] || die "PERSIST partition not found: $PERSIST_PART"
    mkfs.ext4 -F -L PERSIST "$PERSIST_PART"
  fi
fi

# Copy default.env into ENV
if [[ -n "$ENV_FILE" ]]; then
  [[ -f "$ENV_FILE" ]] || die "--env-file not found: $ENV_FILE"
  log "Copying env file into ENV as /default.env: $ENV_FILE"
  mkdir -p /mnt/env
  mount "$ENV_PART" /mnt/env
  cp -f "$ENV_FILE" /mnt/env/default.env
  sync
  umount /mnt/env
fi

log "Done. Final layout:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,TRAN,RM,MOUNTPOINT "$REAL_DEV" || true

echo
echo "ENV:     $ENV_PART (label ENV)  -> contains /default.env"
if [[ -n "$PERSIST_PART" ]]; then
  echo "PERSIST: $PERSIST_PART (label PERSIST)"
else
  echo "PERSIST: not created"
fi
