#!/bin/sh
TCE_DIR="/etc/sysconfig/tcedir"
LOG_DIR="$TCE_DIR/logs"
STATE_DIR="$TCE_DIR/state"

mkdir -p "$LOG_DIR" "$STATE_DIR"
exec >>"$LOG_DIR/bootlocal.log" 2>&1
set -x

echo "$(date -Iseconds) bootlocal START" > "$STATE_DIR/bootlocal.started"

# Esperar red sin iproute2 (busybox route)
i=0
while [ "$i" -lt 25 ]; do
  route -n | grep -q '^0.0.0.0' && break
  sleep 1
  i=$((i+1))
done

# Cargar extensiones listadas en onboot.lst (offline si existen, online si no)
if [ -f "$TCE_DIR/onboot.lst" ]; then
  while read -r ext; do
    ext="${ext%%#*}"
    ext="$(echo "$ext" | tr -d '\r' | xargs)"
    [ -z "$ext" ] && continue
    case "$ext" in *.tcz) ;; *) ext="${ext}.tcz" ;; esac

    if [ -f "$TCE_DIR/optional/$ext" ]; then
      tce-load -i "$TCE_DIR/optional/$ext" || echo "Failed local: $ext"
    else
      # si hay red, intenta descargar e instalar
      tce-load -wi "$ext" || echo "Failed download: $ext"
    fi
  done < "$TCE_DIR/onboot.lst"
fi

# Lanzar autorun con marca persistente
if [ -x /opt/autorun/autoprov-run.sh ]; then
  echo "$(date -Iseconds) autorun START" > "$STATE_DIR/autorun.started"
  /opt/autorun/autoprov-run.sh >>"$LOG_DIR/autoprov.log" 2>&1
  rc=$?
  echo "$(date -Iseconds) autorun END rc=$rc" > "$STATE_DIR/autorun.finished"
fi

echo "$(date -Iseconds) bootlocal END" > "$STATE_DIR/bootlocal.finished"
