#!/usr/bin/env python3
"""Convert one or more ASCII-armored OpenPGP public-key blocks to packets."""

from __future__ import annotations

import argparse
import base64
import pathlib
import re


BLOCK = re.compile(
    r"-----BEGIN PGP PUBLIC KEY BLOCK-----\s*"
    r"(?:[^\n:]+:[^\n]*\n)*\s*"
    r"([A-Za-z0-9+/=\r\n]+?)"
    r"(?:\n=[A-Za-z0-9+/]+)?\s*"
    r"-----END PGP PUBLIC KEY BLOCK-----"
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("destination", type=pathlib.Path)
    args = parser.parse_args()

    armored = args.source.read_text(encoding="ascii")
    packets = bytearray()
    for match in BLOCK.finditer(armored):
        packets.extend(base64.b64decode("".join(match.group(1).split()), validate=True))
    if not packets:
        raise SystemExit(f"no PGP public-key block in {args.source}")
    args.destination.write_bytes(packets)


if __name__ == "__main__":
    main()

