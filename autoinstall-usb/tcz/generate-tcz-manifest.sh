#!/usr/bin/env bash
set -euo pipefail
#
# tcz/generate-tcz-manifest.sh
#
# Computes a sha256 for every *.tcz found under --dir (and records the
# upstream .md5.txt sidecar's value too, when present, after verifying the
# file against it), then writes a pinned manifest consumed by
# build-tinycore-usb.sh's verify_tcz_checksums() before any package is
# copied onto a USB build. This is how Phase 1's "Pin Tiny Core version and
# extension checksums in a manifest" requirement is satisfied.
#
# Usage:
#   ./tcz/generate-tcz-manifest.sh --dir ./tcz-cache/tce/optional \
#       [--out ./tcz/tcz-manifest.json] [--tc-version 16.x] [--arch x86_64]
#
# Re-run this script whenever tcz-cache/ is refreshed with new/updated
# packages (see tcz/README.md for the full caching pipeline), then commit
# the regenerated tcz-manifest.json.

die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR=""
OUT="$SCRIPT_DIR/tcz-manifest.json"
TC_VERSION="16.x"
ARCH="x86_64"

usage() {
  cat <<EOF
Usage: $0 --dir <path with *.tcz> [--out tcz-manifest.json] [--tc-version 16.x] [--arch x86_64]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --tc-version) TC_VERSION="$2"; shift 2;;
    --arch) ARCH="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

[[ -n "$DIR" && -d "$DIR" ]] || die "Missing/invalid --dir"
have jq || die "Missing jq"
have sha256sum || die "Missing sha256sum"
have md5sum || die "Missing md5sum"

shopt -s nullglob
files=("$DIR"/*.tcz)
shopt -u nullglob
((${#files[@]} > 0)) || die "No .tcz files found in $DIR"

extensions_json="{}"
warned=0
for f in "${files[@]}"; do
  base="$(basename "$f")"
  sha256="$(sha256sum "$f" | awk '{print $1}')"
  md5=""
  if [[ -f "$f.md5.txt" ]]; then
    if ! ( cd "$DIR" && md5sum -c "$base.md5.txt" --status ); then
      die "MD5 mismatch for $base against upstream sidecar $base.md5.txt -- refusing to pin a corrupted/tampered file"
    fi
    md5="$(awk '{print $1}' "$f.md5.txt")"
  else
    echo "WARNING: no upstream .md5.txt sidecar for $base; pinning sha256 from local file content only" >&2
    warned=1
  fi
  entry="$(jq -n --arg sha256 "$sha256" --arg md5 "$md5" '{sha256: $sha256} + (if $md5 != "" then {md5: $md5} else {} end)')"
  extensions_json="$(jq --arg k "$base" --argjson v "$entry" '. + {($k): $v}' <<<"$extensions_json")"
done

jq -n \
  --arg generated "$(date -Iseconds)" \
  --arg tc_version "$TC_VERSION" \
  --arg arch "$ARCH" \
  --argjson extensions "$extensions_json" \
  '{generated: $generated, tc_version: $tc_version, arch: $arch, extensions: $extensions}' \
  > "$OUT"

echo "[+] Wrote manifest: $OUT ($(jq '.extensions | length' "$OUT") packages pinned)"
[[ "$warned" -eq 0 ]] || echo "[!] One or more packages were pinned without upstream md5 verification (see warnings above)"
