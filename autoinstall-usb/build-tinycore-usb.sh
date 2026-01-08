#!/usr/bin/env bash
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
sudo ./build-tinycore-usb.sh \
  --iso ./Core-current.iso \
  --dev /dev/sdX \
  --overlay ./overlay \
  --tcz-dir ./tcz \
  --pkg-list ./tcz/onboot.lst \
  --vm-test --vm-src /dev/sdX

Options:
  --iso PATH
  --dev /dev/sdX
  --overlay DIR              (ej: ./overlay; contiene opt/bootlocal.sh, opt/autorun/*)
  --tcz-dir DIR              (opcional: *.tcz, *.tcz.dep, *.md5.txt)
  --pkg-list FILE            (opcional: onboot.lst)
  --label-esp LABEL          (default: TINYBOOT)
  --label-persist LABEL      (default: TINYDATA)
  --esp-mib N                (default: 1024)
  --no-patch-bootcodes       (no añade tce=LABEL=... a syslinux configs)
  -y                         (no pide confirmación)

UEFI:
  Si la ISO no trae EFI/BOOT/BOOTX64.EFI, el script genera uno con GRUB (grub-mkstandalone)
  y usa search --fs-uuid con el UUID real de la ESP.

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
OVERLAY_DIR="./overlay"
BOOTSTRAP_FILES_DIR="./bootstrap"
TCZ_DIR=""
PKG_LIST=""
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
    --overlay) OVERLAY_DIR="$2"; shift 2;;
    --tcz-dir) TCZ_DIR="$2"; shift 2;;
    --pkg-list) PKG_LIST="$2"; shift 2;;
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
  [[ -n "$DEV" && -b "$DEV" ]] || die "Missing/invalid --dev"
  [[ ! "$DEV" =~ [0-9]$ ]] || die "--dev must be a disk like /dev/sdX"
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

# Detect TinyCore kernel/initrd inside ESP
detect_tc_boot_files() {
  local esp_root="$1"
  local k=""
  local i=""

  # Common
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

# Generate BOOTX64.EFI and grub.cfg. Uses ESP UUID for search.
generate_grub_uefi_loader() {
  local esp_root="$1"
  local esp_uuid="$2"     # UUID of /dev/sdX1 (vfat)
  local data_uuid="$3"     # UUID of /dev/sdX2 (PERSIST)

  have grub-mkstandalone || die "grub-mkstandalone not found. Install: sudo apt install grub-efi-amd64-bin"

  local bi
  bi="$(detect_tc_boot_files "$esp_root" || true)"
  [[ -n "$bi" ]] || die "Cannot detect TinyCore boot files under /boot (need vmlinuz* and *.gz)"
  local KERNEL="${bi%%|*}"
  local INITRD="${bi##*|}"

  mkdir -p "$esp_root/EFI/BOOT"

  # IMPORTANT: put search inside menuentry so root is correct when loading kernel/initrd
  cat > "$esp_root/EFI/BOOT/grub.cfg" <<EOF
set timeout=3
set default=0

menuentry "TinyCore (UEFI) + autoprov" {
  insmod part_gpt
  insmod fat
  search --no-floppy --fs-uuid --set=root ${esp_uuid}
  echo "Loading TinyCore..."
  linux  ${KERNEL} quiet waitusb=20:UUID=$data_uuid tc-config tce=UUID=$data_uuid backup=UUID=$data_uuid loglevel=7
  initrd ${INITRD}
}
EOF

  echo "[+] Generating EFI/BOOT/BOOTX64.EFI with grub-mkstandalone..."
  grub-mkstandalone \
    -O x86_64-efi \
    -o "$esp_root/EFI/BOOT/BOOTX64.EFI" \
    "boot/grub/grub.cfg=$esp_root/EFI/BOOT/grub.cfg" >/dev/null

  [[ -f "$esp_root/EFI/BOOT/BOOTX64.EFI" ]] || die "Failed to generate BOOTX64.EFI"
}

check_or_make_uefi() {
  local esp_root="$1"
  local esp_uuid="$2"
  local data_uuid="$3"     # UUID of /dev/sdX2 (PERSIST)

  if [[ -f "$esp_root/EFI/BOOT/BOOTX64.EFI" ]]; then
    echo "[+] UEFI loader already present: EFI/BOOT/BOOTX64.EFI"
    return 0
  fi
  echo "[!] No EFI loader in ISO copy. Will generate BOOTX64.EFI via GRUB..."
  generate_grub_uefi_loader "$esp_root" "$esp_uuid" "$data_uuid"
}

check_uefi_on_block_device() {
  local dev="$1"
  local p1="${dev}1"
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
  local p1="${loopdev}p1"
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

  echo "[!] ABOUT TO ERASE: $dev"
  lsblk -o NAME,SIZE,MODEL,TRAN "$dev" || true
  if [[ "$ASSUME_YES" != "1" ]]; then
    read -r -p "Type YES to continue: " ans
    [[ "$ans" == "YES" ]] || die "Aborted."
  fi

  unmount_dev_tree "$dev"
  wipefs -a "$dev"

  parted -s "$dev" mklabel gpt
  parted -s "$dev" mkpart ESP fat32 1MiB "${ESP_MIB}MiB"
  parted -s "$dev" set 1 esp on
  parted -s "$dev" mkpart PERSIST ext4 "${ESP_MIB}MiB" 100%

  partprobe "$dev" || true
  sleep 1

  local esp="${dev}1"
  local persist="${dev}2"
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
  [[ -n "$esp_uuid" ]] || die "Cannot read UUID from ESP ($esp)"

  local work
  work="$(mktemp -d)"
  local iso_mnt="$work/iso"
  local esp_mnt="$work/esp"
  local per_mnt="$work/persist"
  mkdir -p "$iso_mnt" "$esp_mnt" "$per_mnt"
  trap 'set +e; umount "$iso_mnt" >/dev/null 2>&1 || true; umount "$esp_mnt" >/dev/null 2>&1 || true; umount "$per_mnt" >/dev/null 2>&1 || true; rm -rf "$work"' RETURN

  mount -o loop,ro "$iso" "$iso_mnt"
  mount "$esp" "$esp_mnt"
  mount "$persist" "$per_mnt"

  # Copy ISO to ESP
  if have rsync; then
    rsync -aHAX --delete "$iso_mnt"/ "$esp_mnt"/
  else
    rm -rf "$esp_mnt"/*
    cp -a "$iso_mnt"/. "$esp_mnt"/
  fi

  # Ensure UEFI loader exists (either from ISO or generated). Uses detected ESP UUID.
  check_or_make_uefi "$esp_mnt" "$esp_uuid" "$data_uuid"

  # Prepare persistent /tce
  mkdir -p "$per_mnt/tce/optional" "$per_mnt/tce/logs" "$per_mnt/tce/autoprov"
  cat > "$per_mnt/tce/README.txt" <<EOF
TinyCore persistent storage:
- Extensions:  /tce/optional
- Onboot:      /tce/onboot.lst
- Backup:      /tce/mydata.tgz (restores overlay at boot)
- Logs:        /tce/logs
EOF

  # Copy tcz offline
  if [[ -n "$TCZ_DIR" ]]; then
    shopt -s nullglob
    cp -a "$TCZ_DIR"/*.tcz "$per_mnt/tce/optional/" 2>/dev/null || true
    cp -a "$TCZ_DIR"/*.tcz.dep "$per_mnt/tce/optional/" 2>/dev/null || true
    cp -a "$TCZ_DIR"/*.tcz.md5.txt "$per_mnt/tce/optional/" 2>/dev/null || true
    shopt -u nullglob
  fi

  # Install onboot.lst
  if [[ -n "$PKG_LIST" ]]; then
    awk '{
      gsub(/\r/,"");
      if ($0 ~ /^[[:space:]]*$/) next;
      if ($0 ~ /^[[:space:]]*#/) next;
      print $0
    }' "$PKG_LIST" > "$per_mnt/tce/onboot.lst"
  fi

  # Pack overlay -> mydata.tgz (restored on boot)
  tar -C "$OVERLAY_DIR" -czf "$per_mnt/tce/mydata.tgz" --numeric-owner .

  # For legacy/syslinux paths (optional)
#   if [[ "$PATCH_BOOTCODES" == "1" ]]; then
#     patch_bootconfigs_add_karg "$esp_mnt" "tce=LABEL=${LABEL_PERSIST}"
#     patch_bootconfigs_add_karg "$esp_mnt" "backup=LABEL=${LABEL_PERSIST}"
#   fi

  # copy autorun env file
  cp -a "$OVERLAY_DIR/opt/autorun/autoprov.env" "$per_mnt/tce" 2>/dev/null || true
  # copy files needed by bootstrap scripts
  cp -a "$BOOTSTRAP_FILES_DIR/." "$per_mnt/tce" 2>/dev/null || true

  sync
  umount "$per_mnt" || true
  umount "$esp_mnt" || true
  umount "$iso_mnt" || true
  trap - RETURN
  rm -rf "$work"

  echo "[+] Done. UEFI loader present and persistence ready."
  echo "    ESP UUID:  $esp_uuid (used in grub search)"
  echo "    Logs in:   LABEL=$LABEL_PERSIST -> tce/logs/"
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
  build_usb "$ISO" "$DEV"
fi

if [[ "$VM_TEST" == "1" || "$VM_ONLY" == "1" ]]; then
  vm_test "$VM_SRC"
fi
