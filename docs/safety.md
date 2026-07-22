# Safety boundaries and emergency recovery

This document is the authoritative summary of the destructive-operation rules
in `agent-plan` §3 ("Global safety and test rules") and each phase's
safety-specific tasks. If any script's behavior contradicts this document,
treat it as a bug and stop.

## Destructive boundaries

1. **Whole-disk selection only.** Every destructive command must operate on an
   explicitly selected whole-disk device, never a partition path guessed from
   a pattern.
2. **Identity by major/minor, not by name.** `/dev/sdX` names are not stable;
   controllers must resolve and compare kernel major/minor numbers.
3. **Hard exclusions.** The following are refused unconditionally and can never
   be selected as a destructive target:
   - The disk backing the currently running live/installer media.
   - Any disk carrying an excluded filesystem UUID or PARTUUID
     (`EXCLUDE_UUID` in `installer.env` / `config/schema/installer.schema.json`).
   - Any mounted disk.
   - The disk backing the running root filesystem.
   - Any disk whose serial does not match the inventory entry
     (`config/schema/machines.schema.json` → `disk_serial`).
4. **`DRY_RUN=1` by default.** Every destructive controller (`check-so`,
   `autoinstall-usb`, `sysrescue-testbench`) defaults to a dry run until the
   physical-installation phase for that component has been explicitly
   accepted. Non-interactive destructive execution additionally requires all
   of:
   - `ALLOW_DESTRUCTIVE=1`
   - A matching machine identity (normalized MAC, optionally hardware serial)
   - A matching target disk serial
   - A valid, checksummed/signed configuration manifest
5. **Never bypass exclusions in a fallback selector.** If the primary selection
   logic refuses a disk, no fallback path may pick it anyway.
6. **Pinned downloads only.** Every externally fetched artifact (Tiny Core
   extensions, Ubuntu/Debian/Proxmox installer media, iPXE binaries, GitHub
   runner) is pinned to an exact version and verified against a recorded
   SHA-256 (or stronger) checksum before use.

## Emergency stop

- **During a Tiny Core / installer run:** power off the target machine
  (hold power button) or physically disconnect the target disk. Because
  `DRY_RUN=1` is the default and destructive execution requires the four
  conditions in rule 4, an unattended boot should never reach an irreversible
  write; if it does, treat it as a critical bug and open an issue referencing
  the log under `TINYDATA`/`tests/fixtures` before re-running anything.
- **During an Ansible run:** interrupt with `Ctrl-C` or stop the
  `autoprov-pull` unit (`systemctl stop autoprov-pull.service`, introduced in
  Phase 10). `ansible-pull` promotes checkouts atomically, so an interrupted
  run leaves the previous successful checkout and `config_version` untouched.
- **During PXE service testing:** stop `dnsmasq`/`nginx` on the supervisor;
  because the PXE network is isolated (agent-plan §2.3, §3 rule 10), stopping
  these services cannot affect the household/office LAN.
- **During SystemRescue TestBench destructive tests:** these always require
  typing the exact selected disk identity as a confirmation token; closing the
  terminal/VM before confirming aborts the test with no writes performed.

## Recovery procedures

| Failure | Recovery |
| ------- | -------- |
| USB will not boot | Rebuild from the pinned Tiny Core manifest (`autoinstall-usb/bootstrap/`); see the Phase 1 runbook once written in `docs/machine-onboarding.md` (Phase 14). |
| Wrong/ambiguous disk selected | Re-run `check-so` `inspect` (read-only) and compare against `config/machines.yml`; the controller must refuse to proceed while state is `ambiguous`/`unsafe`. |
| Ansible run failed mid-convergence | `config_version` is only written after every role succeeds (agent-plan §2.5), so a failed run is detected on the next `inspect`/pull and safely retried; no partial version is ever recorded. |
| PXE asset corruption | `pxe_assets` (Phase 5) retains one prior verified version and only promotes a new one after full checksum verification; roll back by re-promoting the retained version. |
| Bad Ansible convergence pushed to `main` | Use the Phase 10 rollback command to reapply the previous successful checkout on affected hosts. |

## Reporting

Every destructive-capable script must log (agent-plan §3 rule 9):
timestamp, selected machine identity, selected disk identity, state
transition, the exact command attempted, and the final result. Logs are
required evidence for every phase's "Completion evidence" section and must
never contain secrets (private keys, tokens, passwords) — see
`scripts/lint.sh`'s secret scanner and `scripts/collect-diagnostics.sh`
(Phase 14).
