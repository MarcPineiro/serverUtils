#!/bin/sh
set -eu

MARK="/run/autoprov.executed"
LOG="/run/autoprov-run.log"

exec >>"$LOG" 2>&1

echo "[autoprov] start $(date)"

# Only once per boot
[ -f "$MARK" ] && exit 0
date > "$MARK"

# Load env prepared by mount-env
if [ -f /run/autoprov.env ]; then
  set -a
  . /run/autoprov.env
  set +a
fi

: "${GITHUB_BOOTSTRAP_URL:=}"
: "${BOOTSTRAP_TIMEOUT_SEC:=15}"
: "${BOOTSTRAP_DEST:=/opt/autorun/bootstrap.sh}"

normalize_github_url() {
  case "$1" in
    https://github.com/*/*/blob/*)
      echo "$1" | sed -E 's#^https://github.com/([^/]+)/([^/]+)/blob/([^/]+)/(.*)$#https://raw.githubusercontent.com/\1/\2/\3/\4#'
      ;;
    *) echo "$1";;
  esac
}

fetch_to() {
  url="$1"; dest="$2"; timeout="$3"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout "$timeout" --max-time "$timeout" "$url" -o "$dest"
  else
    wget -q -T "$timeout" -O "$dest" "$url"
  fi
}

BOOT_OK=0
if [ -n "$GITHUB_BOOTSTRAP_URL" ]; then
  RAW_URL="$(normalize_github_url "$GITHUB_BOOTSTRAP_URL")"
  echo "[autoprov] downloading bootstrap: $RAW_URL"
  if fetch_to "$RAW_URL" "$BOOTSTRAP_DEST" "$BOOTSTRAP_TIMEOUT_SEC"; then
    chmod +x "$BOOTSTRAP_DEST" || true
    BOOT_OK=1
  else
    echo "[autoprov] download failed; will fallback"
  fi
else
  echo "[autoprov] GITHUB_BOOTSTRAP_URL empty; will fallback"
fi

if [ "$BOOT_OK" -ne 1 ]; then
  if [ -f /opt/autorun/bootstrap.fallback.sh ]; then
    echo "[autoprov] using embedded fallback bootstrap"
    cp -f /opt/autorun/bootstrap.fallback.sh "$BOOTSTRAP_DEST"
    chmod +x "$BOOTSTRAP_DEST" || true
  else
    echo "[autoprov] ERROR: missing /opt/autorun/bootstrap.fallback.sh"
    exit 1
  fi
fi

echo "[autoprov] executing: $BOOTSTRAP_DEST"
"$BOOTSTRAP_DEST" || true

echo "[autoprov] end $(date)"
exit 0
