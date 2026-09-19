#!/bin/sh
set -eu

candidate_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$candidate_dir/../.." && pwd)
workspace_parent=$(CDPATH= cd -- "$repo_root/.." && pwd)
. "$candidate_dir/sources.lock"

source_root=${1:-${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}}
qsdk=$source_root/qsdk
packages=$qsdk/qca/feeds/packages
recipe=$packages/utils/coreutils
attr_recipe=$packages/utils/attr
acl_recipe=$packages/utils/acl
output=${COREUTILS_NATIVE_OUTPUT:-"$candidate_dir/candidate-out/coreutils-native"}
jobs=${QSDK_JOBS:-4}

export LC_ALL=C
export TZ=UTC
export SOURCE_DATE_EPOCH

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

sha256_file() {
	sha256sum "$1" | awk '{print $1}'
}

assert_sha256() {
	actual=$(sha256_file "$1")
	[ "$actual" = "$2" ] || fail "source hash mismatch: $1"
}

set_config_module() {
	symbol=$1
	sed -i -e "/^${symbol}=/d" -e "/^# ${symbol} is not set$/d" "$qsdk/.config"
	printf '%s=m\n' "$symbol" >> "$qsdk/.config"
}

disable_config_symbol() {
	symbol=$1
	sed -i -e "/^${symbol}=/d" -e "/^# ${symbol} is not set$/d" "$qsdk/.config"
	printf '# %s is not set\n' "$symbol" >> "$qsdk/.config"
}

[ "$(uname -s)" = Linux ] || fail 'native coreutils IPKs must be built inside Linux'
[ -f "$qsdk/Makefile" ] || fail "locked QSDK tree is missing: $qsdk"
[ -f "$qsdk/.config" ] || fail 'locked QSDK .config is missing'
[ "$(git -C "$qsdk" rev-parse HEAD)" = "$QSDK_TOP_COMMIT" ] || fail 'wrong QSDK commit'
[ "$(git -C "$packages" rev-parse HEAD)" = "$QSDK_PACKAGES_COMMIT" ] || fail 'wrong packages feed commit'
[ "$(git -C "$packages" rev-parse 'HEAD:utils/coreutils')" = "$COREUTILS_TREE" ] || fail 'wrong coreutils recipe tree'
[ "$(sha256_file "$qsdk/.config")" = "$QSDK_BASE_CONFIG_SHA256" ] || fail 'shared QSDK .config is not the released baseline'

assert_sha256 "$recipe/Makefile" "$COREUTILS_MAKEFILE_SHA256"
assert_sha256 "$recipe/patches/001-no_docs_man_tests.patch" "$COREUTILS_PATCH_001_SHA256"
assert_sha256 "$recipe/patches/002-ls-restore-831-behavior-on-removed-directories.patch" "$COREUTILS_PATCH_002_SHA256"
assert_sha256 "$candidate_dir/distfiles/$COREUTILS_ARCHIVE" "$COREUTILS_ARCHIVE_SHA256"
[ "$(git -C "$packages" rev-parse 'HEAD:utils/attr')" = "$ATTR_TREE" ] || fail 'wrong attr build-dependency recipe tree'
[ "$(git -C "$packages" rev-parse 'HEAD:utils/acl')" = "$ACL_TREE" ] || fail 'wrong acl build-dependency recipe tree'
assert_sha256 "$attr_recipe/Makefile" "$ATTR_MAKEFILE_SHA256"
assert_sha256 "$acl_recipe/Makefile" "$ACL_MAKEFILE_SHA256"
assert_sha256 "$candidate_dir/distfiles/$ATTR_ARCHIVE" "$ATTR_ARCHIVE_SHA256"
assert_sha256 "$candidate_dir/distfiles/$ACL_ARCHIVE" "$ACL_ARCHIVE_SHA256"

target_stage=$qsdk/staging_dir/target-aarch64_cortex-a73+neon-vfpv4_musl
root_stage=$target_stage/root-ipq95xx

path_exists() {
	[ -e "$1" ] || [ -L "$1" ]
}

check_shared_state_clean() {
	dirty=0
	for rel in \
		usr/include/attr \
		usr/include/acl \
		usr/include/sys/xattr.h \
		usr/include/sys/acl.h \
		usr/lib/libattr.a \
		usr/lib/libattr.la \
		usr/lib/libattr.so \
		usr/lib/libattr.so.1 \
		usr/lib/libattr.so.1.1.2448 \
		usr/lib/libacl.a \
		usr/lib/libacl.la \
		usr/lib/libacl.so \
		usr/lib/libacl.so.1 \
		usr/lib/libacl.so.1.1.2253 \
		usr/lib/pkgconfig/libattr.pc \
		usr/lib/pkgconfig/libacl.pc \
		stamp/.attr_installed \
		stamp/.acl_installed \
		stamp/.libattr_installed \
		stamp/.libacl_installed \
		stamp/.coreutils_installed \
		stamp/.coreutils-base64_installed \
		stamp/.coreutils-nohup_installed \
		stamp/.coreutils-timeout_installed \
		packages/attr.list \
		packages/acl.list \
		packages/libattr.list \
		packages/libacl.list \
		packages/coreutils.list \
		packages/coreutils-base64.list \
		packages/coreutils-nohup.list \
		packages/coreutils-timeout.list \
		pkginfo/attr.provides \
		pkginfo/acl.provides \
		pkginfo/libattr.provides \
		pkginfo/libacl.provides \
		pkginfo/coreutils.provides \
		pkginfo/coreutils-base64.provides \
		pkginfo/coreutils-nohup.provides \
		pkginfo/coreutils-timeout.provides; do
		if path_exists "$target_stage/$rel"; then
			printf 'ERROR: temporary target staging path remains: %s\n' "$target_stage/$rel" >&2
			dirty=1
		fi
	done
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
		if path_exists "$root_stage/$rel"; then
			printf 'ERROR: temporary root staging path remains: %s\n' "$root_stage/$rel" >&2
			dirty=1
		fi
	done
	if find "$qsdk/bin" -type f \
		\( -name 'coreutils*.ipk' -o -name 'attr_*.ipk' -o -name 'libattr_*.ipk' \
		-o -name 'acl_*.ipk' -o -name 'libacl_*.ipk' \) -print -quit | grep -q .; then
		printf 'ERROR: temporary coreutils/ACL/attr IPK remains under shared QSDK bin\n' >&2
		dirty=1
	fi
	[ "$dirty" -eq 0 ]
}

remove_transient_build_state() {
	rm -rf "$target_stage/usr/include/attr" "$target_stage/usr/include/acl"
	rm -f \
		"$target_stage/usr/include/sys/xattr.h" \
		"$target_stage/usr/include/sys/acl.h" \
		"$target_stage/usr/lib/libattr.a" \
		"$target_stage/usr/lib/libattr.la" \
		"$target_stage/usr/lib/libattr.so" \
		"$target_stage/usr/lib/libattr.so.1" \
		"$target_stage/usr/lib/libattr.so.1.1.2448" \
		"$target_stage/usr/lib/libacl.a" \
		"$target_stage/usr/lib/libacl.la" \
		"$target_stage/usr/lib/libacl.so" \
		"$target_stage/usr/lib/libacl.so.1" \
		"$target_stage/usr/lib/libacl.so.1.1.2253" \
		"$target_stage/usr/lib/pkgconfig/libattr.pc" \
		"$target_stage/usr/lib/pkgconfig/libacl.pc" \
		"$target_stage/stamp/.attr_installed" \
		"$target_stage/stamp/.acl_installed" \
		"$target_stage/stamp/.libattr_installed" \
		"$target_stage/stamp/.libacl_installed" \
		"$target_stage/stamp/.coreutils_installed" \
		"$target_stage/stamp/.coreutils-base64_installed" \
		"$target_stage/stamp/.coreutils-nohup_installed" \
		"$target_stage/stamp/.coreutils-timeout_installed" \
		"$target_stage/packages/attr.list" \
		"$target_stage/packages/acl.list" \
		"$target_stage/packages/libattr.list" \
		"$target_stage/packages/libacl.list" \
		"$target_stage/packages/coreutils.list" \
		"$target_stage/packages/coreutils-base64.list" \
		"$target_stage/packages/coreutils-nohup.list" \
		"$target_stage/packages/coreutils-timeout.list" \
		"$target_stage/pkginfo/attr.provides" \
		"$target_stage/pkginfo/acl.provides" \
		"$target_stage/pkginfo/libattr.provides" \
		"$target_stage/pkginfo/libacl.provides" \
		"$target_stage/pkginfo/coreutils.provides" \
		"$target_stage/pkginfo/coreutils-base64.provides" \
		"$target_stage/pkginfo/coreutils-nohup.provides" \
		"$target_stage/pkginfo/coreutils-timeout.provides" \
		"$root_stage/etc/xattr.conf" \
		"$root_stage/usr/bin/attr" \
		"$root_stage/usr/bin/getfattr" \
		"$root_stage/usr/bin/setfattr" \
		"$root_stage/usr/lib/libattr.so" \
		"$root_stage/usr/lib/libattr.so.1" \
		"$root_stage/usr/lib/libattr.so.1.1.2448" \
		"$root_stage/usr/lib/libacl.so" \
		"$root_stage/usr/lib/libacl.so.1" \
		"$root_stage/usr/lib/libacl.so.1.1.2253" \
		"$root_stage/usr/libexec/base64-coreutils" \
		"$root_stage/usr/libexec/nohup-coreutils" \
		"$root_stage/usr/libexec/timeout-coreutils" \
		"$root_stage/stamp/.attr_installed" \
		"$root_stage/stamp/.acl_installed" \
		"$root_stage/stamp/.libattr_installed" \
		"$root_stage/stamp/.libacl_installed" \
		"$root_stage/stamp/.coreutils_installed" \
		"$root_stage/stamp/.coreutils-base64_installed" \
		"$root_stage/stamp/.coreutils-nohup_installed" \
		"$root_stage/stamp/.coreutils-timeout_installed"
	find "$qsdk/bin" -type f \
		\( -name 'coreutils*.ipk' -o -name 'attr_*.ipk' -o -name 'libattr_*.ipk' \
		-o -name 'acl_*.ipk' -o -name 'libacl_*.ipk' \) -delete
}

check_shared_state_clean || fail 'shared QSDK staging is not clean enough for an isolated coreutils build'

mkdir -p "$output"
config_backup=$(mktemp "${TMPDIR:-/tmp}/sbe-coreutils-config.XXXXXX")
old_config_backup=$(mktemp "${TMPDIR:-/tmp}/sbe-coreutils-old-config.XXXXXX")
defconfig_log=$(mktemp "${TMPDIR:-/tmp}/sbe-coreutils-defconfig.XXXXXX")
selected_symbols=$(mktemp "${TMPDIR:-/tmp}/sbe-coreutils-selected.XXXXXX")
cp "$qsdk/.config" "$config_backup"
had_old_config=0
if [ -f "$qsdk/.config.old" ]; then
	had_old_config=1
	cp "$qsdk/.config.old" "$old_config_backup"
fi
build_started=0

cleanup() {
	status=$?
	trap - EXIT HUP INT TERM
	set +e
	if [ "$build_started" -eq 1 ]; then
		make -C "$qsdk" DL_DIR="$candidate_dir/distfiles" \
			package/feeds/packages/coreutils/clean >/dev/null 2>&1 || true
		make -C "$qsdk" DL_DIR="$candidate_dir/distfiles" \
			package/feeds/packages/acl/clean >/dev/null 2>&1 || true
		make -C "$qsdk" DL_DIR="$candidate_dir/distfiles" \
			package/feeds/packages/attr/clean >/dev/null 2>&1 || true
		remove_transient_build_state
	fi
	cp "$config_backup" "$qsdk/.config"
	if [ "$had_old_config" -eq 1 ]; then
		cp "$old_config_backup" "$qsdk/.config.old"
	else
		rm -f "$qsdk/.config.old"
	fi
	rm -f "$config_backup" "$old_config_backup" "$defconfig_log" "$selected_symbols"
	if [ "$(sha256_file "$qsdk/.config")" != "$QSDK_BASE_CONFIG_SHA256" ]; then
		printf 'ERROR: shared QSDK .config was not restored by cleanup\n' >&2
		status=1
	fi
	if ! check_shared_state_clean; then
		printf 'ERROR: isolated coreutils build left shared staging residue\n' >&2
		status=1
	fi
	exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

sed -n 's/^\(CONFIG_PACKAGE_coreutils-[^=]*\)=[ym]$/\1/p' "$qsdk/.config" > "$selected_symbols"
while IFS= read -r symbol; do
	[ -n "$symbol" ] || continue
	disable_config_symbol "$symbol"
done < "$selected_symbols"

# The released image selects the top-level Open vSwitch package, whose recipe
# pulls coreutils-sleep solely for its own fractional-sleep helper.  Disable
# that top-level selection only in this temporary package-only configuration so
# defconfig cannot add a fourth, out-of-scope coreutils applet package.
disable_config_symbol CONFIG_PACKAGE_openvswitch
disable_config_symbol CONFIG_PACKAGE_attr
disable_config_symbol CONFIG_PACKAGE_acl

set_config_module CONFIG_PACKAGE_coreutils
set_config_module CONFIG_PACKAGE_coreutils-base64
set_config_module CONFIG_PACKAGE_coreutils-nohup
set_config_module CONFIG_PACKAGE_coreutils-timeout
set_config_module CONFIG_PACKAGE_libattr
set_config_module CONFIG_PACKAGE_libacl

make -C "$qsdk" defconfig >"$defconfig_log" 2>&1 || {
	cat "$defconfig_log" >&2
	fail 'QSDK defconfig failed for native coreutils packages'
}

for selected in \
	CONFIG_PACKAGE_coreutils=m \
	CONFIG_PACKAGE_coreutils-base64=m \
	CONFIG_PACKAGE_coreutils-nohup=m \
	CONFIG_PACKAGE_coreutils-timeout=m; do
	grep -Fqx "$selected" "$qsdk/.config" || fail "defconfig did not retain $selected"
done

unexpected=$(grep -E '^CONFIG_PACKAGE_coreutils-[^=]+=[ym]$' "$qsdk/.config" |
	grep -Ev '^CONFIG_PACKAGE_coreutils-(base64|nohup|timeout)=m$' || true)
[ -z "$unexpected" ] || fail "defconfig selected unrelated coreutils applets: $unexpected"

cp "$qsdk/.config" "$output/CANDIDATE_BUILD_CONFIG"
build_config_sha=$(sha256_file "$qsdk/.config")

find "$output" -maxdepth 1 -type f -name 'coreutils*.ipk' -delete
build_started=1
make -C "$qsdk" DL_DIR="$candidate_dir/distfiles" \
	package/feeds/packages/acl/clean
make -C "$qsdk" DL_DIR="$candidate_dir/distfiles" \
	package/feeds/packages/attr/clean
make -C "$qsdk" DL_DIR="$candidate_dir/distfiles" \
	package/feeds/packages/coreutils/clean
make -C "$qsdk" -j"$jobs" NO_DEPS=1 \
	DL_DIR="$candidate_dir/distfiles" \
	package/feeds/packages/attr/compile V=s
make -C "$qsdk" -j"$jobs" NO_DEPS=1 \
	DL_DIR="$candidate_dir/distfiles" \
	package/feeds/packages/acl/compile V=s
make -C "$qsdk" -j"$jobs" NO_DEPS=1 \
	DL_DIR="$candidate_dir/distfiles" \
	package/feeds/packages/coreutils/compile V=s

[ "$(sha256_file "$qsdk/.config")" = "$build_config_sha" ] || fail 'temporary build configuration changed during compilation'

for expected in \
	"coreutils_${COREUTILS_VERSION}-${COREUTILS_RELEASE}_${TARGET_ARCH}.ipk" \
	"coreutils-base64_${COREUTILS_VERSION}-${COREUTILS_RELEASE}_${TARGET_ARCH}.ipk" \
	"coreutils-nohup_${COREUTILS_VERSION}-${COREUTILS_RELEASE}_${TARGET_ARCH}.ipk" \
	"coreutils-timeout_${COREUTILS_VERSION}-${COREUTILS_RELEASE}_${TARGET_ARCH}.ipk"; do
	artifact=$(find "$qsdk/bin" -type f -name "$expected" | LC_ALL=C sort)
	[ "$(printf '%s\n' "$artifact" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 1 ] || \
		fail "expected one shared-bin artifact named $expected"
	cp "$artifact" "$output/$expected"
done
[ "$(find "$output" -maxdepth 1 -type f -name 'coreutils*.ipk' | wc -l | tr -d ' ')" -eq 4 ] || fail 'package-only build emitted an unexpected coreutils package set'

(cd "$output" && sha256sum ./coreutils*.ipk > PACKAGE_SHA256SUMS)
printf 'BUILT, NOT DEPLOYED: four source-bound native coreutils IPKs are in %s\n' "$output"
printf 'Only coreutils and its temporary official ACL/attr build dependencies were cleaned or compiled.\n'
