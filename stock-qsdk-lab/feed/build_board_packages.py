#!/usr/bin/env python3
"""Package release-specific upgrade checks and vendor WLAN bytes as IPKs."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import stat
import tarfile
from pathlib import Path


ARCH = "aarch64_cortex-a73_neon-vfpv4"


def archive_member(name: str, mode: int, size: int = 0) -> tarfile.TarInfo:
    item = tarfile.TarInfo("./" + name)
    item.uid = item.gid = item.mtime = 0
    item.uname = item.gname = "root"
    item.mode = mode
    item.size = size
    return item


def gzip_tar(entries: list[tuple[str, bytes | None, int, str | None]]) -> bytes:
    tar_stream = io.BytesIO()
    with tarfile.open(fileobj=tar_stream, mode="w", format=tarfile.GNU_FORMAT) as archive:
        for name, payload, mode, link in entries:
            item = archive_member(name, mode, len(payload) if payload is not None else 0)
            if link is not None:
                item.type = tarfile.SYMTYPE
                item.linkname = link
                archive.addfile(item)
            elif payload is None:
                item.type = tarfile.DIRTYPE
                archive.addfile(item)
            else:
                archive.addfile(item, io.BytesIO(payload))
    compressed = io.BytesIO()
    with gzip.GzipFile(fileobj=compressed, mode="wb", filename="", mtime=0, compresslevel=9) as target:
        target.write(tar_stream.getvalue())
    return compressed.getvalue()


def tree_paths(root: Path, prefix: str) -> list[str]:
    base = root / prefix
    if not base.is_dir() or base.is_symlink():
        raise ValueError(f"missing package data directory: {prefix}")
    return [prefix] + [path.relative_to(root).as_posix() for path in sorted(base.rglob("*"))]


def data_entries(root: Path, paths: list[str]) -> list[tuple[str, bytes | None, int, str | None]]:
    result = []
    for relative in sorted(set(paths)):
        item = root / relative
        mode = stat.S_IMODE(item.lstat().st_mode)
        if item.is_symlink():
            result.append((relative, None, mode, os.readlink(item)))
        elif item.is_dir():
            result.append((relative, None, mode, None))
        elif item.is_file():
            result.append((relative, item.read_bytes(), mode, None))
        else:
            raise ValueError(f"unsupported package object: {relative}")
    return result


def write_ipk(output: Path, name: str, version: str, description: str,
              source_sha256: str, entries: list[tuple[str, bytes | None, int, str | None]],
              *, depends: str = "", provides: str = "", conffiles: list[str] | None = None,
              source: str = "Spectrum SBE1V1K stock release", scripts: dict[str, bytes] | None = None,
              essential: bool = False) -> None:
    control = (
        f"Package: {name}\n"
        f"Version: {version}\n"
        f"Architecture: {ARCH}\n"
        f"Source: {source}\n"
        f"Source-Revision: {source_sha256}\n"
        f"Maintainer: SBE1V1K community build\n"
        f"Section: firmware\n"
        f"Description: {description}\n"
        + (f"Depends: {depends}\n" if depends else "")
        + (f"Provides: {provides}\n" if provides else "")
        + ("Essential: yes\n" if essential else "")
    ).encode()
    control_entries = [("control", control, 0o644, None)]
    if conffiles:
        control_entries.append(("conffiles", ("\n".join(conffiles) + "\n").encode(), 0o644, None))
    for script, payload in sorted((scripts or {}).items()):
        if script not in {"postinst", "prerm", "postrm"}:
            raise ValueError(f"unsupported maintainer script: {script}")
        control_entries.append((script, payload, 0o755, None))
    controls = gzip_tar(control_entries)
    data = gzip_tar(entries)
    outer = gzip_tar([
        ("debian-binary", b"2.0\n", 0o644, None),
        ("control.tar.gz", controls, 0o644, None),
        ("data.tar.gz", data, 0o644, None),
    ])
    # IPKs in this QSDK feed use the conventional gzipped tar envelope.
    output.write_bytes(outer)


def install_record(root: Path, name: str, version: str, paths: list[str], ipk: Path) -> None:
    import tarfile
    status = root / "usr/lib/opkg/status"
    if any(row.startswith("Package: " + name + "\n") for row in status.read_text().split("\n\n")):
        raise ValueError(f"refusing duplicate installed package: {name}")
    with tarfile.open(ipk, "r:gz") as outer:
        control_archive = outer.extractfile("./control.tar.gz").read()
    with tarfile.open(fileobj=io.BytesIO(control_archive), mode="r:gz") as controls:
        control = controls.extractfile("./control").read()
        extra = {item.name.removeprefix("./"): (controls.extractfile(item).read(), item.mode)
                 for item in controls if item.isfile() and item.name.removeprefix("./") != "control"}
    info = root / "usr/lib/opkg/info"
    (info / (name + ".control")).write_bytes(control)
    (info / (name + ".list")).write_text(
        "".join("/" + path + "\n" for path in sorted(set(paths)))
    )
    for suffix, (payload, mode) in extra.items():
        target = info / (name + "." + suffix)
        target.write_bytes(payload)
        target.chmod(mode)
    configs = ""
    if "conffiles" in extra:
        configs = "Conffiles:\n" + "".join(
            f" {path} {hashlib.md5((root / path.lstrip('/')).read_bytes()).hexdigest()}\n"
            for path in extra["conffiles"][0].decode().splitlines())
    with status.open("a") as stream:
        stream.write(control.decode() + "Status: install ok installed\nAuto-Installed: yes\n" + configs + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--derived", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source = json.loads(args.derived.read_text())
    if source.get("format") != "sbe1v1k-derived-source-v1":
        raise ValueError("unknown vendor source manifest")
    # Increment adaptation revisions independently of unchanged vendor WLAN.
    package_revisions = {"sbe-wififw": 1, "sbe-upgrade-profile": 2}
    release_sha = source["source_sha256"]
    root = args.root
    packages = {
        "sbe-wififw": (
            ["etc/init.d/wifi_fw_mount", "lib/firmware/IPQ9574/WIFI_FW",
             "usr/share/sbe-build/vendor-wifi-source"] +
            tree_paths(root, "usr/share/sbe-wififw"),
            "Vendor IPQ9574 QCN9224 WLAN firmware paired with this QSDK kernel",
        ),
        "sbe-upgrade-profile": (
            ["lib/upgrade/platform.sh", "usr/share/sbe-build/upgrade-source.env"],
            "SBE1V1K eMMC sysupgrade checks for the selected vendor kernel",
        ),
    }
    args.output.mkdir(parents=True, exist_ok=True)
    for name, (paths, description) in packages.items():
        version = source["release"] + f"-{package_revisions[name]}"
        entries = data_entries(root, paths)
        ipk = args.output / f"{name}_{version}_{ARCH}.ipk"
        write_ipk(ipk, name, version, description, release_sha, entries)
        install_record(root, name, version, paths, ipk)
        print(f"packaged {name}: {ipk.name} {hashlib.sha256(ipk.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    main()
