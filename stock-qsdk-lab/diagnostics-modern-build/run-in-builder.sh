#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$build_dir/../.." && pwd)
workspace_parent=$(CDPATH= cd -- "$repo_root/.." && pwd)
. "$build_dir/sources.lock"

source_root=${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}
qsdk_dir=$source_root/qsdk
image=${DIAGNOSTICS_BUILDER_IMAGE:-openwrt-builder:ubuntu-22.04-arm64}
mode=${1:-all}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

sha256_file() {
	sha256sum "$1" | awk '{print $1}'
}

[ "$(uname -s)" = Darwin ] || fail 'this wrapper is for the macOS QSDK host'
command -v docker >/dev/null 2>&1 || fail 'docker is required'
[ -f "$qsdk_dir/Makefile" ] || fail "locked QSDK tree is missing: $qsdk_dir"
[ -f "$qsdk_dir/.config" ] || fail 'shared QSDK .config is missing'
[ "$(sha256_file "$qsdk_dir/.config")" = "$QSDK_BASE_CONFIG_SHA256" ] ||
	fail 'shared QSDK .config differs from the released lock before Docker'

package_parent=$qsdk_dir/package/sbe-qsdk-lab
for package in sbe-mtr096-root-cli-candidate sbe-htop353-candidate sbe-nano92-daily-candidate
do
	[ ! -e "$package_parent/$package" ] ||
		fail "candidate package path already exists before Docker: $package_parent/$package"
done

case "$mode" in
	repro)
		container_command='/repo/stock-qsdk-lab/diagnostics-modern-build/verify-nano-signature.sh && /repo/stock-qsdk-lab/diagnostics-modern-build/verify-reproducible.sh /workspace/qsdk-spf12.2-locked'
		qsdk_mount=$source_root:/workspace/qsdk-spf12.2-locked:rw
		;;
	audit)
		container_command='/repo/stock-qsdk-lab/diagnostics-modern-build/verify-nano-signature.sh && /repo/stock-qsdk-lab/diagnostics-modern-build/audit-artifacts.sh'
		qsdk_mount=$source_root:/workspace/qsdk-spf12.2-locked:ro
		;;
	all)
		container_command='/repo/stock-qsdk-lab/diagnostics-modern-build/verify-nano-signature.sh && /repo/stock-qsdk-lab/diagnostics-modern-build/verify-reproducible.sh /workspace/qsdk-spf12.2-locked && /repo/stock-qsdk-lab/diagnostics-modern-build/audit-artifacts.sh'
		qsdk_mount=$source_root:/workspace/qsdk-spf12.2-locked:rw
		;;
	*)
		printf 'usage: %s [repro|audit|all]\n' "$0" >&2
		exit 2
		;;
esac

set +e
docker run --rm --pull=never --network none --platform linux/arm64 \
	-e GIT_CONFIG_COUNT=4 \
	-e GIT_CONFIG_KEY_0=safe.directory \
	-e GIT_CONFIG_VALUE_0=/workspace/qsdk-spf12.2-locked/qsdk \
	-e GIT_CONFIG_KEY_1=safe.directory \
	-e GIT_CONFIG_VALUE_1=/repo/stock-qsdk-lab/diagnostics-modern-build/sources/mtr \
	-e GIT_CONFIG_KEY_2=safe.directory \
	-e GIT_CONFIG_VALUE_2=/repo/stock-qsdk-lab/diagnostics-modern-build/sources/htop \
	-e GIT_CONFIG_KEY_3=safe.directory \
	-e GIT_CONFIG_VALUE_3=/repo/stock-qsdk-lab/diagnostics-modern-build/sources/nano \
	-v "$repo_root:/repo:rw" \
	-v "$qsdk_mount" \
	"$image" /bin/bash -lc "$container_command"
docker_status=$?
set -e

[ "$(sha256_file "$qsdk_dir/.config")" = "$QSDK_BASE_CONFIG_SHA256" ] ||
	fail 'shared QSDK .config was not restored after Docker exited'
for package in sbe-mtr096-root-cli-candidate sbe-htop353-candidate sbe-nano92-daily-candidate
do
	[ ! -e "$package_parent/$package" ] ||
		fail "diagnostics package overlay symlink remains after Docker exited: $package"
done
[ "$docker_status" -eq 0 ] || exit "$docker_status"

printf 'PASS: diagnostics builder completed and restored shared QSDK state.\n'
