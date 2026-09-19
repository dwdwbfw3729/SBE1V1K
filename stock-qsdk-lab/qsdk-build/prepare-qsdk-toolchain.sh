#!/bin/sh
set -eu

lab_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$lab_dir/../.." && pwd)
workspace_root=$(CDPATH= cd -- "$repo_root/.." && pwd)
. "$lab_dir/sources.lock"

source_root=${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}
qsdk_dir=$source_root/qsdk
jobs=${QSDK_JOBS:-4}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[ "$(uname -s)" = Linux ] || fail 'the QSDK toolchain build must run inside Linux'
if [ -f "$qsdk_dir/.config" ]; then
	QSDK_SOURCE_ROOT=$source_root "$lab_dir/verify-sources.sh"
else
	QSDK_SOURCE_ROOT=$source_root QSDK_VERIFY_SOURCE_PREP=1 \
		"$lab_dir/verify-sources.sh"
fi

if [ ! -f "$qsdk_dir/.config" ]; then
	(
		cd "$qsdk_dir"
		qca/configs/qsdk/setup-environment -t ipq95xx -a 64 -p premium -d n
	)
fi
grep -q '^CONFIG_TARGET_ipq95xx=y$' "$qsdk_dir/.config" || fail 'QSDK target is not ipq95xx'
grep -q '^CONFIG_TARGET_ipq95xx_generic=y$' "$qsdk_dir/.config" || fail 'QSDK subtarget is not generic/64-bit'

make -C "$qsdk_dir" -j"$jobs" toolchain/install V=s
compiler=$(find "$qsdk_dir/staging_dir" -type f \
	-name 'aarch64-openwrt-linux-musl-gcc' -perm -111 -print -quit)
[ -n "$compiler" ] || fail 'QSDK AArch64 GCC was not found after toolchain/install'
[ "$("$compiler" -dumpfullversion -dumpversion)" = "$FACTORY_GCC_VERSION" ] || \
	fail 'built compiler is not GCC 7.5.0'

prefix=${compiler%gcc}
printf 'PASS: QSDK toolchain built.\n'
printf 'export QSDK_CROSS_COMPILE=%s\n' "$prefix"
