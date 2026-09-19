#!/usr/bin/env python3
"""Initialize source dependencies; never reset an existing checkout or update locks."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

LAB = Path(__file__).resolve().parents[1]
CATALOG = LAB / "sources/dependencies.json"


def run(*args, **kwargs):
    print("+ " + " ".join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def git(path: Path, *args: str) -> str:
    return subprocess.check_output(
        ["git", "-C", str(path), *args], text=True).strip()


def dependencies(lab: Path = LAB) -> dict:
    data = json.loads((lab / "sources/dependencies.json").read_text())
    if data.get("format") != 1:
        raise ValueError("unsupported dependency catalog format")
    seen = set()
    for dep in data["git"]:
        relative = Path(dep["path"])
        if relative.is_absolute() or ".." in relative.parts or ".git" in relative.parts:
            raise ValueError("unsafe dependency path")
        if not relative.parts or dep["path"] in seen:
            raise ValueError("duplicate or empty dependency path")
        seen.add(dep["path"])
        if not re.fullmatch(r"[0-9a-f]{40}", dep["commit"]):
            raise ValueError("dependency commit must be a full immutable Git object ID")
        if not dep["url"].startswith("https://"):
            raise ValueError("source dependencies require HTTPS origins")
        if not (lab / relative).resolve().is_relative_to(lab.resolve()):
            raise ValueError("dependency path escapes the build directory")
    return data


def verify_checkout(path: Path, dep: dict) -> None:
    if not (path / ".git").exists():
        raise ValueError(f"missing source checkout: {dep['path']}")
    if git(path, "rev-parse", "HEAD") != dep["commit"]:
        raise ValueError(f"{dep['path']}: HEAD differs from lock; existing checkout preserved")
    if git(path, "remote", "get-url", "origin") != dep["url"]:
        raise ValueError(f"{dep['path']}: origin differs from lock")
    if git(path, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError(f"{dep['path']}: source checkout has local changes; preserved")


def detach_git_directory(path: Path, lab: Path) -> None:
    """Copy former submodule metadata locally. Keep the original for recovery.

    No source files, refs, or parent .git/modules directories are removed. A
    normal clone never needs this migration. Git worktrees are NOT submodules.
    """
    marker = path / ".git"
    if not marker.is_file():
        return
    source = Path(git(path, "rev-parse", "--absolute-git-dir"))
    common = Path(git(path, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    if source != common or "modules" not in source.parts:
        raise ValueError(f"refusing to convert a Git worktree: {path}")
    if (source / "objects/info/alternates").exists():
        raise ValueError(f"shared object store requires a standalone clone: {path}")
    backup = lab / "work/submodule-migration" / path.relative_to(lab) / "gitdir-pointer"
    backup.parent.mkdir(parents=True, exist_ok=True)
    if backup.exists() and backup.read_bytes() != marker.read_bytes():
        raise ValueError(f"migration backup already differs: {backup}")
    staging = Path(tempfile.mkdtemp(prefix=".git-migrate-", dir=path))
    try:
        shutil.copytree(source, staging, dirs_exist_ok=True, symlinks=True)
        # Former submodule core.worktree is relative to the parent's .git/modules.
        result = subprocess.run(["git", "--git-dir=" + str(staging),
                                 "--work-tree=" + str(path), "config",
                                 "--unset", "core.worktree"])
        if result.returncode not in (0, 5):
            raise ValueError("could not detach former submodule worktree setting")
        shutil.copyfile(marker, backup)
        marker.unlink()
        try:
            staging.rename(marker)
        except BaseException:
            shutil.copyfile(backup, marker)
            raise
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def initialize_checkout(lab: Path, dep: dict, check: bool = False) -> None:
    path = lab / dep["path"]
    if path.exists():
        # A fresh Git checkout may leave an empty directory for a removed gitlink.
        if path.is_dir() and not any(path.iterdir()) and not check:
            path.rmdir()
        else:
            verify_checkout(path, dep)
            if not check:
                detach_git_directory(path, lab)
                verify_checkout(path, dep)
            print(f"verified {dep['path']} @ {dep['commit'][:12]}", flush=True)
            return
    if check:
        raise ValueError(f"missing source checkout: {dep['path']}; run build.sh sources")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=".sbe-clone-", dir=path.parent))
    try:
        # Full refs/tags are intentional: component audits verify ancestry and
        # signed release tags in addition to the pinned commit.
        run("git", "-c", "core.autocrlf=false", "clone", "--no-checkout",
            dep["url"], temporary)
        run("git", "-C", temporary, "config", "core.autocrlf", "false")
        run("git", "-C", temporary, "checkout", "--detach", dep["commit"])
        verify_checkout(temporary, dep)
        temporary.rename(path)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def qsdk_sources(root: Path, check: bool) -> None:
    env = dict(os.environ, QSDK_SOURCE_ROOT=str(root))
    if not check and os.uname().sysname == "Darwin":
        root.mkdir(parents=True, exist_ok=True)
        probe = Path(tempfile.mkdtemp(prefix=".sbe-case-", dir=root))
        try:
            (probe / "lower").mkdir()
            insensitive = (probe / "LOWER").exists()
        finally:
            shutil.rmtree(probe)
        if insensitive:
            image = LAB / "work/qsdk-sources.sparsebundle"
            image.parent.mkdir(parents=True, exist_ok=True)
            env["QSDK_SOURCE_IMAGE"] = str(image)
            action = "mount" if image.exists() else "create"
            run("sh", LAB / "qsdk-build/mount-case-sensitive-source-macos.sh", action, env=env)
    # The stock-based image retains vendor kernel/NSS/WLAN binaries. The six
    # build-ready projects are sufficient for userland; do not download 67
    # unrelated kernel/bootloader projects just to produce these packages.
    scripts = ["verify-sources.sh" if check else "fetch-sources.sh"]
    for script in scripts:
        run("sh", LAB / "qsdk-build" / script, env=env)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="read-only source verification; no downloads")
    parser.add_argument("--git-only", action="store_true", help="initialize component Git sources, excluding QSDK")
    parser.add_argument("--qsdk-source-root", type=Path,
                        default=Path(os.environ.get("QSDK_SOURCE_ROOT", LAB / "deps/qsdk-spf12.2-locked")))
    args = parser.parse_args()
    catalog = dependencies()
    for dep in catalog["git"]:
        initialize_checkout(LAB, dep, args.check)
    if not args.git_only:
        qsdk_sources(args.qsdk_source_root.resolve(), args.check)
    print("PASS: locked source dependencies verified; no submodule update is required.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as exc:
        raise SystemExit(f"ERROR: {exc}") from exc
