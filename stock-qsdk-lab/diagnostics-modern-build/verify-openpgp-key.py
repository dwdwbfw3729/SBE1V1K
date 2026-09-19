#!/usr/bin/env python3
"""Validate and dearmor one pinned OpenPGP v4 public-key block."""

from __future__ import annotations

import base64
import binascii
import hashlib
import pathlib
import sys


class OpenPGPKeyError(ValueError):
    pass


def crc24(data: bytes) -> int:
    value = 0xB704CE
    for byte in data:
        value ^= byte << 16
        for _ in range(8):
            value <<= 1
            if value & 0x1000000:
                value ^= 0x1864CFB
    return value & 0xFFFFFF


def dearmor(path: pathlib.Path) -> bytes:
    lines = path.read_text(encoding="ascii").splitlines()
    try:
        begin = lines.index("-----BEGIN PGP PUBLIC KEY BLOCK-----")
        end = lines.index("-----END PGP PUBLIC KEY BLOCK-----", begin + 1)
    except ValueError as error:
        raise OpenPGPKeyError(
            "not a single ASCII-armored public-key block"
        ) from error
    if any(line.strip() for line in lines[:begin] + lines[end + 1 :]):
        raise OpenPGPKeyError("text exists outside the public-key armor")

    body: list[str] = []
    checksum: str | None = None
    in_body = False
    for line in lines[begin + 1 : end]:
        if not in_body:
            if not line:
                in_body = True
            elif ":" not in line:
                raise OpenPGPKeyError("malformed armor header")
            continue
        if line.startswith("="):
            if checksum is not None or len(line) != 5:
                raise OpenPGPKeyError("malformed armor checksum")
            checksum = line[1:]
        elif line:
            if checksum is not None:
                raise OpenPGPKeyError("base64 data follows the armor checksum")
            body.append(line)
    if not body or checksum is None:
        raise OpenPGPKeyError("armor body or checksum is missing")
    try:
        binary = base64.b64decode("".join(body), validate=True)
        encoded_crc = base64.b64decode(checksum, validate=True)
    except (ValueError, binascii.Error) as error:
        raise OpenPGPKeyError("invalid armor base64") from error
    if len(encoded_crc) != 3 or int.from_bytes(encoded_crc, "big") != crc24(binary):
        raise OpenPGPKeyError("armor CRC-24 does not match")
    return binary


def read_new_length(data: bytes, offset: int) -> tuple[int, int]:
    if offset >= len(data):
        raise OpenPGPKeyError("truncated new-format packet length")
    first = data[offset]
    if first < 192:
        return first, offset + 1
    if first <= 223:
        if offset + 1 >= len(data):
            raise OpenPGPKeyError("truncated two-octet packet length")
        return ((first - 192) << 8) + data[offset + 1] + 192, offset + 2
    if first == 255:
        if offset + 5 > len(data):
            raise OpenPGPKeyError("truncated five-octet packet length")
        return int.from_bytes(data[offset + 1 : offset + 5], "big"), offset + 5
    raise OpenPGPKeyError(
        "partial body lengths are not accepted in the pinned key"
    )


def first_packet(data: bytes) -> tuple[int, bytes]:
    if not data or not (data[0] & 0x80):
        raise OpenPGPKeyError("invalid OpenPGP packet header")
    header = data[0]
    if header & 0x40:
        tag = header & 0x3F
        length, offset = read_new_length(data, 1)
    else:
        tag = (header >> 2) & 0x0F
        length_type = header & 0x03
        widths = {0: 1, 1: 2, 2: 4}
        if length_type not in widths:
            raise OpenPGPKeyError(
                "indeterminate old-format length is not accepted"
            )
        width = widths[length_type]
        if 1 + width > len(data):
            raise OpenPGPKeyError("truncated old-format packet length")
        length = int.from_bytes(data[1 : 1 + width], "big")
        offset = 1 + width
    if length <= 0 or offset + length > len(data):
        raise OpenPGPKeyError("truncated OpenPGP packet body")
    return tag, data[offset : offset + length]


def primary_fingerprint(data: bytes) -> str:
    tag, body = first_packet(data)
    if tag != 6:
        raise OpenPGPKeyError(f"first packet is tag {tag}, not a public key")
    if not body or body[0] != 4:
        raise OpenPGPKeyError(
            "only an explicitly pinned OpenPGP v4 key is accepted"
        )
    if len(body) > 0xFFFF:
        raise OpenPGPKeyError("v4 public-key packet is too large")
    framed = b"\x99" + len(body).to_bytes(2, "big") + body
    return hashlib.sha1(framed).hexdigest().upper()


def main() -> int:
    if len(sys.argv) != 4:
        print(f"usage: {sys.argv[0]} KEY.asc FINGERPRINT OUTPUT.gpg", file=sys.stderr)
        return 2
    source = pathlib.Path(sys.argv[1])
    expected = sys.argv[2].replace(" ", "").upper()
    output = pathlib.Path(sys.argv[3])
    if len(expected) != 40 or any(c not in "0123456789ABCDEF" for c in expected):
        print("ERROR: expected a 40-hex-digit fingerprint", file=sys.stderr)
        return 1
    try:
        binary = dearmor(source)
        actual = primary_fingerprint(binary)
        if actual != expected:
            raise OpenPGPKeyError(
                f"primary fingerprint {actual} differs from {expected}"
            )
        if output.is_symlink():
            raise OpenPGPKeyError("refusing symlink output")
        output.write_bytes(binary)
        output.chmod(0o600)
    except (OpenPGPKeyError, OSError, UnicodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"verified OpenPGP public-key fingerprint={actual} file={source.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
