#!/usr/bin/env bash
set -euo pipefail

log() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Missing required tool: $1"; }
have() { command -v "$1" >/dev/null 2>&1; }
