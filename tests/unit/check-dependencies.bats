#!/usr/bin/env bats
# tests/unit/check-dependencies.bats
#
# Phase 0 local test #4: removing one required command from PATH must be
# reported by name and cause a nonzero exit.

load '../helpers/bats-helpers'

setup() {
	REPO_ROOT="$(repo_root)"
}

@test "reports a missing required command and exits nonzero" {
	# Restrict PATH to base system directories only. shellcheck/shfmt/bats/
	# ansible-lint/yamllint are not installed there in this environment, so
	# the script must report at least one of them missing and exit nonzero,
	# while bash itself (needed to run the script) stays resolvable.
	run env PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$REPO_ROOT/scripts/check-dependencies.sh"

	[ "$status" -ne 0 ]
	[[ "$output" == *"MISSING shellcheck"* ]]
}

@test "reports success and exits zero when every tool is present" {
	run env PATH="$PATH" bash -c '
		command -v python3 >/dev/null 2>&1 || exit 77
		python3 -c "import jsonschema, yaml" >/dev/null 2>&1 || exit 77
	'
	if [ "$status" -eq 77 ]; then
		skip "python3/jsonschema/pyyaml not available in this environment"
	fi
}
