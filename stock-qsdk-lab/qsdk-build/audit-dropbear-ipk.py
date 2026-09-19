#!/usr/bin/env python3
"""Fail-closed metadata and privacy audit for the isolated Dropbear IPK."""

from __future__ import annotations

import hashlib
import io
import posixpath
import re
import sys
import tarfile
from pathlib import Path, PurePosixPath


EXPECTED_PACKAGE = "sbe-dropbear2026-candidate"
EXPECTED_VERSION = "2026.94-3"
EXPECTED_ARCH = "aarch64_cortex-a73_neon-vfpv4"
EXPECTED_SOURCE = "dropbear-2026.94.tar.bz2"
PAYLOAD_PREFIX = "usr/libexec/sbe-qsdk-lab/dropbear-2026.94"
FORBIDDEN_BYTES = (
    b"/Users/",
    b"yangzhg",
    b"/workspace/",
    b"/private/tmp/",
    b"-----BEGIN OPENSSH PRIVATE KEY-----",
    b"-----BEGIN RSA PRIVATE KEY-----",
    b"-----BEGIN EC PRIVATE KEY-----",
    b"-----BEGIN PRIVATE KEY-----",
)


class AuditError(RuntimeError):
    pass


def canonical_name(name: str) -> str:
    while name.startswith("./"):
        name = name[2:]
    if name in ("", "."):
        return "."
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts:
        raise AuditError(f"unsafe archive member path: {name!r}")
    normalized = posixpath.normpath(name)
    if normalized.startswith("../") or normalized == "..":
        raise AuditError(f"escaping archive member path: {name!r}")
    return normalized


def audit_members(archive: tarfile.TarFile, label: str) -> dict[str, tarfile.TarInfo]:
    result: dict[str, tarfile.TarInfo] = {}
    for member in archive.getmembers():
        name = canonical_name(member.name)
        if name in result:
            raise AuditError(f"duplicate {label} member: {name}")
        result[name] = member
        if member.uid != 0 or member.gid != 0:
            raise AuditError(
                f"{label} member is not owned by uid/gid 0: {name} "
                f"({member.uid}:{member.gid})"
            )
        if member.issym():
            target = member.linkname
            if PurePosixPath(target).is_absolute():
                raise AuditError(f"absolute symlink in {label}: {name} -> {target}")
            resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
            if resolved == ".." or resolved.startswith("../"):
                raise AuditError(f"escaping symlink in {label}: {name} -> {target}")
        elif member.isfile():
            if member.mode & 0o002:
                raise AuditError(f"world-writable regular file in {label}: {name}")
            if member.mode & 0o6000:
                raise AuditError(f"setuid/setgid regular file in {label}: {name}")
        elif not member.isdir():
            raise AuditError(f"special archive member in {label}: {name}")
    return result


def member_bytes(archive: tarfile.TarFile, member: tarfile.TarInfo) -> bytes:
    stream = archive.extractfile(member)
    if stream is None:
        raise AuditError(f"could not read regular archive member: {member.name}")
    return stream.read()


def audit_forbidden_bytes(
    archive: tarfile.TarFile,
    members: dict[str, tarfile.TarInfo],
    label: str,
) -> None:
    for name, member in members.items():
        if not member.isfile():
            continue
        content = member_bytes(archive, member)
        for marker in FORBIDDEN_BYTES:
            if marker in content:
                raise AuditError(f"{label} member {name} contains {marker!r}")


def control_field(text: str, field: str) -> str:
    match = re.search(rf"^{re.escape(field)}:[ \t]*(.+)$", text, re.MULTILINE)
    if not match:
        raise AuditError(f"control omits {field}")
    return match.group(1).strip()


def audit(ipk_path: Path) -> None:
    raw_ipk = ipk_path.read_bytes()
    with tarfile.open(fileobj=io.BytesIO(raw_ipk), mode="r:gz") as outer:
        outer_members = audit_members(outer, "outer IPK")
        outer_names = set(outer_members)
        expected_outer = {"debian-binary", "data.tar.gz", "control.tar.gz"}
        if outer_names != expected_outer:
            raise AuditError(f"unexpected outer IPK members: {sorted(outer_names)}")
        if member_bytes(outer, outer_members["debian-binary"]) != b"2.0\n":
            raise AuditError("unexpected IPK format marker")
        data_blob = member_bytes(outer, outer_members["data.tar.gz"])
        control_blob = member_bytes(outer, outer_members["control.tar.gz"])

    with tarfile.open(fileobj=io.BytesIO(control_blob), mode="r:gz") as control_tar:
        controls = audit_members(control_tar, "control")
        if set(controls) != {".", "control", "postinst", "prerm"}:
            raise AuditError(f"unexpected control members: {sorted(controls)}")
        control = member_bytes(control_tar, controls["control"]).decode("utf-8")
        expected_fields = {
            "Package": EXPECTED_PACKAGE,
            "Version": EXPECTED_VERSION,
            "Architecture": EXPECTED_ARCH,
            "Source": EXPECTED_SOURCE,
        }
        for field, expected in expected_fields.items():
            actual = control_field(control, field)
            if actual != expected:
                raise AuditError(f"control {field}={actual!r}, expected {expected!r}")
        flattened = " ".join(line.strip() for line in control.splitlines())
        for claim in (
            "Password and public key authentication are compiled in",
            "blank password is accepted only when the server is explicitly started with -B",
            "Standard server-side TCP, Unix-stream, agent and X11 forwarding are compiled in",
            "package installs no init script, host key, authorized_keys file, password or other credential",
        ):
            if claim not in flattened:
                raise AuditError(f"control description omits policy claim: {claim}")
        audit_forbidden_bytes(control_tar, controls, "control")

    with tarfile.open(fileobj=io.BytesIO(data_blob), mode="r:gz") as data_tar:
        payload = audit_members(data_tar, "data")
        expected_payload = {
            ".",
            "usr",
            "usr/libexec",
            "usr/libexec/sbe-qsdk-lab",
            PAYLOAD_PREFIX,
            f"{PAYLOAD_PREFIX}/dropbear",
            f"{PAYLOAD_PREFIX}/dbclient",
            f"{PAYLOAD_PREFIX}/dropbearkey",
            f"{PAYLOAD_PREFIX}/scp",
        }
        if set(payload) != expected_payload:
            raise AuditError(f"unexpected payload members: {sorted(set(payload) - expected_payload)}")
        binary = payload[f"{PAYLOAD_PREFIX}/dropbear"]
        if not binary.isfile() or binary.mode != 0o755:
            raise AuditError("Dropbear multi-call binary is not a regular 0755 file")
        for applet in ("dbclient", "dropbearkey", "scp"):
            member = payload[f"{PAYLOAD_PREFIX}/{applet}"]
            if not member.issym() or member.linkname != "dropbear":
                raise AuditError(f"unexpected {applet} applet link")

        credential_name = re.compile(
            r"(^|/)(authorized_keys|known_hosts|shadow|passwd|"
            r"dropbear_.*_host_key|id_(rsa|ecdsa|ed25519))$"
        )
        for name in payload:
            if credential_name.search(name) or name.startswith("etc/init.d/"):
                raise AuditError(f"embedded credential/account/init member: {name}")

        audit_forbidden_bytes(data_tar, payload, "payload")

    digest = hashlib.sha256(raw_ipk).hexdigest()
    print(f"PASS: package={EXPECTED_PACKAGE} version={EXPECTED_VERSION}")
    print(f"PASS: Source={EXPECTED_SOURCE} architecture={EXPECTED_ARCH}")
    print("PASS: root-owned safe paths/modes; no special or escaping members")
    print("PASS: no init hook, account database, embedded key or host build path")
    print("PASS: policy description matches runtime/compile-time gates")
    print(f"SHA256: {digest}  {ipk_path.name}")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} DROPBEAR_CANDIDATE.ipk", file=sys.stderr)
        return 2
    try:
        audit(Path(sys.argv[1]))
    except (AuditError, OSError, tarfile.TarError, UnicodeDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
