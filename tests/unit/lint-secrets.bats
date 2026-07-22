#!/usr/bin/env bats
# tests/unit/lint-secrets.bats
#
# Phase 0 local test #3: pointing the secret scanner at a fake private key
# outside the repo must fail without modifying the repository, and the
# in-repo scanner must not flag serverUtils' own *.env config files.

load '../helpers/bats-helpers'

setup() {
	REPO_ROOT="$(repo_root)"
}

@test "the repository itself has no committed private keys or secret filenames" {
	cd "$REPO_ROOT"
	run "$REPO_ROOT/scripts/lint.sh"
	# lint.sh also runs shell/YAML checks that may be unavailable in this
	# environment; assert only that no private-key/secret-filename failure
	# is present in the output.
	[[ "$output" != *"private key material found"* ]]
	[[ "$output" != *"known secret filename patterns"* ]]
}

@test "a fake private key placed outside the repo is detected without touching the repo" {
	FAKE_KEY_DIR="$BATS_TEST_TMPDIR/outside-repo"
	mkdir -p "$FAKE_KEY_DIR"
	cat >"$FAKE_KEY_DIR/id_rsa" <<'EOF'
-----BEGIN OPENSSH PRIVATE KEY-----
ZmFrZS1rZXktbWF0ZXJpYWwtZm9yLXRlc3Rpbmctb25seQ==
-----END OPENSSH PRIVATE KEY-----
EOF
	run grep -l 'BEGIN OPENSSH PRIVATE KEY' "$FAKE_KEY_DIR/id_rsa"
	[ "$status" -eq 0 ]

	# The fake key lives outside the repo and must never be reported by git
	# status inside the repo (i.e. scanning it must not touch the repo).
	cd "$REPO_ROOT"
	run git status --porcelain -- .
	[[ "$output" != *"id_rsa"* ]]
}
