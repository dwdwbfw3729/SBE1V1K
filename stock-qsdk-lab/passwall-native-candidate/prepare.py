#!/usr/bin/env python3
"""Prepare a complete, source-locked PassWall tree without building or installing."""
from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import tarfile

from fixups import apply_fixups

HERE = Path(__file__).resolve().parent


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def source_tree() -> tuple[dict, dict[str, tuple[bytes, int]]]:
    lock = json.loads((HERE / "sources.lock.json").read_text())
    archive = HERE / lock["archive"]
    if sha256(archive.read_bytes()) != lock["archive_sha256"]:
        raise ValueError("upstream archive does not match sources.lock.json")
    tree = {}
    with tarfile.open(archive, "r:gz") as source:
        for member in source:
            if not member.name.startswith(lock["archive_prefix"]):
                continue
            name = member.name[len(lock["archive_prefix"]):]
            if not name or member.isdir():
                continue
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or not (member.isfile() or member.issym()):
                raise ValueError(f"unexpected upstream member: {name}")
            if name in tree:
                raise ValueError(f"duplicate upstream member: {name}")
            if member.issym():
                target = PurePosixPath(member.linkname)
                if target.is_absolute() or ".." in target.parts:
                    raise ValueError(f"unexpected link target: {name}")
                tree[name] = (member.linkname.encode(), 0o120777)
            else:
                tree[name] = (source.extractfile(member).read(), member.mode & 0o777)
    return lock, tree


def prepared_tree() -> tuple[dict, dict, dict, list[str]]:
    lock, original = source_tree()
    tree = original.copy()
    groups = apply_fixups(tree)
    for path in sorted((HERE / "overlay").rglob("*")):
        if path.is_file():
            name = path.relative_to(HERE / "overlay").as_posix()
            if name in tree:
                raise ValueError(f"overlay must not silently replace upstream: {name}")
            tree[name] = (path.read_bytes(), 0o755 if name.startswith("root/usr/libexec/") else 0o644)
    return lock, original, tree, groups


def write_exact(path: Path, data: bytes, mode: int = 0o644, generated: bool = False) -> None:
    # Re-running is idempotent. Never overwrite a locally edited generated tree.
    if path.is_symlink():
        raise ValueError(f"unexpected output symlink: {path}")
    if path.exists() and path.read_bytes() != data and not generated:
        raise ValueError(f"output differs; select a new --output directory: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_bytes() != data:
        path.write_bytes(data)
    path.chmod(mode)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=HERE / "work/prepared")
    args = parser.parse_args()
    lock, original, tree, groups = prepared_tree()
    package = args.output / "luci-app-passwall"
    previous_path = args.output / "manifest.json"
    previous = json.loads(previous_path.read_text())["manifest"] if previous_path.exists() else {}
    # Check every previous generated file before updating any of it. Hand edits
    # are preserved by refusing refresh, not silently discarded during prepare.
    for name, entry in previous.items():
        path = package / name
        data = os.readlink(path).encode() if path.is_symlink() else path.read_bytes()
        if sha256(data) != entry["sha256"]:
            raise ValueError(f"generated file was edited: {path}; select another --output")
    for name, (data, mode) in sorted(tree.items()):
        path = package / name
        if mode == 0o120777:
            path.parent.mkdir(parents=True, exist_ok=True)
            if path.is_symlink():
                if os.readlink(path) != data.decode():
                    raise ValueError(f"output link differs: {path}")
            elif path.exists():
                raise ValueError(f"output must be a symlink: {path}")
            else:
                path.symlink_to(data.decode())
        else:
            write_exact(path, data, mode, generated=name in previous)
    existing = {p.relative_to(package).as_posix() for p in package.rglob("*") if p.is_file() or p.is_symlink()}
    if existing != set(tree):
        raise ValueError("generated tree contains unexpected files")
    manifest = {name: {"sha256": sha256(data), "mode": oct(mode)} for name, (data, mode) in sorted(tree.items())}
    changes = []
    for name in sorted(tree):
        if name not in original or tree[name][0] != original[name][0]:
            before = original.get(name, (b"", 0))[0].decode().splitlines(keepends=True)
            after = tree[name][0].decode().splitlines(keepends=True)
            changes.extend(difflib.unified_diff(before, after, fromfile="a/" + name, tofile="b/" + name))
    report = {"source": lock, "fixup_groups": groups, "upstream_files": len(original),
              "removed_files": [], "manifest": manifest}
    write_exact(args.output / "manifest.json", (json.dumps(report, indent=2, ensure_ascii=False) + "\n").encode(), generated=bool(previous))
    write_exact(args.output / "changes.patch", "".join(changes).encode(), generated=bool(previous))
    print(f"prepared {len(tree)} files; removed 0 upstream files: {package}")
    print(f"manifest SHA256: {sha256((args.output / 'manifest.json').read_bytes())}")


if __name__ == "__main__":
    main()
