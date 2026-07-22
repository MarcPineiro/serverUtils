#!/usr/bin/env bash
# tests/helpers/bats-helpers.bash
#
# Shared helpers for Bats-core unit tests. `load`-ed from tests/unit/*.bats.
# Never touches real block devices or the network: only $BATS_TEST_TMPDIR and
# copies of repo files.

repo_root() {
	cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

# Copies config/examples and config/schema into a scratch directory so tests
# can mutate fixtures (e.g. inject a malformed MAC) without touching the repo.
make_scratch_config() {
	local root
	root="$(repo_root)"
	local scratch="$1"
	mkdir -p "$scratch/config/schema" "$scratch/config/examples"
	cp "$root"/config/schema/*.schema.json "$scratch/config/schema/"
	cp "$root"/config/examples/*.yml "$scratch/config/examples/"
}
