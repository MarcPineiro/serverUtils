#!/usr/bin/env bash
# autoinstall-usb/validate-build.sh
#
# Post-build validator (agent-plan Phase 1: "Add a post-build validator").
# Mounts both partitions of a built USB (real disk, whole-disk device, or a
# raw --image file) read-only, verifies every artifact the plan requires,
# and emits build-manifest.json with sha256 hashes (Completion evidence:
# "build-manifest.json matching the tested USB").
#
# Usage:
#   ./validate-build.sh --dev /dev/sdX [--out build-manifest.json]
#   ./validate-build.sh --image ./usb.img [--out build-manifest.json]
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/functions.sh
source "$SCRIPT_ROOT/lib/functions.sh"
# shellcheck source=lib/grub.sh
source "$SCRIPT_ROOT/lib/grub.sh"
# shellcheck source=lib/syslinux.sh
source "$SCRIPT_ROOT/lib/syslinux.sh"
# shellcheck source=lib/validate.sh
source "$SCRIPT_ROOT/lib/validate.sh"

trap cleanup_on_exit EXIT

usage() {
  cat <<'EOF'
sudo ./validate-build.sh --dev /dev/sdX [--out build-manifest.json]
sudo ./validate-build.sh --image ./usb.img [--out build-manifest.json]

Mounts both partitions read-only, verifies UEFI loader, BIOS loader (if
present), kernel, initrd, mydata.tgz, package list, cached packages,
environment file, and bootstrap fallback, checks that grub.cfg/syslinux
configs reference the real filesystem UUIDs, and writes build-manifest.json
(default: ./build-manifest.json) with sha256 hashes of every artifact.
EOF
}

DEV=""
IMAGE=""
OUT="build-manifest.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev) DEV="$2"; shift 2;;
    --image) IMAGE="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

[[ -n "$DEV" || -n "$IMAGE" ]] || { usage; die "One of --dev or --image is required"; }
[[ -z "$DEV" || -z "$IMAGE" ]] || die "--dev and --image are mutually exclusive"

have blkid || die "Missing blkid (util-linux)"

TARGET_DEV="$DEV"
if [[ -n "$IMAGE" ]]; then
  [[ -f "$IMAGE" ]] || die "No such image: $IMAGE"
  have losetup || die "losetup is required to validate --image"
  TARGET_DEV="$(losetup --find --show --read-only --partscan "$IMAGE")"
  register_cleanup_loop "$TARGET_DEV"
else
  require_whole_disk "$DEV"
fi

esp_dev="$(partition_path "$TARGET_DEV" 1)"
persist_dev="$(partition_path "$TARGET_DEV" 2)"
[[ -b "$esp_dev" ]] || die "Missing ESP partition: $esp_dev"
[[ -b "$persist_dev" ]] || die "Missing PERSIST partition: $persist_dev"

esp_uuid="$(blkid -s UUID -o value "$esp_dev" || true)"
data_uuid="$(blkid -s UUID -o value "$persist_dev")"
[[ -n "$esp_uuid" ]] || die "Cannot read UUID from ESP ($esp_dev)"
[[ -n "$data_uuid" ]] || die "Cannot read UUID from PERSIST ($persist_dev)"

work="$(mktemp -d)"
register_cleanup_dir "$work"
esp_mnt="$work/esp"
persist_mnt="$work/persist"
mkdir -p "$esp_mnt" "$persist_mnt"

mount -o ro "$esp_dev" "$esp_mnt" || die "Cannot mount ESP $esp_dev read-only"
register_cleanup_mount "$esp_mnt"
mount -o ro "$persist_dev" "$persist_mnt" || die "Cannot mount PERSIST $persist_dev read-only"
register_cleanup_mount "$persist_mnt"

echo "[+] Validating ESP ($esp_dev, UUID=$esp_uuid) ..."
boot_files="$(validate_esp_root "$esp_mnt" "$esp_uuid" "$data_uuid")"
kernel="${boot_files%%|*}"
initrd="${boot_files##*|}"

echo "[+] Validating PERSIST ($persist_dev, UUID=$data_uuid) ..."
validate_persist_root "$persist_mnt"

echo "[+] All checks passed. Writing manifest: $OUT"
emit_build_manifest "$esp_mnt" "$persist_mnt" "$esp_uuid" "$data_uuid" "$kernel" "$initrd" >"$OUT"

echo "[+] Wrote $OUT"
