#!/bin/sh
set -eu

candidate_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$candidate_dir/../.." && pwd)
workspace_parent=$(CDPATH= cd -- "$repo_root/.." && pwd)
. "$candidate_dir/sources.lock"
. "$candidate_dir/../tools/select-builder.sh"

source_root=${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}
qsdk=$source_root/qsdk

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[ "$(uname -s)" = Darwin ] || fail 'this wrapper is for the macOS Docker host'
command -v docker >/dev/null 2>&1 || fail 'docker is required'
[ -f "$qsdk/Makefile" ] || fail "locked QSDK source root is missing: $source_root"
[ "$(sha256_file "$qsdk/.config")" = "$QSDK_BASE_CONFIG_SHA256" ] || fail 'shared QSDK .config is not the released baseline'
[ "$(git -C "$qsdk" rev-parse HEAD)" = "$QSDK_TOP_COMMIT" ] || fail 'wrong QSDK commit'
[ "$(git -C "$qsdk/qca/feeds/packages" rev-parse HEAD)" = "$QSDK_PACKAGES_COMMIT" ] || fail 'wrong packages feed commit'
[ "$(git -C "$qsdk/qca/feeds/luci" rev-parse HEAD)" = "$QSDK_LUCI_COMMIT" ] || fail 'wrong LuCI commit'

actual_image_id=$(docker image inspect "$BUILDER_IMAGE_REF" --format '{{.Id}}')
[ "$actual_image_id" = "$BUILDER_IMAGE_ID" ] || fail "wrong Docker builder image: $actual_image_id"

set +e
docker run --rm --pull=never --network none --platform linux/arm64 \
	-e HOME=/tmp/sbe-ddns-native-home \
	-e LC_ALL=C -e TZ=UTC \
	-e QSDK_JOBS="${QSDK_JOBS:-4}" \
	-e GIT_CONFIG_COUNT=3 \
	-e GIT_CONFIG_KEY_0=safe.directory \
	-e GIT_CONFIG_VALUE_0=/workspace/qsdk-spf12.2-locked/qsdk \
	-e GIT_CONFIG_KEY_1=safe.directory \
	-e GIT_CONFIG_VALUE_1=/workspace/qsdk-spf12.2-locked/qsdk/qca/feeds/packages \
	-e GIT_CONFIG_KEY_2=safe.directory \
	-e GIT_CONFIG_VALUE_2=/workspace/qsdk-spf12.2-locked/qsdk/qca/feeds/luci \
	-v "$repo_root:/repo:ro" \
	-v "$candidate_dir:/repo/stock-qsdk-lab/ddns-native-candidate:rw" \
	-v "$source_root:/workspace/qsdk-spf12.2-locked:rw" \
	"$BUILDER_IMAGE_REF" /bin/bash -lc \
	'mkdir -p "$HOME" && /repo/stock-qsdk-lab/ddns-native-candidate/verify-reproducible.sh /workspace/qsdk-spf12.2-locked'
status=$?
set -e

[ "$(sha256_file "$qsdk/.config")" = "$QSDK_BASE_CONFIG_SHA256" ] || fail 'shared QSDK .config was not restored'
[ "$(git -C "$qsdk" rev-parse HEAD)" = "$QSDK_TOP_COMMIT" ] || fail 'QSDK source commit changed'
[ "$(git -C "$qsdk/qca/feeds/packages" rev-parse HEAD)" = "$QSDK_PACKAGES_COMMIT" ] || fail 'packages source commit changed'
[ "$(git -C "$qsdk/qca/feeds/luci" rev-parse HEAD)" = "$QSDK_LUCI_COMMIT" ] || fail 'LuCI source commit changed'
exit "$status"
