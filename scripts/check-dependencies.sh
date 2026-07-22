#!/usr/bin/env bash
# scripts/check-dependencies.sh
#
# Verifies that the tools required by scripts/lint.sh, scripts/validate-config.sh,
# and `make unit`/`make integration` are present on PATH. Never installs anything;
# only reports what is missing and how to install it. Exits nonzero when any
# required tool is absent (Phase 0, agent-plan).
set -euo pipefail

log() { printf '%s [check-deps] %s\n' "$(date -Iseconds 2>/dev/null || date)" "$*" >&2; }

# name|check-command|apt-hint|brew-hint
TOOLS=(
  "bash|command -v bash|apt-get install -y bash|brew install bash"
  "shellcheck|command -v shellcheck|apt-get install -y shellcheck|brew install shellcheck"
  "shfmt|command -v shfmt|apt-get install -y shfmt (or: go install mvdan.cc/sh/v3/cmd/shfmt@latest)|brew install shfmt"
  "jq|command -v jq|apt-get install -y jq|brew install jq"
  "yq|command -v yq|snap install yq (or) apt-get install -y yq|brew install yq"
  "curl|command -v curl|apt-get install -y curl|brew install curl"
  "qemu-img|command -v qemu-img|apt-get install -y qemu-utils|brew install qemu"
  "qemu-system-x86_64|command -v qemu-system-x86_64|apt-get install -y qemu-system-x86|brew install qemu"
  "xorriso|command -v xorriso|apt-get install -y xorriso|brew install xorriso"
  "ansible-core|command -v ansible-playbook|apt-get install -y ansible-core (or: pipx install ansible-core)|brew install ansible"
  "ansible-lint|command -v ansible-lint|pipx install ansible-lint|brew install ansible-lint"
  "yamllint|command -v yamllint|apt-get install -y yamllint|brew install yamllint"
  "dnsmasq|command -v dnsmasq|apt-get install -y dnsmasq-base|brew install dnsmasq"
  "bats|command -v bats|npm install -g bats (or) apt-get install -y bats|brew install bats-core"
  "python3|command -v python3|apt-get install -y python3|brew install python3"
  "python3-jsonschema|python3 -c \"import jsonschema\"|apt-get install -y python3-jsonschema (or: pip3 install jsonschema)|pip3 install jsonschema"
  "python3-yaml|python3 -c \"import yaml\"|apt-get install -y python3-yaml (or: pip3 install pyyaml)|pip3 install pyyaml"
)

missing=0

for entry in "${TOOLS[@]}"; do
  IFS='|' read -r name check apt_hint brew_hint <<<"$entry"
  if eval "$check" >/dev/null 2>&1; then
    log "OK    $name"
  else
    log "MISSING $name"
    log "         Debian/Ubuntu: sudo $apt_hint"
    log "         macOS (brew):  $brew_hint"
    missing=$((missing + 1))
  fi
done

if [ "$missing" -gt 0 ]; then
  log "$missing required tool(s) missing. Install them, then re-run this script."
  exit 1
fi

log "All required tools are present."
exit 0
