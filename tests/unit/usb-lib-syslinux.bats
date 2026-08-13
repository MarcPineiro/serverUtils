#!/usr/bin/env bats
# tests/unit/usb-lib-syslinux.bats
#
# Idempotent legacy BIOS append-line patching (autoinstall-usb/lib/syslinux.sh).
# Operates only on files under $BATS_TEST_TMPDIR; no real ESP/USB is touched.

load '../helpers/bats-helpers'

setup() {
	REPO_ROOT="$(repo_root)"
	FUNCS="$REPO_ROOT/autoinstall-usb/lib/functions.sh"
	LIB="$REPO_ROOT/autoinstall-usb/lib/syslinux.sh"
	UUID="1111-2222-3333-4444"
}

@test "patch_append_line adds each karg exactly once" {
	run bash -c "source '$FUNCS'; source '$LIB'; patch_append_line 'quiet' '$UUID'"
	[ "$status" -eq 0 ]
	[[ "$output" == *"waitusb=20:UUID=$UUID"* ]]
	[[ "$output" == *"tce=UUID=$UUID"* ]]
	[[ "$output" == *"backup=UUID=$UUID"* ]]
}

@test "patch_append_line is idempotent when applied twice" {
	run bash -c "
    source '$FUNCS'; source '$LIB'
    once=\"\$(patch_append_line 'quiet' '$UUID')\"
    twice=\"\$(patch_append_line \"\$once\" '$UUID')\"
    [ \"\$once\" = \"\$twice\" ]
  "
	[ "$status" -eq 0 ]
}

@test "patch_append_line replaces a stale LABEL= form instead of duplicating" {
	run bash -c "source '$FUNCS'; source '$LIB'; patch_append_line 'quiet tce=LABEL=TINYDATA backup=LABEL=TINYDATA' '$UUID'"
	[ "$status" -eq 0 ]
	[[ "$output" != *"LABEL=TINYDATA"* ]]
	# exactly one tce= token
	count=$(grep -o 'tce=' <<<"$output" | wc -l)
	[ "$count" -eq 1 ]
}

@test "verify_append_line_once dies on a duplicated karg" {
	run bash -c "source '$FUNCS'; source '$LIB'; verify_append_line_once 'tce=UUID=$UUID tce=UUID=$UUID backup=UUID=$UUID waitusb=20:UUID=$UUID' '$UUID'"
	[ "$status" -ne 0 ]
}

@test "patch_syslinux_file rewrites APPEND lines and leaves other lines untouched" {
	f="$BATS_TEST_TMPDIR/isolinux.cfg"
	cat >"$f" <<'EOF'
DEFAULT tinycore
LABEL tinycore
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/core.gz quiet
EOF
	run bash -c "source '$FUNCS'; source '$LIB'; patch_syslinux_file '$f' '$UUID'"
	[ "$status" -eq 0 ]
	grep -q '^DEFAULT tinycore$' "$f"
	grep -q 'APPEND initrd=/boot/core.gz quiet waitusb=20:UUID='"$UUID" "$f"
}

@test "patch_syslinux_file run twice stays byte-identical" {
	f="$BATS_TEST_TMPDIR/isolinux2.cfg"
	cat >"$f" <<'EOF'
LABEL tinycore
  APPEND initrd=/boot/core.gz quiet
EOF
	bash -c "source '$FUNCS'; source '$LIB'; patch_syslinux_file '$f' '$UUID'"
	cp "$f" "$f.first"
	bash -c "source '$FUNCS'; source '$LIB'; patch_syslinux_file '$f' '$UUID'"
	diff "$f.first" "$f"
}

@test "find_syslinux_configs finds isolinux/syslinux/extlinux under a tree" {
	mkdir -p "$BATS_TEST_TMPDIR/esp/boot/isolinux" "$BATS_TEST_TMPDIR/esp/boot/syslinux"
	: >"$BATS_TEST_TMPDIR/esp/boot/isolinux/isolinux.cfg"
	: >"$BATS_TEST_TMPDIR/esp/boot/syslinux/syslinux.cfg"
	run bash -c "source '$FUNCS'; source '$LIB'; find_syslinux_configs '$BATS_TEST_TMPDIR/esp' | sort"
	[ "$status" -eq 0 ]
	[[ "$output" == *"isolinux.cfg"* ]]
	[[ "$output" == *"syslinux.cfg"* ]]
}
