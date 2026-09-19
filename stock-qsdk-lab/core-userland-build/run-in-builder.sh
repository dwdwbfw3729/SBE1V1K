#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$build_dir/../.." && pwd)
workspace_parent=$(CDPATH= cd -- "$repo_root/.." && pwd)
source_root=${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}
image=${CORE_USERLAND_BUILDER_IMAGE:-openwrt-builder:ubuntu-22.04-arm64}
mode=${1:-repro}

[ -f "$source_root/qsdk/Makefile" ] || {
	printf 'ERROR: locked QSDK source root is missing: %s\n' "$source_root" >&2
	exit 1
}
command -v docker >/dev/null 2>&1 || {
	printf 'ERROR: docker is required\n' >&2
	exit 1
}

case "$mode" in
	repro)
		container_command='/repo/stock-qsdk-lab/core-userland-build/prepare-stock-abi-sysroot.sh && /repo/stock-qsdk-lab/core-userland-build/verify-reproducible.sh /workspace/qsdk-spf12.2-locked'
		qsdk_mount=$source_root:/workspace/qsdk-spf12.2-locked:rw
		;;
	audit)
		container_command='/repo/stock-qsdk-lab/core-userland-build/audit-artifacts.sh && /repo/stock-qsdk-lab/core-userland-build/check-netifd-ppp-compat.sh /workspace/qsdk-spf12.2-locked'
		qsdk_mount=$source_root:/workspace/qsdk-spf12.2-locked:ro
		;;
	*)
		printf 'usage: %s [repro|audit]\n' "$0" >&2
		exit 2
		;;
esac

docker run --rm --network none --platform linux/arm64 \
	-e HOME=/tmp/sbe-home \
	-e GIT_CONFIG_COUNT=7 \
	-e GIT_CONFIG_KEY_0=safe.directory \
	-e GIT_CONFIG_VALUE_0=/workspace/qsdk-spf12.2-locked/qsdk \
	-e GIT_CONFIG_KEY_1=safe.directory \
	-e GIT_CONFIG_VALUE_1=/repo/stock-qsdk-lab/core-userland-build/sources/uhttpd \
	-e GIT_CONFIG_KEY_2=safe.directory \
	-e GIT_CONFIG_VALUE_2=/repo/stock-qsdk-lab/core-userland-build/sources/rpcd \
	-e GIT_CONFIG_KEY_3=safe.directory \
	-e GIT_CONFIG_VALUE_3=/repo/stock-qsdk-lab/core-userland-build/sources/odhcpd \
	-e GIT_CONFIG_KEY_4=safe.directory \
	-e GIT_CONFIG_VALUE_4=/repo/stock-qsdk-lab/core-userland-build/sources/ppp \
	-e GIT_CONFIG_KEY_5=safe.directory \
	-e GIT_CONFIG_VALUE_5=/repo/stock-qsdk-lab/core-userland-build/sources/ustream-ssl \
	-e GIT_CONFIG_KEY_6=safe.directory \
	-e GIT_CONFIG_VALUE_6=/repo/stock-qsdk-lab/core-userland-build/sources/iwinfo \
	-v "$repo_root:/repo:rw" \
	-v "$qsdk_mount" \
	"$image" /bin/bash -lc "mkdir -p \"\$HOME\" && $container_command"
