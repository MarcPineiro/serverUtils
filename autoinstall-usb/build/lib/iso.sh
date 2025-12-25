#!/usr/bin/env bash
set -euo pipefail

# Requires: utils.sh

download_iso() {
  local url="$1" out="$2"
  if [[ -f "$out" ]]; then
    log "Base ISO already present: $out"
    return 0
  fi
  log "Downloading Alpine ISO: $url"
  curl -fL "$url" -o "$out"
}

extract_iso() {
  local base_iso="$1" iso_dir="$2"
  rm -rf "$iso_dir"
  mkdir -p "$iso_dir"
  log "Extracting ISO..."
  xorriso -osirrox on -indev "$base_iso" -extract / "$iso_dir" >/dev/null 2>&1
}

build_apkovl() {
  local overlay_dir="$1" out_tar_gz="$2"
  [[ -d "$overlay_dir" ]] || die "Overlay dir not found: $overlay_dir"
  log "Building apkovl from overlay: $overlay_dir"
  tar -C "$overlay_dir" -czf "$out_tar_gz" .
}

embed_bootstrap_into_apkovl() {
  local apkovl="$1" workdir="$2" github_url="$3"
  local embed_path="$workdir/bootstrap.embedded.sh"
  local tmp="$workdir/ovl-tmp"

  log "Attempting build-time bootstrap download to embed..."
  if curl -fsSL "$github_url" -o "$embed_path"; then
    log "Bootstrap downloaded OK; embedding into apkovl"
    rm -rf "$tmp"
    mkdir -p "$tmp"
    tar -C "$tmp" -xzf "$apkovl"
    mkdir -p "$tmp/opt/autorun"
    cp "$embed_path" "$tmp/opt/autorun/bootstrap.embedded.sh"
    chmod +x "$tmp/opt/autorun/bootstrap.embedded.sh" || true
    tar -C "$tmp" -czf "$apkovl" .
  else
    warn "Could not download bootstrap at build-time; runtime will use fallback."
  fi
}

install_apkovl_into_iso() {
  local apkovl="$1" iso_dir="$2" name="$3"
  log "Installing apkovl into ISO root: $name"
  cp "$apkovl" "$iso_dir/$name"
}

repack_iso_replay_boot() {
  local base_iso="$1"
  local iso_dir="$2"
  local out_iso="$3"

  log "Repacking ISO (explicit boot config) to: $out_iso"

  xorriso -as mkisofs \
    -o "$out_iso" \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "ALPINE_AUTOPROV" \
    \
    -eltorito-boot boot/syslinux/isolinux.bin \
      -eltorito-catalog boot/syslinux/boot.cat \
      -no-emul-boot \
      -boot-load-size 4 \
      -boot-info-table \
    \
    -eltorito-alt-boot \
      -e efi/boot/bootx64.efi \
      -no-emul-boot \
    \
    -isohybrid-mbr "$iso_dir/boot/syslinux/isohdpfx.bin" \
    -isohybrid-gpt-basdat \
    \
    "$iso_dir"
}

