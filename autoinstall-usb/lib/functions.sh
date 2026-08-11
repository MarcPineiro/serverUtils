#!/usr/bin/env bash
# autoinstall-usb/lib/functions.sh
#
# Pure/testable helper functions for build-tinycore-usb.sh, split out so
# tests/unit/*.bats can `source` this file directly without triggering the
# main script's CLI parsing, dependency checks, or `die`-on-exit behaviour.
#
# Every function here is safe to call in isolation given only its explicit
# arguments (plus, where noted, a mockable external command such as lsblk).
# None of them format, partition, or otherwise write to a real block device.

die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
log() { echo "$(date -Iseconds) [+] $*"; }
warn() { echo "$(date -Iseconds) [!] $*" >&2; }

# partition_path DISK NUM
# Prints the partition device path for partition number NUM of whole-disk
# DISK, handling the naming families that require a "p" separator (nvme*nN,
# mmcblkN, loopN) versus those that concatenate the number directly (sdX,
# vdX, hdX, xvdX, ...).
partition_path() {
  local disk="$1" num="$2"
  local base
  base="$(basename "$disk")"
  case "$base" in
    nvme*n[0-9]*|mmcblk*|loop*)
      echo "${disk}p${num}"
      ;;
    *)
      echo "${disk}${num}"
      ;;
  esac
}

# require_whole_disk DEV
# Verifies DEV is a block device whose lsblk TYPE is exactly "disk" (never a
# partition, loop-partition, or other node), regardless of naming
# convention. Replaces a previous fragile "--dev must not end in a digit"
# regex, which incorrectly rejected whole nvme/mmcblk disks (whose whole-disk
# names themselves end in a digit, e.g. /dev/nvme0n1).
require_whole_disk() {
  local dev="$1"
  [[ -b "$dev" ]] || die "--dev must be an existing block device: $dev"
  have lsblk || die "Missing lsblk (util-linux)"
  local t
  t="$(lsblk -ndo TYPE "$dev" 2>/dev/null || true)"
  [[ "$t" == "disk" ]] || die "--dev must be a whole disk (lsblk TYPE=disk), got TYPE='${t:-unknown}' for $dev"
}

# print_disk_info DEV
# Prints model, serial, size, transport, and current mounts before erasure.
print_disk_info() {
  local dev="$1"
  echo "Target device: $dev"
  lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,RM,RO,MOUNTPOINT "$dev" 2>/dev/null || true
  local mounts
  mounts="$(lsblk -ln -o NAME,MOUNTPOINT "$dev" 2>/dev/null | awk '$2 != "" {print "  /dev/"$1" -> "$2}')"
  if [[ -n "$mounts" ]]; then
    echo "Currently mounted:"
    echo "$mounts"
  else
    echo "Currently mounted: (nothing)"
  fi
}

# detect_tc_boot_files ESP_ROOT
# Detects the TinyCore kernel/initrd filenames inside a mounted (or fixture)
# ESP tree. Prints "KERNEL|INITRD" (paths relative to ESP_ROOT, leading "/")
# on success; returns nonzero if either is missing.
detect_tc_boot_files() {
  local esp_root="$1"
  local k=""
  local i=""

  [[ -f "$esp_root/boot/vmlinuz64" ]] && k="/boot/vmlinuz64"
  [[ -z "$k" && -f "$esp_root/boot/vmlinuz" ]] && k="/boot/vmlinuz"

  if [[ -z "$k" ]]; then
    local found
    found="$(find "$esp_root/boot" -maxdepth 1 -type f -name 'vmlinuz*' 2>/dev/null | head -n1 || true)"
    [[ -n "$found" ]] && k="/boot/$(basename "$found")"
  fi

  for cand in corepure64.gz coreplus.gz core.gz tinycore.gz; do
    if [[ -f "$esp_root/boot/$cand" ]]; then
      i="/boot/$cand"
      break
    fi
  done
  if [[ -z "$i" ]]; then
    local foundi
    foundi="$(find "$esp_root/boot" -maxdepth 1 -type f -name '*.gz' 2>/dev/null | head -n1 || true)"
    [[ -n "$foundi" ]] && i="/boot/$(basename "$foundi")"
  fi

  [[ -n "$k" && -n "$i" ]] || return 1
  echo "$k|$i"
}

# GPT protective-MBR boot code shipped by syslinux-common, needed to hand
# control to the ESP's installed extlinux VBR on legacy BIOS firmware. See
# https://wiki.syslinux.org/wiki/index.php?title=Install#UEFI and
# doc/gpt.txt in the syslinux source for the underlying protocol.
GPTMBR_CANDIDATES=(
  /usr/lib/syslinux/mbr/gptmbr.bin
  /usr/lib/EXTLINUX/gptmbr.bin
  /usr/share/syslinux/gptmbr.bin
  /usr/lib/syslinux/gptmbr.bin
)

find_gptmbr_bin() {
  local c
  for c in "${GPTMBR_CANDIDATES[@]}"; do
    [[ -f "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

# patch_bootconfigs_add_karg ESP_ROOT KARG
# Idempotently appends KARG to every syslinux/isolinux "append" line found
# under ESP_ROOT (e.g. boot/isolinux/isolinux.cfg copied from the source
# ISO). Safe to call repeatedly for the same KARG: does not duplicate it if
# already present, and refuses (dies) if KARG already appears more than once
# on a given append line, since that would indicate pre-existing corruption
# rather than something safe to silently "fix".
patch_bootconfigs_add_karg() {
  local esp_root="$1" karg="$2"
  local f found=0
  while IFS= read -r -d '' f; do
    found=1
    local tmp="$f.tmp.$$"
    if ! awk -v karg="$karg" '
      BEGIN { IGNORECASE = 1 }
      /^[[:space:]]*append[[:space:]]/ {
        n = gsub(karg, karg)
        if (n == 0) {
          sub(/[[:space:]]*$/, "")
          $0 = $0 " " karg
          n = 1
        }
        if (n > 1) {
          print "DUPLICATE_KARG " karg " in " FILENAME > "/dev/stderr"
          bad = 1
        }
      }
      { print }
      END { if (bad) exit 1 }
    ' "$f" > "$tmp"; then
      rm -f "$tmp"
      die "Refusing to patch $f: kernel arg '$karg' already appears more than once on an append line"
    fi
    mv "$tmp" "$f"
  done < <(find "$esp_root" -type f -iname '*.cfg' -path '*isolinux*' -print0)
  [[ "$found" -eq 1 ]] || warn "No isolinux/syslinux .cfg found under $esp_root (skipping legacy BIOS karg patch for: $karg)"
}

# generate_extlinux_conf ESP_ROOT DATA_UUID
# extlinux reads "extlinux.conf" at the root of its installation directory
# (not isolinux.cfg, which isolinux itself uses). Generated with the same
# kernel/initrd/persistence args as the UEFI GRUB entry for consistency.
generate_extlinux_conf() {
  local esp_root="$1" data_uuid="$2"
  local bi
  bi="$(detect_tc_boot_files "$esp_root" || true)"
  [[ -n "$bi" ]] || die "Cannot detect TinyCore boot files for extlinux.conf"
  local KERNEL="${bi%%|*}"
  local INITRD="${bi##*|}"
  local PERSIST_ARGS="waitusb=20:UUID=${data_uuid} tc-config tce=UUID=${data_uuid} backup=UUID=${data_uuid}"

  cat > "$esp_root/extlinux.conf" <<EOF
DEFAULT tinycore
TIMEOUT 50
PROMPT 1

LABEL tinycore
  KERNEL ${KERNEL}
  INITRD ${INITRD}
  APPEND quiet ${PERSIST_ARGS} loglevel=7

LABEL tinycore-diagnostic
  KERNEL ${KERNEL}
  INITRD ${INITRD}
  APPEND ${PERSIST_ARGS} loglevel=8 debug
EOF
}

# validate_build_tree ESP_ROOT PER_ROOT ESP_UUID DATA_UUID [PATCH_BOOTCODES]
# Pure filesystem checks against already-mounted (or fixture) directory
# trees. Never mounts/unmounts/formats anything itself, so it is unit
# testable against plain fixture directories without root or real devices.
# PATCH_BOOTCODES defaults to "1" (legacy BIOS files expected present).
validate_build_tree() {
  local esp_root="$1" per_root="$2" esp_uuid="$3" data_uuid="$4"
  local patch_bootcodes="${5:-1}"
  local errors=0

  _vbt_req() {
    [[ -e "$1" ]] || { echo "[validate] MISSING: $1" >&2; errors=$((errors + 1)); }
  }

  _vbt_req "$esp_root/EFI/BOOT/BOOTX64.EFI"
  _vbt_req "$esp_root/EFI/BOOT/grub.cfg"

  local bi
  if bi="$(detect_tc_boot_files "$esp_root" 2>/dev/null)"; then
    _vbt_req "$esp_root/${bi%%|*}"
    _vbt_req "$esp_root/${bi##*|}"
  else
    echo "[validate] MISSING: kernel/initrd under $esp_root/boot" >&2
    errors=$((errors + 1))
  fi

  if [[ "$patch_bootcodes" == "1" ]]; then
    _vbt_req "$esp_root/extlinux.conf"
    _vbt_req "$esp_root/ldlinux.sys"
  fi

  _vbt_req "$per_root/tce/mydata.tgz"
  _vbt_req "$per_root/tce/onboot.lst"
  _vbt_req "$per_root/tce/autoprov.env"
  _vbt_req "$per_root/tce/bootstrap.fallback.sh"

  if [[ -f "$esp_root/EFI/BOOT/grub.cfg" ]]; then
    grep -qF -- "$esp_uuid" "$esp_root/EFI/BOOT/grub.cfg" || { echo "[validate] grub.cfg does not reference expected ESP UUID $esp_uuid" >&2; errors=$((errors + 1)); }
    grep -qF -- "$data_uuid" "$esp_root/EFI/BOOT/grub.cfg" || { echo "[validate] grub.cfg does not reference expected data UUID $data_uuid" >&2; errors=$((errors + 1)); }
  fi

  echo "[validate] $errors error(s)"
  [[ "$errors" -eq 0 ]]
}

# emit_build_manifest OUT_FILE ESP_ROOT PER_ROOT ESP_UUID DATA_UUID
# Writes build-manifest.json with sha256 hashes of the key generated/staged
# files plus the two persistence UUIDs. Requires jq (already a hard
# dependency of build-tinycore-usb.sh).
emit_build_manifest() {
  local out_file="$1" esp_root="$2" per_root="$3" esp_uuid="$4" data_uuid="$5"
  have jq || die "jq required to emit build-manifest.json"
  have sha256sum || die "sha256sum required to emit build-manifest.json"

  local files_json="{}"
  local f rel h
  while IFS= read -r -d '' f; do
    rel="${f#"$esp_root"/}"
    h="$(sha256sum "$f" | awk '{print $1}')"
    files_json="$(jq --arg k "esp/$rel" --arg v "$h" '. + {($k): $v}' <<<"$files_json")"
  done < <(find "$esp_root/EFI" "$esp_root/boot" -type f -print0 2>/dev/null)

  if [[ -f "$esp_root/extlinux.conf" ]]; then
    h="$(sha256sum "$esp_root/extlinux.conf" | awk '{print $1}')"
    files_json="$(jq --arg k "esp/extlinux.conf" --arg v "$h" '. + {($k): $v}' <<<"$files_json")"
  fi

  while IFS= read -r -d '' f; do
    rel="${f#"$per_root"/}"
    h="$(sha256sum "$f" | awk '{print $1}')"
    files_json="$(jq --arg k "persist/$rel" --arg v "$h" '. + {($k): $v}' <<<"$files_json")"
  done < <(find "$per_root/tce" -maxdepth 1 -type f -print0 2>/dev/null)

  jq -n \
    --arg generated "$(date -Iseconds)" \
    --arg esp_uuid "$esp_uuid" \
    --arg data_uuid "$data_uuid" \
    --argjson files "$files_json" \
    '{generated: $generated, esp_uuid: $esp_uuid, data_uuid: $data_uuid, files: $files}' \
    > "$out_file"
}

# verify_tcz_checksums TCZ_DIR MANIFEST
# Verifies every *.tcz file found in TCZ_DIR has a matching sha256 entry in
# the pinned MANIFEST (see tcz/generate-tcz-manifest.sh). Dies loudly on any
# mismatch or missing entry rather than silently copying an unpinned or
# tampered package onto the USB.
verify_tcz_checksums() {
  local tcz_dir="$1" manifest="$2"
  [[ -f "$manifest" ]] || die "TCZ manifest not found: $manifest (see tcz/generate-tcz-manifest.sh)"
  have jq || die "Missing jq"
  have sha256sum || die "Missing sha256sum"
  local f base expected actual
  shopt -s nullglob
  for f in "$tcz_dir"/*.tcz; do
    base="$(basename "$f")"
    expected="$(jq -r --arg n "$base" '.extensions[$n].sha256 // empty' "$manifest")"
    if [[ -z "$expected" ]]; then
      die "No pinned sha256 for $base in $manifest; run tcz/generate-tcz-manifest.sh to (re)pin it before building"
    fi
    actual="$(sha256sum "$f" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || die "Checksum mismatch for $base: expected $expected got $actual"
  done
  shopt -u nullglob
}
