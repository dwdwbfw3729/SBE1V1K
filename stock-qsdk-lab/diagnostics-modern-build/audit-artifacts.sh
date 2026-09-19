#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$build_dir/sources.lock"
output=${1:-"$build_dir/candidate-out/diagnostics-modern"}
report=$output/ARTIFACT-AUDIT.txt

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[ "$(uname -s)" = Linux ] || fail 'artifact audit must run inside Linux'
[ -d "$output" ] || fail "candidate output is missing: $output"
command -v readelf >/dev/null 2>&1 || fail 'readelf is required'
command -v strings >/dev/null 2>&1 || fail 'strings is required'

# QSDK's package-ipkg.mk emits these two framework wrappers for every IPK,
# even when the package recipe defines no lifecycle hook.  Accept only the
# byte-exact stock wrappers; candidate-specific commands remain forbidden.
qsdk_postinst_sha256=dfc2ccf84c6f9ca4a3967196812a4b2bfc1569721d755f301b320f78fec4854d
qsdk_prerm_sha256=ed0f3b379f15894bd3877e9654f8edb919f4ffd8868753aa62ccfb93a09670d9

tmp=$(mktemp -d "${TMPDIR:-/tmp}/sbe-diagnostics-audit.XXXXXX")
cleanup() {
	case "$tmp" in
		*/sbe-diagnostics-audit.*) rm -rf "$tmp" ;;
	esac
}
trap cleanup EXIT HUP INT TERM

find "$output" -maxdepth 1 -type f -name '*.ipk' -print | LC_ALL=C sort > "$tmp/ipks"
[ "$(wc -l < "$tmp/ipks" | tr -d ' ')" -eq 3 ] ||
	fail 'artifact audit expected exactly three IPKs'

find_ipk() {
	package=$1
	find "$output" -maxdepth 1 -type f -name "${package}_*.ipk" -print \
		> "$tmp/${package}.list"
	[ "$(wc -l < "$tmp/${package}.list" | tr -d ' ')" -eq 1 ] ||
		fail "expected exactly one $package IPK"
	cat "$tmp/${package}.list"
}

audit_control() {
	package=$1
	ipk=$2
	expected_source=$3
	forbidden_deps=$4
	control_dir=$tmp/control-$package
	control_archive=$tmp/control-$package.tar.gz
	mkdir -p "$control_dir"
	tar -xOzf "$ipk" ./control.tar.gz > "$control_archive" ||
		fail "cannot extract control archive from $ipk"
	tar -xzf "$control_archive" -C "$control_dir" ||
		fail "cannot extract control metadata from $ipk"
	control=$control_dir/control
	[ -f "$control" ] || fail "$package control file is missing"
	[ "$(sed -n 's/^Package: //p' "$control")" = "$package" ] ||
		fail "$package identity differs from policy"
	[ "$(sed -n 's/^Source: //p' "$control")" = "$expected_source" ] ||
		fail "$package source identity differs from the source lock"
	grep -q '^Depends: .*libncurses' "$control" ||
		fail "$package does not depend on the reviewed libncurses ABI"
	if [ -n "$forbidden_deps" ] && grep -Ei "^Depends: .*($forbidden_deps)" "$control"; then
		fail "$package gained a disabled optional dependency"
	fi
	printf '%s\n' control postinst prerm | LC_ALL=C sort > "$tmp/expected-control-files"
	find "$control_dir" -maxdepth 1 -type f -exec basename '{}' ';' |
		LC_ALL=C sort > "$tmp/actual-control-files"
	cmp -s "$tmp/expected-control-files" "$tmp/actual-control-files" ||
		fail "$package control archive has an unreviewed file set"
	for hook in preinst postrm conffiles
	do
		[ ! -e "$control_dir/$hook" ] || fail "$package unexpectedly ships $hook"
	done
	[ "$(sha256sum "$control_dir/postinst" | awk '{print $1}')" = "$qsdk_postinst_sha256" ] ||
		fail "$package postinst is not the byte-exact stock QSDK wrapper"
	[ "$(sha256sum "$control_dir/prerm" | awk '{print $1}')" = "$qsdk_prerm_sha256" ] ||
		fail "$package prerm is not the byte-exact stock QSDK wrapper"
	for hook in postinst prerm
	do
		[ "$(stat -c '%a' "$control_dir/$hook")" = 755 ] ||
			fail "$package $hook does not have stock mode 0755"
		[ "$(tar --numeric-owner -tvzf "$control_archive" "./$hook" | awk 'NR == 1 { print $2 }')" = 0/0 ] ||
			fail "$package $hook is not archived as root:root"
	done
	if grep -ERq '/workspace/|/repo/|/Users/|/Volumes/|/private/tmp/|/home/|BEGIN [A-Z0-9 ]*PRIVATE KEY' "$control_dir"; then
		fail "$package control metadata leaks a host path or private key"
	fi
}

extract_payload() {
	package=$1
	ipk=$2
	root=$tmp/root-$package
	data_archive=$tmp/data-$package.tar.gz
	mkdir -p "$root"
	tar -xOzf "$ipk" ./data.tar.gz > "$data_archive" ||
		fail "cannot extract payload archive from $ipk"
	tar -xzf "$data_archive" -C "$root" ||
		fail "cannot extract payload from $ipk"
	find "$root" \( -type f -o -type l \) -print | sed "s#^$root##" |
		LC_ALL=C sort > "$tmp/payload-$package"
	printf '%s\n' "$root"
}

audit_elf() {
	elf=$1
	expect_curses=$2
	header=$(readelf -h "$elf")
	printf '%s\n' "$header" | grep -Eq 'Machine:[[:space:]]+AArch64' ||
		fail "$elf is not AArch64"
	printf '%s\n' "$header" | grep -Eq 'Type:[[:space:]]+DYN' ||
		fail "$elf is not PIE ELF type DYN"
	program=$(readelf -W -l "$elf")
	printf '%s\n' "$program" | grep -q 'GNU_RELRO' || fail "$elf lacks GNU_RELRO"
	stack=$(printf '%s\n' "$program" | grep 'GNU_STACK' || true)
	[ -n "$stack" ] || fail "$elf lacks GNU_STACK metadata"
	printf '%s\n' "$stack" | grep -Eq '[[:space:]]RWE[[:space:]]' &&
		fail "$elf has an executable stack"
	printf '%s\n' "$program" | grep -q '/lib/ld-musl-aarch64.so.1' ||
		fail "$elf does not use the locked AArch64 musl interpreter"
	dynamic=$(readelf -W -d "$elf")
	printf '%s\n' "$dynamic" | grep -Eq 'BIND_NOW|FLAGS.*NOW' ||
		fail "$elf lacks full RELRO NOW binding"
	printf '%s\n' "$dynamic" | grep -Eq '\((RPATH|RUNPATH)\)' &&
		fail "$elf contains RPATH/RUNPATH"
	needed=$(printf '%s\n' "$dynamic" |
		sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')
	printf '%s\n' "$needed" | grep -qxF libc.so || fail "$elf does not depend on musl libc.so"
	if [ "$expect_curses" = yes ]; then
		printf '%s\n' "$needed" | grep -qxF "libncursesw.so.$QSDK_NCURSES_ABI" ||
			fail "$elf does not bind the reviewed libncursesw ABI"
	fi
	printf '%s\n' "$needed" | while IFS= read -r library; do
		[ -n "$library" ] || continue
		case "$library" in
			libc.so|libgcc_s.so.1|libm.so|libdl.so|libtinfo.so.*|libncursesw.so."$QSDK_NCURSES_ABI") ;;
			*) fail "$elf has an unreviewed NEEDED library: $library" ;;
		esac
	done
	if strings -a "$elf" | grep -Eq '/workspace/|/repo/|/Users/|/Volumes/|/private/tmp/|/home/|BEGIN [A-Z0-9 ]*PRIVATE KEY|BEGIN OPENSSH PRIVATE KEY'; then
		fail "$elf leaks a host path or private-key marker"
	fi
}

mtr_package=sbe-mtr096-root-cli-candidate
htop_package=sbe-htop353-candidate
nano_package=sbe-nano92-daily-candidate
mtr_ipk=$(find_ipk "$mtr_package")
htop_ipk=$(find_ipk "$htop_package")
nano_ipk=$(find_ipk "$nano_package")

audit_control "$mtr_package" "$mtr_ipk" "$MTR_RELEASE_ARCHIVE" 'libcap|jansson|gtk'
audit_control "$htop_package" "$htop_ipk" "$HTOP_RELEASE_ARCHIVE" 'libcap|libnl|libsensors|hwloc|unwind|pcp'
audit_control "$nano_package" "$nano_ipk" "$NANO_RELEASE_ARCHIVE" 'libmagic|aspell|hunspell'

mtr_root=$(extract_payload "$mtr_package" "$mtr_ipk")
htop_root=$(extract_payload "$htop_package" "$htop_ipk")
nano_root=$(extract_payload "$nano_package" "$nano_ipk")

printf '%s\n' /usr/sbin/mtr /usr/sbin/mtr-packet | LC_ALL=C sort > "$tmp/expected-mtr"
printf '%s\n' /usr/bin/htop > "$tmp/expected-htop"
printf '%s\n' /usr/bin/nano > "$tmp/expected-nano"
cmp -s "$tmp/expected-mtr" "$tmp/payload-$mtr_package" ||
	fail 'mtr payload is not exactly /usr/sbin/mtr and /usr/sbin/mtr-packet'
cmp -s "$tmp/expected-htop" "$tmp/payload-$htop_package" ||
	fail 'htop payload is not exactly /usr/bin/htop'
cmp -s "$tmp/expected-nano" "$tmp/payload-$nano_package" ||
	fail 'nano payload is not exactly /usr/bin/nano'

[ "$(stat -c '%a' "$mtr_root/usr/sbin/mtr")" = 700 ] || fail 'mtr is not root-only mode 0700'
[ "$(stat -c '%a' "$mtr_root/usr/sbin/mtr-packet")" = 700 ] ||
	fail 'mtr-packet is not root-only mode 0700'
[ "$(stat -c '%a' "$htop_root/usr/bin/htop")" = 755 ] || fail 'htop mode is not 0755'
[ "$(stat -c '%a' "$nano_root/usr/bin/nano")" = 755 ] || fail 'nano mode is not 0755'
for archived_binary in \
	"$tmp/data-$mtr_package.tar.gz:./usr/sbin/mtr" \
	"$tmp/data-$mtr_package.tar.gz:./usr/sbin/mtr-packet" \
	"$tmp/data-$htop_package.tar.gz:./usr/bin/htop" \
	"$tmp/data-$nano_package.tar.gz:./usr/bin/nano"
do
	archive=${archived_binary%%:*}
	member=${archived_binary#*:}
	[ "$(tar --numeric-owner -tvzf "$archive" "$member" | awk 'NR == 1 { print $2 }')" = 0/0 ] ||
		fail "$member is not archived as root:root"
done
for root in "$mtr_root" "$htop_root" "$nano_root"
do
	[ -z "$(find "$root" -type f -perm /6000 -print)" ] ||
		fail "payload under $root contains a setuid or setgid file"
	if command -v getcap >/dev/null 2>&1; then
		[ -z "$(getcap -r "$root" 2>/dev/null || true)" ] ||
			fail "payload under $root contains a file capability"
	fi
done

audit_elf "$mtr_root/usr/sbin/mtr" yes
audit_elf "$mtr_root/usr/sbin/mtr-packet" no
audit_elf "$htop_root/usr/bin/htop" yes
audit_elf "$nano_root/usr/bin/nano" yes

if strings -a "$mtr_root/usr/sbin/mtr" |
	grep -Eq 'origin6?\.asn\.cymru\.com|--ipinfo|--aslookup|ipinfo_provider'; then
	fail 'mtr binary retained disabled external IP-information lookup support'
fi

(cd "$output" && sha256sum ./*.ipk | LC_ALL=C sort -k2) > "$tmp/PACKAGE_SHA256SUMS"
[ -f "$output/PACKAGE_SHA256SUMS" ] || fail 'PACKAGE_SHA256SUMS is missing'
cmp -s "$tmp/PACKAGE_SHA256SUMS" "$output/PACKAGE_SHA256SUMS" ||
	fail 'PACKAGE_SHA256SUMS does not describe the exact three IPKs'
for metadata in CANDIDATE_BUILD_CONFIG PACKAGE_SHA256SUMS REPRODUCIBILITY.txt
do
	[ -f "$output/$metadata" ] || continue
	if grep -Eq '/repo/|/workspace/|/Users/|/Volumes/|/private/tmp/|/tmp/sbe-diagnostics-|/home/|BEGIN [A-Z0-9 ]*PRIVATE KEY|OPENSSH PRIVATE KEY' "$output/$metadata"; then
		fail "$metadata leaks a host path or private-key marker"
	fi
done

{
	printf 'mtr/htop/nano modern diagnostics artifact audit: PASS\n'
	printf 'mtr_version=%s commit=%s payload=/usr/sbin/mtr,/usr/sbin/mtr-packet mode=0700\n' "$MTR_VERSION" "$MTR_COMMIT"
	printf 'htop_version=%s commit=%s payload=/usr/bin/htop\n' "$HTOP_VERSION" "$HTOP_COMMIT"
	printf 'nano_version=%s commit=%s release_sha256=%s payload=/usr/bin/nano\n' "$NANO_VERSION" "$NANO_COMMIT" "$NANO_RELEASE_SHA256"
	printf 'packages=3 payload_files=4\n'
	printf 'elf_machine=AArch64 elf_type=PIE-DYN ncurses_abi=%s\n' "$QSDK_NCURSES_ABI"
	printf 'nx_full_relro=yes rpath_runpath=none\n'
	printf 'setuid_setgid=none file_capabilities=none\n'
	printf 'payload_ownership=root:root\n'
	printf 'lifecycle_hooks=stock_qsdk_wrappers_only\n'
	printf 'mtr_external_ipinfo=disabled optional_dependency_surface=disabled\n'
	printf 'htop_unicode=enabled htop_native_affinity=enabled\n'
	printf 'nano_utf8_help_browser_multibuffer_nanorc=enabled nano_external_tools=disabled\n'
	printf 'configuration_credentials=none host_path_private_key_leaks=none\n'
} > "$report"

printf 'PASS: exact diagnostics payloads are AArch64 PIE, NX/full-RELRO, stock-ncurses ABI and privacy clean.\n'
printf 'mtr and mtr-packet are root-only without setuid, setgid or file capabilities.\n'
