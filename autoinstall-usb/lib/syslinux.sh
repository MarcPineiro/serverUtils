#!/usr/bin/env bash
# autoinstall-usb/lib/syslinux.sh
#
# Idempotent legacy BIOS (syslinux/isolinux) kernel-argument patching.
# "Idempotent" here means: running the patch any number of times on the same
# file produces byte-identical output after the first pass, and each
# persistence kernel argument (tce=, backup=, waitusb=) appears exactly once
# per APPEND line, referencing the exact persistent-partition UUID.
#
# shellcheck shell=bash

# strip_karg LINE KEY
# Removes any existing KEY=VALUE token (VALUE has no embedded spaces),
# regardless of whether VALUE was a previous UUID= or LABEL= form.
strip_karg() {
  local line="$1" key="$2"
  sed -E "s/(^|[[:space:]])${key}=[^[:space:]]+/\\1/g" <<<"$line"
}

# patch_append_line LINE DATA_UUID
# Returns LINE with tce=/backup=/waitusb= kargs removed and re-added exactly
# once each, pointing at DATA_UUID. Safe to call repeatedly.
patch_append_line() {
  local line="$1" uuid="$2"
  local out="$line"
  out="$(strip_karg "$out" "tce")"
  out="$(strip_karg "$out" "backup")"
  out="$(strip_karg "$out" "waitusb")"
  out="$(tr -s '[:space:]' ' ' <<<"$out")"
  out="$(sed -E 's/[[:space:]]+$//' <<<"$out")"
  printf '%s waitusb=20:UUID=%s tce=UUID=%s backup=UUID=%s' "$out" "$uuid" "$uuid" "$uuid"
}

# verify_append_line_once LINE DATA_UUID
# Dies unless each of tce=/backup=/waitusb= referencing DATA_UUID appears
# exactly once in LINE (agent-plan: "Verify the persistence UUID occurs
# exactly once per entry").
verify_append_line_once() {
  local line="$1" uuid="$2" key pattern count
  for key in tce backup waitusb; do
    if [[ "$key" == "waitusb" ]]; then
      pattern="waitusb=20:UUID=${uuid}"
    else
      pattern="${key}=UUID=${uuid}"
    fi
    count="$(grep -o "$pattern" <<<"$line" | wc -l | tr -d '[:space:]')"
    [[ "$count" -eq 1 ]] || die "syslinux patch: '${pattern}' appears ${count} time(s) (expected 1) in: $line"
  done
}

# find_syslinux_configs ESP_ROOT
# Prints candidate syslinux/isolinux config file paths under ESP_ROOT, one
# per line (none if none exist -- legacy BIOS support is optional per ISO).
find_syslinux_configs() {
  local esp_root="$1"
  find "$esp_root" \( -iname 'isolinux.cfg' -o -iname 'syslinux.cfg' -o -iname 'extlinux.conf' \) 2>/dev/null
}

# patch_syslinux_file FILE DATA_UUID
# Rewrites every APPEND line in FILE in place (idempotent) and verifies the
# result. Non-APPEND lines are left untouched.
patch_syslinux_file() {
  local file="$1" uuid="$2"
  local tmp
  tmp="$(mktemp)"
  local changed="0"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*APPEND[[:space:]] ]]; then
      local prefix="${line%%APPEND*}APPEND"
      local rest="${line#*APPEND}"
      rest="$(sed -E 's/^[[:space:]]+//' <<<"$rest")"
      local patched
      patched="$(patch_append_line "$rest" "$uuid")"
      verify_append_line_once "$patched" "$uuid"
      printf '%s %s\n' "$prefix" "$patched" >>"$tmp"
      changed="1"
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$file"
  if [[ "$changed" == "1" ]]; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
  fi
}

# patch_syslinux_configs ESP_ROOT DATA_UUID
# Patches every discovered syslinux/isolinux config under ESP_ROOT. A no-op
# (not an error) when the ISO ships no legacy BIOS loader.
patch_syslinux_configs() {
  local esp_root="$1" uuid="$2"
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    echo "[+] Patching legacy BIOS config: ${f#"$esp_root"/}"
    patch_syslinux_file "$f" "$uuid"
  done < <(find_syslinux_configs "$esp_root")
}
