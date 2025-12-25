#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# Libs
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/iso.sh"
source "$SCRIPT_DIR/lib/offline-apks.sh"

# -----------------------------
# Config
# -----------------------------
VM_LOCAL_WORKDIR="/tmp/autoinstall-build"
WORKDIR="$VM_LOCAL_WORKDIR"
ISO_DIR="$WORKDIR/iso"

OUT_ISO="$WORKDIR/alpine-autoprovision.iso"

ALPINE_ISO_URL="$(cat "$ROOT_DIR/alpine/iso/alpine.iso.url")"
PKGS_FILE="$ROOT_DIR/alpine/pkgs.txt"
REPOS_FILE="$ROOT_DIR/alpine/repositories.txt"
OVERLAY_DIR="$ROOT_DIR/overlay"

CLEAN=false

usage() {
  echo "Usage: build-usb.sh [--clean] [--out PATH]"
}

# -----------------------------
# Args
# -----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) CLEAN=true; shift;;
    --out) OUT_ISO="$2"; shift 2;;
    --help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

# -----------------------------
# Prepare workdir (VM-local!)
# -----------------------------
rm -rf "$VM_LOCAL_WORKDIR"
mkdir -p "$ISO_DIR"

# -----------------------------
# Build
# -----------------------------
BASE_ISO="$WORKDIR/base.iso"

download_iso "$ALPINE_ISO_URL" "$BASE_ISO"
extract_iso "$BASE_ISO" "$ISO_DIR"

# apkovl
APKVOL="$WORKDIR/localhost.apkovl.tar.gz"
build_apkovl "$OVERLAY_DIR" "$APKVOL"
install_apkovl_into_iso "$APKVOL" "$ISO_DIR" "localhost.apkovl.tar.gz"

# 🔥 OFFLINE APK FETCH (AQUÍ SE LLAMA)
fetch_offline_apks_if_possible \
  "$PKGS_FILE" \
  "$REPOS_FILE" \
  "$ISO_DIR/apks"

# -----------------------------
# Repack final ISO
# -----------------------------
log "Repacking final ISO..."
repack_iso_replay_boot "$BASE_ISO" "$ISO_DIR" "$OUT_ISO"

log "ISO built at: $OUT_ISO"
