#!/usr/bin/env python3
"""Create a deterministic standard opkg Packages index from local IPKs."""

from __future__ import annotations

import argparse
import hashlib
import io
import re
import tarfile
from pathlib import Path


PACKAGE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+._-]{0,127}$")
FILENAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+._~-]*\.ipk$")
ARCHITECTURES = {
    "all",
    "noarch",
    "aarch64_generic",
    "aarch64_cortex-a73_neon-vfpv4",
}
FIELDS = (
    "Package",
    "Version",
    "Depends",
    "Provides",
    "Conflicts",
    "Replaces",
    "Alternatives",
    "Essential",
    "Require-User",
    "Source",
    "SourceName",
    "Source-Revision",
    "License",
    "LicenseFiles",
    "Section",
    "Priority",
    "Maintainer",
    "Architecture",
    "Installed-Size",
    "Filename",
    "Size",
    "SHA256sum",
    "Description",
)


class IndexError(RuntimeError):
    pass


def member_bytes(archive: tarfile.TarFile, names: tuple[str, ...]) -> bytes:
    for name in names:
        try:
            member = archive.extractfile(name)
        except KeyError:
            member = None
        if member is not None:
            return member.read()
    raise IndexError(f"archive is missing {names[0]}")


def parse_control(contents: bytes) -> dict[str, str]:
    fields: dict[str, str] = {}
    current: str | None = None
    for raw in contents.decode("utf-8", "strict").splitlines():
        if raw.startswith((" ", "\t")):
            if current is None:
                raise IndexError("control continuation has no field")
            fields[current] += "\n" + raw[1:]
            continue
        if not raw:
            continue
        if ":" not in raw:
            raise IndexError(f"malformed control line: {raw!r}")
        current, value = raw.split(":", 1)
        if current in fields:
            raise IndexError(f"duplicate control field: {current}")
        fields[current] = value.lstrip()
    return fields


def read_ipk(path: Path) -> dict[str, str]:
    try:
        with tarfile.open(path, "r:gz") as outer:
            control_tar = member_bytes(outer, ("./control.tar.gz", "control.tar.gz"))
        with tarfile.open(fileobj=io.BytesIO(control_tar), mode="r:gz") as controls:
            control = member_bytes(controls, ("./control", "control"))
    except (OSError, tarfile.TarError, UnicodeError) as error:
        raise IndexError(f"cannot read {path.name}: {error}") from error
    fields = parse_control(control)
    for required in ("Package", "Version", "Architecture", "Description"):
        if not fields.get(required):
            raise IndexError(f"{path.name}: missing {required}")
    if not PACKAGE.fullmatch(fields["Package"]):
        raise IndexError(f"{path.name}: invalid package name")
    if fields["Architecture"] not in ARCHITECTURES:
        raise IndexError(f"{path.name}: incompatible architecture {fields['Architecture']}")
    if not FILENAME.fullmatch(path.name):
        raise IndexError(f"unsafe IPK filename: {path.name}")
    payload = path.read_bytes()
    fields.update(
        Filename=path.name,
        Size=str(len(payload)),
        SHA256sum=hashlib.sha256(payload).hexdigest(),
    )
    return fields


def write_field(name: str, value: str) -> str:
    lines = value.splitlines() or [""]
    return f"{name}: {lines[0]}\n" + "".join(f" {line}\n" for line in lines[1:])


def build(input_dir: Path) -> str:
    records = [read_ipk(path) for path in sorted(input_dir.glob("*.ipk"))]
    if not records:
        raise IndexError("local feed contains no IPK files")
    records.sort(key=lambda item: (item["Package"], item["Version"], item["Architecture"]))
    seen: set[tuple[str, str, str]] = set()
    output: list[str] = []
    for record in records:
        identity = (record["Package"], record["Version"], record["Architecture"])
        if identity in seen:
            raise IndexError(f"duplicate package tuple: {identity}")
        seen.add(identity)
        for field in FIELDS:
            if field in record:
                output.append(write_field(field, record[field]))
        output.append("\n")
    return "".join(output)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = build(args.input)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_name("." + args.output.name + ".tmp")
    temporary.write_text(result, encoding="utf-8")
    temporary.replace(args.output)
    print(f"indexed {result.count('Package: ')} packages into {args.output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except IndexError as error:
        raise SystemExit(str(error)) from error
