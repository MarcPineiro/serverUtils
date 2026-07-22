#!/usr/bin/env bash
# scripts/validate-config.sh
#
# Validates non-secret configuration under config/ against the JSON Schemas in
# config/schema/ (Phase 0, agent-plan). Thin wrapper around
# scripts/lib/validate_config.py so the matching logic is testable in Python.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "[ERROR] python3 is required. Run scripts/check-dependencies.sh for install hints." >&2
  exit 1
fi

if ! python3 -c "import jsonschema, yaml" >/dev/null 2>&1; then
  echo "[ERROR] python3 modules 'jsonschema' and 'pyyaml' are required." >&2
  echo "         Run scripts/check-dependencies.sh for install hints." >&2
  exit 1
fi

exec python3 "$SCRIPT_DIR/lib/validate_config.py" "$@"
