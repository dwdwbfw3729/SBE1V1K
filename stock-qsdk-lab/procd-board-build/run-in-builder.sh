#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$build_dir/../.." && pwd)
workspace_parent=$(CDPATH= cd -- "$repo_root/.." && pwd)
source_root=${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}
image=${PROCD_BOARD_BUILDER_IMAGE:-openwrt-builder:ubuntu-22.04-arm64}
mode=${1:-all}
expected_config_sha=${QSDK_BASE_CONFIG_SHA256:-f6074aab89763c9a8bd95a49ebf6909efda4f4103d5aaadaecedf5ac07d9381a}

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

[ "$(uname -s)" = Darwin ] || {
	printf 'ERROR: this wrapper is for the macOS Docker host\n' >&2
	exit 1
}
[ -f "$source_root/qsdk/Makefile" ] || {
	printf 'ERROR: locked QSDK source root is missing: %s\n' "$source_root" >&2
	exit 1
}
command -v docker >/dev/null 2>&1 || {
	printf 'ERROR: docker is required\n' >&2
	exit 1
}
[ "$(sha256_file "$source_root/qsdk/.config")" = "$expected_config_sha" ] || {
	printf 'ERROR: shared QSDK .config is not the released baseline (another package build may still be running)\n' >&2
	exit 1
}

case "$mode" in
	repro)
		command='/repo/stock-qsdk-lab/procd-board-build/verify-reproducible.sh /workspace/qsdk-spf12.2-locked'
		qsdk_mode=rw
		;;
	audit)
		command='/repo/stock-qsdk-lab/procd-board-build/audit-artifact.sh'
		qsdk_mode=ro
		;;
	all)
		command='/repo/stock-qsdk-lab/procd-board-build/verify-reproducible.sh /workspace/qsdk-spf12.2-locked && /repo/stock-qsdk-lab/procd-board-build/audit-artifact.sh'
		qsdk_mode=rw
		;;
	*)
		printf 'usage: %s [repro|audit|all]\n' "$0" >&2
		exit 2
		;;
esac

set +e
docker run --rm --pull=never --network none --platform linux/arm64 \
	-e HOME=/tmp/sbe-home \
	-v "$repo_root:/repo:ro" \
	-v "$build_dir:/repo/stock-qsdk-lab/procd-board-build:rw" \
	-v "$source_root:/workspace/qsdk-spf12.2-locked:$qsdk_mode" \
	"$image" /bin/bash -lc "mkdir -p \"\$HOME\" && $command"
status=$?
set -e

[ "$(sha256_file "$source_root/qsdk/.config")" = "$expected_config_sha" ] || {
	printf 'ERROR: shared QSDK .config was not restored after Docker exited\n' >&2
	exit 1
}
[ ! -L "$source_root/qsdk/package/sbe-qsdk-lab/sbe-procd2020-board-candidate" ] || {
	printf 'ERROR: procd package overlay symlink remains after Docker exited\n' >&2
	exit 1
}
exit "$status"

