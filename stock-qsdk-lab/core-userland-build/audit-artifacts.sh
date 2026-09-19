#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output=${1:-"$build_dir/candidate-out/core-userland-2026"}
report=$output/ARTIFACT-AUDIT.txt

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[ "$(uname -s)" = Linux ] || fail 'artifact audit must run inside Linux'
[ -d "$output" ] || fail "candidate directory is missing: $output"
command -v readelf >/dev/null 2>&1 || fail 'readelf is required'
command -v strings >/dev/null 2>&1 || fail 'strings is required'

tmp=$(mktemp -d "${TMPDIR:-/tmp}/sbe-core-userland-audit.XXXXXX")
cleanup() {
	case "$tmp" in
		/tmp/sbe-core-userland-audit.*|/var/tmp/sbe-core-userland-audit.*)
			rm -rf "$tmp"
			;;
	esac
}
trap cleanup EXIT HUP INT TERM

find "$output" -maxdepth 1 -type f -name '*.ipk' -print | LC_ALL=C sort > "$tmp/ipks"
[ "$(wc -l < "$tmp/ipks" | tr -d ' ')" -eq 9 ] || fail 'expected exactly nine candidate IPKs'

: > "$tmp/packages"
: > "$tmp/elfs"
while IFS= read -r ipk; do
	control=$(tar -xOzf "$ipk" ./control.tar.gz | tar -xOzf - ./control) ||
		fail "cannot read control metadata: $ipk"
	pkg=$(printf '%s\n' "$control" | sed -n 's/^Package: //p')
	[ -n "$pkg" ] || fail "missing Package field: $ipk"
	printf '%s\n' "$control" > "$tmp/$pkg.control"
	printf '%s\n' "$pkg" >> "$tmp/packages"
	pkgroot=$tmp/$pkg
	mkdir -p "$pkgroot"
	tar -xOzf "$ipk" ./data.tar.gz | tar -xzf - -C "$pkgroot"
	find "$pkgroot" \( -type f -o -type l \) -print | LC_ALL=C sort > "$tmp/$pkg.files"
	while IFS= read -r file; do
		[ -L "$file" ] && continue
		if readelf -h "$file" >/dev/null 2>&1; then
			printf '%s\n' "$file" >> "$tmp/elfs"
		fi
	done < "$tmp/$pkg.files"
done < "$tmp/ipks"

cat > "$tmp/expected-packages" <<'EOF'
sbe-odhcpd2026-ipv6only-candidate
sbe-ppp254-candidate
sbe-ppp254-mod-pppoe-candidate
sbe-rpcd2026-candidate
sbe-rpcd2026-mod-file-candidate
sbe-rpcd2026-mod-iwinfo-candidate
sbe-rpcd2026-mod-rpcsys-candidate
sbe-uhttpd2026-candidate
sbe-uhttpd2026-mod-ubus-candidate
EOF
LC_ALL=C sort "$tmp/packages" > "$tmp/packages.sorted"
cmp -s "$tmp/expected-packages" "$tmp/packages.sorted" || fail 'candidate package set differs from the locked nine-package set'

check_payload() {
	pkg=$1
	expected=$2
	actual=$tmp/$pkg.payload
	sed "s#^$tmp/$pkg##" "$tmp/$pkg.files" > "$actual"
	[ "$(wc -l < "$actual" | tr -d ' ')" -eq 1 ] || fail "$pkg has unexpected payload members"
	grep -qxF "$expected" "$actual" || fail "$pkg does not contain only $expected"
}

check_payload sbe-uhttpd2026-candidate /usr/sbin/uhttpd
check_payload sbe-uhttpd2026-mod-ubus-candidate /usr/lib/uhttpd_ubus.so
cat > "$tmp/rpcd.expected" <<'EOF'
/sbin/rpcd
/usr/share/rpcd/acl.d/unauthenticated.json
EOF
sed "s#^$tmp/sbe-rpcd2026-candidate##" \
	"$tmp/sbe-rpcd2026-candidate.files" > "$tmp/rpcd.payload"
cmp -s "$tmp/rpcd.expected" "$tmp/rpcd.payload" ||
	fail 'rpcd daemon package payload differs from daemon plus locked ACL policy'
check_payload sbe-rpcd2026-mod-file-candidate /usr/lib/rpcd/file.so
check_payload sbe-rpcd2026-mod-rpcsys-candidate /usr/lib/rpcd/rpcsys.so
check_payload sbe-rpcd2026-mod-iwinfo-candidate /usr/lib/rpcd/iwinfo.so
check_payload sbe-odhcpd2026-ipv6only-candidate /usr/sbin/odhcpd
check_payload sbe-ppp254-candidate /usr/sbin/pppd
check_payload sbe-ppp254-mod-pppoe-candidate /usr/lib/pppd/2.5.4/rp-pppoe.so

while IFS= read -r elf; do
	header=$(readelf -h "$elf")
	printf '%s\n' "$header" | grep -Eq 'Machine:[[:space:]]+AArch64' || fail "non-AArch64 ELF: $elf"
	printf '%s\n' "$header" | grep -Eq 'Type:[[:space:]]+DYN' || fail "ELF is not PIE/shared-object type: $elf"
	program=$(readelf -W -l "$elf")
	printf '%s\n' "$program" | grep -q 'GNU_RELRO' || fail "missing GNU_RELRO: $elf"
	stack=$(printf '%s\n' "$program" | grep 'GNU_STACK' || true)
	[ -n "$stack" ] || fail "missing GNU_STACK: $elf"
	printf '%s\n' "$stack" | grep -Eq '[[:space:]]RWE[[:space:]]' && fail "executable stack: $elf"
	dynamic=$(readelf -W -d "$elf")
	printf '%s\n' "$dynamic" | grep -Eq 'BIND_NOW|FLAGS.*NOW' || fail "missing full RELRO NOW binding: $elf"
	printf '%s\n' "$dynamic" | grep -Eq '\((RPATH|RUNPATH)\)' && fail "RPATH/RUNPATH present: $elf"
	strings -a "$elf" | grep -Eq '/repo/|/workspace/|/Users/|/private/tmp/|BEGIN [A-Z ]*PRIVATE KEY' &&
		fail "host path or private-key material found: $elf"
done < "$tmp/elfs"

iwinfo=$tmp/sbe-rpcd2026-mod-iwinfo-candidate/usr/lib/rpcd/iwinfo.so
readelf -W -d "$iwinfo" | grep -Eq '\(NEEDED\).+\[libiwinfo\.so\]' ||
	fail 'rpcd iwinfo plugin does not use the factory libiwinfo.so ABI name'

uhttpd=$tmp/sbe-uhttpd2026-candidate/usr/sbin/uhttpd
strings -a "$uhttpd" | grep -qxF 'libustream-ssl.so' ||
	fail 'uhttpd lost its runtime TLS library loader'
strings -a "$uhttpd" | grep -qxF 'ustream_ssl_ops' ||
	fail 'uhttpd lost its runtime TLS ops lookup'
grep -Eq '^Depends: .*libustream-openssl20150806([, ]|$)' \
	"$tmp/sbe-uhttpd2026-candidate.control" ||
	fail 'uhttpd package lost its factory ustream-ssl ABI dependency'

rpcsys=$tmp/sbe-rpcd2026-mod-rpcsys-candidate/usr/lib/rpcd/rpcsys.so
strings -a "$rpcsys" | grep -Eiq 'sysupgrade|jffs2reset|firmware|factory|upgrade_test|validate_firmware_image' &&
	fail 'rpcsys exposes a firmware-write/reset surface'

pppd=$tmp/sbe-ppp254-candidate/usr/sbin/pppd
pppoe=$tmp/sbe-ppp254-mod-pppoe-candidate/usr/lib/pppd/2.5.4/rp-pppoe.so
strings -a "$pppd" "$pppoe" | grep -Eiq 'radiusclient|pptp\.so|eap[-_]tls|private[._ -]?key[._ -]?password' &&
	fail 'PPP payload contains a disabled RADIUS/PPTP/EAP-TLS surface or credential'

{
	printf 'core-userland-2026 artifact audit: PASS\n'
	printf 'packages=9\n'
	printf 'payload_members=10\n'
	printf 'elf_machine=AArch64\n'
	printf 'pie_nx_full_relro=yes\n'
	printf 'rpath_runpath=none\n'
	printf 'host_path_private_key_leaks=none\n'
	printf 'rpcsys_firmware_write_surface=none\n'
	printf 'ppp_plugin_dir=/usr/lib/pppd/2.5.4\n'
	printf 'hardware_pd_ra_ndp_pppoe=BLOCKED_NOT_RUN\n'
} > "$report"

printf 'PASS: nine exact payloads are AArch64, PIE/NX/full-RELRO, path-clean and feature-bounded.\n'
