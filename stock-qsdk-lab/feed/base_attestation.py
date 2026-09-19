#!/usr/bin/env python3
"""Create and verify the immutable package-feed base attestation."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


PACKAGE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+._-]{0,127}$")
PROFILE_NAME = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
ATTESTATION_PATH = PurePosixPath("usr/share/sbe-opkg/base-attestation")
PROFILE_REPORT_PATH = PurePosixPath("usr/share/sbe-build/component-profile.json")
SCHEMA = "1"


class AttestationError(RuntimeError):
    pass


@dataclass(frozen=True)
class BaseAttestation:
    profile: str
    profile_sha256: str
    paths_sha256: str
    namespace_sha256: str
    packages: dict[str, str]
    provides: dict[str, str]
    sha256: str


def parse_control(contents: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    current: str | None = None
    for raw_line in contents.splitlines():
        if raw_line.startswith((" ", "\t")):
            if current is None:
                raise AttestationError("status continuation without a field")
            fields[current] += "\n" + raw_line[1:]
            continue
        if not raw_line:
            continue
        if ":" not in raw_line:
            raise AttestationError(f"malformed status line: {raw_line!r}")
        current, value = raw_line.split(":", 1)
        current = current.strip()
        if not current or current in fields:
            raise AttestationError(f"duplicate or empty status field: {current!r}")
        fields[current] = value.lstrip()
    return fields


def checked_token(value: str, label: str) -> str:
    if not value or "\t" in value or "\n" in value or "\r" in value:
        raise AttestationError(f"unsafe {label}: {value!r}")
    return value


def read_namespace(status_path: Path) -> tuple[dict[str, str], dict[str, str]]:
    if status_path.is_symlink() or not status_path.is_file():
        raise AttestationError(f"installed package database is missing or unsafe: {status_path}")
    packages: dict[str, str] = {}
    raw_status = status_path.read_text(encoding="utf-8")
    installed_records: list[dict[str, str]] = []
    for stanza in re.split(r"\n[ \t]*\n", raw_status):
        if not stanza.strip():
            continue
        fields = parse_control(stanza)
        if fields.get("Status") != "install ok installed":
            continue
        package = fields.get("Package", "")
        version = checked_token(fields.get("Version", ""), "package version")
        if not PACKAGE_NAME.fullmatch(package):
            raise AttestationError(f"unsafe installed package name: {package!r}")
        if package in packages:
            raise AttestationError(f"duplicate installed package namespace: {package}")
        packages[package] = version
        installed_records.append(fields)
    if not packages:
        raise AttestationError("installed package namespace is empty")

    provides: dict[str, str] = {}
    for fields in installed_records:
        provider = fields["Package"]
        raw_provides = fields.get("Provides", "").strip()
        if not raw_provides:
            continue
        for raw_name in raw_provides.split(","):
            virtual = raw_name.strip()
            if not PACKAGE_NAME.fullmatch(virtual):
                raise AttestationError(
                    f"unsupported or versioned Provides entry from {provider}: {virtual!r}"
                )
            if virtual in packages:
                raise AttestationError(
                    f"Provides namespace collides with installed Package: {virtual}"
                )
            previous = provides.get(virtual)
            if previous is not None:
                raise AttestationError(
                    f"Provides namespace is not unique: {virtual} from {previous} and {provider}"
                )
            provides[virtual] = provider
    return packages, provides


def path_kind(mode: int) -> str:
    if stat.S_ISREG(mode):
        return "file"
    if stat.S_ISDIR(mode):
        return "directory"
    if stat.S_ISLNK(mode):
        return "symlink"
    if stat.S_ISCHR(mode):
        return "character"
    if stat.S_ISBLK(mode):
        return "block"
    if stat.S_ISFIFO(mode):
        return "fifo"
    if stat.S_ISSOCK(mode):
        return "socket"
    raise AttestationError(f"unsupported filesystem object mode: {mode:o}")


def path_rows(root: Path) -> list[str]:
    if root.is_symlink() or not root.is_dir():
        raise AttestationError(f"base rootfs is missing or unsafe: {root}")
    rows: list[str] = []
    root_mode = root.lstat().st_mode
    rows.append(f"/\tdirectory\t{root_mode & 0o7777:04o}\n")
    pending = [PurePosixPath(".")]
    while pending:
        relative_parent = pending.pop()
        parent = root if relative_parent == PurePosixPath(".") else root / relative_parent
        try:
            entries = sorted(os.scandir(parent), key=lambda entry: entry.name)
        except OSError as error:
            raise AttestationError(f"cannot enumerate base rootfs path: {parent}") from error
        directories: list[PurePosixPath] = []
        for entry in entries:
            if any(character in entry.name for character in ("\t", "\n", "\r")):
                raise AttestationError(f"unsafe base-root path component: {entry.name!r}")
            relative = (
                PurePosixPath(entry.name)
                if relative_parent == PurePosixPath(".")
                else relative_parent / entry.name
            )
            if relative == ATTESTATION_PATH:
                continue
            item_stat = entry.stat(follow_symlinks=False)
            kind = path_kind(item_stat.st_mode)
            rows.append(f"/{relative.as_posix()}\t{kind}\t{item_stat.st_mode & 0o7777:04o}\n")
            if kind == "directory":
                directories.append(relative)
        pending.extend(reversed(directories))
    return sorted(rows)


def namespace_rows(
    packages: dict[str, str], provides: dict[str, str]
) -> list[str]:
    rows = [f"package\t{name}\t{version}\n" for name, version in packages.items()]
    rows.extend(f"provide\t{name}\t{provider}\n" for name, provider in provides.items())
    return sorted(rows)


def digest_rows(rows: list[str]) -> str:
    return hashlib.sha256("".join(rows).encode("utf-8")).hexdigest()


def verify_profile_report(root: Path, profile: str, profile_sha256: str) -> None:
    report_path = root / PROFILE_REPORT_PATH
    if report_path.is_symlink() or not report_path.is_file():
        raise AttestationError(f"component profile runtime report is missing or unsafe: {report_path}")
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise AttestationError("component profile runtime report is malformed") from error
    if not isinstance(report, dict):
        raise AttestationError("component profile runtime report is not an object")
    if report.get("name") != profile or report.get("profile_sha256") != profile_sha256:
        raise AttestationError(
            "component profile identity/hash differs from its embedded runtime report"
        )


def render(
    root: Path, profile: str, profile_sha256: str
) -> tuple[bytes, dict[str, str], dict[str, str], str, str]:
    if not PROFILE_NAME.fullmatch(profile):
        raise AttestationError(f"unsafe component profile identity: {profile!r}")
    if not HEX64.fullmatch(profile_sha256):
        raise AttestationError("component profile SHA256 is invalid")
    packages, provides = read_namespace(root / "usr/lib/opkg/status")
    paths_sha256 = digest_rows(path_rows(root))
    namespace_sha256 = digest_rows(namespace_rows(packages, provides))
    lines = [
        f"SBE-Base-Attestation-Version: {SCHEMA}\n",
        f"SBE-Component-Profile: {profile}\n",
        f"SBE-Component-Profile-SHA256: {profile_sha256}\n",
        f"SBE-Path-Type-Mode-SHA256: {paths_sha256}\n",
        f"SBE-Package-Namespace-SHA256: {namespace_sha256}\n",
    ]
    lines.extend(f"SBE-Package: {name}\t{packages[name]}\n" for name in sorted(packages))
    lines.extend(f"SBE-Provide: {name}\t{provides[name]}\n" for name in sorted(provides))
    return "".join(lines).encode("utf-8"), packages, provides, paths_sha256, namespace_sha256


def create(root: Path, profile: str, profile_file: Path, output: Path) -> BaseAttestation:
    if profile_file.is_symlink() or not profile_file.is_file():
        raise AttestationError(f"component profile file is missing or unsafe: {profile_file}")
    profile_sha256 = hashlib.sha256(profile_file.read_bytes()).hexdigest()
    expected = root / ATTESTATION_PATH
    if output.resolve(strict=False) != expected.resolve(strict=False):
        raise AttestationError(f"attestation must be embedded at /{ATTESTATION_PATH}")
    # The containing directory is part of the attested path/type/mode set;
    # create it before calculating the digest while excluding only the file
    # itself to avoid a self-reference.
    output.parent.mkdir(parents=True, exist_ok=True)
    verify_profile_report(root, profile, profile_sha256)
    data, packages, provides, paths_sha256, namespace_sha256 = render(
        root, profile, profile_sha256
    )
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".base-attestation.", dir=output.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
        temporary.chmod(0o644)
        temporary.replace(output)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
    return BaseAttestation(
        profile,
        profile_sha256,
        paths_sha256,
        namespace_sha256,
        packages,
        provides,
        hashlib.sha256(data).hexdigest(),
    )


def parse_attestation(data: bytes) -> tuple[str, str, str, str, dict[str, str], dict[str, str]]:
    try:
        text = data.decode("utf-8", "strict")
    except UnicodeError as error:
        raise AttestationError("base attestation is not UTF-8") from error
    headers: dict[str, str] = {}
    packages: dict[str, str] = {}
    provides: dict[str, str] = {}
    for raw_line in text.splitlines():
        if ": " not in raw_line:
            raise AttestationError(f"malformed base attestation line: {raw_line!r}")
        field, value = raw_line.split(": ", 1)
        if field == "SBE-Package":
            columns = value.split("\t")
            if len(columns) != 2 or not PACKAGE_NAME.fullmatch(columns[0]):
                raise AttestationError("malformed base attestation Package record")
            checked_token(columns[1], "attested package version")
            if columns[0] in packages:
                raise AttestationError(f"duplicate attested Package: {columns[0]}")
            packages[columns[0]] = columns[1]
        elif field == "SBE-Provide":
            columns = value.split("\t")
            if len(columns) != 2 or not all(PACKAGE_NAME.fullmatch(item) for item in columns):
                raise AttestationError("malformed base attestation Provide record")
            if columns[0] in provides:
                raise AttestationError(f"duplicate attested Provide: {columns[0]}")
            provides[columns[0]] = columns[1]
        else:
            if field in headers:
                raise AttestationError(f"duplicate base attestation field: {field}")
            headers[field] = value
    expected_headers = {
        "SBE-Base-Attestation-Version",
        "SBE-Component-Profile",
        "SBE-Component-Profile-SHA256",
        "SBE-Path-Type-Mode-SHA256",
        "SBE-Package-Namespace-SHA256",
    }
    if set(headers) != expected_headers:
        raise AttestationError("base attestation header set is incomplete or unexpected")
    if headers["SBE-Base-Attestation-Version"] != SCHEMA:
        raise AttestationError("unsupported base attestation schema")
    if not PROFILE_NAME.fullmatch(headers["SBE-Component-Profile"]):
        raise AttestationError("invalid attested component profile")
    for field in (
        "SBE-Component-Profile-SHA256",
        "SBE-Path-Type-Mode-SHA256",
        "SBE-Package-Namespace-SHA256",
    ):
        if not HEX64.fullmatch(headers[field]):
            raise AttestationError(f"invalid digest in {field}")
    if not packages:
        raise AttestationError("attested package namespace is empty")
    for virtual, provider in provides.items():
        if virtual in packages:
            raise AttestationError(f"attested Provide collides with Package: {virtual}")
        if provider not in packages:
            raise AttestationError(f"attested Provide has missing provider: {virtual}")
    if digest_rows(namespace_rows(packages, provides)) != headers["SBE-Package-Namespace-SHA256"]:
        raise AttestationError("attested package namespace digest mismatch")
    return (
        headers["SBE-Component-Profile"],
        headers["SBE-Component-Profile-SHA256"],
        headers["SBE-Path-Type-Mode-SHA256"],
        headers["SBE-Package-Namespace-SHA256"],
        packages,
        provides,
    )


def verify(root: Path, path: Path | None = None) -> BaseAttestation:
    path = path or root / ATTESTATION_PATH
    if path.is_symlink() or not path.is_file():
        raise AttestationError(f"base attestation is missing or unsafe: {path}")
    data = path.read_bytes()
    profile, profile_sha256, paths_sha256, namespace_sha256, packages, provides = (
        parse_attestation(data)
    )
    verify_profile_report(root, profile, profile_sha256)
    expected, actual_packages, actual_provides, actual_paths_sha256, actual_namespace_sha256 = (
        render(root, profile, profile_sha256)
    )
    if data != expected:
        raise AttestationError("embedded base attestation does not match the exact assembled rootfs")
    if packages != actual_packages or provides != actual_provides:
        raise AttestationError("embedded namespace differs from assembled package status")
    if paths_sha256 != actual_paths_sha256 or namespace_sha256 != actual_namespace_sha256:
        raise AttestationError("embedded base attestation digest differs from assembled rootfs")
    return BaseAttestation(
        profile,
        profile_sha256,
        paths_sha256,
        namespace_sha256,
        packages,
        provides,
        hashlib.sha256(data).hexdigest(),
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    creator = subparsers.add_parser("create")
    creator.add_argument("--root", type=Path, required=True)
    creator.add_argument("--profile", required=True)
    creator.add_argument("--profile-file", type=Path, required=True)
    creator.add_argument("--output", type=Path, required=True)
    verifier = subparsers.add_parser("verify")
    verifier.add_argument("--root", type=Path, required=True)
    verifier.add_argument("--attestation", type=Path)
    args = parser.parse_args()
    if args.command == "create":
        result = create(
            args.root.resolve(), args.profile, args.profile_file.resolve(), args.output.resolve()
        )
        print(f"created base attestation {result.sha256} for {result.profile}")
    else:
        result = verify(args.root.resolve(), args.attestation.resolve() if args.attestation else None)
        print(f"verified base attestation {result.sha256} for {result.profile}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AttestationError, OSError, UnicodeError) as error:
        raise SystemExit(f"base attestation error: {error}")
