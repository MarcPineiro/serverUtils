#!/usr/bin/env bats
# tests/unit/tcz-fetch-manifest.bats
#
# Exercises autoinstall-usb/tcz/fetch-tcz.sh end-to-end against a fake HTTP
# mirror (a mocked `curl` on PATH serving fixture bytes from
# $BATS_TEST_TMPDIR) -- never a real network call, never a real Tiny Core
# mirror. Verifies: pinned tc/arch/mirror defaults, md5 sidecar
# verification, and the emitted tce/manifest.json.

load '../helpers/bats-helpers'

setup() {
	REPO_ROOT="$(repo_root)"
	SCRIPT="$REPO_ROOT/autoinstall-usb/tcz/fetch-tcz.sh"
	FIXBIN="$BATS_TEST_TMPDIR/bin"
	MIRROR_DIR="$BATS_TEST_TMPDIR/mirror"
	mkdir -p "$FIXBIN" "$MIRROR_DIR"

	echo -n "fake-package-bytes" >"$MIRROR_DIR/fake.tcz"
	md5sum "$MIRROR_DIR/fake.tcz" | awk '{print $1"  fake.tcz"}' >"$MIRROR_DIR/fake.tcz.md5.txt"

	echo "fake.tcz" >"$BATS_TEST_TMPDIR/onboot.lst"

	# Fake curl: serves files from $MIRROR_DIR by mapping the URL's basename,
	# mimicking `-fsSL ... -o dst URL`.
	cat >"$FIXBIN/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
dst=""
url=""
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
  if [[ "\${args[i]}" == "-o" ]]; then
    dst="\${args[i+1]}"
  fi
done
url="\${args[-1]}"
name="\$(basename "\$url")"
src="$MIRROR_DIR/\$name"
[[ -f "\$src" ]] || exit 22
cp "\$src" "\$dst"
EOF
	chmod +x "$FIXBIN/curl"
}

@test "fetch-tcz.sh downloads, verifies md5, and emits a valid manifest.json" {
	out="$BATS_TEST_TMPDIR/tce"
	run env PATH="$FIXBIN:$PATH" "$SCRIPT" --onboot "$BATS_TEST_TMPDIR/onboot.lst" --out "$out" --mirror "file://unused"
	[ "$status" -eq 0 ]
	[ -f "$out/optional/fake.tcz" ]
	[ -f "$out/manifest.json" ]
	run jq -e '.packages[0].name == "fake.tcz"' "$out/manifest.json"
	[ "$status" -eq 0 ]
	expected_sha="$(sha256sum "$out/optional/fake.tcz" | awk '{print $1}')"
	run jq -r '.packages[0].sha256' "$out/manifest.json"
	[ "$output" = "$expected_sha" ]
}

@test "fetch-tcz.sh fails loudly on an md5 mismatch instead of continuing" {
	echo -n "corrupted-bytes-not-matching-md5" >"$MIRROR_DIR/fake.tcz.corrupt-source"
	# Point the sidecar at bytes that will never match what curl serves.
	echo "0000000000000000000000000000000  fake.tcz" >"$MIRROR_DIR/fake.tcz.md5.txt"
	out="$BATS_TEST_TMPDIR/tce-bad"
	run env PATH="$FIXBIN:$PATH" "$SCRIPT" --onboot "$BATS_TEST_TMPDIR/onboot.lst" --out "$out" --mirror "file://unused"
	[ "$status" -ne 0 ]
	[[ "$output" == *"Checksum mismatch"* ]]
}

@test "fetch-tcz.sh resolves tc/arch/mirror defaults from pinned-version.json" {
	run bash -c "jq -e '.tc_major and .arch and .mirror' '$REPO_ROOT/autoinstall-usb/tcz/pinned-version.json'"
	[ "$status" -eq 0 ]
}
