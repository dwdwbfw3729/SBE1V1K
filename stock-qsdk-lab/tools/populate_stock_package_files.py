#!/usr/bin/env python3
"""Restore package ownership for selected tools genuinely retained from stock."""
import argparse
import importlib.util
import json
from pathlib import Path, PurePosixPath


def root_file(root, name):
    """Resolve target-root symlinks without following absolute links on the host."""
    target = PurePosixPath(name)
    if not target.is_absolute():
        raise ValueError(f"stock ownership path is not absolute: {name}")
    pending, resolved, links = list(target.parts[1:]), [], 0
    while pending:
        part = pending.pop(0)
        if part in ("", "."):
            continue
        if part == "..":
            if not resolved:
                raise ValueError(f"stock ownership link escapes target root: {name}")
            resolved.pop()
            continue
        candidate = root.joinpath(*resolved, part)
        if candidate.is_symlink():
            links += 1
            if links > 40:
                raise ValueError(f"stock ownership symlink loop: {name}")
            link = PurePosixPath(candidate.readlink().as_posix())
            if link.is_absolute():
                resolved = []
                pending = list(link.parts[1:]) + pending
            else:
                pending = list(link.parts) + pending
        else:
            resolved.append(part)
    result = root.joinpath(*resolved)
    if not result.is_file() or result.stat().st_size == 0:
        raise ValueError(f"retained stock file is absent or empty: {name}")
    return result


def elf_needed(path):
    # Reuse the existing offline AArch64 ELF parser; no target binary executes.
    spec = importlib.util.spec_from_file_location(
        "stock_ownership_elf", Path(__file__).with_name("audit_elf_abi.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return sorted(module.Elf64(path).needed)


def populate(root, specification):
    status = root / "usr/lib/opkg/status"
    info = root / "usr/lib/opkg/info"
    records = status.read_text().strip().split("\n\n")
    updates = []
    for package, entry in specification.items():
        matches = [i for i, record in enumerate(records)
                   if record.splitlines()[0] == "Package: " + package]
        if len(matches) != 1:
            raise ValueError(f"expected one stock package record: {package}")
        index = matches[0]
        lines = records[index].splitlines()
        if "Version: 0-factory" not in lines:
            # A profile or normal IPK may have replaced the factory package.
            # Its own metadata and file list are authoritative, not this spec.
            continue
        if not entry["files"]:
            raise ValueError(f"stock package file list is empty: {package}")
        for name in entry["files"]:
            root_file(root, name)
        for name, expected in entry.get("elf_needed", {}).items():
            if name not in entry["files"]:
                raise ValueError(f"ELF evidence has no file owner: {name}")
            actual = elf_needed(root_file(root, name))
            if actual != sorted(expected):
                raise ValueError(f"stock ELF dependencies changed: {name}: {actual}")
        for field in ("Depends", "Provides"):
            lines = [line for line in lines if not line.startswith(field + ":")]
            if field in entry:
                lines.append(f"{field}: {entry[field]}")
        records[index] = "\n".join(lines)
        control = [line for line in lines
                   if not line.startswith(("Status:", "Auto-Installed:", "Installed-Time:"))]
        updates.append((package, entry["files"], control))
    # Validate the entire selected set first, so a missing later file cannot
    # leave partial ownership metadata behind.
    info.mkdir(parents=True, exist_ok=True)
    for package, files, control in updates:
        (info / (package + ".list")).write_text("\n".join(files) + "\n")
        (info / (package + ".control")).write_text("\n".join(control) + "\n")
    status.write_text("\n\n".join(records) + "\n\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--spec", type=Path, default=Path(__file__).resolve().parents[1] / "stock-package-files.json")
    args = parser.parse_args()
    populate(args.root, json.loads(args.spec.read_text()))
