#!/bin/sh
set -eu

ENV_LABEL="ENV"
PERSIST_LABEL="PERSIST"

ENV_DEV="/dev/disk/by-label/${ENV_LABEL}"
PERSIST_DEV="/dev/disk/by-label/${PERSIST_LABEL}"

ENV_MNT="/mnt/env"
PERSIST_MNT="/mnt/persist"

OUT_ENV="/run/autoprov.env"
MARK="/run/mount-env.executed"

mkdir -p "$ENV_MNT" "$PERSIST_MNT" /run

log_kmsg() { echo "[mount-env] $*" > /dev/kmsg 2>/dev/null || true; }

is_mounted() { grep -q " $1 " /proc/mounts 2>/dev/null; }

# Mount ENV (vfat) if present
if [ -e "$ENV_DEV" ]; then
  if ! is_mounted "$ENV_MNT"; then
    mount -t vfat -o rw,umask=022 "$ENV_DEV" "$ENV_MNT" 2>/dev/null || \
      mount -t vfat -o ro "$ENV_DEV" "$ENV_MNT" 2>/dev/null || true
  fi
else
  log_kmsg "ENV device not found: $ENV_DEV"
fi

# Mount PERSIST (ext4) if present
if [ -e "$PERSIST_DEV" ]; then
  if ! is_mounted "$PERSIST_MNT"; then
    mount -t ext4 -o rw "$PERSIST_DEV" "$PERSIST_MNT" 2>/dev/null || true
  fi
else
  log_kmsg "PERSIST device not found: $PERSIST_DEV"
fi

# Build normalized env file for later scripts.
# Priority:
#  1) /mnt/env/default.env
#  2) /opt/autorun/default.env
#  3) built-in defaults
: > "$OUT_ENV"

append_env_file() {
  f="$1"
  [ -f "$f" ] || return 0
  sed -e 's/\r$//' \
      -e '/^[[:space:]]*#/d' \
      -e '/^[[:space:]]*$/d' \
      -e '/^[A-Za-z_][A-Za-z0-9_]*=.*/!d' \
      "$f" >> "$OUT_ENV"
}

if [ -f "$ENV_MNT/default.env" ]; then
  log_kmsg "Loading env from $ENV_MNT/default.env"
  append_env_file "$ENV_MNT/default.env"
elif [ -f "/opt/autorun/default.env" ]; then
  log_kmsg "Loading env from /opt/autorun/default.env"
  append_env_file "/opt/autorun/default.env"
else
  log_kmsg "No env found; using built-in defaults"
  cat >>"$OUT_ENV" <<'EOF'
GITHUB_BOOTSTRAP_URL=""
BOOTSTRAP_TIMEOUT_SEC="15"
BOOTSTRAP_DEST="/opt/autorun/bootstrap.sh"
EOF
fi

echo "ENV_MOUNTED=$([ -f "$ENV_MNT/default.env" ] && echo 1 || echo 0)" >> "$OUT_ENV"
echo "PERSIST_MOUNTED=$(is_mounted "$PERSIST_MNT" && echo 1 || echo 0)" >> "$OUT_ENV"

chmod 0644 "$OUT_ENV" 2>/dev/null || true
date > "$MARK"
