#!/usr/bin/env bats
# tests/unit/usb-lib-grub.bats
#
# render_grub_cfg is a pure function (stdout only); detect_tc_boot_files is
# tested against a synthetic $BATS_TEST_TMPDIR tree, never a real ESP.

load '../helpers/bats-helpers'

setup() {
	REPO_ROOT="$(repo_root)"
	FUNCS="$REPO_ROOT/autoinstall-usb/lib/functions.sh"
	LIB="$REPO_ROOT/autoinstall-usb/lib/grub.sh"
}

@test "detect_tc_boot_files finds vmlinuz64 and corepure64.gz" {
	mkdir -p "$BATS_TEST_TMPDIR/esp/boot"
	: >"$BATS_TEST_TMPDIR/esp/boot/vmlinuz64"
	: >"$BATS_TEST_TMPDIR/esp/boot/corepure64.gz"
	run bash -c "source '$FUNCS'; source '$LIB'; detect_tc_boot_files '$BATS_TEST_TMPDIR/esp'"
	[ "$status" -eq 0 ]
	[ "$output" = "/boot/vmlinuz64|/boot/corepure64.gz" ]
}

@test "detect_tc_boot_files fails when no initrd-like file exists" {
	mkdir -p "$BATS_TEST_TMPDIR/esp2/boot"
	: >"$BATS_TEST_TMPDIR/esp2/boot/vmlinuz64"
	run bash -c "source '$FUNCS'; source '$LIB'; detect_tc_boot_files '$BATS_TEST_TMPDIR/esp2'"
	[ "$status" -ne 0 ]
}

@test "render_grub_cfg includes a normal entry with quiet and persistence kargs" {
	run bash -c "source '$FUNCS'; source '$LIB'; render_grub_cfg ESPUUID DATAUUID /boot/vmlinuz64 /boot/corepure64.gz"
	[ "$status" -eq 0 ]
	[[ "$output" == *'menuentry "Tiny Core autoprov (normal)"'* ]]
	[[ "$output" == *"tce=UUID=DATAUUID"* ]]
	[[ "$output" == *"backup=UUID=DATAUUID"* ]]
	[[ "$output" == *"waitusb=20:UUID=DATAUUID"* ]]
	[[ "$output" == *"search --no-floppy --fs-uuid --set=root ESPUUID"* ]]
}

@test "render_grub_cfg includes a diagnostic entry without 'quiet' and with verbose logging" {
	run bash -c "source '$FUNCS'; source '$LIB'; render_grub_cfg ESPUUID DATAUUID /boot/vmlinuz64 /boot/corepure64.gz"
	[ "$status" -eq 0 ]
	[[ "$output" == *'menuentry "Tiny Core autoprov (diagnostic, verbose)"'* ]]
	[[ "$output" == *"loglevel=8"* ]]
}

@test "render_grub_cfg reserves a guarded Ubuntu autoinstall entry for Phase 3" {
	run bash -c "source '$FUNCS'; source '$LIB'; render_grub_cfg ESPUUID DATAUUID /boot/vmlinuz64 /boot/corepure64.gz"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Ubuntu Server autoinstall (reserved, Phase 3)"* ]]
	[[ "$output" == *"/ubuntu/casper/vmlinuz"* ]]
	# guarded: only appears inside an `if [ -f ... ]` block
	[[ "$output" == *"if [ -f (\$root)/ubuntu/casper/vmlinuz"* ]]
}
