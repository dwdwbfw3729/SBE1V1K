#!/bin/sh
set -eu

candidate_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_root=${1:-${QSDK_SOURCE_ROOT:-}}
[ -n "$source_root" ] || {
	printf 'ERROR: pass the locked QSDK source root\n' >&2
	exit 2
}

run_root=$(mktemp -d "${TMPDIR:-/tmp}/sbe-coreutils-native-repro.XXXXXX")
run1=$run_root/run-1
run2=$run_root/run-2
final=$candidate_dir/candidate-out/coreutils-native

cleanup() {
	case "$run_root" in
		*/sbe-coreutils-native-repro.*) rm -rf "$run_root" ;;
	esac
}
trap cleanup EXIT HUP INT TERM

COREUTILS_NATIVE_OUTPUT="$run1" "$candidate_dir/build-candidate.sh" "$source_root"
COREUTILS_NATIVE_OUTPUT="$run2" "$candidate_dir/build-candidate.sh" "$source_root"

list1=$run_root/list1
list2=$run_root/list2
find "$run1" -maxdepth 1 -type f -name 'coreutils*.ipk' -exec basename '{}' ';' | LC_ALL=C sort > "$list1"
find "$run2" -maxdepth 1 -type f -name 'coreutils*.ipk' -exec basename '{}' ';' | LC_ALL=C sort > "$list2"
cmp -s "$list1" "$list2" || {
	printf 'ERROR: the two builds emitted different package sets\n' >&2
	diff -u "$list1" "$list2" >&2 || true
	exit 1
}
[ "$(wc -l < "$list1" | tr -d ' ')" -eq 4 ] || {
	printf 'ERROR: reproducibility gate expected exactly four IPKs\n' >&2
	exit 1
}
cmp -s "$run1/CANDIDATE_BUILD_CONFIG" "$run2/CANDIDATE_BUILD_CONFIG" || {
	printf 'ERROR: candidate build configurations differ\n' >&2
	exit 1
}

report=$run_root/REPRODUCIBILITY.txt
{
	printf 'locked QSDK packages-feed GNU coreutils package-only reproducibility: PASS\n'
	printf 'runs=2\n'
	printf 'status=evaluation-only-not-deployed\n'
	printf 'package_sha256 payload_data_tar_sha256 control_tar_sha256 filename\n'
} > "$report"

while IFS= read -r name; do
	[ -n "$name" ] || continue
	first=$run1/$name
	second=$run2/$name
	cmp -s "$first" "$second" || {
		printf 'ERROR: IPK bytes differ: %s\n' "$name" >&2
		exit 1
	}
	ipk_sha=$(sha256sum "$first" | awk '{print $1}')
	data1=$(tar -xOzf "$first" ./data.tar.gz | sha256sum | awk '{print $1}')
	data2=$(tar -xOzf "$second" ./data.tar.gz | sha256sum | awk '{print $1}')
	control1=$(tar -xOzf "$first" ./control.tar.gz | sha256sum | awk '{print $1}')
	control2=$(tar -xOzf "$second" ./control.tar.gz | sha256sum | awk '{print $1}')
	[ "$data1" = "$data2" ] || { printf 'ERROR: payload differs: %s\n' "$name" >&2; exit 1; }
	[ "$control1" = "$control2" ] || { printf 'ERROR: control differs: %s\n' "$name" >&2; exit 1; }
	printf '%s %s %s %s\n' "$ipk_sha" "$data1" "$control1" "$name" >> "$report"
done < "$list1"

mkdir -p "$final"
find "$final" -maxdepth 1 -type f -name 'coreutils*.ipk' -delete
while IFS= read -r name; do
	[ -n "$name" ] || continue
	cp "$run2/$name" "$final/$name"
done < "$list2"
cp "$run2/CANDIDATE_BUILD_CONFIG" "$final/"
cp "$run2/PACKAGE_SHA256SUMS" "$final/"
cp "$report" "$final/"

"$candidate_dir/audit-artifacts.sh" "$final" "$source_root"
printf 'PASS: four native coreutils IPKs are byte-identical across two clean package builds\n'

