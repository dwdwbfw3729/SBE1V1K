#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$build_dir/sources.lock"

source_root=${1:-${QSDK_SOURCE_ROOT:-}}
[ -n "$source_root" ] || { printf 'usage: %s QSDK_SOURCE_ROOT\n' "$0" >&2; exit 2; }
qsdk_dir=$source_root/qsdk
output=${UCI_SECURITY_OUTPUT:-$build_dir/candidate-out/round}
jobs=${QSDK_JOBS:-4}

export LC_ALL=C
export TZ=UTC
export SOURCE_DATE_EPOCH

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

sha256_file() {
	sha256sum "$1" | awk '{print $1}'
}

[ "$(uname -s)" = Linux ] || fail 'QSDK package build must run inside Linux'
[ "$(git -C "$qsdk_dir" rev-parse HEAD)" = "$QSDK_GIT_COMMIT" ] || fail 'QSDK commit mismatch'
[ "$(sha256_file "$qsdk_dir/.config")" = "$QSDK_CONFIG_SHA256" ] || fail 'QSDK .config mismatch'
[ "$(sha256_file "$qsdk_dir/dl/$UCI_ARCHIVE")" = "$UCI_ARCHIVE_SHA256" ] || fail 'uci archive mismatch'
grep -qx 'PKG_SOURCE_VERSION:=415f9e48436d29f612348f58f546b3ad8d74ac38' \
	"$qsdk_dir/package/system/uci/Makefile" || fail 'package overlay source commit is not locked'
grep -qx '  ABI_VERSION:=20130104' "$qsdk_dir/package/system/uci/Makefile" || fail 'package overlay ABI changed'
grep -qx 'PKG_RELEASE:=5' "$qsdk_dir/package/system/uci/Makefile" || fail 'package overlay release changed'

(cd "$build_dir" && sha256sum -c patches.lock)

mkdir -p "$output"
find "$output" -mindepth 1 -maxdepth 1 -type f -delete

config_before=$(sha256_file "$qsdk_dir/.config")
kernel_before=$(mktemp /tmp/sbe-uci-kernel-before.XXXXXX)
kernel_after=$(mktemp /tmp/sbe-uci-kernel-after.XXXXXX)
cleanup() {
	rm -f "$kernel_before" "$kernel_after"
}
trap cleanup EXIT HUP INT TERM

snapshot_kernel() {
	find "$qsdk_dir/build_dir" "$qsdk_dir/bin/targets" \
		\( -path '*/linux-*/*' -o -path '*/targets/*' \) -type f \
		-printf '%p\t%s\t%T@\n' 2>/dev/null | LC_ALL=C sort
}
snapshot_kernel > "$kernel_before"

pattern='libuci20130104_2019-09-01-415f9e48-5_*.ipk'
find "$qsdk_dir/bin" -type f -name "$pattern" -delete

make -C "$qsdk_dir" \
	CONFIG_PACKAGE_libuci=m CONFIG_PACKAGE_uci= CONFIG_PACKAGE_libuci-lua= \
	package/system/uci/clean

remaining=$(find "$qsdk_dir/build_dir" -mindepth 2 -maxdepth 2 -type d \
	-name 'uci-2019-09-01-415f9e48' -print | wc -l | tr -d ' ')
[ "$remaining" -eq 0 ] || fail 'package clean left a uci build directory behind'
printf 'clean_build_dir_absent=yes\n' > "$output/CLEAN-GATE.txt"

set +e
make -C "$qsdk_dir" -j"$jobs" NO_DEPS=1 \
	CONFIG_PACKAGE_libuci=m CONFIG_PACKAGE_uci= CONFIG_PACKAGE_libuci-lua= \
	package/system/uci/compile V=s > "$output/BUILD.log" 2>&1
status=$?
set -e
[ "$status" -eq 0 ] || { tail -n 120 "$output/BUILD.log" >&2; fail 'libuci package-only compile failed'; }

if grep -E '(^|[ /])(world|kernel/(compile|install)|package/kernel/|qca-[^ /]*/(compile|install))([ /]|$)' \
	"$output/BUILD.log" >/dev/null 2>&1; then
	fail 'build log contains a forbidden world, kernel or QCA target'
fi
snapshot_kernel > "$kernel_after"
cmp -s "$kernel_before" "$kernel_after" || fail 'kernel/target artifact metadata changed during libuci build'
[ "$(sha256_file "$qsdk_dir/.config")" = "$config_before" ] || fail 'QSDK .config changed during build'

artifact_count=$(find "$qsdk_dir/bin" -type f -name "$pattern" -print | wc -l | tr -d ' ')
[ "$artifact_count" -eq 1 ] || fail "expected one $pattern artifact, found $artifact_count"
artifact=$(find "$qsdk_dir/bin" -type f -name "$pattern" -print -quit)
cp "$artifact" "$output/"

pkg_build_count=$(find "$qsdk_dir/build_dir" -mindepth 2 -maxdepth 2 -type d \
	-name 'uci-2019-09-01-415f9e48' -print | wc -l | tr -d ' ')
[ "$pkg_build_count" -eq 1 ] || fail "expected one prepared uci build directory, found $pkg_build_count"
pkg_build=$(find "$qsdk_dir/build_dir" -mindepth 2 -maxdepth 2 -type d \
	-name 'uci-2019-09-01-415f9e48' -print -quit)
[ -x "$pkg_build/uci" ] || fail 'test-only uci CLI build product is missing'
cp "$pkg_build/uci" "$output/uci-cli.test-only"

tmp=$(mktemp -d /tmp/sbe-uci-ipk.XXXXXX)
case "$tmp" in /tmp/sbe-uci-ipk.*|/var/tmp/sbe-uci-ipk.*) ;; *) fail 'unsafe temp path' ;; esac
tar -xzf "$artifact" -C "$tmp"
mkdir -p "$tmp/root"
tar -xzf "$tmp/data.tar.gz" -C "$tmp/root"
[ -f "$tmp/root/lib/libuci.so" ] || fail 'candidate IPK does not contain /lib/libuci.so'
cp "$tmp/root/lib/libuci.so" "$output/libuci.so"
control=$(tar -xOzf "$tmp/control.tar.gz" ./control)
rm -rf "$tmp"

[ "$(printf '%s\n' "$control" | sed -n 's/^Package: //p')" = libuci20130104 ] || fail 'package ABI name changed'
[ "$(printf '%s\n' "$control" | sed -n 's/^Version: //p')" = 2019-09-01-415f9e48-5 ] || fail 'package version changed unexpectedly'
[ "$(printf '%s\n' "$control" | sed -n 's/^Architecture: //p')" = aarch64_cortex-a73_neon-vfpv4 ] || fail 'package architecture changed'

{
	printf 'make_target=package/system/uci/compile\n'
	printf 'no_deps=1\n'
	printf 'selected_package=libuci20130104\n'
	printf 'uci_cli=test-only-not-packaged\n'
	printf 'kernel_qca_world=not_invoked\n'
	printf 'qsdk_config_before_after=%s\n' "$config_before"
	printf 'source_date_epoch=%s\n' "$SOURCE_DATE_EPOCH"
} > "$output/BUILD-ATTESTATION.txt"

(cd "$pkg_build" && sha256sum \
	delta.c file.c libuci.c list.c uci.h uci_internal.h util.c test/tests.d/090_cli_options) \
	> "$output/PREPARED-SOURCE-SHA256SUMS"
(cd "$output" && sha256sum ./*.ipk ./libuci.so ./uci-cli.test-only) > "$output/ARTIFACT-SHA256SUMS"
