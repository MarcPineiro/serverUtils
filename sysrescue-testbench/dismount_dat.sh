#!/usr/bin/env bash
set -euo pipefail

MNT="${1:-/mnt/persist}"

if ! mountpoint -q "$MNT"; then
  echo "No está montado: $MNT"
  exit 0
fi

# Salir del directorio si estás dentro
if [[ "$(pwd)" == "$MNT"* ]]; then
  cd /
fi

sudo sync

# Intento normal
if sudo umount "$MNT"; then
  echo "✅ Desmontado: $MNT"
  exit 0
fi

echo "⚠️  Está ocupado. Mostrando procesos que lo usan:"
sudo fuser -vm "$MNT" || true

echo "Puedes cerrar terminales/editores que estén usando $MNT y reintentar."
echo "Si quieres forzar (seguro): sudo umount -l $MNT"
exit 1
