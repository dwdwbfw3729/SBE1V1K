#!/usr/bin/env python3
"""Verify a locked vendor FIT and extract the three release inputs.

This never executes content from the firmware. Hashes of the extracted parts
are derived after verifying the versioned source lock, rather than being
maintained as independent constants in the build program.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import zlib
from pathlib import Path


FDT_MAGIC = 0xD00DFEED


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fdt_nodes(data: bytes) -> tuple[int, dict[str, dict[str, bytes]]]:
    if len(data) < 40:
        raise ValueError("truncated FIT/FDT header")
    (magic, total, structs, strings, reserved, version, compatible, _,
     strings_len, structs_len) = struct.unpack_from(">10I", data)
    if (magic != FDT_MAGIC or total > len(data) or total < 40 or
            version < 17 or compatible > version or reserved < 40 or
            structs < 40 or strings < 40 or
            structs + structs_len > total or strings + strings_len > total):
        raise ValueError("invalid FIT/FDT header or section bounds")
    string_table = data[strings:strings + strings_len]
    nodes: dict[str, dict[str, bytes]] = {}
    stack: list[str] = []
    cursor = structs
    end = structs + structs_len
    ended = False
    while cursor + 4 <= end:
        token = struct.unpack_from(">I", data, cursor)[0]
        cursor += 4
        if token == 1:  # FDT_BEGIN_NODE
            name_end = data.find(b"\0", cursor, end)
            if name_end < 0:
                raise ValueError("unterminated FIT node name")
            name = data[cursor:name_end].decode("ascii")
            if not stack and name != "":
                raise ValueError("FIT root node must be unnamed")
            stack.append(name)
            path = "/" + "/".join(n for n in stack if n)
            if path in nodes:
                raise ValueError(f"duplicate FIT node {path}")
            nodes[path] = {}
            cursor = (name_end + 4) & ~3
        elif token == 2:  # FDT_END_NODE
            if not stack:
                raise ValueError("unbalanced FIT node")
            stack.pop()
        elif token == 3:  # FDT_PROP
            if not stack or cursor + 8 > end:
                raise ValueError("invalid FIT property header")
            size, name_offset = struct.unpack_from(">II", data, cursor)
            cursor += 8
            if name_offset >= len(string_table) or cursor + size > end:
                raise ValueError("FIT property outside section bounds")
            name_end = string_table.find(b"\0", name_offset)
            if name_end < 0:
                raise ValueError("unterminated FIT property name")
            name = string_table[name_offset:name_end].decode("ascii")
            path = "/" + "/".join(n for n in stack if n)
            if name in nodes[path]:
                raise ValueError(f"duplicate FIT property {path}/{name}")
            nodes[path][name] = data[cursor:cursor + size]
            cursor = (cursor + size + 3) & ~3
        elif token == 4:  # FDT_NOP
            continue
        elif token == 9:  # FDT_END
            if stack:
                raise ValueError("unterminated FIT nodes")
            ended = True
            break
        else:
            raise ValueError(f"unknown FIT token {token}")
    if not ended:
        raise ValueError("missing FIT end token")
    return total, nodes


def fit_text(data: bytes) -> str:
    return data.rstrip(b"\0").decode("ascii")


def verify_bundle(blob: bytes, lock: dict) -> dict[str, bytes]:
    if len(blob) != lock["size"] or digest(blob) != lock["sha256"]:
        raise ValueError("vendor bundle does not match versioned size/SHA-256 lock")
    total, nodes = fdt_nodes(blob)
    if total != len(blob):
        raise ValueError("unexpected data following vendor FIT")
    if fit_text(nodes["/"]["description"]) != lock["fit_description"]:
        raise ValueError("unexpected vendor FIT description")
    component_names = lock["components"]
    images = {p.split("/")[-1]: props["data"] for p, props in nodes.items()
              if p.startswith("/images/") and p.count("/") == 2 and "data" in props}
    if set(images) != set(component_names):
        raise ValueError("vendor FIT component set differs from source lock")
    for name, payload in images.items():
        path = f"/images/{name}"
        checks = [(p, props) for p, props in nodes.items()
                  if p.startswith(path + "/hash") and p.count("/") == 3]
        if not checks:
            raise ValueError(f"missing embedded checksum for {name}")
        for _, props in checks:
            algo = fit_text(props["algo"])
            if algo == "crc32":
                actual = struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF)
            elif algo == "sha256":
                actual = hashlib.sha256(payload).digest()
            else:
                raise ValueError(f"unsupported FIT hash algorithm {algo}")
            if actual != props["value"]:
                raise ValueError(f"embedded checksum failed for {name}")
    return images


def embedded_fit(hlos: bytes) -> tuple[int, bytes]:
    offsets = [m.start() for m in re.finditer(re.escape(struct.pack(">I", FDT_MAGIC)), hlos)]
    valid = []
    for offset in offsets:
        try:
            total, nodes = fdt_nodes(hlos[offset:])
            if "/images" in nodes and "/configurations" in nodes:
                valid.append((offset, hlos[offset:offset + total]))
        except (ValueError, KeyError, UnicodeDecodeError, struct.error):
            pass
    if len(valid) != 1:
        raise ValueError("expected one embedded kernel FIT in vendor HLOS")
    return valid[0]


def kernel_lzma(data: bytes) -> bytes:
    """Read the kernel payload from an already authenticated vendor FIT.

    Vendor FITs use legacy @ node names rejected by newer dumpimage versions.
    Reuse the bounded parser; never rewrite the FIT used for booting.
    """
    total, nodes = fdt_nodes(data)
    kernels = [(path, props) for path, props in nodes.items()
               if path.startswith("/images/") and path.count("/") == 2
               and props.get("type") == b"kernel\0"]
    if total != len(data) or len(kernels) != 1:
        raise ValueError("expected exactly one embedded kernel")
    path, props = kernels[0]
    if (props.get("arch") != b"arm64\0" or props.get("os") != b"linux\0"
            or props.get("compression") != b"lzma\0" or not props.get("data")):
        raise ValueError("unexpected stock kernel type/compression")
    return props["data"]


def squashfs_used(data: bytes) -> int:
    if len(data) < 96 or data[:4] != b"hsqs":
        raise ValueError("expected SquashFS 4.0")
    major, minor = struct.unpack_from("<HH", data, 28)
    used = struct.unpack_from("<Q", data, 40)[0]
    if (major, minor) != (4, 0) or not 96 <= used <= len(data):
        raise ValueError("invalid SquashFS superblock")
    return used


def padded(source: bytes, size: int) -> bytes:
    if len(source) > size:
        raise ValueError("source component exceeds target partition")
    return source + bytes(size - len(source))


def prepare(lock_path: Path, source: Path, outdir: Path) -> dict:
    lock = json.loads(lock_path.read_text())
    if lock.get("format") != "sbe1v1k-stock-source-v1":
        raise ValueError("unsupported source lock format")
    images = verify_bundle(source.read_bytes(), lock)
    hlos = images["hlos-askey"]
    root = images["rootfs-askey"]
    wifi = images["wifi_fw_ipq9574_qcn9000_qcn9224_v2"]
    offset, kernel_fit = embedded_fit(hlos)
    squashfs_used(root)
    squashfs_used(wifi)
    p25_size = lock["partition_bytes"]["0:HLOS"]
    p27_size = lock["partition_bytes"]["rootfs"]
    wifi_size = lock["partition_bytes"]["WIFIFW"]
    files = {
        "vendor-hlos-p25.img": padded(hlos, p25_size),
        "stock-rootfs-p27.img": padded(root, p27_size),
        "stock-p25.fit": kernel_fit,
        "stock-wifi.squashfs": wifi,
    }
    outdir.mkdir(parents=True, exist_ok=True)
    for name, content in files.items():
        (outdir / name).write_bytes(content)
    derived = {
        "format": "sbe1v1k-derived-source-v1",
        "release": lock["release"],
        "source_filename": lock["filename"],
        "source_sha256": lock["sha256"],
        "source_lock_sha256": digest(lock_path.read_bytes()),
        "kernel_fit_offset": offset,
        "components": {name: {"size": len(content), "sha256": digest(content)}
                       for name, content in images.items()},
        "artifacts": {name: {"size": len(content), "sha256": digest(content)}
                      for name, content in files.items()},
    }
    (outdir / "derived-source.json").write_text(json.dumps(derived, indent=2, sort_keys=True) + "\n")
    baseline = (
        f"STOCK_P27_SHA256={derived['artifacts']['stock-rootfs-p27.img']['sha256']}\n"
        f"STOCK_P27_PARTITION_SIZE={p27_size}\n"
        f"STOCK_P25_SHA256={derived['artifacts']['vendor-hlos-p25.img']['sha256']}\n"
        f"STOCK_P25_PARTITION_SIZE={p25_size}\n"
        f"STOCK_P25_FIT_OFFSET={offset}\n"
        f"ROOTFS_SOURCE_DATE_EPOCH={lock['rootfs_source_date_epoch']}\n"
    )
    (outdir / "stock-baseline.env").write_text(baseline)
    return derived


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--outdir", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(prepare(args.lock, args.source, args.outdir), sort_keys=True))


if __name__ == "__main__":
    main()
