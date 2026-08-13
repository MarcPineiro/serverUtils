#!/usr/bin/env bash
set -euo pipefail

# Uso:
#   ./tcz/fetch-tcz.sh --onboot ./tcz/onboot.lst --out ./tcz-cache/tce
#
# By default --tc/--arch/--mirror are read from tcz/pinned-version.json
# (agent-plan Phase 1: "Pin Tiny Core version and extension checksums in a
# manifest"); pass --tc/--arch/--mirror explicitly to override the pin.
#
# Resultado:
#   ./tcz-cache/tce/onboot.lst
#   ./tcz-cache/tce/optional/*.tcz (+ .dep/.md5 si existen)
#   ./tcz-cache/tce/manifest.json  (sha256 per package + pinned tc/arch/mirror;
#                                    consumed by build-tinycore-usb.sh before
#                                    copying any cached package to a USB)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/functions.sh
source "$ROOT_DIR/lib/functions.sh"

ONBOOT=""
OUT=""
TC_MAJOR=""
ARCH=""
MIRROR=""
PIN_FILE="$ROOT_DIR/tcz/pinned-version.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --onboot) ONBOOT="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --tc) TC_MAJOR="$2"; shift 2;;
    --arch) ARCH="$2"; shift 2;;
    --mirror) MIRROR="$2"; shift 2;;
    --pin-file) PIN_FILE="$2"; shift 2;;
    -h|--help)
      cat <<EOF
Usage:
  $0 --onboot ./tcz/onboot.lst --out ./tcz-cache/tce [--tc 16] [--arch x86_64] [--mirror https://tinycorelinux.net] [--pin-file tcz/pinned-version.json]

Defaults for --tc/--arch/--mirror come from --pin-file when not given explicitly.
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
have jq || die "Need jq (to read $PIN_FILE and write manifest.json)"

if [[ -z "$TC_MAJOR" || -z "$ARCH" || -z "$MIRROR" ]]; then
  [[ -f "$PIN_FILE" ]] || die "No --tc/--arch/--mirror given and pin file missing: $PIN_FILE"
  [[ -z "$TC_MAJOR" ]] && TC_MAJOR="$(jq -r '.tc_major' "$PIN_FILE")"
  [[ -z "$ARCH" ]] && ARCH="$(jq -r '.arch' "$PIN_FILE")"
  [[ -z "$MIRROR" ]] && MIRROR="$(jq -r '.mirror' "$PIN_FILE")"
fi
[[ -n "$TC_MAJOR" && "$TC_MAJOR" != "null" ]] || die "Could not resolve tc_major from $PIN_FILE"
[[ -n "$ARCH" && "$ARCH" != "null" ]] || die "Could not resolve arch from $PIN_FILE"
[[ -n "$MIRROR" && "$MIRROR" != "null" ]] || die "Could not resolve mirror from $PIN_FILE"

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

  # Verify against the upstream md5 sidecar when it was fetched (global
  # safety rule #6: pinned checksum before use). A missing sidecar is not
  # fatal (some mirrors omit it), but a mismatching one is.
  if [[ -s "$OUT/optional/$ext.md5.txt" ]]; then
    expected_md5="$(awk '{print $1}' "$OUT/optional/$ext.md5.txt")"
    actual_md5="$(md5sum "$OUT/optional/$ext" | awk '{print $1}')"
    [[ "$expected_md5" == "$actual_md5" ]] || die "Checksum mismatch for $ext: expected $expected_md5, got $actual_md5"
  fi

  # deps recursivas
  if [[ -s "$OUT/optional/$ext.dep" ]]; then
    while IFS= read -r dep; do
      dep="$(norm "$dep" || true)"
      [[ -n "$dep" && -z "${seen[$dep]:-}" ]] && queue+=("$dep")
    done < "$OUT/optional/$ext.dep"
  fi
done

# Emit a self-consistent manifest (sha256 computed from what actually landed
# on disk, not merely re-stating the upstream md5) so build-tinycore-usb.sh
# can verify cached packages before copying them onto any USB.
manifest="$OUT/manifest.json"
{
  echo "{"
  echo "  \"tc_major\": $(jq -Rn --arg v "$TC_MAJOR" '$v'),"
  echo "  \"arch\": $(jq -Rn --arg v "$ARCH" '$v'),"
  echo "  \"mirror\": $(jq -Rn --arg v "$MIRROR" '$v'),"
  echo "  \"generated_at\": $(jq -Rn --arg v "$(date -Iseconds)" '$v'),"
  echo "  \"packages\": ["
  first=1
  shopt -s nullglob
  for f in "$OUT/optional"/*.tcz; do
    name="$(basename "$f")"
    sha="$(sha256_file "$f")"
    [[ "$first" -eq 1 ]] || echo ","
    first=0
    printf '    {"name": %s, "sha256": %s}' "$(jq -Rn --arg v "$name" '$v')" "$(jq -Rn --arg v "$sha" '$v')"
  done
  shopt -u nullglob
  echo ""
  echo "  ]"
  echo "}"
} >"$manifest"
jq empty "$manifest" || die "Generated manifest is not valid JSON: $manifest"

echo "[+] Done. Total downloaded: $(ls -1 "$OUT/optional"/*.tcz 2>/dev/null | wc -l)"
echo "[+] Manifest: $manifest"

