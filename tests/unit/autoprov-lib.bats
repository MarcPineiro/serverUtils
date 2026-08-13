#!/usr/bin/env bats
# tests/unit/autoprov-lib.bats
#
# Tests for autoinstall-usb/overlay/opt/autorun/lib.sh and autoprov-run.sh
# (agent-plan Phase 1: "Repair autoprov-run.sh" + "Add tests for malformed
# environment files and missing network tools"). No real network access:
# curl/wget/ip are mocked fixtures on PATH. No real block device.

load '../helpers/bats-helpers'

setup() {
	REPO_ROOT="$(repo_root)"
	AUTORUN_DIR="$REPO_ROOT/autoinstall-usb/overlay/opt/autorun"
	LIB="$AUTORUN_DIR/lib.sh"
	FIXBIN="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$FIXBIN"
}

# A minimal PATH containing only the tools autoprov-run.sh genuinely needs
# (mkdir, dirname, date, dd, sha256sum, awk, sleep, mv, rm, rmdir, grep,
# printf, cat), symlinked from wherever they really resolve on this host, so
# tests control curl/wget/ip availability precisely regardless of what else
# happens to be installed.
make_minimal_path() {
	local dest="$1" tool resolved
	mkdir -p "$dest"
	for tool in bash mkdir dirname date dd sha256sum awk sleep mv rm rmdir grep printf cat true false; do
		resolved="$(command -v "$tool" 2>/dev/null || true)"
		[ -n "$resolved" ] || continue
		ln -sf "$resolved" "$dest/$tool"
	done
}

@test "ap_validate_downloaded: fails on an empty file" {
	: >"$BATS_TEST_TMPDIR/empty"
	run bash -c "source '$LIB'; ap_validate_downloaded '$BATS_TEST_TMPDIR/empty'"
	[ "$status" -ne 0 ]
}

@test "ap_validate_downloaded: fails when the file has no shell shebang" {
	printf 'echo hi\n' >"$BATS_TEST_TMPDIR/noshebang"
	run bash -c "source '$LIB'; ap_validate_downloaded '$BATS_TEST_TMPDIR/noshebang'"
	[ "$status" -ne 0 ]
}

@test "ap_validate_downloaded: passes with a shebang and no expected sha256" {
	printf '#!/bin/sh\necho hi\n' >"$BATS_TEST_TMPDIR/ok.sh"
	run bash -c "source '$LIB'; ap_validate_downloaded '$BATS_TEST_TMPDIR/ok.sh'"
	[ "$status" -eq 0 ]
}

@test "ap_validate_downloaded: fails on a sha256 mismatch" {
	printf '#!/bin/sh\necho hi\n' >"$BATS_TEST_TMPDIR/ok2.sh"
	run bash -c "source '$LIB'; ap_validate_downloaded '$BATS_TEST_TMPDIR/ok2.sh' deadbeef"
	[ "$status" -ne 0 ]
}

@test "ap_validate_downloaded: passes on a matching sha256" {
	printf '#!/bin/sh\necho hi\n' >"$BATS_TEST_TMPDIR/ok3.sh"
	expected="$(sha256sum "$BATS_TEST_TMPDIR/ok3.sh" | awk '{print $1}')"
	run bash -c "source '$LIB'; ap_validate_downloaded '$BATS_TEST_TMPDIR/ok3.sh' '$expected'"
	[ "$status" -eq 0 ]
}

@test "ap_download_once: fails cleanly with a clear message when neither curl nor wget exist" {
	make_minimal_path "$FIXBIN"
	run env PATH="$FIXBIN" bash -c "source '$LIB'; ap_download_once http://example.invalid/x '$BATS_TEST_TMPDIR/out'"
	[ "$status" -ne 0 ]
	[[ "$output" == *"Neither curl nor wget is available"* ]]
	[ ! -f "$BATS_TEST_TMPDIR/out" ]
}

@test "ap_download_with_retry: writes the final content at the exact requested dest path (regression: dest must not be clobbered by the nested ap_download_once call)" {
	make_minimal_path "$FIXBIN"
	cat >"$FIXBIN/curl" <<'EOF'
#!/usr/bin/env bash
# -o is the last arg pair in ap_download_once's invocation
for ((i=1;i<=$#;i++)); do
  if [ "${!i}" = "-o" ]; then j=$((i+1)); echo "#!/bin/sh
echo hello" > "${!j}"; exit 0; fi
done
exit 1
EOF
	chmod +x "$FIXBIN/curl"
	dest="$BATS_TEST_TMPDIR/final-bootstrap.sh"
	run env PATH="$FIXBIN:$PATH" bash -c "source '$LIB'; ap_download_with_retry http://example.invalid/x '$dest' 3 0"
	[ "$status" -eq 0 ]
	[ -f "$dest" ]
	[ ! -f "${dest}.attempt" ]
	run cat "$dest"
	[[ "$output" == *"hello"* ]]
}

@test "ap_download_with_retry: retries the configured number of times and gives up" {
	make_minimal_path "$FIXBIN"
	cat >"$FIXBIN/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
	chmod +x "$FIXBIN/curl"
	dest="$BATS_TEST_TMPDIR/never.sh"
	run env PATH="$FIXBIN:$PATH" bash -c "source '$LIB'; ap_download_with_retry http://example.invalid/x '$dest' 2 0"
	[ "$status" -ne 0 ]
	[ ! -f "$dest" ]
	# 2 attempts logged
	[[ "$output" == *"Download attempt 1/2 failed"* ]]
	[[ "$output" == *"Download attempt 2/2 failed"* ]]
}

@test "ap_acquire_lock/ap_release_lock: mkdir-based lock is atomic and reusable after release" {
	run bash -c "source '$LIB'; ap_acquire_lock '$BATS_TEST_TMPDIR/lock'"
	[ "$status" -eq 0 ]
	run bash -c "source '$LIB'; ap_acquire_lock '$BATS_TEST_TMPDIR/lock'"
	[ "$status" -ne 0 ]
	run bash -c "source '$LIB'; ap_release_lock '$BATS_TEST_TMPDIR/lock'; ap_acquire_lock '$BATS_TEST_TMPDIR/lock'"
	[ "$status" -eq 0 ]
}

@test "ap_wait_for_network: returns immediately when a mocked default route exists" {
	cat >"$FIXBIN/ip" <<'EOF'
#!/usr/bin/env bash
echo "default via 10.0.0.1 dev eth0"
EOF
	chmod +x "$FIXBIN/ip"
	run env PATH="$FIXBIN:$PATH" bash -c "source '$LIB'; ap_wait_for_network 5"
	[ "$status" -eq 0 ]
}

@test "ap_wait_for_network: times out and returns nonzero when no default route ever appears" {
	cat >"$FIXBIN/ip" <<'EOF'
#!/usr/bin/env bash
echo "no default here"
EOF
	chmod +x "$FIXBIN/ip"
	run env PATH="$FIXBIN:$PATH" bash -c "source '$LIB'; ap_wait_for_network 1"
	[ "$status" -ne 0 ]
}

@test "autoprov-run.sh: a malformed/incomplete environment file (missing GITHUB_BOOTSTRAP_URL) fails loudly" {
	tce_dir="$BATS_TEST_TMPDIR/tce"
	mkdir -p "$tce_dir"
	: >"$tce_dir/autoprov.env"
	run env TCE_DIR="$tce_dir" "$AUTORUN_DIR/autoprov-run.sh"
	[ "$status" -ne 0 ]
	[[ "$output" == *"Missing GITHUB_BOOTSTRAP_URL"* ]]
}

@test "autoprov-run.sh: with no curl/wget/fallback available it fails cleanly and records autoprov.failed (never hangs)" {
	make_minimal_path "$FIXBIN"
	tce_dir="$BATS_TEST_TMPDIR/tce2"
	mkdir -p "$tce_dir"
	cat >"$tce_dir/autoprov.env" <<'EOF'
GITHUB_BOOTSTRAP_URL="http://example.invalid/bootstrap.sh"
NET_WAIT_SECONDS=0
DOWNLOAD_RETRIES=1
DOWNLOAD_RETRY_DELAY=0
RUN_ONCE=0
EOF
	run env PATH="$FIXBIN" TCE_DIR="$tce_dir" "$AUTORUN_DIR/autoprov-run.sh"
	[ "$status" -eq 0 ]
	[ -f "$tce_dir/state/autoprov.failed" ]
	[ ! -f "$tce_dir/state/autoprov.succeeded" ]
}
