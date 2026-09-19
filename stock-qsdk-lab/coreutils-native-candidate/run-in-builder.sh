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
[ "$(sha256_file "$candidate_dir/distfiles/$COREUTILS_ARCHIVE")" = "$COREUTILS_ARCHIVE_SHA256" ] || fail 'wrong coreutils source archive'
[ "$(sha256_file "$candidate_dir/distfiles/$ATTR_ARCHIVE")" = "$ATTR_ARCHIVE_SHA256" ] || fail 'wrong attr build-dependency archive'
[ "$(sha256_file "$candidate_dir/distfiles/$ACL_ARCHIVE")" = "$ACL_ARCHIVE_SHA256" ] || fail 'wrong acl build-dependency archive'

config_before=$(sha256_file "$qsdk/.config")
old_config_before=absent
if [ -f "$qsdk/.config.old" ]; then
	old_config_before=$(sha256_file "$qsdk/.config.old")
fi
packages_status_before=$(git -C "$qsdk/qca/feeds/packages" status --porcelain -- utils/coreutils utils/attr utils/acl)
actual_image_id=$(docker image inspect "$BUILDER_IMAGE_REF" --format '{{.Id}}')
[ "$actual_image_id" = "$BUILDER_IMAGE_ID" ] || fail "wrong Docker builder image: $actual_image_id"

set +e
docker run --rm --pull=never --network none --platform linux/arm64 \
	--hostname sbe-coreutils-builder \
	-e HOME=/tmp/sbe-coreutils-native-home \
	-e LC_ALL=C -e TZ=UTC \
	-e QSDK_JOBS="${QSDK_JOBS:-4}" \
	-e GIT_CONFIG_COUNT=2 \
	-e GIT_CONFIG_KEY_0=safe.directory \
	-e GIT_CONFIG_VALUE_0=/workspace/qsdk-spf12.2-locked/qsdk \
	-e GIT_CONFIG_KEY_1=safe.directory \
	-e GIT_CONFIG_VALUE_1=/workspace/qsdk-spf12.2-locked/qsdk/qca/feeds/packages \
	-v "$repo_root:/repo:ro" \
	-v "$candidate_dir:/repo/stock-qsdk-lab/coreutils-native-candidate:rw" \
	-v "$source_root:/workspace/qsdk-spf12.2-locked:rw" \
	"$BUILDER_IMAGE_REF" /bin/bash -lc \
	'mkdir -p "$HOME" && /repo/stock-qsdk-lab/coreutils-native-candidate/verify-reproducible.sh /workspace/qsdk-spf12.2-locked'
status=$?
set -e

[ "$(sha256_file "$qsdk/.config")" = "$config_before" ] || fail 'shared QSDK .config was not restored'
if [ "$old_config_before" = absent ]; then
	[ ! -f "$qsdk/.config.old" ] || fail 'shared QSDK .config.old was unexpectedly created'
else
	[ -f "$qsdk/.config.old" ] || fail 'shared QSDK .config.old was not restored'
	[ "$(sha256_file "$qsdk/.config.old")" = "$old_config_before" ] || fail 'shared QSDK .config.old changed'
fi
[ "$(git -C "$qsdk" rev-parse HEAD)" = "$QSDK_TOP_COMMIT" ] || fail 'QSDK source commit changed'
[ "$(git -C "$qsdk/qca/feeds/packages" rev-parse HEAD)" = "$QSDK_PACKAGES_COMMIT" ] || fail 'packages source commit changed'
packages_status_after=$(git -C "$qsdk/qca/feeds/packages" status --porcelain -- utils/coreutils utils/attr utils/acl)
[ "$packages_status_after" = "$packages_status_before" ] || fail 'locked coreutils/ACL/attr recipe tree changed'
target_stage=$qsdk/staging_dir/target-aarch64_cortex-a73+neon-vfpv4_musl
if find "$target_stage/usr/include" "$target_stage/usr/lib" \
	\( -path '*/attr' -o -path '*/attr/*' -o -path '*/acl' -o -path '*/acl/*' \
	-o -name 'libattr*' -o -name 'libacl*' \) -print -quit | grep -q .; then
	fail 'temporary ACL/attr headers or libraries remained in shared staging'
fi
root_stage=$target_stage/root-ipq95xx
for rel in \
	etc/xattr.conf \
	usr/bin/attr \
	usr/bin/getfattr \
	usr/bin/setfattr \
	usr/lib/libattr.so \
	usr/lib/libattr.so.1 \
	usr/lib/libattr.so.1.1.2448 \
	usr/lib/libacl.so \
	usr/lib/libacl.so.1 \
	usr/lib/libacl.so.1.1.2253 \
	usr/libexec/base64-coreutils \
	usr/libexec/nohup-coreutils \
	usr/libexec/timeout-coreutils \
	stamp/.attr_installed \
	stamp/.acl_installed \
	stamp/.libattr_installed \
	stamp/.libacl_installed \
	stamp/.coreutils_installed \
	stamp/.coreutils-base64_installed \
	stamp/.coreutils-nohup_installed \
	stamp/.coreutils-timeout_installed; do
	[ ! -e "$root_stage/$rel" ] && [ ! -L "$root_stage/$rel" ] || \
		fail "temporary root staging path remained: $root_stage/$rel"
done
if find "$qsdk/bin" -type f \
	\( -name 'coreutils*.ipk' -o -name 'attr_*.ipk' -o -name 'libattr_*.ipk' \
	-o -name 'acl_*.ipk' -o -name 'libacl_*.ipk' \) -print -quit | grep -q .; then
	fail 'temporary coreutils/ACL/attr IPKs remained under shared QSDK bin'
fi
exit "$status"
