#!/usr/bin/env python3
"""Build the SBE1V1K 1.5.3 release inputs and the three OpenWrt image types.

Usage: python3 stock-qsdk-lab/tools/build_1_5_3.py --output DIR
       [--vendor-simg ALREADY_DOWNLOADED_SIMG]
       [--initramfs VERIFIED_ITB --initramfs-sums MATCHING_SHA256SUMS]
       [--with-passwall]

The vendor SIMG is authenticated against a committed versioned source lock.
Generated component hashes and target upgrade checks come from that image.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


LAB = Path(__file__).resolve().parents[1]
LOCK = LAB / "sources/stock-1.5.3.json"
INITRAMFS_NAME = "openwrt-qualcommbe-ipq95xx-askey_sbe1v1k-initramfs-uImage.itb"
SNAPSHOT_BASE = "https://downloads.openwrt.org/snapshots/targets/qualcommbe/ipq95xx"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(*args: str, env: dict[str, str] | None = None) -> None:
    subprocess.run(args, check=True, env=env)


def download(url: str, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    run("curl", "--fail", "--location", "--retry", "3", "--output", str(path), url)


def official_initramfs(
    source: Path | None, sums_source: Path | None, release: Path
) -> dict:
    target = release / INITRAMFS_NAME
    sums = release / "openwrt-snapshot-sha256sums"
    if source is None:
        download(SNAPSHOT_BASE + "/sha256sums", sums)
        download(SNAPSHOT_BASE + "/" + INITRAMFS_NAME, target)
    else:
        if sums_source is None or not source.is_file() or source.is_symlink() or \
                not sums_source.is_file() or sums_source.is_symlink():
            raise ValueError("local initramfs requires a regular image and matching sha256sums")
        shutil.copyfile(sums_source, sums)
        shutil.copyfile(source, target)
    expected = []
    for line in sums.read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})\s+\*?(\S+)", line)
        if match and match.group(2) == INITRAMFS_NAME:
            expected.append(match.group(1))
    if len(expected) != 1 or sha256(target) != expected[0]:
        raise ValueError("official initramfs does not match its snapshot sha256sums")
    with target.open("rb") as image:
        magic = image.read(4)
    if not 40 <= target.stat().st_size < 31 * 1024 * 1024 or \
            magic != b"\xd0\x0d\xfe\xed":
        raise ValueError("initramfs is not a size-compatible FIT image")
    return {"filename": INITRAMFS_NAME, "size": target.stat().st_size,
            "sha256": sha256(target),
            "origin": "downloaded-openwrt-snapshot" if source is None
            else "user-supplied-openwrt-snapshot"}


def check_local_inputs() -> None:
    """Fail before a long build when ignored, separately built inputs are absent."""
    missing: list[str] = []
    kernel = json.loads((LAB / "sources/kernel-support-1.5.3.json").read_text())
    for name, record in kernel["modules"].items():
        relative = "qsdk-build/out/kernel-support-1.5.3/" + name
        path = LAB / relative
        if not path.is_file() or sha256(path) != record["sha256"]:
            missing.append(relative)
    profile = json.loads((LAB / "component-profiles/production.json").read_text())
    for artifact in profile["artifacts"]:
        path = LAB / artifact["path"]
        if not path.is_file():
            missing.append(artifact["path"])
    for relative in ("busybox-candidate/rootfs-payload", "logd-candidate/rootfs-payload"):
        if not (LAB / relative).is_dir():
            missing.append(relative)
    manifest = LAB / "work/luci-package-manifest.tsv"
    if not manifest.is_file():
        missing.append("work/luci-package-manifest.tsv (run tools/prepare_packages.sh)")
    else:
        with manifest.open(newline="") as stream:
            for row in list(csv.reader(stream, delimiter="\t"))[1:]:
                if len(row) != 6:
                    raise ValueError("invalid LuCI package manifest row")
                if not (LAB / "cache/ipk" / row[3]).is_file():
                    missing.append("cache/ipk/" + row[3])
    feed_inputs = LAB / "feed/native-feed-inputs.tsv"
    with feed_inputs.open(newline="") as stream:
        for row in csv.reader(stream, delimiter="\t"):
            if not row or row[0].startswith("#"):
                continue
            if len(row) != 4:
                raise ValueError("invalid native feed input row")
            source = LAB / row[3]
            if not (source.is_file() if row[2] == "copy" else source.is_dir()):
                missing.append(row[3])
    if missing:
        preview = "\n".join("  " + path for path in missing[:20])
        raise ValueError(
            f"{len(missing)} locked local build inputs are missing:\n{preview}\n"
            "Build the source-locked component candidates and native feed first; "
            "the release command does not silently substitute unverified packages."
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--vendor-simg", type=Path)
    parser.add_argument("--initramfs", type=Path)
    parser.add_argument("--initramfs-sums", type=Path)
    parser.add_argument("--with-passwall", action="store_true",
                        help="preinstall verified PassWall packages without caching IPKs in the image")
    args = parser.parse_args()
    if args.initramfs_sums and not args.initramfs:
        parser.error("--initramfs-sums requires --initramfs")
    if args.initramfs and not args.initramfs_sums:
        parser.error("--initramfs requires the corresponding --initramfs-sums")
    check_local_inputs()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("output directory must be new or empty")
    output.mkdir(parents=True, exist_ok=True)
    source_dir = output / "source"
    release = output / "release"
    source_dir.mkdir()
    release.mkdir()
    lock = json.loads(LOCK.read_text())
    source = source_dir / lock["filename"]
    if args.vendor_simg:
        shutil.copyfile(args.vendor_simg, source)
    else:
        download(lock["url"], source)
    if source.stat().st_size != lock["size"] or sha256(source) != lock["sha256"]:
        raise ValueError("vendor SIMG differs from the committed source lock")
    run(sys.executable, str(LAB / "tools/prepare_stock_source.py"),
        "--lock", str(LOCK), "--source", str(source), "--outdir", str(source_dir))

    rootfs_partition = release / "sbe1v1k-qsdk-1.5.3-rootfs-partition.img"
    env = os.environ.copy()
    env["SBE_FEED_POLICY"] = "external"
    env["SBE_PACKAGE_PROFILE"] = "passwall" if args.with_passwall else "base"
    run(str(LAB / "tools/build_rootfs_docker.sh"),
        str(source_dir / "stock-rootfs-p27.img"), str(rootfs_partition),
        "rootfs_data_1", "normal", "production",
        str(source_dir / "stock-baseline.env"), env=env)
    feed_inputs = release / "compatible-feed-inputs"
    feed = release / "compatible-feed"
    run("sh", str(LAB / "feed/build-feed.sh"),
        "--input", str(feed_inputs), "--output", str(feed))
    run("sh", str(LAB / "feed/verify-feed.sh"), "--feed", str(feed))
    shutil.rmtree(feed_inputs)
    # Separate repository package for existing installations. A source
    # commit timestamp gives repeated builds a stable, ordered package version.
    source_epoch = subprocess.check_output(
        ["git", "-C", str(LAB), "show", "-s", "--format=%ct", "HEAD"], text=True).strip()
    if not source_epoch.isdecimal():
        raise ValueError("invalid source commit timestamp")
    offline = release / "sbe1v1k-qsdk-offline-feed.ipk"
    run(sys.executable, str(LAB / "feed/package_offline_feed.py"),
        "--feed", str(feed), "--output", str(offline), "--version", f"1.5.3-{source_epoch}")

    rootfs = release / "sbe1v1k-qsdk-1.5.3-rootfs-partition.root.squashfs"
    if args.with_passwall:
        run("sh", str(LAB / "passwall-native-candidate/tests/native-acceptance.sh"), str(rootfs))
        run("sh", str(LAB / "tests/test_preinstalled_rootfs.sh"), str(rootfs), str(feed))
    # Audit the current assembled rootfs, not an old RAM session's status.
    status = output / "assembled-opkg-status.txt"
    with status.open("wb") as stream:
        subprocess.run([
            "docker", "run", "--rm", "--network", "none", "--platform", "linux/arm64",
            "-v", f"{release}:/release:ro", "--entrypoint", "unsquashfs",
            "sbe1v1k-stock-rootfs-builder:ubuntu-24.04", "-cat",
            f"/release/{rootfs.name}", "usr/lib/opkg/status"], check=True, stdout=stream)
    run(sys.executable, str(LAB / "luci-maintenance/tests/runtime-final-status-compat.py"),
        "--artifacts", str(LAB / "luci-maintenance/runtime-candidate-out/release"),
        "--luci-artifacts", str(LAB / "luci-maintenance/candidate-out/release"),
        "--packages-lock", str(LAB / "luci-maintenance/runtime-packages.lock.tsv"),
        "--status", str(status), "--status-mode", "final",
        "--opkg-conf", str(LAB / "overlay/etc/opkg.conf"),
        "--output", str(output / "runtime-final-rootfs-compat.tsv"))
    manifest = release / (rootfs_partition.name + ".manifest")
    factory = release / "sbe1v1k-qsdk-1.5.3-squashfs-factory.bin"
    sysupgrade = release / "sbe1v1k-qsdk-1.5.3-squashfs-sysupgrade.bin"
    run(sys.executable, str(LAB / "tools/make_factory.py"),
        "--rootfs", str(rootfs), "--manifest", str(manifest),
        "--output", str(factory))
    if not (LAB / "firmware-tools/out/fwtool").is_file():
        run("bash", str(LAB / "firmware-tools/build-fwtool.sh"))
    run("docker", "run", "--rm", "--network", "none", "--platform", "linux/arm64",
        "-v", f"{LAB}:/lab:ro", "-v", f"{output}:/build",
        "--entrypoint", "python3", "sbe1v1k-stock-rootfs-builder:ubuntu-24.04",
        "/lab/tools/make_openwrt_qsdk_sysupgrade.py",
        "--fit", "/build/source/stock-p25.fit",
        "--derived-source", "/build/source/derived-source.json",
        "--source-lock", "/lab/sources/stock-1.5.3.json",
        "--rootfs", f"/build/release/{rootfs.name}",
        "--rootfs-manifest", f"/build/release/{manifest.name}",
        "--fwtool", "/lab/firmware-tools/out/fwtool",
        "--release-id", "1.5.3-qsdk", "--output", f"/build/release/{sysupgrade.name}")
    initramfs = official_initramfs(args.initramfs, args.initramfs_sums, release)
    images = {path.name: {"size": path.stat().st_size, "sha256": sha256(path)}
              for path in (factory, sysupgrade)}
    images[initramfs["filename"]] = initramfs
    source_identity = {}
    for line in manifest.read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            if key in {"source_git_commit", "source_tree_dirty", "source_diff_sha256"}:
                source_identity[key] = value
    report = {"format": "sbe1v1k-release-artifacts-v1",
              "package_profile": "passwall" if args.with_passwall else "base",
              "feed_policy": env["SBE_FEED_POLICY"],
              "vendor_source_lock_sha256": sha256(LOCK),
              "vendor_simg_sha256": sha256(source),
              "builder_source": source_identity,
              "images": images,
              "optional_packages": {offline.name: {"size": offline.stat().st_size, "sha256": sha256(offline)}},
              "hardware_validation": "pending user-operated flashing and device tests"}
    (release / "release-artifacts.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n")
    (release / "SHA256SUMS").write_text("".join(
        f"{item['sha256']}  {name}\n" for name, item in sorted(
            {**images, **report['optional_packages']}.items())))
    print(f"Built three images in {release}")
    print("Hardware validation is pending; the operator performs flashing.")


if __name__ == "__main__":
    main()
