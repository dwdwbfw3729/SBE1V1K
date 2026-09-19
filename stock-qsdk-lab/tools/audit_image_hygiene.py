#!/usr/bin/env python3

"""Reject private, host-specific, or transient data in an expanded rootfs."""

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path


PERSONAL_PATH_PATTERNS = (
    # Keep this case-sensitive: lower-case /users/ is common in documentation
    # URLs (for example wireless.kernel.org/en/users/) and is not a macOS home.
    ("macOS-user-path", re.compile(br"/Users/")),
    ("macOS-private-tmp-path", re.compile(br"/private/tmp/", re.IGNORECASE)),
    (
        "Windows-user-path",
        re.compile(br"[A-Z]:[\\/]Users[\\/]", re.IGNORECASE),
    ),
    (
        "build-workspace-path",
        re.compile(br"/(?:mnt/)?workspace/", re.IGNORECASE),
    ),
)

# These patterns are safe to scan in every regular file, including ELF,
# firmware blobs and bytecode.  Requiring a complete PEM block avoids treating
# parser/help strings such as "BEGIN PRIVATE KEY" as actual key material.
BINARY_CONTENT_PATTERNS = PERSONAL_PATH_PATTERNS + (
    (
        "private-key-pem",
        re.compile(
            br"-----BEGIN ((?:[A-Z0-9][A-Z0-9 -]{0,47} )?PRIVATE KEY)-----\r?\n"
            br"(?:[A-Za-z0-9+/]{4,80}={0,2}\r?\n){2,}"
            br"-----END \1-----"
        ),
    ),
)

# Markup and automatic web assets are meaningful only in text-like payloads.
TEXT_CONTENT_PATTERNS = (
    (
        "remote-web-asset",
        re.compile(
            br"(?:<(?:script|link)\b[^>]*(?:src|href)\s*=\s*['\"]https?://|"
            br"@import\s+(?:url\()?\s*['\"]?https?://)",
            re.IGNORECASE,
        ),
    ),
)

PATH_PATTERNS = PERSONAL_PATH_PATTERNS

# These factory files contain a shared Basic-Auth credential or a reusable
# server private key.  Their presence is unsafe even if a later init script is
# expected to replace them.
STOCK_FIXED_CREDENTIAL_PATHS = {
    "etc/httpd.conf",
    "etc/lighttpd/.lighttpdpassword",
    "etc/lighttpd/self-signed.pem",
    "etc/uhttpd.crt",
    "etc/uhttpd.key",
    "usr/askey/server_rsakey.pem",
    "usr/opensync/certs/client_dec.key",
}

# The replacement image must not merely disable these management stacks.  A
# clean release physically omits their payloads so a stray hook cannot revive
# operator cloud control after an upgrade or configuration restore.
FORBIDDEN_OPERATOR_PREFIXES = (
    "etc/hotplug.d/dump_q6v5",
    "etc/hotplug.d/dump",
    "etc/hotplug.d/minidump",
    "etc/hotplug.d/iface/70-quagga",
    "etc/pairing",
    "etc/quagga",
    "opt/cujo",
    "opt/samknows",
    "sbin/modecheck.sh",
    "sbin/mf_tool_old",
    "usr/cujo",
    "usr/lib/libmosquitto",
    "usr/lib/libofproto",
    "usr/lib/libsflow",
    "usr/opensync",
    "usr/plume",
    "usr/sbin/askey_fan",
    "usr/sbin/askey_pwm.init",
    "usr/sbin/askey_pwm.test",
    "usr/sbin/inetd",
    "usr/sbin/veriWaveTestCommands.sh",
)

FORBIDDEN_OPERATOR_PATHS = {
    "etc/config/minidump",
    "etc/init.d/inetd",
    "lib/preinit/42_mount_askey_mfc_partition",
    "sbin/ftm_qcc710_start",
    "sbin/mapctrol",
    "usr/bin/auto_burn_fw.sh",
    "usr/bin/ble_upgrade",
    "usr/bin/bootloader_upgrade",
    "usr/bin/qdss_setup.sh",
    "usr/bin/rcp_upgrade",
    "usr/bin/se_upgrade",
    "usr/bin/thread_upgrade",
    "usr/sbin/diag_flash_logger",
    "usr/sbin/diag_socket_app",
    "usr/sbin/diag_stress_app",
    "usr/sbin/ftpd",
    "usr/sbin/ftm",
    "usr/sbin/license-pfm-upgrade.sh",
    "usr/sbin/myftm",
    "usr/sbin/registerReboot",
    "usr/sbin/wpd",
    "usr/sbin/wlanfw-upgrade.sh",
    "usr/lib/opkg/info/libmosquitto-ssl.control",
}

# Dormant factory components and packaging tests that are intentionally absent
# from the local-management firmware.  Prefix matching also catches versioned
# libcpc sonames and Python bytecode suffix variants.
FORBIDDEN_RELEASE_PREFIXES = (
    "usr/lib/libcpc.so",
    "usr/lib/python3.7/site-packages/ecdsa/test_",
)

FORBIDDEN_RELEASE_PATHS = {
    "etc/init.d/cpcd",
    "etc/init.d/otbr-agent",
    "usr/bin/cpcapp",
    "usr/bin/cpcd",
    "usr/etc/cpcd.conf",
    "usr/local/firmware/ncp_empty_2.gbl",
    "usr/local/firmware/thread_test.gbl",
    "usr/sbin/cpc_hci_bridge",
    "usr/sbin/encrypt_client_app",
    "usr/sbin/ot-ctl",
    "usr/sbin/otbr-agent",
}

FORBIDDEN_ACTIVE_SERVICES = {
    "avahi-daemon",
    "boot-ftm",
    "cnss_diag",
    "dbus",
    "dhcrelay4",
    "diag_socket_app",
    "inetd",
    "led",
    "mcproxy",
    "quagga",
    "qca-acfg",
    "sysstat",
}

# Scripts which run automatically must never upload crash data, contact a
# provisioning host, or invoke an operator messaging client.  User-invoked
# package downloads remain governed by the separately audited opkg wrapper.
AUTOMATIC_EGRESS_COMMAND = re.compile(
    br"(?:^[\t ]*|[;&|`][\t ]*|\$\([\t ]*)"
    br"(?:(?:exec|command|then|do)[\t ]+)?"
    br"(?:/[^\s;&|()]+/)?"
    br"(?:tftp|curl|wget|nc|netcat|socat|mosquitto_pub|mosquitto_sub|mqtt)"
    br"(?=[\t \r\n<>;&|]|$)",
    re.IGNORECASE | re.MULTILINE,
)

HOTPLUG_EGRESS_TOKEN = re.compile(
    br"\b(?:tftp|curl|wget|nc|netcat|socat|mosquitto_pub|mosquitto_sub|mqtt)\b",
    re.IGNORECASE,
)

AUTO_SCRIPT_PREFIXES = (
    "etc/crontabs/",
    "etc/hotplug.d/",
    "etc/profile.d/",
)

AUTO_SCRIPT_PATHS = {
    "etc/profile",
    "etc/rc.local",
}

HISTORY_NAMES = {
    ".ash_history",
    ".bash_history",
    ".history",
    ".lesshst",
    ".mysql_history",
    ".node_repl_history",
    ".python_history",
    ".sqlite_history",
    ".zsh_history",
}

RUNTIME_STATE_NAMES = {
    "btmp",
    "lastlog",
    "machine-id",
    "nohup.out",
    "random-seed",
    "utmp",
    "wtmp",
}

DROPBEAR_HOST_KEY = re.compile(r"^dropbear_[a-z0-9_-]+_host_key$", re.IGNORECASE)
LOG_NAME = re.compile(r"\.log(?:\.\d+|\.gz|\.xz|\.bz2)?$", re.IGNORECASE)
PRIVATE_SCAN_OVERLAP = 32768
SCAN_CHUNK_SIZE = 1024 * 1024


def normalized_relative(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def is_transient_state(relative: str) -> str:
    parts = relative.split("/")
    name = parts[-1]
    lower_name = name.lower()
    lower_parts = [part.lower() for part in parts]

    if name.startswith("._") or lower_name == ".ds_store":
        return "macOS-metadata"
    if lower_name in HISTORY_NAMES or lower_name.endswith("_history"):
        return "shell-or-tool-history"
    if lower_name in RUNTIME_STATE_NAMES:
        return "runtime-identity-or-state"
    if lower_name == "leases" or lower_name.endswith(".leases"):
        return "network-lease-state"
    if LOG_NAME.search(lower_name):
        return "log-file"
    if len(lower_parts) >= 2 and lower_parts[:2] in (
        ["var", "log"],
        ["tmp", "log"],
    ):
        return "log-file"
    if len(lower_parts) >= 3 and lower_parts[:3] == ["usr", "askey", "log"]:
        return "log-file"
    return ""


def content_matches(path: Path, vendor_firmware: bool = False):
    """Yield (label, byte offset) once for each prohibited byte pattern."""
    found = set()
    offset = 0
    carry = b""
    with path.open("rb") as stream:
        sample = stream.read(8192)
        printable = sum(
            byte in b"\t\n\r" or 32 <= byte <= 126 for byte in sample
        )
        text_like = b"\x00" not in sample and (
            not sample or printable * 100 >= len(sample) * 85
        )
        patterns = BINARY_CONTENT_PATTERNS
        if vendor_firmware:
            # The locked vendor WLAN blob embeds its own build workspace path.
            # The caller permits this exception only for its attested bytes.
            patterns = tuple(item for item in patterns
                             if item[0] != "build-workspace-path")
        if text_like:
            patterns += TEXT_CONTENT_PATTERNS
        stream.seek(0)
        while True:
            chunk = stream.read(SCAN_CHUNK_SIZE)
            if not chunk:
                break
            data = carry + chunk
            data_offset = offset - len(carry)
            for label, pattern in patterns:
                if label in found:
                    continue
                match = pattern.search(data)
                if match is not None:
                    found.add(label)
                    yield label, data_offset + match.start()
            carry = data[-PRIVATE_SCAN_OVERLAP:]
            offset += len(chunk)


def textish_bytes(path: Path):
    """Return small text-like files as bytes, otherwise return None."""
    try:
        data = path.read_bytes()
    except OSError:
        return None
    sample = data[:8192]
    if b"\x00" in sample:
        return None
    try:
        data.decode("utf-8", errors="strict")
        return data
    except UnicodeDecodeError:
        pass
    printable = sum(byte in b"\t\n\r" or 32 <= byte <= 126 for byte in sample)
    if sample and printable * 100 < len(sample) * 85:
        return None
    return data


def automatic_egress_match(path: Path, relative: str):
    data = textish_bytes(path)
    if data is None:
        return None
    if relative.startswith("etc/hotplug.d/"):
        offset = 0
        for line in data.splitlines(keepends=True):
            stripped = line.lstrip()
            if stripped and not stripped.startswith(b"#"):
                match = HOTPLUG_EGRESS_TOKEN.search(stripped)
                if match is not None:
                    return offset + len(line) - len(stripped) + match.start()
            offset += len(line)
        return None
    match = AUTOMATIC_EGRESS_COMMAND.search(data)
    return None if match is None else match.start()


def inspect_shutdown_wrappers(root: Path):
    violations = []
    for name in ("reboot", "halt", "poweroff"):
        path = root / "sbin" / name
        relative = f"sbin/{name}"
        if not path.is_file() or path.is_symlink():
            violations.append(
                (
                    "unsafe-shutdown-command",
                    relative,
                    "must be a regular local wrapper, never a factory BusyBox link",
                )
            )
            continue
        text = path.read_text(errors="replace").lower()
        for forbidden in (
            "busybox reboot",
            "busybox halt",
            "busybox poweroff",
            "opensync-default",
            "/usr/askey/persist",
        ):
            if forbidden in text:
                violations.append(
                    (
                        "unsafe-shutdown-command",
                        relative,
                        f"factory shutdown accounting remains: {forbidden}",
                    )
                )
        if name == "reboot" and "ubus call system reboot" not in text:
            violations.append(
                (
                    "unsafe-shutdown-command",
                    relative,
                    "reboot does not delegate directly to procd over ubus",
                )
            )
        if name != "reboot" and "exit 1" not in text:
            violations.append(
                (
                    "unsafe-shutdown-command",
                    relative,
                    "unsupported power operation does not fail closed",
                )
            )
    return violations


def inspect_rc_policy(root: Path):
    violations = []
    rc_dir = root / "etc/rc.d"
    for link in sorted(rc_dir.glob("S*")):
        relative = normalized_relative(link, root)
        if not link.is_symlink():
            violations.append(
                ("startup-policy", relative, "startup entry is not a symlink")
            )
            continue
        target = os.readlink(link)
        service = Path(target).name
        if service in FORBIDDEN_ACTIVE_SERVICES:
            violations.append(
                (
                    "startup-policy",
                    relative,
                    f"factory/optional/conflicting service is active: {service}",
                )
            )
        if target.startswith("/"):
            target_path = root / target.lstrip("/")
        else:
            target_path = link.parent / target
        target_path = Path(os.path.normpath(target_path))
        if target_path.is_file():
            offset = automatic_egress_match(target_path, "etc/rc.d-active")
            if offset is not None:
                violations.append(
                    (
                        "automatic-network-egress",
                        relative,
                        f"active service invokes an upload/client command at byte {offset}",
                    )
                )
    return violations


def inspect_opkg_policy(root: Path):
    violations = []
    key_dir = root / "etc/opkg/keys"
    if key_dir.is_dir():
        for path in sorted(key_dir.iterdir()):
            if (
                not path.is_file()
                or path.is_symlink()
                or path.stat().st_size > 4096
                or b"PRIVATE" in path.read_bytes()
            ):
                violations.append(
                    (
                        "invalid-opkg-key",
                        normalized_relative(path, root),
                        "opkg keys must be small regular public-key files",
                    )
                )

    config_paths = [root / "etc/opkg.conf"]
    config_paths.extend(sorted((root / "etc/opkg").glob("*.conf")))
    source_line = re.compile(br"^\s*src(?:/gz|-gz)?\s+", re.IGNORECASE)
    local_source_seen = False
    for path in config_paths:
        if not path.is_file():
            continue
        for line_number, line in enumerate(path.read_bytes().splitlines(), start=1):
            stripped = line.lstrip()
            if stripped.startswith(b"#"):
                continue
            if not source_line.match(line):
                continue
            fields = line.split()
            if fields == [b"src/gz", b"sbe_local", b"file:///usr/share/sbe-feed"]:
                local_source_seen = True
                continue
            if (
                len(fields) == 3
                and fields[0] in (b"src", b"src/gz")
                and re.fullmatch(br"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", fields[1])
                and re.fullmatch(br"[A-Za-z][A-Za-z0-9+.-]*://\S+", fields[2])
            ):
                continue
            violations.append(
                (
                    "invalid-opkg-source",
                    normalized_relative(path, root),
                    f"malformed opkg source at line {line_number}",
                )
            )
    feed_marker = root / "usr/share/sbe-build/feed-policy"
    external_feed = feed_marker.is_file() and feed_marker.read_text() == "external\n"
    if external_feed:
        if local_source_seen or (root / "usr/share/sbe-feed").exists():
            violations.append(
                ("opkg-external-feed-bundled", "usr/share/sbe-feed",
                 "external feed policy must not embed its package archive")
            )
    else:
        if not local_source_seen:
            violations.append(
                ("opkg-local-feed-missing", "etc/opkg.conf",
                 "built-in file:///usr/share/sbe-feed source is missing")
            )
        if not (root / "usr/share/sbe-feed/Packages").is_file():
            violations.append(
                ("opkg-local-feed-missing", "usr/share/sbe-feed/Packages",
                 "built-in package index is missing")
            )

    wrapper = root / "bin/opkg"
    wrapper_data = textish_bytes(wrapper) if wrapper.is_file() else None
    for marker in (
        b"/usr/libexec/sbe-opkg-real",
        b'exec "$real_opkg" "$@"',
    ):
        if wrapper_data is None or marker not in wrapper_data:
            violations.append(
                (
                    "broken-opkg-entrypoint",
                    "bin/opkg",
                    f"transparent wrapper marker is missing: {marker.decode()}",
                )
            )
    if wrapper_data is not None:
        for forbidden in (b"package-denylist", b"filter_protected", "只支持单个".encode()):
            if forbidden in wrapper_data:
                violations.append(
                    (
                        "restricted-opkg-entrypoint",
                        "bin/opkg",
                        f"legacy package restriction remains: {forbidden.decode()}",
                    )
                )

    real_opkg = root / "usr/libexec/sbe-opkg-real"
    if not real_opkg.is_file() or real_opkg.read_bytes()[:4] != b"\x7fELF":
        violations.append(
            (
                "broken-opkg-entrypoint",
                "usr/libexec/sbe-opkg-real",
                "preserved real opkg is missing or not ELF",
            )
        )
    elif stat.S_IMODE(real_opkg.stat().st_mode) != 0o755:
        violations.append(
            (
                "broken-opkg-entrypoint",
                "usr/libexec/sbe-opkg-real",
                "preserved real opkg mode must be exactly 0755",
            )
        )

    custom_ui_paths = (
        "www/luci-static/resources/view/system/sbe-packages.js",
        "usr/share/luci/menu.d/sbe-packages.json",
        "usr/share/rpcd/acl.d/sbe-packages.json",
        "usr/sbin/sbe-opkg-ui",
        "usr/sbin/sbe-opkg-status",
        "usr/sbin/sbe-opkg-source",
    )
    for relative in custom_ui_paths:
        path = root / relative
        if path.exists() or path.is_symlink():
            violations.append(
                (
                    "legacy-opkg-ui",
                    relative,
                    "custom package manager replacement remains beside native luci-app-opkg",
                )
            )

    native_files = {
        "usr/lib/lua/luci/controller/opkg.lua": (
            b'entry({"admin", "system", "opkg"}, template("opkg"), _("Software"), 30)',
            b'{ "/bin/opkg", "--force-removal-of-dependent-packages" }',
            b'cmd[#cmd + 1] = "--autoremove"',
            b'cmd[#cmd + 1] = "--force-overwrite"',
        ),
        "usr/lib/lua/luci/view/opkg.htm": (
            b"<%+header%>",
            b'<script type="text/javascript" src="<%=resource%>/view/opkg.js',
            b"<%+footer%>",
        ),
        "www/luci-static/resources/view/opkg.js": (
            b"var path='/tmp/upload.ipk'",
            b"L.ui.uploadFile(path)",
            b"L.fs.remove(path)",
        ),
    }
    for relative, markers in native_files.items():
        path = root / relative
        data = textish_bytes(path) if path.is_file() and not path.is_symlink() else None
        if data is None:
            violations.append(
                ("native-opkg-ui-missing", relative, "native luci-app-opkg file is missing")
            )
            continue
        for marker in markers:
            if marker not in data:
                violations.append(
                    (
                        "native-opkg-ui-mismatch",
                        relative,
                        f"native luci-app-opkg marker is missing: {marker.decode()}",
                    )
                )

    luci_acl_path = root / "usr/share/rpcd/acl.d/luci-base.json"
    try:
        luci_acl = json.loads(luci_acl_path.read_text())["luci-access"]["write"]
        upload_methods = set(luci_acl.get("cgi-io", []))
        upload_file_methods = set(luci_acl.get("file", {}).get("/tmp/upload.ipk", []))
        file_methods = set(luci_acl.get("ubus", {}).get("file", []))
    except (OSError, KeyError, TypeError, ValueError) as error:
        violations.append(("native-opkg-upload-policy", "usr/share/rpcd/acl.d/luci-base.json", str(error)))
    else:
        for present, expected, detail in (
            (upload_methods, "upload", "cgi-io upload permission is missing"),
            (upload_file_methods, "write", "/tmp/upload.ipk write permission is missing"),
            (file_methods, "remove", "ubus file.remove permission is missing"),
        ):
            if expected not in present:
                violations.append(
                    ("native-opkg-upload-policy", "usr/share/rpcd/acl.d/luci-base.json", detail)
                )
    return violations


def inspect_management_surface(root: Path):
    """Validate that the standard LuCI management surface is intact.

    Normal LuCI pages and their matching rpcd ACLs are functionality, not
    dormant attack surface.  This audit therefore verifies structure and the
    presence of the native system views, without imposing local UI text,
    hiding backup/flash/service controls or disabling Dropbear forwarding.
    """

    violations = []
    download_cgi = root / "www/cgi-bin/cgi-download"
    if download_cgi.exists() or download_cgi.is_symlink():
        violations.append(
            (
                "management-surface",
                "www/cgi-bin/cgi-download",
                "unused authenticated download CGI remains without a caller",
            )
        )

    for relative, required_key in (
        ("usr/share/luci/menu.d/luci-mod-system.json", None),
        ("usr/share/rpcd/acl.d/luci-base.json", "luci-access"),
    ):
        path = root / relative
        try:
            document = json.loads(path.read_text())
            if not isinstance(document, dict):
                raise TypeError("top-level JSON value is not an object")
            if required_key is not None and required_key not in document:
                raise KeyError(required_key)
        except (OSError, KeyError, TypeError, ValueError) as error:
            violations.append(("management-surface", relative, str(error)))

    for relative in (
        "www/luci-static/resources/view/system/dropbear.js",
        "www/luci-static/resources/view/system/leds.js",
        "www/luci-static/resources/view/system/mounts.js",
        "www/luci-static/resources/view/system/sshkeys.js",
        "www/luci-static/resources/view/system/startup.js",
        "www/luci-static/resources/view/system/system.js",
        "etc/init.d/dropbear",
    ):
        path = root / relative
        if not path.is_file() or path.is_symlink():
            violations.append(
                ("management-surface", relative, "native management file is missing")
            )
    return violations


def inspect_logging_policy(root: Path):
    violations = []
    var_path = root / "var"
    if not var_path.is_symlink() or os.readlink(var_path) != "tmp":
        violations.append(
            (
                "persistent-log-policy",
                "var",
                "/var must remain a tmpfs-backed link to /tmp",
            )
        )

    config_path = root / "etc/config/system"
    config = config_path.read_text(errors="replace") if config_path.is_file() else ""
    for marker in ("option log_size '2048'",):
        if marker not in config:
            violations.append(
                (
                    "unbounded-log-policy",
                    "etc/config/system",
                    f"bounded RAM logging marker is missing: {marker}",
                )
            )
    if re.search(r"^\s*option\s+log_ip\s+", config, flags=re.MULTILINE):
        violations.append(
            (
                "automatic-network-egress",
                "etc/config/system",
                "default remote syslog destination is configured",
            )
        )

    for forbidden in ("option log_file", "option log_type"):
        if forbidden in config:
            violations.append(
                (
                    "persistent-log-policy",
                    "etc/config/system",
                    f"default memory logging is overridden: {forbidden}",
                )
            )

    init_path = root / "etc/init.d/log"
    init = init_path.read_text(errors="replace") if init_path.is_file() else ""
    for marker in (
        'procd_set_param command "/sbin/logd"',
        'procd_append_param command -S "${log_buffer_size}"',
        "start_service_file",
        "start_service_remote",
    ):
        if marker not in init:
            violations.append(
                (
                    "unbounded-log-policy",
                    "etc/init.d/log",
                    f"native logd service marker is missing: {marker}",
                )
            )
    for relative in ("sbin/logd", "sbin/logread"):
        binary = root / relative
        if not binary.is_file() or binary.is_symlink() or not os.access(binary, os.X_OK):
            violations.append(
                (
                    "unbounded-log-policy",
                    relative,
                    "native logd executable is missing or not executable",
                )
            )
    return violations


def inspect_mf_tool_policy(root: Path):
    violations = []
    wrapper = root / "sbin/mf_tool"
    wrapper_data = textish_bytes(wrapper) if wrapper.is_file() else None
    for marker in (
        b'case "$#:$1" in',
        b"1:READ_HW_VERSION|1:READ_TN|1:READ_6G_MAC)",
        b'exec /usr/libexec/sbe-mf-tool-real "$1"',
    ):
        if wrapper_data is None or marker not in wrapper_data:
            violations.append(
                (
                    "unsafe-manufacturing-tool",
                    "sbin/mf_tool",
                    f"read-only wrapper marker is missing: {marker.decode()}",
                )
            )

    real_tool = root / "usr/libexec/sbe-mf-tool-real"
    if not real_tool.is_file() or real_tool.read_bytes()[:4] != b"\x7fELF":
        violations.append(
            (
                "unsafe-manufacturing-tool",
                "usr/libexec/sbe-mf-tool-real",
                "protected factory tool is missing or not ELF",
            )
        )
    elif stat.S_IMODE(real_tool.stat().st_mode) != 0o700:
        violations.append(
            (
                "unsafe-manufacturing-tool",
                "usr/libexec/sbe-mf-tool-real",
                "protected factory tool mode must be exactly 0700",
            )
        )

    invocation = re.compile(
        br"(?:^|[;&|`(])[\t ]*(?:/sbin/)?mf_tool[\t ]+([A-Z0-9_]+)",
        re.MULTILINE,
    )
    allowed = {b"READ_HW_VERSION", b"READ_TN", b"READ_6G_MAC"}
    for path in root.rglob("*"):
        if not path.is_file() or path.is_symlink() or path == wrapper:
            continue
        data = textish_bytes(path)
        if data is None:
            continue
        for match in invocation.finditer(data):
            if match.group(1) not in allowed:
                violations.append(
                    (
                        "unsafe-manufacturing-tool",
                        normalized_relative(path, root),
                        f"automatic/non-wrapper call uses {match.group(1).decode()}",
                    )
                )
        if b"/usr/libexec/sbe-mf-tool-real" in data:
            violations.append(
                (
                    "unsafe-manufacturing-tool",
                    normalized_relative(path, root),
                    "protected real mf_tool path is referenced outside its wrapper",
                )
            )
    return violations


def inspect_led_policy(root: Path):
    violations = []
    public_tool = root / "sbin/led_ctl"
    public_data = textish_bytes(public_tool) if public_tool.is_file() else None
    for marker in (
        b"manager=/usr/sbin/sbe-led",
        b'exec "$manager" upgrade',
        b'exec "$manager" error',
    ):
        if public_data is None or marker not in public_data:
            violations.append(
                (
                    "uncontrolled-led-entrypoint",
                    "sbin/led_ctl",
                    f"policy-wrapper marker is missing: {marker.decode()}",
                )
            )
    if public_data is not None and b"askey_pwm_sig" in public_data:
        violations.append(
            (
                "uncontrolled-led-entrypoint",
                "sbin/led_ctl",
                "public LED wrapper directly accesses the PWM actuator",
            )
        )

    real_tool = root / "usr/libexec/sbe-led-ctl-real"
    real_data = textish_bytes(real_tool) if real_tool.is_file() else None
    if real_data is None or b"/usr/bin/askey_pwm_sig" not in real_data:
        violations.append(
            (
                "uncontrolled-led-entrypoint",
                "usr/libexec/sbe-led-ctl-real",
                "protected stock LED actuator is missing",
            )
        )
    elif stat.S_IMODE(real_tool.stat().st_mode) != 0o700:
        violations.append(
            (
                "uncontrolled-led-entrypoint",
                "usr/libexec/sbe-led-ctl-real",
                "protected stock LED actuator mode must be exactly 0700",
            )
        )
    if real_data is not None and b"error_check() {\n\treturn 0\n}" not in real_data:
        violations.append(
            (
                "uncontrolled-led-entrypoint",
                "usr/libexec/sbe-led-ctl-real",
                "factory world-writable /tmp LED latch is still active",
            )
        )

    for relative in (
        "usr/bin/askey_pwm",
        "usr/bin/askey_pwm_sig",
        "usr/sbin/askey_pwm.script",
    ):
        actuator = root / relative
        if (
            not actuator.is_file()
            or actuator.is_symlink()
            or stat.S_IMODE(actuator.stat().st_mode) != 0o700
        ):
            violations.append(
                (
                    "uncontrolled-board-actuator",
                    relative,
                    "board PWM executors must be root-only mode 0700",
                )
            )

    manager = root / "usr/sbin/sbe-led"
    manager_data = textish_bytes(manager) if manager.is_file() else None
    if manager_data is None or b"/usr/libexec/sbe-led-ctl-real" not in manager_data:
        violations.append(
            (
                "uncontrolled-led-entrypoint",
                "usr/sbin/sbe-led",
                "LED policy manager does not use the protected actuator",
            )
        )

    pwm_init = root / "etc/init.d/askey_pwm"
    pwm_init_data = textish_bytes(pwm_init) if pwm_init.is_file() else None
    if pwm_init_data is None or b"PROG=/usr/bin/askey_pwm" not in pwm_init_data:
        violations.append(
            (
                "uncontrolled-led-entrypoint",
                "etc/init.d/askey_pwm",
                "board PWM daemon is not supervised by the local init script",
            )
        )
    elif b"led_ctl" in pwm_init_data or b"askey_pwm_sig" in pwm_init_data:
        violations.append(
            (
                "uncontrolled-led-entrypoint",
                "etc/init.d/askey_pwm",
                "PWM init script bypasses the LED policy manager",
            )
        )

    # Enforce the ownership boundary on the completed image, not just on the
    # overlay sources.  Stock and package payloads are merged before this
    # audit, so any resurrected legacy caller is caught here as well.
    allowed_text_callers = {
        # The preserved stock actuator contains its own led_ctl function/name.
        # It is the protected implementation endpoint, not an external bypass.
        b"led_ctl": {
            "sbin/led_ctl",
            "usr/sbin/sbe-led",
            "usr/libexec/sbe-led-ctl-real",
        },
        b"askey_pwm_sig": {
            "usr/libexec/sbe-led-ctl-real",
            "usr/sbin/askey_pwm.script",
        },
        b"/usr/libexec/sbe-led-ctl-real": {"usr/sbin/sbe-led"},
        b"/usr/sbin/askey_pwm.script": {
            "etc/init.d/sbe-thermal-policy",
            "usr/sbin/sbe-thermal-policy",
        },
    }
    for path in root.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        try:
            if not (stat.S_IMODE(path.stat().st_mode) & 0o111):
                continue
        except OSError:
            continue
        data = textish_bytes(path)
        if data is None:
            continue
        relative = normalized_relative(path, root)
        for token, allowed in allowed_text_callers.items():
            if token in data and relative not in allowed:
                violations.append(
                    (
                        "uncontrolled-led-caller",
                        relative,
                        f"protected LED token is referenced outside its owner: {token.decode()}",
                    )
                )
    return violations


def inspect_immutable_permissions(root: Path):
    violations = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            continue
        try:
            metadata = path.lstat()
        except OSError as error:
            violations.append(
                ("scan-error", normalized_relative(path, root), str(error))
            )
            continue
        mode = stat.S_IMODE(metadata.st_mode)
        relative = normalized_relative(path, root)
        if stat.S_ISREG(metadata.st_mode):
            if mode & (stat.S_IWGRP | stat.S_IWOTH):
                violations.append(
                    (
                        "writable-immutable-file",
                        relative,
                        f"regular file mode {mode:04o} permits group/other writes",
                    )
                )
            if mode & (stat.S_ISUID | stat.S_ISGID):
                violations.append(
                    (
                        "privileged-immutable-file",
                        relative,
                        f"regular file mode {mode:04o} carries setuid/setgid",
                    )
                )
        elif stat.S_ISDIR(metadata.st_mode):
            if relative == "tmp":
                if mode != 0o1777:
                    violations.append(
                        (
                            "runtime-directory-mode",
                            relative,
                            f"/tmp mode must be exactly 1777, found {mode:04o}",
                        )
                    )
            elif mode & (stat.S_IWGRP | stat.S_IWOTH):
                violations.append(
                    (
                        "writable-immutable-directory",
                        relative,
                        f"directory mode {mode:04o} permits group/other writes",
                    )
                )
    return violations


def inspect_root(root: Path):
    violations = []
    entry_count = 0
    file_count = 0

    for current, directories, files in os.walk(root, followlinks=False):
        directories.sort()
        files.sort()
        current_path = Path(current)

        # os.walk does not visit symlinked directories, but their link itself
        # still needs path and target inspection.
        entries = list(directories) + list(files)
        for name in entries:
            path = current_path / name
            relative = normalized_relative(path, root)
            entry_count += 1

            lower_name = name.lower()
            display_path = ("/" + relative).encode(
                "utf-8", errors="surrogateescape"
            )
            for label, pattern in PATH_PATTERNS:
                if pattern.search(display_path):
                    violations.append(
                        (label, relative, "prohibited string in image path")
                    )

            if lower_name in ("authorized_keys", "known_hosts"):
                violations.append(
                    ("SSH-trust-material", relative, "forbidden path name")
                )

            if relative in STOCK_FIXED_CREDENTIAL_PATHS:
                violations.append(
                    (
                        "stock-fixed-credential",
                        relative,
                        "known factory credential/private-key path",
                    )
                )

            if any(
                relative == prefix or relative.startswith(prefix + "/")
                for prefix in FORBIDDEN_OPERATOR_PREFIXES
            ):
                violations.append(
                    (
                        "operator-control-payload",
                        relative,
                        "retired operator management tree remains in image",
                    )
                )

            if relative in FORBIDDEN_OPERATOR_PATHS:
                violations.append(
                    (
                        "operator-control-payload",
                        relative,
                        "retired factory/test/diagnostic entry point remains",
                    )
                )

            if relative in FORBIDDEN_RELEASE_PATHS or any(
                relative.startswith(prefix) for prefix in FORBIDDEN_RELEASE_PREFIXES
            ):
                violations.append(
                    (
                        "dormant-or-test-payload",
                        relative,
                        "retired Thread/CPC component or packaging test remains",
                    )
                )

            try:
                metadata = path.lstat()
            except OSError as error:
                violations.append(("scan-error", relative, str(error)))
                continue

            if path.is_symlink():
                try:
                    target = os.readlink(path).encode("utf-8", errors="surrogateescape")
                except OSError as error:
                    violations.append(("scan-error", relative, str(error)))
                    continue
                for label, pattern in PERSONAL_PATH_PATTERNS + TEXT_CONTENT_PATTERNS:
                    if pattern.search(target):
                        violations.append(
                            (label, relative, "prohibited string in symlink target")
                        )
                if DROPBEAR_HOST_KEY.match(lower_name):
                    violations.append(
                        (
                            "dropbear-host-key",
                            relative,
                            "host-key symlink is not a verifiably empty placeholder",
                        )
                    )
                transient = is_transient_state(relative)
                if transient:
                    violations.append(
                        (transient, relative, "transient build/runtime symlink")
                    )
                target_text = target.decode("utf-8", errors="surrogateescape")
                if target_text.startswith("/"):
                    target_path = root / target_text.lstrip("/")
                else:
                    target_path = path.parent / target_text
                target_path = Path(os.path.normpath(target_path))
                immutable_target = target_text.startswith(
                    ("/bin/", "/sbin/", "/lib/", "/usr/", "/etc/")
                ) or relative.startswith(("bin/", "sbin/", "lib/", "usr/"))
                if immutable_target and not os.path.lexists(target_path):
                    violations.append(
                        (
                            "dangling-immutable-symlink",
                            relative,
                            f"target is absent: {target_text}",
                        )
                    )
                continue

            if not stat.S_ISREG(metadata.st_mode):
                continue
            file_count += 1

            transient = is_transient_state(relative)
            if transient:
                violations.append((transient, relative, "transient build/runtime file"))

            if DROPBEAR_HOST_KEY.match(lower_name) and metadata.st_size != 0:
                violations.append(
                    (
                        "dropbear-host-key",
                        relative,
                        f"embedded host key is {metadata.st_size} bytes",
                    )
                )

            if relative in AUTO_SCRIPT_PATHS or relative.startswith(
                AUTO_SCRIPT_PREFIXES
            ):
                byte_offset = automatic_egress_match(path, relative)
                if byte_offset is not None:
                    violations.append(
                        (
                            "automatic-network-egress",
                            relative,
                            f"automatic script contains an upload/client token at byte {byte_offset}",
                        )
                    )

            try:
                vendor_firmware = False
                if relative == "usr/share/sbe-wififw/qcn9224/amss.bin":
                    source = root / "usr/share/sbe-build/vendor-wifi-source"
                    if source.is_file():
                        expected = next(
                            (line.removeprefix("qcn9224_amss_sha256=")
                             for line in source.read_text().splitlines()
                             if line.startswith("qcn9224_amss_sha256=")), None)
                        if expected and expected == hashlib.sha256(path.read_bytes()).hexdigest():
                            vendor_firmware = True
                for label, byte_offset in content_matches(path, vendor_firmware):
                    violations.append(
                        (label, relative, f"prohibited content at byte {byte_offset}")
                    )
            except OSError as error:
                violations.append(("scan-error", relative, str(error)))

    violations.extend(inspect_shutdown_wrappers(root))
    violations.extend(inspect_rc_policy(root))
    violations.extend(inspect_opkg_policy(root))
    violations.extend(inspect_management_surface(root))
    violations.extend(inspect_logging_policy(root))
    violations.extend(inspect_mf_tool_policy(root))
    violations.extend(inspect_led_policy(root))
    violations.extend(inspect_immutable_permissions(root))
    return entry_count, file_count, sorted(set(violations))


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Audit an expanded rootfs for embedded SSH trust, private keys, "
        "personal build paths, factory credentials, and transient state."
        )
    )
    parser.add_argument("rootfs", type=Path, help="expanded rootfs directory")
    args = parser.parse_args()

    root = args.rootfs.resolve()
    if not root.is_dir():
        parser.error(f"not an expanded rootfs directory: {args.rootfs}")

    entry_count, file_count, violations = inspect_root(root)
    print(f"rootfs:                {root}")
    print(f"entries inspected:     {entry_count}")
    print(f"regular files scanned: {file_count}")

    if violations:
        print(f"\nFAIL: {len(violations)} image-hygiene violation(s):")
        for label, relative, detail in violations:
            print(f"  [{label}] /{relative}: {detail}")
        return 1

    print(
        "\nPASS: no embedded SSH trust, host key, private key, personal path, "
        "factory credential, operator payload, remote web asset, or transient "
        "state was found; startup, automatic-egress, shutdown, logging, mf_tool, "
        "LED, curated-feed and immutable-permission policies are locked."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
