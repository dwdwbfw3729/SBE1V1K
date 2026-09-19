#!/bin/bash

set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
WORKSPACE_PARENT=$(CDPATH= cd -- "$REPO_ROOT/.." && pwd)
. "$HERE/common.sh"
. "$HERE/sources.lock"
. "$HERE/../tools/select-builder.sh"

QSDK_SOURCE_ROOT=${QSDK_SOURCE_ROOT:-$HERE/../deps/qsdk-spf12.2-locked}
QSDK=$QSDK_SOURCE_ROOT/qsdk
LUCI=$QSDK/qca/feeds/luci
BUILD_SCOPE=${1:-full}

case "$BUILD_SCOPE" in
	full|rpcd-release-only|qca-wireless-only|status-realtime-only|base-i18n-only|network-only) ;;
	*) fail "usage: $0 [full|rpcd-release-only|qca-wireless-only|status-realtime-only|base-i18n-only|network-only]" ;;
esac

command -v docker >/dev/null 2>&1 || fail 'Docker is required'
command -v git >/dev/null 2>&1 || fail 'git is required'
[ -f "$QSDK/Makefile" ] || fail "locked QSDK tree is missing: $QSDK"
[ -f "$QSDK/.config" ] || fail 'locked QSDK .config is missing'
[ "$(git -C "$QSDK" rev-parse HEAD)" = "$QSDK_TOP_COMMIT" ] ||
	fail 'QSDK top-level commit does not match sources.lock'
[ "$(git -C "$LUCI" rev-parse HEAD)" = "$QSDK_LUCI_COMMIT" ] ||
	fail 'QSDK LuCI commit does not match sources.lock'
[ -z "$(git -C "$QSDK" status --porcelain --untracked-files=all)" ] ||
	fail 'QSDK tracked/source tree is not clean'
[ -z "$(git -C "$LUCI" status --porcelain --untracked-files=all)" ] ||
	fail 'QSDK LuCI source tree is not clean'
[ "$(sha256_file "$QSDK/.config")" = "$QSDK_BASE_CONFIG_SHA256" ] ||
	fail 'QSDK .config differs from the released baseline'

actual_image_id=$(docker image inspect "$BUILDER_IMAGE_REF" --format '{{.Id}}')
[ "$actual_image_id" = "$BUILDER_IMAGE_ID" ] ||
	fail "wrong Docker builder image: $actual_image_id"

case "$(uname -s)" in
	Darwin) temp_parent=/private/tmp ;;
	*) temp_parent=${TMPDIR:-/tmp} ;;
esac
SOURCE_COPY=$(mktemp -d "$temp_parent/sbe-luci-maintenance.XXXXXX")
cleanup() {
	rm -rf "$SOURCE_COPY"
}
trap cleanup EXIT HUP INT TERM

git -C "$LUCI" archive --format=tar "$QSDK_LUCI_COMMIT" |
	tar -xf - -C "$SOURCE_COPY"

seen_patches=$(mktemp "$temp_parent/sbe-luci-patches.XXXXXX")
trap 'rm -f "$seen_patches"; cleanup' EXIT HUP INT TERM
: > "$seen_patches"
while IFS= read -r patch_name; do
	case "$patch_name" in
		''|'#'*) continue ;;
		/*|*'..'*) fail "unsafe patch name: $patch_name" ;;
	esac
	[[ "$patch_name" =~ [[:space:]] ]] && fail "unsafe patch name: $patch_name"
	grep -Fx -q "$patch_name" "$seen_patches" &&
		fail "duplicate patch in series: $patch_name"
	printf '%s\n' "$patch_name" >> "$seen_patches"
	patch_path=$HERE/patches/$patch_name
	[ -f "$patch_path" ] || fail "series patch is missing: $patch_name"
	expected=$(awk -F '\t' -v path="patches/$patch_name" '$2 == path { print $1 }' "$HERE/patches.lock")
	[ -n "$expected" ] || fail "patch has no hash lock: $patch_name"
	[ "$(printf '%s\n' "$expected" | wc -l | tr -d ' ')" = 1 ] ||
		fail "patch has multiple hash locks: $patch_name"
	[ "$(sha256_file "$patch_path")" = "$expected" ] ||
		fail "patch hash mismatch: $patch_name"
	(
		cd "$SOURCE_COPY"
		git apply --check "$patch_path"
		git apply "$patch_path"
	)
done < "$HERE/patches/series"

while IFS=$'\t' read -r _locked_hash locked_path; do
	case "${_locked_hash:-}" in ''|'#'*) continue ;; esac
	case "$locked_path" in patches/*) ;;
		*) fail "invalid path in patches.lock: $locked_path" ;;
	esac
	patch_name=${locked_path#patches/}
	grep -Fx -q "$patch_name" "$seen_patches" ||
		fail "hash-locked patch is absent from series: $patch_name"
done < "$HERE/patches.lock"

while IFS= read -r patch_path; do
	patch_name=${patch_path#"$HERE/patches/"}
	grep -Fx -q "$patch_name" "$seen_patches" ||
		fail "unlisted patch file: $patch_name"
done < <(find "$HERE/patches" -type f -name '*.patch' | LC_ALL=C sort)

source_tree_hash=$(source_tree_sha256 "$SOURCE_COPY")
config_hash_before=$(sha256_file "$QSDK/.config")

set +e
if [ "$BUILD_SCOPE" = rpcd-release-only ] ||
   [ "$BUILD_SCOPE" = qca-wireless-only ] ||
   [ "$BUILD_SCOPE" = status-realtime-only ] ||
   [ "$BUILD_SCOPE" = base-i18n-only ] ||
   [ "$BUILD_SCOPE" = network-only ]; then
	linux_builder=/bundle/rebuild-rpcd-release-in-linux.sh
else
	linux_builder=/bundle/build-in-linux.sh
fi
docker run --rm --pull=never --network none --platform linux/arm64 \
	--read-only --tmpfs /tmp:rw,exec,nosuid,nodev \
	-e HOME=/tmp/sbe-luci-home \
	-e LC_ALL=C -e TZ=UTC \
	-e SBE_BUILDER_IMAGE="${SBE_BUILDER_IMAGE:-$BUILDER_IMAGE_REF}" \
	-e SBE_BUILDER_IMAGE_ID="${SBE_BUILDER_IMAGE_ID:-$BUILDER_IMAGE_ID}" \
	-e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
	-e EXPECTED_SOURCE_TREE_SHA256="$source_tree_hash" \
	-e LUCI_REBUILD_SCOPE="$BUILD_SCOPE" \
	-e QSDK_JOBS="${QSDK_JOBS:-4}" \
	--mount "type=bind,src=$QSDK,dst=/qsdk" \
	--mount "type=bind,src=$SOURCE_COPY,dst=/qsdk/qca/feeds/luci,readonly" \
	--mount "type=bind,src=$HERE,dst=/bundle" \
	"$BUILDER_IMAGE_REF" /bin/bash "$linux_builder"
status=$?
set -e

[ "$(sha256_file "$QSDK/.config")" = "$config_hash_before" ] ||
	fail 'QSDK .config changed during the package-only build'
[ -z "$(git -C "$QSDK" status --porcelain --untracked-files=all)" ] ||
	fail 'QSDK tracked/source tree changed during the package-only build'
[ -z "$(git -C "$LUCI" status --porcelain --untracked-files=all)" ] ||
	fail 'QSDK LuCI source tree changed during the package-only build'
[ "$status" = 0 ] || exit "$status"

if [ "$BUILD_SCOPE" = rpcd-release-only ]; then
	printf 'PASS: locked rpcd-mod-luci release-only A/B rebuild is byte-identical\n'
elif [ "$BUILD_SCOPE" = qca-wireless-only ]; then
	printf 'PASS: locked QCA wireless LuCI two-package A/B rebuild is byte-identical\n'
elif [ "$BUILD_SCOPE" = status-realtime-only ]; then
	printf 'PASS: locked luci-mod-status realtime-graph A/B rebuild is byte-identical\n'
elif [ "$BUILD_SCOPE" = base-i18n-only ]; then
	printf 'PASS: locked luci-base and Simplified Chinese catalog A/B rebuild is byte-identical\n'
elif [ "$BUILD_SCOPE" = network-only ]; then
	printf 'PASS: locked luci-mod-network A/B rebuild is byte-identical\n'
else
	printf 'PASS: locked QSDK LuCI package-only A/B build is byte-identical\n'
fi
printf 'Artifacts: %s/candidate-out/release\n' "$HERE"
