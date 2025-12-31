#!/usr/bin/env bash
set -euo pipefail

# Uso:
#   ./tcz/fetch-tcz.sh --onboot ./tcz/onboot.lst --out ./tcz-cache/tce --tc 16 --arch x86_64
#
# Resultado:
#   ./tcz-cache/tce/onboot.lst
#   ./tcz-cache/tce/optional/*.tcz (+ .dep/.md5 si existen)

die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

ONBOOT=""
OUT=""
TC_MAJOR="16"
ARCH="x86_64"
MIRROR="http://tinycorelinux.net"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --onboot) ONBOOT="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --tc) TC_MAJOR="$2"; shift 2;;
    --arch) ARCH="$2"; shift 2;;
    --mirror) MIRROR="$2"; shift 2;;
    -h|--help)
      cat <<EOF
Usage:
  $0 --onboot ./tcz/onboot.lst --out ./tcz-cache/tce [--tc 16] [--arch x86_64] [--mirror https://tinycorelinux.net]
EOF
      exit 0
      ;;
    *) die "Unknown arg: $1";;
  esac
done

[[ -f "$ONBOOT" ]] || die "Missing --onboot file: $ONBOOT"
[[ -n "$OUT" ]] || die "Missing --out"
mkdir -p "$OUT/optional"

have curl || have wget || die "Need curl or wget"

BASE="${MIRROR%/}/${TC_MAJOR}.x/${ARCH}/tcz"

download() {
  local url="$1" dst="$2"
  if have curl; then
    curl -fsSL --retry 3 --connect-timeout 10 -o "$dst" "$url"
  else
    wget -q --tries=3 --timeout=10 -O "$dst" "$url"
  fi
}

norm() {
  local x="$1"
  x="${x//$'\r'/}"
  x="$(echo "$x" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -z "$x" ]] && return 1
  [[ "$x" == \#* ]] && return 1
  [[ "$x" == *.tcz ]] || x="${x}.tcz"
  echo "$x"
}

declare -A seen=()
queue=()

# Copiamos onboot.lst “limpio” al OUT (para tener el bundle completo)
awk '{
  gsub(/\r/,"");
  if ($0 ~ /^[[:space:]]*$/) next;
  if ($0 ~ /^[[:space:]]*#/) next;
  print $0;
}' "$ONBOOT" > "$OUT/onboot.lst"

while IFS= read -r line; do
  ext="$(norm "$line" || true)"
  [[ -n "$ext" ]] && queue+=("$ext")
done < "$OUT/onboot.lst"

echo "[+] Repo: $BASE"
echo "[+] Output: $OUT/optional"

while ((${#queue[@]} > 0)); do
  ext="${queue[0]}"
  queue=("${queue[@]:1}")

  [[ -n "${seen[$ext]:-}" ]] && continue
  seen["$ext"]=1

  echo "[+] Download $ext"
  download "$BASE/$ext" "$OUT/optional/$ext" || die "Failed: $BASE/$ext"

  # sidecars opcionales
  download "$BASE/$ext.dep" "$OUT/optional/$ext.dep" 2>/dev/null || true
  download "$BASE/$ext.md5.txt" "$OUT/optional/$ext.md5.txt" 2>/dev/null || true

  # deps recursivas
  if [[ -s "$OUT/optional/$ext.dep" ]]; then
    while IFS= read -r dep; do
      dep="$(norm "$dep" || true)"
      [[ -n "$dep" && -z "${seen[$dep]:-}" ]] && queue+=("$dep")
    done < "$OUT/optional/$ext.dep"
  fi
done

echo "[+] Done. Total downloaded: $(ls -1 "$OUT/optional"/*.tcz 2>/dev/null | wc -l)"
