#!/usr/bin/env python3
"""Build the SBE1V1K eMMC factory image: a 64 KiB padded SquashFS."""

import argparse
import hashlib
import struct
from pathlib import Path


def manifest_values(path: Path) -> dict[str, str]:
    values = {}
    for line in path.read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            key, value = line.split("=", 1)
            if key in values:
                raise ValueError(f"duplicate manifest field: {key}")
            values[key] = value
    return values


def make_factory(rootfs: Path, manifest: Path, output: Path) -> None:
    raw = rootfs.read_bytes()
    info = manifest_values(manifest)
    if raw[:4] != b"hsqs" or len(raw) < 96:
        raise ValueError("expected SquashFS source")
    used = struct.unpack_from("<Q", raw, 40)[0]
    if not 96 <= used <= len(raw):
        raise ValueError("invalid SquashFS superblock")
    if info.get("squashfs_sha256") != hashlib.sha256(raw).hexdigest() or \
            info.get("squashfs_size") != str(len(raw)):
        raise ValueError("rootfs does not match its build manifest")
    if info.get("feed_policy") not in ("external", "embedded"):
        raise ValueError("factory source must use a supported feed policy")
    padded = raw + bytes(-len(raw) % 65536)
    if len(padded) > 127926272:
        raise ValueError("factory image exceeds rootfs partition")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(padded)
    if output.stat().st_size % 65536:
        raise ValueError("factory image is not 64 KiB aligned")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rootfs", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    make_factory(args.rootfs, args.manifest, args.output)


if __name__ == "__main__":
    main()
