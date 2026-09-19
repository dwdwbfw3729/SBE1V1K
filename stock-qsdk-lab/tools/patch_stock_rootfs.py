#!/usr/bin/env python3

import argparse
import filecmp
import hashlib
import json
import os
import re
import shutil
import stat
from pathlib import Path
from typing import Optional


DISABLED_RC_LINKS = (
    "K01lldpd",
    "K01iot_upgrade",
    "K10sysstat",
    "K89conntrackd",
    "K91cnss_diag",
    "K91otbr-agent",
    "K92cpcd",
    "K93avahi-daemon",
    "K94dbus",
    "K98boot-ftm",
    "K10update_vendor_data",
    "K50lighttpd",
    "K99socat",
    "K99update_neighbor6_global",
    "K98update_passwd",
    "S10update_passwd",
    "K01healthcheck",
    "S99healthcheck",
    "K99syslog-ng",
    "S11syslog-ng",
    "K99wpd",
    "S11wpd",
    "S08boot-ftm",
    "S10qca-acfg",
    "S15openvswitch",
    "S80rngd",
    "S21conntrackd",
    "S12sbe-wireless-policy",
    "S21sbe-wireless-policy",
    "S40fstab",
    "S50dropbear",
    "S50lighttpd",
    "S19cnss_diag",
    "S60dbus",
    "S61avahi-daemon",
    "S62bluetoothd",
    "S64mg21_init",
    "S65alsa",
    "S68default_ssid_key",
    "S90cujo-user",
    "S90btagent",
    "S90lldpd",
    "S90sysstat",
    "S91dhcrelay4",
    "S96led",
    "S97verify_ib",
    "S98check_mode",
    "S98diag_socket_app",
    "S98default_ssid_key",
    "S98sstorage",
    "S98time-services",
    "S99iot_upgrade",
    "S99mcproxy",
    "S99ookla",
    "S99opensync",
    "S99process_crash_dump",
    "S99qca_pta_config",
    "S99urandom_seed",
    "S99samknows",
    "S99secure_key",
    "S99socat",
    "S99trymodedone",
    "S99update_neighbor6_global",
    "S99update_vendor_data",
)

# Only these local/QSDK services may be reachable from an S* startup link.
# Optional services which need deliberate configuration (Avahi, DHCP relay,
# MCProxy and sysstat) retain their packages but are disabled by default.
# Factory-test and remote-diagnostic entry points are not whitelisted.  This
# includes qca-acfg: its init script reads U-Boot `serverip` and starts the
# broad acfg event/configuration tool with that network target; hostapd and the
# qcawificfg80211/netifd control path do not require that daemon.  The
# seemingly generic askey_pwm service is retained: it is the board-local fan
# actuator used by sbe-thermal-policy through askey_pwm_sig, while thermald is
# an independent emergency shutdown layer.  Likewise ftm creates /dev/caldata
# from ART; it is not the remote FTM socket service removed above.
ALLOWED_STARTUP_SERVICES = frozenset(
    {
        "01_skb_recycler",
        "SI_eye_diagram",
        "askey_pwm",
        "boot",
        "cron",
        "ddns",
        "dnsmasq",
        "done",
        "dropbear",
        "firewall",
        "ftm",
        "gpio_switch",
        "license-pfm",
        "load_cnss2",
        "mcsd",
        "miniupnpd",
        "network",
        "odhcpd",
        "passwall",
        "passwall_server",
        "powerctl",
        "qca-hostapd",
        "qca-nss-dp",
        "qca-nss-ecm",
        "qca-ssdk",
        "qca-wpa-supplicant",
        "qcawifi-config-cmd",
        "rngd",
        "rpcd",
        "sbe-accel",
        "sbe-led",
        "sbe-local-watchdog",
        "sbe-overlay-commit",
        "sbe-random-seed",
        "sbe-thermal-policy",
        "sysntpd",
        "sbe-wireless-policy",
        "sysctl",
        "sysfixtime",
        "syslog",
        "log",
        "system",
        "thermal",
        "ucitrack",
        "uhttpd",
        "wifi_fw_done",
        "wifi_fw_mount",
    }
)

ALLOWED_STOP_SERVICES = ALLOWED_STARTUP_SERVICES | {"umount"}


def harden_immutable_permissions(root: Path) -> None:
    """Remove factory group/world-write and privilege bits from the rootfs.

    The dumped image marks many immutable scripts, libraries and configuration
    files as 0666/0777. Overlayfs would make those bytes replaceable by any
    compromised non-root process. No regular file in this image needs that
    access, and the only deliberately shared writable directory is /tmp.
    """

    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            continue
        metadata = path.lstat()
        mode = stat.S_IMODE(metadata.st_mode)
        if stat.S_ISREG(metadata.st_mode):
            hardened = mode & ~(stat.S_IWGRP | stat.S_IWOTH)
            hardened &= ~(stat.S_ISUID | stat.S_ISGID)
        elif stat.S_ISDIR(metadata.st_mode):
            relative = path.relative_to(root).as_posix()
            if relative == "tmp":
                hardened = 0o1777
            else:
                hardened = mode & ~(stat.S_IWGRP | stat.S_IWOTH)
        else:
            continue
        if hardened != mode:
            path.chmod(hardened)

ENABLED_LINKS = {
    "S02sbe-random-seed": "../init.d/sbe-random-seed",
    "S11syslog": "../init.d/syslog",
    "S12rpcd": "../init.d/rpcd",
    "S18rngd": "../init.d/rngd",
    "S19dropbear": "../init.d/dropbear",
    "S19dnsmasq": "../init.d/dnsmasq",
    "S19firewall": "../init.d/firewall",
    "S97sbe-wireless-policy": "../init.d/sbe-wireless-policy",
    "S27sbe-accel": "../init.d/sbe-accel",
    "S29sbe-thermal-policy": "../init.d/sbe-thermal-policy",
    "S35odhcpd": "../init.d/odhcpd",
    "S50cron": "../init.d/cron",
    "S50uhttpd": "../init.d/uhttpd",
    "S80ucitrack": "../init.d/ucitrack",
    "S94miniupnpd": "../init.d/miniupnpd",
    "S97sbe-led": "../init.d/sbe-led",
    "S99sbe-overlay-commit": "../init.d/sbe-overlay-commit",
    "K50dropbear": "../init.d/dropbear",
    "K01sbe-random-seed": "../init.d/sbe-random-seed",
    "K85odhcpd": "../init.d/odhcpd",
    "K99syslog": "../init.d/syslog",
}

REMOVED_INIT_SCRIPTS = (
    "boot-ftm",
    "check_mode",
    "cujo-user",
    "default_ssid_key",
    "diag_socket_app",
    "healthcheck",
    "fstab",
    "iot_upgrade",
    "led",
    "lighttpd",
    "manager",
    "openvswitch",
    "opensync",
    "ookla",
    "process_crash_dump",
    "samknows",
    "secure_key",
    "socat",
    "sshm",
    "sstorage",
    "trymodedone",
    "update_neighbor6_global",
    "update_vendor_data",
    "verify_ib",
    "wpd",
)


def replace_once(path: Path, old: str, new: str):
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"expected one patch anchor in {path}, found {count}")
    path.write_text(text.replace(old, new))


def patch_dnsmasq_resolver_migration(root: Path) -> None:
    """Retain the standard migration and align the QSDK netifd output with it."""

    migration = root / "etc/uci-defaults/50-dnsmasq-migrate-resolv-conf-auto.sh"
    replace_once(
        migration,
        '$(uci get dhcp.@dnsmasq[0].resolvfile)',
        '$(uci -q get dhcp.@dnsmasq[0].resolvfile)',
    )


def patch_netifd_resolver(root: Path) -> None:
    """Use netifd's existing -r option, without replacing its vendor binary."""
    replace_once(
        root / "etc/init.d/network",
        '\tprocd_set_param command /sbin/netifd\n',
        '\t# Keep the resolver in a dedicated directory visible inside ujail.\n'
        '\t[ ! -L /tmp/resolv.conf.d ] || return 1\n'
        '\tmkdir -p /tmp/resolv.conf.d || return 1\n'
        '\tchmod 0755 /tmp/resolv.conf.d || return 1\n'
        '\tprocd_set_param command /sbin/netifd -r /tmp/resolv.conf.d/resolv.conf.auto\n',
    )


def patch_dnsmasq_runtime_resolver(root: Path) -> None:
    """Keep atomic resolver updates visible within the dnsmasq sandbox.

    As in upstream OpenWrt, bind the containing directory rather than one
    inode. The dedicated runtime directory avoids exposing all of /tmp.
    Create only the standard directory, not arbitrary configured paths.
    """

    dnsmasq = root / "etc/init.d/dnsmasq"
    replace_once(
        dnsmasq,
        '\t\tconfig_get resolvfile "$cfg" resolvfile /tmp/resolv.conf.auto\n'
        '\t\t[ -n "$resolvfile" -a ! -e "$resolvfile" ] && touch "$resolvfile"\n',
        '\t\tconfig_get resolvfile "$cfg" resolvfile /tmp/resolv.conf.auto\n'
        '\t\tif [ "$resolvfile" = "/tmp/resolv.conf.d/resolv.conf.auto" ]; then\n'
        '\t\t\t[ ! -L /tmp/resolv.conf.d ] || return 1\n'
        '\t\t\tmkdir -p /tmp/resolv.conf.d || return 1\n'
        '\t\t\t[ -d /tmp/resolv.conf.d ] && '
        '[ ! -L /tmp/resolv.conf.d ] || return 1\n'
        '\t\t\t[ "$(stat -c %u /tmp/resolv.conf.d 2>/dev/null)" = 0 ] || return 1\n'
        '\t\t\tchmod 0755 /tmp/resolv.conf.d || return 1\n'
        '\t\t\tif [ -e "$resolvfile" ] || [ -L "$resolvfile" ]; then\n'
        '\t\t\t\t[ -f "$resolvfile" ] && [ ! -L "$resolvfile" ] || return 1\n'
        '\t\t\t\t[ "$(stat -c %u "$resolvfile" 2>/dev/null)" = 0 ] || return 1\n'
        '\t\t\tfi\n'
        '\t\tfi\n'
        '\t\t[ -n "$resolvfile" -a ! -e "$resolvfile" ] && touch "$resolvfile"\n'
        '\t\tif [ "$resolvfile" = "/tmp/resolv.conf.d/resolv.conf.auto" ]; then\n'
        '\t\t\t[ -f "$resolvfile" ] && [ ! -L "$resolvfile" ] || return 1\n'
        '\t\t\t[ "$(stat -c %u "$resolvfile" 2>/dev/null)" = 0 ] || return 1\n'
        '\t\t\tchmod 0644 "$resolvfile" || return 1\n'
        '\t\tfi\n',
    )
    text = dnsmasq.read_text()
    text = text.replace('/tmp/resolv.conf.auto', '/tmp/resolv.conf.d/resolv.conf.auto')
    text = text.replace('local resolvfile localuse=0', 'local resolvfile resolvdir localuse=0')
    anchor = '\t\txappend "--resolv-file=$resolvfile"\n'
    if text.count(anchor) != 1:
        raise RuntimeError("unexpected dnsmasq resolver configuration")
    text = text.replace(anchor, anchor + '\t\tresolvdir="${resolvfile%/*}"\n')
    mount_anchor = '$dnsmasqconfdir $resolvfile $user_dhcpscript'
    if text.count(mount_anchor) != 1:
        raise RuntimeError("unexpected dnsmasq resolver jail mount")
    text = text.replace(mount_anchor, '$dnsmasqconfdir $resolvdir $user_dhcpscript')
    dnsmasq.write_text(text)


def patch_uhttpd_tcp_keepalive_contract(root: Path) -> None:
    """Keep the retained init script compatible with valued ``-A``.

    Current uhttpd interprets ``-A`` as a TCP keepalive interval in seconds.
    Some older control payloads treated the UCI setting as a boolean and
    emitted a bare option, causing getopt to consume the following option as
    its value.  Repair that exact legacy form while accepting the already
    compatible stock form used by the authenticated base image.
    """

    init = root / "etc/init.d/uhttpd"
    legacy = '\tappend_bool "$cfg" tcp_keepalive "-A" 0\n'
    valued = '\tappend_arg "$cfg" tcp_keepalive "-A"\n'
    text = init.read_text()
    legacy_count = text.count(legacy)
    valued_count = text.count(valued)
    if legacy_count == 1 and valued_count == 0:
        init.write_text(text.replace(legacy, valued))
    elif legacy_count != 0 or valued_count != 1:
        raise RuntimeError("unexpected uhttpd TCP keepalive init contract")


def replace_function(path: Path, name: str, replacement: str):
    text = path.read_text()
    pattern = rf"^{re.escape(name)}\(\)[ \t]*\{{\n.*?^\}}\n"
    updated, count = re.subn(
        pattern,
        replacement.rstrip() + "\n",
        text,
        flags=re.MULTILINE | re.DOTALL,
    )
    if count != 1:
        raise RuntimeError(f"expected one {name} function in {path}, found {count}")
    path.write_text(updated)


def remove_path(path: Path):
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink(missing_ok=True)


def validate_rc_whitelist(rc_dir: Path):
    """Reject any startup/shutdown link not explicitly owned by this image."""
    for path in sorted(rc_dir.iterdir()):
        if not path.name.startswith(("S", "K")):
            continue
        if not path.is_symlink():
            raise RuntimeError(f"non-symlink rc entry is not allowed: {path.name}")
        target = os.readlink(path)
        service = Path(target).name
        allowed = (
            ALLOWED_STARTUP_SERVICES
            if path.name.startswith("S")
            else ALLOWED_STOP_SERVICES
        )
        if service not in allowed:
            raise RuntimeError(
                f"rc entry is outside the local startup whitelist: "
                f"{path.name} -> {target}"
            )
        if target != f"../init.d/{service}":
            raise RuntimeError(
                f"rc entry has an unexpected target: {path.name} -> {target}"
            )


def replace_release_field(path: Path, key: str, old_value: str, new_value: str):
    replace_once(path, f'{key}="{old_value}"', f'{key}="{new_value}"')


def patch_qsdk_identity(root: Path):
    description = "SBE1V1K QSDK SPF12.2CUS2"

    release = root / "etc/openwrt_release"
    replace_once(
        release,
        "DISTRIB_DESCRIPTION='OpenWrt 19.07-SNAPSHOT r0+43-ac77edb2e'",
        f"DISTRIB_DESCRIPTION='{description}'",
    )

    os_release = root / "usr/lib/os-release"
    replace_release_field(
        os_release, "PRETTY_NAME", "OpenWrt 19.07-SNAPSHOT", description
    )
    replace_release_field(
        os_release,
        "OPENWRT_RELEASE",
        "OpenWrt 19.07-SNAPSHOT r0+43-ac77edb2e",
        description,
    )
    replace_release_field(
        os_release, "OPENWRT_DEVICE_MANUFACTURER", "OpenWrt", "Askey"
    )
    replace_release_field(
        os_release, "OPENWRT_DEVICE_PRODUCT", "Generic", "SBE1V1K"
    )

    device_info = root / "etc/device_info"
    replace_once(
        device_info, "DEVICE_MANUFACTURER='OpenWrt'", "DEVICE_MANUFACTURER='Askey'"
    )
    replace_once(
        device_info, "DEVICE_PRODUCT='Generic'", "DEVICE_PRODUCT='SBE1V1K'"
    )

    system_version = (root / "etc/system_version.info").read_text()
    if 'SDK_VERSION="SPF12.2CUS2"' not in system_version:
        raise RuntimeError("stock QSDK SDK_VERSION anchor is missing")


def patch_board_services(root: Path):
    # OpenSync PM used to consume this stock table.  The replacement policy
    # keeps the same thresholds, fan RPM and chain masks without OVSDB.
    pwm = root / "etc/config/pwm"
    pwm_bytes = pwm.read_bytes()
    pwm_sha256 = hashlib.sha256(pwm_bytes).hexdigest()
    if pwm_sha256 != "e152b6c7995e2563640bfd558d9fe2d6ebc28ade3871a5ecde503be41cddc2ea":
        raise RuntimeError(f"stock PWM configuration hash mismatch: {pwm_sha256}")
    pwm_text = pwm_bytes.decode()
    for token in (
        "option fan_rpm '4700'",
        "option radio_txchainmask '1,1,1,0,0'",
        "option tmp_cmd '/usr/sbin/askey_pwm.script temperature_cpu'",
    ):
        if token not in pwm_text:
            raise RuntimeError(f"stock PWM policy anchor is missing: {token}")

    thermald = root / "etc/thermal/thermald-9574.conf"
    thermal_text = thermald.read_text()
    if "[tsens_tz_sensor11]" not in thermal_text:
        raise RuntimeError("stock thermald sensor table anchor is missing")
    for sensor in range(12, 16):
        section = f"[tsens_tz_sensor{sensor}]"
        if section not in thermal_text:
            thermal_text += (
                f"\n{section}\n"
                "sampling         1000\n"
                "thresholds       125000\n"
                "thresholds_clr   120000\n"
                "actions          shutdown\n"
                "action_info      1000\n"
            )
    thermald.write_text(thermal_text)

    # This board exposes only GPIO54 as KEY_RESTART.  Remove generic QSDK WPS
    # handlers, including one which could erase an unrelated /overlay tree.
    for relative in (
        "etc/hotplug.d/button/50-button_reset_led",
        "etc/hotplug.d/button/50-wps",
        "etc/hotplug.d/button/51-wps-reset",
        "etc/hotplug.d/button/52-wps-supplicant",
        "etc/hotplug.d/button/54-wps-extender",
    ):
        remove_path(root / relative)

    # Retained multicast management uses a Linux bridge now that OVS userland
    # is gone.  qca_ovsmgr/openvswitch kernel modules stay as dependencies of
    # ECM, qca_mcs and the PPE bridge manager, but no OVS datapath is created.
    mcsd_hotplug = root / "etc/hotplug.d/iface/78-mcsd"
    replace_once(
        mcsd_hotplug,
        "ovs-vsctl br-exists $device >/dev/null 2>&1\n[ $? = 0 ] && mcsd_restart",
        '[ -n "$device" ] && [ -d "/sys/class/net/$device/bridge" ] && mcsd_restart',
    )

    boot_ftm = root / "etc/init.d/boot-ftm"
    replace_once(
        boot_ftm,
        "\tcp *openvswitch /etc/modules.d.ftm\n\tcp *qca-ovsmgr /etc/modules.d.ftm\n",
        "\t# OVS userland is removed; dependency modules load through ECM/PPE.\n",
    )

def patch_qsdk_wireless_driver_script(root: Path) -> None:
    """Initialize the QSDK wireless command before the Lithium stats hook."""
    script = root / "lib/wifi/qcawificfg80211.sh"
    old = '''\tcase "$board_name" in
\t\tap-hk*|ap-ac*|ap-cp*|ap-oak*|ap-mp*|*emu*|ap-al*|ap-sdx*|ap-mi*)
\t\techo "Disable ol_stats for Lithium platforms"
\t\t"$device_if" "$phy" enable_ol_stats 0
\t;;
\t\t*) echo "ol_stats is disabled for non-Lithium platforms"
\t;;
\tesac

\t# in MBSS case, send notification to allow deletion of transmitting VAP
\tconfig_get device_if "$device" device_if "cfg80211tool"
'''
    new = '''\tconfig_get device_if "$device" device_if "cfg80211tool"
\tcase "$board_name" in
\t\tap-hk*|ap-ac*|ap-cp*|ap-oak*|ap-mp*|*emu*|ap-al*|ap-sdx*|ap-mi*)
\t\techo "Disable ol_stats for Lithium platforms"
\t\t"$device_if" "$phy" enable_ol_stats 0
\t;;
\t\t*) echo "ol_stats is disabled for non-Lithium platforms"
\t;;
\tesac

\t# in MBSS case, send notification to allow deletion of transmitting VAP
'''
    replace_once(script, old, new)


def patch_embedded_wifi_source(root: Path) -> None:
    """Use the vendor Wi-Fi files paired with the verified release kernel."""
    if not (root / "usr/share/sbe-build/vendor-wifi-source").is_file():
        return
    script = root / "etc/init.d/wifi_fw_mount"
    replace_once(
        script,
        '\tmkdir -p /lib/firmware/$arch/WIFI_FW\n\tif [ -n "$emmc_part" ]; then',
        '\t# Keep the kernel-matched firmware in the immutable rootfs.\n'
        '\t# Leave WIFIFW and device-specific calibration partitions untouched.\n'
        '\tif [ "$arch" = IPQ9574 ]; then\n'
        '\t\t[ -r /usr/share/sbe-build/vendor-wifi-source ] && '
        '[ -f /usr/share/sbe-wififw/qcn9224/amss.bin ] || return 1\n'
        '\t\temmc_part= nor_flash= nand_part=\n'
        '\tfi\n'
        '\tmkdir -p /lib/firmware/$arch/WIFI_FW\n'
        '\tif [ -n "$emmc_part" ]; then',
    )


def patch_local_service_policy(root: Path):
    patch_dnsmasq_resolver_migration(root)
    patch_netifd_resolver(root)
    patch_dnsmasq_runtime_resolver(root)
    patch_uhttpd_tcp_keepalive_contract(root)

    # The factory image starts Bluetooth, Thread/MG21/PTA, conntrackd and an
    # LLDP daemon even though the replacement UI has no local management plane
    # for them.  Their rc links are removed separately; discard unsafe default
    # state as well.  In particular, the stock LLDP configuration advertises a
    # fictitious physical address and enables four unrelated discovery dialects.
    for relative in (
        "etc/config/btagent",
        "etc/config/lldpd",
        "etc/lldpd.d",
        "etc/modules.d/bluetooth",
        "etc/init.d/lldpd",
        "etc/hotplug.d/ntp",
        "lib/preinit/81_urandom_seed",
        "etc/init.d/urandom_seed",
        "sbin/urandom_seed",
        "etc/urandom.seed",
    ):
        remove_path(root / relative)

    # Replace the opaque Qualcomm time service with native QSDK sysntpd.
    # sysfixtime remains responsible for initial RTC restoration.
    remove_path(root / "etc/init.d/time-services")
    replace_once(
        root / "etc/init.d/sysfixtime",
        "\t\t# try to check /usr/askey folder as it has "
        "/usr/askey/persist/opensync-default\n",
        "\t\t# fall back to immutable board files when /data has no timestamp\n",
    )

    # Native logd owns the daily image's log controls. Do not override the
    # administrator's file path, transport or buffer settings here.

    root_cron = root / "etc/crontabs/root"
    active_root_cron = {
        line.strip()
        for line in root_cron.read_text().splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }
    expected_root_cron = {
        "0 1 * * *  /etc/init.d/process_crash_dump start",
    }
    logrotate_jobs = {
        "*/15 * * * * logrotate /etc/logrotate.conf -s /tmp/log/logrotate.status",
        "*/5 * * * * logrotate /etc/logrotate.conf -s /tmp/log/logrotate.status",
    }
    if len(active_root_cron & logrotate_jobs) != 1 or active_root_cron - logrotate_jobs != expected_root_cron:
        raise RuntimeError("unexpected factory root cron job")

    operator_cron = root / "etc/crontabs/operator"
    if operator_cron.exists():
        active_operator_cron = {
            line.strip()
            for line in operator_cron.read_text().splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }
        if active_operator_cron != {
            "*/15 * * * * logrotate /etc/logrotate.conf -s /tmp/log/logrotate.status"
        }:
            raise RuntimeError("unexpected factory operator cron job")
        remove_path(operator_cron)
    root_cron.write_text(
        "# Periodic local services are supervised by procd; no cloud jobs.\n"
    )

    # This image does not use JFFS2/overlayfs for configuration.  The stock
    # command can erase unrelated storage, so leave an explicit hard failure
    # for both jffs2reset and its jffs2mark symlink.
    jffs2reset = root / "sbin/jffs2reset"
    remove_path(jffs2reset)
    jffs2reset.write_text(
        "#!/bin/sh\n"
        "echo 'jffs2reset is disabled: SBE1V1K uses /data/openwrt.' >&2\n"
        "exit 1\n"
    )
    jffs2reset.chmod(0o755)
    jffs2mark = root / "sbin/jffs2mark"
    remove_path(jffs2mark)
    jffs2mark.symlink_to("jffs2reset")


def prune_operator_payloads(root: Path):
    # Remove operator/cloud payloads while retaining all QCA/SSDK/NSS board
    # executors, including askey_pwm, thermaltool and the kernel dependency
    # modules openvswitch.ko/qca-ovsmgr.ko.
    paths = (
        "etc/config/minidump",
        "etc/httpd.conf",
        "etc/hotplug.d/dump_q6v5",
        "etc/hotplug.d/dump",
        "etc/hotplug.d/minidump",
        "etc/hotplug.d/iface/70-quagga",
        "etc/init.d/inetd",
        "etc/init.d/update_passwd",
        "etc/init.d/healthcheck",
        "etc/init.d/cpcd",
        "etc/init.d/otbr-agent",
        "etc/init.d/quagga",
        "etc/lighttpd",
        "etc/local/certs",
        "etc/pairing",
        "etc/quagga",
        "etc/sign",
        "etc/uhttpd.crt",
        "etc/uhttpd.key",
        "lib/modules/5.4.213/ecm_ovs.ko",
        "lib/modules/5.4.213/nflua.ko",
        "opt/cujo",
        "opt/samknows",
        "opt/._samknows",
        "usr/cujo",
        "usr/etc/sstorage.acl",
        "usr/lib/lighttpd",
        "usr/opensync",
        "usr/sbin/lighttpd",
        "usr/sbin/sstorage",
        "usr/bin/socat",
        "etc/init.d/syslog-ng",
        "etc/syslog-ng.conf",
        "etc/syslog-ng_hostname.sh",
        "etc/syslog-ng.d",
        "lib/upgrade/keep.d/syslog-ng",
        "usr/lib/syslog-ng",
        "usr/share/syslog-ng",
        "sbin/restart_webservice.sh",
        "sbin/modecheck.sh",
        # The only stock caller was libopensync.so.  Its reachable MAP-T
        # branches invoke nfm_ip[46]tables.sh under the removed OpenSync tree,
        # so retaining this orphan would preserve an unusable operator path.
        "sbin/mapctrol",
        "sbin/mf_tool_old",
        "sbin/ftm_qcc710_start",
        "usr/share/openvswitch",
        "usr/sbin/askey_fan",
        "usr/sbin/askey_pwm.init",
        "usr/sbin/askey_pwm.test",
        "usr/sbin/diag_flash_logger",
        "usr/sbin/diag_socket_app",
        "usr/sbin/diag_stress_app",
        "usr/sbin/ftpd",
        "usr/sbin/ftm",
        "usr/sbin/inetd",
        "usr/sbin/license-pfm-upgrade.sh",
        "usr/sbin/myftm",
        "usr/sbin/quagga.init",
        "usr/sbin/registerReboot",
        "usr/sbin/ripd",
        "usr/sbin/veriWaveTestCommands.sh",
        "usr/sbin/watchquagga",
        "usr/sbin/wlanfw-upgrade.sh",
        # OpenSync wano watchdog proxy.  Its init script is removed and it has
        # no remaining caller, but the binary can still control watchdog0.
        "usr/sbin/wpd",
        "usr/sbin/zebra",
        "usr/bin/auto_burn_fw.sh",
        "usr/bin/ble_upgrade",
        "usr/bin/bootloader_upgrade",
        "usr/bin/cpcapp",
        "usr/bin/cpcd",
        "usr/bin/qdss_setup.sh",
        "usr/bin/rcp_upgrade",
        "usr/bin/se_upgrade",
        "usr/bin/thread_upgrade",
        "usr/bin/vtysh",
        "usr/etc/cpcd.conf",
        "usr/local/firmware/ncp_empty_2.gbl",
        "usr/local/firmware/thread_test.gbl",
        "usr/askey/inter_cert.pem",
        "usr/askey/inter_cert_7300.pem",
        "usr/askey/server_cert.pem",
        "usr/askey/server_rsakey.pem",
        "usr/askey/tlshandshake-start-testserver",
        "usr/askey/tlshandshake-verifier",
        "usr/askey/sbin/JWS_getcert.py",
        "usr/askey/sbin/JWS_getib.py",
        "usr/askey/sbin/JWS_getibjson.py",
        "usr/askey/sbin/JWS_verify.py",
        "usr/askey/sbin/debugCert_verify",
        "usr/askey/sbin/install_pki.sh",
        "usr/askey/sbin/secure_key",
        "usr/askey/sbin/verifyblob",
        "usr/lib/lua/luci/controller/admin/thread.lua",
        "usr/lib/lua/luci/view/admin_thread",
        "usr/sbin/cpc_hci_bridge",
        "usr/sbin/encrypt_client_app",
        "usr/sbin/ot-ctl",
        "usr/sbin/otbr-agent",
        "www/luci-static/resources/handle_error.js",
    )
    for relative in paths:
        remove_path(root / relative)

    # Bluetooth/Thread operator onboarding has no replacement management
    # plane in this image.  Besides being dormant, the stock CPC/OpenThread
    # payload embeds public test keys and vendor workstation paths.  Remove the
    # complete userland/firmware stack rather than silently exempting it.
    for library in (root / "usr/lib").glob("libcpc.so*"):
        remove_path(library)

    # Python package tests are not runtime dependencies.  The factory ecdsa
    # bytecode includes complete public EC private-key test vectors, which
    # must never be mistaken for acceptable key material in a release image.
    for python_root in (root / "usr/lib").glob("python*/site-packages/ecdsa"):
        for test_asset in python_root.glob("test_*.py*"):
            remove_path(test_asset)

    for relative in (
        "usr/bin/ovs-appctl",
        "usr/bin/ovs-dpctl",
        "usr/bin/ovs-ofctl",
        "usr/bin/ovs-vsctl",
        "usr/bin/ovsdb-client",
        "usr/bin/ovsdb-tool",
        "usr/sbin/ovs-vswitchd",
        "usr/sbin/ovsdb-server",
        "usr/sbin/ovsh",
        "usr/lib/libopenvswitch-2.12.so.0",
        "usr/lib/libopenvswitch-2.12.so.0.0.0",
        "usr/lib/libopenvswitch.so",
        "usr/lib/libovsdb-2.12.so.0",
        "usr/lib/libovsdb-2.12.so.0.0.0",
        "usr/lib/libovsdb.so",
        "usr/lib/libofproto-2.12.so.0",
        "usr/lib/libofproto-2.12.so.0.0.0",
        "usr/lib/libofproto.so",
        "usr/lib/libsflow-2.12.so.0",
        "usr/lib/libsflow-2.12.so.0.0.0",
        "usr/lib/libsflow.so",
        "usr/lib/libmosquitto.so",
        "usr/lib/libmosquitto.so.1",
        "usr/lib/opkg/info/cujo-luapermission.control",
        "usr/lib/opkg/info/libmosquitto-ssl.control",
        "usr/bin/dqtool",
        "usr/bin/loggen",
        "usr/bin/pdbtool",
        "usr/bin/persist-tool",
        "usr/bin/slogencrypt",
        "usr/bin/slogkey",
        "usr/bin/slogverify",
        "usr/bin/update-patterndb",
        "usr/man/man1/dqtool.1",
        "usr/man/man1/loggen.1",
        "usr/man/man1/pdbtool.1",
        "usr/man/man1/persist-tool.1",
        "usr/man/man1/slogencrypt.1",
        "usr/man/man1/slogkey.1",
        "usr/man/man1/slogverify.1",
        "usr/man/man1/syslog-ng-ctl.1",
        "usr/man/man1/syslog-ng-debun.1",
        "usr/man/man5/syslog-ng.conf.5",
        "usr/man/man7/secure-logging.7",
        "usr/man/man8/syslog-ng.8",
    ):
        remove_path(root / relative)

    for module_config in (root / "etc/modules.d").glob("*ecm-ovs*"):
        remove_path(module_config)
    for module_config in (root / "etc/modules.d").glob("*nflua*"):
        remove_path(module_config)
    for syslog_ng in (root / "usr/lib").glob("libsyslog-ng*"):
        remove_path(syslog_ng)
    for syslog_ng in (root / "usr/sbin").glob("syslog-ng*"):
        remove_path(syslog_ng)
    for syslog_ng in (
        "libevtlog*",
        "libloggen_helper*",
        "libloggen_plugin*",
        "libsecret-storage*",
    ):
        for library in (root / "usr/lib").glob(syslog_ng):
            remove_path(library)
    for zebra in (root / "usr/lib").glob("libzebra*"):
        remove_path(zebra)

    submodules = root / "etc/submodule_version.info"
    submodule_lines = [
        line
        for line in submodules.read_text().splitlines()
        if "feeds/cujo" not in line
    ]
    submodules.write_text("\n".join(submodule_lines) + "\n")
    for apple_double in root.rglob("._*"):
        remove_path(apple_double)


def prune_web_root(root: Path):
    www = root / "www"
    allowed_top = {"cgi-bin", "index.html", "luci-static"}
    for path in www.iterdir():
        if path.name not in allowed_top:
            remove_path(path)

    cgi = www / "cgi-bin"
    allowed_cgi = {
        "cgi-backup",
        "cgi-exec",
        "cgi-upload",
        "luci",
    }
    for path in cgi.iterdir():
        if path.name not in allowed_cgi:
            remove_path(path)

    index = www / "index.html"
    if not (cgi / "luci").is_file() or not (www / "luci-static").is_dir():
        raise RuntimeError("LuCI web root is incomplete after pruning")
    index_text = index.read_text()
    if "cgi-bin/luci" not in index_text or "warehouse" in index_text.lower():
        raise RuntimeError("unexpected index.html after LuCI web-root pruning")


def harden_luci_untrusted_tables(root: Path) -> None:
    """Render LAN-controlled lease and UPnP strings as text, never HTML.

    The retained LuCI 2022 table helper interprets a bare string cell as
    ``innerHTML``.  DHCP hostnames and UPnP descriptions are supplied by
    unauthenticated LAN peers, so patch only those dynamic cells to DOM text
    nodes while leaving intentionally constructed static markup unchanged.
    """

    status_dhcp = (
        root
        / "www/luci-static/resources/view/status/include/40_dhcp.js"
    )
    replace_once(
        status_dhcp,
        "return[lease.hostname||'-',lease.ipaddr,lease.macaddr,exp];",
        "return[document.createTextNode(lease.hostname||'-'),"
        "document.createTextNode(lease.ipaddr||'-'),"
        "document.createTextNode(lease.macaddr||'-'),exp];",
    )
    replace_once(
        status_dhcp,
        "return[host||'-',lease.ip6addrs?lease.ip6addrs.join(' '):"
        "lease.ip6addr,lease.duid,exp];",
        "return[document.createTextNode(host||'-'),"
        "document.createTextNode((lease.ip6addrs?lease.ip6addrs.join(' '):"
        "lease.ip6addr)||'-'),document.createTextNode(lease.duid||'-'),exp];",
    )

    network_dhcp = root / "www/luci-static/resources/view/network/dhcp.js"
    replace_once(
        network_dhcp,
        "return[lease.hostname||'?',lease.ipaddr,lease.macaddr,exp];",
        "return[document.createTextNode(lease.hostname||'?'),"
        "document.createTextNode(lease.ipaddr||'-'),"
        "document.createTextNode(lease.macaddr||'-'),exp];",
    )
    replace_once(
        network_dhcp,
        "return[host||'-',lease.ip6addrs?lease.ip6addrs.join(' '):"
        "lease.ip6addr,lease.duid,exp];",
        "return[document.createTextNode(host||'-'),"
        "document.createTextNode((lease.ip6addrs?lease.ip6addrs.join(' '):"
        "lease.ip6addr)||'-'),document.createTextNode(lease.duid||'-'),exp];",
    )

    upnp_status = root / "usr/lib/lua/luci/view/upnp_status.htm"
    replace_once(
        upnp_status,
        'st[i].host_hint || "<%:Unknown%>",',
        'document.createTextNode(st[i].host_hint || "<%:Unknown%>"),',
    )
    replace_once(
        upnp_status,
        "\t\t\t\t\t\tst[i].descr,\n",
        "\t\t\t\t\t\tdocument.createTextNode(st[i].descr || ''),\n",
    )


def repair_luci_firewall_strict_mode(root: Path) -> None:
    """Keep the retained firewall summary renderers valid in strict mode.

    The locked LuCI package assigns to ``m`` without declaring it in three
    ``rule_proto_txt()`` helpers.  Every file starts with ``'use strict'``, so
    rendering the first configured rule raises ``ReferenceError``.  Declare
    the first assignment locally; the later reassignments then use the same
    function-scoped variable without changing firewall or UCI semantics.
    """

    helpers = (
        "www/luci-static/resources/view/firewall/rules.js",
        "www/luci-static/resources/view/firewall/forwards.js",
    )
    for relative in helpers:
        path = root / relative
        replace_once(
            path,
            ");m=String(uci.get('firewall',s,'helper')||'').match(",
            ");var m=String(uci.get('firewall',s,'helper')||'').match(",
        )

    snats = root / "www/luci-static/resources/view/firewall/snats.js"
    replace_once(
        snats,
        ");m=String(uci.get('firewall',s,'mark')).match(",
        ");var m=String(uci.get('firewall',s,'mark')).match(",
    )


def component_profile_has_rrdns(profile_path: Optional[Path]) -> bool:
    """Return whether the production profile selects the canonical rrdns module."""

    if profile_path is None:
        return False
    try:
        profile = json.loads(profile_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"cannot inspect component profile for rrdns: {error}")
    if not isinstance(profile, dict):
        raise RuntimeError("component profile for rrdns is not a JSON object")
    packages = profile.get("packages")
    if not isinstance(packages, list):
        raise RuntimeError("component profile packages are not a list")
    for package in packages:
        if not isinstance(package, dict) or package.get("name") != "rpcd-mod-rrdns":
            continue
        if package.get("candidate_paths") != ["/usr/lib/rpcd/rrdns.so"]:
            raise RuntimeError(
                "rpcd-mod-rrdns profile entry does not own exactly its canonical SO"
            )
        return True
    return False


def harden_luci_status_views(root: Path, *, rrdns_available: bool = False) -> None:
    """Keep daemon- and LAN-derived status strings out of HTML sinks.

    LuCI 2022 deliberately interprets a scalar passed to ``E()`` or
    ``cbi_update_table()`` as HTML.  Preserve the few intentional markup
    fragments, but turn host hints and process metadata into DOM text nodes
    and HTML-encode the variable parts of the legacy iptables markup.
    """

    wifi_status = (
        root
        / "www/luci-static/resources/view/status/include/60_wifi.js"
    )
    replace_once(
        wifi_status,
        "var hint;if(name&&ipv4&&ipv6)\n"
        "hint='%s <span class=\"hide-xs\">(%s, %s)</span>'.format(name,ipv4,ipv6);"
        "else if(name&&(ipv4||ipv6))\n"
        "hint='%s <span class=\"hide-xs\">(%s)</span>'.format(name,ipv4||ipv6);"
        "else\n"
        "hint=name||ipv4||ipv6||'?';",
        "var hint=E('span',{},[name||ipv4||ipv6||'?']);"
        "if(name&&(ipv4||ipv6))\n"
        "hint.appendChild(E('span',{'class':'hide-xs'},"
        "[' (',ipv4||'',ipv4&&ipv6?', ':'',ipv6||'',')']));",
    )
    replace_once(
        wifi_status,
        "]),bss.mac,hint,E('span',",
        "]),document.createTextNode(String(bss.mac||'')),hint,E('span',",
    )

    processes = root / "www/luci-static/resources/view/status/processes.js"
    replace_once(
        processes,
        "rows.push([proc.PID,proc.USER,proc.COMMAND,proc['%CPU'],proc['%MEM'],",
        "rows.push([proc.PID,document.createTextNode(String(proc.USER||'')),"
        "document.createTextNode(String(proc.COMMAND||'')),proc['%CPU'],proc['%MEM'],",
    )

    # luci.sys from the selected 2022 package parses the historic BusyBox top
    # format.  The audited BusyBox 1.37 build enables decimal percentages and
    # FEATURE_TOP_SMP_PROCESS, adding a CPU-number column.  Accept both layouts
    # and normalize the decimal values to the strings expected by LuCI.
    luci_sys = root / "usr/lib/lua/luci/sys.lua"
    replace_once(
        luci_sys,
        '''function process.list()
	local data = {}
	local k
	local ps = luci.util.execi("/bin/busybox top -bn1")

	if not ps then
		return
	end

	for line in ps do
		local pid, ppid, user, stat, vsz, mem, cpu, cmd = line:match(
			"^ *(%d+) +(%d+) +(%S.-%S) +([RSDZTW][<NW ][<N ]) +(%d+m?) +(%d+%%) +(%d+%%) +(.+)"
		)

		local idx = tonumber(pid)
		if idx and not cmd:match("top %-bn1") then
			data[idx] = {
				['PID']     = pid,
				['PPID']    = ppid,
				['USER']    = user,
				['STAT']    = stat,
				['VSZ']     = vsz,
				['%MEM']    = mem,
				['%CPU']    = cpu,
				['COMMAND'] = cmd
			}
		end
	end

	return data
end''',
        '''function process.list()
	local data = {}
	local ps = luci.util.execi("/bin/busybox top -bn1")

	if not ps then
		return {}
	end

	for line in ps do
		local pid, ppid, user, stat, vsz, rest = line:match(
			"^%s*(%d+)%s+(%d+)%s+(%S+)%s+([RSDZTWI][<NW]*)%s+(%S+)%s+(.+)"
		)
		local mem, cpu, cmd

		if pid then
			-- BusyBox with FEATURE_TOP_SMP_PROCESS: %VSZ, CPU, %CPU.
			mem, cpu, cmd = rest:match("^(%S+)%s+%d+%s+(%S+)%s+(.+)$")
			if not mem then
				-- Historic layout without the CPU-number column.
				mem, cpu, cmd = rest:match("^(%S+)%s+(%S+)%s+(.+)$")
			end
		end

		local idx = tonumber(pid)
		if idx and mem and cpu and cmd and not cmd:match("top %-bn1") then
			if not mem:match("%%$") then mem = mem .. "%" end
			if not cpu:match("%%$") then cpu = cpu .. "%" end
			data[idx] = {
				['PID']     = pid,
				['PPID']    = ppid,
				['USER']    = user,
				['STAT']    = stat,
				['VSZ']     = vsz,
				['%MEM']    = mem,
				['%CPU']    = cpu,
				['COMMAND'] = cmd
			}
		end
	end

	return data
end''',
    )

    iptables = root / "www/luci-static/resources/view/status/iptables.js"
    replace_once(
        iptables,
        "format(_('Chain'),chain,_('Policy'),policy,packets,",
        "format(_('Chain'),'%h'.format(chain),_('Policy'),'%h'.format(policy),packets,",
    )
    replace_once(
        iptables,
        "format(_('Chain'),chain,references,_('References'));",
        "format(_('Chain'),'%h'.format(chain),references,_('References'));",
    )
    replace_once(
        iptables,
        "target?'<span class=\"target\">%s</span>'.format(target):'-',"
        "proto,(indev!=='*')?'<span class=\"ifacebadge\">%s</span>'.format(indev):'*',"
        "(outdev!=='*')?'<span class=\"ifacebadge\">%s</span>'.format(outdev):'*',"
        "srcnet,dstnet,options,[comment]",
        "target?'<span class=\"target\">%s</span>'.format('%h'.format(target)):'-',"
        "[proto],(indev!=='*')?'<span class=\"ifacebadge\">%s</span>'.format('%h'.format(indev)):'*',"
        "(outdev!=='*')?'<span class=\"ifacebadge\">%s</span>'.format('%h'.format(outdev)):'*',"
        "[srcnet],[dstnet],[options],[comment]",
    )

    # The immutable base has no trusted reverse-DNS module, so keep its
    # connection table numeric-only. A RAM profile which owns the exact
    # canonical rpcd module retains LuCI's bounded queue and opt-in button;
    # the component applicator then hash-verifies that module.
    connections = root / "www/luci-static/resources/view/status/connections.js"
    if not rrdns_available:
        replace_once(
            connections,
            "var callNetworkRrdnsLookup=rpc.declare({object:'network.rrdns',"
            "method:'lookup',params:['addrs','timeout','limit'],expect:{'':{}}});",
            "var callNetworkRrdnsLookup=function(){return Promise.resolve({});};",
        )
        connections_text = connections.read_text()
        connections_text, lookup_branch_count = re.subn(
            r"if\(enableLookups&&lookup_queue\.length>0\)\{.*?"
            r"var btn=document\.querySelector\('\.btn\.toggle-lookups'\);.*?\}\}\);\}",
            "",
            connections_text,
            count=1,
            flags=re.S,
        )
        if lookup_branch_count != 1:
            raise RuntimeError("unexpected LuCI connections reverse-DNS branch")
        connections.write_text(connections_text)
        replace_once(
            connections,
            "E('div',{'class':'right'},[E('button',{'class':'btn toggle-lookups',"
            "'click':function(ev){if(!enableLookups){ev.currentTarget.classList.add('spinning');"
            "ev.currentTarget.disabled=true;enableLookups=true;}\n"
            "else{ev.currentTarget.firstChild.data=_('Enable DNS lookups');enableLookups=false;}\n"
            "this.blur();}},[enableLookups?_('Disable DNS lookups'):_('Enable DNS lookups')])]),"
            "E('br'),",
            "E('div',{'class':'right'},[E('small',{},[_('Numeric addresses only')])]),"
            "E('br'),",
        )


def harden_luci_logging_and_headers(root: Path) -> None:
    """Bound log fields and add browser containment compatible with old LuCI."""

    dispatcher = root / "usr/lib/lua/luci/dispatcher.lua"
    replace_once(
        dispatcher,
        "local function session_setup(user, pass)\n",
        '''local function sanitize_log_field(value)
\tvalue = tostring(value or "?")
\tvalue = value:gsub("[%z\\1-\\31\\127]", function(byte)
\t\treturn string.format("\\\\x%02x", string.byte(byte))
\tend)
\treturn value:sub(1, 256)
end

local function session_setup(user, pass)
''',
    )
    dispatcher_text = dispatcher.read_text()
    unsafe_log_args = (
        '%{ rp, user or "?", http.getenv("REMOTE_ADDR") or "?" })'
    )
    if dispatcher_text.count(unsafe_log_args) != 2:
        raise RuntimeError("unexpected LuCI login log argument count")
    safe_log_args = (
        "%{ sanitize_log_field(rp), sanitize_log_field(user), "
        'sanitize_log_field(http.getenv("REMOTE_ADDR")) })'
    )
    dispatcher.write_text(dispatcher_text.replace(unsafe_log_args, safe_log_args))

    http = root / "usr/lib/lua/luci/http.lua"
    replace_once(
        http,
        '''\t\t\tif not context.headers["x-content-type-options"] then
\t\t\t\theader("X-Content-Type-Options", "nosniff")
\t\t\tend

\t\t\tcontext.eoh = true
''',
        '''\t\t\tif not context.headers["x-content-type-options"] then
\t\t\t\theader("X-Content-Type-Options", "nosniff")
\t\t\tend
\t\t\tif not context.headers["referrer-policy"] then
\t\t\t\theader("Referrer-Policy", "no-referrer")
\t\t\tend
\t\t\tif not context.headers["permissions-policy"] then
\t\t\t\theader("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=()")
\t\t\tend
\t\t\tif not context.headers["content-security-policy"] then
\t\t\t\t-- The 2022 LuCI module loader needs inline code and eval.  The
\t\t\t\t-- remaining directives still block cross-origin resources,
\t\t\t\t-- plugins, framing and cross-origin form submission.
\t\t\t\theader("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'")
\t\t\tend

\t\t\tcontext.eoh = true
''',
    )


def harden_luci_management_capabilities(root: Path) -> None:
    """Validate that the standard LuCI management pages remain available.

    Board compatibility belongs in the service/RPC backends.  Do not replace,
    rename or prune native LuCI pages here: doing so made ordinary controls
    disappear and caused the frontend to diverge from the QSDK LuCI API.
    """

    menu_path = root / "usr/share/luci/menu.d/luci-mod-system.json"
    menu = json.loads(menu_path.read_text())
    startup_entry = menu.get("admin/system/startup")
    if not startup_entry or startup_entry.get("action", {}).get("path") != "system/startup":
        raise RuntimeError("native LuCI startup menu entry was not found")
    mounts_entry = menu.get("admin/system/mounts")
    if (
        not mounts_entry
        or mounts_entry.get("action", {}).get("path") != "system/mounts"
    ):
        raise RuntimeError("LuCI removable-storage menu entry was not found")
    leds_entry = menu.get("admin/system/leds")
    if not leds_entry or leds_entry.get("action", {}).get("path") != "system/leds":
        raise RuntimeError("LuCI generic LED menu entry was not found")
    flash_entry = menu.get("admin/system/flash")
    if not flash_entry or flash_entry.get("action", {}).get("path") != "system/flash":
        raise RuntimeError("LuCI backup/restore menu entry was not found")
    for relative in (
        "network/diagnostics.js",
        "system/dropbear.js",
        "system/flash.js",
        "system/leds.js",
        "system/mounts.js",
        "system/sshkeys.js",
        "system/startup.js",
        "system/system.js",
    ):
        view = root / "www/luci-static/resources/view" / relative
        if not view.is_file():
            raise RuntimeError(f"native LuCI view is missing: {relative}")

    # The stock LuCI handler starts fs.exec() without awaiting it and begins
    # probing the still-live current address immediately.  On a fast LAN this
    # reloads the page before rpcd has dispatched sysupgrade, so the flashing
    # modal disappears while no upgrade was started.  Wait for the command to
    # return (or for the expected connection loss), and surface a synchronous
    # sysupgrade error instead of silently reloading.
    flash_view = root / "www/luci-static/resources/view/system/flash.js"
    flash_text = flash_view.read_text()
    old_upgrade_handler = """opts.push('--force');opts.push('/tmp/firmware.bin');fs.exec('/sbin/sysupgrade',opts);if(keep.checked)
ui.awaitReconnect(window.location.host);else
ui.awaitReconnect('192.168.1.1','openwrt.lan');"""
    new_upgrade_handler = """opts.push('--force');opts.push('/tmp/firmware.bin');var reconnect=function(){if(keep.checked)
return ui.awaitReconnect(window.location.host);return ui.awaitReconnect('192.168.1.1','openwrt.lan');};return fs.exec('/sbin/sysupgrade',opts).then(function(res){if(res.code!=0){ui.showModal(_('Sysupgrade failed'),[E('p',_('The sysupgrade command failed with code %d').format(res.code)),res.stderr?E('pre',{},[res.stderr]):'',E('div',{'class':'right'},[E('button',{'class':'btn','click':ui.hideModal},[_('Dismiss')])])]);return;}return reconnect();},reconnect);"""
    if flash_text.count(old_upgrade_handler) != 1:
        raise RuntimeError("native LuCI sysupgrade confirmation handler changed")
    flash_view.write_text(flash_text.replace(old_upgrade_handler, new_upgrade_handler))

    acl_path = root / "usr/share/rpcd/acl.d/luci-base.json"
    acl = json.loads(acl_path.read_text())
    access = acl.get("luci-access", {})
    if "download" not in access.get("read", {}).get("cgi-io", []):
        raise RuntimeError("native LuCI download capability is missing")
    if "setInitAction" not in access.get("write", {}).get("ubus", {}).get("luci", []):
        raise RuntimeError("native LuCI service-control capability is missing")
    if access.get("write", {}).get("file", {}).get("/tmp/upload.ipk") != ["write"]:
        raise RuntimeError("native LuCI package-upload capability is missing")


def patch_partition_mount_policy(
    preinit: Path, rootfs_data_label: str, trial_safe: bool
):
    # Stock/operator-owned partitions are never part of the replacement
    # management plane.  Keep them read-only even after installation; only the
    # dedicated rootfs_data_1 namespace below is writable.
    shared_options = "ro,noload"

    replace_function(
        preinit,
        "do_mount_log_partition",
        f'''do_mount_log_partition() {{
\tgrep -wqs log /sys/class/ubi/ubi1/ubi1_*/name && {{
\t\tmkdir -p /usr/askey/log
\t\tmount -t ubifs -o {shared_options} ubi1:log /usr/askey/log
\t\treturn
\t}}

\tlocal emmcblock="$(find_mmc_part "log")"
\t[ -e "$emmcblock" ] || return 1
\tmkdir -p /usr/askey/log
\tmount -t ext4 -o {shared_options} "$emmcblock" /usr/askey/log
}}''',
    )


def install_authentication_defaults(root: Path) -> None:
    """Ship normal account files; the selected root overlay owns persistence.

    The vendor's /tmp account databases were populated on every boot. Keeping
    those symlinks silently loses passwords on a clean installed system, even
    though a keep-config upgrade can hide the problem by restoring regular
    files. These are image defaults only, never a runtime password reset.
    """
    accounts = {
        "passwd": """root:x:0:0:root:/root:/bin/ash
nobody:*:65534:65534:nobody:/var:/bin/false
ntp:x:123:123:ntp:/var/run/ntp:/bin/false
dnsmasq:x:453:453:dnsmasq:/var/run/dnsmasq:/bin/false
unbound:x:65537:65537:unbound:/var/run/unbound:/bin/false
""",
        "shadow": """root:::0:99999:7:::
nobody:*:0:0:99999:7:::
ntp:x:0:0:99999:7:::
dnsmasq:x:0:0:99999:7:::
unbound:x:0:0:99999:7:::
""",
        "group": """root:x:0:
nobody:x:65534:
ntp:x:123:ntp
dnsmasq:x:453:dnsmasq
unbound:x:65537:unbound
dialout:x:20:
audio:x:29:
nogroup:x:5:
""",
    }
    for name, content in accounts.items():
        path = root / "etc" / name
        if path.is_symlink():
            if os.readlink(path) != f"/tmp/etc/{name}":
                raise RuntimeError(f"unexpected vendor account link: {name}")
            path.unlink()
        path.write_text(content, encoding="utf-8")
        path.chmod(0o600 if name == "shadow" else 0o644)


def patch_management_plane(
    root: Path,
    preinit: Path,
    rootfs_data_label: str,
    trial_safe: bool,
    rrdns_available: bool = False,
):
    shared_options = "ro,noload"
    # Expose the full QSDK iproute2 binary at OpenWrt's standard path. This
    # keeps the native routes view and command ACL unchanged.
    ip_command = root / "sbin/ip"
    if not (ip_command.exists() or ip_command.is_symlink()):
        ip_command.symlink_to("../usr/sbin/ip")
    defaults = root / "lib/preinit/01_default_configs"
    replace_once(defaults, "\tcreate_rw_overlay etc/config\n", "")
    install_authentication_defaults(root)
    replace_function(
        defaults,
        "create_default_files",
        '''create_default_files() {
[ -d /tmp/etc ] || mkdir -p /tmp/etc
mkdir -p /tmp/etc/modules.d/
cat > /tmp/etc/modules.d/nf-nathelper-extra <<EOF
nf_conntrack_amanda
nf_conntrack_broadcast
nf_conntrack_h323
nf_conntrack_irc
nf_conntrack_pptp
nf_conntrack_sip
nf_conntrack_snmp
nf_conntrack_tftp
nf_nat_amanda
nf_nat_h323
nf_nat_irc
nf_nat_pptp
nf_nat_sip
nf_nat_snmp_basic
nf_nat_tftp
EOF

cat > /tmp/etc/modules.d/ipt-nathelper-rtsp <<EOF
nf_conntrack_rtsp
nf_nat_rtsp
EOF
}''',
    )

    boot = root / "etc/init.d/boot"
    text = boot.read_text()
    text, stale_plume_comments = re.subn(
        r"\n\s*#\. /lib/plume_functions\.sh\n"
        r"\s*#echo -e \"plume\\nplume\\n\" \| /usr/bin/passwd plume\n",
        "\n",
        text,
    )
    if stale_plume_comments != 1:
        raise RuntimeError("stock Plume password comment block changed unexpectedly")
    if text.count("ovs_enabled=1") != 2:
        raise RuntimeError("unexpected qca-nss-bridge-mgr policy in stock boot script")
    boot.write_text(text.replace("ovs_enabled=1", "ovs_enabled=0"))
    replace_function(boot, "del_osync_for_upgrade", "")
    replace_function(boot, "del_plume_for_upgrade", "")
    text = boot.read_text()
    text, count = re.subn(
        r"\n\s*#PIR-9117 create copy of password in tmpfs\n"
        r"\s*cp /etc/shadow\.orig /tmp/shadow\n",
        "\n",
        text,
    )
    if count != 1:
        raise RuntimeError("stock shadow-copy hook changed unexpectedly")
    text, count = re.subn(
        r"\n\t# change root password\n.*?\n\t# temporary hack until configd exists\n",
        "\n\t# standard OpenWrt authentication is managed through persistent /etc/shadow\n"
        "\n\t# Refresh generated defaults after removing the factory credential flow.\n",
        text,
        flags=re.DOTALL,
    )
    if count != 1:
        # The 1.5.3 vendor release moved this credential mutation into a
        # separate boot service. Both forms are removed before publishing.
        updater = root / "etc/init.d/update_passwd"
        if count != 0 or not updater.is_file() or \
                "# temporary hack until configd exists" not in text or \
                "# change root password" in text or \
                "update_pw" not in updater.read_text():
            raise RuntimeError("stock serial-number password block changed unexpectedly")
    dnsmasq_disable = "\t/etc/init.d/dnsmasq disable\n"
    if text.count(dnsmasq_disable) != 1:
        raise RuntimeError("stock dnsmasq-disable hook changed unexpectedly")
    text = text.replace(dnsmasq_disable, "")
    text, count = re.subn(
        r"^[ \t]*secdat_tool -u[ \t]*\n",
        "\t\t# Preserve sec.dat; the standard management plane never mutates it.\n",
        text,
        flags=re.MULTILINE,
    )
    if count != 1:
        raise RuntimeError("stock sec.dat uninstall hook changed unexpectedly")

    # The factory OpenSync target mapping and its shipped backup database both
    # identify wifi0=2.4 GHz, wifi1=6 GHz and wifi2=5 GHz.  The separate board
    # SI script agrees that the 6 GHz QCN9224 is PCIe2/BDF b0004.  The stock
    # boot script nevertheless assigns READ_6G_MAC to wifi2 and tests an
    # unquoted variable, which can run even when the read failed.  Correct that
    # stale factory line while retaining the read-only manufacturing call.
    text, count = re.subn(
        r"\n\tlocal mac6g=`mf_tool\s+READ_6G_MAC`\s*\n"
        r"\t\[ -n \$mac6g \] && \{echo \"write the 6G macaddress\";"
        r"cfg80211tool wifi2 setHwaddr \$mac6g\}\n",
        "\n\tlocal mac6g\n"
        "\tmac6g=\"$(mf_tool READ_6G_MAC 2>/dev/null)\"\n"
        "\t[ -n \"$mac6g\" ] && {\n"
        "\t\techo \"write the 6G macaddress\"\n"
        "\t\tcfg80211tool wifi1 setHwaddr \"$mac6g\"\n"
        "\t}\n",
        text,
    )
    if count != 1:
        raise RuntimeError("stock 6 GHz MAC assignment changed unexpectedly")
    boot.write_text(text)

    bridge_module = root / "etc/modules.d/51-qca-nss-drv-bridge-mgr"
    if bridge_module.exists():
        text = bridge_module.read_text()
        if text.count("ovs_enabled=1") != 1:
            raise RuntimeError("unexpected qca-nss-bridge-mgr module options")
        bridge_module.write_text(text.replace("ovs_enabled=1", "ovs_enabled=0"))

    for relative in (
        "etc/modules.d/openvswitch",
        "etc/modules.d/50-qca-ovsmgr",
    ):
        (root / relative).unlink(missing_ok=True)

    ppe_bridge = root / "etc/modules.d/51-qca-nss-ppe-bridge-mgr"
    text = ppe_bridge.read_text()
    if text.count("ovs_enabled=1") != 1:
        raise RuntimeError("unexpected PPE bridge-manager module options")
    ppe_bridge.write_text(text.replace("ovs_enabled=1", "ovs_enabled=0"))

    ecm = root / "etc/init.d/qca-nss-ecm"
    replace_once(
        ecm,
        '\t[ -e /lib/modules/$(uname -r)/qca-ovsmgr.ko ] && modprobe qca-ovsmgr\n',
        "",
    )
    replace_once(
        ecm,
        '''\n\tif [ -d /sys/module/qca_ovsmgr ]; then
\t\tinsmod ecm_ovs
\tfi
''',
        "\n",
    )
    replace_once(
        ecm,
        '''\n\tif [ -d /sys/module/ecm_ovs ]; then
\t\trmmod ecm_ovs
\tfi
''',
        "\n",
    )

    root_cron = root / "etc/crontabs/root"
    lines = [
        line
        for line in root_cron.read_text().splitlines()
        if "process_crash_dump" not in line and "logrotate" not in line
    ]
    root_cron.write_text("\n".join(lines) + "\n")
    (root / "etc/crontabs/operator").unlink(missing_ok=True)

    # The stock overrides pipe every core into OpenSync and enable proxy NDP on
    # its br-home bridge.  Keep only the QSDK conntrack sizing override; the
    # standard OpenWrt defaults in /etc/sysctl.d/10-default.conf own the rest.
    (root / "etc/sysctl.conf").write_text(
        "# Local QSDK datapath sizing override.\n"
        "net.netfilter.nf_conntrack_max=65536\n"
    )
    remove_path(root / "etc/sysctl.conf.orig")

    # Stock rotates OVS/CUJO logs as the deleted operator account, archives to
    # /usr/opensync and invokes ovs-appctl.  logd uses its own RAM ring buffer,
    # so no periodic file rotation is needed in the replacement management UI.
    remove_path(root / "etc/logrotate.d/tmp_log")
    # This migration rewrites the stock opkg feed files on the read-only root.
    # There is no legacy writable overlay to migrate in this image.
    remove_path(root / "etc/uci-defaults/20_migrate-feeds")

    # The overlay replaces the stock Qualcomm upgrader with a narrowly scoped
    # configuration backup interface.  It never accepts firmware and validates
    # every restored tar header and path before copying selected configuration.
    sysupgrade = root / "sbin/sysupgrade"
    sysupgrade_text = sysupgrade.read_text()
    for marker in (
        "--list-backup",
        "--create-backup",
        "--restore-backup",
        "forced firmware upgrades are disabled",
        "/usr/libexec/validate_firmware_image",
        "ubus call system sysupgrade",
        "/usr/libexec/sbe-backup-validate",
    ):
        if marker not in sysupgrade_text:
            raise RuntimeError(f"safe sysupgrade compatibility marker is missing: {marker}")

    firstboot = root / "sbin/firstboot"
    firstboot_text = firstboot.read_text()
    if "exec /usr/sbin/sbe-overlay-reset" not in firstboot_text:
        raise RuntimeError("firstboot does not delegate to the audited overlay reset")

    backup_validator = root / "usr/libexec/sbe-backup-validate"
    if not backup_validator.is_file():
        raise RuntimeError("strict SBE1V1K backup validator is missing")

    # LuCI firmware upgrade is enabled only through the replacement's strict
    # board/geometry/tar/hash validator and p25-last read-back writer.
    platform_upgrade = root / "lib/upgrade/platform.sh"
    if not platform_upgrade.is_file():
        raise RuntimeError("strict SBE1V1K platform upgrader is missing")
    platform_text = platform_upgrade.read_text()
    for marker in (
        "REQUIRE_IMAGE_METADATA=1",
        "qcom,ipq9574-ap-al02-c4",
        "unexpected tar member order or names",
        "p27 read-back verification failed",
        "p25 read-back verification failed",
        "/dev/mmcblk0p29",
    ):
        if marker not in platform_text:
            raise RuntimeError(f"strict platform upgrade marker is missing: {marker}")
    remove_path(root / "lib/upgrade/platform.sh.orig")

    fw_env_config = root / "etc/fw_env.config"
    if fw_env_config.read_text() != "/dev/mmcblk0p17 0x0 0x40000 0x40000\n":
        raise RuntimeError("SBE1V1K APPSBLENV geometry is missing or unexpected")

    harden_luci_management_capabilities(root)

    for relative in (
        "etc/config/cloud_config",
        "etc/config/opensync-default",
        "etc/config/openvswitch",
        "etc/config/socat",
        "etc/hotplug.d/net/99-regdomain",
        "lib/upgrade/keep.d/openvswitch-common",
    ):
        (root / relative).unlink(missing_ok=True)

    for name in REMOVED_INIT_SCRIPTS:
        remove_path(root / "etc/init.d" / name)

    # All three halt-family applets in the factory BusyBox were modified to
    # write opensync-default reboot state under /usr/askey/persist.  The
    # overlay supplies regular local wrappers: reboot asks procd over ubus,
    # while halt/poweroff fail closed because this externally powered router
    # has no audited software power-off path.  Never recreate BusyBox links.
    for name in ("reboot", "halt", "poweroff"):
        shutdown_tool = root / "sbin" / name
        if not shutdown_tool.is_file() or shutdown_tool.is_symlink():
            raise RuntimeError(f"local /sbin/{name} wrapper is missing")
        shutdown_text = shutdown_tool.read_text()
        for forbidden in (
            "busybox reboot",
            "busybox halt",
            "busybox poweroff",
            "opensync-default",
            "/usr/askey/persist",
        ):
            if forbidden in shutdown_text:
                raise RuntimeError(
                    f"unsafe factory shutdown path in /sbin/{name}: {forbidden}"
                )
    if "ubus call system reboot" not in (root / "sbin/reboot").read_text():
        raise RuntimeError("local reboot wrapper must delegate to procd over ubus")

    # Disconnect dormant operator-only entry points as well.  The proprietary
    # payload files remain in the conservative hardware-trial image, but no
    # standard command, service or iptables extension should enter them.
    for relative in (
        ".version",
        # The factory baked a plain "1" marker into the UCI config directory.
        # No retained service consumes it; global UCI operations try to parse
        # it and fail before ordinary package/service configuration completes.
        "etc/config/firstboot",
        "etc/init.d/debugnet",
        "etc/miniupnpd/iptscript.sh",
        "etc/openvswitch",
        "sbin/trigger_update_firmware",
        "usr/bin/ovs-ctl",
        "usr/bin/ovs-kmod-ctl",
        "usr/lib/iptables/libxt_LUA.so",
        "usr/lib/iptables/libxt_lua.so",
        "usr/plume",
    ):
        remove_path(root / relative)
    (root / "etc/sysupgrade.conf").write_text(
        "# Additional files and directories to preserve in configuration backups.\n"
        "# One absolute path or shell glob per line.\n"
    )

    inert_hooks = {
        "etc/udhcpc.user": """#!/bin/sh
# netifd's DHCP protocol script owns routes and resolvers.
exit 0
""",
        "etc/ppp/ip-up": """#!/bin/sh
# netifd invokes /lib/netifd/ppp-up directly.
exit 0
""",
        "etc/ppp/ip-down": """#!/bin/sh
# netifd invokes /lib/netifd/ppp-down directly.
exit 0
""",
        "etc/profile": """#!/bin/sh
[ -f /etc/banner ] && cat /etc/banner
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/opt/bin:/opt/sbin:/usr/askey/sbin
export HOME=$(grep -e \"^${USER:-root}:\" /etc/passwd | cut -d \":\" -f 6)
export HOME=${HOME:-/root}
export PS1='${USER}@\\h:\\w\\$ '
[ -x /usr/bin/arp ] || arp() { cat /proc/net/arp; }
[ -x /usr/bin/ldd ] || ldd() { LD_TRACE_LOADED_OBJECTS=1 $*; }
""",
    }
    for relative, contents in inert_hooks.items():
        path = root / relative
        path.write_text(contents)
        path.chmod(0o755)

    prune_web_root(root)
    harden_luci_untrusted_tables(root)
    repair_luci_firewall_strict_mode(root)
    harden_luci_status_views(root, rrdns_available=rrdns_available)
    harden_luci_logging_and_headers(root)

    mount_root = root / "lib/preinit/80_mount_root"
    replace_function(
        mount_root,
        "init_emmc_rootfs_data",
        '''init_emmc_rootfs_data() {
\t# Never format or repair either data slot automatically.
\treturn 0
}''',
    )
    replace_function(
        mount_root,
        "do_mount_root",
        '''do_mount_root() {
\t# Mount only through the audited board partition hook.  The stock path
\t# could execute a reserved-partition payload and write it back to eMMC.
\tboot_run_hook preinit_mount_root
}''',
    )
    mount_root_text = mount_root.read_text()
    mount_root_hook = '[ "$INITRAMFS" = "1" ] || boot_hook_add preinit_main do_mount_root'
    ram_trial_hook = '''if [ "$INITRAMFS" != "1" ] || grep -qw sbe_ram_trial=1 /proc/cmdline; then
\tboot_hook_add preinit_main do_mount_root
fi'''
    if mount_root_text.count(mount_root_hook) != 1:
        raise ValueError("unexpected preinit mount-root hook")
    mount_root.write_text(mount_root_text.replace(mount_root_hook, ram_trial_hook))

    replace_function(
        preinit,
        "do_mount_persist_partition",
        f'''do_mount_persist_partition() {{
\tgrep -wqs persist /sys/class/ubi/ubi1/ubi1_*/name && {{
\t\tmkdir -p /usr/askey/persist
\t\tmount -t ubifs -o {shared_options} ubi1:persist /usr/askey/persist
\t\treturn
\t}}

\tlocal emmcblock="$(find_mmc_part "persist")"
\t[ -e "$emmcblock" ] || return 1
\tmkdir -p /usr/askey/persist
\tmount -t ext3 -o {shared_options} "$emmcblock" /usr/askey/persist
}}''',
    )
    replace_function(
        preinit,
        "do_mount_usr_app_partition",
        f'''do_mount_usr_app_partition() {{
\tlocal emmcblock="$(find_mmc_part "usr_app")"
\t[ -e "$emmcblock" ] || return 1
\tmkdir -p /usr/app
\tmount -t ext4 -o {shared_options} "$emmcblock" /usr/app
}}''',
    )
    replace_function(
        preinit,
        "do_mount_rootfs_data_partition",
        f'''do_mount_rootfs_data_partition() {{
\tmkdir -p /data
\tif grep -qw sbe_ram_trial=1 /proc/cmdline; then
\t\t# A network-enabled TFTP trial keeps every persistent file in tmpfs.
\t\tmkdir -p /tmp/sbe-ram-data
\t\tmount -o bind /tmp/sbe-ram-data /data || return 1
\telse
\t\tlocal emmcblock="$(find_mmc_part "{rootfs_data_label}")"
\t\t[ -e "$emmcblock" ] || return 1
\t\tmount -t ext4 -o rw,nosuid,nodev,noexec "$emmcblock" /data || return 1
\tfi

\t# Never import /data/etc: it belongs to the factory/operator image and may
\t# contain device identity, credentials or OpenSync state.
\tif [ -e /data/openwrt/.factory-reset ]; then
\t\t[ -d /data/openwrt ] || return 1
\t\trm -rf /data/openwrt/etc
\t\trm -f /data/openwrt/.factory-reset
\tfi
\tmkdir -p -m 700 /data/openwrt/etc || return 1
\tlocal persistent_etc=/data/openwrt/etc

\t# Start with an empty writable Dropbear directory.  The standard init script
\t# generates unique per-device host keys; no stock or developer key is copied.
\tif [ ! -d "$persistent_etc/dropbear" ]; then
\t\tmkdir -p -m 700 "$persistent_etc/dropbear"
\tfi
\tchmod 700 "$persistent_etc/dropbear"
\t[ ! -f "$persistent_etc/dropbear/authorized_keys" ] || \\
\t\tchmod 600 "$persistent_etc/dropbear/authorized_keys"
\tmount -o bind "$persistent_etc/dropbear" /etc/dropbear || return 1

\tfor persistent_dir in config crontabs uci-defaults; do
\t\tif [ ! -d "$persistent_etc/$persistent_dir" ]; then
\t\t\tmkdir -p "$persistent_etc/$persistent_dir"
\t\t\tcp -af "/etc/$persistent_dir/." "$persistent_etc/$persistent_dir/"
\t\tfi
\t\tmount -o bind "$persistent_etc/$persistent_dir" \\
\t\t\t"/etc/$persistent_dir" || return 1
\tdone

\t# Load and immediately rotate the dedicated seed after persistent UCI has
\t# been bound, but before Dropbear or other key-generating services start.
\t# The helper explicitly becomes a no-op for sbe_ram_trial=1.
\t/usr/sbin/sbe-random-seed load >/dev/null 2>&1 || \\
\t\techo "# persistent random seed was not loaded"

\tfor persistent_file in rc.local firewall.user sysupgrade.conf; do
\t\tif [ ! -f "$persistent_etc/$persistent_file" ]; then
\t\t\tcp -pf "/etc/$persistent_file" "$persistent_etc/$persistent_file"
\t\tfi
\t\tmount -o bind "$persistent_etc/$persistent_file" "/etc/$persistent_file" || \\
\t\t\treturn 1
\tdone

\tfor account_file in passwd shadow group; do
\t\t[ -f "/tmp/etc/$account_file" ] || continue
\t\t[ -f "$persistent_etc/$account_file" ] || \\
\t\t\tcp -f "/tmp/etc/$account_file" "$persistent_etc/$account_file"
\t\tfor disabled_account in operator cujo osync plume; do
\t\t\tsed -i "/^${{disabled_account}}:/d" "$persistent_etc/$account_file"
\t\tdone
\t\trm -f "/tmp/etc/$account_file"
\t\tln -s "$persistent_etc/$account_file" "/tmp/etc/$account_file"
\tdone
\tchmod 600 "$persistent_etc/shadow"
}}''',
    )
    replace_function(
        preinit,
        "do_mount_rsvd_3_partition",
        f'''do_mount_rsvd_3_partition() {{
\tlocal emmcblock="$(find_mmc_part "bypass_cert")"
\t[ -e "$emmcblock" ] || return 1
\tmkdir -p /usr/bypass-cert
\tmount -t ext4 -o {shared_options} "$emmcblock" /usr/bypass-cert
}}''',
    )
    replace_function(
        preinit,
        "do_mount_user_data_partition",
        f'''do_mount_user_data_partition() {{
\tgrep -wqs user_data /sys/class/ubi/ubi1/ubi1_*/name && {{
\t\tmkdir -p /opt/data
\t\tmount -t ubifs -o {shared_options} ubi1:user_data /opt/data
\t\treturn
\t}}

\tlocal emmcblock="$(find_mmc_part "user_data")"
\t[ -e "$emmcblock" ] || return 1
\tmkdir -p -m 777 /opt/data
\tmount -t ext3 -o {shared_options} "$emmcblock" /opt/data
}}''',
    )

    replace_once(
        preinit,
        '''\tverify_rsvd_1 || {
\t\tdo_mount_rootfs_data_partition || echo "# failed to rootfs user_data parition"
\t}''',
        '''\tdo_mount_rootfs_data_partition || echo "# failed to mount rootfs_data partition"''',
    )
    replace_function(
        preinit,
        "do_mount_askey_partition",
        '''do_mount_askey_partition() {
\tif grep -qw sbe_ram_trial=1 /proc/cmdline; then
\t\t# Do not mount any eMMC data partition during the RAM-only trial.
\t\tdo_mount_rootfs_data_partition || \\
\t\t\techo "# failed to create RAM-only configuration layer"
\t\treturn
\tfi

\t# The replacement system owns only the dedicated rootfs_data_1 partition.
\t# Factory log/persist/app/TLS/user-data partitions stay entirely unmounted;
\t# Wi-Fi firmware, ART and licences use their separate audited boot hooks.
\tdo_mount_rootfs_data_partition || echo "# failed to mount rootfs_data partition"
}''',
    )


def finalize_preinit_mount_hook(root: Path, preinit: Path):
    overlay_hook = root / "lib/preinit/82_sbe_overlay_root"
    if not overlay_hook.is_file():
        raise RuntimeError("audited SBE1V1K overlay-root hook is missing")

    # The factory image also ships a second, earlier 42_* hook.  Its dispatcher
    # mounts operator log/vendor/user-data volumes and can relink
    # /usr/askey/persist.  A later shell definition currently shadows it, but
    # dead privileged mount code is not an acceptable release boundary: a
    # changed source order could make it reachable again.  Anchor the exact
    # kind of payload we expect and then remove the whole hook.  WIFIFW,
    # LICENSE and ART/caldata are handled by separate audited init services.
    legacy_mfc_hook = root / "lib/preinit/42_mount_askey_mfc_partition"
    if not legacy_mfc_hook.is_file() or legacy_mfc_hook.is_symlink():
        raise RuntimeError("factory Askey MFC/operator mount hook is missing or unsafe")
    legacy_mfc_text = legacy_mfc_hook.read_text()
    for marker in (
        "do_mount_oprt_data_partition()",
        "do_mount_askey_mfc_partition()",
        "do_mount_log_partition()",
        "do_mount_vendor_partition()",
        "do_mount_user_data_partition()",
        "do_mount_askey_partition()",
        "boot_hook_add preinit_mount_root do_mount_askey_partition",
    ):
        if legacy_mfc_text.count(marker) != 1:
            raise RuntimeError(
                f"unexpected factory Askey MFC/operator mount hook: {marker}"
            )
    remove_path(legacy_mfc_hook)

    # All destructive stock mount functions have now been anchor-checked and
    # neutralized.  Do not ship their dead implementations: retain only the
    # hook name which 82_sbe_overlay_root safely redefines after validating the
    # explicit RAM/persistent mode and the exact p30 geometry.
    preinit.write_text(
        "#!/bin/sh\n"
        "# SBE1V1K mount dispatch is implemented in 82_sbe_overlay_root.\n"
        "do_mount_askey_partition() {\n"
        "\techo '# SBE1V1K overlay policy was not loaded' >/dev/kmsg 2>/dev/null\n"
        "\treturn 1\n"
        "}\n"
        "boot_hook_add preinit_mount_root do_mount_askey_partition\n"
    )


def patch_package_manager(root: Path):
    """Preserve the factory binary behind a transparent opkg entry point."""
    opkg = root / "bin/opkg"
    real_opkg = root / "usr/libexec/sbe-opkg-real"
    wrapper = root / "usr/libexec/sbe-opkg-wrapper"
    if not opkg.is_file() or not wrapper.is_file():
        raise RuntimeError("stock opkg or SBE1V1K compatibility entry point is missing")
    if real_opkg.exists() or real_opkg.is_symlink():
        raise RuntimeError(
            "refusing to patch opkg twice; preserved factory binary already exists"
        )
    if not (root / "usr/bin/usign").is_file():
        raise RuntimeError("factory usign is required for normal opkg signature support")
    if not (root / "usr/sbin/opkg-key").is_file():
        raise RuntimeError("factory opkg-key is required for feed compatibility")

    real_opkg.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(opkg, real_opkg)
    shutil.copy2(wrapper, opkg)
    opkg.chmod(0o755)
    real_opkg.chmod(0o755)

    # Keep normal opkg key handling and a standard custom feed file. LuCI edits
    # ordinary src/src-gz entries here or in the other /etc/opkg/*.conf files.
    key_dir = root / "etc/opkg/keys"
    key_dir.mkdir(parents=True, exist_ok=True)
    (root / "etc/opkg/customfeeds.conf").write_text(
        "# Additional opkg sources configured from LuCI's 软件包 page.\n"
    )


def gate_manufacturing_tool(root: Path):
    """Expose only the three read operations required by normal board boot."""
    entrypoint = root / "sbin/mf_tool"
    real_tool = root / "usr/libexec/sbe-mf-tool-real"
    if not entrypoint.is_file() or entrypoint.read_bytes()[:4] != b"\x7fELF":
        raise RuntimeError("factory mf_tool ELF is missing")
    real_tool.parent.mkdir(parents=True, exist_ok=True)
    remove_path(real_tool)
    shutil.move(entrypoint, real_tool)
    real_tool.chmod(0o700)
    entrypoint.write_text(
        "#!/bin/sh\n"
        "case \"$#:$1\" in\n"
        "1:READ_HW_VERSION|1:READ_TN|1:READ_6G_MAC)\n"
        "\texec /usr/libexec/sbe-mf-tool-real \"$1\"\n"
        "\t;;\n"
        "*)\n"
        "\techo 'mf_tool manufacturing command is disabled' >&2\n"
        "\texit 1\n"
        "\t;;\n"
        "esac\n"
    )
    entrypoint.chmod(0o755)


def gate_led_actuator(root: Path):
    """Keep the stock PWM mapping private and route policy through sbe-led."""
    real_tool = root / "usr/libexec/sbe-led-ctl-real"
    public_tool = root / "sbin/led_ctl"
    pwm_init = root / "etc/init.d/askey_pwm"

    if not real_tool.is_file() or real_tool.is_symlink():
        raise RuntimeError("preserved stock LED actuator is missing")
    real_text = real_tool.read_text()
    for marker in ("/usr/bin/askey_pwm_sig", "error_check(){", "do_ctl(){"):
        if marker not in real_text:
            raise RuntimeError(f"stock LED actuator anchor is missing: {marker}")
    replace_function(real_tool, "error_check", "error_check() {\n\treturn 0\n}")
    real_tool.chmod(0o700)

    if not public_tool.is_file() or public_tool.is_symlink():
        raise RuntimeError("sbe-led compatibility entry point is missing")
    public_text = public_tool.read_text()
    if "manager=/usr/sbin/sbe-led" not in public_text or "askey_pwm_sig" in public_text:
        raise RuntimeError("public LED entry point bypasses the local policy manager")
    public_tool.chmod(0o755)

    if not pwm_init.is_file() or pwm_init.is_symlink():
        raise RuntimeError("local askey_pwm procd service is missing")
    pwm_init_text = pwm_init.read_text()
    if "PROG=/usr/bin/askey_pwm" not in pwm_init_text:
        raise RuntimeError("askey_pwm service does not supervise the board actuator")
    for bypass in ("led_ctl", "askey_pwm_sig"):
        if bypass in pwm_init_text:
            raise RuntimeError(f"askey_pwm service still bypasses sbe-led via {bypass}")

    # These stock board actuators arrived mode 0777.  They are implementation
    # details of the root-owned procd/policy chain, not public administration
    # commands; mode 0700 prevents another local service account from bypassing
    # thermal or LED arbitration.
    for relative in (
        "usr/bin/askey_pwm",
        "usr/bin/askey_pwm_sig",
        "usr/sbin/askey_pwm.script",
    ):
        actuator = root / relative
        if not actuator.is_file() or actuator.is_symlink():
            raise RuntimeError(f"private board actuator is missing: {relative}")
        actuator.chmod(0o700)


STOCK_USB_REGULAR_PATHS = (
    "usr/sbin/blkid",
    "usr/sbin/e2fsck",
    "usr/sbin/mke2fs",
    "usr/lib/libblkid.so.1.1.0",
    "usr/bin/fusermount",
    "etc/modules.d/69-usb-storage",
    "etc/modules.d/usb-uas",
    "etc/modules.d/80-fuse",
)

STOCK_USB_SYMLINKS = {
    "usr/lib/libblkid.so.1": "libblkid.so.1.1.0",
    "usr/sbin/fsck.ext2": "e2fsck",
    "usr/sbin/fsck.ext3": "e2fsck",
    "usr/sbin/fsck.ext4": "e2fsck",
    "usr/sbin/mkfs.ext2": "mke2fs",
    "usr/sbin/mkfs.ext3": "mke2fs",
    "usr/sbin/mkfs.ext4": "mke2fs",
}

STOCK_USB_MODULES = tuple(
    f"lib/modules/5.4.213/{module}"
    for module in (
        "dwc3-qcom.ko",
        "dwc3.ko",
        "fuse.ko",
        "phy-qcom-qusb2.ko",
        "uas.ko",
        "usb-common.ko",
        "usb-storage.ko",
        "usbcore.ko",
        "xhci-hcd.ko",
        "xhci-plat-hcd.ko",
    )
)

STOCK_USB_CONSUMERS_FILE = ".libblkid-consumers"


def stock_libblkid_consumers(root: Path):
    from audit_elf_abi import Elf64, elf_paths

    consumers = set()
    for path in elf_paths(root):
        try:
            elf = Elf64(path)
        except (OSError, ValueError) as error:
            raise RuntimeError(f"cannot audit storage ELF {path}: {error}") from error
        if "libblkid.so.1" in elf.needed:
            consumers.add(path.relative_to(root).as_posix())
    return consumers


def capture_stock_usb_compatibility(root: Path, destination: Path):
    """Capture only the stock files whose bytes the repack must preserve.

    The whole source partition is authenticated by stock-baseline.env before
    this runs.  Keeping this small before/after tree avoids duplicating one
    firmware release's individual file digests in the patcher.
    """

    if destination.exists():
        raise RuntimeError(f"stock USB baseline destination already exists: {destination}")
    destination.mkdir(parents=True)
    for relative in (*STOCK_USB_REGULAR_PATHS, *STOCK_USB_MODULES):
        source = root / relative
        target = destination / relative
        if not source.is_file() or source.is_symlink():
            raise RuntimeError(f"stock USB baseline payload is missing: {relative}")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    for relative, expected in STOCK_USB_SYMLINKS.items():
        source = root / relative
        if not source.is_symlink() or os.readlink(source) != expected:
            raise RuntimeError(f"stock USB baseline symlink changed: {relative}")
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(expected)
    consumers = sorted(stock_libblkid_consumers(root))
    if not consumers:
        raise RuntimeError("stock libblkid has no audited consumers")
    (destination / STOCK_USB_CONSUMERS_FILE).write_text(
        "".join(f"{path}\n" for path in consumers), encoding="utf-8"
    )


def validate_stock_usb_compatibility(root: Path, baseline: Optional[Path] = None):
    """Keep the factory USB layer intact while rejecting added storage UI.

    SBE1V1K has no exposed USB connector, so the image does not add
    block-mount, usbutils, NTFS or a LuCI mounting surface.  The factory image
    nevertheless enables its USB controller/PHY and ships storage utilities.
    Preserve those bytes and their module autoload policy for maximum QSDK
    compatibility, but inventory every consumer so an unexpected overlay
    fails assembly instead of being silently misclassified.

    This validator is deliberately read-only.  It proves that no generic
    OpenWrt storage management package was layered in and, when an assembly
    baseline is supplied, that no retained factory file changed.  The
    comparison is against the authenticated input tree captured immediately
    before overlays, not hard-coded per-file hashes tied to one release.
    """

    consumers = stock_libblkid_consumers(root)
    if baseline is not None:
        consumer_file = baseline / STOCK_USB_CONSUMERS_FILE
        if not consumer_file.is_file() or consumer_file.is_symlink():
            raise RuntimeError("stock USB baseline consumer inventory is missing")
        expected_consumers = set(consumer_file.read_text(encoding="utf-8").splitlines())
        if consumers != expected_consumers:
            raise RuntimeError(
                "libblkid consumer set changed after overlays: "
                + ", ".join(sorted(consumers ^ expected_consumers))
            )
    elif not consumers:
        raise RuntimeError("libblkid has no audited consumers")

    for relative in STOCK_USB_REGULAR_PATHS:
        path = root / relative
        if not path.is_file() or path.is_symlink():
            raise RuntimeError(f"audited storage payload is missing: {relative}")

    for relative, expected in STOCK_USB_SYMLINKS.items():
        path = root / relative
        if not path.is_symlink() or os.readlink(path) != expected:
            raise RuntimeError(f"audited storage symlink changed: {relative}")

    storage_autoloads = {
        "etc/modules.d/69-usb-storage": "usb-storage\n",
        "etc/modules.d/usb-uas": "uas\n",
        "etc/modules.d/80-fuse": "fuse\n",
    }
    for relative, expected in storage_autoloads.items():
        path = root / relative
        if not path.is_file() or path.is_symlink() or path.read_text() != expected:
            raise RuntimeError(f"audited storage module autoload changed: {relative}")
    for relative in STOCK_USB_MODULES:
        path = root / relative
        if not path.is_file() or path.is_symlink():
            raise RuntimeError(f"stock QSDK USB compatibility module is missing: {relative}")

    if baseline is not None:
        for relative in (*STOCK_USB_REGULAR_PATHS, *STOCK_USB_MODULES):
            current = root / relative
            original = baseline / relative
            if not original.is_file() or original.is_symlink():
                raise RuntimeError(f"stock USB baseline payload is missing: {relative}")
            if not filecmp.cmp(current, original, shallow=False):
                raise RuntimeError(f"factory USB compatibility payload changed: {relative}")
            if stat.S_IMODE(current.stat().st_mode) != stat.S_IMODE(original.stat().st_mode):
                raise RuntimeError(f"factory USB compatibility mode changed: {relative}")
        for relative in STOCK_USB_SYMLINKS:
            original = baseline / relative
            if not original.is_symlink() or os.readlink(original) != os.readlink(root / relative):
                raise RuntimeError(f"factory USB compatibility symlink changed: {relative}")

    forbidden_paths = (
        "sbin/block",
        "lib/libblkid-tiny.so",
        "usr/bin/lsusb",
        "usr/bin/ntfs-3g",
        "usr/bin/ntfs-3g.probe",
        "sbin/mount.ntfs",
        "sbin/mount.ntfs-3g",
        "etc/init.d/fstab",
        "etc/config/fstab",
        "etc/hotplug.d/block/00-media-change",
        "etc/hotplug.d/block/10-mount",
    )
    unexpected = [
        relative
        for relative in forbidden_paths
        if (root / relative).exists() or (root / relative).is_symlink()
    ]
    for pattern in ("usr/lib/libntfs-3g.so*", "usr/lib/libusb-1.0.so*"):
        unexpected.extend(
            path.relative_to(root).as_posix() for path in root.glob(pattern)
        )
    if unexpected:
        raise RuntimeError(
            "unsupported removable-storage package payload present: "
            + ", ".join(sorted(unexpected))
        )


def patch_dropbear_policy(root: Path) -> None:
    dropbear = root / "etc/init.d/dropbear"
    # Use the upstream OpenWrt 19.07 Dropbear service wrapper, not the vendor
    # build which is hard-coded to reject every login name except "operator".
    if "START=19\nSTOP=50" not in dropbear.read_text():
        raise RuntimeError("upstream Dropbear must keep its early START=19 ordering")
    replace_once(
        dropbear,
        "\tfor ktype in ecdsa rsa; do\n",
        "\tfor ktype in ed25519 ecdsa rsa; do\n",
    )
    replace_once(
        dropbear,
        "\t\t'PasswordAuth:bool:1' \\\n",
        "\t\t'PasswordAuth:bool:1' \\\n"
        "\t\t'AllowBlankPassword:bool:0' \\\n",
    )
    replace_once(
        dropbear,
        '\t[ "${PasswordAuth}" -eq 0 ] && procd_append_param command -s\n',
        '\t[ "${PasswordAuth}" -eq 0 ] && procd_append_param command -s\n'
        '\t[ "${AllowBlankPassword}" -eq 1 ] && procd_append_param command -B\n',
    )
    # Keep native Interface/GatewayPorts handling. LAN is the shipped default,
    # not a constraint silently imposed on later administrator choices.


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument(
        "--rootfs-data-label",
        choices=("rootfs_data_1",),
        default="rootfs_data_1",
        help="dedicated unused GPT label mounted at /data by the patched rootfs",
    )
    parser.add_argument(
        "--trial-safe",
        action="store_true",
        help="mount shared stock data partitions read-only and without journal replay",
    )
    parser.add_argument(
        "--capture-stock-usb-baseline",
        type=Path,
        help="capture retained USB/QSDK bytes from the authenticated stock root and exit",
    )
    parser.add_argument(
        "--stock-usb-baseline",
        type=Path,
        help="compare retained USB/QSDK bytes with a pre-overlay stock snapshot",
    )
    parser.add_argument(
        "--component-profile",
        type=Path,
        help="selected hash-locked profile; enables rrdns UI only when it owns the canonical module",
    )
    args = parser.parse_args()
    root = args.root

    if args.capture_stock_usb_baseline is not None:
        if args.stock_usb_baseline is not None or args.trial_safe:
            parser.error("stock USB capture cannot be combined with patch options")
        capture_stock_usb_compatibility(root, args.capture_stock_usb_baseline)
        print(f"captured stock USB compatibility baseline: {args.capture_stock_usb_baseline}")
        return

    preinit = root / "lib/preinit/42_mount_askey_partition"
    patch_qsdk_identity(root)
    patch_board_services(root)
    patch_qsdk_wireless_driver_script(root)
    patch_embedded_wifi_source(root)
    patch_local_service_policy(root)
    patch_partition_mount_policy(preinit, args.rootfs_data_label, args.trial_safe)
    patch_management_plane(
        root,
        preinit,
        args.rootfs_data_label,
        args.trial_safe,
        component_profile_has_rrdns(args.component_profile),
    )
    finalize_preinit_mount_hook(root, preinit)
    prune_operator_payloads(root)
    patch_package_manager(root)
    gate_manufacturing_tool(root)
    gate_led_actuator(root)
    validate_stock_usb_compatibility(root, args.stock_usb_baseline)
    patch_dropbear_policy(root)

    rc_dir = root / "etc/rc.d"
    for name in DISABLED_RC_LINKS:
        path = rc_dir / name
        if path.exists() or path.is_symlink():
            path.unlink()
    for name in ("S60firewall", "K90opensync"):
        path = rc_dir / name
        if path.exists() or path.is_symlink():
            path.unlink()
    for name, target in ENABLED_LINKS.items():
        path = rc_dir / name
        if path.exists() or path.is_symlink():
            path.unlink()
        path.symlink_to(target)
    if (root / "etc/init.d/sysntpd").is_file():
        remove_path(rc_dir / "S98sysntpd")
        (rc_dir / "S98sysntpd").symlink_to("../init.d/sysntpd")
        (root / "etc/init.d/sysntpd").chmod(0o755)
        (root / "usr/sbin/ntpd-hotplug").chmod(0o755)
    if (root / "etc/init.d/log").is_file():
        for legacy in ("S11syslog", "K99syslog"):
            remove_path(rc_dir / legacy)
        for name in ("S12log", "K89log"):
            remove_path(rc_dir / name)
            (rc_dir / name).symlink_to("../init.d/log")
        (root / "etc/init.d/log").chmod(0o755)
    validate_rc_whitelist(rc_dir)

    executable_paths = (
        "etc/init.d/askey_pwm",
        "etc/init.d/dropbear",
        "etc/init.d/firewall",
        "etc/init.d/rpcd",
        "etc/init.d/rngd",
        "etc/init.d/sbe-accel",
        "etc/init.d/sbe-led",
        "etc/init.d/sbe-local-watchdog",
        "etc/init.d/sbe-overlay-commit",
        "etc/init.d/sbe-random-seed",
        "etc/init.d/sbe-thermal-policy",
        "etc/init.d/sbe-wireless-policy",
        "etc/init.d/ucitrack",
        "etc/init.d/uhttpd",
        "etc/hotplug.d/button/50-sbe-reset-led",
        "etc/hotplug.d/iface/96-sbe-led",
        "etc/rc.button/reset",
        "lib/preinit/82_sbe_overlay_root",
        "usr/sbin/sbe-healthcheck",
        "usr/sbin/sbe-led",
        "usr/sbin/sbe-local-watchdog",
        "usr/sbin/sbe-mbssid-policy",
        "usr/sbin/sbe-overlay-reset",
        "usr/sbin/sbe-p30-audit",
        "usr/sbin/sbe-random-seed",
        "usr/sbin/sbe-slot-confirm",
        "usr/sbin/sbe-status",
        "usr/sbin/sbe-thermal-policy",
        "usr/sbin/sbe-wifi-lifecycle",
        "usr/libexec/sbe-backup-validate",
        "usr/libexec/sbe-opkg-wrapper",
        "sbin/firstboot",
        "sbin/led_ctl",
        "sbin/halt",
        "sbin/poweroff",
        "sbin/reboot",
        "sbin/sysupgrade",
    )
    for relative in executable_paths:
        path = root / relative
        path.chmod(0o755)

    dropbear_dir = root / "etc/dropbear"
    (dropbear_dir / "authorized_keys").unlink(missing_ok=True)
    for host_key in dropbear_dir.glob("dropbear_*_host_key"):
        host_key.unlink()
    dropbear_dir.chmod(0o700)

    # UCI files which may later contain provider tokens or wireless
    # passphrases must not be world-readable in the immutable defaults either.
    for relative in ("etc/config/ddns", "etc/config/wireless"):
        sensitive_config = root / relative
        if sensitive_config.exists():
            sensitive_config.chmod(0o600)

    # Run this after every stock, package and local overlay mutation.
    harden_immutable_permissions(root)

    print(
        "patched stock rootfs service policy and persistent configuration "
        f"(data label: {args.rootfs_data_label}, "
        f"mount policy: {'trial-safe' if args.trial_safe else 'normal'})"
    )


if __name__ == "__main__":
    main()
