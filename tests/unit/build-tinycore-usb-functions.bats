#!/usr/bin/env bats
# tests/unit/build-tinycore-usb-functions.bats
#
# Phase 1 task #1 (partition_path/require_whole_disk), #3
# (patch_bootconfigs_add_karg idempotency), #4 (validate_build_tree /
# emit_build_manifest), and #10/#11 (verify_tcz_checksums manifest pinning).
#
# Exercises autoinstall-usb/lib/functions.sh directly. None of these tests
# touch real block devices, mount anything, or require root: they operate
# purely on $BATS_TEST_TMPDIR fixture trees, plain files, and (where noted)
# real read-only block-device metadata queries via lsblk.

load '../helpers/bats-helpers'

setup() {
	REPO_ROOT="$(repo_root)"
	LIB="$REPO_ROOT/autoinstall-usb/lib/functions.sh"
	load "$LIB"
}

# --- partition_path -----------------------------------------------------

@test "partition_path: sdX-style disks concatenate the partition number" {
	run partition_path /dev/sda 1
	[ "$status" -eq 0 ]
	[ "$output" = "/dev/sda1" ]

	run partition_path /dev/vdb 2
	[ "$output" = "/dev/vdb2" ]
}

@test "partition_path: nvme/mmcblk/loop disks use a 'p' separator" {
	run partition_path /dev/nvme0n1 1
	[ "$output" = "/dev/nvme0n1p1" ]

	run partition_path /dev/mmcblk0 1
	[ "$output" = "/dev/mmcblk0p1" ]

	run partition_path /dev/loop3 2
	[ "$output" = "/dev/loop3p2" ]
}

# --- require_whole_disk --------------------------------------------------

@test "require_whole_disk: rejects a path that is not a block device at all" {
	local not_a_disk="$BATS_TEST_TMPDIR/not-a-disk"
	: > "$not_a_disk"
	run require_whole_disk "$not_a_disk"
	[ "$status" -ne 0 ]
	[[ "$output" == *"must be an existing block device"* ]]
}

@test "require_whole_disk: accepts a whole disk and rejects one of its partitions (real device, read-only)" {
	# Portable-best-effort: only runs when this host exposes at least one
	# real disk with a partition via lsblk. Read-only (lsblk metadata query
	# only); never formats/mounts/writes anything. Skips cleanly on hosts/CI
	# runners with no visible block devices (e.g. some containers).
	if ! command -v lsblk >/dev/null 2>&1; then
		skip "lsblk not available"
	fi
	local disk part
	disk="$(lsblk -ndo NAME,TYPE -p 2>/dev/null | awk '$2=="disk"{print $1; exit}')"
	if [[ -z "$disk" ]]; then
		skip "no real whole disk visible to lsblk in this environment"
	fi
	part="$(lsblk -ndo NAME,TYPE -p "$disk" 2>/dev/null | awk '$2=="part"{print $1; exit}')"

	run require_whole_disk "$disk"
	[ "$status" -eq 0 ]

	if [[ -n "$part" ]]; then
		run require_whole_disk "$part"
		[ "$status" -ne 0 ]
		[[ "$output" == *"must be a whole disk"* ]]
	else
		skip "disk $disk has no partitions to test the rejection path"
	fi
}

# --- detect_tc_boot_files -------------------------------------------------

@test "detect_tc_boot_files: finds vmlinuz64 + corepure64.gz" {
	mkdir -p "$BATS_TEST_TMPDIR/esp/boot"
	touch "$BATS_TEST_TMPDIR/esp/boot/vmlinuz64" "$BATS_TEST_TMPDIR/esp/boot/corepure64.gz"
	run detect_tc_boot_files "$BATS_TEST_TMPDIR/esp"
	[ "$status" -eq 0 ]
	[ "$output" = "/boot/vmlinuz64|/boot/corepure64.gz" ]
}

@test "detect_tc_boot_files: fails when kernel or initrd is missing" {
	mkdir -p "$BATS_TEST_TMPDIR/esp/boot"
	run detect_tc_boot_files "$BATS_TEST_TMPDIR/esp"
	[ "$status" -ne 0 ]
}

# --- patch_bootconfigs_add_karg -------------------------------------------

@test "patch_bootconfigs_add_karg: appends the karg once, and stays idempotent on repeat calls" {
	mkdir -p "$BATS_TEST_TMPDIR/esp/boot/isolinux"
	cat > "$BATS_TEST_TMPDIR/esp/boot/isolinux/isolinux.cfg" <<'EOF'
label corepure64
  kernel /boot/vmlinuz64
  append initrd=/boot/corepure64.gz loglevel=3
EOF
	patch_bootconfigs_add_karg "$BATS_TEST_TMPDIR/esp" "tce=UUID=abcd-1234"
	patch_bootconfigs_add_karg "$BATS_TEST_TMPDIR/esp" "tce=UUID=abcd-1234"

	local count
	count=$(grep -o 'tce=UUID=abcd-1234' "$BATS_TEST_TMPDIR/esp/boot/isolinux/isolinux.cfg" | wc -l)
	[ "$count" -eq 1 ]
}

@test "patch_bootconfigs_add_karg: two different kargs coexist on the same append line" {
	mkdir -p "$BATS_TEST_TMPDIR/esp/boot/isolinux"
	cat > "$BATS_TEST_TMPDIR/esp/boot/isolinux/isolinux.cfg" <<'EOF'
label corepure64
  append initrd=/boot/corepure64.gz loglevel=3
EOF
	patch_bootconfigs_add_karg "$BATS_TEST_TMPDIR/esp" "tce=UUID=abcd-1234"
	patch_bootconfigs_add_karg "$BATS_TEST_TMPDIR/esp" "backup=UUID=abcd-1234"

	run grep -c 'tce=UUID=abcd-1234' "$BATS_TEST_TMPDIR/esp/boot/isolinux/isolinux.cfg"
	[ "$output" -eq 1 ]
	run grep -c 'backup=UUID=abcd-1234' "$BATS_TEST_TMPDIR/esp/boot/isolinux/isolinux.cfg"
	[ "$output" -eq 1 ]
}

@test "patch_bootconfigs_add_karg: refuses to patch when the karg already appears more than once" {
	mkdir -p "$BATS_TEST_TMPDIR/esp/boot/isolinux"
	cat > "$BATS_TEST_TMPDIR/esp/boot/isolinux/isolinux.cfg" <<'EOF'
label corepure64
  append initrd=/boot/corepure64.gz tce=UUID=abcd-1234 tce=UUID=abcd-1234
EOF
	run patch_bootconfigs_add_karg "$BATS_TEST_TMPDIR/esp" "tce=UUID=abcd-1234"
	[ "$status" -ne 0 ]
	[[ "$output" == *"already appears more than once"* ]]
}

@test "patch_bootconfigs_add_karg: warns (does not fail) when no isolinux cfg exists" {
	mkdir -p "$BATS_TEST_TMPDIR/esp"
	run patch_bootconfigs_add_karg "$BATS_TEST_TMPDIR/esp" "tce=UUID=abcd-1234"
	[ "$status" -eq 0 ]
	[[ "$output" == *"No isolinux/syslinux .cfg found"* ]]
}

# --- validate_build_tree ---------------------------------------------------

@test "validate_build_tree: fails on an incomplete tree and reports every missing file" {
	mkdir -p "$BATS_TEST_TMPDIR/esp" "$BATS_TEST_TMPDIR/persist/tce"
	run validate_build_tree "$BATS_TEST_TMPDIR/esp" "$BATS_TEST_TMPDIR/persist" "ESP-UUID" "DATA-UUID" "0"
	[ "$status" -ne 0 ]
	[[ "$output" == *"MISSING"*"BOOTX64.EFI"* ]]
	[[ "$output" == *"MISSING"*"mydata.tgz"* ]]
}

@test "validate_build_tree: passes on a complete UEFI-only tree" {
	mkdir -p "$BATS_TEST_TMPDIR/esp/boot" "$BATS_TEST_TMPDIR/esp/EFI/BOOT" "$BATS_TEST_TMPDIR/persist/tce"
	touch "$BATS_TEST_TMPDIR/esp/boot/vmlinuz64" "$BATS_TEST_TMPDIR/esp/boot/corepure64.gz"
	touch "$BATS_TEST_TMPDIR/esp/EFI/BOOT/BOOTX64.EFI"
	cat > "$BATS_TEST_TMPDIR/esp/EFI/BOOT/grub.cfg" <<'EOF'
search --fs-uuid ESP-UUID
linux /boot/vmlinuz64 tce=UUID=DATA-UUID
EOF
	touch "$BATS_TEST_TMPDIR/persist/tce/mydata.tgz" \
		"$BATS_TEST_TMPDIR/persist/tce/onboot.lst" \
		"$BATS_TEST_TMPDIR/persist/tce/autoprov.env" \
		"$BATS_TEST_TMPDIR/persist/tce/bootstrap.fallback.sh"

	run validate_build_tree "$BATS_TEST_TMPDIR/esp" "$BATS_TEST_TMPDIR/persist" "ESP-UUID" "DATA-UUID" "0"
	[ "$status" -eq 0 ]
}

@test "validate_build_tree: requires extlinux.conf/ldlinux.sys when patch_bootcodes=1" {
	mkdir -p "$BATS_TEST_TMPDIR/esp/boot" "$BATS_TEST_TMPDIR/esp/EFI/BOOT" "$BATS_TEST_TMPDIR/persist/tce"
	touch "$BATS_TEST_TMPDIR/esp/boot/vmlinuz64" "$BATS_TEST_TMPDIR/esp/boot/corepure64.gz"
	touch "$BATS_TEST_TMPDIR/esp/EFI/BOOT/BOOTX64.EFI"
	echo "search --fs-uuid ESP-UUID; linux /boot/vmlinuz64 tce=UUID=DATA-UUID" > "$BATS_TEST_TMPDIR/esp/EFI/BOOT/grub.cfg"
	touch "$BATS_TEST_TMPDIR/persist/tce/mydata.tgz" \
		"$BATS_TEST_TMPDIR/persist/tce/onboot.lst" \
		"$BATS_TEST_TMPDIR/persist/tce/autoprov.env" \
		"$BATS_TEST_TMPDIR/persist/tce/bootstrap.fallback.sh"

	run validate_build_tree "$BATS_TEST_TMPDIR/esp" "$BATS_TEST_TMPDIR/persist" "ESP-UUID" "DATA-UUID" "1"
	[ "$status" -ne 0 ]
	[[ "$output" == *"MISSING"*"extlinux.conf"* ]]

	touch "$BATS_TEST_TMPDIR/esp/extlinux.conf" "$BATS_TEST_TMPDIR/esp/ldlinux.sys"
	run validate_build_tree "$BATS_TEST_TMPDIR/esp" "$BATS_TEST_TMPDIR/persist" "ESP-UUID" "DATA-UUID" "1"
	[ "$status" -eq 0 ]
}

@test "validate_build_tree: fails if grub.cfg does not reference the expected UUIDs" {
	mkdir -p "$BATS_TEST_TMPDIR/esp/boot" "$BATS_TEST_TMPDIR/esp/EFI/BOOT" "$BATS_TEST_TMPDIR/persist/tce"
	touch "$BATS_TEST_TMPDIR/esp/boot/vmlinuz64" "$BATS_TEST_TMPDIR/esp/boot/corepure64.gz"
	touch "$BATS_TEST_TMPDIR/esp/EFI/BOOT/BOOTX64.EFI"
	echo "search --fs-uuid WRONG-UUID" > "$BATS_TEST_TMPDIR/esp/EFI/BOOT/grub.cfg"
	touch "$BATS_TEST_TMPDIR/persist/tce/mydata.tgz" \
		"$BATS_TEST_TMPDIR/persist/tce/onboot.lst" \
		"$BATS_TEST_TMPDIR/persist/tce/autoprov.env" \
		"$BATS_TEST_TMPDIR/persist/tce/bootstrap.fallback.sh"

	run validate_build_tree "$BATS_TEST_TMPDIR/esp" "$BATS_TEST_TMPDIR/persist" "ESP-UUID" "DATA-UUID" "0"
	[ "$status" -ne 0 ]
	[[ "$output" == *"does not reference expected ESP UUID"* ]]
}

# --- verify_tcz_checksums --------------------------------------------------

@test "verify_tcz_checksums: passes when files match the pinned manifest" {
	mkdir -p "$BATS_TEST_TMPDIR/tcz"
	echo "hello" > "$BATS_TEST_TMPDIR/tcz/pkg.tcz"
	local sha
	sha="$(sha256sum "$BATS_TEST_TMPDIR/tcz/pkg.tcz" | awk '{print $1}')"
	jq -n --arg h "$sha" '{extensions: {"pkg.tcz": {sha256: $h}}}' > "$BATS_TEST_TMPDIR/manifest.json"

	run verify_tcz_checksums "$BATS_TEST_TMPDIR/tcz" "$BATS_TEST_TMPDIR/manifest.json"
	[ "$status" -eq 0 ]
}

@test "verify_tcz_checksums: fails closed on a tampered package" {
	mkdir -p "$BATS_TEST_TMPDIR/tcz"
	echo "hello" > "$BATS_TEST_TMPDIR/tcz/pkg.tcz"
	local sha
	sha="$(sha256sum "$BATS_TEST_TMPDIR/tcz/pkg.tcz" | awk '{print $1}')"
	jq -n --arg h "$sha" '{extensions: {"pkg.tcz": {sha256: $h}}}' > "$BATS_TEST_TMPDIR/manifest.json"

	echo "tampered" >> "$BATS_TEST_TMPDIR/tcz/pkg.tcz"
	run verify_tcz_checksums "$BATS_TEST_TMPDIR/tcz" "$BATS_TEST_TMPDIR/manifest.json"
	[ "$status" -ne 0 ]
	[[ "$output" == *"Checksum mismatch"* ]]
}

@test "verify_tcz_checksums: fails closed on an unpinned package not present in the manifest" {
	mkdir -p "$BATS_TEST_TMPDIR/tcz"
	echo "hello" > "$BATS_TEST_TMPDIR/tcz/unpinned.tcz"
	jq -n '{extensions: {}}' > "$BATS_TEST_TMPDIR/manifest.json"

	run verify_tcz_checksums "$BATS_TEST_TMPDIR/tcz" "$BATS_TEST_TMPDIR/manifest.json"
	[ "$status" -ne 0 ]
	[[ "$output" == *"No pinned sha256"* ]]
}

@test "verify_tcz_checksums: dies clearly when the manifest file itself is missing" {
	mkdir -p "$BATS_TEST_TMPDIR/tcz"
	echo "hello" > "$BATS_TEST_TMPDIR/tcz/pkg.tcz"
	run verify_tcz_checksums "$BATS_TEST_TMPDIR/tcz" "$BATS_TEST_TMPDIR/does-not-exist.json"
	[ "$status" -ne 0 ]
	[[ "$output" == *"TCZ manifest not found"* ]]
}

# --- emit_build_manifest ----------------------------------------------------

@test "emit_build_manifest: writes valid JSON with sha256 hashes and both UUIDs" {
	mkdir -p "$BATS_TEST_TMPDIR/esp/EFI/BOOT" "$BATS_TEST_TMPDIR/esp/boot" "$BATS_TEST_TMPDIR/persist/tce"
	echo "efi" > "$BATS_TEST_TMPDIR/esp/EFI/BOOT/BOOTX64.EFI"
	echo "kernel" > "$BATS_TEST_TMPDIR/esp/boot/vmlinuz64"
	echo "data" > "$BATS_TEST_TMPDIR/persist/tce/mydata.tgz"

	local out="$BATS_TEST_TMPDIR/build-manifest.json"
	emit_build_manifest "$out" "$BATS_TEST_TMPDIR/esp" "$BATS_TEST_TMPDIR/persist" "ESP-UUID" "DATA-UUID"

	[ -f "$out" ]
	run jq -r '.esp_uuid' "$out"
	[ "$output" = "ESP-UUID" ]
	run jq -r '.data_uuid' "$out"
	[ "$output" = "DATA-UUID" ]
	run jq -r '.files["esp/EFI/BOOT/BOOTX64.EFI"]' "$out"
	[ "$output" = "$(sha256sum "$BATS_TEST_TMPDIR/esp/EFI/BOOT/BOOTX64.EFI" | awk '{print $1}')" ]
	run jq -r '.files["persist/tce/mydata.tgz"]' "$out"
	[ "$output" = "$(sha256sum "$BATS_TEST_TMPDIR/persist/tce/mydata.tgz" | awk '{print $1}')" ]
}
