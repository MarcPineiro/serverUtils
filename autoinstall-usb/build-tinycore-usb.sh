#!/usr/bin/env bash
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/functions.sh
source "$SCRIPT_ROOT/lib/functions.sh"
# shellcheck source=lib/grub.sh
source "$SCRIPT_ROOT/lib/grub.sh"
# shellcheck source=lib/syslinux.sh
source "$SCRIPT_ROOT/lib/syslinux.sh"

# A single EXIT trap (registered once, at top level) guarantees every mount
# and loop device this script creates is released even when `die`/`set -e`
# short-circuits control flow (agent-plan Phase 1: "Add an EXIT cleanup trap
# for mounts and loop devices").
trap cleanup_on_exit EXIT

usage() {
  cat <<'EOF'
sudo ./build-tinycore-usb.sh \
  --iso ./Core-current.iso \
  --dev /dev/sdX \
  --overlay ./overlay \
  --tcz-dir ./tcz \
  --pkg-list ./tcz/onboot.lst \
  --vm-test --vm-src /dev/sdX

sudo ./build-tinycore-usb.sh --iso ./Core-current.iso --image /tmp/usb.img --image-size 2G

Options:
  --iso PATH
  --dev /dev/sdX              Whole-disk target (mutually exclusive with --image).
  --image PATH                 Build into a raw image file instead of a real disk
                                (loop-attached; safe for CI/local testing).
  --image-size SIZE            Required the first time --image PATH does not exist
                                yet (qemu-img size syntax, e.g. 2G).
  --overlay DIR              (ej: ./overlay; contiene opt/bootlocal.sh, opt/autorun/*)
  --tcz-dir DIR              (opcional: *.tcz, *.tcz.dep, *.md5.txt [+ manifest.json])
  --pkg-list FILE            (opcional: onboot.lst)
  --controller-src PATH        Controller bundled onto TINYDATA as the local
                                fallback (default: ../check-so/autoinstall-ubuntu.sh).
  --no-bundle-fallback          Skip bundling the fallback controller (testing only).
  --label-esp LABEL          (default: TINYBOOT)
  --label-persist LABEL      (default: TINYDATA)
  --esp-mib N                (default: 1024)
  --no-patch-bootcodes       (no añade tce=/backup=/waitusb= a syslinux configs)
  -y                         (no pide confirmación interactiva; el token sigue
                              impreso para que quede constancia en el log)

UEFI:
  EFI/BOOT/grub.cfg y BOOTX64.EFI se regeneran SIEMPRE con GRUB
  (grub-mkstandalone) usando el UUID real de la ESP; nunca se confía en el
  loader de la ISO de origen.

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

  local root="$SCRIPT_ROOT"
  local fetch_script="$root/tcz/fetch-tcz.sh"
  local cache_root="$root/tcz-cache"
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

  # Si TCZ_DIR está vacío o no contiene .tcz, descargamos con fetch-tcz.sh
  # (tcz/onboot.lst es la única lista canónica; nunca se genera aquí).
  if [[ "$need_fetch" == "1" ]]; then
    [[ -f "$fetch_script" ]] || die "No existe $fetch_script (necesario para descargar TCZ)"
    [[ -f "$PKG_LIST" ]] || die "Invalid --pkg-list: $PKG_LIST"

    echo "[+] No hay .tcz offline en --tcz-dir. Descargando con fetch-tcz.sh..."
    run_as_user "cd '$root' && '$fetch_script' --onboot '$PKG_LIST' --out ./tcz-cache/tce"

    shopt -s nullglob
    local downloaded=( "$cache_optional"/*.tcz )
    shopt -u nullglob
    ((${#downloaded[@]} > 0)) || die "fetch-tcz.sh terminó pero el cache sigue vacío: $cache_optional"

    # IMPORTANTE: apuntamos TCZ_DIR al directorio que contiene .tcz DIRECTAMENTE
    TCZ_DIR="$cache_optional"
    echo "[+] Usando cache offline: TCZ_DIR=$TCZ_DIR"
  fi
}

ISO=""
DEV=""
IMAGE=""
IMAGE_SIZE=""
OVERLAY_DIR="$SCRIPT_ROOT/overlay"
BOOTSTRAP_FILES_DIR="$SCRIPT_ROOT/bootstrap"
TCZ_DIR=""
PKG_LIST=""
CONTROLLER_SRC="$(cd "$SCRIPT_ROOT/.." && pwd)/check-so/autoinstall-ubuntu.sh"
BUNDLE_FALLBACK="1"
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso) ISO="$2"; shift 2;;
    --dev) DEV="$2"; shift 2;;
    --image) IMAGE="$2"; shift 2;;
    --image-size) IMAGE_SIZE="$2"; shift 2;;
    --overlay) OVERLAY_DIR="$2"; shift 2;;
    --tcz-dir) TCZ_DIR="$2"; shift 2;;
    --pkg-list) PKG_LIST="$2"; shift 2;;
    --controller-src) CONTROLLER_SRC="$2"; shift 2;;
    --no-bundle-fallback) BUNDLE_FALLBACK="0"; shift 1;;
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

if [[ "$VM_ONLY" != "1" ]]; then
  [[ -n "$ISO" && -f "$ISO" ]] || die "Missing/invalid --iso"
  [[ -n "$DEV" || -n "$IMAGE" ]] || die "One of --dev or --image is required"
  [[ -z "$DEV" || -z "$IMAGE" ]] || die "--dev and --image are mutually exclusive"
  if [[ -n "$DEV" ]]; then
    require_whole_disk "$DEV"
  fi
  if [[ -n "$IMAGE" && ! -f "$IMAGE" ]]; then
    [[ -n "$IMAGE_SIZE" ]] || die "--image-size is required to create a new image: $IMAGE"
  fi
  [[ -d "$OVERLAY_DIR" ]] || die "Invalid --overlay dir: $OVERLAY_DIR"
  if [[ "$BUNDLE_FALLBACK" == "1" ]]; then
    [[ -f "$CONTROLLER_SRC" ]] || die "--controller-src not found: $CONTROLLER_SRC (or pass --no-bundle-fallback for a test-only build)"
  fi
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

check_or_make_uefi() {
  local esp_root="$1"
  local esp_uuid="$2"
  local data_uuid="$3"     # UUID of PERSIST partition

  # A GRUB config is ALWAYS (re)generated: never trust an unmodified loader
  # copied verbatim from the source ISO (agent-plan Phase 1).
  generate_grub_uefi_loader "$esp_root" "$esp_uuid" "$data_uuid"
}

check_uefi_on_block_device() {
  local dev="$1"
  local p1
  p1="$(partition_path "$dev" 1)"
  [[ -b "$p1" ]] || die "UEFI check: missing ${p1}"
  local tmp
  tmp="$(mktemp -d)"
  register_cleanup_dir "$tmp"
  mount -o ro "$p1" "$tmp" || die "UEFI check: cannot mount ${p1}"
  register_cleanup_mount "$tmp"
  [[ -f "$tmp/EFI/BOOT/BOOTX64.EFI" ]] || die "UEFI check failed on ${p1}: missing EFI/BOOT/BOOTX64.EFI"
  umount "$tmp"
}

check_uefi_on_image_file() {
  local img="$1"
  have losetup || die "losetup required to validate UEFI on image"
  local loopdev
  loopdev="$(losetup --find --show --read-only --partscan "$img")"
  register_cleanup_loop "$loopdev"
  local p1
  p1="$(partition_path "$loopdev" 1)"
  local tmp
  tmp="$(mktemp -d)"
  register_cleanup_dir "$tmp"
  mount -o ro "$p1" "$tmp" || die "UEFI check: cannot mount ${p1}"
  register_cleanup_mount "$tmp"
  [[ -f "$tmp/EFI/BOOT/BOOTX64.EFI" ]] || die "UEFI check failed on image: missing EFI/BOOT/BOOTX64.EFI"
  umount "$tmp"
}

build_usb() {
  local iso="$1"
  local dev="$2"          # real whole-disk device to partition/format
  local erase_token="$3"  # serial (real disk) or image path (image build)

  confirm_erase_token "$dev" "$erase_token" "$ASSUME_YES"

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

  # Get ESP UUID now that it's formatted
  local esp_uuid
  esp_uuid="$(blkid -s UUID -o value "$esp" || true)"
  [[ -n "$esp_uuid" ]] || die "Cannot read UUID from ESP ($esp)"
  local data_uuid
  data_uuid="$(blkid -s UUID -o value "$persist")"
  [[ -n "$data_uuid" ]] || die "Cannot read UUID from PERSIST ($persist)"

  local work
  work="$(mktemp -d)"
  register_cleanup_dir "$work"
  local iso_mnt="$work/iso"
  local esp_mnt="$work/esp"
  local per_mnt="$work/persist"
  mkdir -p "$iso_mnt" "$esp_mnt" "$per_mnt"

  mount -o loop,ro "$iso" "$iso_mnt"
  register_cleanup_mount "$iso_mnt"
  mount "$esp" "$esp_mnt"
  register_cleanup_mount "$esp_mnt"
  mount "$persist" "$per_mnt"
  register_cleanup_mount "$per_mnt"

  # Copy ISO to ESP
  if have rsync; then
    rsync -aHAX --delete "$iso_mnt"/ "$esp_mnt"/
  else
    rm -rf "${esp_mnt:?}"/*
    cp -a "$iso_mnt"/. "$esp_mnt"/
  fi

  # Ensure UEFI loader exists (project-owned, always regenerated).
  check_or_make_uefi "$esp_mnt" "$esp_uuid" "$data_uuid"

  # Legacy BIOS/syslinux: idempotent append-line patching (no-op if the ISO
  # ships no legacy loader).
  if [[ "$PATCH_BOOTCODES" == "1" ]]; then
    patch_syslinux_configs "$esp_mnt" "$data_uuid"
  fi

  # Prepare persistent /tce
  mkdir -p "$per_mnt/tce/optional" "$per_mnt/tce/logs" "$per_mnt/tce/autoprov"
  cat > "$per_mnt/tce/README.txt" <<EOF
TinyCore persistent storage:
- Extensions:  /tce/optional
- Onboot:      /tce/onboot.lst
- Backup:      /tce/mydata.tgz (restores overlay at boot, including
               /opt/autorun/bootstrap.fallback.sh, the bundled offline
               controller used only after remote download retries are
               exhausted)
- Logs:        /tce/logs
- Package manifest: /tce/manifest.json (sha256 of every cached .tcz, when
               --tcz-dir was used to build this USB)
EOF

  # Copy tcz offline (verified against tcz/pinned-version.json + fetch-tcz.sh
  # manifest.json before copying; agent-plan Phase 1 "TCZ caching pipeline").
  if [[ -n "$TCZ_DIR" ]]; then
    verify_tcz_dir_against_manifest "$TCZ_DIR"
    shopt -s nullglob
    cp -a "$TCZ_DIR"/*.tcz "$per_mnt/tce/optional/" 2>/dev/null || true
    cp -a "$TCZ_DIR"/*.tcz.dep "$per_mnt/tce/optional/" 2>/dev/null || true
    cp -a "$TCZ_DIR"/*.tcz.md5.txt "$per_mnt/tce/optional/" 2>/dev/null || true
    shopt -u nullglob
    # Also carry the manifest itself onto the USB (top-level tce/manifest.json,
    # never inside optional/ so it is never mistaken for a package) so
    # validate-build.sh can re-verify cached packages by mounting the image
    # alone, without access to the original --tcz-dir (agent-plan Phase 1
    # post-build validator: "Verify ... cached packages").
    if [[ -f "$TCZ_DIR/manifest.json" ]]; then
      cp -a "$TCZ_DIR/manifest.json" "$per_mnt/tce/manifest.json"
    elif [[ -f "$(dirname "$TCZ_DIR")/manifest.json" ]]; then
      cp -a "$(dirname "$TCZ_DIR")/manifest.json" "$per_mnt/tce/manifest.json"
    fi
  fi

  # Install onboot.lst (tcz/onboot.lst is the single canonical package list)
  if [[ -n "$PKG_LIST" ]]; then
    awk '{
      gsub(/\r/,"");
      if ($0 ~ /^[[:space:]]*$/) next;
      if ($0 ~ /^[[:space:]]*#/) next;
      print $0
    }' "$PKG_LIST" > "$per_mnt/tce/onboot.lst"
  fi

  # Stage the overlay into a scratch copy so the fallback controller can be
  # injected at opt/autorun/bootstrap.fallback.sh before packing -- the
  # git-tracked overlay/ source tree itself is never written to (agent-plan
  # Phase 1: "Add /opt/autorun/bootstrap.fallback.sh to the overlay").
  local overlay_stage
  overlay_stage="$(mktemp -d)"
  register_cleanup_dir "$overlay_stage"
  if have rsync; then
    rsync -aHAX "$OVERLAY_DIR"/ "$overlay_stage"/
  else
    cp -a "$OVERLAY_DIR"/. "$overlay_stage"/
  fi

  if [[ "$BUNDLE_FALLBACK" == "1" ]]; then
    mkdir -p "$overlay_stage/opt/autorun"
    cp -a "$CONTROLLER_SRC" "$overlay_stage/opt/autorun/bootstrap.fallback.sh"
    chmod +x "$overlay_stage/opt/autorun/bootstrap.fallback.sh"
    echo "[+] Bundled fallback controller: $CONTROLLER_SRC -> opt/autorun/bootstrap.fallback.sh"
    echo "    sha256: $(sha256_file "$overlay_stage/opt/autorun/bootstrap.fallback.sh")"
  else
    echo "[!] --no-bundle-fallback: no offline fallback controller bundled."
  fi

  # Pack the staged overlay -> mydata.tgz (restored on boot); bootlocal.sh is
  # the single authoritative entrypoint (agent-plan Phase 1).
  tar -C "$overlay_stage" -czf "$per_mnt/tce/mydata.tgz" --numeric-owner .

  # A second, directly-editable copy of autoprov.env lives on the tce
  # partition itself (ENV_TCE in autoprov-run.sh): it overrides the
  # overlay-shipped defaults without requiring a full USB rebuild.
  cp -a "$OVERLAY_DIR/opt/autorun/autoprov.env" "$per_mnt/tce" 2>/dev/null || true
  # copy files needed by bootstrap scripts
  cp -a "$BOOTSTRAP_FILES_DIR/." "$per_mnt/tce" 2>/dev/null || true

  sync
  umount "$per_mnt"
  umount "$esp_mnt"
  umount "$iso_mnt"
  rm -rf "$work"

  echo "[+] Done. UEFI loader present and persistence ready."
  echo "    ESP UUID:     $esp_uuid (used in grub search)"
  echo "    PERSIST UUID: $data_uuid (used in tce=/backup=/waitusb= kargs)"
  echo "    Logs in:      LABEL=$LABEL_PERSIST -> tce/logs/"
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

build_from_image() {
  local iso="$1" image="$2"

  if [[ ! -f "$image" ]]; then
    have qemu-img || die "qemu-img is required to create --image $image"
    echo "[+] Creating sparse image: $image (${IMAGE_SIZE})"
    qemu-img create -f raw "$image" "$IMAGE_SIZE" >/dev/null
  fi

  have losetup || die "losetup is required for --image builds"
  local loopdev
  loopdev="$(losetup --find --show --partscan "$image")"
  register_cleanup_loop "$loopdev"

  build_usb "$iso" "$loopdev" "$(cd "$(dirname "$image")" && pwd)/$(basename "$image")"

  losetup -d "$loopdev"
  # Unregister: already detached above, avoid a harmless double-detach warning.
  local i kept=()
  for i in "${CLEANUP_LOOPS[@]}"; do
    [[ "$i" == "$loopdev" ]] || kept+=("$i")
  done
  CLEANUP_LOOPS=("${kept[@]}")
}

if [[ "$VM_ONLY" != "1" ]]; then
  if [[ -n "$IMAGE" ]]; then
    build_from_image "$ISO" "$IMAGE"
  else
    build_usb "$ISO" "$DEV" "$(disk_serial "$DEV")"
  fi
fi

if [[ "$VM_TEST" == "1" || "$VM_ONLY" == "1" ]]; then
  vm_test "$VM_SRC"
fi

