#!/bin/sh
# /opt/bootlocal.sh
#
# The single authoritative Tiny Core boot entrypoint (agent-plan Phase 1:
# "Replace the two potential launch paths with one authoritative path").
# Tiny Core's base system runs this script automatically at the end of boot;
# no /etc/rc.d or /etc/init.d hook is needed or shipped by this overlay --
# a prior duplicate (S99autoprov / etc/init.d/autoprov) has been removed.
# The actual run-once/lock/retry logic lives in autoprov-run.sh itself, so
# it stays safe even if something else invokes it a second time.
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

# Provisioning: autoprov-run.sh owns its own started/running/downloaded/
# succeeded/failed state files and its own boot lock; bootlocal.sh only
# needs to know its overall exit code for bootlocal.log.
if [ -x /opt/autorun/autoprov-run.sh ]; then
  /opt/autorun/autoprov-run.sh
  rc=$?
  echo "$(date -Iseconds) autoprov-run.sh rc=$rc"
fi

echo "$(date -Iseconds) bootlocal END" > "$STATE_DIR/bootlocal.finished"
