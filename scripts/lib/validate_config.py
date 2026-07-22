#!/usr/bin/env python3
"""JSON Schema validation helper for scripts/validate-config.sh.

Validates YAML/JSON configuration documents under config/examples/ (and any
non-secret files under config/) against the schemas in config/schema/,
matching each file to a schema by its leading name component
(e.g. machines.example.yml -> machines.schema.json).

Never invents or guesses schema mappings for unrecognized prefixes: an
unmatched file is reported as an error so new config types are wired up
explicitly instead of silently skipped.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import yaml
from jsonschema import Draft7Validator, FormatChecker

REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_DIR = REPO_ROOT / "config" / "schema"


def load_schema(name: str) -> dict:
    path = SCHEMA_DIR / f"{name}.schema.json"
    if not path.is_file():
        raise FileNotFoundError(f"no schema found at {path}")
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def schema_name_for(file_path: Path) -> str:
    # "machines.example.yml" -> "machines"; "network.yml" -> "network"
    return file_path.name.split(".", 1)[0]


def validate_file(file_path: Path) -> list[str]:
    errors: list[str] = []
    schema_name = schema_name_for(file_path)
    try:
        schema = load_schema(schema_name)
    except FileNotFoundError as exc:
        return [f"{file_path}: {exc}"]

    with file_path.open("r", encoding="utf-8") as fh:
        try:
            document = yaml.safe_load(fh)
        except yaml.YAMLError as exc:
            return [f"{file_path}: invalid YAML/JSON: {exc}"]

    validator = Draft7Validator(schema, format_checker=FormatChecker())
    for error in sorted(validator.iter_errors(document), key=lambda e: list(e.path)):
        field_path = ".".join(str(p) for p in error.path) or "<root>"
        errors.append(f"{file_path}: [{field_path}] {error.message}")
    return errors


def discover_targets(explicit: list[str]) -> list[Path]:
    if explicit:
        return [Path(p) for p in explicit]
    targets: list[Path] = []
    examples_dir = REPO_ROOT / "config" / "examples"
    if examples_dir.is_dir():
        targets.extend(sorted(examples_dir.glob("*.yml")))
        targets.extend(sorted(examples_dir.glob("*.yaml")))
    config_dir = REPO_ROOT / "config"
    if config_dir.is_dir():
        for pattern in ("*.yml", "*.yaml"):
            for path in sorted(config_dir.glob(pattern)):
                targets.append(path)
    return targets


def main(argv: list[str]) -> int:
    targets = discover_targets(argv)
    if not targets:
        print("validate-config: no configuration files found to validate", file=sys.stderr)
        return 0

    all_errors: list[str] = []
    for path in targets:
        if not path.is_file():
            all_errors.append(f"{path}: not found")
            continue
        all_errors.extend(validate_file(path))

    if all_errors:
        for err in all_errors:
            print(f"[FAIL] {err}", file=sys.stderr)
        print(f"validate-config: {len(all_errors)} error(s) in {len(targets)} file(s)", file=sys.stderr)
        return 1

    print(f"validate-config: {len(targets)} file(s) valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
