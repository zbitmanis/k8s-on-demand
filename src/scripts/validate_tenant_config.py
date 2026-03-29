#!/usr/bin/env python3
"""
validate_tenant_config.py — Validate a tenant config.yaml against the platform schema.

Exit 0 on success, exit 1 with descriptive error on failure.

Usage:
    python validate_tenant_config.py --tenant-id <id> [--config-root <path>]
    python validate_tenant_config.py --file <path>
"""

import argparse
import re
import sys
from pathlib import Path

import yaml


VALID_TIERS = {"standard", "premium", "enterprise"}
VALID_STATES = {"active", "suspended", "deprovisioning"}

# Kubernetes resource quantity pattern (e.g. "4", "500m", "8Gi", "16Gi")
_QUANTITY_RE = re.compile(r"^\d+(\.\d+)?(m|Ki|Mi|Gi|Ti|Pi|E|P|T|G|M|K)?$")
_EMAIL_RE = re.compile(r"^[^@]+@[^@]+\.[^@]+$")
_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$")


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def require(path: str, obj: dict, *keys: str) -> None:
    """Assert that all keys are present and non-empty in obj."""
    for key in keys:
        if key not in obj or obj[key] is None or obj[key] == "":
            fail(f"Missing required field: {path}.{key}")


def validate_quantity(path: str, value: str) -> None:
    if not _QUANTITY_RE.match(str(value)):
        fail(f"Invalid resource quantity at {path}: '{value}'")


def validate(config: dict) -> None:
    # Top-level sections
    for section in ("tenant", "namespace", "quotas"):
        if section not in config:
            fail(f"Missing required top-level section: '{section}'")

    # tenant section
    t = config["tenant"]
    require("tenant", t, "id", "name", "tier", "region", "owner_email")

    tenant_id = t["id"]
    if not _ID_RE.match(tenant_id):
        fail(
            f"tenant.id '{tenant_id}' is invalid — must be lowercase alphanumeric with hyphens, "
            "2-63 chars, no leading/trailing hyphen"
        )

    if t["tier"] not in VALID_TIERS:
        fail(f"tenant.tier '{t['tier']}' is not valid — must be one of: {', '.join(sorted(VALID_TIERS))}")

    if not _EMAIL_RE.match(t["owner_email"]):
        fail(f"tenant.owner_email '{t['owner_email']}' is not a valid email address")

    # namespace section
    ns = config["namespace"]
    require("namespace", ns, "name")
    if not _ID_RE.match(ns["name"]):
        fail(f"namespace.name '{ns['name']}' is not a valid Kubernetes namespace name")

    # quotas section — all keys must be valid resource quantities
    quotas = config["quotas"]
    required_quotas = [
        "requests.cpu",
        "requests.memory",
        "limits.cpu",
        "limits.memory",
        "pods",
        "services",
        "persistentvolumeclaims",
    ]
    for key in required_quotas:
        if key not in quotas:
            fail(f"Missing required quota: quotas.{key}")
        validate_quantity(f"quotas.{key}", quotas[key])

    # state (optional, defaults to active)
    state = config.get("state", "active")
    if state not in VALID_STATES:
        fail(f"state '{state}' is not valid — must be one of: {', '.join(sorted(VALID_STATES))}")

    print(f"OK: tenant config for '{tenant_id}' is valid")


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate tenant config.yaml")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--tenant-id", help="Tenant ID — loads tenants/<id>/config.yaml")
    group.add_argument("--file", help="Explicit path to a config.yaml file")
    parser.add_argument(
        "--config-root",
        default="tenants",
        help="Root directory for tenant configs (default: tenants/)",
    )
    args = parser.parse_args()

    if args.file:
        config_path = Path(args.file)
    else:
        config_path = Path(args.config_root) / args.tenant_id / "config.yaml"

    if not config_path.exists():
        fail(f"Config file not found: {config_path}")

    try:
        with config_path.open() as f:
            config = yaml.safe_load(f)
    except yaml.YAMLError as e:
        fail(f"Failed to parse YAML: {e}")

    if not isinstance(config, dict):
        fail("Config file is empty or not a YAML mapping")

    validate(config)


if __name__ == "__main__":
    main()
