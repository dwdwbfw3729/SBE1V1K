#!/bin/bash

set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
WORKSPACE_PARENT=$(CDPATH= cd -- "$REPO_ROOT/.." && pwd)
. "$HERE/common.sh"
. "$HERE/sources.lock"
. "$HERE/runtime-sources.lock"
. "$HERE/../tools/select-builder.sh"

QSDK_SOURCE_ROOT=${QSDK_SOURCE_ROOT:-$HERE/../deps/qsdk-spf12.2-locked}
QSDK=$QSDK_SOURCE_ROOT/qsdk
LUCI=$QSDK/qca/feeds/luci
BASELINE_DIR=$REPO_ROOT/stock-qsdk-lab/cache/ipk
OPKG_CONF=$REPO_ROOT/stock-qsdk-lab/overlay/etc/opkg.conf
LUCI_RELEASE=$HERE/candidate-out/release

command -v docker >/dev/null 2>&1 || fail 'Docker is required'
command -v git >/dev/null 2>&1 || fail 'git is required'
command -v python3 >/dev/null 2>&1 || fail 'python3 is required'
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
[ "$(sha256_file "$OPKG_CONF")" = "$RUNTIME_OPKG_CONF_SHA256" ] ||
	fail 'final opkg.conf differs from runtime-sources.lock'
[ -d "$LUCI_RELEASE" ] || fail 'source-built LuCI release is missing; build it first'

while IFS=$'\t' read -r expected filename; do
	case "${expected:-}" in ''|'#'*) continue ;; esac
	[ -f "$BASELINE_DIR/$filename" ] || fail "baseline reference is missing: $filename"
	[ "$(sha256_file "$BASELINE_DIR/$filename")" = "$expected" ] ||
		fail "baseline reference hash mismatch: $filename"
done < "$HERE/runtime-baseline-ipks.lock"

actual_image_id=$(docker image inspect "$BUILDER_IMAGE_REF" --format '{{.Id}}')
[ "$actual_image_id" = "$BUILDER_IMAGE_ID" ] ||
	fail "wrong Docker builder image: $actual_image_id"

case "$(uname -s)" in
	Darwin) temp_parent=/private/tmp ;;
	*) temp_parent=${TMPDIR:-/tmp} ;;
esac
SOURCE_COPY=$(mktemp -d "$temp_parent/sbe-luci-runtime.XXXXXX")
seen_patches=$(mktemp "$temp_parent/sbe-luci-runtime-patches.XXXXXX")
cleanup() {
	rm -f "$seen_patches"
	rm -rf "$SOURCE_COPY"
}
trap cleanup EXIT HUP INT TERM

git -C "$QSDK" archive --format=tar "$QSDK_TOP_COMMIT" \
	package/utils/lua \
	package/system/ubus \
	package/system/uci \
	package/network/utils/iwinfo |
	tar -xf - -C "$SOURCE_COPY"

: > "$seen_patches"
while IFS= read -r patch_name; do
	case "$patch_name" in
		''|'#'*) continue ;;
		/*|*'..'*) fail "unsafe runtime patch name: $patch_name" ;;
	esac
	[[ "$patch_name" =~ [[:space:]] ]] && fail "unsafe runtime patch name: $patch_name"
	grep -Fx -q "$patch_name" "$seen_patches" &&
		fail "duplicate runtime patch in series: $patch_name"
	printf '%s\n' "$patch_name" >> "$seen_patches"
	patch_path=$HERE/runtime-patches/$patch_name
	[ -f "$patch_path" ] || fail "runtime series patch is missing: $patch_name"
	expected=$(awk -F '\t' -v path="runtime-patches/$patch_name" \
		'$2 == path { print $1 }' "$HERE/runtime-patches.lock")
	[ -n "$expected" ] || fail "runtime patch has no hash lock: $patch_name"
	[ "$(printf '%s\n' "$expected" | wc -l | tr -d ' ')" = 1 ] ||
		fail "runtime patch has multiple hash locks: $patch_name"
	[ "$(sha256_file "$patch_path")" = "$expected" ] ||
		fail "runtime patch hash mismatch: $patch_name"
	(
		cd "$SOURCE_COPY"
		# These outer patches add ordinary quilt patch files; their added
		# lines necessarily contain the inner diff's whitespace-prefixed
		# context.  Validate bytes by SHA above and suppress only Git's
		# misleading outer-patch whitespace warning.
		git apply --check --whitespace=nowarn "$patch_path"
		git apply --whitespace=nowarn "$patch_path"
	)
done < "$HERE/runtime-patches/series"

while IFS=$'\t' read -r locked_hash locked_path; do
	case "${locked_hash:-}" in ''|'#'*) continue ;; esac
	case "$locked_path" in runtime-patches/*) ;;
		*) fail "invalid path in runtime-patches.lock: $locked_path" ;;
	esac
	patch_name=${locked_path#runtime-patches/}
	grep -Fx -q "$patch_name" "$seen_patches" ||
		fail "hash-locked runtime patch is absent from series: $patch_name"
done < "$HERE/runtime-patches.lock"

while IFS= read -r patch_path; do
	patch_name=${patch_path#"$HERE/runtime-patches/"}
	grep -Fx -q "$patch_name" "$seen_patches" ||
		fail "unlisted runtime patch file: $patch_name"
done < <(find "$HERE/runtime-patches" -type f -name '*.patch' | LC_ALL=C sort)

source_tree_hash=$(source_tree_sha256 "$SOURCE_COPY")
config_hash_before=$(sha256_file "$QSDK/.config")

set +e
docker run --rm --pull=never --network none --platform linux/arm64 \
	--read-only --tmpfs /tmp:rw,exec,nosuid,nodev \
	-e HOME=/tmp/sbe-luci-runtime-home \
	-e SBE_BUILDER_IMAGE="${SBE_BUILDER_IMAGE:-$BUILDER_IMAGE_REF}" \
	-e SBE_BUILDER_IMAGE_ID="${SBE_BUILDER_IMAGE_ID:-$BUILDER_IMAGE_ID}" \
	-e LC_ALL=C -e TZ=UTC \
	-e SOURCE_DATE_EPOCH="$RUNTIME_SOURCE_DATE_EPOCH" \
	-e EXPECTED_RUNTIME_SOURCE_TREE_SHA256="$source_tree_hash" \
	-e QSDK_JOBS="${QSDK_JOBS:-4}" \
	--mount "type=bind,src=$QSDK,dst=/qsdk" \
	--mount "type=bind,src=$QSDK,dst=/qsdk-original,readonly" \
	--mount "type=bind,src=$SOURCE_COPY,dst=/runtime-source,readonly" \
	--mount "type=bind,src=$SOURCE_COPY/package/utils/lua,dst=/qsdk/package/utils/lua,readonly" \
	--mount "type=bind,src=$SOURCE_COPY/package/system/ubus,dst=/qsdk/package/system/ubus,readonly" \
	--mount "type=bind,src=$SOURCE_COPY/package/system/uci,dst=/qsdk/package/system/uci,readonly" \
	--mount "type=bind,src=$SOURCE_COPY/package/network/utils/iwinfo,dst=/qsdk/package/network/utils/iwinfo,readonly" \
	--mount "type=bind,src=$HERE,dst=/bundle" \
	"$BUILDER_IMAGE_REF" /bin/bash /bundle/build-runtime-in-linux.sh
status=$?
set -e

[ "$(sha256_file "$QSDK/.config")" = "$config_hash_before" ] ||
	fail 'QSDK .config changed during the runtime package-only build'
[ -z "$(git -C "$QSDK" status --porcelain --untracked-files=all)" ] ||
	fail 'QSDK tracked/source tree changed during the runtime package-only build'
[ -z "$(git -C "$LUCI" status --porcelain --untracked-files=all)" ] ||
	fail 'QSDK LuCI source tree changed during the runtime package-only build'
[ "$status" = 0 ] || exit "$status"

# Keep the opaque feed IPKs completely outside the compiler container.  They
# enter only this second, read-only comparison container after A/B release
# artifacts already exist.
set +e
docker run --rm --pull=never --network none --platform linux/arm64 \
	--read-only --tmpfs /tmp:rw,exec,nosuid,nodev \
	-e HOME=/tmp/sbe-luci-runtime-audit-home \
	-e LC_ALL=C -e TZ=UTC \
	--mount "type=bind,src=$QSDK,dst=/qsdk,readonly" \
	--mount "type=bind,src=$BASELINE_DIR,dst=/baseline-ipk,readonly" \
	--mount "type=bind,src=$HERE,dst=/bundle" \
	"$BUILDER_IMAGE_REF" /bin/bash /bundle/audit-runtime-artifacts.sh \
	/bundle/runtime-candidate-out/release \
	/bundle/runtime-candidate-out/audit /baseline-ipk
audit_status=$?
set -e

[ "$(sha256_file "$QSDK/.config")" = "$config_hash_before" ] ||
	fail 'QSDK .config changed during the separate runtime artifact audit'
[ -z "$(git -C "$QSDK" status --porcelain --untracked-files=all)" ] ||
	fail 'QSDK tracked/source tree changed during the separate runtime artifact audit'
[ -z "$(git -C "$LUCI" status --porcelain --untracked-files=all)" ] ||
	fail 'QSDK LuCI source tree changed during the separate runtime artifact audit'
[ "$audit_status" = 0 ] || exit "$audit_status"

# Final-rootfs compatibility is checked after assembly, against that build's
# actual opkg status (tools/build_1_5_3.py), not a historical private dump.
[ "$(sha256_file "$OPKG_CONF")" = "$RUNTIME_OPKG_CONF_SHA256" ] ||
	fail 'final opkg.conf changed during compatibility audit'

printf 'PASS: locked QSDK Lua/LuCI runtime package-only A/B build is byte-identical\n'
printf 'Artifacts: %s/runtime-candidate-out/release\n' "$HERE"
