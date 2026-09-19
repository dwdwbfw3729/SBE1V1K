#!/usr/bin/env python3
"""Prepare source archives and service files from existing versioned locks."""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

from build_release import LAB, download, sha256


def lock(path):
    result = {}
    for line in Path(path).read_text().splitlines():
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values = shlex.split(value, comments=True)
            result[key] = values[0] if values else ""
    return result


def sources(qsdk):
    for component, prefix, name in (
        ("procd-board-build", "PROCD", "procd"),
        ("cgi-io-security-build", "CGI_IO", "cgi-io"),
    ):
        root = LAB / component
        values = lock(root / "sources.lock")
        target = root / "distfiles" / values[prefix + "_ARCHIVE"]
        expected = values[prefix + "_ARCHIVE_SHA256"]
        target.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="sbe-source-") as directory:
            archive = Path(directory) / "source.tar"
            subprocess.run(["git", "-C", str(root / "sources" / name), "-c", "tar.umask=0002",
                            "archive", "--format=tar", "--prefix=" + name + "-" + values[prefix + "_COMMIT"] + "/",
                            "--output=" + str(archive), values[prefix + "_COMMIT"]], check=True)
            if sha256(archive) != expected:
                raise ValueError(f"{component}: Git archive differs from source lock")
            if target.exists() and sha256(target) != expected:
                raise ValueError(f"{component}: cached source archive differs; preserved")
            if not target.exists():
                shutil.copyfile(archive, target)
    for component, prefix in (("ubus-security-build", "UBUS"), ("lucihttp-security-build", "LUCIHTTP")):
        root = LAB / component
        values = lock(root / "sources.lock")
        filename = values[prefix + "_ARCHIVE"]
        download("https://sources.openwrt.org/" + filename,
                 root / "distfiles" / filename, values[prefix + "_ARCHIVE_SHA256"])
    values = lock(LAB / "qsdk-build/sources.lock")
    for prefix, filename in (("DNSMASQ", "dnsmasq-" + values["DNSMASQ_VERSION"] + ".tar.xz"),
                             ("DROPBEAR", "dropbear-" + values["DROPBEAR_VERSION"] + ".tar.bz2")):
        download(values[prefix + "_URL"], qsdk / "qsdk/dl" / filename, values[prefix + "_SHA256"])
    native = LAB / "passwall-native-candidate"
    values = json.loads((native / "sources.lock.json").read_text())
    for name in ("shadowsocks_rust", "sing_box"):
        download(values[name + "_archive_url"], native / values[name + "_archive"], values[name + "_archive_sha256"])


def service_files(qsdk):
    mappings = [
        ("package/utils/busybox/files/sysntpd", "busybox-candidate/rootfs-payload/etc/init.d/sysntpd"),
        ("package/utils/busybox/files/ntpd-hotplug", "busybox-candidate/rootfs-payload/usr/sbin/ntpd-hotplug"),
        ("package/system/ubox/files/log.init", "logd-candidate/rootfs-payload/etc/init.d/log"),
    ]
    for source, target in mappings:
        # Use locked Git bytes, not a developer's modified file in the worktree.
        data = subprocess.check_output(["git", "-C", str(qsdk / "qsdk"), "show", "HEAD:" + source])
        target = LAB / target
        if target.exists() and target.read_bytes() != data:
            raise ValueError(f"generated service input differs; preserved: {target}")
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists():
            target.write_bytes(data)
            target.chmod(0o755)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--services-only", action="store_true")
    parser.add_argument("--qsdk-source-root", type=Path, required=True)
    args = parser.parse_args()
    service_files(args.qsdk_source_root)
    if not args.services_only:
        sources(args.qsdk_source_root)
