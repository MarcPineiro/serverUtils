#!/usr/bin/env bash
set -u
set -o pipefail
# shellcheck disable=SC1091
source /opt/testbench/lib/common.sh

# Helper: log a fichero + consola con tee
run_and_tee() {
  # Uso: run_and_tee "titulo" "file.log" comando...
  local title="$1"; shift
  local logfile="$1"; shift
  banner "$title"
  echo "[INFO] Log: $logfile"
  echo "[INFO] Cmd: $*"
  echo
  # Importante: no matar el flujo si falla un comando
  "$@" 2>&1 | tee -a "$logfile"
  return 0
}

write_system_inventory() {
  local out="$1"
  local f="$out/system_inventory.txt"
  banner "Inventario"
  echo "[INFO] Escribiendo: $f"
  {
    echo "=== OS ==="
    . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || true
    echo
    echo "=== uname -a ==="
    uname -a || true
    echo
    echo "=== lscpu ==="
    lscpu || true
    echo
    echo "=== free -h ==="
    free -h || true
    echo
    echo "=== lsblk ==="
    lsblk -o NAME,TYPE,SIZE,MODEL,SERIAL,TRAN,ROTA,MOUNTPOINTS || true
    echo
    echo "=== lspci -nn ==="
    lspci -nn || true
    echo
    echo "=== dmesg tail ==="
    dmesg | tail -n 200 || true
  } 2>&1 | tee -a "$f"
  echo "[OK] Inventario generado"
}

write_sensors() {
  local out="$1"
  local f="$out/sensors.txt"
  banner "Sensores"
  echo "[INFO] Escribiendo: $f"
  if have sensors; then
    sensors 2>&1 | tee -a "$f" || true
  else
    echo "sensors no disponible" | tee -a "$f"
  fi
  echo "[OK] Sensores"
}

disk_size_kernel_bytes() {
  local dev="$1" base sectors
  base="$(basename "$dev")"
  sectors="$(cat "/sys/block/$base/size" 2>/dev/null || echo 0)"
  echo $((sectors * 512))
}

disk_identity_report_one() {
  local dev="$1" out="$2" base f
  base="$(basename "$dev")"
  f="$out/disk_${base}_identity.txt"

  banner "Disco: $dev (tamaño real vs firmware + SMART)"
  echo "[INFO] Escribiendo: $f"

  {
    echo "Device: $dev"
    echo "Kernel size bytes: $(disk_size_kernel_bytes "$dev")"
    echo
    echo "lsblk -b:"
    lsblk -b -o NAME,SIZE,TYPE,MODEL,SERIAL,TRAN,ROTA,LOG-SEC,PHY-SEC "$dev" || true
    echo

    if [[ "$base" == nvme* ]] && have nvme; then
      echo "nvme id-ctrl:"
      nvme id-ctrl "$dev" || true
      echo
      echo "nvme id-ns:"
      nvme id-ns "$dev" || true
      echo
      echo "nvme smart-log:"
      nvme smart-log "$dev" || true
      echo
    fi

    if have smartctl; then
      echo "smartctl -i:"
      smartctl -i "$dev" || true
      echo
      echo "smartctl -a:"
      smartctl -a "$dev" || true
    else
      echo "smartctl no disponible"
    fi
  } 2>&1 | tee -a "$f"

  echo "[OK] Disco report: $dev"
}

list_block_devs() {
  lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}'
}

disk_reports_all() {
  local out="$1"
  banner "Discos: report para todos"
  for d in $(list_block_devs); do
    is_excluded "$d" && { echo "[SKIP] /dev/$d (EXCLUDE_DISKS)"; continue; }
    disk_identity_report_one "/dev/$d" "$out"
  done
  echo "[OK] Discos report"
}

cpu_stress() {
  local out="$1"
  local f="$out/cpu_stress.txt"
  local minutes="$CPU_MINUTES"

  banner "CPU stress"
  echo "[INFO] Duración: ${minutes}m"
  echo "[INFO] Escribiendo: $f"

  if have stress-ng; then
    run_and_tee "stress-ng CPU" "$f" \
      stress-ng --cpu "$(nproc)" --cpu-method matrixprod --metrics-brief --timeout "${minutes}m"
    echo "[OK] CPU stress (stress-ng) terminado"
    return 0
  fi

  local tools; tools="$(tools_dir)"
  if [[ -x "$tools/y-cruncher/y-cruncher" ]]; then
    run_and_tee "y-cruncher" "$out/cpu_ycruncher.txt" \
      "$tools/y-cruncher/y-cruncher" bench 0
    echo "[OK] CPU stress (y-cruncher) terminado"
    return 0
  fi

  echo "[WARN] No hay stress-ng ni y-cruncher. CPU stress no ejecutado." | tee -a "$f"
  return 0
}

ram_stress() {
  local out="$1"
  local minutes="$RAM_MINUTES"
  banner "RAM/IMC stress"
  echo "[INFO] Duración: ${minutes}m"

  if have stressapptest; then
    run_and_tee "stressapptest" "$out/ram_stressapptest.txt" \
      stressapptest -W -s $((minutes*60))
    echo "[OK] RAM stress (stressapptest) terminado"
    return 0
  fi

  local tools; tools="$(tools_dir)"
  if [[ -x "$tools/stressapptest/stressapptest" ]]; then
    run_and_tee "stressapptest (tools)" "$out/ram_stressapptest.txt" \
      "$tools/stressapptest/stressapptest" -W -s $((minutes*60))
    echo "[OK] RAM stress (stressapptest tools) terminado"
    return 0
  fi

  if have stress-ng; then
    run_and_tee "stress-ng VM verify" "$out/ram_stressng_vm.txt" \
      stress-ng --vm 2 --vm-bytes 75% --verify --metrics-brief --timeout "${minutes}m"
    echo "[OK] RAM stress (stress-ng) terminado"
    return 0
  fi

  echo "[WARN] No hay stressapptest ni stress-ng. RAM stress no ejecutado." | tee -a "$out/ram_missing.txt"
  return 0
}

fio_safe() {
  local out="$1"
  local minutes="$DISK_FIO_MINUTES" size="$DISK_FIO_SIZE"
  banner "Disco: fio seguro (archivo)"
  echo "[INFO] Duración: ${minutes}m  Size: $size"

  if ! have fio; then
    echo "[WARN] fio no disponible" | tee -a "$out/disk_fio_missing.txt"
    return 0
  fi

  local base_dir="/tmp/testbench-tmp"
  if [[ -d /run/archiso/bootmnt && -w /run/archiso/bootmnt ]]; then
    base_dir="/run/archiso/bootmnt/testbench/tmp"
  fi
  mkdir -p "$base_dir"
  local file="$base_dir/fio_testfile.bin"

  run_and_tee "fio randrw" "$out/disk_fio_randrw.txt" \
    fio --name=randrw --filename="$file" --size="$size" --rw=randrw --rwmixread=70 \
        --bs=4k --iodepth=32 --numjobs=4 --direct=1 --time_based --runtime $((minutes*60)) \
        --group_reporting

  rm -f "$file" || true
  echo "[OK] FIO terminado"
}

final_report() {
  local out="$1"
  local f="$out/summary.txt"
  banner "Resumen"
  echo "[INFO] Escribiendo: $f"

  {
    echo "== Report $(ts) =="
    echo
    echo "== Errores relevantes dmesg =="
    dmesg | egrep -i "error|fail|mce|machine check|I/O error|nvme|ata.*error|reset|timeout" | tail -n 200 || true
    echo
    echo "== Discos =="
    lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,ROTA || true
  } 2>&1 | tee -a "$f"

  echo "[OK] Resumen generado"
}

disk_type() {
  local dev="$1" base rota tran
  base="$(basename "$dev")"
  if [[ "$base" == nvme* ]]; then
    echo "nvme"
    return 0
  fi
  rota="$(cat "/sys/block/$base/queue/rotational" 2>/dev/null || echo "")"
  tran="$(lsblk -dn -o TRAN "$dev" 2>/dev/null | head -n1 || true)"
  if [[ "$rota" == "1" ]]; then
    echo "hdd${tran:+ ($tran)}"
  elif [[ "$rota" == "0" ]]; then
    echo "ssd${tran:+ ($tran)}"
  else
    echo "disk${tran:+ ($tran)}"
  fi
}

# Test destructivo mínimo para detectar capacidad maquillada:
# - lee último LBA
# - escribe/verifica los últimos TAIL_VERIFY_MIB MiB
# - opcional: RANDOM_TAIL_SAMPLES lecturas/escrituras en el último % del disco
disk_verify_real_capacity() {
  local dev="$1" out="$2"
  local base f dtype sectors last tail_mib cnt start
  base="$(basename "$dev")"
  f="$out/disk_${base}_capacity_verify.txt"
  dtype="$(disk_type "$dev")"

  banner "Verify real capacity — $dev [$dtype]"
  echo "[INFO] Log: $f" | tee -a "$f"

  if [[ "${ALLOW_DESTRUCTIVE:-0}" != "1" ]]; then
    echo "[SKIP] ALLOW_DESTRUCTIVE=0 (este test escribe al final del disco)" | tee -a "$f"
    return 0
  fi

  # Info adicional NVMe (solo evidencia, no imprescindible)
  if [[ "$dtype" == "nvme" ]] && have nvme; then
    echo "[INFO] nvme id-ctrl/id-ns (evidencia firmware/capacidad declarada)" | tee -a "$f"
    nvme id-ctrl "$dev" 2>&1 | tee -a "$f" || true
    nvme id-ns "$dev" 2>&1 | tee -a "$f" || true
  fi

  sectors="$(cat "/sys/block/$base/size" 2>/dev/null || echo 0)"
  if [[ "$sectors" -le 0 ]]; then
    echo "[ERR] No pude leer /sys/block/$base/size" | tee -a "$f"
    return 0
  fi
  last=$((sectors-1))
  echo "[INFO] sectors=$sectors last_lba=$last (512B sectors)" | tee -a "$f"
  echo "[INFO] lsblk -b:" | tee -a "$f"
  lsblk -b -o NAME,SIZE,MODEL,SERIAL,TRAN,ROTA,LOG-SEC,PHY-SEC "$dev" 2>&1 | tee -a "$f" || true

  echo "[STEP] Leer último sector (no destructivo)..." | tee -a "$f"
  if dd if="$dev" of=/dev/null bs=512 skip="$last" count=1 iflag=direct status=none 2>>"$f"; then
    echo "[OK] Último sector LEÍDO correctamente" | tee -a "$f"
  else
    echo "[FAIL] No se puede leer el último sector -> posible capacidad falsa o disco defectuoso" | tee -a "$f"
    return 0
  fi

  tail_mib="${TAIL_VERIFY_MIB:-64}"      # 8/16/64 recomendado
  cnt=$((tail_mib*1024*1024/512))
  if [[ "$cnt" -le 0 || "$cnt" -ge "$sectors" ]]; then
    echo "[ERR] TAIL_VERIFY_MIB inválido: $tail_mib" | tee -a "$f"
    return 0
  fi
  start=$((sectors-cnt))

  echo "[WARN] SOBREESCRIBIENDO los últimos ${tail_mib}MiB de $dev" | tee -a "$f"
  echo "[STEP] Escribiendo patrón aleatorio al final..." | tee -a "$f"
  if dd if=/dev/urandom of="$dev" bs=512 seek="$start" count="$cnt" oflag=direct conv=fsync status=progress 2>>"$f"; then
    echo "[OK] Escritura tail completada" | tee -a "$f"
  else
    echo "[FAIL] Error escribiendo cerca del final -> fuerte indicio de capacidad maquillada" | tee -a "$f"
    return 0
  fi

  echo "[STEP] Leyendo tail de vuelta y hasheando..." | tee -a "$f"
  rm -f /tmp/testbench_tail_verify.bin 2>/dev/null || true
  if dd if="$dev" of=/tmp/testbench_tail_verify.bin bs=512 skip="$start" count="$cnt" iflag=direct status=progress 2>>"$f"; then
    sha256sum /tmp/testbench_tail_verify.bin 2>&1 | tee -a "$f"
    echo "[OK] Lectura tail OK (no veo wrap/error en el final)" | tee -a "$f"
  else
    echo "[FAIL] Error leyendo tail -> posible capacidad falsa o disco defectuoso" | tee -a "$f"
    return 0
  fi

  # Opcional: muestras aleatorias en el último % (detecta wrap en algunos fakes)
  local samples="${RANDOM_TAIL_SAMPLES:-0}"
  local tail_pct="${RANDOM_TAIL_PERCENT:-10}"
  if [[ "$samples" -gt 0 ]]; then
    echo "[STEP] Muestras aleatorias: $samples en el último ${tail_pct}% (destructivo mínimo)" | tee -a "$f"
    local tail_start=$((sectors - (sectors*tail_pct/100)))
    local i off blocks
    blocks=$((4*1024*1024/512))  # 4MiB por muestra
    for i in $(seq 1 "$samples"); do
      off=$(( tail_start + (RANDOM % (sectors - tail_start - blocks)) ))
      echo "  [SAMPLE $i] offset_sector=$off (4MiB)" | tee -a "$f"
      dd if=/dev/urandom of="$dev" bs=512 seek="$off" count="$blocks" oflag=direct conv=fsync status=none 2>>"$f" || {
        echo "  [FAIL] write sample $i" | tee -a "$f"; return 0; }
      dd if="$dev" of=/dev/null bs=512 skip="$off" count="$blocks" iflag=direct status=none 2>>"$f" || {
        echo "  [FAIL] read sample $i" | tee -a "$f"; return 0; }
    done
    echo "[OK] Muestras aleatorias OK" | tee -a "$f"
  fi

  echo "[DONE] Capacity verify terminado" | tee -a "$f"
}

disk_verify_real_capacity_all() {
  local out="$1"
  local d
  local targets=()

  banner "Verify real capacity (DESTRUCTIVE) — ALL DISKS"
  echo "[WARN] Este test sobreescribe el final de cada disco (TAIL_VERIFY_MIB=${TAIL_VERIFY_MIB:-64}MiB)."
  echo "[WARN] Respeta EXCLUDE_DISKS='$EXCLUDE_DISKS'"
  echo "[WARN] TOTALMENTE DESTRUCTIVO en los discos seleccionados."
  echo

  if [[ "${ALLOW_DESTRUCTIVE:-0}" != "1" ]]; then
    echo "[SKIP] ALLOW_DESTRUCTIVE=0" | tee -a "$out/disk_capacity_verify_skipped.txt"
    return 0
  fi

  # Construir lista real de discos afectados
  for d in $(list_block_devs); do
    if is_excluded "$d"; then
      echo "[SKIP] /dev/$d (EXCLUDE_DISKS)"
    else
      targets+=( "$d" )
    fi
  done

  if [[ "${#targets[@]}" -eq 0 ]]; then
    echo "[INFO] No hay discos para test destructivo."
    return 0
  fi

  echo "Los siguientes discos serán afectados:"
  for d in "${targets[@]}"; do
    echo "   - /dev/$d"
  done
  echo

  # Confirmación:
  # - En menú interactivo: pedir DESTROY
  # - En autorun: permitir sin prompt solo si AUTO_DESTRUCTIVE_CONFIRM=1
  if [[ "${AUTO_DESTRUCTIVE_CONFIRM:-0}" == "1" ]]; then
    echo "[OK] AUTO_DESTRUCTIVE_CONFIRM=1 -> ejecutando sin prompt interactivo."
  else
    echo ">>> CONFIRMACIÓN NECESARIA <<<"
    echo "Para continuar, escribe EXACTAMENTE: DESTROY"
    echo -n "> "
    read -r CONFIRM || true

    if [[ "${CONFIRM:-}" != "DESTROY" ]]; then
      echo "[ABORT] Confirmación incorrecta. No se destruye nada."
      return 0
    fi
  fi

  echo "[OK] Confirmación aceptada. Iniciando pruebas destructivas..."
  echo

  # Ejecutar test en cada disco
  for d in "${targets[@]}"; do
    disk_verify_real_capacity "/dev/$d" "$out"
  done

  echo "[OK] Verify real capacity (DESTRUCTIVE) terminado"
}

# Parse selections like: "1 3 5", "1-3,7", "all"
parse_disk_selection() {
  # args: selection_string max_index
  local sel="$1" max="$2"
  local out=()
  local token a b i

  sel="${sel//,/ }"
  sel="${sel,,}"  # lowercase

  if [[ "$sel" == "all" ]]; then
    for i in $(seq 1 "$max"); do out+=( "$i" ); done
    printf '%s\n' "${out[@]}"
    return 0
  fi

  for token in $sel; do
    if [[ "$token" =~ ^[0-9]+$ ]]; then
      out+=( "$token" )
    elif [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
      if (( a > b )); then
        i="$a"; a="$b"; b="$i"
      fi
      for i in $(seq "$a" "$b"); do out+=( "$i" ); done
    else
      echo "[ERR] Selección inválida: '$token'" >&2
      return 1
    fi
  done

  # validar rango 1..max y deduplicar
  # shellcheck disable=SC2207
  out=( $(printf '%s\n' "${out[@]}" | awk -v max="$max" '
    $1 ~ /^[0-9]+$/ && $1>=1 && $1<=max {print $1}
  ' | sort -n | uniq) )

  if [[ "${#out[@]}" -eq 0 ]]; then
    echo "[ERR] No se seleccionó ningún índice válido." >&2
    return 1
  fi

  printf '%s\n' "${out[@]}"
}

# Selección interactiva de discos (por números) y test destructivo
disk_verify_real_capacity_selective() {
  local out="$1"
  local disks=() i d base dtype size model tran rota
  local selectable_idx=()  # índice -> name (solo no excluidos)
  local idx_to_disk=()     # índice -> diskname (todos)
  local selection raw sel_indexes=()
  local targets=()

  banner "Verify real capacity (DESTRUCTIVE) — SELECTIVE"
  echo "[WARN] Este test SOBREESCRIBE el final del disco (TAIL_VERIFY_MIB=${TAIL_VERIFY_MIB:-64}MiB)."
  echo "[WARN] TOTALMENTE DESTRUCTIVO en los discos seleccionados."
  echo

  if [[ "${ALLOW_DESTRUCTIVE:-0}" != "1" ]]; then
    echo "[SKIP] ALLOW_DESTRUCTIVE=0" | tee -a "$out/disk_capacity_verify_skipped.txt"
    return 0
  fi

  # listar discos
  # shellcheck disable=SC2207
  disks=( $(list_block_devs) )
  if [[ "${#disks[@]}" -eq 0 ]]; then
    echo "[ERR] No se detectaron discos." | tee -a "$out/disk_capacity_verify_error.txt"
    return 0
  fi

  echo "Discos detectados:"
  echo "  # | DEV        | SIZE     | TRAN | ROTA | TYPE     | MODEL"
  echo "----+------------+----------+------+------|----------+-----------------------------"

  i=0
  for d in "${disks[@]}"; do
    i=$((i+1))
    idx_to_disk[$i]="$d"

    base="/dev/$d"
    dtype="$(disk_type "$base")"

    size="$(lsblk -dn -o SIZE "$base" 2>/dev/null | head -n1 || echo "?")"
    tran="$(lsblk -dn -o TRAN "$base" 2>/dev/null | head -n1 || echo "-")"
    rota="$(lsblk -dn -o ROTA "$base" 2>/dev/null | head -n1 || echo "-")"
    model="$(lsblk -dn -o MODEL "$base" 2>/dev/null | sed 's/[[:space:]]\+/ /g' | head -n1 || true)"

    if is_excluded "$d"; then
      printf "  %2d | %-10s | %-8s | %-4s | %-4s | %-8s | %s [EXCLUDED]\n" \
        "$i" "$d" "$size" "${tran:--}" "${rota:--}" "$dtype" "${model:-}"
    else
      printf "  %2d | %-10s | %-8s | %-4s | %-4s | %-8s | %s\n" \
        "$i" "$d" "$size" "${tran:--}" "${rota:--}" "$dtype" "${model:-}"
      selectable_idx+=( "$i" )
    fi
  done

  if [[ "${#selectable_idx[@]}" -eq 0 ]]; then
    echo "[INFO] Todos los discos están excluidos (EXCLUDE_DISKS). Nada que hacer."
    return 0
  fi

  echo
  echo "Selecciona discos por número (ejemplos: '1 3 4' o '1-3,5' o 'all')."
  echo "OJO: 'all' selecciona TODOS los que NO están excluidos."
  echo -n "> "
  read -r raw || true
  raw="${raw:-}"

  if [[ -z "$raw" ]]; then
    echo "[ABORT] Sin selección. No se destruye nada."
    return 0
  fi

  # parse índices con límite = número total de discos
  if ! mapfile -t sel_indexes < <(parse_disk_selection "$raw" "${#disks[@]}"); then
    echo "[ABORT] Selección inválida."
    return 0
  fi

  # construir targets, respetando EXCLUDE_DISKS
  for i in "${sel_indexes[@]}"; do
    d="${idx_to_disk[$i]}"
    [[ -z "${d:-}" ]] && continue
    if is_excluded "$d"; then
      echo "[SKIP] /dev/$d (EXCLUDE_DISKS)"
      continue
    fi
    targets+=( "$d" )
  done

  if [[ "${#targets[@]}" -eq 0 ]]; then
    echo "[ABORT] No quedó ningún disco seleccionable tras aplicar EXCLUDE_DISKS."
    return 0
  fi

  echo
  echo "Vas a ejecutar el test destructivo en:"
  for d in "${targets[@]}"; do
    echo "   - /dev/$d"
  done
  echo

  echo ">>> CONFIRMACIÓN NECESARIA <<<"
  echo "Para continuar, escribe EXACTAMENTE: DESTROY"
  echo -n "> "
  read -r CONFIRM || true

  if [[ "${CONFIRM:-}" != "DESTROY" ]]; then
    echo "[ABORT] Confirmación incorrecta. No se destruye nada."
    return 0
  fi

  echo "[OK] Confirmación aceptada. Iniciando..."
  echo

  for d in "${targets[@]}"; do
    disk_verify_real_capacity "/dev/$d" "$out"
  done

  echo "[OK] Verify real capacity (DESTRUCTIVE) terminado"
}
