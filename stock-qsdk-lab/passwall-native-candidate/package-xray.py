#!/usr/bin/env python3
"""Package the already built static Xray as a standard xray-core IPK."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import tarfile

HERE = Path(__file__).resolve().parent


def archive(entries, epoch):
    output = io.BytesIO()
    with gzip.GzipFile(fileobj=output, mode="wb", filename="", mtime=0, compresslevel=9) as zipped:
        with tarfile.open(fileobj=zipped, mode="w", format=tarfile.GNU_FORMAT) as tar:
            for name, data, mode in entries:
                info = tarfile.TarInfo(name)
                info.size, info.mode, info.mtime = len(data), mode, epoch
                info.uid = info.gid = 0
                info.uname = info.gname = "root"
                tar.addfile(info, io.BytesIO(data))
    return output.getvalue()


def build():
    lock = json.loads((HERE / "sources.lock.json").read_text())
    data = (HERE / lock["xray_binary"]).read_bytes()
    if data[:4] != b"\x7fELF" or data[4:6] != b"\x02\x01" or int.from_bytes(data[18:20], "little") != 183:
        raise ValueError("Xray input is not AArch64 ELF64")
    offset = int.from_bytes(data[32:40], "little")
    size = int.from_bytes(data[54:56], "little")
    count = int.from_bytes(data[56:58], "little")
    if any(int.from_bytes(data[offset + i * size:offset + i * size + 4], "little") == 3 for i in range(count)):
        raise ValueError("Xray binary unexpectedly requires a dynamic ELF interpreter")
    epoch = lock["source_date_epoch"]
    control = ("Package: xray-core\nVersion: 26.3.27-1\n"
               "Architecture: aarch64_cortex-a73_neon-vfpv4\n"
               "Section: net\nPriority: optional\n"
               f"Installed-Size: {len(data)}\n"
               "Source: https://github.com/XTLS/Xray-core/tree/d2758a023cd7f4174a5a5fa4ff66e487d4342ba0\n"
               "Description: Xray proxy core\n").encode()
    return archive([
        ("./debian-binary", b"2.0\n", 0o644),
        ("./control.tar.gz", archive([("./control", control, 0o644)], epoch), 0o644),
        ("./data.tar.gz", archive([("./usr/bin/xray", data, 0o755)], epoch), 0o644)
    ], epoch)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=HERE / "candidate-out")
    args = parser.parse_args()
    data = build()
    if data != build():
        raise ValueError("Xray package is not reproducible")
    args.output.mkdir(parents=True, exist_ok=True)
    path = args.output / "xray-core_26.3.27-1_aarch64_cortex-a73_neon-vfpv4.ipk"
    if path.exists() and path.read_bytes() != data:
        raise ValueError("output exists with different contents")
    path.write_bytes(data)
    path.chmod(0o644)
    print(f"{hashlib.sha256(data).hexdigest()}  {path}")
