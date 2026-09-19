#!/usr/bin/env python3
"""Assert the issuer fingerprint embedded in an ASCII-armored signature."""

from __future__ import annotations

import base64
import pathlib
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} SIGNATURE.asc FINGERPRINT", file=sys.stderr)
        return 2
    path = pathlib.Path(sys.argv[1])
    fingerprint = sys.argv[2].replace(" ", "").upper()
    if len(fingerprint) != 40:
        print("ERROR: expected a 40-hex-digit OpenPGP fingerprint", file=sys.stderr)
        return 1
    try:
        needle = bytes.fromhex(fingerprint)
    except ValueError:
        print("ERROR: fingerprint is not hexadecimal", file=sys.stderr)
        return 1

    lines = path.read_text(encoding="ascii").splitlines()
    try:
        begin = lines.index("-----BEGIN PGP SIGNATURE-----")
        end = lines.index("-----END PGP SIGNATURE-----", begin + 1)
    except ValueError:
        print(f"ERROR: {path} is not an armored OpenPGP signature", file=sys.stderr)
        return 1

    body: list[str] = []
    in_body = False
    for line in lines[begin + 1 : end]:
        if not in_body:
            if not line:
                in_body = True
            continue
        if line.startswith("="):
            break
        if line:
            body.append(line)
    try:
        packet = base64.b64decode("".join(body), validate=True)
    except (ValueError, base64.binascii.Error):
        print(f"ERROR: {path} has invalid armored signature data", file=sys.stderr)
        return 1
    if needle not in packet:
        print(f"ERROR: {path} does not name issuer {fingerprint}", file=sys.stderr)
        return 1
    print(f"verified OpenPGP issuer={fingerprint} file={path.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
