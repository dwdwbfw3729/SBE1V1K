#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$build_dir/../.." && pwd)
workspace_parent=$(CDPATH= cd -- "$repo_root/.." && pwd)
. "$build_dir/sources.lock"
. "$build_dir/../tools/select-builder.sh"

source_root=${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}
qsdk_dir=$source_root/qsdk
image=${UCI_SECURITY_BUILDER_IMAGE:-$BUILDER_IMAGE_REF}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

sha256_file() {
	shasum -a 256 "$1" | awk '{print $1}'
}

[ "$(uname -s)" = Darwin ] || fail 'offline wrapper must run on macOS'
[ "$(git -C "$qsdk_dir" rev-parse HEAD)" = "$QSDK_GIT_COMMIT" ] || fail 'QSDK commit mismatch'
[ -z "$(git -C "$qsdk_dir" status --porcelain)" ] || fail 'QSDK tree is not clean before build'
[ "$(sha256_file "$qsdk_dir/.config")" = "$QSDK_CONFIG_SHA256" ] || fail 'QSDK .config mismatch before build'
[ "$(sha256_file "$qsdk_dir/package/system/uci/Makefile")" = "$QSDK_UCI_MAKEFILE_SHA256" ] || fail 'QSDK uci Makefile mismatch'
[ "$(sha256_file "$qsdk_dir/package/system/uci/patches/001-file-uci_parse_package-fix-heap-use-after-free.patch")" = "$QSDK_UCI_PATCH_001_SHA256" ] || fail 'QSDK uci patch 001 mismatch'
[ "$(sha256_file "$qsdk_dir/package/system/uci/patches/002-file-Check-buffer-size-after-strtok.patch")" = "$QSDK_UCI_PATCH_002_SHA256" ] || fail 'QSDK uci patch 002 mismatch'
docker image inspect "$image" >/dev/null 2>&1 || fail 'locked builder image is unavailable locally'
[ "$(docker image inspect --format '{{.Id}}' "$image")" = "$BUILDER_IMAGE_ID" ] || fail 'builder image ID mismatch'

set +e
docker run --rm --pull=never --network none --platform linux/arm64 \
	-e HOME=/tmp/sbe-uci-build-home \
	-e QSDK_JOBS="${QSDK_JOBS:-4}" \
	-e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
	-e GIT_CONFIG_COUNT=1 \
	-e GIT_CONFIG_KEY_0=safe.directory \
	-e GIT_CONFIG_VALUE_0=/workspace/qsdk-spf12.2-locked/qsdk \
	-v "$repo_root:/repo:ro" \
	-v "$build_dir:/repo/stock-qsdk-lab/uci-security-build:rw" \
	-v "$source_root:/workspace/qsdk-spf12.2-locked:rw" \
	-v "$build_dir/package-overlay:/workspace/qsdk-spf12.2-locked/qsdk/package/system/uci:ro" \
	"$image" /bin/bash -lc \
	'/bin/sh /repo/stock-qsdk-lab/uci-security-build/verify-reproducible-in-linux.sh /workspace/qsdk-spf12.2-locked'
status=$?
set -e

[ "$(sha256_file "$qsdk_dir/.config")" = "$QSDK_CONFIG_SHA256" ] || fail 'QSDK .config changed after build'
[ -z "$(git -C "$qsdk_dir" status --porcelain)" ] || fail 'QSDK tree is not clean after overlay unmount'
exit "$status"
