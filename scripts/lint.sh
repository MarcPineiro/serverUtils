#!/usr/bin/env bash
# scripts/lint.sh
#
# Runs all Phase 0 static checks (agent-plan): shell syntax/style, YAML lint,
# ansible-lint (once ansible/ exists), cloud-init YAML syntax, and a secret
# scanner. Fails loudly (no `|| true`) so CI and `make lint` see every problem.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

status=0
fail() {
  echo "[FAIL] $*" >&2
  status=1
}
info() { echo "[lint] $*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    fail "required command '$1' not found. Run scripts/check-dependencies.sh."
    return 1
  }
}

# --- collect tracked shell scripts and classify shebang dialect -------------
mapfile -d '' -t ALL_TRACKED < <(git ls-files -z)

BASH_SCRIPTS=()
SH_SCRIPTS=()
for f in "${ALL_TRACKED[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in
    *.sh) ;;
    *) continue ;;
  esac
  first_line="$(head -n1 "$f" 2>/dev/null || true)"
  case "$first_line" in
    '#!'*bash*) BASH_SCRIPTS+=("$f") ;;
    '#!'*/sh | '#!'*dash* | '#!'*ash*) SH_SCRIPTS+=("$f") ;;
    *) BASH_SCRIPTS+=("$f") ;; # default: repo convention is bash for .sh
  esac
done

# --- bash -n / sh -n syntax checks ------------------------------------------
info "checking bash syntax (${#BASH_SCRIPTS[@]} files)"
for f in "${BASH_SCRIPTS[@]}"; do
  bash -n "$f" || fail "bash -n failed: $f"
done

info "checking POSIX sh syntax (${#SH_SCRIPTS[@]} files)"
for f in "${SH_SCRIPTS[@]}"; do
  sh -n "$f" || fail "sh -n failed: $f"
done

# --- shellcheck --------------------------------------------------------------
if require_cmd shellcheck; then
  if [ "${#BASH_SCRIPTS[@]}" -gt 0 ]; then
    info "shellcheck (bash dialect)"
    shellcheck -s bash "${BASH_SCRIPTS[@]}" || fail "shellcheck reported issues (bash)"
  fi
  if [ "${#SH_SCRIPTS[@]}" -gt 0 ]; then
    info "shellcheck (sh dialect)"
    shellcheck -s sh "${SH_SCRIPTS[@]}" || fail "shellcheck reported issues (sh)"
  fi
fi

# --- shfmt (check mode, no rewrites) -----------------------------------------
if require_cmd shfmt; then
  info "shfmt -d (diff/check mode)"
  if [ "${#BASH_SCRIPTS[@]}" -gt 0 ] || [ "${#SH_SCRIPTS[@]}" -gt 0 ]; then
    shfmt -i 2 -ci -bn -d "${BASH_SCRIPTS[@]}" "${SH_SCRIPTS[@]}" || fail "shfmt reported formatting differences"
  fi
fi

# --- yamllint ------------------------------------------------------------
if require_cmd yamllint; then
  mapfile -d '' -t YAML_FILES < <(git ls-files -z '*.yml' '*.yaml')
  if [ "${#YAML_FILES[@]}" -gt 0 ]; then
    info "yamllint (${#YAML_FILES[@]} files)"
    yamllint -c .yamllint.yml "${YAML_FILES[@]}" || fail "yamllint reported issues"
  fi
fi

# --- ansible-lint (only once ansible/ exists, introduced in Phase 4) ---------
if [ -d ansible ]; then
  if require_cmd ansible-lint; then
    info "ansible-lint"
    ansible-lint || fail "ansible-lint reported issues"
  fi
else
  info "skipping ansible-lint: ansible/ does not exist yet (introduced in Phase 4)"
fi

# --- cloud-init YAML syntax --------------------------------------------------
if require_cmd python3; then
  CLOUD_INIT_FILES=()
  for f in "${ALL_TRACKED[@]}"; do
    [ -f "$f" ] || continue
    case "$f" in
      */cloud-init/*/user-data | */cloud-init/*/meta-data | */cloud-init/*/network-config)
        CLOUD_INIT_FILES+=("$f")
        ;;
    esac
  done
  if [ "${#CLOUD_INIT_FILES[@]}" -gt 0 ]; then
    info "cloud-init YAML syntax (${#CLOUD_INIT_FILES[@]} files)"
    for f in "${CLOUD_INIT_FILES[@]}"; do
      python3 - "$f" <<'PYEOF' || fail "invalid cloud-init YAML: $f"
import sys
import yaml
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    text = fh.read()
body = text
if body.startswith("#cloud-config"):
    body = body.split("\n", 1)[1] if "\n" in body else ""
if not body.strip():
    sys.exit(0)
yaml.safe_load(body)
PYEOF
    done
  fi
fi

# --- reject committed private keys and known secret filenames ---------------
info "scanning for private-key material and known secret filenames"
if git grep -I -n -E '-----BEGIN (RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----' -- . >/tmp/lint-secret-keys.$$ 2>/dev/null; then
  fail "private key material found in tracked files:"
  cat /tmp/lint-secret-keys.$$ >&2
fi
rm -f /tmp/lint-secret-keys.$$

mapfile -d '' -t SECRET_NAME_HITS < <(git ls-files -z -- \
  '*id_rsa' '*id_rsa.pub' '*id_ed25519' '*id_ed25519.pub' \
  '*.pem' '*.p12' '*.pfx' '*.ppk' '*_rsa' '*.key')
if [ "${#SECRET_NAME_HITS[@]}" -gt 0 ]; then
  fail "tracked files matching known secret filename patterns:"
  printf '  %s\n' "${SECRET_NAME_HITS[@]}" >&2
fi

if [ "$status" -ne 0 ]; then
  echo "[lint] FAILED" >&2
  exit 1
fi
echo "[lint] all checks passed"
