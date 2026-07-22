# Test lab

This document describes the isolated environments used to run the local and
integration tests required by every phase of `agent-plan`.

## Isolated libvirt network

- **Network name:** `serverutils-pxe-test`
- **Mode:** `isolated` (no `<forward>` element) — no bridge or NAT to the real
  LAN, matching global safety rule #10 (agent-plan §3).
- **Subnet:** `198.51.100.0/24` (TEST-NET-2, documentation-only range), matching
  `config/examples/network.example.yml`.
- Create it once per workstation:

  ```bash
  virsh net-define tests/fixtures/serverutils-pxe-test.xml   # added when Phase 5 needs it
  virsh net-start serverutils-pxe-test
  virsh net-autostart serverutils-pxe-test
  ```

  The network XML itself is added in the phase that first needs a PXE client
  (Phase 5), so this file does not yet exist in Phase 0.

## VM naming convention

| VM name              | Role                          | Introduced in |
| --------------------- | ------------------------------ | ------------- |
| `supervisor-test`      | Supervisor install/PXE server  | Phase 1 / 3 / 5 |
| `pxe-client-known`     | Registered PXE client (role test) | Phase 6 |
| `pxe-client-unknown`   | Unregistered PXE client (safety test) | Phase 6 |
| `nas-test`             | NAS install/OMV convergence    | Phase 7 |
| `proxmox-test`         | Proxmox install/convergence    | Phase 8 |
| `edge-test`            | Edge node (VPN/DNS/runner)     | Phase 9 |

## Virtual disk types used in tests

Fixture sparse images live in `tests/fixtures/` and back the QEMU test targets
documented in the comment block at the end of
[check-so/autoinstall-ubuntu.sh](../check-so/autoinstall-ubuntu.sh):

| File                                   | Bus/controller     | Represents |
| --------------------------------------- | ------------------ | ---------- |
| `tests/fixtures/testdisk.qcow2`         | `ide-hd` on `ich9-ahci` | SATA disk |
| `tests/fixtures/ssd.qcow2`              | `virtio-blk-pci`   | virtio SSD |
| `tests/fixtures/nvme.qcow2`             | `nvme`             | NVMe disk |
| `tests/fixtures/scsi.qcow2`             | `scsi-hd` on `virtio-scsi-pci` | SCSI/rotational disk |
| `tests/fixtures/OVMF_VARS.fd`           | `pflash`           | UEFI NVRAM variable store |

These are created as sparse files with `qemu-img create -f qcow2 <name> <size>`
and are gitignored (`*.qcow2`, `*.fd`); only their presence under
`tests/fixtures/` and this table are checked in.

## Physical test machine

**Status: not yet selected.**

The disposable physical machine and target disk serial used for the
physical-machine test sections of every phase must be recorded here before any
phase's physical-machine test is run, per agent-plan §1 completion criteria
("The physical-machine test passes on disposable hardware"). Do not invent a
placeholder serial: fill in the table below once real hardware is set aside
for testing, then update this document.

| Field                    | Value |
| ------------------------- | ----- |
| Machine model              | TBD |
| Disposable test disk model  | TBD |
| Disposable test disk serial | TBD |
| Network switch/segment used | TBD |

## Related documentation

- [safety.md](safety.md) — destructive boundaries and emergency stop/recovery.
- [agent-plan](../agent-plan) — full phased implementation plan.
