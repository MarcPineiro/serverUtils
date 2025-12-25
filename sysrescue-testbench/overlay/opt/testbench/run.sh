#!/usr/bin/env bash
set -u
set -o pipefail

# shellcheck disable=SC1091
source /opt/testbench/lib/common.sh
# shellcheck disable=SC1091
source /opt/testbench/lib/tests.sh

LOGROOT="$(init_logs)"
load_config

# Ahora TODO lo que se imprima irá a pantalla y a console.log
exec > >(tee -a "$LOGROOT/console.log") 2>&1

echo "Logs: $LOGROOT"
echo "Config: TEST_LEVEL=$TEST_LEVEL CPU_MINUTES=$CPU_MINUTES RAM_MINUTES=$RAM_MINUTES FIO=${DISK_FIO_SIZE}/${DISK_FIO_MINUTES}m"
echo "EXCLUDE_DISKS='$EXCLUDE_DISKS'  ALLOW_DESTRUCTIVE=$ALLOW_DESTRUCTIVE"
echo

if menu_requested; then
  exec /opt/testbench/menu.sh
fi

write_system_inventory "$LOGROOT"
write_sensors "$LOGROOT"
disk_reports_all "$LOGROOT"
cpu_stress "$LOGROOT"
ram_stress "$LOGROOT"
fio_safe "$LOGROOT"
# Destructivo al final (solo si ALLOW_DESTRUCTIVE=1)
if [[ "${ALLOW_DESTRUCTIVE:-0}" == "1" ]]; then
  if [[ "${AUTO_DESTRUCTIVE_CONFIRM:-0}" == "1" ]]; then
    # Destructivo AUTOMÁTICO solo si esta variable está puesta explícitamente
    disk_verify_real_capacity_all "$LOGROOT"
  else
    echo "[SKIP] Test destructivo NO ejecutado en autorun (AUTO_DESTRUCTIVE_CONFIRM=0)"
  fi
fi
final_report "$LOGROOT"

banner "FIN — Revisa: $LOGROOT/summary.txt"
