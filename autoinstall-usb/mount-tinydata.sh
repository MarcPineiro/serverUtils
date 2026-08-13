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

# Logs on the workstation live under the mounted TINYDATA partition itself
# (tce/logs/), never under the build host's own /etc/sysconfig/tcedir --
# that path only resolves inside a booted Tiny Core system (agent-plan
# Phase 1: "Correct mount-tinydata.sh so it lists logs from the mountpoint
# it actually mounted").
echo "[+] OK. Logs en: $MNT/tce/logs/"
ls -la "$MNT/tce/logs" 2>/dev/null || true
