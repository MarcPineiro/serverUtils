#!/bin/sh
# /opt/autorun/autoprov-run.sh
set -eu

TCE_DIR="/etc/sysconfig/tcedir"
STATE="$TCE_DIR/state"

mkdir -p "$STATE"
echo "$(date -Iseconds) START" > "$STATE/autorun.started"

ENV_OVERLAY="/opt/autorun/autoprov.env"
ENV_TCE="$TCE_DIR/autoprov.env"

[ -f "$ENV_OVERLAY" ] && . "$ENV_OVERLAY"
[ -f "$ENV_TCE" ] && . "$ENV_TCE"

: "${GITHUB_BOOTSTRAP_URL:?Missing GITHUB_BOOTSTRAP_URL in $ENV_FILE}"
: "${NET_WAIT_SECONDS:=25}"
: "${RUN_ONCE:=1}"
: "${RUN_ONCE_FLAG_REL:=autoprov/ran.ok}"
: "${FALLBACK_SCRIPT:=/opt/autorun/bootstrap.fallback.sh}"
: "${BOOTSTRAP_ARGS:=}"

LOG_DIR="/etc/sysconfig/tcedir/logs"
mkdir -p "$LOG_DIR" >/dev/null 2>&1 || true
LOG="$LOG_DIR/autoprov.log"
#exec >>"$LOG" 2>&1
set -x

FLAG_PATH="/etc/sysconfig/tcedir/${RUN_ONCE_FLAG_REL}"

# if [ "$RUN_ONCE" = "1" ] && [ -f "$FLAG_PATH" ]; then
#   echo "[autoprov] RUN_ONCE enabled and flag exists: $FLAG_PATH -> skipping"
#   exit 0
# fi

i=0
while [ "$i" -lt "$NET_WAIT_SECONDS" ]; do
  ip route | grep -q '^default' && break
  sleep 1
  i=$((i+1))
done

DL_TOOL=""
if command -v curl >/dev/null 2>&1; then
  DL_TOOL="curl"
elif command -v wget >/dev/null 2>&1; then
  DL_TOOL="wget"
fi

TMP_BOOT="/tmp/bootstrap.sh"
ok="0"

if [ "$DL_TOOL" = "curl" ]; then
  if curl -fsSL "$GITHUB_BOOTSTRAP_URL" -o "$TMP_BOOT"; then ok="1"; fi
elif [ "$DL_TOOL" = "wget" ]; then
  if wget -qO "$TMP_BOOT" "$GITHUB_BOOTSTRAP_URL"; then ok="1"; fi
else
  echo "[autoprov] Neither curl nor wget found. Ensure .tcz are in onboot.lst"
fi

if [ "$ok" = "1" ]; then
  chmod +x "$TMP_BOOT"
  echo "[autoprov] Running downloaded bootstrap: $GITHUB_BOOTSTRAP_URL"
  bash "$TMP_BOOT" $BOOTSTRAP_ARGS || ok="0"
else
  echo "[autoprov] Download failed, will use fallback"
fi

if [ "$ok" != "1" ]; then
  if [ -x "$FALLBACK_SCRIPT" ]; then
    echo "[autoprov] Running fallback: $FALLBACK_SCRIPT"
    bash "$FALLBACK_SCRIPT" || true
  else
    echo "[autoprov] Fallback script missing/not executable: $FALLBACK_SCRIPT"
  fi
fi

if [ "$RUN_ONCE" = "1" ]; then
  mkdir -p "$(dirname "$FLAG_PATH")" || true
  date > "$FLAG_PATH" || true
fi

echo "[autoprov] Done"

echo "$(date -Iseconds) END" > "$STATE/autorun.finished"