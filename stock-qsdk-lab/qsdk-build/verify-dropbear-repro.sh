#!/bin/sh
set -eu

lab_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
lock=$lab_dir/dropbear-forwarding.lock.tsv
first=${1:?usage: verify-dropbear-repro.sh FIRST_BUILD SECOND_BUILD}
second=${2:?usage: verify-dropbear-repro.sh FIRST_BUILD SECOND_BUILD}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[ -d "$first" ] || fail "first build directory is missing: $first"
[ -d "$second" ] || fail "second build directory is missing: $second"
[ -f "$lock" ] || fail "Dropbear forwarding lock is missing: $lock"
command -v diff >/dev/null 2>&1 || fail 'diff is required'

if ! diff -qr "$first" "$second"; then
	fail 'forced-clean build directories differ'
fi
printf 'PASS: forced-clean build directories are byte-identical.\n'

if command -v sha256sum >/dev/null 2>&1; then
	hash_file() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
	hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }
else
	fail 'sha256sum or shasum is required'
fi

locked_hash() {
	kind=$1
	name=$2
	awk -F '\t' -v kind="$kind" -v name="$name" \
		'$1 == kind && $2 == name { print $5; found=1; exit }
		 END { if (!found) exit 1 }' "$lock"
}

check_locked_file() {
	kind=$1
	name=$2
	path=$3
	expected=$(locked_hash "$kind" "$name") || \
		fail "lock omits $kind $name"
	actual=$(hash_file "$path")
	[ "$actual" = "$expected" ] || \
		fail "$kind $name hashes as $actual instead of locked $expected"
}

printf '\nFirst-build SHA-256 values:\n'
for path in $(find "$first" -type f -print | sort); do
	relative=${path#"$first"/}
	digest=$(hash_file "$path")
	matching=$(hash_file "$second/$relative")
	[ "$digest" = "$matching" ] || fail "hash mismatch for $relative"
	printf '%s  %s\n' "$digest" "$relative"
done

dropbear_count=$(find "$first" -maxdepth 1 -type f \
	-name 'sbe-dropbear2026-candidate_2026.94-3_*.ipk' | wc -l | tr -d ' ')
[ "$dropbear_count" = 1 ] || fail 'expected exactly one release-3 Dropbear IPK'
dropbear_ipk=$(find "$first" -maxdepth 1 -type f \
	-name 'sbe-dropbear2026-candidate_2026.94-3_*.ipk' -print)
dropbear_name=$(basename "$dropbear_ipk")
check_locked_file build-config CANDIDATE_BUILD_CONFIG \
	"$first/CANDIDATE_BUILD_CONFIG"
check_locked_file compile-policy DROPBEAR_COMPILE_POLICY \
	"$first/DROPBEAR_COMPILE_POLICY"
check_locked_file ipk "$dropbear_name" "$dropbear_ipk"

expected_binary=$(locked_hash binary \
	/usr/libexec/sbe-qsdk-lab/dropbear-2026.94/dropbear) || \
	fail 'lock omits the installed Dropbear binary'
actual_binary=$(tar -xOzf "$dropbear_ipk" ./data.tar.gz | \
	tar -xOzf - ./usr/libexec/sbe-qsdk-lab/dropbear-2026.94/dropbear | \
	{ if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | \
	awk '{print $1}')
[ "$actual_binary" = "$expected_binary" ] || \
	fail "installed binary hashes as $actual_binary instead of locked $expected_binary"

printf '\nPASS: release-3 Dropbear candidate occurs exactly once and matches the forwarding lock.\n'
