#!/usr/bin/env python3
"""Merge an explicit BusyBox fragment into an allnoconfig-generated file."""

from __future__ import annotations

import re
import sys
from pathlib import Path


SET_RE = re.compile(r"^CONFIG_([A-Za-z0-9_]+)=(.*)$")
UNSET_RE = re.compile(r"^# CONFIG_([A-Za-z0-9_]+) is not set$")


def parse(lines: list[str], *, fragment: bool) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in lines:
        line = raw.rstrip("\n")
        match = SET_RE.match(line) or UNSET_RE.match(line)
        if not match:
            continue
        symbol = match.group(1)
        if symbol in values:
            raise SystemExit(f"duplicate CONFIG_{symbol} in {'fragment' if fragment else 'base'}")
        if SET_RE.match(line):
            values[symbol] = line
        else:
            values[symbol] = f"# CONFIG_{symbol} is not set"
    return values


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} BASE_CONFIG FRAGMENT")
    base_path = Path(sys.argv[1])
    fragment_path = Path(sys.argv[2])
    base_lines = base_path.read_text(encoding="utf-8").splitlines()
    base = parse([line + "\n" for line in base_lines], fragment=False)
    fragment = parse(fragment_path.read_text(encoding="utf-8").splitlines(True), fragment=True)
    missing = sorted(set(fragment) - set(base))
    if missing:
        raise SystemExit("fragment contains unknown symbols: " + ", ".join(f"CONFIG_{s}" for s in missing))

    output: list[str] = []
    replaced: set[str] = set()
    for line in base_lines:
        match = SET_RE.match(line) or UNSET_RE.match(line)
        if match and match.group(1) in fragment:
            symbol = match.group(1)
            output.append(fragment[symbol])
            replaced.add(symbol)
        else:
            output.append(line)
    if replaced != set(fragment):
        raise SystemExit("internal merge error: not all fragment symbols were replaced")
    base_path.write_text("\n".join(output) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()

