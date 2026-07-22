# tests/

- `unit/` — Bats-core unit tests. No root privileges, no real block devices,
  no network access. See `docs/test-lab.md` and the repo root `README`
  (installation instructions for `bats-core`, added in this phase) below.
- `integration/` — QEMU/libvirt integration tests, populated starting in
  Phase 1 (USB boot) and Phase 3 (installer). Uses an isolated libvirt network
  per `docs/test-lab.md`.
- `fixtures/` — Static test inputs: sparse QEMU disk images, `OVMF_VARS.fd`,
  and (later phases) Bats fixtures for disk/network scenarios. Large binary
  fixtures (`*.qcow2`, `*.fd`, `*.iso`) are gitignored; only small text
  fixtures are committed.
- `helpers/` — Shared Bats helper functions (`load`-ed from test files).

## Installing bats-core

Any of the following works; `scripts/check-dependencies.sh` checks for the
`bats` command on `PATH` regardless of install method:

```bash
# Debian/Ubuntu package
sudo apt-get install -y bats

# npm (works anywhere Node.js is available)
npm install -g bats

# From source (pinned tag, recommended for CI reproducibility)
git clone --branch v1.11.0 --depth 1 https://github.com/bats-core/bats-core.git /tmp/bats-core
sudo /tmp/bats-core/install.sh /usr/local
```
