#!/usr/bin/env bash
set -euo pipefail

# Requires: utils.sh

fetch_offline_apks_if_possible() {
  local pkgs_file="$1"
  local repos_file="$2"
  local iso_apks_dir="$3"

  if ! have apk; then
    warn "apk not found; skipping offline APK fetch."
    return 0
  fi

  [[ -f "$pkgs_file" ]] || die "Packages file not found: $pkgs_file"
  [[ -f "$repos_file" ]] || die "Repositories file not found: $repos_file"

  # IMPORTANT:
  # Never fetch directly into a VirtualBox shared folder (/work).
  # Use VM-local storage first, then copy results.
  local TMP_APKS="/tmp/apks"
  rm -rf "$TMP_APKS"
  mkdir -p "$TMP_APKS" "$iso_apks_dir"

  log "Preparing APK indexes for offline fetch..."
  apk update --repositories-file "$repos_file" >/dev/null

  log "Fetching offline APKs into VM-local dir: $TMP_APKS"

  local ARCH
  ARCH="$(apk --print-arch)"

  while IFS= read -r pkg; do
    pkg="$(echo "$pkg" | sed 's/#.*$//' | xargs || true)"
    [[ -n "$pkg" ]] || continue

    log "  - apk fetch: $pkg"

    if ! apk fetch \
      --arch "$ARCH" \
      --repositories-file "$repos_file" \
      --recursive \
      --output "$TMP_APKS" \
      "$pkg"; then
      warn "apk fetch failed for: $pkg"
    fi
  done < "$pkgs_file"

  log "Copying APKs into ISO tree: $iso_apks_dir"
  cp -a "$TMP_APKS/." "$iso_apks_dir/"
}
