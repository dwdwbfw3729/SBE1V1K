#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$build_dir/sources.lock"
output=${1:-"$build_dir/candidate-out/rrdns-modern"}
report=$output/ARTIFACT-AUDIT.txt

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[ "$(uname -s)" = Linux ] || fail 'artifact audit must run inside Linux'
[ -d "$output" ] || fail "candidate directory is missing: $output"
command -v readelf >/dev/null 2>&1 || fail 'readelf is required'
command -v strings >/dev/null 2>&1 || fail 'strings is required'

tmp=$(mktemp -d "${TMPDIR:-/tmp}/sbe-rrdns-audit.XXXXXX")
cleanup() {
	case "$tmp" in
		*/sbe-rrdns-audit.*) rm -rf "$tmp" ;;
	esac
}
trap cleanup EXIT HUP INT TERM

find "$output" -maxdepth 1 -type f -name '*.ipk' -print | LC_ALL=C sort > "$tmp/ipks"
[ "$(wc -l < "$tmp/ipks" | tr -d ' ')" -eq 1 ] || fail 'expected exactly one candidate IPK'
ipk=$(cat "$tmp/ipks")
control=$(tar -xOzf "$ipk" ./control.tar.gz | tar -xOzf - ./control) ||
	fail 'cannot read candidate control metadata'
[ "$(printf '%s\n' "$control" | sed -n 's/^Package: //p')" = \
	'sbe-rpcd-mod-rrdns20170710-modern-candidate' ] || fail 'unexpected package identity'
[ "$(printf '%s\n' "$control" | sed -n 's/^Source: //p')" = "$LUCI_ARCHIVE" ] ||
	fail 'unexpected package source identity'
depends=$(printf '%s\n' "$control" | sed -n 's/^Depends: //p' | tr -d ' ')
[ "$depends" = "libc,rpcd,libubox$QSDK_LIBUBOX_ABI,libubus$QSDK_LIBUBUS_ABI" ] ||
	fail "candidate dependencies differ from locked stock rpcd/libubox/libubus ABIs: $depends"

root=$tmp/root
mkdir -p "$root"
tar -xOzf "$ipk" ./data.tar.gz | tar -xzf - -C "$root"
find "$root" \( -type f -o -type l \) -print | sed "s#^$root##" | LC_ALL=C sort > "$tmp/payload"
[ "$(wc -l < "$tmp/payload" | tr -d ' ')" -eq 1 ] || fail 'candidate payload is not exactly one member'
grep -qxF '/usr/lib/rpcd/rrdns.so' "$tmp/payload" ||
	fail 'candidate payload is not only /usr/lib/rpcd/rrdns.so'
[ -f "$root/usr/lib/rpcd/rrdns.so" ] && [ ! -L "$root/usr/lib/rpcd/rrdns.so" ] ||
	fail 'rrdns payload must be one regular shared module'
[ -x "$root/usr/lib/rpcd/rrdns.so" ] || fail 'rrdns module is not executable/loadable'

elf=$root/usr/lib/rpcd/rrdns.so
header=$(readelf -h "$elf")
printf '%s\n' "$header" | grep -Eq 'Machine:[[:space:]]+AArch64' || fail 'rrdns module is not AArch64'
printf '%s\n' "$header" | grep -Eq 'Type:[[:space:]]+DYN' || fail 'rrdns module is not ELF shared-object type DYN'
program=$(readelf -W -l "$elf")
printf '%s\n' "$program" | grep -q 'GNU_RELRO' || fail 'rrdns module lacks GNU_RELRO'
stack=$(printf '%s\n' "$program" | grep 'GNU_STACK' || true)
[ -n "$stack" ] || fail 'rrdns module lacks GNU_STACK metadata'
printf '%s\n' "$stack" | grep -Eq '[[:space:]]RWE[[:space:]]' && fail 'rrdns module has an executable stack'
dynamic=$(readelf -W -d "$elf")
printf '%s\n' "$dynamic" | grep -Eq 'BIND_NOW|FLAGS.*NOW' || fail 'rrdns module lacks full RELRO NOW binding'
printf '%s\n' "$dynamic" | grep -Eq '\((RPATH|RUNPATH)\)' && fail 'rrdns module contains RPATH/RUNPATH'
needed=$(printf '%s\n' "$dynamic" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' | LC_ALL=C sort)
expected_needed=$(printf '%s\n' libc.so libubox.so "libubus.so.$QSDK_LIBUBUS_ABI" | LC_ALL=C sort)
[ "$needed" = "$expected_needed" ] ||
	fail "rrdns runtime dependencies differ from libc/libubox/libubus.so.$QSDK_LIBUBUS_ABI: $needed"
# QSDK's sstrip deliberately removes section headers.  Ask GNU readelf to
# enumerate symbols through PT_DYNAMIC/DT_HASH, as the runtime loader does.
readelf -W --use-dynamic -s "$elf" | grep -Eq '[[:space:]]GLOBAL[[:space:]]+DEFAULT[[:space:]]+[0-9]+[[:space:]]+rpc_plugin$' ||
	fail 'rrdns module does not export the stock rpcd plugin entry point'
strings -a "$elf" | grep -qxF 'network.rrdns' || fail 'rrdns ubus object string is missing'
strings -a "$elf" | grep -qxF 'lookup' || fail 'rrdns lookup method string is missing'

printf '%s\n' "$control" | grep -Eq '/workspace/|/Users/|/home/|/private/tmp/|BEGIN [A-Z ]*PRIVATE KEY' &&
	fail 'control metadata leaks a host path or private key'
strings -a "$elf" | grep -Eq '/workspace/|/Users/|/home/|/private/tmp/|BEGIN [A-Z ]*PRIVATE KEY|BEGIN OPENSSH PRIVATE KEY' &&
	fail 'rrdns payload leaks a host path or private key'

(cd "$output" && sha256sum ./*.ipk | LC_ALL=C sort -k2) > "$tmp/PACKAGE_SHA256SUMS"
[ -f "$output/PACKAGE_SHA256SUMS" ] || fail 'PACKAGE_SHA256SUMS is missing'
cmp -s "$tmp/PACKAGE_SHA256SUMS" "$output/PACKAGE_SHA256SUMS" ||
	fail 'PACKAGE_SHA256SUMS does not match the exact candidate IPK'
for metadata in CANDIDATE_BUILD_CONFIG PACKAGE_SHA256SUMS REPRODUCIBILITY.txt
do
	[ -f "$output/$metadata" ] || continue
	grep -Eq '/repo/|/workspace/|/Users/|/Volumes/|/private/tmp/|/tmp/sbe-rrdns-|/home/|BEGIN [A-Z0-9 ]*PRIVATE KEY|OPENSSH PRIVATE KEY' \
		"$output/$metadata" && fail "$metadata leaks a host path or private-key marker"
done

{
	printf 'rpcd-mod-rrdns current-official artifact audit: PASS\n'
	printf 'luci_commit=%s\n' "$LUCI_COMMIT"
	printf 'upstream_package_version=%s\n' "$RRDNS_PKG_VERSION"
	printf 'packages=1\n'
	printf 'payload=/usr/lib/rpcd/rrdns.so\n'
	printf 'payload_members=1\n'
	printf 'elf_machine=AArch64\n'
	printf 'elf_type=shared-object-DYN\n'
	printf 'nx_full_relro=yes\n'
	printf 'rpath_runpath=none\n'
	printf 'rpcd_entrypoint=rpc_plugin\n'
	printf 'needed=libc.so,libubox.so,libubus.so.%s\n' "$QSDK_LIBUBUS_ABI"
	printf 'acl_payload=none\n'
	printf 'host_path_private_key_leaks=none\n'
} > "$report"

printf 'PASS: exact one-module rrdns payload is stock-ABI AArch64, NX/full-RELRO and privacy-clean.\n'
