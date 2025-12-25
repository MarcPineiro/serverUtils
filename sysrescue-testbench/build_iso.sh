#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Uso:
  $0 [opciones] [ISO_IN] [ISO_OUT] [OVERLAY_DIR]

Opciones:
  --clean           Recrea siempre el .dat de persistencia
  -h, --help        Muestra esta ayuda y sale

Argumentos posicionales:
  ISO_IN            ISO base (default: systemrescue-12.03-amd64.iso)
  ISO_OUT           ISO salida (default: systemrescue-12.03-testbench-amd64.iso)
  OVERLAY_DIR       Directorio overlay (default: overlay)

Variables de entorno:
  DAT_OUT           Fichero .dat (default: systemrescue-persist.dat)
  DAT_SIZE_MB       Tamaño del .dat en MB (default: 1024)

Ejemplos:
  $0
  $0 --clean
  $0 --clean in.iso out.iso overlay
  DAT_SIZE_MB=2048 $0 in.iso
EOF
}

CLEAN_DAT=false

# Preprocesado para soportar flags largos con getopts
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --clean) ARGS+=("-c") ;;
    --help)  ARGS+=("-h") ;;
    *)       ARGS+=("$arg") ;;
  esac
done
set -- "${ARGS[@]}"

while getopts ":ch" opt; do
  case "$opt" in
    c) CLEAN_DAT=true ;;
    h) usage; exit 0 ;;
    \?)
      echo "Opción inválida: -$OPTARG" >&2
      usage
      exit 1
      ;;
  esac
done
shift $((OPTIND - 1))

ISO_IN="${1:-systemrescue-12.03-amd64.iso}"
ISO_OUT="${2:-systemrescue-12.03-testbench-amd64.iso}"
OVERLAY_DIR="${3:-overlay}"
DAT_OUT="${DAT_OUT:-systemrescue-persist.dat}"
DAT_SIZE_MB="${DAT_SIZE_MB:-1024}"      # 1GB
DAT_MNT="${DAT_MNT:-/mnt/persist}"
DAT_LABEL="${DAT_LABEL:-SYSRESCUE_PERSIST}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Falta '$1'"; exit 1; }; }

need xorriso
need unsquashfs
need mksquashfs
need rsync
need dd
need mkfs.ext4
need mount
need umount

[[ -f "$ISO_IN" ]] || { echo "No existe ISO: $ISO_IN"; exit 1; }
[[ -d "$OVERLAY_DIR" ]] || { echo "No existe overlay dir: $OVERLAY_DIR"; exit 1; }

# Validaciones mínimas
[[ -f "$OVERLAY_DIR/etc/systemd/system/testbench.service" ]] || { echo "Falta testbench.service en overlay"; exit 1; }
[[ -x "$OVERLAY_DIR/opt/testbench/run.sh" || -f "$OVERLAY_DIR/opt/testbench/run.sh" ]] || { echo "Falta /opt/testbench/run.sh en overlay"; exit 1; }

# Necesitamos el config.env para poblar el DAT
if [[ ! -f "$OVERLAY_DIR/opt/testbench/config.env" ]]; then
  echo "ERROR: falta $OVERLAY_DIR/opt/testbench/config.env"
  exit 1
fi

WORK="$(mktemp -d)"
trap '
  if mountpoint -q "$DAT_MNT" 2>/dev/null; then
    umount -l "$DAT_MNT" || true
  fi
  sudo rm -rf "$WORK" 2>/dev/null || rm -rf "$WORK" 2>/dev/null
' EXIT

ISO_DIR="$WORK/iso"
SFS_DIR="$WORK/sfs"
ROOTFS_DIR="$WORK/rootfs"
mkdir -p "$ISO_DIR" "$SFS_DIR"

echo "[1/6] Extrayendo ISO -> $ISO_DIR"
xorriso -osirrox on -indev "$ISO_IN" -extract / "$ISO_DIR" >/dev/null 2>&1

echo "[2/6] Buscando airootfs.sfs"
SFS_PATH="$(find "$ISO_DIR" -type f \( -name 'airootfs.sfs' -o -name '*.sfs' \) | head -n 1 || true)"
if [[ -z "${SFS_PATH:-}" ]]; then
  echo "No encontré airootfs.sfs ni ningún .sfs dentro de la ISO."
  echo "Lista de sysrescue content:"
  find "$ISO_DIR" -maxdepth 3 -type f | head -n 50
  exit 1
fi
echo "  -> SFS: $SFS_PATH"

echo "[3/6] Detectando compresión del SFS"
SFS_COMP="$(unsquashfs -s "$SFS_PATH" | awk -F': ' '/Compression/{print $2}' | tr '[:upper:]' '[:lower:]' | head -n 1)"
SFS_COMP="${SFS_COMP:-xz}"
echo "  -> Compression: $SFS_COMP"

# Map a mksquashfs args
MKSQ_COMP_ARGS=()
case "$SFS_COMP" in
  zstd) MKSQ_COMP_ARGS=(-comp zstd) ;;
  xz)   MKSQ_COMP_ARGS=(-comp xz) ;;
  lz4)  MKSQ_COMP_ARGS=(-comp lz4) ;;
  gzip) MKSQ_COMP_ARGS=(-comp gzip) ;;
  lzo)  MKSQ_COMP_ARGS=(-comp lzo) ;;
  *)    echo "Compresión desconocida '$SFS_COMP'. Usando xz."; MKSQ_COMP_ARGS=(-comp xz) ;;
esac

echo "[4/6] Extrayendo SFS -> $ROOTFS_DIR"
unsquashfs -d "$ROOTFS_DIR" "$SFS_PATH" >/dev/null

echo "[5/6] Aplicando overlay -> rootfs"
# Copia overlay encima del rootfs (rutas absolutas dentro del FS)
rsync -aHAX --info=stats1 "$OVERLAY_DIR"/ "$ROOTFS_DIR"/

# Asegura permisos ejecutables de scripts
chmod +x "$ROOTFS_DIR/opt/testbench/"*.sh 2>/dev/null || true
chmod +x "$ROOTFS_DIR/opt/testbench/lib/"*.sh 2>/dev/null || true

echo "[5.5/6] Instalando paquetes extra dentro del rootfs (fio, opcional stressapptest)"
# Requiere internet EN LA MÁQUINA BUILDER (no en el live). La ISO resultante será offline.

# Asegura DNS en el chroot (muy importante)
mkdir -p "$ROOTFS_DIR/etc"
cp -L /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf" || true

# Montajes necesarios para pacman en chroot
mount --bind /dev  "$ROOTFS_DIR/dev"
mount --bind /proc "$ROOTFS_DIR/proc"
mount --bind /sys  "$ROOTFS_DIR/sys"
mount --bind /run  "$ROOTFS_DIR/run"

# Si tu host tiene efivars y quieres evitar warnings, puedes montar esto (opcional)
# if [[ -d /sys/firmware/efi/efivars ]]; then
#   mkdir -p "$ROOTFS_DIR/sys/firmware/efi/efivars"
#   mount --bind /sys/firmware/efi/efivars "$ROOTFS_DIR/sys/firmware/efi/efivars" || true
# fi

# Inicializa keyring si hiciera falta (no siempre necesario)
chroot "$ROOTFS_DIR" bash -lc 'pacman-key --init >/dev/null 2>&1 || true'
chroot "$ROOTFS_DIR" bash -lc 'pacman-key --populate archlinux >/dev/null 2>&1 || true'

# Sync repos + instala paquetes
chroot "$ROOTFS_DIR" bash -lc 'pacman -Sy --noconfirm fio' 
# Opcional: stressapptest si quieres test RAM más “serio” que stress-ng
# chroot "$ROOTFS_DIR" bash -lc 'pacman -Sy --noconfirm stressapptest'

# Limpia caché para no inflar la ISO
chroot "$ROOTFS_DIR" bash -lc 'yes | pacman -Scc >/dev/null 2>&1 || true'

# Desmontar (en orden inverso)
umount -l "$ROOTFS_DIR/run"  || true
umount -l "$ROOTFS_DIR/sys"  || true
umount -l "$ROOTFS_DIR/proc" || true
umount -l "$ROOTFS_DIR/dev"  || true

echo "[6/6] Reempaquetando SFS y reconstruyendo ISO"
NEW_SFS="$WORK/airootfs.sfs"
mksquashfs "$ROOTFS_DIR" "$NEW_SFS" -noappend "${MKSQ_COMP_ARGS[@]}" 

# Reemplaza el SFS dentro del árbol ISO extraído
cp -f "$NEW_SFS" "$SFS_PATH"

# Asegura que no existe la ISO de salida
rm -f "$ISO_OUT"

echo "Extrayendo parámetros de arranque (mkisofs) del ISO original..."
MKOPTS_FILE="$WORK/mkisofs_opts.txt"
xorriso -indev "$ISO_IN" -report_el_torito as_mkisofs > "$MKOPTS_FILE"

echo "Reconstruyendo ISO (mkisofs mode) -> $ISO_OUT"
# Ojo: usamos eval para aplicar las opciones tal cual las reporta xorriso.
# La parte final "-graft-points /=$ISO_DIR" añade el árbol de ficheros modificado.
eval xorriso -as mkisofs \
  -o "\"$ISO_OUT\"" \
  -V "\"SYSRESCUE_TB_1203\"" \
  $(cat "$MKOPTS_FILE") \
  -graft-points "\"/=$ISO_DIR\""

# Validación: solo éxito si existe el fichero
if [[ ! -f "$ISO_OUT" ]]; then
  echo "ERROR: xorriso no generó la ISO de salida."
  exit 1
fi

echo "✅ ISO generada: $ISO_OUT"
sha256sum "$ISO_OUT" | tee "${ISO_OUT}.sha256"

echo "[+] Creando/poblando DAT de persistencia: $DAT_OUT"

[[ "$DAT_OUT" == *.dat ]] || {
  echo "ERROR: DAT_OUT no parece un .dat: $DAT_OUT"
  exit 1
}

if [[ "$CLEAN_DAT" == true && -f "$DAT_OUT" ]]; then
  echo "  - --clean activo: recreando $DAT_OUT"
  rm -f "$DAT_OUT"
fi

if [[ ! -f "$DAT_OUT" ]]; then
  echo "  - Creando archivo de ${DAT_SIZE_MB}MB"
  dd if=/dev/zero of="$DAT_OUT" bs=1M count="$DAT_SIZE_MB" status=progress
  mkfs.ext4 -F -L "$DAT_LABEL" "$DAT_OUT" >/dev/null
else
  echo "  - DAT ya existe, se conserva contenido"
fi

sudo mkdir -p "$DAT_MNT"
sudo mount -o loop "$DAT_OUT" "$DAT_MNT"

sudo mkdir -p "$DAT_MNT/env" "$DAT_MNT/logs" "$DAT_MNT/state"
sudo cp -f "$OVERLAY_DIR/opt/testbench/config.env" "$DAT_MNT/env/config.env"
sudo chmod -R 755 "$DAT_MNT/env" "$DAT_MNT/logs" "$DAT_MNT/state" || true

sudo sync
sudo umount "$DAT_MNT"

echo "DAT listo: $DAT_OUT"

