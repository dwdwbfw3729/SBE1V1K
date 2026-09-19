#!/usr/bin/env python3
"""Package standard-path userland dependencies without startup scripts."""
from __future__ import annotations
import gzip
import hashlib
import io
import sys
import tarfile
from pathlib import Path

EPOCH = 1789420800
ARCH = "aarch64_cortex-a73_neon-vfpv4"
PACKAGES = {
    "microsocks": ("1.0.5-2-qsdk1", "libc, libgcc1, libpthread", "https://github.com/rofl0r/microsocks", "MIT"),
    "dns2socks": ("2.1-2-qsdk1", "libc, libgcc1, libpthread", "https://sourceforge.net/projects/dns2socks/", "BSD-3-Clause"),
    "tcping": ("0.3-1-qsdk1", "libc, libgcc1", "https://github.com/Lienol/tcping", "GPL-2.0-only"),
    "ipt2socks": ("1.1.4-3-qsdk1", "libc, libgcc1, libpthread", "https://github.com/zfl9/ipt2socks", "AGPL-3.0"),
    "chinadns-ng": ("2025.08.09-1", "", "https://github.com/zfl9/chinadns-ng", "AGPL-3.0-only"),
    "libyaml": ("0.2.5-2-qsdk1", "libc, libgcc1", "https://github.com/yaml/libyaml", "MIT"),
    "lyaml": ("6.2.8-1-qsdk1", "libc, libgcc1, lua, libyaml", "https://github.com/gvvaughan/lyaml", "MIT"),
}

def archive(entries):
    result = io.BytesIO()
    with gzip.GzipFile(fileobj=result, mode="wb", filename="", mtime=0) as zipped:
        with tarfile.open(fileobj=zipped, mode="w", format=tarfile.GNU_FORMAT) as tar:
            for name, data, mode, target in entries:
                info = tarfile.TarInfo("./" + name)
                info.mtime = EPOCH
                info.uid = info.gid = 0
                info.uname = info.gname = "root"
                info.mode = mode
                if data is None:
                    info.type = tarfile.DIRTYPE
                    tar.addfile(info)
                elif target is not None:
                    info.type = tarfile.SYMTYPE
                    info.linkname = target
                    tar.addfile(info)
                else:
                    info.size = len(data)
                    tar.addfile(info, io.BytesIO(data))
    return result.getvalue()

def main():
    out = Path(sys.argv[1])
    manifest = []
    for name, (version, dependencies, source, license_name) in PACKAGES.items():
        root = out / "payload" / name
        entries = []
        size = 0
        for path in sorted(root.rglob("*")):
            if path.is_symlink():
                target = str(path.readlink())
                assert not target.startswith("/") and ".." not in Path(target).parts
                entries.append((path.relative_to(root).as_posix(), b"", 0o777, target))
            elif path.is_file():
                data = path.read_bytes()
                size += len(data)
                mode = 0o755 if data.startswith(b"\x7fELF") else 0o644
                entries.append((path.relative_to(root).as_posix(), data, mode, None))
            elif path.is_dir():
                entries.append((path.relative_to(root).as_posix(), None, 0o755, None))
        assert entries, name
        data_archive = archive(entries)
        control = f"Package: {name}\nVersion: {version}\nArchitecture: {ARCH}\n"
        if dependencies:
            control += f"Depends: {dependencies}\n"
        section = {"libyaml": "libs", "lyaml": "lang"}.get(name, "net")
        # Match the locked QSDK ipkg-build convention: compressed data bytes,
        # not KiB. LuCI/opkg already perform their own unit conversion.
        control += f"Source: {source}\nLicense: {license_name}\nSection: {section}\nPriority: optional\nInstalled-Size: {len(data_archive)}\nDescription: {name} userland component for QSDK\n"
        package = archive([
            ("debian-binary", b"2.0\n", 0o644, None),
            ("control.tar.gz", archive([("control", control.encode(), 0o644, None)]), 0o644, None),
            ("data.tar.gz", data_archive, 0o644, None),
        ])
        target = out / f"{name}_{version}_{ARCH}.ipk"
        target.write_bytes(package)
        manifest.append(f"{hashlib.sha256(package).hexdigest()}  {target.name}\n")
    (out / "PACKAGE_SHA256SUMS").write_text("".join(manifest))
    print("".join(manifest), end="")

if __name__ == "__main__":
    main()
