#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$build_dir/../.." && pwd)
workspace_parent=$(CDPATH= cd -- "$repo_root/.." && pwd)
. "$build_dir/sources.lock"
. "$build_dir/../tools/select-builder.sh"
source_root=${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}
image=${UBUS_SECURITY_BUILDER_IMAGE:-$UBUS_BUILDER_IMAGE_REF}
mode=${1:-repro}
expected_config_sha=${QSDK_BASE_CONFIG_SHA256:-f6074aab89763c9a8bd95a49ebf6909efda4f4103d5aaadaecedf5ac07d9381a}

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

[ "$(uname -s)" = Darwin ] || {
	printf 'ERROR: this offline wrapper is for the macOS Docker host\n' >&2
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
docker image inspect "$image" >/dev/null 2>&1 || {
	printf 'ERROR: builder image is not present locally; offline execution will not pull it: %s\n' \
		"$image" >&2
	exit 1
}
[ "$(docker image inspect --format '{{.Id}}' "$image")" = "$UBUS_BUILDER_IMAGE_ID" ] || {
	printf 'ERROR: builder image ID differs from sources.lock\n' >&2
	exit 1
}
[ "$(sha256_file "$source_root/qsdk/.config")" = "$expected_config_sha" ] || {
	printf 'ERROR: shared QSDK .config is not the released baseline\n' >&2
	exit 1
}

case "$mode" in
	repro)
		container_command='/repo/stock-qsdk-lab/ubus-security-build/verify-reproducible.sh /workspace/qsdk-spf12.2-locked'
		qsdk_mount=$source_root:/workspace/qsdk-spf12.2-locked:rw
		;;
	audit)
		container_command='/repo/stock-qsdk-lab/ubus-security-build/audit-artifacts.sh'
		qsdk_mount=$source_root:/workspace/qsdk-spf12.2-locked:ro
		;;
	*)
		printf 'usage: %s [repro|audit]\n' "$0" >&2
		exit 2
		;;
esac

set +e
docker run --rm --pull=never --network none --platform linux/arm64 \
	-e HOME=/tmp/sbe-home \
	-e GIT_CONFIG_COUNT=2 \
	-e GIT_CONFIG_KEY_0=safe.directory \
	-e GIT_CONFIG_VALUE_0=/workspace/qsdk-spf12.2-locked/qsdk \
	-e GIT_CONFIG_KEY_1=safe.directory \
	-e GIT_CONFIG_VALUE_1=/repo/stock-qsdk-lab/ubus-security-build/sources/ubus \
	-v "$repo_root:/repo:ro" \
	-v "$build_dir:/repo/stock-qsdk-lab/ubus-security-build:rw" \
	-v "$qsdk_mount" \
	"$image" /bin/bash -lc "mkdir -p \"\$HOME\" && $container_command"
status=$?
set -e

[ "$(sha256_file "$source_root/qsdk/.config")" = "$expected_config_sha" ] || {
	printf 'ERROR: shared QSDK .config was not restored after Docker exited\n' >&2
	exit 1
}
[ ! -L "$source_root/qsdk/package/sbe-qsdk-lab/sbe-ubus2022-security-candidate" ] || {
	printf 'ERROR: ubus package overlay symlink remains after Docker exited\n' >&2
	exit 1
}
exit "$status"
