#!/usr/bin/env bash
set -u
set -o pipefail

banner() {
  echo
  echo "================================================================"
  echo "$*"
  echo "================================================================"
}

ts() { date +"%Y-%m-%d_%H-%M-%S"; }

have() { command -v "$1" >/dev/null 2>&1; }

# En SystemRescue arrancado desde Ventoy esto existe casi siempre
find_bootmnt() {
  if [[ -d /run/archiso/bootmnt ]]; then
    echo "/run/archiso/bootmnt"
    return 0
  fi
  return 1
}

load_config() {
  # Defaults
  TEST_LEVEL="${TEST_LEVEL:-extended}"       # quick|normal|extended
  CPU_MINUTES="${CPU_MINUTES:-60}"
  RAM_MINUTES="${RAM_MINUTES:-90}"
  DISK_FIO_SIZE="${DISK_FIO_SIZE:-10G}"
  DISK_FIO_MINUTES="${DISK_FIO_MINUTES:-15}"
  EXCLUDE_DISKS="${EXCLUDE_DISKS:-}"
  ALLOW_DESTRUCTIVE="${ALLOW_DESTRUCTIVE:-0}"
  TAIL_VERIFY_MIB="${TAIL_VERIFY_MIB:-64}"
  RANDOM_TAIL_SAMPLES="${RANDOM_TAIL_SAMPLES:-0}"
  RANDOM_TAIL_PERCENT="${RANDOM_TAIL_PERCENT:-10}"
  AUTO_DESTRUCTIVE_CONFIRM="${AUTO_DESTRUCTIVE_CONFIRM:-0}"

  mkdir -p /mnt/persist
  mount -L PERSIST /mnt/persist

  # 1) Prefer bootmnt config
  if [[ -f /mnt/persist/config.env ]]; then
    # shellcheck disable=SC1091
    source /mnt/persist/config.env
    return 0
  fi

  # 2) Fallback: local inside ISO
  if [[ -f /opt/testbench/config.env ]]; then
    # shellcheck disable=SC1091
    source /opt/testbench/config.env
    return 0
  fi

  return 0
}

tools_dir() {
  if [[ -d /mnt/persist/tools ]]; then
    echo "/mnt/persist/tools"
  else
    echo "/opt/testbench/tools"
  fi
}

init_logs() {
  HOST="$(hostname 2>/dev/null || echo "unknown-host")"

  # Fuerza guardar SIEMPRE en /mnt/persist
  local base="/mnt/persist/logs"

  if [[ -d /mnt/persist ]]; then
    base="/mnt/persist"
  else
    base="/tmp/testbench-logs"
  fi

  mkdir -p "$base"

  LOGROOT="$base/$HOST/$(1)"
  mkdir -p "$LOGROOT"

  echo "$LOGROOT"
}


# Devuelve 0 si se pulsa tecla y hay que ir a menú
menu_requested() {
  local tty="/dev/tty1"
  if [[ -r "$tty" && -w "$tty" ]]; then
    echo "TestBench: arrancando en 30s… pulsa una tecla para entrar al menú." > "$tty"
    if IFS= read -r -n 1 -t 30 _key < "$tty"; then
      return 0
    fi
  else
    # headless o sin tty1: no bloqueamos
    sleep 1
  fi
  return 1
}

is_excluded() {
  local base="$1"
  for x in $EXCLUDE_DISKS; do
    [[ "$base" == "$x" ]] && return 0
  done
  return 1
}
