#!/usr/bin/env bash
set -euo pipefail

DAT="${1:-./systemrescue-persist.dat}"
MNT="${2:-/mnt/persist}"

[[ -f "$DAT" ]] || { echo "No existe: $DAT"; exit 1; }

sudo mkdir -p "$MNT"

# Evita montarlo dos veces
if mountpoint -q "$MNT"; then
  echo "Ya está montado en $MNT"
  exit 0
fi

sudo mount -o loop "$DAT" "$MNT"
echo "✅ Montado: $DAT -> $MNT"
echo "Contenido:"
ls -la "$MNT"

# Abrir el explorador de archivos si existe (Nautilus)
if command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$MNT" >/dev/null 2>&1 || true
fi
