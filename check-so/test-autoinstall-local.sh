#!/usr/bin/env bash
set -euo pipefail

# test-autoinstall-local.sh
# Crea un loopback disk y simula varios casos para ejecutar
# `autoinstall-ubuntu.sh` en modo de prueba (`TEST_MODE=1`).

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AUTOINSTALL="$SCRIPT_DIR/autoinstall-ubuntu.sh"

usage(){
  cat <<EOF
Usage: $0 <case>
Cases:
  none            -> disco vacío (instalación esperada)
  wrong           -> OS diferente (ej: VERSION_ID=22.04)
  correct-noconfig-> Ubuntu 24.04 sin config_version
  correct-config  -> Ubuntu 24.04 con config_version
  grub-no-ds      -> Ubuntu 24.04 sin ds=nocloud en grub

Example: sudo $0 correct-noconfig
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then usage; exit 0; fi
case="$1"
if [ -z "$case" ]; then usage; exit 2; fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root." >&2
  exit 2
fi

for cmd in losetup sgdisk mkfs.ext4 mount umount dd; do
  command -v $cmd >/dev/null 2>&1 || { echo "$cmd required" >&2; exit 3; }
done

TMPDIR=$(mktemp -d)
IMG="$TMPDIR/loopdisk.img"
truncate -s 512M "$IMG"
echo "Created image $IMG"

loop=$(losetup --show -fP "$IMG")
echo "Loop device: $loop"

# Create two partitions: EFI 64M and rest root
sgdisk -og "$loop"
sgdisk -n1:1M:+64M -t1:ef00 -c1:"EFI" "$loop"
sgdisk -n2:0:0 -t2:8300 -c2:"root" "$loop"
partprobe "$loop" || true
sleep 1

part1="${loop}p1"
part2="${loop}p2"
if [ ! -b "$part1" ]; then part1="${loop}1"; part2="${loop}2"; fi

mkfs.vfat -n EFI "$part1"
mkfs.ext4 -F "$part2"

mountpoint="$TMPDIR/mnt"
mkdir -p "$mountpoint"

case $case in
  none)
    echo "Leaving root partition empty"
    ;;
  wrong)
    mount "$part2" "$mountpoint"
    mkdir -p "$mountpoint/etc"
    cat > "$mountpoint/etc/os-release" <<EOF
NAME="Ubuntu"
VERSION="22.04 LTS"
VERSION_ID="22.04"
EOF
    umount "$mountpoint"
    ;;
  correct-noconfig)
    mount "$part2" "$mountpoint"
    mkdir -p "$mountpoint/etc"
    cat > "$mountpoint/etc/os-release" <<EOF
NAME="Ubuntu"
VERSION="24.04 LTS"
VERSION_ID="24.04"
EOF
    # no config_version
    umount "$mountpoint"
    ;;
  correct-config)
    mount "$part2" "$mountpoint"
    mkdir -p "$mountpoint/etc"
    cat > "$mountpoint/etc/os-release" <<EOF
NAME="Ubuntu"
VERSION="24.04 LTS"
VERSION_ID="24.04"
EOF
    mkdir -p "$mountpoint/var/lib/autoprov"
    echo "1" > "$mountpoint/var/lib/autoprov/config_version"
    umount "$mountpoint"
    ;;
  grub-no-ds)
    mount "$part2" "$mountpoint"
    mkdir -p "$mountpoint/etc"
    cat > "$mountpoint/etc/os-release" <<EOF
NAME="Ubuntu"
VERSION="24.04 LTS"
VERSION_ID="24.04"
EOF
    mkdir -p "$mountpoint/boot/grub"
    echo "set default=0" > "$mountpoint/boot/grub/grub.cfg"
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' > "$mountpoint/etc/default/grub"
    umount "$mountpoint"
    ;;
  *) echo "Unknown case"; losetup -d "$loop"; rm -rf "$TMPDIR"; exit 4 ;;
esac

echo "Prepared case: $case on $loop"

echo "Running autoinstall in TEST_MODE..."
TEST_MODE=1 TEST_DISK="$loop" bash "$AUTOINSTALL"

echo "--- Post-run inspection ---"
mount "$part2" "$mountpoint" || true
if [ -d "$mountpoint" ]; then
  echo "/etc/os-release:"; cat "$mountpoint/etc/os-release" 2>/dev/null || true
  echo "/var/lib/autoprov/config_version:"; cat "$mountpoint/var/lib/autoprov/config_version" 2>/dev/null || true
  echo "/etc/default/grub:"; cat "$mountpoint/etc/default/grub" 2>/dev/null || true
  echo "/boot/grub/grub.cfg:"; cat "$mountpoint/boot/grub/grub.cfg" 2>/dev/null || true
  umount "$mountpoint" || true
fi

echo "Cleaning up"
losetup -d "$loop" || true
rm -rf "$TMPDIR"

echo "Done"
