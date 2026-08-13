#!/usr/bin/env bats
# tests/unit/usb-lib-functions.bats
#
# Pure-function tests for autoinstall-usb/lib/functions.sh. No real block
# device, loop device, or root privilege is used: lsblk is a fixture stub on
# PATH (tests/fixtures/bin/lsblk-*), never the host's own disks.

load '../helpers/bats-helpers'

setup() {
	REPO_ROOT="$(repo_root)"
	LIB="$REPO_ROOT/autoinstall-usb/lib/functions.sh"
	FIXBIN="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$FIXBIN"
}

@test "partition_path: sdX style disks get no separator" {
	run bash -c "source '$LIB'; partition_path /dev/sda 1"
	[ "$status" -eq 0 ]
	[ "$output" = "/dev/sda1" ]
}

@test "partition_path: vdX style disks get no separator" {
	run bash -c "source '$LIB'; partition_path /dev/vdb 2"
	[ "$status" -eq 0 ]
	[ "$output" = "/dev/vdb2" ]
}

@test "partition_path: nvme disks get p separator" {
	run bash -c "source '$LIB'; partition_path /dev/nvme0n1 1"
	[ "$status" -eq 0 ]
	[ "$output" = "/dev/nvme0n1p1" ]
}

@test "partition_path: mmcblk disks get p separator" {
	run bash -c "source '$LIB'; partition_path /dev/mmcblk0 1"
	[ "$status" -eq 0 ]
	[ "$output" = "/dev/mmcblk0p1" ]
}

@test "partition_path: loop devices get p separator" {
	run bash -c "source '$LIB'; partition_path /dev/loop0 2"
	[ "$status" -eq 0 ]
	[ "$output" = "/dev/loop0p2" ]
}

@test "is_whole_disk: true when mocked lsblk reports TYPE=disk" {
	cat >"$FIXBIN/lsblk" <<'EOF'
#!/usr/bin/env bash
echo "disk"
EOF
	chmod +x "$FIXBIN/lsblk"
	run env PATH="$FIXBIN:$PATH" bash -c "source '$LIB'; is_whole_disk /dev/fake"
	[ "$status" -eq 0 ]
}

@test "is_whole_disk: false when mocked lsblk reports TYPE=part" {
	cat >"$FIXBIN/lsblk" <<'EOF'
#!/usr/bin/env bash
echo "part"
EOF
	chmod +x "$FIXBIN/lsblk"
	run env PATH="$FIXBIN:$PATH" bash -c "source '$LIB'; is_whole_disk /dev/fake1"
	[ "$status" -ne 0 ]
}

@test "require_whole_disk: dies on a non-block-device path" {
	run bash -c "source '$LIB'; require_whole_disk '$BATS_TEST_TMPDIR/not-a-device'"
	[ "$status" -ne 0 ]
	[[ "$output" == *"not a block device"* ]]
}

@test "disk_serial: returns the mocked serial with no whitespace" {
	cat >"$FIXBIN/lsblk" <<'EOF'
#!/usr/bin/env bash
echo "  ABC123  "
EOF
	chmod +x "$FIXBIN/lsblk"
	run env PATH="$FIXBIN:$PATH" bash -c "source '$LIB'; disk_serial /dev/fake"
	[ "$status" -eq 0 ]
	[ "$output" = "ABC123" ]
}

@test "confirm_erase_token: assume_yes=1 skips prompt without matching" {
	cat >"$FIXBIN/lsblk" <<'EOF'
#!/usr/bin/env bash
echo "fake-disk-info"
EOF
	chmod +x "$FIXBIN/lsblk"
	run env PATH="$FIXBIN:$PATH" bash -c "source '$LIB'; confirm_erase_token /dev/fake SERIALXYZ 1"
	[ "$status" -eq 0 ]
}

@test "confirm_erase_token: wrong typed token aborts" {
	cat >"$FIXBIN/lsblk" <<'EOF'
#!/usr/bin/env bash
echo "fake-disk-info"
EOF
	chmod +x "$FIXBIN/lsblk"
	run env PATH="$FIXBIN:$PATH" bash -c "source '$LIB'; echo WRONG | confirm_erase_token /dev/fake SERIALXYZ 0"
	[ "$status" -ne 0 ]
	[[ "$output" == *"did not match"* ]]
}

@test "confirm_erase_token: correct typed token succeeds" {
	cat >"$FIXBIN/lsblk" <<'EOF'
#!/usr/bin/env bash
echo "fake-disk-info"
EOF
	chmod +x "$FIXBIN/lsblk"
	run env PATH="$FIXBIN:$PATH" bash -c "source '$LIB'; echo SERIALXYZ | confirm_erase_token /dev/fake SERIALXYZ 0"
	[ "$status" -eq 0 ]
}

@test "sha256_file: matches sha256sum of a known file" {
	echo -n "hello" >"$BATS_TEST_TMPDIR/f.txt"
	run bash -c "source '$LIB'; sha256_file '$BATS_TEST_TMPDIR/f.txt'"
	[ "$status" -eq 0 ]
	[ "$output" = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" ]
}

@test "cleanup_on_exit: unmounts, detaches loops, and removes dirs on a simulated die" {
	local_mnt="$BATS_TEST_TMPDIR/mnt"
	mkdir -p "$local_mnt"
	# Use a fake umount/losetup so no real mount/loop device is touched; just
	# verify the registered cleanup actions are invoked in the right order.
	cat >"$FIXBIN/umount" <<EOF
#!/usr/bin/env bash
echo "umount \$1" >>"$BATS_TEST_TMPDIR/cleanup.log"
EOF
	cat >"$FIXBIN/losetup" <<EOF
#!/usr/bin/env bash
echo "losetup \$*" >>"$BATS_TEST_TMPDIR/cleanup.log"
EOF
	chmod +x "$FIXBIN/umount" "$FIXBIN/losetup"
	run env PATH="$FIXBIN:$PATH" BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" bash -c "
    source '$LIB'
    trap cleanup_on_exit EXIT
    register_cleanup_mount '$local_mnt'
    register_cleanup_loop '/dev/loop77'
    register_cleanup_dir '$local_mnt'
    die 'boom'
  "
	[ "$status" -ne 0 ]
	[ ! -d "$local_mnt" ]
	grep -q "umount $local_mnt" "$BATS_TEST_TMPDIR/cleanup.log"
	grep -q "losetup -d /dev/loop77" "$BATS_TEST_TMPDIR/cleanup.log"
}
