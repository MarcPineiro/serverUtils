#!/bin/sh
# /opt/autorun/autoprov-run.sh
#
# The single authoritative provisioning entrypoint. Invoked exactly once per
# boot by /opt/bootlocal.sh (agent-plan Phase 1: "Replace the two potential
# launch paths with one authoritative path"). A mkdir-based lock (BusyBox has
# no flock(1)) makes even a stray manual/duplicate invocation within the same
# boot a harmless no-op, and a persistent RUN_ONCE flag file on the data
# partition prevents a successful remote run from ever repeating across
# reboots.
#
# State files under $TCE_DIR/state/ (agent-plan Phase 1: "Distinguish
# started, downloaded, running, succeeded, and failed state files"):
#   autoprov.started    written unconditionally at the top of every invocation
#   autoprov.running    written once the lock is held and network wait begins
#   autoprov.downloaded written once the remote bootstrap has been fetched
#                       and passed validation (before it is executed)
#   autoprov.succeeded  written on a successful run; records whether the
#                       remote controller or the offline fallback succeeded
#   autoprov.failed     written when both the remote controller and the
#                       offline fallback failed or were unavailable
#
# The persistent RUN_ONCE flag (default: $TCE_DIR/autoprov/ran.ok) is written
# ONLY after the downloaded remote controller itself succeeds -- a fallback
# run never marks the host as done, so the next boot keeps retrying the
# real remote controller (agent-plan: "Write the success flag only after the
# downloaded controller succeeds").
set -eu

TCE_DIR="${TCE_DIR:-/etc/sysconfig/tcedir}"
STATE_DIR="$TCE_DIR/state"
LOG_DIR="$TCE_DIR/logs"
SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

mkdir -p "$STATE_DIR" "$LOG_DIR"

# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

ENV_OVERLAY="/opt/autorun/autoprov.env"
ENV_TCE="$TCE_DIR/autoprov.env"
[ -f "$ENV_OVERLAY" ] && . "$ENV_OVERLAY"
[ -f "$ENV_TCE" ] && . "$ENV_TCE"

: "${GITHUB_BOOTSTRAP_URL:?Missing GITHUB_BOOTSTRAP_URL in $ENV_OVERLAY / $ENV_TCE}"
: "${NET_WAIT_SECONDS:=25}"
: "${RUN_ONCE:=1}"
: "${RUN_ONCE_FLAG_REL:=autoprov/ran.ok}"
: "${FALLBACK_SCRIPT:=/opt/autorun/bootstrap.fallback.sh}"
: "${BOOTSTRAP_ARGS:=}"
: "${BOOTSTRAP_SHA256:=}"
: "${DOWNLOAD_RETRIES:=3}"
: "${DOWNLOAD_RETRY_DELAY:=5}"

LOG="$LOG_DIR/autoprov.log"
exec >>"$LOG" 2>&1
set -x

RUN_ONCE_FLAG="$TCE_DIR/${RUN_ONCE_FLAG_REL}"
LOCK_DIR="$STATE_DIR/autoprov.lock"

ap_write_state "$STATE_DIR/autoprov.started" "$(ap_now) pid=$$"

if [ "$RUN_ONCE" = "1" ] && [ -f "$RUN_ONCE_FLAG" ]; then
  echo "[autoprov] RUN_ONCE enabled and flag exists: $RUN_ONCE_FLAG -> skipping"
  ap_write_state "$STATE_DIR/autoprov.succeeded" "$(ap_now) result=skipped-run-once"
  exit 0
fi

if ! ap_acquire_lock "$LOCK_DIR"; then
  echo "[autoprov] Another invocation is already running/ran this boot (lock: $LOCK_DIR) -> skipping"
  exit 0
fi
trap 'ap_release_lock "$LOCK_DIR"' EXIT

ap_write_state "$STATE_DIR/autoprov.running" "$(ap_now)"

ap_wait_for_network "$NET_WAIT_SECONDS" || echo "[autoprov] Network wait timed out after ${NET_WAIT_SECONDS}s; trying download anyway"

TMP_BOOT="$STATE_DIR/bootstrap.sh.$$"
FINAL_BOOT="/tmp/bootstrap.sh"

ok="0"
if ap_download_with_retry "$GITHUB_BOOTSTRAP_URL" "$TMP_BOOT" "$DOWNLOAD_RETRIES" "$DOWNLOAD_RETRY_DELAY"; then
  if ap_validate_downloaded "$TMP_BOOT" "$BOOTSTRAP_SHA256"; then
    mv -f "$TMP_BOOT" "$FINAL_BOOT"
    chmod +x "$FINAL_BOOT"
    ap_write_state "$STATE_DIR/autoprov.downloaded" "$(ap_now) $GITHUB_BOOTSTRAP_URL"
    ok="1"
  else
    echo "[autoprov] Downloaded content failed validation (empty/no shebang/sha256 mismatch)" >&2
    mv -f "$TMP_BOOT" "$STATE_DIR/autoprov.download-failed.sh" 2>/dev/null || rm -f "$TMP_BOOT"
  fi
else
  echo "[autoprov] Download failed after $DOWNLOAD_RETRIES attempt(s): $GITHUB_BOOTSTRAP_URL" >&2
fi

result="failed"
if [ "$ok" = "1" ]; then
  echo "[autoprov] Running downloaded bootstrap: $GITHUB_BOOTSTRAP_URL"
  if sh "$FINAL_BOOT" $BOOTSTRAP_ARGS; then
    result="remote"
  else
    echo "[autoprov] Downloaded bootstrap exited nonzero" >&2
    cp -f "$FINAL_BOOT" "$STATE_DIR/autoprov.controller-failed.sh" 2>/dev/null || true
  fi
fi

if [ "$result" != "remote" ]; then
  if [ -x "$FALLBACK_SCRIPT" ]; then
    echo "[autoprov] Remote retries exhausted; running fallback: $FALLBACK_SCRIPT"
    if sh "$FALLBACK_SCRIPT" $BOOTSTRAP_ARGS; then
      result="fallback"
    else
      echo "[autoprov] Fallback script exited nonzero" >&2
    fi
  else
    echo "[autoprov] Fallback script missing/not executable: $FALLBACK_SCRIPT"
  fi
fi

case "$result" in
  remote)
    if [ "$RUN_ONCE" = "1" ]; then
      mkdir -p "$(dirname "$RUN_ONCE_FLAG")"
      ap_now >"$RUN_ONCE_FLAG"
    fi
    ap_write_state "$STATE_DIR/autoprov.succeeded" "$(ap_now) result=remote"
    ;;
  fallback)
    # Deliberately does NOT set RUN_ONCE_FLAG: the offline fallback is an
    # emergency measure, not a substitute for a real completed run, so the
    # next boot retries the remote controller again.
    ap_write_state "$STATE_DIR/autoprov.succeeded" "$(ap_now) result=fallback (RUN_ONCE flag not set)"
    ;;
  *)
    ap_write_state "$STATE_DIR/autoprov.failed" "$(ap_now) both remote and fallback failed or unavailable"
    ;;
esac

echo "[autoprov] Done: result=$result"