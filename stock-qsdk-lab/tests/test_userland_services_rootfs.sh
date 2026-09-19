#!/bin/sh
set -eu

root=${1:?usage: test_userland_services_rootfs.sh ASSEMBLED_ROOTFS LAB_DIR}
lab=${2:?usage: test_userland_services_rootfs.sh ASSEMBLED_ROOTFS LAB_DIR}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

assert_control() {
	package=$1
	version=$2
	control=$root/usr/lib/opkg/info/$package.control
	[ -f "$control" ] || fail "missing canonical control record: $package"
	[ "$(sed -n 's/^Package: //p' "$control")" = "$package" ] ||
		fail "wrong canonical package identity: $package"
	[ "$(sed -n 's/^Version: //p' "$control")" = "$version" ] ||
		fail "wrong canonical package version: $package"
}

[ -d "$root" ] && [ ! -L "$root" ] || fail 'assembled rootfs is missing or unsafe'
[ -f "$lab/component-profiles/production.json" ] ||
	fail 'production source profile is missing'

[ -x "$root/sbin/ujail" ] || fail 'ABI-matched ujail is missing from the rootfs'
for binary in dnsmasq miniupnpd ntpdate
do
	[ "$(stat -c '%u:%g:%a' "$root/usr/sbin/$binary")" = 0:0:755 ] ||
		fail "wrong ownership or mode for $binary"
	grep -a -i -F opensync "$root/usr/sbin/$binary" >/dev/null 2>&1 &&
		fail "$binary contains an OpenSync marker"
done

assert_control dnsmasq-full 2.93-1-qsdk3
assert_control miniupnpd 2.3.11-1-sbe1
assert_control ntpdate 4.2.8p18-2-sbe1
for legacy in \
	dnsmasq \
	dnsmasq-dhcpv6 \
	sbe-dnsmasq293-candidate \
	sbe-miniupnpd2311-candidate \
	sbe-ntpdate4218-candidate \
	ntfs-3g \
	sbe-ntfs3g2026-candidate
do
	[ ! -e "$root/usr/lib/opkg/info/$legacy.control" ] ||
		fail "forbidden stale/research package metadata remains: $legacy"
done
for staging in \
	usr/libexec/sbe-qsdk-lab/dnsmasq-2.93 \
	usr/libexec/sbe-qsdk-lab/ntpdate-4.2.8p18
do
	[ ! -e "$root/$staging" ] || fail "isolated staging payload remains: /$staging"
done

python3 - "$root" "$lab" <<'PY'
import hashlib
import json
import pathlib
import shlex
import sys

root = pathlib.Path(sys.argv[1])
lab = pathlib.Path(sys.argv[2])
profile_path = lab / "component-profiles/production.json"
profile_raw = profile_path.read_bytes()
profile = json.loads(profile_raw)
report = json.loads((root / "usr/share/sbe-build/component-profile.json").read_text())
assert report["name"] == "production"
assert report["release_state"] == "production"
assert report["profile_sha256"] == hashlib.sha256(profile_raw).hexdigest()

packages = {item["name"]: item for item in profile["packages"]}
for name in ("dnsmasq-full", "miniupnpd", "ntpdate"):
    package = packages[name]
    expected = "\n".join(sorted(package["candidate_paths"] + package["retained_paths"])) + "\n"
    actual = (root / f"usr/lib/opkg/info/{name}.list").read_text()
    assert actual == expected, f"canonical path list differs for {name}"


def parse_uci_config(path):
    sections = []
    current = None
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        try:
            fields = shlex.split(line, comments=True, posix=True)
        except ValueError as error:
            raise AssertionError(f"{path}:{lineno}: invalid UCI syntax: {error}") from error
        if not fields:
            continue
        if fields[0] == "config":
            assert len(fields) in (2, 3), (
                f"{path}:{lineno}: invalid UCI config declaration"
            )
            current = {
                "type": fields[1],
                "name": fields[2] if len(fields) == 3 else None,
                "options": {},
            }
            sections.append(current)
        elif fields[0] == "option":
            assert current is not None and len(fields) == 3, (
                f"{path}:{lineno}: invalid UCI option declaration"
            )
            current["options"][fields[1]] = fields[2]
    return sections


def require_uci_option(
    sections,
    section_type,
    section_name,
    option,
    expected,
):
    matches = [
        section
        for section in sections
        if section["type"] == section_type
        and (section_name is None or section["name"] == section_name)
    ]
    assert len(matches) == 1, (
        f"DHCP/DNS safe default requires exactly one {section_type!r} "
        f"section{f' named {section_name!r}' if section_name else ''}"
    )
    actual = matches[0]["options"].get(option)
    assert actual == expected, (
        f"DHCP/DNS safe default {section_type}."
        f"{section_name + '.' if section_name else ''}{option}="
        f"{expected!r} is missing or is {actual!r}"
    )


dhcp_sections = parse_uci_config(root / "etc/config/dhcp")
for requirement in (
    ("dnsmasq", None, "resolvfile", "/tmp/resolv.conf.d/resolv.conf.auto"),
    ("dnsmasq", None, "rebind_protection", "1"),
    ("dnsmasq", None, "localservice", "1"),
    ("dhcp", "lan", "dhcpv6", "server"),
    ("dhcp", "lan", "ra", "server"),
    ("dhcp", "wan", "ignore", "1"),
):
    require_uci_option(dhcp_sections, *requirement)

# Validate both ends of the resolver contract, including the first-boot script
# which previously changed the otherwise correct image default to an empty file.
netifd = (root / "sbin/netifd").read_bytes()
assert b"/tmp/resolv.conf.auto\0" in netifd, "vendor netifd default unexpectedly changed"
network = (root / "etc/init.d/network").read_text()
assert 'procd_set_param command /sbin/netifd -r /tmp/resolv.conf.d/resolv.conf.auto' in network
migration = (root / "etc/uci-defaults/50-dnsmasq-migrate-resolv-conf-auto.sh").read_text()
assert 'uci set dhcp.@dnsmasq[0].resolvfile="/tmp/resolv.conf.auto"' not in migration
assert 'uci set dhcp.@dnsmasq[0].resolvfile="/tmp/resolv.conf.d/resolv.conf.auto"' in migration
dnsmasq_init = (root / "etc/init.d/dnsmasq").read_text()
assert '$dnsmasqconfdir $resolvdir $user_dhcpscript' in dnsmasq_init
assert '$dnsmasqconfdir $resolvfile $user_dhcpscript' not in dnsmasq_init

serialized = profile_raw.lower()
assert b"ntfs-3g" not in serialized
assert b"ntfs3g" not in serialized
PY

upnp=$root/etc/config/upnpd
grep -Eq "option[[:space:]]+enabled[[:space:]]+['\"]?0" "$upnp" ||
	fail 'MiniUPnPd is not disabled by default'
grep -Eq "option[[:space:]]+secure_mode[[:space:]]+['\"]?1" "$upnp" ||
	fail 'MiniUPnPd secure_mode is not enabled'
grep -Eq "option[[:space:]]+ext_ports[[:space:]]+['\"]?1024-65535" "$upnp" ||
	fail 'MiniUPnPd high-port allow boundary is missing'
grep -Eq "option[[:space:]]+action[[:space:]]+['\"]?deny" "$upnp" ||
	fail 'MiniUPnPd terminal deny rule is missing'

dnsmasq_init=$root/etc/init.d/dnsmasq
grep -Fq 'if [ "$resolvfile" = "/tmp/resolv.conf.d/resolv.conf.auto" ]; then' \
	"$dnsmasq_init" || fail 'dnsmasq migrated resolver path is not narrowly guarded'
grep -Fq '[ ! -L /tmp/resolv.conf.d ] || return 1' "$dnsmasq_init" ||
	fail 'dnsmasq resolver directory does not reject symlinks'
grep -Fq 'stat -c %u /tmp/resolv.conf.d' "$dnsmasq_init" ||
	fail 'dnsmasq resolver directory ownership is not verified'
grep -Fq 'stat -c %u "$resolvfile"' "$dnsmasq_init" ||
	fail 'dnsmasq resolver file ownership is not verified'
mkdir_line=$(grep -nF 'mkdir -p /tmp/resolv.conf.d || return 1' "$dnsmasq_init" | cut -d: -f1)
touch_line=$(grep -nF '&& touch "$resolvfile"' "$dnsmasq_init" | cut -d: -f1)
[ -n "$mkdir_line" ] && [ -n "$touch_line" ] && [ "$mkdir_line" -lt "$touch_line" ] ||
	fail 'dnsmasq does not create the volatile resolver directory before touch'
grep -F 'mkdir -p "$(dirname "$resolvfile")"' "$dnsmasq_init" >/dev/null 2>&1 &&
	fail 'dnsmasq may create a configured non-tmpfs resolver directory'

[ -L "$root/usr/sbin/ntpd" ] || fail 'native ntpd applet link is missing'
[ ! -e "$root/usr/sbin/sbe-timesync" ] || fail 'obsolete time service remains'
for script in \
	etc/init.d/dnsmasq \
	etc/init.d/miniupnpd \
	etc/init.d/sysntpd \
	etc/uci-defaults/50-dnsmasq-migrate-resolv-conf-auto.sh \
	usr/sbin/ntpd-hotplug
do
	sh -n "$root/$script" || fail "shell syntax failed: /$script"
done

printf 'PASS: dnsmasq, MiniUPnPd and native sysntpd rootfs integration.\n'
