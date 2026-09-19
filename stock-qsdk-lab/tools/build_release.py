#!/usr/bin/env python3
"""Build a stock-based release, without flashing devices or rewriting source locks."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import datetime
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

from init_dependencies import LAB, dependencies


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def local(relative):
    path = LAB / relative
    if Path(relative).is_absolute() or ".." in Path(relative).parts or not path.resolve().is_relative_to(LAB.resolve()):
        raise ValueError(f"path escapes stock build directory: {relative}")
    return path


def artifact_contracts():
    """Return build inputs and optional byte locks.

    Immutable vendor inputs, approved rootfs promotions and kernel modules
    retain byte locks.  IPKs that only enter the compatible feed are selected
    by its manifest and validated as packages; their final hashes are generated
    in the release instead of being duplicated in another source file.
    """
    artifacts = {}

    def add(path, digest=None):
        local(path)
        if digest is not None and not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError(f"invalid artifact hash: {path}")
        if path in artifacts and artifacts[path] != digest:
            if artifacts[path] is None:
                artifacts[path] = digest
                return
            if digest is None:
                return
            raise ValueError(f"conflicting artifact contracts: {path}")
        artifacts[path] = digest
    profile = json.loads((LAB / "component-profiles/production.json").read_text())
    for item in profile["artifacts"]:
        add(item["path"], item["sha256"])
    with (LAB / "feed/native-feed-inputs.tsv").open() as stream:
        for line in stream:
            fields = line.rstrip("\n").split("\t")
            if not fields or fields[0].startswith("#"):
                continue
            if len(fields) != 4:
                raise ValueError("invalid native feed input row")
            if fields[2] == "copy":
                add(fields[3])
    # Reuse the existing extension packager's independent artifact lock.
    spec = importlib.util.spec_from_file_location("xtables", LAB / "feed/package_passwall_bundle.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    for name, digest in module.EXPECTED.items():
        add("passwall-build-v2/out/netfilter-candidates/xtables/" + name, digest)
    kernel = json.loads((LAB / "sources/kernel-support-1.5.3.json").read_text())
    for name, record in kernel["modules"].items():
        add("qsdk-build/out/kernel-support-1.5.3/" + name, record["sha256"])
    return artifacts


def stage_plan():
    catalog = json.loads((LAB / "sources/build-stages.json").read_text())
    if catalog["format"] != 1:
        raise ValueError("unsupported build-stage catalog")
    stages = catalog["stages"]
    if len({s["name"] for s in stages}) != len(stages):
        raise ValueError("duplicate build stage")
    for stage in stages:
        stage["artifacts"] = {}
    for path, digest in artifact_contracts().items():
        owners = [s for s in stages if any(path.startswith(p) for p in s["input_prefixes"])]
        if len(owners) != 1:
            raise ValueError(f"artifact needs exactly one build recipe: {path}")
        owners[0]["artifacts"][path] = digest
    for stage in stages:
        if not stage["artifacts"]:
            raise ValueError(f"empty build stage: {stage['name']}")
        for directory in stage.get("artifact_directories", []):
            local(directory)
    return stages


def missing(stage):
    return [path for path, digest in stage["artifacts"].items()
            if not local(path).is_file() or
            (digest is not None and sha256(local(path)) != digest)]


def stage_artifacts(stage):
    """Validate outputs and promote only byte-locked artifacts when needed.

    No workspace-wide search, newest-file selection, or automatic lock update.
    Manifest-only feed outputs are produced at their declared paths by their
    recipe. Mismatched locked inputs are preserved for investigation.
    """
    by_digest = {}
    for directory in stage.get("artifact_directories", []):
        for path in sorted(local(directory).glob("*.ipk")):
            if path.is_symlink():
                raise ValueError(f"unexpected symlink in build output: {path}")
            by_digest[sha256(path)] = path
    for relative in missing(stage):
        target = local(relative)
        if target.exists():
            raise ValueError(f"refusing to replace mismatched artifact: {relative}")
        digest = stage["artifacts"][relative]
        source = by_digest.get(digest) if digest is not None else None
        if source:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
    # Rebuilds also authenticate fresh outputs when an older good cache exists.
    if stage.get("artifact_directories"):
        for relative, digest in stage["artifacts"].items():
            if digest is not None and digest not in by_digest:
                raise ValueError(f"fresh {stage['name']} output differs from lock: {relative}")
    if missing(stage):
        raise ValueError(f"{stage['name']}: output did not satisfy its artifact contracts: " + ", ".join(missing(stage)))


def download(url, target, expected):
    target = Path(target)
    if target.is_file():
        if sha256(target) != expected:
            raise ValueError(f"cached download differs from lock: {target.name}; preserved")
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix=".download-", dir=target.parent, delete=False) as stream:
        temporary = Path(stream.name)
    try:
        subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--connect-timeout", "20",
                        "--output", str(temporary), url], check=True)
        if sha256(temporary) != expected:
            raise ValueError(f"download SHA-256 mismatch: {target.name}")
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)


@contextmanager
def exclusive(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ValueError("another stock firmware build is already running") from exc
        yield


class Build:
    def __init__(self, args):
        self.args = args
        self.qsdk = args.qsdk_source_root.resolve()
        self.env = dict(os.environ, QSDK_SOURCE_ROOT=str(self.qsdk),
                        QSDK_TOP=str(self.qsdk / "qsdk"), QSDK_JOBS=str(args.jobs),
                        PYTHONDONTWRITEBYTECODE="1")
        self.logdir = LAB / "work/build-logs" / datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        self.logdir.mkdir(parents=True, exist_ok=False)
        self.records = []

    def run(self, name, command):
        print(f"[{name}] {shlex.join(map(str, command))}", flush=True)
        log = self.logdir / (name + ".log")
        with log.open("wb") as stream:
            result = subprocess.run(list(map(str, command)), env=self.env, cwd=LAB, stdout=stream, stderr=subprocess.STDOUT)
        self.records.append({"stage": name, "exit_code": result.returncode,
                             "log": str(log.relative_to(LAB))})
        (self.logdir / "stages.json").write_text(json.dumps(self.records, indent=2) + "\n")
        if result.returncode:
            print("\n".join(log.read_text(errors="replace").splitlines()[-40:]), file=sys.stderr)
            raise ValueError(f"stage {name} failed; log: {log}")
        print(f"[{name}] PASS (log: {log.relative_to(LAB)})", flush=True)

    def vendor(self):
        lock = json.loads((LAB / "sources/stock-1.5.3.json").read_text())
        target = LAB / "cache/stock-1.5.3" / lock["filename"]
        if self.args.vendor_simg:
            source = self.args.vendor_simg.resolve()
            if sha256(source) != lock["sha256"] or source.stat().st_size != lock["size"]:
                raise ValueError("vendor image differs from versioned source lock")
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists() and sha256(target) != lock["sha256"]:
                raise ValueError("cached vendor image differs; preserved")
            if not target.exists():
                shutil.copyfile(source, target)
        download(lock["url"], target, lock["sha256"])
        self.run("vendor-source", [sys.executable, LAB / "tools/prepare_stock_source.py",
                 "--lock", LAB / "sources/stock-1.5.3.json", "--source", target, "--outdir", target.parent])
        return target

    def builder(self):
        image = self.args.builder_image
        if not image:
            image = "sbe1v1k-qsdk-builder:ubuntu-22.04-arm64"
            self.run("builder-image", ["docker", "build", "--platform", "linux/arm64", "-t", image,
                      "-f", LAB / "qsdk-build/Dockerfile.ubuntu22.04", LAB / "qsdk-build"])
        identity = subprocess.check_output(["docker", "image", "inspect", "--format", "{{.Id}}", image], text=True).strip()
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", identity):
            raise ValueError("invalid Docker builder identity")
        self.env.update(SBE_BUILDER_IMAGE=image, SBE_BUILDER_IMAGE_ID=identity,
                        QSDK_BUILD_IMAGE=image, BUILDER_IMAGE=image)
        for prefix in ("BUSYBOX", "LOGD", "PROCD_BOARD", "CGI_IO", "LUCIHTTP", "UBUS_SECURITY",
                       "CORE_USERLAND", "USERLAND", "RRDNS", "DIAGNOSTICS", "UCI_SECURITY"):
            self.env[prefix + "_BUILDER_IMAGE"] = image
        self.env["TLS_CURL_BUILD_IMAGE"] = image
        (self.logdir / "builder.json").write_text(json.dumps({"image": image, "id": identity,
            "dockerfile_sha256": sha256(LAB / "qsdk-build/Dockerfile.ubuntu22.04"),
            "origin": "user-supplied-image" if self.args.builder_image else "built-from-repository"}, indent=2) + "\n")

    def main(self, stages):
        if not (self.args.stage or self.args.components_only) and self.args.output.exists():
            raise ValueError(f"output already exists; choose a new --output directory: {self.args.output}")
        for stage in stages:
            for relative in missing(stage):
                if local(relative).exists():
                    raise ValueError(f"mismatched existing artifact preserved: {relative}")
        need_build = [s for s in stages if missing(s) or self.args.rebuild]
        if need_build and not self.args.assemble_only and (os.uname().sysname, os.uname().machine) != ("Darwin", "arm64"):
            raise ValueError("component builders currently require macOS/arm64; Linux containers perform cross compilation")
        for program in ("docker", "git", "curl"):
            if not shutil.which(program):
                raise ValueError(f"required host program is missing: {program}")
        vendor = self.vendor()
        if not self.args.assemble_only:
            self.run("sources", [sys.executable, LAB / "tools/init_dependencies.py",
                     "--qsdk-source-root", self.qsdk])
            self.run("service-inputs", [sys.executable, LAB / "tools/prepare-component-sources.py",
                     "--services-only", "--qsdk-source-root", self.qsdk])
            if need_build or not (LAB / "firmware-tools/out/fwtool").is_file():
                self.builder()
            if need_build:
                self.run("build-environment", ["bash", LAB / "tools/prepare-build-environment.sh"])
            self.run("seed-packages", ["sh", LAB / "tools/prepare_packages.sh"])
            for stage in stages:
                if stage in need_build:
                    command = [p.format(lab=LAB, qsdk=self.qsdk) for p in stage["command"]]
                    self.run(stage["name"], command)
                    stage_artifacts(stage)
                else:
                    print(f"[{stage['name']}] artifact cache verified", flush=True)
        else:
            if need_build:
                raise ValueError("--assemble-only requires all declared inputs; missing: " + ", ".join(s["name"] for s in need_build))
            if not (LAB / "firmware-tools/out/fwtool").is_file():
                self.builder()
        # Do not let a partial component run masquerade as a firmware release.
        if self.args.stage or self.args.components_only:
            return
        from build_1_5_3 import check_local_inputs
        check_local_inputs()
        output = self.args.output.resolve()
        command = [sys.executable, LAB / "tools/build_1_5_3.py", "--vendor-simg", vendor, "--output", output]
        if self.args.profile == "production":
            command.append("--with-passwall")
        if self.args.initramfs:
            command += ["--initramfs", self.args.initramfs.resolve(), "--initramfs-sums", self.args.initramfs_sums.resolve()]
        self.run("images", command)
        shutil.copyfile(self.logdir / "stages.json", output / "build-stages.json")
        print(f"Release files: {output / 'release'}\nNo router was accessed or flashed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--profile", choices=("production", "base"), default="base",
                        help="production preinstalls the verified PassWall suite")
    parser.add_argument("--qsdk-source-root", type=Path, default=Path(os.environ.get("QSDK_SOURCE_ROOT", LAB / "deps/qsdk-spf12.2-locked")))
    parser.add_argument("--vendor-simg", type=Path)
    parser.add_argument("--initramfs", type=Path)
    parser.add_argument("--initramfs-sums", type=Path)
    parser.add_argument("--builder-image", help="explicitly reuse an existing builder; actual ID is recorded")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--rebuild", action="store_true", help="recompile even valid component inputs")
    parser.add_argument("--assemble-only", action="store_true", help="only assemble already verified component inputs")
    parser.add_argument("--with-passwall", action="store_true",
                        help=argparse.SUPPRESS)
    parser.add_argument("--components-only", action="store_true")
    parser.add_argument("--stage", action="append", help="build/check selected component stage(s), without making images")
    parser.add_argument("--plan", action="store_true", help="read-only list of recipe coverage and missing inputs")
    parser.add_argument("--check", action="store_true", help="read-only artifact verification; fail if anything is missing")
    args = parser.parse_args()
    if args.with_passwall:
        if args.profile == "base":
            args.profile = "production"
    if args.output is None:
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        args.output = LAB / "out/releases" / f"sbe1v1k-qsdk-1.5.3-{args.profile}-{stamp}"
    if args.jobs < 1 or args.jobs > 128:
        parser.error("--jobs must be between 1 and 128")
    if bool(args.initramfs) != bool(args.initramfs_sums):
        parser.error("local initramfs requires --initramfs and --initramfs-sums together")
    if args.assemble_only and (args.rebuild or args.stage or args.components_only):
        parser.error("--assemble-only cannot be combined with component build options")
    stages = stage_plan()
    if args.stage:
        unknown = set(args.stage) - {s["name"] for s in stages}
        if unknown:
            parser.error("unknown stage: " + ", ".join(sorted(unknown)))
        stages = [s for s in stages if s["name"] in args.stage]
    if args.plan or args.check:
        for stage in stages:
            absent = missing(stage)
            print(f"{stage['name']}: {len(stage['artifacts'])} inputs, {len(absent)} missing/mismatched")
            for path in absent:
                print("  " + path)
        if args.check and any(missing(s) for s in stages):
            raise ValueError("not all artifact inputs satisfy their contracts")
        return
    dependencies()  # Validate the catalog before any writes/downloads.
    with exclusive(LAB / "work/build.lock"):
        Build(args).main(stages)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as exc:
        raise SystemExit(f"ERROR: {exc}") from exc
