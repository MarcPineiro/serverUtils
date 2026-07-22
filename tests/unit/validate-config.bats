#!/usr/bin/env bats
# tests/unit/validate-config.bats
#
# Phase 0 local test #2: a malformed MAC in a copied fixture must fail
# validation with the exact field path, and must never modify the repo.

load '../helpers/bats-helpers'

setup() {
	REPO_ROOT="$(repo_root)"
	SCRATCH="$BATS_TEST_TMPDIR/scratch"
	make_scratch_config "$SCRATCH"
}

@test "valid config/examples/*.yml pass validation" {
	run "$REPO_ROOT/scripts/validate-config.sh" \
		"$REPO_ROOT/config/examples/machines.example.yml" \
		"$REPO_ROOT/config/examples/network.example.yml" \
		"$REPO_ROOT/config/examples/installer.example.yml"
	[ "$status" -eq 0 ]
	[[ "$output" == *"3 file(s) valid"* ]]
}

@test "malformed MAC fails validation with the exact field path" {
	sed -i 's/de:ad:be:ef:00:01/not-a-mac-address/' "$SCRATCH/config/examples/machines.example.yml"

	run "$REPO_ROOT/scripts/validate-config.sh" "$SCRATCH/config/examples/machines.example.yml"

	[ "$status" -ne 0 ]
	[[ "$output" == *"[machines.supervisor-01.mac]"* ]]

	# Repo fixture must be untouched.
	run grep -c 'de:ad:be:ef:00:01' "$REPO_ROOT/config/examples/machines.example.yml"
	[ "$status" -eq 0 ]
}

@test "unknown schema prefix is reported, not silently skipped" {
	echo 'foo: bar' >"$SCRATCH/config/examples/nosuchschema.example.yml"
	run "$REPO_ROOT/scripts/validate-config.sh" "$SCRATCH/config/examples/nosuchschema.example.yml"
	[ "$status" -ne 0 ]
	[[ "$output" == *"no schema found"* ]]
}
