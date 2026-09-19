#!/usr/bin/env python3
"""Check rebuilt Lua runtime packages against the final rootfs and LuCI set."""

from __future__ import annotations

import argparse
import io
from pathlib import Path
import re
import tarfile


RUNTIME_PACKAGES = {
    "libiwinfo-lua",
    "libiwinfo20181126",
    "liblua5.1.5",
    "libubus-lua",
    "libuci-lua",
    "lua",
}

LUCI_RUNTIME_EDGES = {
    "luci-base": {"lua", "libubus-lua"},
    "luci-lib-ip": {"liblua5.1.5"},
    "luci-lib-jsonc": {"liblua5.1.5"},
    "luci-lib-nixio": {"liblua5.1.5"},
    "luci-mod-network": {"libiwinfo-lua"},
    "luci-mod-status": {"libiwinfo-lua", "libiwinfo20181126"},
}


def parse_control(text: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    current: str | None = None
    for line in text.splitlines():
        if line[:1].isspace() and current:
            fields[current] += " " + line.strip()
        elif ": " in line:
            current, value = line.split(": ", 1)
            fields[current] = value
        elif not line:
            current = None
    return fields


def read_ipk_control(path: Path) -> dict[str, str]:
    with tarfile.open(path, "r:gz") as outer:
        member = next((m for m in outer.getmembers() if m.name.lstrip("./") == "control.tar.gz"), None)
        if member is None:
            raise RuntimeError(f"{path.name}: control.tar.gz is missing")
        handle = outer.extractfile(member)
        if handle is None:
            raise RuntimeError(f"{path.name}: cannot read control.tar.gz")
        control_archive = handle.read()
    with tarfile.open(fileobj=io.BytesIO(control_archive), mode="r:gz") as controls:
        member = next((m for m in controls.getmembers() if m.name.lstrip("./") == "control"), None)
        if member is None:
            raise RuntimeError(f"{path.name}: control file is missing")
        handle = controls.extractfile(member)
        if handle is None:
            raise RuntimeError(f"{path.name}: cannot read control file")
        return parse_control(handle.read().decode("utf-8"))


def dependency_groups(value: str) -> list[list[str]]:
    groups: list[list[str]] = []
    for group in value.split(","):
        alternatives = []
        for item in group.split("|"):
            name = re.sub(r"\s*\([^)]*\)\s*$", "", item).strip()
            if name:
                alternatives.append(name)
        if alternatives:
            groups.append(alternatives)
    return groups


def dependency_set(record: dict[str, str]) -> set[str]:
    return {name for group in dependency_groups(record.get("Depends", "")) for name in group}


def read_version_lock(path: Path) -> dict[str, tuple[str, str]]:
    """Return package -> (new version, final-rootfs baseline version)."""
    result: dict[str, tuple[str, str]] = {}
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 9:
            raise RuntimeError(f"{path}:{line_number}: expected 9 tab-separated fields")
        package, new_version, baseline_version = fields[2], fields[3], fields[8]
        if package in result:
            raise RuntimeError(f"{path}:{line_number}: duplicate package {package}")
        result[package] = (new_version, baseline_version)
    if set(result) != RUNTIME_PACKAGES:
        raise RuntimeError(f"runtime version lock mismatch: {sorted(result)}")
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--luci-artifacts", type=Path, required=True)
    parser.add_argument("--packages-lock", type=Path, required=True)
    parser.add_argument("--status", type=Path, required=True)
    parser.add_argument("--status-mode", choices=("baseline", "final"), default="baseline")
    parser.add_argument("--opkg-conf", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    version_lock = read_version_lock(args.packages_lock)

    old_records = [parse_control(block) for block in args.status.read_text().split("\n\n") if block.strip()]
    old_by_name = {record["Package"]: record for record in old_records if "Package" in record}
    available = set(old_by_name)
    for record in old_records:
        for provided in dependency_groups(record.get("Provides", "")):
            available.update(provided)

    accepted_arches = {
        line.split()[1]
        for line in args.opkg_conf.read_text().splitlines()
        if line.startswith("arch ") and len(line.split()) == 3
    }
    controls = [read_ipk_control(path) for path in sorted(args.artifacts.glob("*.ipk"))]
    names = {record["Package"] for record in controls}
    if names != RUNTIME_PACKAGES:
        raise RuntimeError(f"runtime package set mismatch: {sorted(names)}")
    available.update(names)

    rows = ["package\told_version\tnew_version\tarchitecture\tdependency_result"]
    for record in sorted(controls, key=lambda item: item["Package"]):
        name = record["Package"]
        if name not in old_by_name:
            raise RuntimeError(f"{name}: package is absent from final rootfs status")
        expected_new, expected_old = version_lock[name]
        if record.get("Version") != expected_new:
            raise RuntimeError(f"{name}: artifact version is not the locked upgrade")
        expected_status = expected_new if args.status_mode == "final" else expected_old
        if old_by_name[name].get("Version") != expected_status:
            raise RuntimeError(f"{name}: rootfs version is not the locked {args.status_mode} version")
        arch = record["Architecture"]
        if arch not in accepted_arches:
            raise RuntimeError(f"{name}: architecture {arch} is not accepted by final opkg.conf")
        missing = [
            "|".join(group)
            for group in dependency_groups(record.get("Depends", ""))
            if not any(candidate in available for candidate in group)
        ]
        if missing:
            raise RuntimeError(f"{name}: unsatisfied dependencies: {', '.join(missing)}")
        rows.append(
            "\t".join(
                (
                    name,
                    old_by_name[name].get("Version", ""),
                    record.get("Version", ""),
                    arch,
                    "locked-security-upgrade" if expected_new != expected_old else "satisfied",
                )
            )
        )

    luci_controls = {
        record["Package"]: record
        for record in (read_ipk_control(path) for path in sorted(args.luci_artifacts.glob("*.ipk")))
    }
    if len(luci_controls) != 20:
        raise RuntimeError(f"expected 20 source-built LuCI controls, got {len(luci_controls)}")
    rows.append("consumer\trequired_runtime_packages\tresult\t")
    for consumer, required in sorted(LUCI_RUNTIME_EDGES.items()):
        if consumer not in luci_controls:
            raise RuntimeError(f"source-built LuCI package is missing: {consumer}")
        actual = dependency_set(luci_controls[consumer])
        missing = required - actual
        if missing:
            raise RuntimeError(f"{consumer}: missing runtime edges: {sorted(missing)}")
        rows.append(f"{consumer}\t{','.join(sorted(required))}\twired\t")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(rows) + "\n")
    print("PASS: 6 runtime packages fit the final rootfs and satisfy every source-built LuCI runtime edge")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
