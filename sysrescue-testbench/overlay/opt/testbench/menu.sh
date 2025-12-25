#!/usr/bin/env bash
set -u
set -o pipefail

# shellcheck disable=SC1091
source /opt/testbench/lib/common.sh
# shellcheck disable=SC1091
source /opt/testbench/lib/tests.sh

LOGROOT="$(init_logs)"
load_config

exec > >(tee -a "$LOGROOT/console.log") 2>&1
exec </dev/tty >/dev/tty 2>&1

banner "SystemRescue TestBench — MENÚ"
echo "Logs: $LOGROOT"
echo "Config: TEST_LEVEL=$TEST_LEVEL CPU_MINUTES=$CPU_MINUTES RAM_MINUTES=$RAM_MINUTES FIO=${DISK_FIO_SIZE}/${DISK_FIO_MINUTES}m"
echo "EXCLUDE_DISKS='$EXCLUDE_DISKS'  ALLOW_DESTRUCTIVE=$ALLOW_DESTRUCTIVE"
echo

show_destructive_menu() {
  [[ "${ALLOW_DESTRUCTIVE:-0}" == "1" ]]
}

while true; do
  echo
  echo "1) Inventario + Sensores"
  echo "2) Discos: tamaño vs firmware + SMART"
  echo "3) CPU stress"
  echo "4) RAM/IMC stress"
  echo "5) Disco: fio seguro"
  echo "6) Full test"

  if show_destructive_menu; then
    echo "7) Verificar capacidad real (DESTRUCTIVO: escribe al final)"
  fi

  echo "0) Salir"
  echo
  read -r opt < /dev/tty1

  if [[ -z "${opt:-}" ]]; then
    echo "[INFO] Entrada vacía, esperando..." 
    sleep 1
    continue
  fi

  case "$opt" in
    1)
      write_system_inventory "$LOGROOT"
      write_sensors "$LOGROOT"
      ;;
    2)
      disk_reports_all "$LOGROOT"
      ;;
    3)
      cpu_stress "$LOGROOT"
      ;;
    4)
      ram_stress "$LOGROOT"
      ;;
    5)
      fio_safe "$LOGROOT"
      ;;
    6)
      write_system_inventory "$LOGROOT"
      write_sensors "$LOGROOT"
      disk_reports_all "$LOGROOT"
      cpu_stress "$LOGROOT"
      ram_stress "$LOGROOT"
      fio_safe "$LOGROOT"
      final_report "$LOGROOT"
      ;;
    7)
      if show_destructive_menu; then
        disk_verify_real_capacity_selective "$LOGROOT"
      else
        echo "[DENY] Opción destructiva deshabilitada (ALLOW_DESTRUCTIVE=0)."
      fi
      ;;
    0) exit 0 ;;
    *) echo "Opción inválida" ;;
  esac

  echo
  echo "[INFO] Terminado. Logs en: $LOGROOT"
done
