#!/usr/bin/env python3
"""Package the three verified PassWall iptables user-space extensions.

The historical version of this script also repacked luci-app-passwall and
created a private dependency bundle. Native QSDK IPKs are now staged without
modification by stage_native_feed.py; this file intentionally owns only the
three reviewed xtables shared objects.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import os
import tarfile
import tempfile
from pathlib import Path


SOURCE_DATE_EPOCH = 1774633540
ARCHITECTURE = "aarch64_cortex-a73_neon-vfpv4"
XTABLES_PACKAGE = "sbe-passwall-iptables-extensions"
XTABLES_VERSION = "1.8.3-1-sbe1"
EXPECTED = {
    "libxt_socket.so": "97452761c87dfd458c9d139029283ff2579faacd9d055e2e6ac8b2da7878a7c3",
    "libxt_TPROXY.so": "105c3a4926f16e804cc18015f3db7591edfc5ceea1d3194fba0c0c9a7de1c6e2",
    "libxt_iprange.so": "97b7535f0e309de5476d99c4859255647d786967b24370797685d496a487ff26",
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def gzip_tar(entries: list[tuple[str, bytes, int]]) -> bytes:
    output = io.BytesIO()
    with gzip.GzipFile(fileobj=output, mode="wb", filename="", mtime=0, compresslevel=9) as zipped:
        with tarfile.open(fileobj=zipped, mode="w", format=tarfile.GNU_FORMAT) as archive:
            for name, contents, mode in entries:
                item = tarfile.TarInfo(name)
                item.size = len(contents)
                item.mode = mode
                item.mtime = SOURCE_DATE_EPOCH
                item.uid = item.gid = 0
                item.uname = item.gname = "root"
                archive.addfile(item, io.BytesIO(contents))
    return output.getvalue()


def make_ipk(control: str, data_tar: bytes) -> bytes:
    return gzip_tar(
        [
            ("./debian-binary", b"2.0\n", 0o644),
            ("./control.tar.gz", gzip_tar([("./control", control.encode(), 0o644)]), 0o644),
            ("./data.tar.gz", data_tar, 0o644),
        ]
    )


def write_package(output: Path, data: bytes) -> Path:
    output.mkdir(parents=True, exist_ok=True)
    target = output / f"{XTABLES_PACKAGE}_{XTABLES_VERSION}_{ARCHITECTURE}.ipk"
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{XTABLES_PACKAGE}.", dir=output)
    try:
        with os.fdopen(descriptor, "wb") as temporary:
            temporary.write(data)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_name, target)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)
    target.chmod(0o644)
    return target


def build_xtables(directory: Path) -> bytes:
    payload: list[tuple[str, bytes, int]] = []
    for name, expected in EXPECTED.items():
        candidate = directory / name
        if not candidate.is_file():
            raise SystemExit(f"missing xtables candidate: {candidate}")
        data = candidate.read_bytes()
        if sha256(data) != expected:
            raise SystemExit(f"{name}: candidate SHA256 does not match")
        payload.append((f"./usr/lib/iptables/{name}", data, 0o755))
    data_tar = gzip_tar(payload)
    control = (
        f"Package: {XTABLES_PACKAGE}\n"
        f"Version: {XTABLES_VERSION}\n"
        f"Architecture: {ARCHITECTURE}\n"
        "Depends: iptables\n"
        "Section: net\n"
        "Priority: optional\n"
        f"Installed-Size: {len(data_tar)}\n"
        "Description: iptables legacy socket, TPROXY and iprange extensions for PassWall.\n"
    )
    return make_ipk(control, data_tar)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--xtables", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    package = write_package(args.output, build_xtables(args.xtables))
    print(f"{sha256(package.read_bytes())}  {package}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
