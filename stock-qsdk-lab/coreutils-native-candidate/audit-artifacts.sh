#!/bin/sh
set -eu

candidate_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$candidate_dir/sources.lock"
output=${1:-"$candidate_dir/candidate-out/coreutils-native"}
source_root=${2:-${QSDK_SOURCE_ROOT:-}}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

find_one() {
	result=$(find "$output" -maxdepth 1 -type f -name "$1" | LC_ALL=C sort)
	[ "$(printf '%s\n' "$result" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 1 ] || fail "expected one artifact matching $1"
	printf '%s\n' "$result"
}

control_text() {
	tar -xOzf "$1" ./control.tar.gz | tar -xOzf - ./control
}

payload_list() {
	tar -xOzf "$1" ./data.tar.gz | tar -tzf -
}

assert_control_line() {
	control=$1
	expected=$2
	printf '%s\n' "$control" | grep -Fqx "$expected" || fail "missing control field: $expected"
}

assert_dep() {
	control=$1
	dep=$2
	printf '%s\n' "$control" | grep -Eq "^Depends: (.*, )?${dep}(, .*)?$" || fail "missing dependency: $dep"
}

meta=$(find_one "coreutils_${COREUTILS_VERSION}-${COREUTILS_RELEASE}_${TARGET_ARCH}.ipk")
base64=$(find_one "coreutils-base64_${COREUTILS_VERSION}-${COREUTILS_RELEASE}_${TARGET_ARCH}.ipk")
nohup=$(find_one "coreutils-nohup_${COREUTILS_VERSION}-${COREUTILS_RELEASE}_${TARGET_ARCH}.ipk")
timeout=$(find_one "coreutils-timeout_${COREUTILS_VERSION}-${COREUTILS_RELEASE}_${TARGET_ARCH}.ipk")
[ "$(find "$output" -maxdepth 1 -type f -name 'coreutils*.ipk' | wc -l | tr -d ' ')" -eq 4 ] || fail 'artifact directory contains an unexpected coreutils package set'

meta_control=$(control_text "$meta")
base64_control=$(control_text "$base64")
nohup_control=$(control_text "$nohup")
timeout_control=$(control_text "$timeout")

for pair in \
	"coreutils:$meta_control" \
	"coreutils-base64:$base64_control" \
	"coreutils-nohup:$nohup_control" \
	"coreutils-timeout:$timeout_control"; do
	package=${pair%%:*}
	control=${pair#*:}
	assert_control_line "$control" "Package: $package"
	assert_control_line "$control" "Version: ${COREUTILS_VERSION}-${COREUTILS_RELEASE}"
	assert_control_line "$control" "Architecture: $TARGET_ARCH"
	assert_control_line "$control" 'Source: qca/feeds/packages/utils/coreutils'
	assert_control_line "$control" "SourceName: $package"
	assert_control_line "$control" 'License: GPL-3.0-or-later'
	if printf '%s\n' "$control" | grep -Eq '^Provides:.*[Bb]usy[Bb]ox'; then
		fail "$package falsely provides BusyBox"
	fi
done

assert_dep "$base64_control" coreutils
assert_dep "$nohup_control" coreutils
assert_dep "$timeout_control" coreutils
assert_dep "$timeout_control" librt
assert_control_line "$base64_control" 'Alternatives: 300:/bin/base64:/usr/libexec/base64-coreutils'
assert_control_line "$nohup_control" 'Alternatives: 300:/usr/bin/nohup:/usr/libexec/nohup-coreutils'
assert_control_line "$timeout_control" 'Alternatives: 300:/usr/bin/timeout:/usr/libexec/timeout-coreutils'
printf '%s\n' "$meta_control" | grep -q '^Alternatives:' && fail 'coreutils metapackage unexpectedly owns an alternative'

tmp=$(mktemp -d "${TMPDIR:-/tmp}/sbe-coreutils-native-audit.XXXXXX")
cleanup() {
	case "$tmp" in
		*/sbe-coreutils-native-audit.*) rm -rf "$tmp" ;;
	esac
}
trap cleanup EXIT HUP INT TERM

for pair in "$meta:meta" "$base64:base64" "$nohup:nohup" "$timeout:timeout"; do
	ipk=${pair%%:*}
	name=${pair#*:}
	mkdir -p "$tmp/$name"
	tar -xOzf "$ipk" ./data.tar.gz | tar -xzf - -C "$tmp/$name"
done

[ -z "$(find "$tmp/meta" -type f -o -type l)" ] || fail 'coreutils is not an empty metapackage'
for spec in \
	"base64:/usr/libexec/base64-coreutils" \
	"nohup:/usr/libexec/nohup-coreutils" \
	"timeout:/usr/libexec/timeout-coreutils"; do
	name=${spec%%:*}
	path=${spec#*:}
	root=$tmp/$name
	[ -f "$root$path" ] || fail "missing standard alternatives target $path"
	[ -x "$root$path" ] || fail "$path is not executable"
	[ "$(find "$root" -type f | wc -l | tr -d ' ')" -eq 1 ] || fail "$name contains an unexpected payload file"
done
[ ! -e "$tmp/base64/bin/base64" ] || fail 'base64 package bypasses the alternatives target'
[ ! -e "$tmp/nohup/usr/bin/nohup" ] || fail 'nohup package bypasses the alternatives target'
[ ! -e "$tmp/timeout/usr/bin/timeout" ] || fail 'timeout package bypasses the alternatives target'

[ -n "$source_root" ] || fail 'the locked QSDK source root is required for ELF and runtime gates'
toolchain=$source_root/qsdk/staging_dir/toolchain-aarch64_cortex-a73+neon-vfpv4_gcc-7.5.0_musl
target=$source_root/qsdk/staging_dir/target-aarch64_cortex-a73+neon-vfpv4_musl
cross=$toolchain/bin/aarch64-openwrt-linux-musl-
loader=$toolchain/lib/ld-musl-aarch64.so.1
library_path=$toolchain/lib:$target/usr/lib
for required in "${cross}readelf" "${cross}strings" "$loader"; do
	[ -e "$required" ] || fail "missing locked toolchain component: $required"
done

for spec in \
	"base64:$tmp/base64/usr/libexec/base64-coreutils" \
	"nohup:$tmp/nohup/usr/libexec/nohup-coreutils" \
	"timeout:$tmp/timeout/usr/libexec/timeout-coreutils"; do
	name=${spec%%:*}
	binary=${spec#*:}
	"${cross}readelf" -h "$binary" > "$tmp/$name.elf-header"
	"${cross}readelf" -W -l "$binary" > "$tmp/$name.elf-program"
	"${cross}readelf" -W -d "$binary" > "$tmp/$name.elf-dynamic"
	grep -q 'Machine:.*AArch64' "$tmp/$name.elf-header" || fail "$name is not AArch64"
	grep -q 'Requesting program interpreter: /lib/ld-musl-aarch64.so.1' "$tmp/$name.elf-program" || fail "$name does not use the locked musl ABI"
	grep -q 'GNU_RELRO' "$tmp/$name.elf-program" || fail "$name lacks GNU_RELRO"
	if grep -Eq '\((RPATH|RUNPATH)\)' "$tmp/$name.elf-dynamic"; then
		fail "$name unexpectedly contains RPATH or RUNPATH"
	fi
	stack_flags=$(awk '$1 == "GNU_STACK" {print $7}' "$tmp/$name.elf-program")
	[ -n "$stack_flags" ] && ! printf '%s\n' "$stack_flags" | grep -q E || fail "$name has an executable or missing GNU_STACK"
	if "${cross}strings" -a "$binary" | grep -E -i '(/Users/|yangzhg|sbe-coreutils-native-repro\.|BEGIN (RSA |OPENSSH )?PRIVATE KEY)' > "$tmp/$name.privacy-rejects"; then
		fail "$name contains a private build path, identity, or key marker"
	fi
	"$loader" --library-path "$library_path" "$binary" --help > "$tmp/$name.help"
	grep -Fq 'GNU coreutils' "$tmp/$name.help" || fail "$name --help is not the GNU implementation"
done

encoded=$(printf 'SBE1V1K native coreutils\n' | "$loader" --library-path "$library_path" "$tmp/base64/usr/libexec/base64-coreutils")
decoded=$(printf '%s\n' "$encoded" | "$loader" --library-path "$library_path" "$tmp/base64/usr/libexec/base64-coreutils" --decode)
[ "$decoded" = 'SBE1V1K native coreutils' ] || fail 'base64 round trip failed'

nohup_result=$("$loader" --library-path "$library_path" "$tmp/nohup/usr/libexec/nohup-coreutils" /bin/sh -c 'printf coreutils-nohup' 2> "$tmp/nohup.stderr")
[ "$nohup_result" = 'coreutils-nohup' ] || fail 'nohup execution fixture failed'

"$loader" --library-path "$library_path" "$tmp/timeout/usr/libexec/timeout-coreutils" 2 /bin/true
set +e
"$loader" --library-path "$library_path" "$tmp/timeout/usr/libexec/timeout-coreutils" 0.1 /bin/sh -c 'sleep 2'
timeout_status=$?
set -e
[ "$timeout_status" -eq 124 ] || fail "timeout fixture returned $timeout_status instead of 124"

printf 'PASS: exact package identity, empty metapackage, standard alternatives, AArch64 musl ELF, offline help, base64 round trip, nohup, and timeout fixtures verified\n'
