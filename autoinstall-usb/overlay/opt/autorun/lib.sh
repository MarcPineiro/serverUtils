#!/bin/sh
# /opt/autorun/lib.sh
#
# Shared POSIX `sh` helpers for autoprov-run.sh. Deliberately BusyBox/ash
# compatible (no bash arrays, no `[[ ]]`): everything here runs on the Tiny
# Core USB itself, where only `sh`, `mkdir`, `mv`, `dd`, `sha256sum` and
# either `curl` or `wget` can be assumed. Sourcing this file has no side
# effects, which is also what lets it be `source`d by Bats (bash) tests with
# mocked `curl`/`wget`/`ip`/`route` on PATH instead of a real network.

ap_now() {
  date -Iseconds 2>/dev/null || date
}

# ap_write_state PATH CONTENT
ap_write_state() {
  mkdir -p "$(dirname "$1")" 2>/dev/null || true
  printf '%s\n' "$2" >"$1"
}

# ap_acquire_lock DIR
# `mkdir` is atomic on every filesystem this project targets (ext4, and even
# FAT for completeness), so it doubles as a lock BusyBox can use without
# flock(1). Returns 1 (without creating anything) if the lock is already
# held, e.g. by a second boot hook or a manual re-invocation in the same
# boot (agent-plan Phase 1: single authoritative launch path).
ap_acquire_lock() {
  mkdir "$1" 2>/dev/null
}

ap_release_lock() {
  rmdir "$1" 2>/dev/null || true
}

# ap_wait_for_network SECONDS
# Polls for a default route with whichever tool is present. Never fatal on
# timeout: callers proceed and let the download attempt itself fail/retry.
ap_wait_for_network() {
  local secs i
  secs="$1"
  i=0
  while [ "$i" -lt "$secs" ]; do
    if command -v ip >/dev/null 2>&1; then
      ip route 2>/dev/null | grep -q '^default' && return 0
    else
      route -n 2>/dev/null | grep -q '^0\.0\.0\.0' && return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# ap_validate_downloaded FILE [EXPECTED_SHA256]
# Nonempty, begins with a shell shebang ("#!"), and -- only when
# EXPECTED_SHA256 is non-empty -- its sha256 matches exactly (agent-plan
# Phase 1: "Validate downloaded content is nonempty, begins with a shell
# shebang, and matches an optional SHA-256").
ap_validate_downloaded() {
  local file expected first_two actual
  file="$1"
  expected="${2:-}"
  [ -s "$file" ] || return 1
  first_two="$(dd if="$file" bs=1 count=2 2>/dev/null)"
  [ "$first_two" = "#!" ] || return 1
  if [ -n "$expected" ]; then
    actual="$(sha256sum "$file" 2>/dev/null | awk '{print $1}')"
    [ "$actual" = "$expected" ] || return 1
  fi
  return 0
}

# ap_download_once URL DEST
# Single attempt with whichever downloader is present; fails cleanly (does
# not hang) when neither curl nor wget exists.
ap_download_once() {
  local url dest
  url="$1"
  dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" --header='Cache-Control: no-cache' --header='Pragma: no-cache' "$url"
  else
    echo "[autoprov] Neither curl nor wget is available" >&2
    return 1
  fi
}

# ap_download_with_retry URL DEST [TRIES] [DELAY_SECONDS]
# Cache-busts the URL on every attempt and retries up to TRIES times
# (default 3) with DELAY_SECONDS between attempts (default 5). Only ever
# leaves a complete file at DEST: every attempt downloads to DEST.attempt
# first and only renames it into place on success (agent-plan Phase 1:
# "atomic temporary file and rename" + "bounded network retries").
ap_download_with_retry() {
  local url dest tries delay n cb sep attempt
  url="$1"
  dest="$2"
  tries="${3:-3}"
  delay="${4:-5}"
  n=1
  while [ "$n" -le "$tries" ]; do
    cb="$(date +%s 2>/dev/null || echo "$n")"
    sep="?"
    case "$url" in *\?*) sep="&" ;; esac
    attempt="${dest}.attempt"
    rm -f "$attempt"
    if ap_download_once "${url}${sep}cb=${cb}" "$attempt"; then
      mv -f "$attempt" "$dest"
      return 0
    fi
    rm -f "$attempt"
    echo "[autoprov] Download attempt $n/$tries failed" >&2
    n=$((n + 1))
    if [ "$n" -le "$tries" ]; then
      sleep "$delay"
    fi
  done
  return 1
}
