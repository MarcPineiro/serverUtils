# Phase 1 — Make the Tiny Core USB deterministic and single-run

Status: **code tasks complete**. All Local-test/Physical-machine test steps
that require root, a loop/real block device, or QEMU/OVMF are **blocked in
this sandbox** and must be run by a human with root on disposable
hardware/VM before Phase 1 is accepted per the plan's own completion
criteria (§1: automated tests + QEMU test + physical-machine test +
evidence, all required).

## Session context

- Project root / write boundary: `/home/mpi/git/personal/serverUtils`
  (repository root is `/home/mpi/git`; only `personal/serverUtils/**` and the
  OS temp directory are writable this session).
- Sandbox facts verified before starting: `uid=1000(mpi)` (no root), `sudo`
  unavailable/forbidden, `losetup`/`mount`/`mkfs` on real or loop-backed block
  devices require root and were **not** exercised against real or loop
  devices in this session. `shellcheck`/`shfmt` are still not preinstalled.
  `bats-core` v1.11.0 was fetched from its pinned upstream GitHub tag into a
  scratch `$TMPDIR` prefix purely to run the unit suite below (network access
  used only to reach `github.com`, never any project remote endpoint).
- Consequence for testing: all Local-test steps in the plan that require
  `--image` + loop-attach, real `--dev`, or QEMU/OVMF boot are **blocked in
  this session** (require root, which this agent must not use/escalate to).
  Every other step (argument parsing, pure functions, state-machine logic,
  idempotent config patching, manifest generation logic, env parsing,
  retry/backoff logic, boot-lock mkdir semantics, JSON manifest emission) is
  verified with mocked commands and fixtures under `$TMPDIR`/`$BATS_TEST_TMPDIR`.
  Exact manual verification procedures are recorded per task below for later
  execution by a human with root on a disposable workstation/VM.

## Task-by-task detail

### Refactor `build-tinycore-usb.sh` into small functions
Split into `autoinstall-usb/lib/{functions.sh,grub.sh,syslinux.sh,validate.sh}`,
sourced by `build-tinycore-usb.sh` and `validate-build.sh`. `functions.sh`
holds `partition_path`, `is_whole_disk`/`require_whole_disk`, `disk_serial`,
`print_disk_info`, `confirm_erase_token`, `sha256_file`,
`verify_tcz_dir_against_manifest`, and the `CLEANUP_MOUNTS`/`CLEANUP_LOOPS`/
`CLEANUP_DIRS` EXIT-trap registry (`cleanup_on_exit`, registered once via
`trap cleanup_on_exit EXIT` at the top of each top-level script). `--image
PATH --image-size SIZE` builds into a loop-attached raw file instead of a
real disk. Tested: `tests/unit/usb-lib-functions.bats` (13 tests, mocked
`lsblk`/`umount`/`losetup`).

### Project-owned GRUB UEFI configuration
`autoinstall-usb/lib/grub.sh`: `detect_tc_boot_files` (locates
`vmlinuz*`/`*.gz` under `/boot`), `render_grub_cfg` (pure, stdout-only —
normal entry, diagnostic entry with `loglevel=8 tc_verbose=1`, and a
Phase-3-reserved Ubuntu autoinstall entry guarded by an `if [ -f ... ]` so it
never appears unless Phase 3 has populated `/ubuntu/casper/*`),
`generate_grub_uefi_loader` (always regenerates `EFI/BOOT/grub.cfg` +
`BOOTX64.EFI` via `grub-mkstandalone`; never trusts the ISO's own loader).
Tested: `tests/unit/usb-lib-grub.bats` (5 tests).

### Legacy BIOS/syslinux patching
`autoinstall-usb/lib/syslinux.sh`: `patch_append_line`/`strip_karg`
(idempotent `tce=`/`backup=`/`waitusb=` rewriting), `verify_append_line_once`
(dies unless each karg appears exactly once), `patch_syslinux_file`/
`find_syslinux_configs` (no-op, not an error, when the ISO ships no legacy
loader). Tested: `tests/unit/usb-lib-syslinux.bats` (7 tests).

### Post-build validator + `build-manifest.json`
Added `autoinstall-usb/lib/validate.sh` and the top-level
`autoinstall-usb/validate-build.sh` (`--dev /dev/sdX` or `--image FILE`,
`--out build-manifest.json`). It mounts the ESP and PERSIST partitions
read-only, then:
- `validate_esp_root`: `EFI/BOOT/BOOTX64.EFI` + `EFI/BOOT/grub.cfg` exist;
  `grub.cfg` references both the real ESP and PERSIST UUIDs; kernel/initrd
  detected via `detect_tc_boot_files` exist; every syslinux/isolinux APPEND
  line (if any) carries the PERSIST UUID exactly once via
  `verify_append_line_once`.
- `validate_persist_root`: `tce/mydata.tgz` and `tce/autoprov.env` exist;
  warns (does not fail) if `tce/onboot.lst` is absent (optional, no
  `--pkg-list` build); if `tce/optional/*.tcz` exist, re-verifies every
  checksum against `tce/manifest.json` via the shared
  `verify_tcz_dir_against_manifest`; extracts `mydata.tgz` to a throwaway
  dir and confirms `opt/bootlocal.sh` is present+executable and (if bundled)
  `opt/autorun/bootstrap.fallback.sh` is present, executable, and has a
  shell shebang.
- `emit_build_manifest`: pure function, prints `build-manifest.json` (sha256
  of the UEFI loader, grub.cfg, kernel, initrd, `mydata.tgz`, `onboot.lst`
  when present, every cached `.tcz`, and the bundled
  `bootstrap.fallback.sh` extracted from the archive, plus both real
  filesystem UUIDs and a UTC timestamp) to stdout; the caller redirects it
  to `--out`.
`verify_tcz_dir_against_manifest` was moved from `build-tinycore-usb.sh` into
`lib/functions.sh` so both the builder (verify before copying onto
`TINYDATA`) and the validator (re-verify after the fact, from the built
image alone) share one implementation.
Tested: `tests/unit/usb-lib-validate.bats` (11 tests) — every check exercised
against synthetic ESP/PERSIST fixture trees under `$BATS_TEST_TMPDIR`
(well-formed tree passes; each individual failure mode — missing
`BOOTX64.EFI`, wrong UUID in `grub.cfg`, missing/incorrect syslinux karg,
missing `mydata.tgz`, missing `bootlocal.sh` inside the archive, a
manifest.json checksum mismatch — is asserted to fail with the right
message; manifest JSON hashes cross-checked against `sha256sum` directly).
**Blocked in this session:** actually mounting a built image's real
partitions (`validate-build.sh --image ...`) requires `losetup`/`mount` as
root; not exercised here.

### Single authoritative launch path
Removed `autoinstall-usb/overlay/etc/init.d/autoprov` and
`autoinstall-usb/overlay/etc/rc.d/S99autoprov` (the second potential launch
path). `opt/bootlocal.sh` is the sole entrypoint Tiny Core invokes at boot;
it in turn calls `opt/autorun/autoprov-run.sh`, which is itself
lock-protected (see below), so even a stray manual second invocation in the
same boot is a harmless no-op.

### Repaired `autoprov-run.sh` / new `lib.sh`
`autoinstall-usb/overlay/opt/autorun/lib.sh` (new, POSIX `sh`/BusyBox `ash`
compatible — no bash arrays, no `[[ ]]`) provides: `ap_write_state`,
`ap_acquire_lock`/`ap_release_lock` (mkdir-based lock — atomic on
ext4/FAT), `ap_wait_for_network` (bounded poll via `ip route`/`route -n`,
never fatal on timeout), `ap_validate_downloaded` (nonempty + `#!` shebang +
optional sha256 match), `ap_download_once` and `ap_download_with_retry`
(cache-busted URL per attempt, bounded retries with a delay, atomic
`.attempt` file + `mv` into the final path, clear error when neither `curl`
nor `wget` exists).
`autoprov-run.sh` itself now: writes `state/autoprov.{started,running,
downloaded,succeeded,failed}` at the right points; only writes the
persistent `RUN_ONCE` flag after the **downloaded remote controller**
succeeds (a fallback-only run never sets it, so the next boot keeps
retrying the real controller); preserves `state/autoprov.download-failed.sh`
and `state/autoprov.controller-failed.sh` for diagnosis; runs
`FALLBACK_SCRIPT` (`/opt/autorun/bootstrap.fallback.sh`) only after remote
retries are exhausted.
**Bug found and fixed during testing:** in POSIX `sh`, functions share
global variable scope. `ap_download_once` and `ap_download_with_retry` both
used bare `url`/`dest` (no `local`), so calling `ap_download_once` from
inside `ap_download_with_retry`'s retry loop silently clobbered the
caller's own `dest`, making the final `mv "$attempt" "$dest"` a no-op
(`mv` of a file onto itself) instead of renaming into the real destination
path. Fixed by adding `local` declarations to `ap_wait_for_network`,
`ap_validate_downloaded`, `ap_download_once`, and `ap_download_with_retry`.
Confirmed `dash -n`/`sh -n` accept `local` (both dash and BusyBox `ash`
support it as a standard extension). A regression test
(`tests/unit/autoprov-lib.bats`, "writes the final content at the exact
requested dest path") fails without the fix and passes with it.
Tested: `tests/unit/autoprov-lib.bats` (13 tests) — `ap_validate_downloaded`
(empty/no-shebang/sha256 match+mismatch), `ap_download_once` with no
curl/wget on a minimal mocked `PATH`, `ap_download_with_retry` (dest-clobber
regression + bounded-retry-then-give-up with a mocked failing `curl`),
`ap_acquire_lock`/`ap_release_lock` (atomic, reusable after release),
`ap_wait_for_network` (immediate success / bounded timeout with a mocked
`ip`), and two full-script runs of `autoprov-run.sh` itself: a malformed
environment file missing `GITHUB_BOOTSTRAP_URL` fails loudly before any
network activity, and a run with no curl/wget/fallback available on a
minimal `PATH` still terminates (never hangs) and records
`state/autoprov.failed`.
**Blocked in this session:** a real boot, real network wait, and real
`RUN_ONCE` persistence across reboots.

### `bootstrap.fallback.sh`
`build_usb()` bundles `--controller-src` (default
`check-so/autoinstall-ubuntu.sh`) into the staged overlay as
`opt/autorun/bootstrap.fallback.sh` before packing `mydata.tgz`, prints its
sha256 at build time, and the post-build validator/manifest re-extract and
re-hash it from the built archive. `--no-bundle-fallback` exists for
test-only builds that intentionally skip it.

### `mount-tinydata.sh` log-path fix
It now prints and lists `$MNT/tce/logs/` (the mountpoint this invocation of
the script actually mounted) instead of the build host's own
`/etc/sysconfig/tcedir/logs/`, which only resolves inside a *booted* Tiny
Core system and never on the build workstation.

### Removed duplicate cached `bootlocal.sh` / single source of truth
Deleted `autoinstall-usb/tcz-cache/bootlocal.sh`. `mydata.tgz` is now always
packed directly from a staged copy of `OVERLAY_DIR` (with only the fallback
controller injected), so there is exactly one source for `opt/bootlocal.sh`.

### Pinned Tiny Core version + extension checksums
Added `autoinstall-usb/tcz/pinned-version.json` (TC release/arch/mirror) and
extended `tcz/fetch-tcz.sh` to emit a `manifest.json` (sha256 per downloaded
`.tcz`) alongside the cache, consumed by both
`verify_tcz_dir_against_manifest` (build-time and validate-time) and the
build manifest.
Tested: `tests/unit/tcz-fetch-manifest.bats` (3 tests: manifest emission,
loud failure on an md5 mismatch, defaults resolved from
`pinned-version.json`).

### TCZ caching pipeline: single canonical package list
Deleted the stale `autoinstall-usb/tcz-cache/onboot.lst` and
`tcz-cache/tce/onboot.lst`; `autoinstall-usb/tcz/onboot.lst` is the only
package list read anywhere in the pipeline. `.gitignore` now excludes
`autoinstall-usb/tcz-cache/` entirely (it is 100% regenerated by
`fetch-tcz.sh`, never a source of truth, never to be committed).

### `autoinstall-usb/isos/` for offline ISO storage
Already existed as a local (gitignored, `*.iso`) directory holding Tiny
Core/CorePlus ISOs; reserved verbatim for Phase 3's `--offline-installer`
flow. No code changes needed in Phase 1 beyond confirming the directory and
`.gitignore` rule already exist.

### Tests for malformed environment files and missing network tools
`tests/unit/autoprov-lib.bats` covers both explicitly (see above): a
`tce/autoprov.env` missing `GITHUB_BOOTSTRAP_URL` fails `autoprov-run.sh`
loudly and immediately, and running with neither `curl` nor `wget` on
`PATH` degrades to the offline-fallback path and records
`state/autoprov.failed` instead of hanging or crashing uncleanly.

## Tests performed (this session)

- Installed `bats-core` v1.11.0 from its pinned upstream GitHub tag into a
  scratch `$TMPDIR` prefix (no root, no system-wide install; the corporate
  npm registry mirror does not carry the `bats` package).
- `bats tests/unit/` — **60 tests, 0 failures** (includes all pre-existing
  Phase 0 tests plus this phase's `usb-lib-functions.bats`,
  `usb-lib-grub.bats`, `usb-lib-syslinux.bats`, `usb-lib-validate.bats`, and
  `autoprov-lib.bats`).
- `bash -n` / `dash -n` / `sh -n` on every new/modified script — all clean.
- `shellcheck`/`shfmt` remain unavailable in this sandbox (as in Phase 0);
  not exercised here.

## Blocked pending human + root + disposable hardware/VM

Per the plan's own Phase-1 acceptance criteria, none of the following can be
signed off from this sandbox and must be run by a human with root access
before Phase 1 is considered *accepted* (the code/unit-test portion is
complete):

- Local test steps 1–10: building a real `--image` + loop-attach, running
  `validate-build.sh` against it, booting under QEMU/OVMF (UEFI) and SeaBIOS
  (legacy), verifying persistence/run-once/fallback behaviour across
  reboots, and deliberately corrupting a cached extension to confirm
  post-build validation fails.
- Physical-machine test steps 1–9: building onto a real, disposable USB
  with a recorded serial, booting a disposable PC with all other disks
  disconnected, and confirming the same behaviours on real hardware in both
  UEFI and legacy BIOS modes.
- Completion evidence: UEFI/BIOS QEMU console logs, physical boot logs from
  `TINYDATA`, and a `build-manifest.json` matching an actually-tested USB —
  none of these can be produced without the steps above.

