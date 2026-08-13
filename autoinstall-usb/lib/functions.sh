#!/usr/bin/env bash
# autoinstall-usb/lib/functions.sh
#
# Small, pure(ish) helper functions shared by build-tinycore-usb.sh and
# validate-build.sh. This file only defines functions: sourcing it has no
# side effects, so it is safe to `source` from Bats unit tests with mocked
# `lsblk`/`blkid` on PATH instead of real block devices.
#
# shellcheck shell=bash

die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# partition_path DISK NUM
# Builds the Nth partition device path for a whole-disk device, handling the
# device families used across the fleet: /dev/sdX, /dev/vdX, /dev/mmcblkN,
# /dev/nvmeNnN and loop devices (all of which need a "p" separator when the
# disk name itself ends in a digit).
partition_path() {
  local disk="$1" num="$2"
  [[ -n "$disk" && -n "$num" ]] || die "partition_path: disk and number are required"
  case "$disk" in
    *[0-9]) printf '%sp%s\n' "$disk" "$num" ;;
    *) printf '%s%s\n' "$disk" "$num" ;;
  esac
}

# is_whole_disk DEV
# True only when lsblk reports TYPE=disk for DEV (never a partition, loop
# partition, or other node).
is_whole_disk() {
  local dev="$1" type
  have lsblk || die "is_whole_disk: lsblk is required"
  type="$(lsblk -ndo TYPE "$dev" 2>/dev/null || true)"
  [[ "$type" == "disk" ]]
}

# require_whole_disk DEV
# Dies unless DEV is a block device and lsblk confirms TYPE=disk.
require_whole_disk() {
  local dev="$1"
  [[ -b "$dev" ]] || die "not a block device: $dev"
  is_whole_disk "$dev" || die "refusing to target a non-whole-disk device (lsblk TYPE != disk): $dev"
}

# disk_serial DEV
# Empty string if lsblk reports no serial.
disk_serial() {
  local dev="$1"
  lsblk -ndo SERIAL "$dev" 2>/dev/null | tr -d '[:space:]'
}

# print_disk_info DEV
# Human-readable model/serial/size/transport/mounts, printed before any
# destructive action (agent-plan Phase 1: "Print model, serial, size,
# transport, and current mounts before erasure").
print_disk_info() {
  local dev="$1"
  echo "[!] Target device: $dev"
  lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,ROTA,MOUNTPOINT "$dev" 2>/dev/null || true
}

# confirm_erase_token DEV TOKEN_TO_TYPE ASSUME_YES
# Prints disk info, then requires the operator to type TOKEN_TO_TYPE exactly
# (the device serial for real disks, or the absolute image path for
# --image builds, since images have no serial). ASSUME_YES=1 skips the
# interactive prompt but never skips printing the info.
confirm_erase_token() {
  local dev="$1" token="$2" assume_yes="$3"
  [[ -n "$token" ]] || die "confirm_erase_token: no confirmation token available for $dev"
  print_disk_info "$dev"
  if [[ "$assume_yes" == "1" ]]; then
    echo "[!] -y supplied: skipping interactive confirmation prompt (token was: $token)"
    return 0
  fi
  local ans
  read -r -p "Type the exact confirmation token to ERASE $dev [$token]: " ans
  [[ "$ans" == "$token" ]] || die "Confirmation token did not match. Aborted."
}

# sha256_file PATH
sha256_file() {
  local path="$1"
  have sha256sum || die "sha256_file: sha256sum is required"
  sha256sum "$path" | awk '{print $1}'
}

# verify_tcz_dir_against_manifest TCZ_DIR
# When TCZ_DIR (or its parent, for the fetch-tcz.sh layout) carries a
# manifest.json produced by fetch-tcz.sh, every *.tcz found in TCZ_DIR must
# match its recorded sha256 exactly (agent-plan Phase 1: "Verify all cached
# packages match the manifest checksums before copying"). Used both while
# building (build-tinycore-usb.sh, before copying onto the USB) and while
# validating an already-built USB (validate-build.sh, against tce/optional).
# Dies loudly on any mismatch or missing manifest entry. Prints a WARNING
# (does not fail) when no manifest exists at all, since an arbitrary manually
# populated --tcz-dir is not something this project can pin.
verify_tcz_dir_against_manifest() {
  local tcz_dir="$1"
  local manifest=""
  if [[ -f "$tcz_dir/manifest.json" ]]; then
    manifest="$tcz_dir/manifest.json"
  elif [[ -f "$(dirname "$tcz_dir")/manifest.json" ]]; then
    manifest="$(dirname "$tcz_dir")/manifest.json"
  fi

  if [[ -z "$manifest" ]]; then
    echo "[!] WARNING: no manifest.json found for --tcz-dir=$tcz_dir; packages are unpinned/unverified." >&2
    return 0
  fi

  have jq || die "jq is required to verify $manifest"
  echo "[+] Verifying cached packages against $manifest ..."
  local f name expected actual
  shopt -s nullglob
  for f in "$tcz_dir"/*.tcz; do
    name="$(basename "$f")"
    expected="$(jq -r --arg n "$name" '.packages[] | select(.name==$n) | .sha256' "$manifest")"
    [[ -n "$expected" ]] || die "manifest.json has no entry for $name (refusing to copy an unpinned package)"
    actual="$(sha256_file "$f")"
    [[ "$expected" == "$actual" ]] || die "Checksum mismatch for $name: manifest says $expected, file is $actual"
  done
  shopt -u nullglob
}

# --- EXIT-trap cleanup registry -------------------------------------------
# Global arrays populated by callers; a single `trap cleanup_on_exit EXIT`
# registered once at top level guarantees mounts/loop devices/tmpdirs are
# released even when `die`/`set -e` short-circuits the normal control flow
# (a per-function `RETURN` trap does not fire on `exit`).
CLEANUP_MOUNTS=()
CLEANUP_LOOPS=()
CLEANUP_DIRS=()

register_cleanup_mount() { CLEANUP_MOUNTS+=("$1"); }
register_cleanup_loop() { CLEANUP_LOOPS+=("$1"); }
register_cleanup_dir() { CLEANUP_DIRS+=("$1"); }

cleanup_on_exit() {
  local rc=$?
  set +e
  local i
  for ((i = ${#CLEANUP_MOUNTS[@]} - 1; i >= 0; i--)); do
    umount "${CLEANUP_MOUNTS[$i]}" >/dev/null 2>&1
  done
  for ((i = ${#CLEANUP_LOOPS[@]} - 1; i >= 0; i--)); do
    losetup -d "${CLEANUP_LOOPS[$i]}" >/dev/null 2>&1
  done
  for ((i = ${#CLEANUP_DIRS[@]} - 1; i >= 0; i--)); do
    rm -rf "${CLEANUP_DIRS[$i]}"
  done
  exit "$rc"
}
