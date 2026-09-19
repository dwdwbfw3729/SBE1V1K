#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$build_dir/sources.lock"
output=${1:-"$build_dir/candidate-out/userland-modern"}
report=$output/ARTIFACT-AUDIT.txt

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[ "$(uname -s)" = Linux ] || fail 'artifact audit must run inside Linux'
[ -d "$output" ] || fail "candidate output is missing: $output"
command -v readelf >/dev/null 2>&1 || fail 'readelf is required'
command -v strings >/dev/null 2>&1 || fail 'strings is required'

tmp=$(mktemp -d "${TMPDIR:-/tmp}/sbe-userland-audit.XXXXXX")
cleanup() {
	case "$tmp" in
		/tmp/sbe-userland-audit.*|/var/tmp/sbe-userland-audit.*) rm -rf "$tmp" ;;
	esac
}
trap cleanup EXIT HUP INT TERM

# QSDK 12.2's package framework unconditionally emits these two generic
# lifecycle wrappers for every IPK.  They contain no package-specific action,
# but treating them as absent would make the audit reject every genuine QSDK
# package.  Accept only the exact framework templates and reject all other
# maintainer scripts below.
cat > "$tmp/expected-postinst" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -x ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
EOF
cat > "$tmp/expected-prerm" <<'EOF'
#!/bin/sh
[ -x ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 $@
EOF

find "$output" -maxdepth 1 -type f -name '*.ipk' -print | LC_ALL=C sort > "$tmp/ipks"
[ "$(wc -l < "$tmp/ipks" | tr -d ' ')" -eq 3 ] ||
	fail 'artifact audit expected exactly three IPKs'

find_ipk() {
	package=$1
	find "$output" -maxdepth 1 -type f -name "${package}_*.ipk" -print > "$tmp/$package.list"
	[ "$(wc -l < "$tmp/$package.list" | tr -d ' ')" -eq 1 ] ||
		fail "expected exactly one $package IPK"
	cat "$tmp/$package.list"
}

audit_control() {
	package=$1
	ipk=$2
	expected_version=$3
	expected_source=$4
	control_root=$tmp/control-$package
	mkdir -p "$control_root"
	tar -xOzf "$ipk" ./control.tar.gz | tar -xzf - -C "$control_root" ||
		fail "cannot extract control metadata from $ipk"
	control=$control_root/control
	[ "$(sed -n 's/^Package: //p' "$control")" = "$package" ] ||
		fail "$package control identity differs from policy"
	[ "$(sed -n 's/^Version: //p' "$control")" = "$expected_version" ] ||
		fail "$package version differs from policy"
	[ "$(sed -n 's/^Source: //p' "$control")" = "$expected_source" ] ||
		fail "$package source identity differs from the source lock"
	for hook in preinst postrm conffiles; do
		[ ! -e "$control_root/$hook" ] || fail "$package unexpectedly ships $hook"
	done
	cmp -s "$control_root/postinst" "$tmp/expected-postinst" ||
		fail "$package postinst differs from the inert QSDK framework template"
	cmp -s "$control_root/prerm" "$tmp/expected-prerm" ||
		fail "$package prerm differs from the inert QSDK framework template"
	if grep -ERq '/workspace/|/repo/|/Users/|/Volumes/|/private/tmp/|/home/|BEGIN [A-Z0-9 ]*PRIVATE KEY' \
		"$control_root"; then
		fail "$package metadata leaks a host path or private key"
	fi
}

extract_payload() {
	package=$1
	ipk=$2
	root=$tmp/root-$package
	mkdir -p "$root"
	tar -xOzf "$ipk" ./data.tar.gz | tar -xzf - -C "$root" ||
		fail "cannot extract payload from $ipk"
	find "$root" \( -type f -o -type l \) -print | sed "s#^$root##" | \
		LC_ALL=C sort > "$tmp/payload-$package"
	printf '%s\n' "$root"
}

audit_tree() {
	root=$1
	[ -z "$(find "$root" -type f -perm /6000 -print)" ] ||
		fail "$root contains a setuid or setgid file"
	[ -z "$(find "$root" -type f -perm -0002 -print)" ] ||
		fail "$root contains a world-writable regular file"
	if command -v getcap >/dev/null 2>&1; then
		[ -z "$(getcap -r "$root" 2>/dev/null || true)" ] ||
			fail "$root contains a file capability"
	fi
	find "$root" -type f -print | while IFS= read -r file; do
		readelf -h "$file" >/dev/null 2>&1 || continue
		header=$(readelf -h "$file")
		printf '%s\n' "$header" | grep -Eq 'Machine:[[:space:]]+AArch64' ||
			fail "$file is not AArch64"
		printf '%s\n' "$header" | grep -Eq 'Type:[[:space:]]+DYN' ||
			fail "$file is not PIE/shared-object type DYN"
		program=$(readelf -W -l "$file")
		printf '%s\n' "$program" | grep -q GNU_RELRO || fail "$file lacks GNU_RELRO"
		stack=$(printf '%s\n' "$program" | grep GNU_STACK || true)
		[ -n "$stack" ] || fail "$file lacks GNU_STACK metadata"
		if printf '%s\n' "$stack" | grep -Eq '[[:space:]]RWE[[:space:]]'; then
			fail "$file has an executable stack"
		fi
		dynamic=$(readelf -W -d "$file")
		printf '%s\n' "$dynamic" | grep -Eq 'BIND_NOW|FLAGS.*NOW' ||
			fail "$file lacks full RELRO NOW binding"
		if printf '%s\n' "$dynamic" | grep -Eq '\((RPATH|RUNPATH)\)'; then
			fail "$file contains RPATH/RUNPATH"
		fi
		if strings -a "$file" | grep -Eq '/workspace/|/repo/|/Users/|/Volumes/|/private/tmp/|/home/|BEGIN [A-Z0-9 ]*PRIVATE KEY'; then
			fail "$file leaks a host path or private-key marker"
		fi
	done
}

mini_package=sbe-miniupnpd2311-candidate
ntfs_package=sbe-ntfs3g2026-candidate
ntp_package=sbe-ntpdate4218-candidate
mini_ipk=$(find_ipk "$mini_package")
ntfs_ipk=$(find_ipk "$ntfs_package")
ntp_ipk=$(find_ipk "$ntp_package")

audit_control "$mini_package" "$mini_ipk" "$MINIUPNPD_VERSION-1" "$MINIUPNPD_ARCHIVE"
audit_control "$ntfs_package" "$ntfs_ipk" "$NTFS3G_VERSION-1" "$NTFS3G_ARCHIVE"
audit_control "$ntp_package" "$ntp_ipk" "$NTP_VERSION-2" "$NTP_ARCHIVE"

mini_root=$(extract_payload "$mini_package" "$mini_ipk")
ntfs_root=$(extract_payload "$ntfs_package" "$ntfs_ipk")
ntp_root=$(extract_payload "$ntp_package" "$ntp_ipk")

printf '%s\n' /usr/sbin/miniupnpd > "$tmp/expected-mini"
printf '%s\n' /usr/libexec/sbe-qsdk-lab/ntpdate-4.2.8p18 > "$tmp/expected-ntp"
cmp -s "$tmp/expected-mini" "$tmp/payload-$mini_package" ||
	fail 'MiniUPnPd candidate payload is not exactly /usr/sbin/miniupnpd'
cmp -s "$tmp/expected-ntp" "$tmp/payload-$ntp_package" ||
	fail 'NTP candidate payload is not exactly the isolated ntpdate binary'

for path in \
	/usr/bin/ntfs-3g \
	/usr/bin/ntfs-3g.probe \
	/sbin/mount.ntfs \
	/sbin/mount.ntfs-3g
do
	grep -qxF "$path" "$tmp/payload-$ntfs_package" ||
		fail "NTFS research candidate is missing $path"
done
grep -Eq '^/usr/lib/libntfs-3g\.so\.' "$tmp/payload-$ntfs_package" ||
	fail 'NTFS research candidate is missing its private shared library ABI'

audit_tree "$mini_root"
audit_tree "$ntfs_root"
audit_tree "$ntp_root"

strings -a "$mini_root/usr/sbin/miniupnpd" | grep -qF "$MINIUPNPD_VERSION" ||
	fail 'MiniUPnPd binary lacks the locked release marker'
strings -a "$ntp_root/usr/libexec/sbe-qsdk-lab/ntpdate-4.2.8p18" | grep -qF "$NTP_VERSION" ||
	fail 'ntpdate binary lacks the locked release marker'
if readelf -W -d "$ntp_root/usr/libexec/sbe-qsdk-lab/ntpdate-4.2.8p18" |
	grep -Eq 'libssl|libcrypto|libevent'; then
	fail 'ntpdate gained an intentionally disabled crypto/event dependency'
fi

(cd "$output" && sha256sum ./*.ipk | LC_ALL=C sort -k2) > "$tmp/PACKAGE_SHA256SUMS"
[ -f "$output/PACKAGE_SHA256SUMS" ] || fail 'PACKAGE_SHA256SUMS is missing'
cmp -s "$tmp/PACKAGE_SHA256SUMS" "$output/PACKAGE_SHA256SUMS" ||
	fail 'PACKAGE_SHA256SUMS does not describe the exact three IPKs'

{
	printf 'maintained userland artifact audit: PASS\n'
	printf 'miniupnpd_version=%s release_eligible=yes payload=/usr/sbin/miniupnpd\n' "$MINIUPNPD_VERSION"
	printf 'ntpdate_version=%s release_eligible=yes payload=/usr/libexec/sbe-qsdk-lab/ntpdate-4.2.8p18\n' "$NTP_VERSION"
	printf 'ntfs3g_version=%s release_eligible=no reason=no-exposed-usb-connector\n' "$NTFS3G_VERSION"
	printf 'packages=3 elf_machine=AArch64 pie_nx_full_relro=yes rpath_runpath=none\n'
	printf 'setuid_setgid=none file_capabilities=none host_path_private_key_leaks=none\n'
	printf 'upnp_firewall_lifecycle=BLOCKED_NOT_RUN ntp_wan_step_slew=BLOCKED_NOT_RUN\n'
} > "$report"

printf 'PASS: MiniUPnPd/NTP candidates are bounded and hardened; NTFS remains research-only.\n'
