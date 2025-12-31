#!/usr/bin/env bash
set -euo pipefail

LABEL="${1:-TINYDATA}"
MNT_BASE="${2:-/mnt}"
MNT="$MNT_BASE/$LABEL"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: ejecútame con sudo" >&2
  exit 1
fi

if mountpoint -q "$MNT"; then
  echo "[+] Desmontando $MNT ..."
  umount "$MNT"
  echo "[+] OK"
else
  echo "[*] No está montado: $MNT"
fi
