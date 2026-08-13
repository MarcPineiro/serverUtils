#!/usr/bin/env bash
# autoinstall-usb/lib/validate.sh
#
# Pure(ish) post-build validation helpers (agent-plan Phase 1: "Add a
# post-build validator"). Every function here operates on an already
# available directory tree (an ESP or PERSIST root) or a standalone file, so
# they can be exercised in Bats against plain fixture directories under
# $BATS_TEST_TMPDIR with no mount, loop device, or root privilege involved.
# `validate-build.sh` is the thin top-level script that mounts the two real
# partitions read-only and calls these functions.
#
# shellcheck shell=bash

# validate_esp_root ESP_ROOT ESP_UUID DATA_UUID
# Verifies the UEFI loader, the project-owned grub.cfg (and that it
# references both real UUIDs), the Tiny Core kernel/initrd, and — when
# present — that every legacy BIOS config's APPEND line carries the
# persistence UUID exactly once (agent-plan: "Verify UEFI loader, BIOS
# loader, kernel, initrd ... Verify referenced UUIDs match the actual
# filesystems").
validate_esp_root() {
  local esp_root="$1" esp_uuid="$2" data_uuid="$3"

  [[ -f "$esp_root/EFI/BOOT/BOOTX64.EFI" ]] || die "validate: missing EFI/BOOT/BOOTX64.EFI"
  [[ -f "$esp_root/EFI/BOOT/grub.cfg" ]] || die "validate: missing EFI/BOOT/grub.cfg"
  grep -q "$esp_uuid" "$esp_root/EFI/BOOT/grub.cfg" || die "validate: grub.cfg does not reference ESP UUID $esp_uuid"
  grep -q "$data_uuid" "$esp_root/EFI/BOOT/grub.cfg" || die "validate: grub.cfg does not reference PERSIST UUID $data_uuid"

  local bi
  bi="$(detect_tc_boot_files "$esp_root")" || die "validate: cannot detect kernel/initrd under $esp_root/boot"
  local kernel="${bi%%|*}" initrd="${bi##*|}"
  [[ -f "$esp_root$kernel" ]] || die "validate: missing kernel $kernel"
  [[ -f "$esp_root$initrd" ]] || die "validate: missing initrd $initrd"

  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*APPEND[[:space:]] ]] || continue
      verify_append_line_once "$line" "$data_uuid"
    done <"$f"
  done < <(find_syslinux_configs "$esp_root")

  echo "$kernel|$initrd"
}

# validate_persist_root PERSIST_ROOT
# Verifies the persistence backup archive, the environment file, the
# (optional) onboot package list, and — when a package manifest was shipped —
# that every cached .tcz still matches its recorded checksum (agent-plan:
# "Verify ... mydata.tgz, package list, cached packages, environment file,
# and bootstrap fallback").
validate_persist_root() {
  local persist_root="$1"

  [[ -f "$persist_root/tce/mydata.tgz" ]] || die "validate: missing tce/mydata.tgz"
  [[ -f "$persist_root/tce/autoprov.env" ]] || die "validate: missing tce/autoprov.env"

  if [[ ! -f "$persist_root/tce/onboot.lst" ]]; then
    echo "[!] WARNING: no tce/onboot.lst on this build (no --pkg-list was used)." >&2
  fi

  shopt -s nullglob
  local cached=( "$persist_root/tce/optional"/*.tcz )
  shopt -u nullglob
  if ((${#cached[@]} > 0)); then
    verify_tcz_dir_against_manifest "$persist_root/tce/optional"
  fi

  validate_bootstrap_fallback_in_archive "$persist_root/tce/mydata.tgz"
}

# validate_bootstrap_fallback_in_archive MYDATA_TGZ
# Extracts MYDATA_TGZ to a throwaway directory and confirms
# opt/bootlocal.sh (the single authoritative entrypoint) and
# opt/autorun/bootstrap.fallback.sh (the bundled offline controller) both
# exist and are executable. Cleans up after itself unconditionally.
validate_bootstrap_fallback_in_archive() {
  local archive="$1"
  local tmp
  tmp="$(mktemp -d)"
  tar -C "$tmp" -xzf "$archive" 2>/dev/null || { rm -rf "$tmp"; die "validate: cannot extract $archive"; }

  local rc=0
  if [[ ! -f "$tmp/opt/bootlocal.sh" || ! -x "$tmp/opt/bootlocal.sh" ]]; then
    echo "ERROR: $archive: missing or non-executable opt/bootlocal.sh" >&2
    rc=1
  fi
  if [[ -f "$tmp/opt/autorun/bootstrap.fallback.sh" ]]; then
    [[ -x "$tmp/opt/autorun/bootstrap.fallback.sh" ]] || { echo "ERROR: $archive: opt/autorun/bootstrap.fallback.sh is not executable" >&2; rc=1; }
    head -c2 "$tmp/opt/autorun/bootstrap.fallback.sh" | grep -q '^#!' || { echo "ERROR: $archive: opt/autorun/bootstrap.fallback.sh has no shell shebang" >&2; rc=1; }
  else
    echo "[!] WARNING: $archive has no opt/autorun/bootstrap.fallback.sh (built with --no-bundle-fallback)." >&2
  fi

  rm -rf "$tmp"
  [[ "$rc" -eq 0 ]] || die "validate: bootstrap-fallback checks failed for $archive"
}

# emit_build_manifest ESP_ROOT PERSIST_ROOT ESP_UUID DATA_UUID KERNEL INITRD
# Prints build-manifest.json to stdout: sha256 of every file the post-build
# validator checked, plus both real filesystem UUIDs and a UTC timestamp
# (agent-plan: "Emit build-manifest.json with hashes"; Completion evidence:
# "build-manifest.json matching the tested USB"). Pure: never writes to disk
# itself, so the caller decides where to save it.
emit_build_manifest() {
  local esp_root="$1" persist_root="$2" esp_uuid="$3" data_uuid="$4" kernel="$5" initrd="$6"

  local uefi_sha grub_sha kernel_sha initrd_sha mydata_sha
  uefi_sha="$(sha256_file "$esp_root/EFI/BOOT/BOOTX64.EFI")"
  grub_sha="$(sha256_file "$esp_root/EFI/BOOT/grub.cfg")"
  kernel_sha="$(sha256_file "$esp_root$kernel")"
  initrd_sha="$(sha256_file "$esp_root$initrd")"
  mydata_sha="$(sha256_file "$persist_root/tce/mydata.tgz")"

  local onboot_json="null"
  if [[ -f "$persist_root/tce/onboot.lst" ]]; then
    onboot_json="{\"path\":\"tce/onboot.lst\",\"sha256\":\"$(sha256_file "$persist_root/tce/onboot.lst")\"}"
  fi

  local packages_json="[]"
  shopt -s nullglob
  local cached=( "$persist_root/tce/optional"/*.tcz )
  shopt -u nullglob
  if ((${#cached[@]} > 0)); then
    local entries="" f name sha
    for f in "${cached[@]}"; do
      name="$(basename "$f")"
      sha="$(sha256_file "$f")"
      [[ -z "$entries" ]] || entries="$entries,"
      entries="$entries{\"name\":\"$name\",\"sha256\":\"$sha\"}"
    done
    packages_json="[$entries]"
  fi

  local fallback_json="null"
  local tmp
  tmp="$(mktemp -d)"
  if tar -C "$tmp" -xzf "$persist_root/tce/mydata.tgz" 2>/dev/null && [[ -f "$tmp/opt/autorun/bootstrap.fallback.sh" ]]; then
    fallback_json="{\"path\":\"opt/autorun/bootstrap.fallback.sh\",\"sha256\":\"$(sha256_file "$tmp/opt/autorun/bootstrap.fallback.sh")\"}"
  fi
  rm -rf "$tmp"

  cat <<EOF
{
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "esp_uuid": "$esp_uuid",
  "persist_uuid": "$data_uuid",
  "uefi_loader": {"path": "EFI/BOOT/BOOTX64.EFI", "sha256": "$uefi_sha"},
  "grub_cfg": {"path": "EFI/BOOT/grub.cfg", "sha256": "$grub_sha"},
  "kernel": {"path": "${kernel#/}", "sha256": "$kernel_sha"},
  "initrd": {"path": "${initrd#/}", "sha256": "$initrd_sha"},
  "mydata_tgz": {"path": "tce/mydata.tgz", "sha256": "$mydata_sha"},
  "onboot_lst": $onboot_json,
  "cached_packages": $packages_json,
  "bootstrap_fallback": $fallback_json
}
EOF
}
