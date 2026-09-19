#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$build_dir/sources.lock"

source_root=${1:-${QSDK_SOURCE_ROOT:-}}
[ -n "$source_root" ] || {
	printf 'usage: %s QSDK_SOURCE_ROOT\n' "$0" >&2
	exit 2
}
[ "$(uname -s)" = Linux ] || {
	printf 'ERROR: reproducibility gate must run inside Linux\n' >&2
	exit 1
}

final_output=${CGI_IO_FINAL_OUTPUT:-"$build_dir/candidate-out/cgi-io-security"}
repro_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sbe-cgi-io-repro.XXXXXX")
round1=$repro_tmp/round1
round2=$repro_tmp/round2

cleanup() {
	case "$repro_tmp" in
		/tmp/sbe-cgi-io-repro.*|/var/tmp/sbe-cgi-io-repro.*)
			rm -rf "$repro_tmp"
			;;
	esac
}
trap cleanup EXIT HUP INT TERM

CGI_IO_SECURITY_OUTPUT=$round1 "$build_dir/build-candidate.sh" "$source_root"
CGI_IO_SECURITY_OUTPUT=$round2 "$build_dir/build-candidate.sh" "$source_root"

list1=$repro_tmp/list1
list2=$repro_tmp/list2
find "$round1" -maxdepth 1 -type f -name '*.ipk' -exec basename '{}' ';' | \
	LC_ALL=C sort > "$list1"
find "$round2" -maxdepth 1 -type f -name '*.ipk' -exec basename '{}' ';' | \
	LC_ALL=C sort > "$list2"
cmp -s "$list1" "$list2" || {
	printf 'ERROR: forced-clean builds emitted different package sets\n' >&2
	diff -u "$list1" "$list2" >&2 || true
	exit 1
}
[ "$(wc -l < "$list1" | tr -d ' ')" -eq 1 ] || {
	printf 'ERROR: reproducibility gate expected exactly one IPK\n' >&2
	exit 1
}
grep -Eq '^sbe-cgi-io2026-security-candidate_.*\.ipk$' "$list1" || {
	printf 'ERROR: reproducibility gate saw an unexpected package name\n' >&2
	exit 1
}
cmp -s "$round1/CANDIDATE_BUILD_CONFIG" "$round2/CANDIDATE_BUILD_CONFIG" || {
	printf 'ERROR: forced-clean build configurations differ\n' >&2
	exit 1
}

name=$(cat "$list1")
first=$round1/$name
second=$round2/$name
cmp -s "$first" "$second" || {
	printf 'ERROR: IPK bytes differ: %s\n' "$name" >&2
	exit 1
}
ipk_sha=$(sha256sum "$first" | awk '{print $1}')
data1=$(tar -xOzf "$first" ./data.tar.gz | sha256sum | awk '{print $1}')
data2=$(tar -xOzf "$second" ./data.tar.gz | sha256sum | awk '{print $1}')
control1=$(tar -xOzf "$first" ./control.tar.gz | sha256sum | awk '{print $1}')
control2=$(tar -xOzf "$second" ./control.tar.gz | sha256sum | awk '{print $1}')
[ "$data1" = "$data2" ] || {
	printf 'ERROR: payload bytes differ: %s\n' "$name" >&2
	exit 1
}
[ "$control1" = "$control2" ] || {
	printf 'ERROR: control bytes differ: %s\n' "$name" >&2
	exit 1
}

report=$repro_tmp/REPRODUCIBILITY.txt
{
	printf 'cgi-io-2026 forced-clean reproducibility: PASS\n'
	printf 'SOURCE_DATE_EPOCH=%s\n' "$SOURCE_DATE_EPOCH"
	printf 'package_sha256 payload_data_tar_sha256 control_tar_sha256 filename\n'
	printf '%s %s %s %s\n' "$ipk_sha" "$data1" "$control1" "$name"
} > "$report"

mkdir -p "$final_output"
find "$final_output" -maxdepth 1 -type f \
	-name 'sbe-cgi-io2026-security-candidate_*.ipk' -delete
cp "$second" "$final_output/$name"
cp "$round2/CANDIDATE_BUILD_CONFIG" "$final_output/CANDIDATE_BUILD_CONFIG"
cp "$round2/PACKAGE_SHA256SUMS" "$final_output/PACKAGE_SHA256SUMS"
cp "$report" "$final_output/REPRODUCIBILITY.txt"

printf 'PASS: two forced-clean cgi-io builds produced a byte-identical IPK and payload.\n'
printf 'Evaluation-only artifact written to %s\n' "$final_output"
