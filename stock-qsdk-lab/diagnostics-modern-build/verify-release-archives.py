#!/usr/bin/env python3
"""Verify official release archives against locked upstream Git objects.

The archive SHA-256 values are checked by verify-sources.sh.  This verifier
adds structural safety checks and proves that every shipped, version-controlled
source file matches the locked release tag, except for the two documented mtr
release-packaging repairs.
"""

from __future__ import annotations

import argparse
import pathlib
import posixpath
import re
import subprocess
import tarfile


BUILD_DIR = pathlib.Path(__file__).resolve().parent
PRIVATE_KEY = re.compile(rb"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----")

EXPECTED_MISSING = {
    "mtr": {
        ".dir-locals.el",
        ".flake8",
        ".github/workflows/test.yaml",
        ".gitignore",
        "FORMATS",
        "bootstrap.sh",
        "build-aux/git-version-gen",
        "build-aux/mangen.sh",
        "portability/.gitignore",
        "test/linux/netem.py",
        "test/linux/netemtests.py",
    },
    "htop": {
        ".editorconfig",
        ".github/FUNDING.yml",
        ".github/dependabot.yml",
        ".github/workflows/build_release.yml",
        ".github/workflows/ci.yml",
        ".github/workflows/codeql-analysis.yml",
        ".github/workflows/coverity.yml",
        ".github/workflows/htoprc",
        ".gitignore",
        ".travis.yml",
    },
    "nano": {
        ".gitignore",
        "ChangeLog.1999-2006",
        "ChangeLog.2007-2015",
        "README.hacking",
        "autogen.sh",
        "doc/.gitignore",
        "doc/cheatsheet.html",
        "nano-regress",
        "po/.gitignore",
        "po/update_linguas.sh",
        "roll-a-release.sh",
    },
}

EXPECTED_CHANGED = {
    "mtr": {"Makefile.am", "README.md"},
    "htop": set(),
    "nano": set(),
}


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def read_lock() -> dict[str, str]:
    values: dict[str, str] = {}
    for line in (BUILD_DIR / "sources.lock").read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        if not re.fullmatch(r"[A-Z0-9_]+=[^\x00\r\n]*", line):
            fail(f"cannot safely parse sources.lock line: {line!r}")
        key, value = line.split("=", 1)
        values[key] = value
    return values


def safe_members(archive: pathlib.Path, prefix: str) -> dict[str, tarfile.TarInfo]:
    members: dict[str, tarfile.TarInfo] = {}
    with tarfile.open(archive, "r:*") as tar:
        for member in tar.getmembers():
            raw_parts = member.name.split("/")
            if (
                member.name.startswith("/")
                or "" in raw_parts[:-1]
                or "." in raw_parts
                or ".." in raw_parts
            ):
                fail(f"{archive.name} has unsafe member path {member.name!r}")
            if member.name != prefix[:-1] and not member.name.startswith(prefix):
                fail(f"{archive.name} has member outside {prefix}: {member.name!r}")
            if member.ischr() or member.isblk() or member.isfifo() or member.isdev():
                fail(f"{archive.name} has special-device member {member.name!r}")
            if member.mode & 0o6000:
                fail(f"{archive.name} has setuid/setgid source member {member.name!r}")
            if member.issym() or member.islnk():
                if member.linkname.startswith("/"):
                    fail(f"{archive.name} has absolute link {member.name!r}")
                base = "" if member.islnk() else posixpath.dirname(member.name)
                target = posixpath.normpath(posixpath.join(base, member.linkname))
                if target != prefix[:-1] and not target.startswith(prefix):
                    fail(f"{archive.name} link escapes its source root: {member.name!r}")
            if member.name == prefix[:-1]:
                continue
            relative = member.name[len(prefix) :]
            if relative in members:
                fail(f"{archive.name} repeats member {relative!r}")
            members[relative] = member

        for relative, member in members.items():
            if not member.isfile():
                continue
            extracted = tar.extractfile(member)
            if extracted is None:
                fail(f"cannot read {archive.name}:{relative}")
            if PRIVATE_KEY.search(extracted.read()):
                fail(f"{archive.name} contains private-key material in {relative}")
    return members


def git_entries(repo: pathlib.Path, commit: str) -> dict[str, tuple[str, str]]:
    raw = subprocess.check_output(
        ["git", "-C", str(repo), "ls-tree", "-rz", "--full-tree", commit]
    )
    entries: dict[str, tuple[str, str]] = {}
    for record in raw.rstrip(b"\0").split(b"\0"):
        metadata, path_bytes = record.split(b"\t", 1)
        mode, object_type, object_id = metadata.decode("ascii").split()
        if object_type != "blob":
            fail(f"{repo.name} tag unexpectedly contains {object_type} at {path_bytes!r}")
        path = path_bytes.decode("utf-8")
        entries[path] = (mode, object_id)
    return entries


def git_blob(repo: pathlib.Path, object_id: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(repo), "cat-file", "blob", object_id])


def compare_release(
    name: str, archive: pathlib.Path, prefix: str, commit: str
) -> None:
    repo = BUILD_DIR / "sources" / name
    members = safe_members(archive, prefix)
    entries = git_entries(repo, commit)
    missing: set[str] = set()
    changed: set[str] = set()

    with tarfile.open(archive, "r:*") as tar:
        for path, (mode, object_id) in entries.items():
            member = members.get(path)
            if member is None:
                missing.add(path)
                continue
            expected = git_blob(repo, object_id)
            if mode == "120000":
                actual = member.linkname.encode("utf-8") if member.issym() else b""
            elif member.isfile():
                extracted = tar.extractfile(member)
                actual = extracted.read() if extracted is not None else b""
                expected_executable = mode == "100755"
                if bool(member.mode & 0o111) != expected_executable:
                    changed.add(path)
            else:
                actual = b""
            if actual != expected:
                changed.add(path)

    if missing != EXPECTED_MISSING[name]:
        fail(
            f"{name} release/tag missing-file set changed: "
            f"expected={sorted(EXPECTED_MISSING[name])} actual={sorted(missing)}"
        )
    if changed != EXPECTED_CHANGED[name]:
        fail(
            f"{name} release/tag changed-file set changed: "
            f"expected={sorted(EXPECTED_CHANGED[name])} actual={sorted(changed)}"
        )

    if name == "mtr":
        tag_makefile = git_blob(repo, entries["Makefile.am"][1])
        tag_readme = git_blob(repo, entries["README.md"][1])
        with tarfile.open(archive, "r:*") as tar:
            makefile_stream = tar.extractfile(members["Makefile.am"])
            readme_stream = tar.extractfile(members["README.md"])
            if makefile_stream is None or readme_stream is None:
                fail("cannot read mtr release packaging deltas")
            release_makefile = makefile_stream.read()
            release_readme = readme_stream.read()
        expected_makefile = tag_makefile.replace(
            b"\tpacket/probe.c packet/probe.h \\\n",
            b"\tpacket/probe.c packet/probe.h \\\n\tpacket/utils.h \\\n",
        )
        if expected_makefile != release_makefile:
            fail("mtr release Makefile.am delta is not solely the packet/utils.h repair")

        expected_readme = tag_readme.replace(
            b"where it says <host>) or", b"where it says ``<host>``) or"
        )
        if expected_readme != release_readme:
            fail("mtr release README.md delta is not solely the documented markup repair")

    if "configure" not in members or not members["configure"].isfile():
        fail(f"{name} official release archive lacks generated configure")
    if name == "nano" and not any(path.startswith("lib/") for path in members):
        fail("nano official release archive lacks generated gnulib sources")

    print(
        f"verified {name:4s} official archive={archive.name} "
        f"tag-missing={len(missing)} tag-deltas={len(changed)}"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive_dir", nargs="?", default=str(BUILD_DIR / "distfiles"))
    args = parser.parse_args()
    archive_dir = pathlib.Path(args.archive_dir)
    lock = read_lock()

    compare_release(
        "mtr",
        archive_dir / lock["MTR_RELEASE_ARCHIVE"],
        f"mtr-{lock['MTR_VERSION']}/",
        lock["MTR_COMMIT"],
    )
    compare_release(
        "htop",
        archive_dir / lock["HTOP_RELEASE_ARCHIVE"],
        f"htop-{lock['HTOP_VERSION']}/",
        lock["HTOP_COMMIT"],
    )
    compare_release(
        "nano",
        archive_dir / lock["NANO_RELEASE_ARCHIVE"],
        f"nano-{lock['NANO_VERSION']}/",
        lock["NANO_COMMIT"],
    )
    print("PASS: official release archives are path-safe and match the locked tags.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
