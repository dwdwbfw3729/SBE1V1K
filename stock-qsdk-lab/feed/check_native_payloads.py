#!/usr/bin/env python3
"""Reject feed reinstall packages that would undo final image-only changes."""
import argparse
import io
import tarfile
from pathlib import Path

from stage_native_feed import read_manifest, resolve_under


def check(lab: Path, root: Path, after_install: bool = False) -> int:
    checked = 0
    for row in read_manifest(lab / "feed/native-feed-inputs.tsv"):
        if not row.source.startswith(("luci-maintenance/", "ddns-native-candidate/",
                                      "luci-proto-vxlan-candidate/", "odhcp6c-build/")):
            continue
        with tarfile.open(resolve_under(lab, row.source)) as ipk:
            with tarfile.open(fileobj=io.BytesIO(ipk.extractfile("./control.tar.gz").read())) as control:
                configs = set()
                if "./conffiles" in control.getnames():
                    configs = set(control.extractfile("./conffiles").read().decode().splitlines())
            with tarfile.open(fileobj=io.BytesIO(ipk.extractfile("./data.tar.gz").read())) as data:
                for member in data:
                    path = "/" + member.name.removeprefix("./").lstrip("/")
                    if member.isdir() or path in configs:
                        continue
                    target = root / path.lstrip("/")
                    # OpenWrt consumes successful uci-defaults during native
                    # package postinst. Absence afterwards is expected, not
                    # evidence of a missing shipped payload.
                    if after_install and path.startswith("/etc/uci-defaults/") and not target.exists() and not target.is_symlink():
                        continue
                    if member.issym():
                        assert target.is_symlink() and target.readlink().as_posix() == member.linkname, (row.package, path)
                    elif member.isfile():
                        assert not target.is_symlink() and target.is_file(), (row.package, path)
                        assert target.read_bytes() == data.extractfile(member).read(), (row.package, path)
                        assert target.stat().st_mode & 0o7777 == member.mode, (row.package, path, "mode")
                    else:
                        raise AssertionError((row.package, path, "unexpected object"))
        checked += 1
    assert checked == 21, checked
    return checked


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lab", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--after-install", action="store_true")
    args = parser.parse_args()
    print(f"PASS: {check(args.lab, args.root, args.after_install)} native feed payloads match the final rootfs")
