#!/usr/bin/env bats
# tests/unit/usb-lib-validate.bats
#
# Pure-function tests for autoinstall-usb/lib/validate.sh (agent-plan
# Phase 1 post-build validator). Every test builds a synthetic ESP/PERSIST
# directory tree under $BATS_TEST_TMPDIR -- never a real mount, loop device,
# or root privilege.

load '../helpers/bats-helpers'

setup() {
	REPO_ROOT="$(repo_root)"
	FUNCS="$REPO_ROOT/autoinstall-usb/lib/functions.sh"
	GRUB="$REPO_ROOT/autoinstall-usb/lib/grub.sh"
	SYSLINUX="$REPO_ROOT/autoinstall-usb/lib/syslinux.sh"
	LIB="$REPO_ROOT/autoinstall-usb/lib/validate.sh"
	SRC="source '$FUNCS'; source '$GRUB'; source '$SYSLINUX'; source '$LIB';"
}

make_fake_esp() {
	local root="$1" esp_uuid="$2" data_uuid="$3"
	mkdir -p "$root/EFI/BOOT" "$root/boot"
	: >"$root/EFI/BOOT/BOOTX64.EFI"
	: >"$root/boot/vmlinuz64"
	: >"$root/boot/corepure64.gz"
	cat >"$root/EFI/BOOT/grub.cfg" <<EOF
search --no-floppy --fs-uuid --set=root ${esp_uuid}
linux /boot/vmlinuz64 waitusb=20:UUID=${data_uuid} tce=UUID=${data_uuid} backup=UUID=${data_uuid}
initrd /boot/corepure64.gz
EOF
}

make_fake_persist() {
	local root="$1"
	mkdir -p "$root/tce/optional"
	: >"$root/tce/autoprov.env"
	local stage
	stage="$(mktemp -d)"
	mkdir -p "$stage/opt/autorun"
	printf '#!/bin/sh\ntrue\n' >"$stage/opt/bootlocal.sh"
	chmod +x "$stage/opt/bootlocal.sh"
	printf '#!/bin/sh\ntrue\n' >"$stage/opt/autorun/bootstrap.fallback.sh"
	chmod +x "$stage/opt/autorun/bootstrap.fallback.sh"
	tar -C "$stage" -czf "$root/tce/mydata.tgz" .
	rm -rf "$stage"
}

@test "validate_esp_root passes and echoes kernel|initrd for a well-formed ESP" {
	make_fake_esp "$BATS_TEST_TMPDIR/esp" ESPUUID DATAUUID
	run bash -c "$SRC validate_esp_root '$BATS_TEST_TMPDIR/esp' ESPUUID DATAUUID"
	[ "$status" -eq 0 ]
	[ "$output" = "/boot/vmlinuz64|/boot/corepure64.gz" ]
}

@test "validate_esp_root fails when BOOTX64.EFI is missing" {
	make_fake_esp "$BATS_TEST_TMPDIR/esp" ESPUUID DATAUUID
	rm "$BATS_TEST_TMPDIR/esp/EFI/BOOT/BOOTX64.EFI"
	run bash -c "$SRC validate_esp_root '$BATS_TEST_TMPDIR/esp' ESPUUID DATAUUID"
	[ "$status" -ne 0 ]
	[[ "$output" == *"missing EFI/BOOT/BOOTX64.EFI"* ]]
}

@test "validate_esp_root fails when grub.cfg does not reference the real PERSIST UUID" {
	make_fake_esp "$BATS_TEST_TMPDIR/esp" ESPUUID WRONGUUID
	run bash -c "$SRC validate_esp_root '$BATS_TEST_TMPDIR/esp' ESPUUID DATAUUID"
	[ "$status" -ne 0 ]
	[[ "$output" == *"does not reference PERSIST UUID"* ]]
}

@test "validate_esp_root fails on a syslinux APPEND line missing a persistence karg" {
	make_fake_esp "$BATS_TEST_TMPDIR/esp" ESPUUID DATAUUID
	cat >"$BATS_TEST_TMPDIR/esp/syslinux.cfg" <<'EOF'
DEFAULT tinycore
LABEL tinycore
  APPEND initrd=/boot/corepure64.gz quiet
EOF
	run bash -c "$SRC validate_esp_root '$BATS_TEST_TMPDIR/esp' ESPUUID DATAUUID"
	[ "$status" -ne 0 ]
}

@test "validate_esp_root passes with a correctly patched syslinux APPEND line" {
	make_fake_esp "$BATS_TEST_TMPDIR/esp" ESPUUID DATAUUID
	cat >"$BATS_TEST_TMPDIR/esp/syslinux.cfg" <<EOF
DEFAULT tinycore
LABEL tinycore
  APPEND initrd=/boot/corepure64.gz quiet waitusb=20:UUID=DATAUUID tce=UUID=DATAUUID backup=UUID=DATAUUID
EOF
	run bash -c "$SRC validate_esp_root '$BATS_TEST_TMPDIR/esp' ESPUUID DATAUUID"
	[ "$status" -eq 0 ]
}

@test "validate_persist_root passes for a well-formed PERSIST tree" {
	make_fake_persist "$BATS_TEST_TMPDIR/persist"
	run bash -c "$SRC validate_persist_root '$BATS_TEST_TMPDIR/persist'"
	[ "$status" -eq 0 ]
}

@test "validate_persist_root fails when mydata.tgz is missing" {
	make_fake_persist "$BATS_TEST_TMPDIR/persist"
	rm "$BATS_TEST_TMPDIR/persist/tce/mydata.tgz"
	run bash -c "$SRC validate_persist_root '$BATS_TEST_TMPDIR/persist'"
	[ "$status" -ne 0 ]
	[[ "$output" == *"missing tce/mydata.tgz"* ]]
}

@test "validate_persist_root fails when bootlocal.sh is missing from mydata.tgz" {
	mkdir -p "$BATS_TEST_TMPDIR/persist/tce/optional"
	: >"$BATS_TEST_TMPDIR/persist/tce/autoprov.env"
	local stage="$BATS_TEST_TMPDIR/stage"
	mkdir -p "$stage/opt/autorun"
	printf '#!/bin/sh\ntrue\n' >"$stage/opt/autorun/bootstrap.fallback.sh"
	chmod +x "$stage/opt/autorun/bootstrap.fallback.sh"
	tar -C "$stage" -czf "$BATS_TEST_TMPDIR/persist/tce/mydata.tgz" .
	run bash -c "$SRC validate_persist_root '$BATS_TEST_TMPDIR/persist'"
	[ "$status" -ne 0 ]
	[[ "$output" == *"missing or non-executable opt/bootlocal.sh"* ]]
}

@test "validate_persist_root fails on a cached package checksum mismatch against manifest.json" {
	make_fake_persist "$BATS_TEST_TMPDIR/persist"
	echo "not-the-real-package" >"$BATS_TEST_TMPDIR/persist/tce/optional/foo.tcz"
	cat >"$BATS_TEST_TMPDIR/persist/tce/manifest.json" <<'EOF'
{"packages":[{"name":"foo.tcz","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}]}
EOF
	if ! command -v jq >/dev/null 2>&1; then skip "jq not installed in this sandbox"; fi
	run bash -c "$SRC validate_persist_root '$BATS_TEST_TMPDIR/persist'"
	[ "$status" -ne 0 ]
	[[ "$output" == *"Checksum mismatch"* ]]
}

@test "emit_build_manifest produces JSON with the expected top-level fields" {
	make_fake_esp "$BATS_TEST_TMPDIR/esp" ESPUUID DATAUUID
	make_fake_persist "$BATS_TEST_TMPDIR/persist"
	run bash -c "$SRC emit_build_manifest '$BATS_TEST_TMPDIR/esp' '$BATS_TEST_TMPDIR/persist' ESPUUID DATAUUID /boot/vmlinuz64 /boot/corepure64.gz"
	[ "$status" -eq 0 ]
	[[ "$output" == *'"esp_uuid": "ESPUUID"'* ]]
	[[ "$output" == *'"persist_uuid": "DATAUUID"'* ]]
	[[ "$output" == *'"uefi_loader"'* ]]
	[[ "$output" == *'"bootstrap_fallback"'* ]]
	if command -v jq >/dev/null 2>&1; then
		echo "$output" | jq . >/dev/null
	fi
}

@test "emit_build_manifest hashes match sha256sum of the same files" {
	make_fake_esp "$BATS_TEST_TMPDIR/esp" ESPUUID DATAUUID
	make_fake_persist "$BATS_TEST_TMPDIR/persist"
	run bash -c "$SRC emit_build_manifest '$BATS_TEST_TMPDIR/esp' '$BATS_TEST_TMPDIR/persist' ESPUUID DATAUUID /boot/vmlinuz64 /boot/corepure64.gz"
	[ "$status" -eq 0 ]
	expected="$(sha256sum "$BATS_TEST_TMPDIR/esp/EFI/BOOT/BOOTX64.EFI" | awk '{print $1}')"
	[[ "$output" == *"\"sha256\": \"$expected\""* ]]
}
