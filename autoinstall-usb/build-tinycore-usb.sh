#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/functions.sh
source "$SCRIPT_DIR/lib/functions.sh"

usage() {
  cat <<'EOF'
sudo ./build-tinycore-usb.sh \
  --iso ./Core-current.iso \
  --dev /dev/sdX \
  --overlay ./overlay \
  --tcz-dir ./tcz \
  --pkg-list ./tcz/onboot.lst \
  --vm-test --vm-src /dev/sdX

  ./build-tinycore-usb.sh \
  --iso ./Core-current.iso \
  --image /tmp/tinycore-test.img --image-size 2G \
  --overlay ./overlay

Options:
  --iso PATH
  --dev /dev/sdX              (whole disk only; rejected if lsblk TYPE != disk)
  --image PATH                (build into a raw image file instead of --dev)
  --image-size SIZE           (required with --image, e.g. 2G; passed to truncate -s)
  --overlay DIR              (ej: ./overlay; contiene opt/bootlocal.sh, opt/autorun/*)
  --tcz-dir DIR              (opcional: *.tcz, *.tcz.dep, *.md5.txt)
  --pkg-list FILE            (opcional: onboot.lst)
  --tcz-manifest FILE        (default: ./tcz/tcz-manifest.json; verified before copying from --tcz-dir)
  --label-esp LABEL          (default: TINYBOOT)
  --label-persist LABEL      (default: TINYDATA)
  --esp-mib N                (default: 1024)
  --no-patch-bootcodes       (skip legacy BIOS: no extlinux/gptmbr.bin install, no isolinux append patch)
  -y                         (no interactive confirmation; still requires disk identity to be printed/logged)

UEFI:
  A project-owned GRUB UEFI loader (EFI/BOOT/BOOTX64.EFI + grub.cfg) is ALWAYS
  generated with grub-mkstandalone, even if the source ISO ships its own
  EFI/BOOT/BOOTX64.EFI (which is overwritten). Uses search --fs-uuid with the
  real UUID of the ESP.

Legacy BIOS (unless --no-patch-bootcodes):
  Installs extlinux on the ESP, writes syslinux's gptmbr.bin to the disk's
  protective MBR (first 440 bytes only; GPT partition table untouched), and
  marks the ESP partition "legacy_boot" so BIOS firmware can chain to it.
  Requires the `extlinux` binary (Debian/Ubuntu: apt install syslinux
  syslinux-common extlinux) and a gptmbr.bin from syslinux-common.

VM:
  --vm-test
  --vm-only
  --vm-src PATH              (/dev/sdX o imagen raw)
  --vm-graphics spice|none   (default: spice)
  --vm-ram MB                (default: 768)
  --vm-name NAME
  --vm-disk-gb N             (default: 2)
EOF
}

# confirm_destructive DEV
# Requires the exact target serial as the confirmation token. Falls back to
# requiring the device path when the device reports no SERIAL (common for
# some virtio/loop/test devices), since a nonexistent serial cannot be
# demanded, but the safety intent (explicit, unambiguous operator
# confirmation) is preserved.
confirm_destructive() {
  local dev="$1"
  local serial token label
  serial="$(lsblk -ndo SERIAL "$dev" 2>/dev/null | head -n1 | xargs 2>/dev/null || true)"
  if [[ -n "$serial" ]]; then
    token="$serial"
    label="disk serial"
  else
    token="$dev"
    label="device path (no hardware SERIAL reported by lsblk)"
    warn "Device reports no SERIAL; falling back to requiring the exact device path as the confirmation token."
  fi

  echo "!!! ABOUT TO ERASE: $dev !!!"
  print_disk_info "$dev"

  if [[ "$ASSUME_YES" == "1" ]]; then
    warn "-y given: skipping interactive confirmation (would have required ${label}=${token})"
    return 0
  fi

  local ans
  read -r -p "Type the exact ${label} to continue [${token}]: " ans
  [[ "$ans" == "$token" ]] || die "Confirmation token mismatch. Aborted, no changes made."
}

# create_image_and_attach PATH SIZE
# Creates a sparse raw image file of SIZE (e.g. 2G) and attaches it via a loop
# device with partition scanning enabled, for safe --image builds that never
# touch a real block device. Registers the loop device in ATTACHED_LOOPDEV so
# the EXIT trap detaches it.
create_image_and_attach() {
  local path="$1" size="$2"
  [[ ! -e "$path" ]] || die "--image path already exists (refusing to overwrite): $path"
  have truncate || die "Missing truncate (coreutils) for --image mode"
  have losetup || die "Missing losetup (util-linux) for --image mode"
  truncate -s "$size" "$path" || die "Failed to create image file: $path ($size)"
  local loopdev
  loopdev="$(losetup --find --show --partscan "$path")" || die "losetup failed for $path"
  ATTACHED_LOOPDEV="$loopdev"
  echo "$loopdev"
}


run_as_user() {
  # Ejecuta comandos como el usuario que invocó sudo (si aplica).
  # Uso: run_as_user "comando..."
  if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    sudo -u "${SUDO_USER}" -H bash -lc "$*"
  else
    bash -lc "$*"
  fi
}

ensure_tcz_offline_with_vagrant_if_needed() {
  # Si hay --pkg-list pero no hay .tcz disponibles en --tcz-dir, usa la VM (Vagrant)
  # para descargarlos con tce-load y deja el cache en ./tcz-cache.
  #
  # Efecto: actualiza TCZ_DIR para que apunte a ./tcz-cache/tce/optional (donde quedan los .tcz).

  [[ -n "${PKG_LIST:-}" ]] || return 0  # nada que hacer si no hay pkg-list

  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  local fetch_script="$root/tcz/fetch-tcz.sh"
  local cache_root="$root/tcz-cache"
  local cache_onboot="$cache_root/onboot.lst"
  local cache_optional="$cache_root/tce/optional"

  # ¿Ya hay .tcz disponibles? entonces no hacemos nada.
  local need_fetch="1"
  if [[ -n "${TCZ_DIR:-}" && -d "$TCZ_DIR" ]]; then
    shopt -s nullglob
    local existing=( "$TCZ_DIR"/*.tcz )
    shopt -u nullglob
    if ((${#existing[@]} > 0)); then
      need_fetch="0"
    fi
  fi

  # Si TCZ_DIR está vacío o no contiene .tcz, descargamos con Vagrant
  if [[ "$need_fetch" == "1" ]]; then
    [[ -f "$fetch_script" ]] || die "No existe $fetch_script (necesario para descargar TCZ con Vagrant)"
    [[ -f "$PKG_LIST" ]] || die "Invalid --pkg-list: $PKG_LIST"

    mkdir -p "$cache_optional"
    cp -f "$PKG_LIST" "$cache_onboot"

    echo "[+] No hay .tcz offline en --tcz-dir. Descargando con Vagrant/TinyCore (tce-load)..."
    run_as_user "cd '$root' && '$fetch_script'" --onboot $root/tcz/onboot.lst --out ./tcz-cache/tce --tc 16 --arch x86_64

    shopt -s nullglob
    local downloaded=( "$cache_optional"/*.tcz )
    shopt -u nullglob
    ((${#downloaded[@]} > 0)) || die "Vagrant terminó pero el cache sigue vacío: $cache_optional"

    # IMPORTANTE: apuntamos TCZ_DIR al directorio que contiene .tcz DIRECTAMENTE
    TCZ_DIR="$cache_optional"
    echo "[+] Usando cache offline: TCZ_DIR=$TCZ_DIR"
  fi
}

ISO=""
DEV=""
IMAGE_PATH=""
IMAGE_SIZE=""
OVERLAY_DIR="./overlay"
BOOTSTRAP_FILES_DIR="./bootstrap"
TCZ_DIR=""
PKG_LIST=""
TCZ_MANIFEST="./tcz/tcz-manifest.json"
LABEL_ESP="TINYBOOT"
LABEL_PERSIST="TINYDATA"
ESP_MIB="1024"
PATCH_BOOTCODES="1"
ASSUME_YES="0"

VM_TEST="0"
VM_ONLY="0"
VM_SRC=""
VM_GRAPHICS="spice"
VM_RAM="768"
VM_NAME=""
VM_DISK_GB="2"

# Populated during build and cleaned up by the EXIT trap below.
WORK_DIR=""
ATTACHED_LOOPDEV=""
ISO_MNT=""
ESP_MNT=""
PER_MNT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso) ISO="$2"; shift 2;;
    --dev) DEV="$2"; shift 2;;
    --image) IMAGE_PATH="$2"; shift 2;;
    --image-size) IMAGE_SIZE="$2"; shift 2;;
    --overlay) OVERLAY_DIR="$2"; shift 2;;
    --tcz-dir) TCZ_DIR="$2"; shift 2;;
    --pkg-list) PKG_LIST="$2"; shift 2;;
    --tcz-manifest) TCZ_MANIFEST="$2"; shift 2;;
    --label-esp) LABEL_ESP="$2"; shift 2;;
    --label-persist) LABEL_PERSIST="$2"; shift 2;;
    --esp-mib) ESP_MIB="$2"; shift 2;;
    --no-patch-bootcodes) PATCH_BOOTCODES="0"; shift 1;;
    -y) ASSUME_YES="1"; shift 1;;

    --vm-test) VM_TEST="1"; shift 1;;
    --vm-only) VM_ONLY="1"; shift 1;;
    --vm-src) VM_SRC="$2"; shift 2;;
    --vm-graphics) VM_GRAPHICS="$2"; shift 2;;
    --vm-ram) VM_RAM="$2"; shift 2;;
    --vm-name) VM_NAME="$2"; shift 2;;
    --vm-disk-gb) VM_DISK_GB="$2"; shift 2;;

    -h|--help) usage; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

have parted || die "Missing parted"
have wipefs || die "Missing wipefs"
have mkfs.vfat || die "Missing mkfs.vfat (dosfstools)"
have mkfs.ext4 || die "Missing mkfs.ext4 (e2fsprogs)"
have mount || die "Missing mount"
have umount || die "Missing umount"
have blkid || die "Missing blkid (util-linux)"
have lsblk || die "Missing lsblk (util-linux)"
have sha256sum || die "Missing sha256sum (coreutils)"
have jq || die "Missing jq"

# Single authoritative cleanup path: unmounts any mountpoints this run
# created and detaches any loop device attached for --image mode, regardless
# of whether the script exits normally, via `die`, or via a `set -e` failure.
cleanup() {
  local rc=$?
  set +e
  local m
  for m in "$PER_MNT" "$ESP_MNT" "$ISO_MNT"; do
    [[ -n "$m" ]] && mountpoint -q "$m" 2>/dev/null && umount "$m" >/dev/null 2>&1
  done
  if [[ -n "$ATTACHED_LOOPDEV" ]]; then
    losetup -d "$ATTACHED_LOOPDEV" >/dev/null 2>&1
  fi
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
  exit "$rc"
}
trap cleanup EXIT

if [[ "$VM_ONLY" != "1" ]]; then
  [[ -n "$ISO" && -f "$ISO" ]] || die "Missing/invalid --iso"
  if [[ -n "$IMAGE_PATH" ]]; then
    [[ -z "$DEV" ]] || die "--image and --dev are mutually exclusive"
    [[ -n "$IMAGE_SIZE" ]] || die "--image requires --image-size"
  else
    [[ -n "$DEV" ]] || die "Missing/invalid --dev (or use --image PATH --image-size SIZE)"
    require_whole_disk "$DEV"
  fi
  [[ -d "$OVERLAY_DIR" ]] || die "Invalid --overlay dir: $OVERLAY_DIR"
fi
if [[ -n "$TCZ_DIR" ]]; then [[ -d "$TCZ_DIR" ]] || die "Invalid --tcz-dir: $TCZ_DIR"; fi
if [[ -n "$PKG_LIST" ]]; then [[ -f "$PKG_LIST" ]] || die "Invalid --pkg-list: $PKG_LIST"; fi

ensure_tcz_offline_with_vagrant_if_needed

if [[ "$VM_TEST" == "1" || "$VM_ONLY" == "1" ]]; then
  [[ -n "$VM_SRC" ]] || die "--vm-src is required for VM"
  [[ -b "$VM_SRC" || -f "$VM_SRC" ]] || die "--vm-src must be block device or image file"
fi

unmount_dev_tree() {
  local dev="$1"
  lsblk -ln -o NAME,MOUNTPOINT "$dev" | awk '$2 != "" {print $1}' | while read -r p; do
    umount "/dev/$p" || true
  done
}

# Generate BOOTX64.EFI and grub.cfg. Uses ESP UUID for search. ALWAYS called
# (even when the source ISO already ships its own EFI/BOOT/BOOTX64.EFI, which
# gets overwritten) so the resulting loader is always project-owned and
# always references this specific build's persistence UUIDs.
generate_grub_uefi_loader() {
  local esp_root="$1"
  local esp_uuid="$2"     # UUID of ESP partition (vfat)
  local data_uuid="$3"     # UUID of PERSIST partition

  have grub-mkstandalone || die "grub-mkstandalone not found. Install: sudo apt install grub-efi-amd64-bin"

  if [[ -f "$esp_root/EFI/BOOT/BOOTX64.EFI" ]]; then
    log "ISO shipped its own EFI/BOOT/BOOTX64.EFI; overwriting with a project-owned GRUB loader."
  fi

  local bi
  bi="$(detect_tc_boot_files "$esp_root" || true)"
  [[ -n "$bi" ]] || die "Cannot detect TinyCore boot files under /boot (need vmlinuz* and *.gz)"
  local KERNEL="${bi%%|*}"
  local INITRD="${bi##*|}"
  local PERSIST_ARGS="waitusb=20:UUID=${data_uuid} tc-config tce=UUID=${data_uuid} backup=UUID=${data_uuid}"

  mkdir -p "$esp_root/EFI/BOOT"

  # IMPORTANT: put search inside menuentry so root is correct when loading kernel/initrd
  cat > "$esp_root/EFI/BOOT/grub.cfg" <<EOF
set timeout=5
set default=0

menuentry "TinyCore supervisor (UEFI)" {
  insmod part_gpt
  insmod fat
  search --no-floppy --fs-uuid --set=root ${esp_uuid}
  echo "Loading TinyCore..."
  linux  ${KERNEL} quiet ${PERSIST_ARGS} loglevel=7
  initrd ${INITRD}
}

menuentry "TinyCore supervisor (UEFI) - diagnostic / verbose" {
  insmod part_gpt
  insmod fat
  search --no-floppy --fs-uuid --set=root ${esp_uuid}
  echo "Loading TinyCore (diagnostic)..."
  linux  ${KERNEL} ${PERSIST_ARGS} loglevel=8 debug
  initrd ${INITRD}
}

# Reserved for Phase 3 ("Installation mechanism"): an Ubuntu autoinstall
# kexec entry, once the Ubuntu Server casper/vmlinuz + casper/initrd are
# staged on this ESP and a NoCloud seed is available. Uncomment and complete
# in Phase 3; do not enable a half-finished entry here.
#
# menuentry "Ubuntu autoinstall (kexec)" {
#   insmod part_gpt
#   insmod fat
#   search --no-floppy --fs-uuid --set=root ${esp_uuid}
#   linux  /ubuntu/casper/vmlinuz autoinstall ds=nocloud;s=/ubuntu/nocloud/ ---
#   initrd /ubuntu/casper/initrd
# }
EOF

  log "Generating EFI/BOOT/BOOTX64.EFI with grub-mkstandalone (project-owned, always regenerated)..."
  grub-mkstandalone \
    -O x86_64-efi \
    -o "$esp_root/EFI/BOOT/BOOTX64.EFI" \
    "boot/grub/grub.cfg=$esp_root/EFI/BOOT/grub.cfg" >/dev/null

  [[ -f "$esp_root/EFI/BOOT/BOOTX64.EFI" ]] || die "Failed to generate BOOTX64.EFI"
}

# install_legacy_bios_boot DEV ESP_PARTNUM ESP_MNT DATA_UUID
# Makes the disk bootable on legacy BIOS firmware from a GPT layout:
#   1. extlinux --install on the mounted (FAT32) ESP: writes ldlinux.sys and
#      patches that partition's VBR.
#   2. Writes gptmbr.bin to the disk's protective MBR (first 440 bytes only;
#      the GPT/PMBR partition table entries at/after offset 446 are never
#      touched).
#   3. Flags the ESP partition "legacy_boot" so gptmbr.bin's handover
#      protocol finds it.
# Requires extlinux (Debian/Ubuntu: apt install syslinux syslinux-common
# extlinux). Use --no-patch-bootcodes to build a UEFI-only USB instead.
# partition_path, find_gptmbr_bin, generate_extlinux_conf, and
# patch_bootconfigs_add_karg are all sourced from lib/functions.sh.
install_legacy_bios_boot() {
  local dev="$1" esp_partnum="$2" esp_mnt="$3" data_uuid="$4"

  have extlinux || die "Missing extlinux (Debian/Ubuntu: apt install syslinux syslinux-common extlinux) required for legacy BIOS support. Pass --no-patch-bootcodes to build a UEFI-only USB."
  local gptmbr
  gptmbr="$(find_gptmbr_bin)" || die "Cannot find gptmbr.bin (checked: ${GPTMBR_CANDIDATES[*]}). Install syslinux-common, or pass --no-patch-bootcodes."

  generate_extlinux_conf "$esp_mnt" "$data_uuid"

  log "Installing extlinux bootloader on ESP (legacy BIOS)..."
  extlinux --install "$esp_mnt" || die "extlinux --install failed on $esp_mnt"

  log "Writing GPT protective-MBR boot code ($gptmbr) to $dev (first 440 bytes only; partition table preserved)..."
  dd if="$gptmbr" of="$dev" bs=440 count=1 conv=notrunc status=none || die "Failed writing gptmbr.bin to $dev"

  log "Marking partition $esp_partnum of $dev as legacy_boot..."
  parted -s "$dev" set "$esp_partnum" legacy_boot on || die "Failed to set legacy_boot flag on ${dev} partition ${esp_partnum}"
}

check_uefi_on_block_device() {
  local dev="$1"
  local p1
  p1="$(partition_path "$dev" 1)"
  [[ -b "$p1" ]] || die "UEFI check: missing ${p1}"
  local tmp
  tmp="$(mktemp -d)"
  mount "$p1" "$tmp" || die "UEFI check: cannot mount ${p1}"
  [[ -f "$tmp/EFI/BOOT/BOOTX64.EFI" ]] || { umount "$tmp" || true; rm -rf "$tmp"; die "UEFI check failed on ${p1}: missing EFI/BOOT/BOOTX64.EFI"; }
  umount "$tmp" || true
  rm -rf "$tmp"
}

check_uefi_on_image_file() {
  local img="$1"
  have losetup || die "losetup required to validate UEFI on image"
  local loopdev
  loopdev="$(losetup --find --show --partscan "$img")"
  local p1
  p1="$(partition_path "$loopdev" 1)"
  local tmp
  tmp="$(mktemp -d)"
  mount "$p1" "$tmp" || { losetup -d "$loopdev" || true; die "UEFI check: cannot mount ${p1}"; }
  [[ -f "$tmp/EFI/BOOT/BOOTX64.EFI" ]] || { umount "$tmp" || true; losetup -d "$loopdev" || true; rm -rf "$tmp"; die "UEFI check failed on image: missing EFI/BOOT/BOOTX64.EFI"; }
  umount "$tmp" || true
  losetup -d "$loopdev" || true
  rm -rf "$tmp"
}

build_usb() {
  local iso="$1"
  local dev="$2"

  confirm_destructive "$dev"

  unmount_dev_tree "$dev"
  wipefs -a "$dev"

  parted -s "$dev" mklabel gpt
  parted -s "$dev" mkpart ESP fat32 1MiB "${ESP_MIB}MiB"
  parted -s "$dev" set 1 esp on
  parted -s "$dev" mkpart PERSIST ext4 "${ESP_MIB}MiB" 100%

  partprobe "$dev" || true
  sleep 1

  local esp persist
  esp="$(partition_path "$dev" 1)"
  persist="$(partition_path "$dev" 2)"
  [[ -b "$esp" ]] || die "ESP not found: $esp"
  [[ -b "$persist" ]] || die "Persist not found: $persist"

  mkfs.vfat -F32 -n "$LABEL_ESP" "$esp"
  mkfs.ext4 -F -L "$LABEL_PERSIST" "$persist" >/dev/null

  # Get UUIDs now that both partitions are formatted.
  local esp_uuid data_uuid
  esp_uuid="$(blkid -s UUID -o value "$esp" || true)"
  [[ -n "$esp_uuid" ]] || die "Cannot read UUID from ESP ($esp)"
  data_uuid="$(blkid -s UUID -o value "$persist" || true)"
  [[ -n "$data_uuid" ]] || die "Cannot read UUID from PERSIST ($persist)"

  # WORK_DIR/ISO_MNT/ESP_MNT/PER_MNT are globals: the single EXIT trap
  # (cleanup(), registered at top-level) unmounts/removes them no matter how
  # this function returns, so there is no local RETURN trap here anymore.
  WORK_DIR="$(mktemp -d)"
  ISO_MNT="$WORK_DIR/iso"
  ESP_MNT="$WORK_DIR/esp"
  PER_MNT="$WORK_DIR/persist"
  mkdir -p "$ISO_MNT" "$ESP_MNT" "$PER_MNT"

  mount -o loop,ro "$iso" "$ISO_MNT"
  mount "$esp" "$ESP_MNT"
  mount "$persist" "$PER_MNT"

  # Copy ISO content to ESP.
  if have rsync; then
    rsync -aHAX --delete "$ISO_MNT"/ "$ESP_MNT"/
  else
    rm -rf "${ESP_MNT:?}"/*
    cp -a "$ISO_MNT"/. "$ESP_MNT"/
  fi

  # ALWAYS generate a project-owned UEFI loader; never trust an unmodified
  # loader shipped by the source ISO (overwritten if present).
  generate_grub_uefi_loader "$ESP_MNT" "$esp_uuid" "$data_uuid"

  # Legacy BIOS boot: extlinux + gptmbr.bin + legacy_boot flag, unless the
  # operator explicitly opted out with --no-patch-bootcodes.
  if [[ "$PATCH_BOOTCODES" == "1" ]]; then
    install_legacy_bios_boot "$dev" 1 "$ESP_MNT" "$data_uuid"
    # Idempotently ensure the ISO's own isolinux configs (copied above,
    # otherwise inert now that extlinux.conf/grub.cfg own the boot chain)
    # also carry the persistence kernel args, in case any firmware/tooling
    # falls back to booting via isolinux.bin directly from the ESP.
    patch_bootconfigs_add_karg "$ESP_MNT" "tce=UUID=${data_uuid}"
    patch_bootconfigs_add_karg "$ESP_MNT" "backup=UUID=${data_uuid}"
  else
    warn "--no-patch-bootcodes: building a UEFI-only USB (no legacy BIOS boot path)"
  fi

  # Prepare persistent /tce.
  mkdir -p "$PER_MNT/tce/optional" "$PER_MNT/tce/logs" "$PER_MNT/tce/autoprov"
  cat > "$PER_MNT/tce/README.txt" <<EOF
TinyCore persistent storage:
- Extensions:  /tce/optional
- Onboot:      /tce/onboot.lst
- Backup:      /tce/mydata.tgz (restores overlay at boot)
- Logs:        /tce/logs
- Fallback:    /tce/bootstrap.fallback.sh (bundled controller, used only if
               the remote download fails after all retries)
EOF

  # Copy tcz offline, verifying pinned checksums first (see
  # tcz/tcz-manifest.json and tcz/generate-tcz-manifest.sh).
  if [[ -n "$TCZ_DIR" ]]; then
    verify_tcz_checksums "$TCZ_DIR" "$TCZ_MANIFEST"
    shopt -s nullglob
    cp -a "$TCZ_DIR"/*.tcz "$PER_MNT/tce/optional/" 2>/dev/null || true
    cp -a "$TCZ_DIR"/*.tcz.dep "$PER_MNT/tce/optional/" 2>/dev/null || true
    cp -a "$TCZ_DIR"/*.tcz.md5.txt "$PER_MNT/tce/optional/" 2>/dev/null || true
    shopt -u nullglob
  fi

  # Install onboot.lst (tcz/onboot.lst is the single canonical source list;
  # see tcz/README.md for the full caching pipeline).
  if [[ -n "$PKG_LIST" ]]; then
    awk '{
      gsub(/\r/,"");
      if ($0 ~ /^[[:space:]]*$/) next;
      if ($0 ~ /^[[:space:]]*#/) next;
      print $0
    }' "$PKG_LIST" > "$PER_MNT/tce/onboot.lst"
  fi

  # Stage the overlay in a scratch directory so bootstrap.fallback.sh (the
  # latest accepted controller) can be injected at build time without
  # permanently committing a duplicate copy of it inside overlay/ itself.
  local staged_overlay="$WORK_DIR/overlay-staged"
  cp -a "$OVERLAY_DIR" "$staged_overlay"
  mkdir -p "$staged_overlay/opt/autorun"
  local fallback_src="$SCRIPT_DIR/../check-so/autoinstall-ubuntu.sh"
  [[ -f "$fallback_src" ]] || die "Cannot bundle bootstrap.fallback.sh: missing $fallback_src"
  cp -a "$fallback_src" "$staged_overlay/opt/autorun/bootstrap.fallback.sh"
  chmod +x "$staged_overlay/opt/autorun/bootstrap.fallback.sh"
  local fallback_sha256
  fallback_sha256="$(sha256sum "$staged_overlay/opt/autorun/bootstrap.fallback.sh" | awk '{print $1}')"

  # Pack staged overlay -> mydata.tgz (restored on boot by bootlocal.sh).
  tar -C "$staged_overlay" -czf "$PER_MNT/tce/mydata.tgz" --numeric-owner .
  # Also drop the fallback script directly onto persist so the post-build
  # validator (and operators inspecting the USB) can see it without
  # unpacking the tgz.
  cp -a "$staged_overlay/opt/autorun/bootstrap.fallback.sh" "$PER_MNT/tce/bootstrap.fallback.sh"

  # Copy autorun env file.
  cp -a "$OVERLAY_DIR/opt/autorun/autoprov.env" "$PER_MNT/tce" 2>/dev/null || true
  # Copy files needed by bootstrap scripts (installer.env, etc.).
  cp -a "$BOOTSTRAP_FILES_DIR/." "$PER_MNT/tce" 2>/dev/null || true

  sync

  log "Validating build tree before declaring success..."
  validate_build_tree "$ESP_MNT" "$PER_MNT" "$esp_uuid" "$data_uuid" "$PATCH_BOOTCODES" \
    || die "Post-build validation failed (see [validate] messages above). The USB was written but is NOT trustworthy; do not deploy it."

  local manifest_out="${BUILD_MANIFEST_OUT:-$(pwd)/build-manifest.json}"
  emit_build_manifest "$manifest_out" "$ESP_MNT" "$PER_MNT" "$esp_uuid" "$data_uuid"
  local manifest_tmp="$manifest_out.tmp.$$"
  jq --arg h "$fallback_sha256" '. + {bootstrap_fallback_sha256: $h}' "$manifest_out" > "$manifest_tmp" \
    && mv "$manifest_tmp" "$manifest_out"
  log "Wrote build manifest: $manifest_out"

  log "Done. UEFI + legacy BIOS loaders present and persistence ready."
  log "  ESP UUID:    $esp_uuid (used in grub search / extlinux persistence args)"
  log "  Data UUID:   $data_uuid"
  log "  Logs in:     LABEL=$LABEL_PERSIST -> tce/logs/"
  log "  Manifest:    $manifest_out"
}

vm_test() {
  local src="$1"
  have virt-install || die "virt-install not found (sudo apt install virtinst)"
  have qemu-img || die "qemu-img not found (sudo apt install qemu-utils)"

  if [[ -b "$src" ]]; then
    check_uefi_on_block_device "$src"
  else
    check_uefi_on_image_file "$src"
  fi
  echo "[+] UEFI validation OK for VM source"

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  local name="${VM_NAME:-tc-autoprov-test-${ts}}"

  [[ "$VM_GRAPHICS" == "spice" || "$VM_GRAPHICS" == "none" ]] || die "--vm-graphics must be spice|none"

  local img_dir="/var/lib/libvirt/images"
  mkdir -p "$img_dir"
  local disk_path="$img_dir/${name}.qcow2"

  echo "[+] Creating VM qcow2 disk: $disk_path (${VM_DISK_GB}G)"
  qemu-img create -f qcow2 "$disk_path" "${VM_DISK_GB}G" >/dev/null
  chmod 0644 "$disk_path" || true

  local gfx_args=()
  if [[ "$VM_GRAPHICS" == "none" ]]; then
    gfx_args=(--graphics none --console pty,target_type=serial)
  else
    gfx_args=(--graphics spice)
  fi

  echo "[+] Launching VM '$name' (UEFI) booting from: $src"
  virt-install \
    --connect qemu:///system \
    --name "$name" \
    --memory "$VM_RAM" \
    --vcpus 2 \
    --boot uefi,menu=on \
    "${gfx_args[@]}" \
    --disk "path=$src,device=disk,format=raw,bus=virtio,boot.order=1" \
    --disk "path=$disk_path,device=disk,format=qcow2,bus=virtio,boot.order=2" \
    --osinfo generic \
    --noautoconsole \
    --import

  echo
  echo "[*] VM: $name"
  echo "    virsh -c qemu:///system console '$name'   #(exit: Ctrl+])"
  echo "    sudo virsh -c qemu:///system domdisplay '$name'"
  echo "    remote-viewer spice://127.0.0.1:5901"
  echo "    "
  echo "    virsh -c qemu:///system destroy '$name' || true"
  echo "    virsh -c qemu:///system undefine '$name' --nvram || virsh -c qemu:///system undefine '$name'"
  echo "    sudo rm -f '$disk_path'   # cleanup qcow2 when done"
}


if [[ "$VM_ONLY" != "1" ]]; then
  TARGET_DEV="$DEV"
  if [[ -n "$IMAGE_PATH" ]]; then
    log "Creating raw image $IMAGE_PATH ($IMAGE_SIZE) and attaching via loop device..."
    TARGET_DEV="$(create_image_and_attach "$IMAGE_PATH" "$IMAGE_SIZE")"
    log "Attached as $TARGET_DEV (detached automatically on exit; populated image file remains at $IMAGE_PATH)"
  fi
  build_usb "$ISO" "$TARGET_DEV"
fi

if [[ "$VM_TEST" == "1" || "$VM_ONLY" == "1" ]]; then
  vm_test "$VM_SRC"
fi
