#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$build_dir/sources.lock"
output=${1:-"$build_dir/candidate-out/cgi-io-security"}
report=$output/ARTIFACT-AUDIT.txt

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[ "$(uname -s)" = Linux ] || fail 'artifact audit must run inside Linux'
[ -d "$output" ] || fail "candidate directory is missing: $output"
command -v readelf >/dev/null 2>&1 || fail 'readelf is required'
command -v strings >/dev/null 2>&1 || fail 'strings is required'

tmp=$(mktemp -d "${TMPDIR:-/tmp}/sbe-cgi-io-audit.XXXXXX")
cleanup() {
	case "$tmp" in
		/tmp/sbe-cgi-io-audit.*|/var/tmp/sbe-cgi-io-audit.*) rm -rf "$tmp" ;;
	esac
}
trap cleanup EXIT HUP INT TERM

find "$output" -maxdepth 1 -type f -name '*.ipk' -print | LC_ALL=C sort > "$tmp/ipks"
[ "$(wc -l < "$tmp/ipks" | tr -d ' ')" -eq 1 ] || fail 'expected exactly one candidate IPK'
ipk=$(cat "$tmp/ipks")
control=$(tar -xOzf "$ipk" ./control.tar.gz | tar -xOzf - ./control) ||
	fail 'cannot read candidate control metadata'
[ "$(printf '%s\n' "$control" | sed -n 's/^Package: //p')" = \
	'sbe-cgi-io2026-security-candidate' ] || fail 'unexpected package identity'
[ "$(printf '%s\n' "$control" | sed -n 's/^Source: //p')" = "$CGI_IO_ARCHIVE" ] ||
	fail 'unexpected package source identity'

root=$tmp/root
mkdir -p "$root"
tar -xOzf "$ipk" ./data.tar.gz | tar -xzf - -C "$root"
find "$root" \( -type f -o -type l \) -print | sed "s#^$root##" | LC_ALL=C sort > "$tmp/payload"
[ "$(wc -l < "$tmp/payload" | tr -d ' ')" -eq 1 ] || fail 'candidate payload is not exactly one member'
grep -qxF '/usr/libexec/cgi-io' "$tmp/payload" || fail 'candidate payload is not only /usr/libexec/cgi-io'
[ -f "$root/usr/libexec/cgi-io" ] && [ ! -L "$root/usr/libexec/cgi-io" ] ||
	fail 'cgi-io payload must be one regular executable'

elf=$root/usr/libexec/cgi-io
header=$(readelf -h "$elf")
printf '%s\n' "$header" | grep -Eq 'Machine:[[:space:]]+AArch64' || fail 'cgi-io is not AArch64'
printf '%s\n' "$header" | grep -Eq 'Type:[[:space:]]+DYN' || fail 'cgi-io is not PIE ELF type DYN'
program=$(readelf -W -l "$elf")
printf '%s\n' "$program" | grep -q 'GNU_RELRO' || fail 'cgi-io lacks GNU_RELRO'
stack=$(printf '%s\n' "$program" | grep 'GNU_STACK' || true)
[ -n "$stack" ] || fail 'cgi-io lacks GNU_STACK metadata'
printf '%s\n' "$stack" | grep -Eq '[[:space:]]RWE[[:space:]]' && fail 'cgi-io has an executable stack'
dynamic=$(readelf -W -d "$elf")
printf '%s\n' "$dynamic" | grep -Eq 'BIND_NOW|FLAGS.*NOW' || fail 'cgi-io lacks full RELRO NOW binding'
printf '%s\n' "$dynamic" | grep -Eq '\((RPATH|RUNPATH)\)' && fail 'cgi-io contains RPATH/RUNPATH'
needed=$(printf '%s\n' "$dynamic" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' | LC_ALL=C sort)
[ "$needed" = "$(printf '%s\n' libc.so libubox.so libubus.so.20210603 | LC_ALL=C sort)" ] ||
	fail 'cgi-io runtime ABI dependencies differ from libc/libubox/libubus.so.20210603'

printf '%s\n' "$control" | grep -Eq '/workspace/|/Users/|/home/|/private/tmp/|BEGIN [A-Z ]*PRIVATE KEY' &&
	fail 'control metadata leaks a host path or private key'
strings -a "$elf" | grep -Eq '/workspace/|/Users/|/home/|/private/tmp/|BEGIN [A-Z ]*PRIVATE KEY|BEGIN OPENSSH PRIVATE KEY' &&
	fail 'cgi-io payload leaks a host path or private key'

(cd "$output" && sha256sum ./*.ipk | LC_ALL=C sort -k2) > "$tmp/PACKAGE_SHA256SUMS"
[ -f "$output/PACKAGE_SHA256SUMS" ] || fail 'PACKAGE_SHA256SUMS is missing'
cmp -s "$tmp/PACKAGE_SHA256SUMS" "$output/PACKAGE_SHA256SUMS" ||
	fail 'PACKAGE_SHA256SUMS does not match the exact candidate IPK'
for metadata in \
	CANDIDATE_BUILD_CONFIG \
	PACKAGE_SHA256SUMS \
	REPRODUCIBILITY.txt
do
	[ -f "$output/$metadata" ] || continue
	grep -Eq '/repo/|/workspace/|/Users/|/Volumes/|/private/tmp/|/tmp/sbe-cgi-io-|/home/|BEGIN [A-Z0-9 ]*PRIVATE KEY|OPENSSH PRIVATE KEY' \
		"$output/$metadata" && fail "$metadata leaks a host path or private-key marker"
done

{
	printf 'cgi-io-2026 artifact audit: PASS\n'
	printf 'packages=1\n'
	printf 'payload=/usr/libexec/cgi-io\n'
	printf 'payload_members=1\n'
	printf 'elf_machine=AArch64\n'
	printf 'pie_nx_full_relro=yes\n'
	printf 'rpath_runpath=none\n'
	printf 'needed=libc.so,libubox.so,libubus.so.20210603\n'
	printf 'host_path_private_key_leaks=none\n'
} > "$report"

printf 'PASS: exact one-file cgi-io payload is AArch64, PIE/NX/full-RELRO and privacy-clean.\n'
