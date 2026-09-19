#!/usr/bin/env python3
"""Verify a narrowly scoped additive module configuration delta."""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path


EXPECTED = {
    "CONFIG_NF_SOCKET_IPV4": ("n", "m"),
    "CONFIG_NF_SOCKET_IPV6": ("n", "m"),
    "CONFIG_NF_TPROXY_IPV4": ("n", "m"),
    "CONFIG_NF_TPROXY_IPV6": ("n", "m"),
    "CONFIG_NETFILTER_XT_MATCH_SOCKET": ("n", "m"),
    "CONFIG_NETFILTER_XT_TARGET_TPROXY": ("n", "m"),
    "CONFIG_NETFILTER_XT_MATCH_IPRANGE": ("n", "m"),
}

SET_RE = re.compile(r"^(CONFIG_[A-Za-z0-9_]+)=(.*)$")
UNSET_RE = re.compile(r"^# (CONFIG_[A-Za-z0-9_]+) is not set$")


def parse_config(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = SET_RE.match(line)
        if match:
            result[match.group(1)] = match.group(2)
            continue
        match = UNSET_RE.match(line)
        if match:
            result[match.group(1)] = "n"
            continue
        if line.startswith("CONFIG_"):
            raise ValueError(f"{path}:{number}: unparsed CONFIG line: {line}")
    return result


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("stock_config", type=Path)
    parser.add_argument("candidate_config", type=Path)
    parser.add_argument("--stock-sha256", required=True)
    parser.add_argument("--fragment", type=Path,
                        help="Optional additive module fragment; never changes an existing built-in")
    args = parser.parse_args()

    actual_hash = sha256(args.stock_config)
    if actual_hash != args.stock_sha256:
        print(
            f"ERROR: stock config SHA-256 is {actual_hash}, expected {args.stock_sha256}",
            file=sys.stderr,
        )
        return 1

    stock = parse_config(args.stock_config)
    candidate = parse_config(args.candidate_config)
    expected = EXPECTED
    absent = "<missing>"
    if args.fragment:
        fragment = parse_config(args.fragment)
        if not fragment or any(value != "m" for value in fragment.values()):
            raise ValueError("fragment must contain only module selections")
        if any(stock.get(key, "n") not in ("n", "m") for key in fragment):
            raise ValueError("additive module build must not replace a built-in")
        for key in fragment:
            if candidate.get(key) != "m":
                raise ValueError(f"requested module was not selected: {key}")
        # Kconfig adds disabled subordinate options when a parent is enabled.
        # Missing and explicit n are semantically identical, but y/m changes
        # outside the reviewed fragment are never permitted.
        absent = "n"
        expected = {key: ("n", "m") for key in fragment if stock.get(key, "n") == "n"}
    changes = {
        key: (stock.get(key, absent), candidate.get(key, absent))
        for key in sorted(set(stock) | set(candidate))
        if stock.get(key, absent) != candidate.get(key, absent)
    }

    failed = False
    for key, transition in expected.items():
        actual = changes.get(key)
        if actual != transition:
            print(f"ERROR: {key}: expected {transition}, got {actual}", file=sys.stderr)
            failed = True

    unexpected = {key: value for key, value in changes.items() if key not in expected}
    for key, value in unexpected.items():
        print(f"ERROR: unrelated Kconfig delta {key}: {value[0]} -> {value[1]}", file=sys.stderr)
        failed = True

    if failed:
        return 1

    print(f"PASS: exactly {len(expected)} reviewed additive module configuration changes.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
