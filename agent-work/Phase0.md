# Phase 0 — Developer tooling, schemas, and test harness

Status: **implemented**, pending user input on one documentation field (see
"Follow-up / open questions" at the end) and pending tool installation on any
machine that runs `make lint`/`make unit` for real (this dev sandbox lacked
shellcheck/shfmt/ansible-core/ansible-lint/yamllint/bats-core preinstalled).

## Task-by-task detail

### Makefile targets

- Initial status: not implemented (no `Makefile` existed).
- Existing implementation reviewed: none.
- Changes: added `Makefile` with `help` (default), `lint`, `unit`,
  `integration`, `test`, `build-usb-image`, `build-testbench`,
  `clean-test-artifacts`. `build-usb-image`/`build-testbench` forward
  `ARGS` to the existing `autoinstall-usb/build-tinycore-usb.sh` and
  `sysrescue-testbench/build_iso.sh` scripts rather than hardcoding any
  disk/serial value.
- Tests: `make help`, `make unit`, `make integration`,
  `make clean-test-artifacts` run correctly (see root-level test log below).
  Found and fixed a real bug during testing: the initial `integration` recipe
  used `exit 0` inside an `if` block on its own recipe line to try to skip
  later lines — in GNU Make each recipe line is its own shell, so `exit 0`
  (success) does not stop subsequent lines (only nonzero does). Rewrote as a
  single `if/elif/else` shell invocation.
- Verify later: `make lint`, `make unit`, `make integration`,
  `make build-usb-image -- --help`, `make build-testbench -- --help`.

### scripts/check-dependencies.sh

- Initial status: not implemented.
- Changes: checks bash, shellcheck, shfmt, jq, yq, curl, qemu-img,
  qemu-system-x86_64, xorriso, ansible-core (via `ansible-playbook`),
  ansible-lint, yamllint, dnsmasq (all explicitly listed in agent-plan), plus
  bats (needed by `make unit`, per the plan's own "document how it is
  installed" task) and python3/jsonschema/pyyaml (needed by
  `scripts/validate-config.sh`, which the plan requires to exist). Prints
  apt/brew hints only; never installs; exits nonzero on any miss.
- Tests: ran directly — correctly reported `MISSING` for tools absent in this
  sandbox (shellcheck, shfmt, ansible-core, ansible-lint, yamllint, bats) and
  exited 1. Ran with `PATH=/usr/bin:/bin:/usr/sbin:/sbin` — correctly reports
  `MISSING shellcheck` (not present in base system dirs) and exits nonzero.
  Bats test `tests/unit/check-dependencies.bats` automates this.
- Known issue: in this specific sandboxed terminal, `command -v` for tools
  under `$HOME/.local/bin` (yamllint, ansible-lint were pre-installed there
  outside this session) was intermittently unreliable — writes to new paths
  under `$HOME` did not reliably persist between separate sandboxed terminal
  invocations, and reads were occasionally inconsistent. This did not affect
  the script's correctness (verified by running the same `command -v` checks
  standalone with the same inconsistent results) — it is a property of this
  sandbox, not the script.

### scripts/lint.sh

- Initial status: not implemented.
- Changes: classifies tracked `*.sh` files by shebang into bash vs POSIX sh,
  runs `bash -n`/`sh -n`, `shellcheck -s <dialect>`, `shfmt -d`, `yamllint -c
  .yamllint.yml`, `ansible-lint` (skipped with an explicit message while
  `ansible/` does not exist — introduced Phase 4), cloud-init YAML syntax
  validation (any `*/cloud-init/*/{user-data,meta-data,network-config}`
  tracked file, using `python3`+`pyyaml`, stripping a leading `#cloud-config`
  line before parsing), and a secret scan (`git grep` for PEM/OpenSSH private
  key headers, plus tracked-filename patterns `id_rsa`, `id_ed25519`, `*.pem`,
  `*.p12`, `*.pfx`, `*.ppk`, `*_rsa`, `*.key`). No `|| true` on any required
  command; exits nonzero on the first category of failure and continues
  checking remaining categories so all problems are visible in one run.
- Tests: ran with shellcheck/shfmt/yamllint made available in a scratch PATH
  (none were preinstalled in this sandbox). Results:
  - `bash -n`/`sh -n`: 15 bash + 4 sh tracked scripts, all syntactically
    valid.
  - `shellcheck`: real findings only in pre-existing files —
    `autoinstall-usb/build-tinycore-usb.sh`, `autoinstall-usb/tcz/fetch-tcz.sh`,
    `autoinstall-usb/overlay/opt/autorun/autoprov-run.sh`,
    `check-so/autoinstall-ubuntu.sh`, `sysrescue-testbench/build_iso.sh`,
    `sysrescue-testbench/overlay/opt/testbench/lib/tests.sh`. Zero findings in
    any file this phase authored.
  - `shfmt -d`: same pre-existing files reformatted-diff, plus (initially) my
    own three new scripts — fixed by running `shfmt -w` on just
    `scripts/{check-dependencies.sh,lint.sh,validate-config.sh}` (mechanical,
    no logic change; re-verified with `bash -n` and `shellcheck` afterwards).
  - `yamllint`: 4 tracked YAML files, no findings.
  - secret scan: no private-key material, no secret-pattern filenames.
  - Overall exit is nonzero solely due to the pre-existing shellcheck/shfmt
    findings above, all in files whose refactor is explicitly scheduled for
    Phase 1, Phase 2, or Phase 13 — not Phase 0. Confirmed with
    `tests/unit/lint-secrets.bats` that the secret-scan portion specifically
    passes clean on the real repository.
- Verify later: once Phase 1/2/13 land, `make lint` should exit 0 on a clean
  checkout (assuming shellcheck/shfmt/yamllint/ansible-lint are installed).

### JSON Schemas + safe examples (config/schema, config/examples)

- Initial status: not implemented.
- `machines.schema.json`: models `machines` as an object keyed by machine ID
  (`^[a-z][a-z0-9-]{1,62}$`) so uniqueness of the ID is enforced by JSON
  object semantics rather than a custom keyword. Each machine requires
  `role` (enum `supervisor|nas|proxmox|edge`), `mac`
  (`^([0-9a-f]{2}:){5}[0-9a-f]{2}$`), and `disk_serial` (every role performs a
  destructive install per the architecture, so it's required for all, not
  conditional). `hostname`, `ip` (format `ipv4`), `hardware_serial`, and a
  free-form `vars` object are optional. Deliberately does **not** attempt to
  enforce cross-machine MAC/hostname/IP uniqueness — agent-plan Phase 6
  explicitly assigns that to `scripts/render-machine-config.sh`.
- `network.schema.json`: the exact §2.3 two-interface variable list, all
  required, plus an opt-in `allow_default_route_interface` boolean matching
  §2.3's "unless an explicit override is set". Cross-field checks (interface
  overlap, default-route detection) are left to the Phase 5 Ansible role,
  since JSON Schema draft-07 cannot cleanly compare two sibling property
  values.
- `installer.schema.json`: modeled directly on the real
  `autoinstall-usb/bootstrap/installer.env` keys (`EXCLUDE_UUID`,
  `CHECK_UUID`, `SEED_URL`, `CONFIG_VERSION`, `RELEASE`, `ARCH`, `TCE_DIR`)
  plus the safety flags referenced by later phases (`RUN_ONCE`, `DRY_RUN`,
  `ALLOW_DESTRUCTIVE`). This is the validated document shape Phase 2 will
  render into the real `KEY=VALUE` file when it replaces the sourced env
  file with strict parsing.
- Safe examples use RFC 5737 documentation ranges (`192.0.2.0/24`,
  `198.51.100.0/24`) and fake MACs (`de:ad:be:ef:00:0N`).
- Tests: `./scripts/validate-config.sh` (all three examples) passes.
  Regex bugs found and fixed during testing:
  - `EXCLUDE_UUID`/`CHECK_UUID` patterns initially required a leading 4-hex
    group for full UUIDs (wrong length: 8-4-4-4-12, not 4-4-4-4-12) — fixed
    to a proper alternation between the short FAT-style `XXXX-XXXX` form and
    the full 8-4-4-4-12 form; `CHECK_UUID` additionally allows the empty
    string.
  - `scripts/lib/validate_config.py` initially computed `REPO_ROOT` one
    directory too shallow (`parents[1]` instead of `parents[2]`, since the
    file lives at `scripts/lib/validate_config.py`) — fixed, verified by
    re-running the validator.

### scripts/validate-config.sh + scripts/lib/validate_config.py

- Initial status: not implemented.
- Design: thin bash wrapper (checks `python3` + `jsonschema`/`pyyaml`
  presence, matching `scripts/check-dependencies.sh`'s hints) execing a
  Python helper. The helper matches a file to a schema by its name up to the
  first `.` (e.g. `machines.example.yml` → `machines.schema.json`) and
  reports an explicit error (not a silent skip) for any file whose prefix
  doesn't match a known schema — this was required by the no-inference /
  no-silent-skip discipline for new config types.
- Tests: `tests/unit/validate-config.bats` (3 cases: valid examples pass;
  malformed MAC reports the exact `[machines.supervisor-01.mac]` field path
  without modifying the repo fixture; unknown schema prefix is reported, not
  skipped) — all pass.

### docs/test-lab.md and docs/safety.md

- `test-lab.md`: documents the isolated libvirt network name/subnet, VM
  naming convention per later phase, and the fixture-to-virtual-disk mapping
  already implied by the QEMU comment block in
  `check-so/autoinstall-ubuntu.sh`.
- `safety.md`: transcribes agent-plan §3's global safety rules into
  destructive-boundary/emergency-stop/recovery sections so they're
  discoverable without reading the whole plan.
- **Open item**: `test-lab.md`'s "Physical test machine" table is left as
  `TBD` — no real disposable-hardware identity (model/disk serial) was
  available to record, and the no-inference policy prohibits inventing one.
  See "Follow-up / open questions" below.

### tests/ scaffolding + Bats-core

- Added `tests/unit/`, `tests/integration/` (placeholder `.gitkeep`, empty by
  design until Phase 1), `tests/fixtures/` (now holding the moved qcow2/OVMF
  fixtures), `tests/helpers/bats-helpers.bash` (repo-root resolution +
  scratch-config copy helper used by the bats tests).
- `tests/README.md` documents three bats-core install methods (apt, npm,
  pinned-tag source build via `install.sh`) since none is universally
  available.
- Tests: installed bats-core 1.11.0 from the pinned `v1.11.0` source tag
  (`git clone --branch v1.11.0 --depth 1 .../bats-core.git && install.sh`) to
  verify the harness; `bats tests/unit` → 7/7 pass. Two test-authoring bugs
  found and fixed during this verification:
  1. `check-dependencies.bats` originally built a fully-fake `PATH` including
     a stub named `bash`; since `check-dependencies.sh`'s shebang is
     `#!/usr/bin/env bash`, `env` resolved the *fake* stub instead of a real
     shell, so the script under test never actually ran (masked as an
     unrelated failure). Fixed by testing against a real-but-narrowed
     `PATH=/usr/bin:/bin:/usr/sbin:/sbin` instead of synthetic stubs.
  2. `lint-secrets.bats` asserted `git status --porcelain` was empty after
     planting a fake key *outside* the repo — but the working tree already
     has this phase's own staged additions, so the assertion was unrelated
     to the fake key and always failed. Fixed to assert only that the fake
     key's path/filename never appears in `git status --porcelain -- .`.

### Moving check-so fixtures / .gitignore

- `check-so/{nvme,scsi,ssd,testdisk}.qcow2` and `check-so/OVMF_VARS.fd` were
  already untracked (matched by the pre-existing `*.qcow2`/`*.fd` gitignore
  patterns), so a plain `mv` was used instead of `git mv` (which correctly
  refused, since there was nothing under version control to move). Updated
  the QEMU example invocation comment in `check-so/autoinstall-ubuntu.sh` to
  reference `../tests/fixtures/...`.
- `.gitignore`: added `tests/tmp/`, `tests/**/*.log`, `.cache/`,
  `node_modules/`, `*.bats.log`, `build-manifest.json`. Deliberately did
  **not** add `autoinstall-usb/isos/` or `autoinstall-usb/tcz-cache/` here —
  `isos/` ignoring is an explicit Phase 3 task, and `tcz-cache/` already
  contains tracked files (`bootlocal.sh`, `onboot.lst`), so blanket-ignoring
  it now would be scope creep belonging to Phase 1's TCZ caching cleanup.

## Regression / full-suite evidence

```
$ ./scripts/validate-config.sh
validate-config: 3 file(s) valid

$ bats tests/unit
7 tests, 0 failures

$ make unit / make integration / make clean-test-artifacts / make help
(all behave as documented — see task sections above)

$ ./scripts/lint.sh   (shellcheck/shfmt/yamllint available via scratch PATH)
bash -n / sh -n: all pass
shellcheck, shfmt: findings only in pre-existing Phase 1/2/13-owned files
yamllint: 4 files, no findings
secret scan: no private keys, no secret filenames
exit 1 (expected — see "Errors and known issues" in the agent-plan comment)
```

## Assumptions and dependencies

- `python3` + `jsonschema` + `pyyaml` are treated as a dependency of
  `scripts/validate-config.sh` and were added to
  `scripts/check-dependencies.sh` even though the plan's explicit tool list
  for that script doesn't name them — they're required for the schema
  validation task the plan does require, and jsonschema's built-in
  `FormatChecker` provides `ipv4`/`uri` format validation without further
  optional dependencies.
- `bats-core` was likewise added to `check-dependencies.sh` beyond the plan's
  literal list, since the plan separately mandates "document how it is
  installed" and `make unit` depends on it.

## Follow-up / open questions

1. **Needs user input**: `docs/test-lab.md`'s physical test machine
   model/disk serial is `TBD`. Please provide the disposable hardware
   identity (or confirm none has been set aside yet) so this can be filled in
   before any phase's physical-machine test is run.
2. Install shellcheck, shfmt, ansible-core, ansible-lint, yamllint, and
   bats-core on the real development workstation (via
   `scripts/check-dependencies.sh`'s hints) to get a fully green `make lint
   unit` — this sandbox only had a subset preinstalled.
3. `make lint` will not be exit-0-clean until Phase 1 (`autoinstall-usb`),
   Phase 2 (`check-so`), and Phase 13 (`sysrescue-testbench`) fix the
   pre-existing shellcheck/shfmt findings identified above; that is expected
   and by design, not a Phase 0 defect.
