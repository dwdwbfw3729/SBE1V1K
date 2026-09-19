#!/usr/bin/env python3
"""Finalize source-built LuCI packages after candidate IPKs are staged.

The stock patcher runs before component promotion so it can validate the
factory-derived tree. Source-built LuCI packages legitimately replace many of
those files afterwards. This step applies backend-neutral maintenance fixes,
keeps the native QSDK views intact, and records the exact final payload.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
import shutil
import stat
from pathlib import Path, PurePosixPath

import patch_stock_rootfs as stock_patcher


LUCI_PACKAGES = {
    "luci-app-firewall",
    "luci-app-opkg",
    "luci-app-upnp",
    "luci-base",
    "luci-compat",
    "luci-i18n-base-zh-cn",
    "luci-i18n-firewall-zh-cn",
    "luci-i18n-opkg-zh-cn",
    "luci-i18n-upnp-zh-cn",
    "luci-lib-ip",
    "luci-lib-jsonc",
    "luci-lib-nixio",
    "luci-mod-admin-full",
    "luci-mod-network",
    "luci-mod-status",
    "luci-mod-system",
    "luci-proto-ipv6",
    "luci-proto-ppp",
    "luci-theme-bootstrap",
    "rpcd-mod-luci",
}

LOCAL_VIEW_OVERRIDES: set[str] = {
    "/www/luci-static/resources/view/system/leds.js",
}

POLICY_REMOVALS: set[str] = set()
LOCK_FIELDS = (
    "path",
    "owner",
    "raw_kind",
    "raw_mode",
    "raw_value",
    "final_kind",
    "final_mode",
    "final_value",
    "reason",
)
LOCK_REASONS = {
    "browser-security-headers",
    "local-overlay",
    "login-log-sanitization",
    "management-acl-pruning",
    "management-menu-pruning",
    "policy-removal",
    "runtime-compatibility",
    "status-output-escaping",
    "untrusted-table-escaping",
}


class FinalizationError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise FinalizationError(message)


def canonical_json(value: object) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("utf-8")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalized_path(value: str, *, label: str) -> str:
    if not isinstance(value, str) or not value.startswith("/"):
        fail(f"{label} is not an absolute rootfs path: {value!r}")
    relative = PurePosixPath(value[1:])
    if (
        not relative.parts
        or str(relative) != value[1:]
        or any(part in ("", ".", "..") for part in relative.parts)
        or any(character in value for character in ("\x00", "\n", "\r", "\t"))
    ):
        fail(f"{label} is not normalized: {value!r}")
    return "/" + str(relative)


def checked_path(root: Path, value: str, *, label: str) -> Path:
    normalized = normalized_path(value, label=label)
    relative = PurePosixPath(normalized[1:])
    current = root
    for part in relative.parts[:-1]:
        current = current / part
        if current.is_symlink():
            fail(f"{label} traverses a symlink: {value}")
    return root.joinpath(*relative.parts)


def remove_node(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def copy_node(source: Path, destination: Path) -> None:
    if not (source.exists() or source.is_symlink()) or source.is_dir():
        fail(f"override source is missing or not a file: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    remove_node(destination)
    if source.is_symlink():
        os.symlink(os.readlink(source), destination)
    else:
        shutil.copyfile(source, destination, follow_symlinks=False)
        os.chmod(destination, stat.S_IMODE(source.stat().st_mode))


def load_profile(path: Path) -> tuple[dict[str, object], bytes]:
    try:
        raw = path.read_bytes()
        profile = json.loads(raw)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"cannot read component profile: {error}")
    if not isinstance(profile, dict) or not isinstance(profile.get("packages"), list):
        fail("component profile does not contain a package list")
    return profile, raw


def selected_luci_packages(profile: dict[str, object]) -> dict[str, dict[str, object]]:
    selected: dict[str, dict[str, object]] = {}
    for package in profile["packages"]:  # type: ignore[index]
        if not isinstance(package, dict) or not isinstance(package.get("name"), str):
            fail("component profile contains an invalid package record")
        name = package["name"]
        if name in LUCI_PACKAGES:
            if name in selected:
                fail(f"duplicate LuCI package in component profile: {name}")
            selected[name] = package
    if selected and set(selected) != LUCI_PACKAGES:
        missing = ", ".join(sorted(LUCI_PACKAGES - set(selected)))
        fail(f"source-built LuCI selection is partial; missing: {missing}")
    return selected


def owned_paths(packages: dict[str, dict[str, object]]) -> dict[str, str]:
    owners: dict[str, str] = {}
    for name, package in packages.items():
        for field in ("candidate_paths", "retained_paths"):
            values = package.get(field, [])
            if not isinstance(values, list) or any(not isinstance(item, str) for item in values):
                fail(f"{name} has an invalid {field}")
            for value in values:
                normalized = normalized_path(value, label=f"{name} {field}")
                prior = owners.get(normalized)
                if prior is not None:
                    fail(f"duplicate LuCI path ownership: {normalized} ({prior}, {name})")
                owners[normalized] = name
    return owners


def restore_local_views(root: Path, local_overlay: Path, owners: dict[str, str]) -> list[dict[str, str]]:
    missing_ownership = sorted(LOCAL_VIEW_OVERRIDES - set(owners))
    if missing_ownership:
        fail("local LuCI override lacks candidate ownership: " + ", ".join(missing_ownership))
    restored: list[dict[str, str]] = []
    for path in sorted(LOCAL_VIEW_OVERRIDES):
        source = checked_path(local_overlay, path, label="local overlay path")
        destination = checked_path(root, path, label="rootfs override path")
        if source.is_symlink():
            digest = "symlink:" + os.readlink(source)
        else:
            digest = sha256_file(source)
        copy_node(source, destination)
        restored.append({"path": path, "sha256_or_target": digest})
    return restored


def reconcile_package_lists(
    root: Path, packages: dict[str, dict[str, object]], owners: dict[str, str]
) -> list[str]:
    missing: set[str] = set()
    existing_by_package = {name: [] for name in packages}
    for path, owner in owners.items():
        target = checked_path(root, path, label="owned LuCI path")
        if target.exists() or target.is_symlink():
            if target.is_dir():
                fail(f"LuCI package path became a directory: {path}")
            existing_by_package[owner].append(path)
        else:
            missing.add(path)
    if missing != POLICY_REMOVALS:
        unexpected = sorted(missing - POLICY_REMOVALS)
        retained = sorted(POLICY_REMOVALS - missing)
        details = []
        if unexpected:
            details.append("unexpected missing paths: " + ", ".join(unexpected))
        if retained:
            details.append("policy removals still present: " + ", ".join(retained))
        fail("; ".join(details))

    info = checked_path(root, "/usr/lib/opkg/info", label="opkg info directory")
    if info.is_symlink() or not info.is_dir():
        fail("opkg info directory is missing or unsafe")
    for name, paths in existing_by_package.items():
        listing = info / f"{name}.list"
        if listing.is_symlink() or not listing.is_file():
            fail(f"installed package list is missing: {name}")
        listing.write_text("\n".join(sorted(paths)) + "\n", encoding="utf-8")
    return sorted(missing)


def refresh_component_overlay(
    root: Path, component_overlay: Path, profile: dict[str, object]
) -> int:
    remove_node(component_overlay)
    component_overlay.mkdir(parents=True)
    copied = 0
    seen: set[str] = set()
    for package in profile["packages"]:  # type: ignore[index]
        if not isinstance(package, dict):
            fail("invalid package while refreshing component overlay")
        values = package.get("candidate_paths", [])
        if not isinstance(values, list):
            fail("invalid candidate paths while refreshing component overlay")
        for value in values:
            if not isinstance(value, str):
                fail("non-string candidate path while refreshing component overlay")
            path = normalized_path(value, label="component candidate path")
            if path in seen:
                fail(f"duplicate component candidate path: {path}")
            seen.add(path)
            source = checked_path(root, path, label="final component path")
            if not (source.exists() or source.is_symlink()):
                if path in POLICY_REMOVALS:
                    continue
                fail(f"final component path is missing: {path}")
            destination = checked_path(component_overlay, path, label="component overlay path")
            copy_node(source, destination)
            copied += 1
    return copied


def final_path_digest(root: Path, owners: dict[str, str]) -> tuple[int, str]:
    rows: list[str] = []
    for path in sorted(owners):
        target = checked_path(root, path, label="final LuCI digest path")
        if not (target.exists() or target.is_symlink()):
            continue
        mode = stat.S_IMODE(target.lstat().st_mode)
        if target.is_symlink():
            kind = "symlink"
            value = os.readlink(target)
        elif target.is_file():
            kind = "file"
            value = sha256_file(target)
        else:
            fail(f"final LuCI digest path has unsupported type: {path}")
        rows.append(f"{path}\t{owners[path]}\t{kind}\t{mode:04o}\t{value}\n")
    digest = hashlib.sha256("".join(rows).encode("utf-8")).hexdigest()
    return len(rows), digest


def node_state(root: Path, path: str, *, label: str) -> tuple[str, str, str]:
    target = checked_path(root, path, label=label)
    try:
        mode = target.lstat().st_mode
    except FileNotFoundError:
        return ("absent", "-", "-")
    if stat.S_ISLNK(mode):
        return ("symlink", f"{stat.S_IMODE(mode):04o}", os.readlink(target))
    if stat.S_ISREG(mode):
        return ("file", f"{stat.S_IMODE(mode):04o}", sha256_file(target))
    fail(f"{label} has an unsupported node type: {path}")


def validate_locked_state(
    path: str, state: tuple[str, str, str], *, phase: str
) -> None:
    kind, mode, value = state
    if kind == "absent":
        if phase == "raw" or mode != "-" or value != "-":
            fail(f"invalid {phase} absent state in LuCI finalization lock: {path}")
        return
    if kind not in {"file", "symlink"}:
        fail(f"invalid {phase} kind in LuCI finalization lock: {path}")
    if len(mode) != 4 or any(character not in "01234567" for character in mode):
        fail(f"invalid {phase} mode in LuCI finalization lock: {path}")
    if kind == "file":
        if len(value) != 64 or any(character not in "0123456789abcdef" for character in value):
            fail(f"invalid {phase} file hash in LuCI finalization lock: {path}")
    elif not value or any(character in value for character in ("\x00", "\n", "\r", "\t")):
        fail(f"invalid {phase} symlink target in LuCI finalization lock: {path}")


def load_finalization_lock(
    path: Path, owners: dict[str, str]
) -> tuple[dict[str, dict[str, str]], bytes]:
    try:
        raw = path.read_bytes()
        text = raw.decode("utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"cannot read LuCI finalization lock: {error}")
    reader = csv.DictReader(io.StringIO(text), delimiter="\t")
    if tuple(reader.fieldnames or ()) != LOCK_FIELDS:
        fail("LuCI finalization lock has an invalid header")
    rows: dict[str, dict[str, str]] = {}
    ordered_paths: list[str] = []
    for line_number, row in enumerate(reader, 2):
        if None in row or any(row[field] == "" for field in LOCK_FIELDS):
            fail(f"LuCI finalization lock line {line_number} is empty or malformed")
        locked_path = normalized_path(row["path"], label="LuCI finalization lock path")
        if locked_path in rows:
            fail(f"duplicate LuCI finalization lock path: {locked_path}")
        if owners.get(locked_path) != row["owner"]:
            fail(f"LuCI finalization lock owner mismatch: {locked_path}")
        validate_locked_state(
            locked_path,
            (row["raw_kind"], row["raw_mode"], row["raw_value"]),
            phase="raw",
        )
        validate_locked_state(
            locked_path,
            (row["final_kind"], row["final_mode"], row["final_value"]),
            phase="final",
        )
        if row["reason"] not in LOCK_REASONS:
            fail(f"invalid LuCI finalization reason for {locked_path}")
        rows[locked_path] = row
        ordered_paths.append(locked_path)
    if not rows or ordered_paths != sorted(ordered_paths):
        fail("LuCI finalization lock paths are empty or not sorted")
    return rows, raw


def verify_lock_state(
    root: Path,
    rows: dict[str, dict[str, str]],
    *,
    phase: str,
) -> None:
    prefix = "raw" if phase == "raw" else "final"
    for path, row in rows.items():
        expected = (
            row[f"{prefix}_kind"],
            row[f"{prefix}_mode"],
            row[f"{prefix}_value"],
        )
        actual = node_state(root, path, label=f"{phase} LuCI finalization path")
        if actual != expected:
            fail(
                f"{phase} LuCI finalization state does not match lock: {path} "
                f"(got {actual}, expected {expected})"
            )


def finalize(
    root: Path,
    profile_path: Path,
    local_overlay: Path,
    component_overlay: Path,
    report_path: Path,
    lock_path: Path,
) -> None:
    profile, raw_profile = load_profile(profile_path)
    packages = selected_luci_packages(profile)
    if not packages:
        fail("component profile does not select the complete source-built LuCI set")
    owners = owned_paths(packages)
    locked_changes, raw_lock = load_finalization_lock(lock_path, owners)
    before = {
        path: node_state(root, path, label="raw LuCI-owned path")
        for path in owners
    }
    verify_lock_state(root, locked_changes, phase="raw")
    restored = restore_local_views(root, local_overlay, owners)

    stock_patcher.harden_luci_management_capabilities(root)
    stock_patcher.prune_web_root(root)
    stock_patcher.harden_luci_untrusted_tables(root)
    stock_patcher.repair_luci_firewall_strict_mode(root)
    stock_patcher.harden_luci_status_views(root, rrdns_available=True)
    stock_patcher.harden_luci_logging_and_headers(root)

    removed = reconcile_package_lists(root, packages, owners)
    after = {
        path: node_state(root, path, label="final LuCI-owned path")
        for path in owners
    }
    changed_paths = {path for path in owners if before[path] != after[path]}
    if changed_paths != set(locked_changes):
        missing = sorted(set(locked_changes) - changed_paths)
        unknown = sorted(changed_paths - set(locked_changes))
        details = []
        if missing:
            details.append("locked paths did not change: " + ", ".join(missing))
        if unknown:
            details.append("unknown changed paths: " + ", ".join(unknown))
        fail("LuCI finalization change set is not exact: " + "; ".join(details))
    verify_lock_state(root, locked_changes, phase="final")
    overlay_count = refresh_component_overlay(root, component_overlay, profile)
    final_count, final_digest = final_path_digest(root, owners)
    report = {
        "format": 1,
        "profile_sha256": hashlib.sha256(raw_profile).hexdigest(),
        "patcher_sha256": sha256_file(Path(stock_patcher.__file__).resolve()),
        "finalizer_sha256": sha256_file(Path(__file__).resolve()),
        "finalization_lock_sha256": hashlib.sha256(raw_lock).hexdigest(),
        "finalization_lock_change_count": len(locked_changes),
        "luci_packages": sorted(packages),
        "local_view_overrides": restored,
        "policy_removed_paths": removed,
        "final_luci_path_count": final_count,
        "final_luci_paths_sha256": final_digest,
        "final_component_overlay_path_count": overlay_count,
    }
    data = canonical_json(report)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_bytes(data)
    embedded = checked_path(
        root,
        "/usr/share/sbe-build/luci-finalization.json",
        label="embedded finalization report",
    )
    embedded.parent.mkdir(parents=True, exist_ok=True)
    embedded.write_bytes(data)
    embedded.chmod(0o644)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--local-overlay", type=Path, required=True)
    parser.add_argument("--component-overlay", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--lock", type=Path, required=True)
    args = parser.parse_args()
    try:
        finalize(
            args.root.resolve(),
            args.profile.resolve(),
            args.local_overlay.resolve(),
            args.component_overlay.resolve(),
            args.report.resolve(),
            args.lock.resolve(),
        )
    except (FinalizationError, OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
