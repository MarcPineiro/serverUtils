#!/usr/bin/env bash
set -euo pipefail

LABEL="${1:-TINYDATA}"
MNT_BASE="${2:-/mnt}"
MNT="$MNT_BASE/$LABEL"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: ejecútame con sudo" >&2
  exit 1
fi

DEV="$(blkid -L "$LABEL" || true)"
if [[ -z "$DEV" ]]; then
  echo "ERROR: no encuentro ninguna partición con LABEL=$LABEL" >&2
  echo "Pistas:" >&2
  echo "  lsblk -f" >&2
  echo "  sudo blkid" >&2
  exit 1
fi

mkdir -p "$MNT"

# Ya montada?
if mountpoint -q "$MNT"; then
  echo "[*] Ya está montada en $MNT ($DEV)"
  exit 0
fi

echo "[+] Montando $DEV en $MNT ..."
mount "$DEV" "$MNT"

echo "[+] OK. Logs en: /etc/sysconfig/tcedir/logs/"
ls -la "/etc/sysconfig/tcedir/logs" 2>/dev/null || true
