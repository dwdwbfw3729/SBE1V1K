#!/usr/bin/env python3
"""Apply a hash-locked RAM-only component profile to an extracted rootfs.

Candidate packages are intentionally built under isolated names and paths.
This tool is the single promotion boundary: it validates every archive before
copying data, performs explicit path promotions/removals, and rewrites opkg
metadata to the canonical package names actually present in the image.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import stat
import tarfile
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any


PROFILE_FORMAT = 1
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
PACKAGE_NAME = re.compile(r"^[a-z0-9][a-z0-9+._-]{0,127}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
ARCHITECTURE = "aarch64_cortex-a73_neon-vfpv4"
ALLOWED_RELEASE_STATES = {"production"}
MAX_ARTIFACT_SIZE = 128 * 1024 * 1024
MAX_UNPACKED_SIZE = 256 * 1024 * 1024


class ProfileError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise ProfileError(message)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()


def relative_path(
    value: str, *, field: str, allow_leading_slash: bool = True
) -> PurePosixPath:
    if not isinstance(value, str) or not value or "\x00" in value or "\n" in value:
        fail(f"{field} is not a safe path")
    if value.startswith("/") and not allow_leading_slash:
        fail(f"{field} must not be absolute: {value!r}")
    stripped = value[1:] if value.startswith("/") else value
    candidate = PurePosixPath(stripped)
    if (
        candidate.is_absolute()
        or not candidate.parts
        or str(candidate) != stripped
        or any(part in ("", ".", "..") for part in candidate.parts)
    ):
        fail(f"{field} is not a normalized root-relative path: {value!r}")
    return candidate


def checked_path(root: Path, value: str, *, field: str, allow_target_symlink: bool = True) -> Path:
    relative = relative_path(value, field=field)
    target = root.joinpath(*relative.parts)
    parent = root
    for part in relative.parts[:-1]:
        parent = parent / part
        if parent.is_symlink():
            fail(f"{field} traverses a symlink: {value!r}")
    if not allow_target_symlink and target.is_symlink():
        fail(f"{field} names a symlink: {value!r}")
    return target


def remove_node(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def prepare_target(path: Path, *, directory: bool) -> None:
    if path.is_symlink():
        path.unlink()
    elif path.exists() and directory and not path.is_dir():
        path.unlink()
    elif path.exists() and not directory:
        if path.is_dir():
            fail(f"refusing to replace directory with file: {path}")
        path.unlink()


def extract_data_tar(ipk: Path, staging: Path) -> list[str]:
    try:
        with tarfile.open(ipk, mode="r:*") as outer:
            candidates = [
                member
                for member in outer.getmembers()
                if member.name in {
                    "data.tar",
                    "./data.tar",
                    "data.tar.gz",
                    "./data.tar.gz",
                    "data.tar.xz",
                    "./data.tar.xz",
                }
            ]
            if len(candidates) != 1 or not candidates[0].isfile():
                fail(f"{ipk.name}: expected exactly one regular data.tar payload")
            if candidates[0].size > MAX_ARTIFACT_SIZE:
                fail(f"{ipk.name}: compressed data payload exceeds the size limit")
            payload_stream = outer.extractfile(candidates[0])
            if payload_stream is None:
                fail(f"{ipk.name}: cannot read data payload")
            payload = payload_stream.read()
    except (tarfile.TarError, OSError) as error:
        fail(f"{ipk.name}: invalid IPK container: {error}")

    installed: list[str] = []
    try:
        with tarfile.open(fileobj=io.BytesIO(payload), mode="r:*") as archive:
            members = archive.getmembers()
            total_size = sum(member.size for member in members if member.isfile())
            if total_size > MAX_UNPACKED_SIZE:
                fail(f"{ipk.name}: unpacked data payload exceeds the size limit")
            member_types: dict[str, str] = {}
            for member in members:
                raw_name = member.name
                if raw_name in ("", ".", "./"):
                    continue
                while raw_name.startswith("./"):
                    raw_name = raw_name[2:]
                if raw_name in ("", "."):
                    continue
                relative = relative_path(
                    raw_name,
                    field=f"{ipk.name} member",
                    allow_leading_slash=False,
                )
                normalized_name = str(relative)
                member_type = (
                    "directory"
                    if member.isdir()
                    else "file"
                    if member.isfile()
                    else "symlink"
                    if member.issym()
                    else "unsupported"
                )
                prior_type = member_types.get(normalized_name)
                if prior_type is not None and not (
                    prior_type == "directory" and member_type == "directory"
                ):
                    fail(
                        f"{ipk.name}: archive member is declared more than once "
                        f"or changes type: {raw_name}"
                    )
                member_types[normalized_name] = member_type
                destination = staging.joinpath(*relative.parts)
                checked_path(staging, str(relative), field=f"{ipk.name} member")

                if member.mode & (stat.S_ISUID | stat.S_ISGID):
                    fail(f"{ipk.name}: setuid/setgid archive member is forbidden: {raw_name}")
                if member.isdir():
                    # Never let mkdir/chmod follow a symlink created by an
                    # earlier archive member at the same pathname.
                    prepare_target(destination, directory=True)
                    destination.mkdir(parents=True, exist_ok=True)
                    os.chmod(destination, member.mode & 0o777)
                    continue

                destination.parent.mkdir(parents=True, exist_ok=True)
                checked_path(staging, str(relative), field=f"{ipk.name} member")
                if member.isfile():
                    source = archive.extractfile(member)
                    if source is None:
                        fail(f"{ipk.name}: cannot read regular member: {raw_name}")
                    prepare_target(destination, directory=False)
                    with destination.open("xb") as output:
                        shutil.copyfileobj(source, output)
                    os.chmod(destination, member.mode & 0o777)
                elif member.issym():
                    if "\x00" in member.linkname or "\n" in member.linkname or not member.linkname:
                        fail(f"{ipk.name}: unsafe symlink target: {raw_name}")
                    # Absolute links are rooted inside the target image.  A
                    # relative link may move upward, but never above image /.
                    target_parts: list[str] = [] if member.linkname.startswith("/") else list(relative.parent.parts)
                    for part in PurePosixPath(member.linkname).parts:
                        if part in ("", ".", "/"):
                            continue
                        if part == "..":
                            if not target_parts:
                                fail(f"{ipk.name}: symlink escapes image root: {raw_name}")
                            target_parts.pop()
                        else:
                            target_parts.append(part)
                    prepare_target(destination, directory=False)
                    os.symlink(member.linkname, destination)
                else:
                    fail(f"{ipk.name}: unsupported archive member type: {raw_name}")
                installed.append("/" + str(relative))
    except (tarfile.TarError, OSError) as error:
        fail(f"{ipk.name}: invalid data payload: {error}")
    return sorted(installed)


def ensure_safe_destination_parent(destination: Path, destination_root: Path) -> None:
    """Create destination parents without ever following a staged symlink.

    Each individual IPK is unpacked into a fresh tree, but candidates are then
    merged.  Without checking the merged destination at every step, one
    artifact could contribute a directory-position symlink and a later one
    could write through it.  The artifacts are hash locked, nevertheless the
    promotion boundary must reject this topology before it can touch either a
    host path or an unexpected rootfs path.
    """

    if destination_root.is_symlink() or not destination_root.is_dir():
        fail(f"copy destination root is missing or unsafe: {destination_root}")
    try:
        relative = destination.relative_to(destination_root)
    except ValueError:
        fail(f"copy destination escapes its root: {destination}")
    current = destination_root
    for part in relative.parts[:-1]:
        current = current / part
        if current.is_symlink():
            fail(f"copy destination traverses a symlink: {destination}")
        if current.exists():
            if not current.is_dir():
                fail(f"copy destination parent is not a directory: {destination}")
        else:
            current.mkdir()


def copy_tree(source: Path, destination: Path, *, destination_root: Path) -> None:
    ensure_safe_destination_parent(destination, destination_root)
    if source.is_symlink():
        prepare_target(destination, directory=False)
        os.symlink(os.readlink(source), destination)
        return
    if source.is_dir():
        if destination.is_symlink():
            fail(f"refusing to replace a destination symlink with a directory: {destination}")
        prepare_target(destination, directory=True)
        destination.mkdir(parents=True, exist_ok=True)
        for child in sorted(source.iterdir(), key=lambda item: item.name):
            copy_tree(
                child,
                destination / child.name,
                destination_root=destination_root,
            )
        os.chmod(destination, stat.S_IMODE(source.stat().st_mode))
        return
    if source.is_file():
        prepare_target(destination, directory=False)
        shutil.copyfile(source, destination, follow_symlinks=False)
        os.chmod(destination, stat.S_IMODE(source.stat().st_mode))
        return
    fail(f"unsupported staged filesystem node: {source}")


def validate_artifact_path(lab: Path, value: str) -> Path:
    relative = relative_path(value, field="artifact path", allow_leading_slash=False)
    path = lab.joinpath(*relative.parts)
    parent = lab
    for part in relative.parts[:-1]:
        parent = parent / part
        if parent.is_symlink():
            fail(f"artifact path traverses a symlink: {value!r}")
    if path.is_symlink() or not path.is_file():
        fail(f"artifact is missing or not a regular file: {value!r}")
    if path.stat().st_size > MAX_ARTIFACT_SIZE:
        fail(f"artifact exceeds the size limit: {value!r}")
    return path


def parse_status(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    paragraphs: list[dict[str, str]] = []
    for paragraph in path.read_text(encoding="utf-8").split("\n\n"):
        fields: dict[str, str] = {}
        current = ""
        for line in paragraph.splitlines():
            if line.startswith((" ", "\t")) and current:
                fields[current] += "\n" + line
                continue
            key, separator, value = line.partition(":")
            if separator:
                if value.startswith(" "):
                    value = value[1:]
                fields[key] = value
                current = key
        if fields.get("Package"):
            paragraphs.append(fields)
    return paragraphs


def render_control(package: dict[str, Any]) -> str:
    lines = [
        f"Package: {package['name']}",
        f"Version: {package['version']}",
        f"Architecture: {package.get('architecture', ARCHITECTURE)}",
    ]
    if package.get("depends"):
        lines.append("Depends: " + ", ".join(package["depends"]))
    if package.get("provides"):
        lines.append("Provides: " + ", ".join(package["provides"]))
    if package.get("essential", False):
        lines.append("Essential: yes")
    lines.extend(
        [
            f"Source: {package['source']}",
            f"Source-Revision: {package['source_revision']}",
            f"Description: {package['description']}",
        ]
    )
    return "\n".join(lines) + "\n"


def rewrite_package_database(root: Path, packages: list[dict[str, Any]]) -> None:
    info = checked_path(root, "/usr/lib/opkg/info", field="opkg info")
    status_path = checked_path(root, "/usr/lib/opkg/status", field="opkg status")
    info.mkdir(parents=True, exist_ok=True)
    status_path.parent.mkdir(parents=True, exist_ok=True)

    replaced: set[str] = set()
    ownership: dict[str, str] = {}
    for package in packages:
        allowed_keys = {
            "name",
            "version",
            "architecture",
            "depends",
            "provides",
            "essential",
            "metadata_only",
            "source",
            "source_revision",
            "description",
            "replaces",
            "candidate_paths",
            "retained_paths",
        }
        if not isinstance(package, dict) or set(package) - allowed_keys:
            fail("candidate package has an invalid schema")
        name = package.get("name")
        if not isinstance(name, str) or not PACKAGE_NAME.fullmatch(name):
            fail(f"invalid canonical package name: {name!r}")
        version = package.get("version")
        if not isinstance(version, str) or not version or "\n" in version:
            fail(f"invalid version for {name}")
        architecture = package.get("architecture", ARCHITECTURE)
        if architecture not in {ARCHITECTURE, "all"}:
            fail(f"invalid architecture for {name}: {architecture!r}")
        if "essential" in package and not isinstance(package["essential"], bool):
            fail(f"invalid Essential value for {name}")
        metadata_only = package.get("metadata_only", False)
        if not isinstance(metadata_only, bool):
            fail(f"invalid metadata-only value for {name}")
        revision = package.get("source_revision")
        if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40,64}", revision):
            fail(f"invalid source revision for {name}")
        source = package.get("source")
        if not isinstance(source, str) or not source.startswith("https://") or "\n" in source:
            fail(f"invalid source URL for {name}")
        description = package.get("description")
        if not isinstance(description, str) or not description.strip() or "\n" in description:
            fail(f"invalid description for {name}")
        dependencies = package.get("depends", [])
        provided_names = package.get("provides", [])
        package_replaces = package.get("replaces", [])
        for label, values in (
            ("dependencies", dependencies),
            ("provides", provided_names),
            ("replaces", package_replaces),
        ):
            if not isinstance(values, list):
                fail(f"invalid {label} list for {name}")
            if any(not isinstance(value, str) for value in values):
                fail(f"non-string value in {label} list for {name}")
            if len(values) != len(set(values)):
                fail(f"duplicate value in {label} list for {name}")
        for dependency in dependencies:
            if not isinstance(dependency, str) or not PACKAGE_NAME.fullmatch(dependency):
                fail(f"invalid dependency for {name}: {dependency!r}")
        for provided in provided_names:
            if not isinstance(provided, str) or not PACKAGE_NAME.fullmatch(provided):
                fail(f"invalid provide for {name}: {provided!r}")
        if name not in package_replaces:
            fail(f"{name} must replace its own prior record")
        for old in package_replaces:
            if not isinstance(old, str) or not PACKAGE_NAME.fullmatch(old):
                fail(f"invalid replaced package for {name}: {old!r}")
            if old in replaced:
                fail(f"two candidates replace the same package: {old}")
            replaced.add(old)
        candidate_paths = package.get("candidate_paths", [])
        retained_paths = package.get("retained_paths", [])
        if not isinstance(candidate_paths, list):
            fail(f"{name} has an invalid candidate path list")
        if not isinstance(retained_paths, list):
            fail(f"{name} has an invalid retained path list")
        if metadata_only:
            if candidate_paths or retained_paths or package.get("essential", False):
                fail(f"metadata-only package {name} must not own files or be Essential")
        elif not candidate_paths:
            fail(f"{name} must declare at least one candidate path")
        package_paths: set[str] = set()
        for owned in candidate_paths + retained_paths:
            relative = relative_path(owned, field=f"package path for {name}")
            normalized = "/" + str(relative)
            if normalized in package_paths:
                fail(f"package {name} declares the same path more than once: {normalized}")
            package_paths.add(normalized)
            prior = ownership.get(normalized)
            if prior is not None:
                fail(f"duplicate candidate ownership for {normalized}: {prior}, {name}")
            ownership[normalized] = name
            actual = checked_path(root, normalized, field=f"package path for {name}")
            if not (actual.exists() or actual.is_symlink()) or actual.is_dir():
                fail(f"package path for {name} is missing or not a file: {normalized}")

    retained = [record for record in parse_status(status_path) if record["Package"] not in replaced]
    available = {record["Package"] for record in retained}
    for record in retained:
        for provided in record.get("Provides", "").split(","):
            provided_name = provided.strip().split(" ", 1)[0]
            if provided_name:
                available.add(provided_name)
    for package in packages:
        available.add(package["name"])
        available.update(package.get("provides", []))
    for package in packages:
        missing = sorted(set(package.get("depends", [])) - available)
        if missing:
            fail(
                f"canonical package {package['name']} has unresolved dependencies: "
                + ", ".join(missing)
            )
    for old in sorted(replaced):
        for metadata in info.glob(old + ".*"):
            if metadata.is_symlink() or metadata.is_file():
                metadata.unlink()
            elif metadata.is_dir():
                fail(f"unexpected opkg metadata directory: {metadata}")

    rendered: list[str] = []
    for record in retained:
        rendered.append(
            "\n".join(
                f"{key}:{value}"
                if value.startswith("\n")
                else f"{key}: {value}"
                if value
                else f"{key}:"
                for key, value in record.items()
            )
        )

    for package in packages:
        name = package["name"]
        control = render_control(package)
        (info / f"{name}.control").write_text(control, encoding="utf-8")
        package_paths = sorted(
            "/" + str(relative_path(path, field=f"package path for {name}"))
            for path in set(
                package.get("candidate_paths", []) + package.get("retained_paths", [])
            )
        )
        (info / f"{name}.list").write_text(
            "".join(path + "\n" for path in package_paths), encoding="utf-8"
        )
        status_control = control.rstrip("\n")
        rendered.append(status_control + "\nStatus: install ok installed\nAuto-Installed: yes")

    status_path.write_text("\n\n".join(rendered) + "\n\n", encoding="utf-8")


def validate_top_level(profile: dict[str, Any], requested_name: str) -> None:
    allowed = {"format", "name", "release_state", "artifacts", "operations", "packages"}
    unknown = set(profile) - allowed
    if unknown:
        fail("unknown profile keys: " + ", ".join(sorted(unknown)))
    if profile.get("format") != PROFILE_FORMAT:
        fail("unsupported component profile format")
    if profile.get("name") != requested_name or not PROFILE_NAME.fullmatch(requested_name):
        fail("component profile name does not match the requested name")
    if profile.get("release_state") not in ALLOWED_RELEASE_STATES:
        fail("component profile is not marked for production")
    for field in ("artifacts", "operations", "packages"):
        if not isinstance(profile.get(field), list):
            fail(f"component profile {field} must be a list")


def normalized_root_path(value: str, *, field: str) -> str:
    return "/" + str(relative_path(value, field=field))


def path_removed(path: str, removals: list[str]) -> bool:
    return any(path == removal or path.startswith(removal.rstrip("/") + "/") for removal in removals)


def apply_profile(
    root: Path,
    lab: Path,
    profile_path: Path,
    requested_name: str,
    report_path: Path,
    overlay_output: Path,
) -> None:
    try:
        raw_profile = profile_path.read_bytes()
        profile = json.loads(raw_profile)
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read component profile: {error}")
    if not isinstance(profile, dict):
        fail("component profile must be a JSON object")
    validate_top_level(profile, requested_name)

    artifact_report: list[dict[str, Any]] = []
    artifact_payload_owners: dict[str, str] = {}
    artifact_components: set[str] = set()
    with tempfile.TemporaryDirectory(prefix="sbe-components-") as temporary:
        combined = Path(temporary) / "combined"
        combined.mkdir()
        for index, artifact in enumerate(profile["artifacts"]):
            if not isinstance(artifact, dict):
                fail(f"artifact {index} has an invalid schema")
            component = artifact.get("component")
            if not isinstance(component, str) or not PROFILE_NAME.fullmatch(component):
                fail(f"artifact {index} has an invalid component name")
            if component in artifact_components:
                fail(f"component artifact is declared more than once: {component}")
            artifact_components.add(component)
            artifact_format = artifact.get("format")
            if artifact_format == "ipk":
                expected_keys = {"component", "format", "path", "sha256"}
            elif artifact_format == "raw":
                expected_keys = {
                    "component",
                    "format",
                    "path",
                    "sha256",
                    "staging_path",
                    "mode",
                }
            else:
                fail(f"artifact {component}: format must be ipk or raw")
            if set(artifact) != expected_keys:
                fail(f"artifact {component} has an invalid schema")
            expected = artifact["sha256"]
            if not isinstance(expected, str) or not SHA256.fullmatch(expected):
                fail(f"artifact {component}: invalid SHA-256")
            path = validate_artifact_path(lab, artifact["path"])
            actual = sha256_file(path)
            if actual != expected:
                fail(f"artifact {component}: SHA-256 mismatch")
            staging = Path(temporary) / f"artifact-{index}"
            staging.mkdir()
            if artifact_format == "ipk":
                files = extract_data_tar(path, staging)
            else:
                staging_relative = relative_path(
                    artifact["staging_path"], field=f"artifact {component} staging path"
                )
                try:
                    raw_mode = int(artifact["mode"], 8)
                except (TypeError, ValueError):
                    fail(f"artifact {component}: invalid raw mode")
                if raw_mode < 0 or raw_mode > 0o777:
                    fail(f"artifact {component}: raw mode is outside 0000..0777")
                staged_file = staging.joinpath(*staging_relative.parts)
                staged_file.parent.mkdir(parents=True)
                shutil.copyfile(path, staged_file)
                os.chmod(staged_file, raw_mode)
                files = ["/" + str(staging_relative)]
            for payload_path in files:
                prior = artifact_payload_owners.get(payload_path)
                if prior is not None:
                    fail(
                        f"candidate artifacts overlap at {payload_path}: "
                        f"{prior}, {component}"
                    )
                artifact_payload_owners[payload_path] = component
            copy_tree(staging, combined, destination_root=combined)
            artifact_report.append(
                {
                    "component": component,
                    "path": artifact["path"],
                    "sha256": actual,
                    "payload_files": files,
                }
            )
        copy_tree(combined, root, destination_root=root)

    promotion_destinations: set[str] = set()
    removal_paths: list[str] = []
    candidate_payload_paths = set(artifact_payload_owners)
    for index, operation in enumerate(profile["operations"]):
        if not isinstance(operation, dict):
            fail(f"operation {index} is not an object")
        op = operation.get("op")
        if op == "promote":
            if set(operation) != {"op", "source", "destination", "mode"}:
                fail(f"promotion {index} has an invalid schema")
            source = checked_path(root, operation["source"], field="promotion source", allow_target_symlink=False)
            destination = checked_path(root, operation["destination"], field="promotion destination")
            source_name = normalized_root_path(operation["source"], field="promotion source")
            destination_name = normalized_root_path(
                operation["destination"], field="promotion destination"
            )
            if source_name not in candidate_payload_paths:
                fail(f"promotion source is not supplied by a candidate artifact: {source_name}")
            if source_name == destination_name:
                fail(f"promotion source and destination are identical: {source_name}")
            if destination_name in promotion_destinations:
                fail(f"two promotions target the same path: {destination_name}")
            promotion_destinations.add(destination_name)
            if not source.is_file():
                fail(f"promotion source is not a regular file: {operation['source']}")
            try:
                mode = int(operation["mode"], 8)
            except (TypeError, ValueError):
                fail(f"promotion {index} has an invalid mode")
            if mode < 0 or mode > 0o777:
                fail(f"promotion {index} mode is outside 0000..0777")
            destination.parent.mkdir(parents=True, exist_ok=True)
            prepare_target(destination, directory=False)
            shutil.copyfile(source, destination)
            os.chmod(destination, mode)
        elif op == "remove":
            if set(operation) != {"op", "path"}:
                fail(f"removal {index} has an invalid schema")
            target = checked_path(root, operation["path"], field="removal path")
            removal = normalized_root_path(operation["path"], field="removal path")
            if len(relative_path(removal, field="removal path").parts) < 2:
                fail("profile removal must not target a top-level rootfs entry")
            removal_paths.append(removal)
            remove_node(target)
        else:
            fail(f"operation {index} has unsupported op: {op!r}")

    expected_owned_paths = {
        path for path in candidate_payload_paths if not path_removed(path, removal_paths)
    }
    expected_owned_paths.update(promotion_destinations)
    declared_owned_paths: set[str] = set()
    for package in profile["packages"]:
        for path in package.get("candidate_paths", []):
            normalized = normalized_root_path(
                path, field=f"candidate path for {package.get('name', 'unknown')}"
            )
            if normalized in declared_owned_paths:
                fail(f"candidate path is declared more than once: {normalized}")
            declared_owned_paths.add(normalized)
    if expected_owned_paths != declared_owned_paths:
        undeclared = sorted(expected_owned_paths - declared_owned_paths)
        unsupported = sorted(declared_owned_paths - expected_owned_paths)
        details = []
        if undeclared:
            details.append("undeclared payload: " + ", ".join(undeclared))
        if unsupported:
            details.append("candidate path has no candidate payload: " + ", ".join(unsupported))
        fail("candidate ownership is incomplete: " + "; ".join(details))

    if profile["packages"]:
        rewrite_package_database(root, profile["packages"])

    if overlay_output == root or root in overlay_output.parents:
        fail("component overlay output must be outside the target rootfs")
    remove_node(overlay_output)
    overlay_output.mkdir(parents=True)
    for owned in sorted(declared_owned_paths):
        source = checked_path(root, owned, field="component overlay source")
        destination = checked_path(
            overlay_output, owned, field="component overlay destination"
        )
        copy_tree(source, destination, destination_root=overlay_output)

    report = {
        "format": PROFILE_FORMAT,
        "name": requested_name,
        "release_state": profile["release_state"],
        "profile_sha256": hashlib.sha256(raw_profile).hexdigest(),
        "applicator_sha256": sha256_file(Path(__file__).resolve()),
        "artifacts": artifact_report,
        "packages": [
            {"name": package["name"], "version": package["version"]}
            for package in profile["packages"]
        ],
    }
    report_data = canonical_json(report)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_bytes(report_data)
    runtime_report = checked_path(root, "/usr/share/sbe-build/component-profile.json", field="runtime report")
    runtime_report.parent.mkdir(parents=True, exist_ok=True)
    runtime_report.write_bytes(report_data)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--lab", type=Path, required=True)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--overlay-output", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        apply_profile(
            arguments.root.resolve(),
            arguments.lab.resolve(),
            arguments.profile.resolve(),
            arguments.name,
            arguments.report.resolve(),
            arguments.overlay_output.resolve(),
        )
    except ProfileError as error:
        print(f"ERROR: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
