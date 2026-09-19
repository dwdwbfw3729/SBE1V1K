#!/usr/bin/env python3
"""Package the locked official static shadowsocks-rust sslocal binary."""

import argparse
import hashlib
import io
import json
import lzma
from pathlib import Path
import tarfile

from importlib.machinery import SourceFileLoader


HERE = Path(__file__).resolve().parent
archive_module = SourceFileLoader(
    "native_ipk_archive", str(HERE / "package-xray.py")
).load_module()


def checked_binary() -> bytes:
    lock = json.loads((HERE / "sources.lock.json").read_text())
    source = HERE / lock["shadowsocks_rust_archive"]
    packed = source.read_bytes()
    if hashlib.sha256(packed).hexdigest() != lock["shadowsocks_rust_archive_sha256"]:
        raise ValueError("shadowsocks-rust archive does not match the source lock")
    with tarfile.open(fileobj=io.BytesIO(lzma.decompress(packed)), mode="r:") as archive:
        member = archive.getmember("sslocal")
        if not member.isfile() or member.name != "sslocal":
            raise ValueError("official archive does not contain a regular sslocal binary")
        stream = archive.extractfile(member)
        if stream is None:
            raise ValueError("could not read sslocal from the official archive")
        binary = stream.read()
    if (
        binary[:6] != b"\x7fELF\x02\x01"
        or int.from_bytes(binary[18:20], "little") != 183
    ):
        raise ValueError("sslocal is not AArch64 ELF64")
    phoff = int.from_bytes(binary[32:40], "little")
    phentsize = int.from_bytes(binary[54:56], "little")
    phnum = int.from_bytes(binary[56:58], "little")
    if any(
        int.from_bytes(binary[phoff + i * phentsize : phoff + i * phentsize + 4], "little")
        == 3
        for i in range(phnum)
    ):
        raise ValueError("sslocal unexpectedly requires a dynamic ELF interpreter")
    return binary


def build() -> bytes:
    lock = json.loads((HERE / "sources.lock.json").read_text())
    binary = checked_binary()
    version = lock["shadowsocks_rust_version"]
    control = (
        "Package: shadowsocks-rust-sslocal\n"
        f"Version: {version}\n"
        "Architecture: aarch64_cortex-a73_neon-vfpv4\n"
        "Section: net\n"
        "Priority: optional\n"
        f"Installed-Size: {len(binary)}\n"
        "Source: https://github.com/shadowsocks/shadowsocks-rust/tree/v1.21.2\n"
        "Description: shadowsocks-rust client with redirection support for PassWall\n"
    ).encode()
    epoch = lock["source_date_epoch"]
    return archive_module.archive(
        [
            ("./debian-binary", b"2.0\n", 0o644),
            (
                "./control.tar.gz",
                archive_module.archive([("./control", control, 0o644)], epoch),
                0o644,
            ),
            (
                "./data.tar.gz",
                archive_module.archive([("./usr/bin/sslocal", binary, 0o755)], epoch),
                0o644,
            ),
        ],
        epoch,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=HERE / "candidate-out")
    args = parser.parse_args()
    data = build()
    if data != build():
        raise ValueError("shadowsocks-rust package is not reproducible")
    args.output.mkdir(parents=True, exist_ok=True)
    path = args.output / (
        "shadowsocks-rust-sslocal_1.21.2-1_"
        "aarch64_cortex-a73_neon-vfpv4.ipk"
    )
    if path.exists() and path.read_bytes() != data:
        raise ValueError("output exists with different contents")
    path.write_bytes(data)
    path.chmod(0o644)
    print(f"{hashlib.sha256(data).hexdigest()}  {path}")
