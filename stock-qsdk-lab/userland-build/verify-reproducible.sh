#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_root=${1:-${QSDK_SOURCE_ROOT:-}}
[ -n "$source_root" ] || {
	printf 'usage: %s QSDK_SOURCE_ROOT\n' "$0" >&2
	exit 2
}
[ "$(uname -s)" = Linux ] || {
	printf 'ERROR: reproducibility gate must run inside Linux\n' >&2
	exit 1
}

final_output=${QSDK_EXTRA_USERLAND_FINAL_OUTPUT:-"$build_dir/candidate-out/userland-modern"}
case "$final_output" in
	"$build_dir"/candidate-out/*) ;;
	*)
		printf 'ERROR: final output must stay below %s/candidate-out\n' "$build_dir" >&2
		exit 1
		;;
esac
repro_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sbe-userland-repro.XXXXXX")
round1=$repro_tmp/round1
round2=$repro_tmp/round2

cleanup() {
	case "$repro_tmp" in
		/tmp/sbe-userland-repro.*|/var/tmp/sbe-userland-repro.*)
			rm -rf "$repro_tmp"
			;;
	esac
}
trap cleanup EXIT HUP INT TERM

QSDK_EXTRA_USERLAND_OUTPUT=$round1 \
	"$build_dir/build-candidates.sh" "$source_root"
QSDK_EXTRA_USERLAND_OUTPUT=$round2 \
	"$build_dir/build-candidates.sh" "$source_root"

find "$round1" -maxdepth 1 -type f -name '*.ipk' -exec basename '{}' ';' | \
	LC_ALL=C sort > "$repro_tmp/list1"
find "$round2" -maxdepth 1 -type f -name '*.ipk' -exec basename '{}' ';' | \
	LC_ALL=C sort > "$repro_tmp/list2"
cmp -s "$repro_tmp/list1" "$repro_tmp/list2" || {
	printf 'ERROR: forced-clean builds emitted different package sets\n' >&2
	diff -u "$repro_tmp/list1" "$repro_tmp/list2" >&2 || true
	exit 1
}
[ "$(wc -l < "$repro_tmp/list1" | tr -d ' ')" -eq 3 ] || {
	printf 'ERROR: reproducibility gate expected exactly three IPKs\n' >&2
	exit 1
}
for package in \
	sbe-miniupnpd2311-candidate \
	sbe-ntfs3g2026-candidate \
	sbe-ntpdate4218-candidate
do
	grep -Eq "^${package}_[^/]+\\.ipk$" "$repro_tmp/list1" || {
		printf 'ERROR: reproducibility gate is missing %s\n' "$package" >&2
		exit 1
	}
done
cmp -s "$round1/CANDIDATE_BUILD_CONFIG" "$round2/CANDIDATE_BUILD_CONFIG" || {
	printf 'ERROR: forced-clean build configurations differ\n' >&2
	exit 1
}

report=$repro_tmp/REPRODUCIBILITY.txt
{
	printf 'maintained userland forced-clean reproducibility: PASS\n'
	printf 'package_sha256 payload_data_tar_sha256 control_tar_sha256 filename\n'
} > "$report"

while IFS= read -r name; do
	[ -n "$name" ] || continue
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
	printf '%s %s %s %s\n' "$ipk_sha" "$data1" "$control1" "$name" >> "$report"
done < "$repro_tmp/list1"

mkdir -p "$final_output"
find "$final_output" -maxdepth 1 -type f -name 'sbe-*-candidate_*.ipk' -delete
while IFS= read -r name; do
	[ -n "$name" ] || continue
	cp "$round2/$name" "$final_output/$name"
done < "$repro_tmp/list2"
cp "$round2/CANDIDATE_BUILD_CONFIG" "$final_output/CANDIDATE_BUILD_CONFIG"
(cd "$final_output" && sha256sum ./*.ipk | LC_ALL=C sort -k2) > \
	"$final_output/PACKAGE_SHA256SUMS"
cp "$report" "$final_output/REPRODUCIBILITY.txt"

printf 'PASS: two forced-clean builds produced three byte-identical IPKs and payloads.\n'
printf 'Evaluation-only artifacts written to %s\n' "$final_output"
