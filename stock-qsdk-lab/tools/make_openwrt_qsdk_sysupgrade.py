#!/usr/bin/env python3
"""Build a guarded mainline-OpenWrt to stock-QSDK migration sysupgrade.

The output is a normal OpenWrt eMMC sysupgrade tar with fwtool metadata.  It is
only for an Askey SBE1V1K already using this repository's mainline GPT layout.
It replaces 0:HLOS and rootfs and invalidates rootfs_data; it never writes GPT,
boot0 or boot1.  The generated companion installer performs the explicit
read-only boot-path check before invoking the stock OpenWrt sysupgrade
implementation. It never changes APPSBLENV or replaces/bypasses a chainloader;
the official direct-p25 path must already be configured on non-chainloader devices.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import struct
import subprocess
import tarfile
import tempfile
from pathlib import Path


FDT_MAGIC = 0xD00DFEED
FWIMAGE_MAGIC = 0x46577830  # "FWx0"
FWIMAGE_INFO = 1
SQUASHFS_MAGIC = b"hsqs"
P25_PARTITION_SIZE = 7_340_032
BOARD = "askey_sbe1v1k"
SUPPORTED_DEVICE = "askey,sbe1v1k"
QSDK_SUPPORTED_DEVICE = "qcom,ipq9574-ap-al02-c4"
CONTROL_BOARD = "spectrum_sbe1v1k"
CONTROL_LAYOUT = "mainline"
ROOTFS_PARTITION_SIZE = 127_926_272
COMPAT_VERSION = "1.1"
CONFIRM_TOKEN = "MIGRATE-OPENWRT-TO-QSDK"
DIRECT_BOOTCMD = (
    'echo "Hit ctrl+c for shell..."; if sleep 3; then run do_boot; '
    "else run do_nothing; fi;"
)
DIRECT_DO_BOOT = "mmc read 0x44000000 0x00014022 0x3800; bootm 0x44000000"
OFFICIAL_BOOTCMD = (
    'echo "Hit ctrl+c for shell..."; if sleep 3; then run do_boot; '
    "else do_nothing; fi;"
)
OFFICIAL_WIKI_BOOTCMD = (
    'echo ""; echo "=== U-Boot Boot Sequence Start ==="; '
    'echo "Hit Ctrl+C within 3 seconds to enter shell."; echo ""; '
    'if sleep 3; then echo "No Ctrl+C detected - continuing automatic boot."; '
    'echo "Attempting TFTP boot (only available when RESET initialized Ethernet)..."; '
    'setenv ipaddr 192.168.1.1; setenv serverip 192.168.1.2; '
    'tftpboot 0x80000000 initramfs.itb; if test $? -eq 0; then '
    'echo "TFTP succeeded - booting downloaded initramfs image..."; '
    'bootm 0x80000000; else echo "TFTP failed - falling back to MMC boot."; '
    'run do_boot; fi; else echo "Ctrl+C detected - entering U-Boot shell."; '
    'run do_nothing; fi; echo "=== U-Boot Boot Sequence End ===";'
)
CHAINLOADER_DO_BOOT = "run boot_chainloader"
CHAINLOADER_BOOT = (
    "mmc dev 0 0; mmc read 0x44000000 0x4f6022 0x2000; bootm 0x44000000"
)
CHAINLOADER_BOOTCMD = (
    'echo "Hit ctrl+c for shell..."; if sleep 3; then setenv bootargs '
    "console=ttyMSM0,115200n8 rootwait root=/dev/mmcblk0p27; run do_boot; "
    "else run do_nothing; fi;"
)
# Observed in the stock 1.1.3.1 APPSBLENV backup. The 1.5.3 SIMG does not
# contain APPSBLENV; devices with different values must fail preflight.
STOCK_BOOTARGS = "console=ttyMSM0,115200n8"
STOCK_BOOTCMD = "aq_load_fw 0x0 && bootipq"
PARTITIONS = {
    "0:APPSBLENV": ("mmcblk0p17", 28_706, 512),
    "0:HLOS": ("mmcblk0p25", 81_954, 14_336),
    "rootfs": ("mmcblk0p27", 110_626, 249_856),
    "rootfs_data": ("mmcblk0p29", 610_338, 1_048_576),
    "rootfs_data_1": ("mmcblk0p30", 1_658_914, 1_048_576),
    "rsvd_2": ("mmcblk0p40", 5_201_954, 65_536),
}


def configure_source(derived_path: Path, lock_path: Path) -> dict[str, str | int]:
    """Bind verified source data for this invocation, without code-level hashes."""
    source = json.loads(derived_path.read_text())
    lock = json.loads(lock_path.read_text())
    if source.get("format") != "sbe1v1k-derived-source-v1" or \
            lock.get("format") != "sbe1v1k-stock-source-v1" or \
            source.get("source_lock_sha256") != sha256_file(lock_path) or \
            source.get("source_sha256") != lock.get("sha256") or \
            source.get("release") != lock.get("release"):
        raise ValueError("derived source does not match the selected vendor source lock")
    artifacts = source["artifacts"]
    hlos = artifacts["vendor-hlos-p25.img"]
    fit = artifacts["stock-p25.fit"]
    expected = {
        "hlos_sha256": hlos["sha256"],
        "hlos_size": hlos["size"],
        "fit_offset": source["kernel_fit_offset"],
        "fit_sha256": fit["sha256"],
        "fit_size": fit["size"],
        "release": source["release"],
    }
    if expected["hlos_size"] != P25_PARTITION_SIZE or \
            not 40 <= expected["fit_size"] <= P25_PARTITION_SIZE or \
            not 0 <= expected["fit_offset"] < P25_PARTITION_SIZE:
        raise ValueError("vendor kernel does not fit the audited p25 partition")
    for field in ("hlos_sha256", "fit_sha256"):
        if not re.fullmatch(r"[0-9a-f]{64}", expected[field]):
            raise ValueError(f"invalid derived {field}")
    return expected


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_write(path: Path, data: bytes, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        temporary = Path(name)
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        temporary.chmod(mode)
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def parse_build_manifest(path: Path, rootfs: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in values:
            raise ValueError(f"duplicate rootfs build-manifest field: {key}")
        values[key] = value

    required = {
        "squashfs_artifact_role": "unpadded-rootfs",
        "rootfs_data_label": "rootfs_data_1",
        "component_profile": "production",
    }
    for key, expected in required.items():
        if values.get(key) != expected:
            raise ValueError(
                f"rootfs build manifest has {key}={values.get(key)!r}, "
                f"expected {expected!r}"
            )
    if values.get("mount_policy") not in {"normal", "trial-safe"}:
        raise ValueError("rootfs build manifest has an unsupported mount policy")
    if values.get("squashfs_sha256") != sha256_file(rootfs):
        raise ValueError("rootfs hash does not match its build manifest")
    if values.get("squashfs_size") != str(rootfs.stat().st_size):
        raise ValueError("rootfs size does not match its build manifest")
    return values


def read_hlos_fit(path: Path, source: dict[str, str | int]) -> tuple[bytes, dict[str, int | str]]:
    hlos = path.read_bytes()
    actual_sha = sha256_bytes(hlos)
    if actual_sha != source["hlos_sha256"] or len(hlos) != source["hlos_size"]:
        raise ValueError(
            "refusing unknown HLOS image: expected the locked stock p25 "
            f"({source['hlos_size']} bytes, {source['hlos_sha256']}), got "
            f"({len(hlos)} bytes, {actual_sha})"
        )
    offset = int(source["fit_offset"])
    if len(hlos) < offset + 40:
        raise ValueError("stock HLOS is too short for its embedded FIT header")
    header = struct.unpack_from(">10I", hlos, offset)
    (
        magic,
        total_size,
        off_struct,
        off_strings,
        off_mem_rsvmap,
        version,
        last_comp_version,
        _boot_cpu,
        size_strings,
        size_struct,
    ) = header
    if magic != FDT_MAGIC:
        raise ValueError(f"no FIT/FDT header at locked offset 0x{offset:x}")
    if version < 17 or last_comp_version > version:
        raise ValueError("unsupported or inconsistent FIT/FDT header version")
    if total_size < 40 or offset + total_size > len(hlos):
        raise ValueError("embedded FIT total size exceeds the HLOS partition image")
    if off_mem_rsvmap < 40:
        raise ValueError("invalid FIT memory-reservation offset")
    if off_struct + size_struct > total_size or off_strings + size_strings > total_size:
        raise ValueError("FIT structure or strings block exceeds total size")
    fit = hlos[offset : offset + total_size]
    if len(fit) != source["fit_size"] or sha256_bytes(fit) != source["fit_sha256"]:
        raise ValueError("vendor HLOS FIT differs from the verified source")
    return fit, {
        "hlos_size": len(hlos),
        "hlos_sha256": actual_sha,
        "fit_offset": offset,
        "fit_size": len(fit),
        "fit_sha256": sha256_bytes(fit),
    }


def read_locked_fit(path: Path, source: dict[str, str | int]) -> tuple[bytes, dict[str, int | str]]:
    """Read the canonical FIT already extracted from the locked stock p25 dump."""
    fit = path.read_bytes()
    actual_sha = sha256_bytes(fit)
    if len(fit) != source["fit_size"] or actual_sha != source["fit_sha256"]:
        raise ValueError(
            "refusing unknown extracted stock FIT: expected "
            f"({source['fit_size']} bytes, {source['fit_sha256']}), got "
            f"({len(fit)} bytes, {actual_sha})"
        )
    header = struct.unpack_from(">10I", fit, 0)
    if header[0] != FDT_MAGIC or header[1] != len(fit):
        raise ValueError("locked extracted stock FIT has an invalid FDT header")
    return fit, {
        "hlos_size": source["hlos_size"],
        "hlos_sha256": source["hlos_sha256"],
        "fit_offset": source["fit_offset"],
        "fit_size": len(fit),
        "fit_sha256": actual_sha,
        "fit_input": "locked-extracted-stock-p25",
    }


def read_squashfs(path: Path) -> tuple[bytes, dict[str, int | str]]:
    root = path.read_bytes()
    if len(root) < 96 or root[:4] != SQUASHFS_MAGIC:
        raise ValueError("root image is not a little-endian SquashFS image")
    major, minor = struct.unpack_from("<HH", root, 28)
    bytes_used = struct.unpack_from("<Q", root, 40)[0]
    if (major, minor) != (4, 0):
        raise ValueError(f"migration requires SquashFS 4.0, got {major}.{minor}")
    if bytes_used < 96 or bytes_used > len(root):
        raise ValueError("invalid SquashFS bytes_used field")
    if len(root) > ROOTFS_PARTITION_SIZE:
        raise ValueError("root image exceeds the audited p27 partition size")
    return root, {
        "rootfs_file_size": len(root),
        "rootfs_bytes_used": bytes_used,
        "rootfs_sha256": sha256_bytes(root),
        "squashfs_version": f"{major}.{minor}",
    }


def tar_info(name: str, size: int, mode: int = 0o644) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.size = size
    info.mode = mode
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = 0
    return info


def build_sysupgrade_tar(path: Path, fit: bytes, root: bytes) -> None:
    prefix = f"sysupgrade-{BOARD}"
    padded_root = root + b"\0" * (-len(root) % 1024)
    # OpenWrt's image builder emits GNU tar.  The recovery parser accepts both
    # GNU and POSIX ustar, but matching the known-good SBE1V1K artifact removes
    # an unnecessary format difference from HTTP recovery qualification.
    with tarfile.open(path, "w", format=tarfile.GNU_FORMAT) as archive:
        directory = tar_info(f"{prefix}/", 0, 0o755)
        directory.type = tarfile.DIRTYPE
        archive.addfile(directory)
        control = (
            f"BOARD={CONTROL_BOARD}\n"
            f"SBE1V1K_LAYOUT={CONTROL_LAYOUT}\n"
            f"SBE_ROOT_SIZE={len(padded_root)}\n"
            f"SBE_ROOT_SHA256={sha256_bytes(padded_root)}\n"
        ).encode()
        archive.addfile(tar_info(f"{prefix}/CONTROL", len(control)), _BytesReader(control))
        archive.addfile(tar_info(f"{prefix}/kernel", len(fit)), _BytesReader(fit))
        archive.addfile(
            tar_info(f"{prefix}/root", len(padded_root)), _BytesReader(padded_root)
        )


class _BytesReader:
    """Small file-like wrapper accepted by tarfile.addfile()."""

    def __init__(self, data: bytes):
        import io

        self._reader = io.BytesIO(data)

    def read(self, size: int = -1) -> bytes:
        return self._reader.read(size)


def crc32_table() -> tuple[int, ...]:
    table = []
    for index in range(256):
        value = index
        for _ in range(8):
            value = (value >> 1) ^ (0xEDB88320 if value & 1 else 0)
        table.append(value)
    return tuple(table)


CRC32_TABLE = crc32_table()


def fwtool_crc32(value: int, data: bytes) -> int:
    for byte in data:
        value = CRC32_TABLE[(value ^ byte) & 0xFF] ^ (value >> 8)
    return value


def append_fwtool_metadata(path: Path, metadata: bytes) -> int:
    """Append the format implemented by locked OpenWrt fwtool commit."""
    if len(metadata) > 30 * 1024:
        raise ValueError("fwtool metadata exceeds its 30 KiB limit")
    base_size = path.stat().st_size
    crc = 0xFFFFFFFF
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            crc = fwtool_crc32(crc, chunk)
    header = b"\0" * 8
    crc = fwtool_crc32(crc, header)
    crc = fwtool_crc32(crc, metadata)
    size = len(header) + len(metadata) + 16
    trailer = struct.pack(">IIB3xI", FWIMAGE_MAGIC, crc, FWIMAGE_INFO, size)
    with path.open("ab") as handle:
        handle.write(header)
        handle.write(metadata)
        handle.write(trailer)
        handle.flush()
        os.fsync(handle.fileno())
    return base_size


def extract_fwtool_metadata(path: Path) -> tuple[int, bytes]:
    file_size = path.stat().st_size
    if file_size < 24:
        raise ValueError("output is too short for fwtool metadata")
    with path.open("rb") as handle:
        handle.seek(-16, os.SEEK_END)
        trailer = handle.read(16)
        magic, expected_crc, kind, size = struct.unpack(">IIB3xI", trailer)
        if magic != FWIMAGE_MAGIC or kind != FWIMAGE_INFO:
            raise ValueError("output has no fwtool information trailer")
        if size < 24 or size > 30 * 1024 + 24 or size > file_size:
            raise ValueError("output has an invalid fwtool information size")
        base_size = file_size - size
        handle.seek(0)
        crc = 0xFFFFFFFF
        remaining = file_size - 16
        while remaining:
            chunk = handle.read(min(1024 * 1024, remaining))
            if not chunk:
                raise ValueError("unexpected EOF while checking fwtool CRC")
            crc = fwtool_crc32(crc, chunk)
            remaining -= len(chunk)
        if crc != expected_crc:
            raise ValueError("fwtool metadata CRC mismatch")
        handle.seek(base_size)
        header = handle.read(8)
        if header != b"\0" * 8:
            raise ValueError("unsupported fwtool information header")
        metadata = handle.read(size - 24)
    return base_size, metadata


def inspect_tar(path: Path, base_size: int, fit: bytes, root: bytes) -> None:
    prefix = f"sysupgrade-{BOARD}"
    expected = [
        f"{prefix}",
        f"{prefix}/CONTROL",
        f"{prefix}/kernel",
        f"{prefix}/root",
    ]
    with tarfile.open(path, "r:") as archive:
        members = archive.getmembers()
        if [member.name.rstrip("/") for member in members] != expected:
            raise ValueError("unexpected sysupgrade member order or names")
        if not members[0].isdir():
            raise ValueError("sysupgrade board directory entry is missing")
        if any(member.pax_headers for member in members):
            raise ValueError("output unexpectedly contains PAX metadata")
        control = archive.extractfile(members[1])
        kernel = archive.extractfile(members[2])
        rootfs = archive.extractfile(members[3])
        padded_root = root + b"\0" * (-len(root) % 1024)
        expected_control = (
            f"BOARD={CONTROL_BOARD}\n"
            f"SBE1V1K_LAYOUT={CONTROL_LAYOUT}\n"
            f"SBE_ROOT_SIZE={len(padded_root)}\n"
            f"SBE_ROOT_SHA256={sha256_bytes(padded_root)}\n"
        ).encode()
        if control is None or control.read() != expected_control:
            raise ValueError("CONTROL member verification failed")
        if kernel is None or kernel.read() != fit:
            raise ValueError("kernel member verification failed")
        if rootfs is None or rootfs.read() != padded_root:
            raise ValueError("root member verification failed")
    if base_size % 10_240:
        raise ValueError("base sysupgrade tar is not record aligned")


def metadata_for(release_id: str, stock_release: str, rootfs_sha256: str) -> dict[str, object]:
    message = (
        "Migration from upstream OpenWrt to stock-QSDK requires sysupgrade -n; "
        "configuration cannot be preserved. UART/TFTP recovery is required if boot fails."
    )
    return {
        "metadata_version": "1.1",
        "compat_version": COMPAT_VERSION,
        "compat_message": message,
        "new_supported_devices": [SUPPORTED_DEVICE, QSDK_SUPPORTED_DEVICE],
        "supported_devices": [
            f"{SUPPORTED_DEVICE} - Image version mismatch: image {COMPAT_VERSION}, "
            f"device 1.0. Please wipe config during upgrade. Reason: {message}",
            QSDK_SUPPORTED_DEVICE,
        ],
        "sbe_migration": {
            "from": "OpenWrt qualcommbe/ipq95xx mainline layout",
            "to": f"stock-QSDK {stock_release} userland candidate",
            "persistent_overlay": "rootfs_data_1/mmcblk0p30",
            "persistent_selectors": [
                "sbe_persistent=1",
                "root=/dev/mmcblk0p27 (audited HTTP chainloader)",
            ],
            "requires_config_wipe": True,
            "rootfs_sha256": rootfs_sha256,
            "package_format": "sbe1v1k-universal-v1",
            "http_recovery_profile": CONTROL_LAYOUT,
        },
        "version": {
            "dist": "SBE1V1K-QSDK",
            "version": release_id,
            "revision": rootfs_sha256[:12],
            "target": "qualcommbe/ipq95xx",
            "board": BOARD,
        },
    }


def verify_with_official_fwtool(
    fwtool: Path, image: Path, base_tar: bytes, metadata: bytes
) -> str:
    if not fwtool.is_file() or not os.access(fwtool, os.X_OK):
        raise ValueError("the locked official fwtool executable is missing")
    with tempfile.TemporaryDirectory(prefix="sbe-fwtool-check-") as directory:
        extracted = Path(directory) / "metadata.json"
        subprocess.run(
            [str(fwtool), "-i", str(extracted), str(image)],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        if extracted.read_bytes() != metadata:
            raise ValueError("official fwtool extracted different metadata bytes")
        stripped = subprocess.run(
            [str(fwtool), "-T", "-i", "/dev/null", str(image)],
            check=True,
            stdout=subprocess.PIPE,
        ).stdout
        if stripped != base_tar:
            raise ValueError("official fwtool stripped output differs from base tar")
    return sha256_file(fwtool)


def render_installer(
    image_name: str,
    image_sha256: str,
) -> bytes:
    geometry = "\n".join(
        f"check_part '{label}' '{device}' '{start}' '{sectors}'"
        for label, (device, start, sectors) in PARTITIONS.items()
    )
    return f'''#!/bin/sh
# Generated guard for {image_name}; default action is read-only preflight.
set -eu

expected_image_sha256='{image_sha256}'
confirm_token='{CONFIRM_TOKEN}'
audit_mount=/tmp/sbe-p30-migration-audit

fail() {{ echo "FAIL: $*" >&2; exit 1; }}
cleanup() {{ umount "$audit_mount" 2>/dev/null || true; rmdir "$audit_mount" 2>/dev/null || true; }}
trap cleanup EXIT HUP INT TERM

device_for_label() {{
\twanted=$1
\tfor uevent in /sys/class/block/mmcblk0p*/uevent; do
\t\t[ -r "$uevent" ] || continue
\t\t[ "$(sed -n 's/^PARTNAME=//p' "$uevent")" = "$wanted" ] || continue
\t\tdevname=$(sed -n 's/^DEVNAME=//p' "$uevent")
\t\t[ -n "$devname" ] || continue
\t\tprintf '/dev/%s\\n' "$devname"
\t\treturn 0
\tdone
\treturn 1
}}

check_part() {{
\tlabel=$1 expected_name=$2 expected_start=$3 expected_sectors=$4
\tdevice=$(device_for_label "$label") || fail "partition label $label is missing"
\tname=${{device##*/}}
\t[ "$name" = "$expected_name" ] || fail "$label resolved to $name"
\t[ "$(cat "/sys/class/block/$name/start")" = "$expected_start" ] || fail "$label start mismatch"
\t[ "$(cat "/sys/class/block/$name/size")" = "$expected_sectors" ] || fail "$label size mismatch"
}}

private_mode() {{
\tmode=$(stat -c %a "$1" 2>/dev/null) || return 1
\tcase "$mode" in
\t\t[0-7][2367][0-7]|[0-7][0-7][2367]) return 1 ;;
\t\t[0-7][0-7][0-7]) return 0 ;;
\t\t*) return 1 ;;
\tesac
}}

check_vendor_wifi_layout() {{
\tvendor="$audit_mount/vendor" wifi="$audit_mount/vendor/wifi"
\t[ -e "$vendor" ] || return 0
\t[ -d "$vendor" ] && [ ! -L "$vendor" ] && [ -O "$vendor" ] && private_mode "$vendor" || return 1
\tfor item in "$vendor"/* "$vendor"/.[!.]* "$vendor"/..?*; do
\t\t[ -e "$item" ] || [ -L "$item" ] || continue
\t\t[ "$item" = "$wifi" ] || return 1
\tdone
\t[ -d "$wifi" ] && [ ! -L "$wifi" ] && [ -O "$wifi" ] && private_mode "$wifi" || return 1
\tfor item in "$wifi"/* "$wifi"/.[!.]* "$wifi"/..?*; do
\t\t[ -e "$item" ] || [ -L "$item" ] || continue
\t\tcase "${{item##*/}}" in
\t\t\twlfw_cal_01_QCN9224_PCI1.bin|wlfw_cal_01_QCN9224_PCI2.bin|wlfw_cal_01_QCN9224_PCI3.bin) ;;
\t\t\t*) return 1 ;;
\t\tesac
\t\t[ -f "$item" ] && [ ! -L "$item" ] && [ -O "$item" ] && private_mode "$item" || return 1
\t\tbytes=$(stat -c %s "$item" 2>/dev/null) || return 1
\t\tcase "$bytes" in ''|*[!0-9]*) return 1 ;; esac
\t\t[ "$bytes" -gt 0 ] && [ "$bytes" -le 8388608 ] || return 1
\tdone
}}

preflight() {{
\timage=$1
\t[ -f "$image" ] || fail "image is missing: $image"
\t[ "$(sha256sum "$image" | awk '{{print $1}}')" = "$expected_image_sha256" ] || fail "image SHA-256 mismatch"
\t[ "$(cat /tmp/sysinfo/board_name 2>/dev/null)" = '{SUPPORTED_DEVICE}' ] || fail "board is not {SUPPORTED_DEVICE}"
\tfor tool in fw_printenv fwtool jsonfilter mount sha256sum sysupgrade tar; do
\t\tcommand -v "$tool" >/dev/null 2>&1 || fail "required command is missing: $tool"
\tdone

{geometry}

\tp30=$(device_for_label rootfs_data_1)
\tgrep -q "^$p30 " /proc/mounts && fail "p30 is already mounted"
\tmkdir -p "$audit_mount"
\tmount -t ext4 -o ro,noload,nosuid,nodev,noexec "$p30" "$audit_mount" || fail "cannot read-only audit p30"
\tfor item in "$audit_mount"/* "$audit_mount"/.[!.]* "$audit_mount"/..?*; do
\t\t[ -e "$item" ] || [ -L "$item" ] || continue
\t\tcase "${{item##*/}}" in
\t\t\tlost+found|openwrt) ;;
\t\t\tvendor) check_vendor_wifi_layout || fail 'invalid p30 Wi-Fi calibration namespace' ;;
\t\t\t*) fail "unexpected p30 entry: ${{item##*/}}" ;;
\t\tesac
\tdone
\tcleanup

\tbootargs=$(fw_printenv -n bootargs) || fail "cannot read U-Boot bootargs"
\tbootcmd=$(fw_printenv -n bootcmd) || fail "cannot read U-Boot bootcmd"
\tdo_boot=$(fw_printenv -n do_boot 2>/dev/null) || do_boot=
\tif [ "$bootargs" = '{STOCK_BOOTARGS}' ] && [ "$bootcmd" = '{STOCK_BOOTCMD}' ] && [ -z "$do_boot" ]; then
\t\tfail "stock bootipq is not prepared for this image; configure the official mainline boot path first; this installer never changes the bootloader environment"
\telse
\t\tcase " $bootargs " in *' root=/dev/mmcblk0p27 '*) ;; *) fail "bootargs does not select p27" ;; esac
\t\tif [ "$do_boot" = '{DIRECT_DO_BOOT}' ] && {{ [ "$bootcmd" = '{DIRECT_BOOTCMD}' ] || [ "$bootcmd" = '{OFFICIAL_BOOTCMD}' ] || [ "$bootcmd" = '{OFFICIAL_WIKI_BOOTCMD}' ]; }}; then
\t\t\tboot_mode=direct-p25
\t\telif [ "$do_boot" = '{CHAINLOADER_DO_BOOT}' ] && {{ [ "$bootcmd" = '{CHAINLOADER_BOOTCMD}' ] || [ "$bootcmd" = '{DIRECT_BOOTCMD}' ]; }}; then
\t\t\tboot_chainloader=$(fw_printenv -n boot_chainloader) || fail "cannot read U-Boot boot_chainloader"
\t\t\t[ "$boot_chainloader" = '{CHAINLOADER_BOOT}' ] || fail "p40 chainloader command is not the audited mainline command"
\t\t\tboot_mode=p40-chainloader-mainline
\t\telse
\t\t\tfail "U-Boot bootcmd/do_boot is not a reviewed stock, direct-p25 or p40-chainloader path"
\t\tfi
\tfi

\tmetadata=/tmp/sbe-qsdk-migration.meta
\tmember_list=/tmp/sbe-qsdk-migration.members
\trm -f "$metadata" "$member_list"
\tfwtool -q -i "$metadata" "$image" || fail "OpenWrt metadata is missing"
\t[ "$(jsonfilter -i "$metadata" -e '@.compat_version')" = '{COMPAT_VERSION}' ] || fail "compat version mismatch"
\t[ "$(jsonfilter -i "$metadata" -e '@.new_supported_devices[0]')" = '{SUPPORTED_DEVICE}' ] || fail "supported-device metadata mismatch"
\ttar tf "$image" > "$member_list" || fail "sysupgrade tar is invalid"
\t[ "$(wc -l < "$member_list" | tr -d ' ')" = 4 ] || fail "unexpected sysupgrade member count"
\tgrep -qx 'sysupgrade-{BOARD}/' "$member_list" || fail "board directory is missing"
\tgrep -qx 'sysupgrade-{BOARD}/CONTROL' "$member_list" || fail "CONTROL is missing"
\tgrep -qx 'sysupgrade-{BOARD}/kernel' "$member_list" || fail "kernel is missing"
\tgrep -qx 'sysupgrade-{BOARD}/root' "$member_list" || fail "rootfs is missing"
\tsysupgrade -n -T "$image" || fail "sysupgrade rejected the migration image"
\techo "PREFLIGHT PASS: board, GPT, p30, U-Boot mode $boot_mode, image hash, metadata and sysupgrade validation are correct."
}}

mode=${{1:-}}
image=${{2:-}}
case "$mode" in
\tpreflight)
\t\t[ "$#" -eq 2 ] || fail "usage: $0 preflight /tmp/{image_name}"
\t\tpreflight "$image"
\t\t;;
\tinstall)
\t\t[ "$#" -eq 3 ] || fail "usage: $0 install /tmp/{image_name} $confirm_token"
\t\t[ "$3" = "$confirm_token" ] || fail "confirmation token mismatch"
\t\tpreflight "$image"
\t\techo 'Starting destructive migration: p25 and p27 will be replaced; p29 will be invalidated.'
\t\techo "Preserving the existing $boot_mode boot path and p40 recovery; no environment writes."
\t\techo 'Do not remove power. Recovery after interruption requires UART/TFTP.'
\t\t# procd owns the asynchronous stage-2 write and reboot. Never erase a
\t\t# partition before handoff or race it with a read-back/forced reboot.
\t\texec sysupgrade -n -v "$image"
\t\t;;
\t*)
\t\tfail "usage: $0 preflight|install /tmp/{image_name} [{CONFIRM_TOKEN}]"
\t\t;;
esac
'''.encode()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Create a deterministic, guarded mainline-OpenWrt to stock-QSDK "
            "SBE1V1K migration sysupgrade. This does not flash a device."
        )
    )
    kernel_source = parser.add_mutually_exclusive_group(required=True)
    kernel_source.add_argument("--hlos", type=Path, help="locked stock mmcblk0p25.img")
    kernel_source.add_argument(
        "--fit", type=Path, help="canonical FIT extracted from the locked stock p25 dump"
    )
    parser.add_argument("--rootfs", required=True, type=Path, help="final QSDK SquashFS")
    parser.add_argument("--derived-source", required=True, type=Path,
                        help="metadata extracted from a verified vendor SIMG")
    parser.add_argument("--source-lock", required=True, type=Path,
                        help="versioned lock for the vendor SIMG")
    parser.add_argument(
        "--rootfs-manifest", required=True, type=Path, help="matching rootfs build manifest"
    )
    parser.add_argument("--fwtool", required=True, type=Path, help="official locked fwtool executable")
    parser.add_argument("--release-id", required=True, help="portable release identifier")
    parser.add_argument("--output", required=True, type=Path, help="output *-sysupgrade.bin")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", args.release_id):
        parser.error("--release-id must be 1-64 portable characters")
    return args


def main() -> None:
    args = parse_args()
    source = configure_source(args.derived_source, args.source_lock)
    build_manifest = parse_build_manifest(args.rootfs_manifest, args.rootfs)
    if args.hlos is not None:
        fit, hlos_metadata = read_hlos_fit(args.hlos, source)
    else:
        fit, hlos_metadata = read_locked_fit(args.fit, source)
    source["p25_canonical_sha256"] = sha256_bytes(
        fit + bytes(P25_PARTITION_SIZE - len(fit)))
    root, root_metadata = read_squashfs(args.rootfs)
    metadata_object = metadata_for(
        args.release_id, str(source["release"]), str(root_metadata["rootfs_sha256"]))
    metadata_bytes = (
        json.dumps(metadata_object, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        fd, name = tempfile.mkstemp(prefix=f".{args.output.name}.", dir=args.output.parent)
        os.close(fd)
        temporary = Path(name)
        build_sysupgrade_tar(temporary, fit, root)
        base_tar = temporary.read_bytes()
        base_size = append_fwtool_metadata(temporary, metadata_bytes)
        extracted_base_size, extracted_metadata = extract_fwtool_metadata(temporary)
        if base_size != extracted_base_size or extracted_metadata != metadata_bytes:
            raise ValueError("internal fwtool metadata round-trip failed")
        inspect_tar(temporary, base_size, fit, root)
        fwtool_sha256 = verify_with_official_fwtool(
            args.fwtool, temporary, base_tar, metadata_bytes
        )
        os.replace(temporary, args.output)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)

    image_sha256 = sha256_file(args.output)
    installer = args.output.with_name(args.output.stem + "-install.sh")
    atomic_write(
        installer,
        render_installer(
            args.output.name,
            image_sha256,
        ),
        0o755,
    )
    manifest = {
        "format": "openwrt-sysupgrade-tar+fwtool-metadata",
        "board": BOARD,
        "supported_device": SUPPORTED_DEVICE,
        "layout": CONTROL_LAYOUT,
        "http_recovery_control_board": CONTROL_BOARD,
        "supported_devices": [SUPPORTED_DEVICE, QSDK_SUPPORTED_DEVICE],
        "release_id": args.release_id,
        "release_eligible": False,
        "hardware_tested": False,
        "exclusion_reason": (
            "cross-system p25/p27 migration has no automatic rollback and still "
            "requires a real-device preflight and UART/TFTP recovery readiness"
        ),
        "requires_config_wipe": True,
        "required_sysupgrade_test": f"sysupgrade -n -T /tmp/{args.output.name}",
        "required_installer_confirmation": CONFIRM_TOKEN,
        "persistent_boot_selectors": [
            "sbe_persistent=1",
            "root=/dev/mmcblk0p27 (audited HTTP chainloader)",
        ],
        "persistent_overlay": "rootfs_data_1/mmcblk0p30",
        "writes_when_installed": ["0:HLOS/mmcblk0p25", "rootfs/mmcblk0p27"],
        "installed_kernel_prefix_size": source["fit_size"],
        "installed_kernel_prefix_sha256": source["fit_sha256"],
        "zero_padded_p25_sha256": source["p25_canonical_sha256"],
        "upstream_kernel_write_scope": (
            "FIT bytes only; bytes after the FIT are not part of the image "
            "and are not cleared by the companion installer"
        ),
        "invalidates_when_installed": ["rootfs_data/mmcblk0p29"],
        "never_written_by_installer": [
            "GPT",
            "mmc boot0",
            "mmc boot1",
            "0:BOOTCONFIG",
            "0:BOOTCONFIG1",
            "0:APPSBLENV/mmcblk0p17",
            "rsvd_2/mmcblk0p40 chainloader",
        ],
        "accepted_source_boot_modes": [
            "direct-p25",
            "p40-chainloader-mainline",
        ],
        "uboot_environment_change": (
            "none; preserve the prepared direct-p25 or existing mainline p40 chainloader path"
        ),
        "partition_geometry": {
            label: {"device": device, "start": start, "sectors": sectors}
            for label, (device, start, sectors) in PARTITIONS.items()
        },
        "metadata": metadata_object,
        "metadata_sha256": sha256_bytes(metadata_bytes),
        "base_sysupgrade_tar_size": base_size,
        "base_sysupgrade_tar_sha256": sha256_bytes(base_tar),
        "sysupgrade_size": args.output.stat().st_size,
        "sysupgrade_sha256": image_sha256,
        "installer_sha256": sha256_file(installer),
        "rootfs_build_manifest_sha256": sha256_file(args.rootfs_manifest),
        "component_profile_sha256": build_manifest.get("component_profile_sha256"),
        "vendor_source_lock_sha256": sha256_file(args.source_lock),
        "vendor_derived_source_sha256": sha256_file(args.derived_source),
        "fwtool_executable_sha256": fwtool_sha256,
        **hlos_metadata,
        **root_metadata,
    }
    manifest_path = args.output.with_name(args.output.name + ".manifest.json")
    atomic_write(
        manifest_path,
        (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode(),
    )
    sums = "\n".join(
        f"{sha256_file(path)}  {path.name}" for path in (args.output, installer, manifest_path)
    ) + "\n"
    atomic_write(args.output.with_name("SHA256SUMS"), sums.encode())
    print(f"built {args.output} ({args.output.stat().st_size} bytes, sha256 {image_sha256})")
    print(f"wrote guarded installer {installer}")
    print(f"wrote manifest {manifest_path}")
    print("HARDWARE GATE: run companion preflight on the target; do not flash this host-side build")


if __name__ == "__main__":
    main()
