SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Extra arguments forwarded to build-usb-image / build-testbench, e.g.:
#   make build-usb-image ARGS="--image /tmp/usb.img --image-size 2G"
ARGS ?=

.PHONY: help lint unit integration test build-usb-image build-testbench clean-test-artifacts

help:
	@echo "Targets:"
	@echo "  lint                 Run scripts/lint.sh (shell, YAML, ansible-lint, secrets)"
	@echo "  unit                 Run tests/unit with bats-core"
	@echo "  integration          Run tests/integration (QEMU/libvirt, later phases)"
	@echo "  test                 lint + unit + integration"
	@echo "  build-usb-image      Run autoinstall-usb/build-tinycore-usb.sh (ARGS=...)"
	@echo "  build-testbench      Run sysrescue-testbench/build_iso.sh (ARGS=...)"
	@echo "  clean-test-artifacts Remove generated test outputs (not checked-in fixtures)"

lint:
	./scripts/lint.sh
	./scripts/validate-config.sh

unit:
	@if ! command -v bats >/dev/null 2>&1; then \
		echo "[unit] bats-core not found. See scripts/check-dependencies.sh."; \
		exit 1; \
	fi
	bats tests/unit

integration:
	@if [ -z "$$(find tests/integration -mindepth 1 -not -name '.gitkeep' -not -name 'README.md' 2>/dev/null)" ]; then \
		echo "[integration] no integration tests yet (introduced starting Phase 1)"; \
	elif ! command -v bats >/dev/null 2>&1; then \
		echo "[integration] bats-core not found. See scripts/check-dependencies.sh."; \
		exit 1; \
	else \
		bats tests/integration; \
	fi

test: lint unit integration

build-usb-image:
	./autoinstall-usb/build-tinycore-usb.sh $(ARGS)

build-testbench:
	./sysrescue-testbench/build_iso.sh $(ARGS)

clean-test-artifacts:
	rm -rf tests/tmp
	rm -f /tmp/lint-secret-keys.*
	find tests/unit tests/integration -name '*.log' -delete 2>/dev/null || true
	@echo "[clean-test-artifacts] done (tests/fixtures/* checked-in fixtures were not touched)"
