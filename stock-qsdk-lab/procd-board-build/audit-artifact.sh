#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$build_dir/sources.lock"
output=${1:-"$build_dir/candidate-out/procd-board"}
report=$output/ARTIFACT-AUDIT.txt

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[ "$(uname -s)" = Linux ] || fail 'artifact audit must run inside Linux'
[ -d "$output" ] || fail "candidate directory is missing: $output"
command -v readelf >/dev/null 2>&1 || fail 'readelf is required'
command -v strings >/dev/null 2>&1 || fail 'strings is required'

tmp=$(mktemp -d "${TMPDIR:-/tmp}/sbe-procd-audit.XXXXXX")
cleanup() {
	case "$tmp" in
		/tmp/sbe-procd-audit.*|/var/tmp/sbe-procd-audit.*) rm -rf "$tmp" ;;
	esac
}
trap cleanup EXIT HUP INT TERM

find "$output" -maxdepth 1 -type f -name '*.ipk' -print | LC_ALL=C sort > "$tmp/ipks"
[ "$(wc -l < "$tmp/ipks" | tr -d ' ')" -eq 1 ] || fail 'expected exactly one candidate IPK'
ipk=$(cat "$tmp/ipks")
control=$(tar -xOzf "$ipk" ./control.tar.gz | tar -xOzf - ./control) ||
	fail 'cannot read candidate control metadata'
[ "$(printf '%s\n' "$control" | sed -n 's/^Package: //p')" = 'sbe-procd2020-board-candidate' ] ||
	fail 'unexpected package identity'
[ "$(printf '%s\n' "$control" | sed -n 's/^Source: //p')" = "$PROCD_ARCHIVE" ] ||
	fail 'unexpected package source identity'

root=$tmp/root
mkdir -p "$root"
tar -xOzf "$ipk" ./data.tar.gz | tar -xzf - -C "$root"
find "$root" \( -type f -o -type l \) -print | sed "s#^$root##" | LC_ALL=C sort > "$tmp/payload"
[ "$(wc -l < "$tmp/payload" | tr -d ' ')" -eq 2 ] || fail 'candidate payload is not exactly two members'
printf '%s\n' /sbin/procd /sbin/ujail | LC_ALL=C sort > "$tmp/expected-payload"
cmp -s "$tmp/expected-payload" "$tmp/payload" || fail 'candidate payload is not exactly procd plus ujail'
[ -f "$root/sbin/procd" ] && [ ! -L "$root/sbin/procd" ] ||
	fail 'procd payload must be one regular executable'
[ -f "$root/sbin/ujail" ] && [ ! -L "$root/sbin/ujail" ] ||
	fail 'ujail payload must be one regular executable'

elf=$root/sbin/procd
header=$(readelf -h "$elf")
printf '%s\n' "$header" | grep -Eq 'Machine:[[:space:]]+AArch64' || fail 'procd is not AArch64'
printf '%s\n' "$header" | grep -Eq 'Type:[[:space:]]+DYN' || fail 'procd is not PIE ELF type DYN'
program=$(readelf -W -l "$elf")
printf '%s\n' "$program" | grep -q 'GNU_RELRO' || fail 'procd lacks GNU_RELRO'
stack=$(printf '%s\n' "$program" | grep 'GNU_STACK' || true)
[ -n "$stack" ] || fail 'procd lacks GNU_STACK metadata'
printf '%s\n' "$stack" | grep -Eq '[[:space:]]RWE[[:space:]]' && fail 'procd has an executable stack'
dynamic=$(readelf -W -d "$elf")
printf '%s\n' "$dynamic" | grep -Eq 'BIND_NOW|FLAGS.*NOW' || fail 'procd lacks full RELRO NOW binding'
printf '%s\n' "$dynamic" | grep -Eq '\((RPATH|RUNPATH)\)' && fail 'procd contains RPATH/RUNPATH'
needed=$(printf '%s\n' "$dynamic" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' | LC_ALL=C sort)
expected_needed=$(printf '%s\n' \
	libblobmsg_json.so libc.so libgcc_s.so.1 libjson-c.so.2 libjson_script.so \
	libubox.so libubus.so.20210603 | LC_ALL=C sort)
[ "$needed" = "$expected_needed" ] || fail 'procd runtime ABI dependencies differ from the stock QSDK closure'

strings -a "$elf" | grep -Fxq 'CPU revision' || fail 'compiled procd lacks the real ARM64 CPU field lookup'
strings -a "$elf" | grep -Fxq 'ARMv8 Processor rev %lu' || fail 'compiled procd lacks the upstream system value format'
strings -a "$elf" | grep -Eiq 'SBE1V1K|IPQ95|Cortex-A73|AP-AL02' &&
	fail 'compiled board-info fix hard-codes this router model or CPU part'
strings -a "$elf" | grep -Eq '/workspace/|/Users/|/home/|/private/tmp/|BEGIN [A-Z ]*PRIVATE KEY|OPENSSH PRIVATE KEY' &&
	fail 'procd payload leaks a host path or private key'

ujail=$root/sbin/ujail
ujail_header=$(readelf -h "$ujail")
printf '%s\n' "$ujail_header" | grep -Eq 'Machine:[[:space:]]+AArch64' || fail 'ujail is not AArch64'
printf '%s\n' "$ujail_header" | grep -Eq 'Type:[[:space:]]+DYN' || fail 'ujail is not PIE ELF type DYN'
ujail_program=$(readelf -W -l "$ujail")
printf '%s\n' "$ujail_program" | grep -q 'GNU_RELRO' || fail 'ujail lacks GNU_RELRO'
ujail_stack=$(printf '%s\n' "$ujail_program" | grep 'GNU_STACK' || true)
[ -n "$ujail_stack" ] || fail 'ujail lacks GNU_STACK metadata'
printf '%s\n' "$ujail_stack" | grep -Eq '[[:space:]]RWE[[:space:]]' && fail 'ujail has an executable stack'
ujail_dynamic=$(readelf -W -d "$ujail")
printf '%s\n' "$ujail_dynamic" | grep -Eq 'BIND_NOW|FLAGS.*NOW' || fail 'ujail lacks full RELRO NOW binding'
printf '%s\n' "$ujail_dynamic" | grep -Eq '\((RPATH|RUNPATH)\)' && fail 'ujail contains RPATH/RUNPATH'
ujail_needed=$(printf '%s\n' "$ujail_dynamic" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' | LC_ALL=C sort)
expected_ujail_needed=$(printf '%s\n' libblobmsg_json.so libc.so libgcc_s.so.1 libubox.so | LC_ALL=C sort)
[ "$ujail_needed" = "$expected_ujail_needed" ] || fail 'ujail runtime ABI dependencies differ from the stock QSDK closure'
strings -a "$ujail" | grep -Eq '/workspace/|/Users/|/home/|/private/tmp/|BEGIN [A-Z ]*PRIVATE KEY|OPENSSH PRIVATE KEY' &&
	fail 'ujail payload leaks a host path or private key'
printf '%s\n' "$control" | grep -Eq '/workspace/|/Users/|/home/|/private/tmp/|BEGIN [A-Z ]*PRIVATE KEY' &&
	fail 'control metadata leaks a host path or private key'

(cd "$output" && sha256sum ./*.ipk | LC_ALL=C sort -k2) > "$tmp/PACKAGE_SHA256SUMS"
[ -f "$output/PACKAGE_SHA256SUMS" ] || fail 'PACKAGE_SHA256SUMS is missing'
cmp -s "$tmp/PACKAGE_SHA256SUMS" "$output/PACKAGE_SHA256SUMS" ||
	fail 'PACKAGE_SHA256SUMS does not match the exact candidate IPK'

{
	printf 'QSDK procd AArch64 board-info artifact audit: PASS\n'
	printf 'packages=1\n'
	printf 'payload=/sbin/procd,/sbin/ujail\n'
	printf 'payload_members=2\n'
	printf 'elf_machine=AArch64\n'
	printf 'pie_nx_full_relro=yes\n'
	printf 'rpath_runpath=none\n'
	printf 'ujail_abi=libubox.so,libblobmsg_json.so\n'
	printf 'system_source=/proc/cpuinfo:CPU revision\n'
	printf 'system_example=ARMv8 Processor rev 0\n'
	printf 'model_cpu_hardcoding=none\n'
} > "$report"

printf 'PASS: procd and ujail are ABI-matched AArch64 payloads without model hard-coding.\n'
