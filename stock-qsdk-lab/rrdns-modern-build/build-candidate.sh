#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$build_dir/../.." && pwd)
workspace_parent=$(CDPATH= cd -- "$repo_root/.." && pwd)
. "$build_dir/sources.lock"

source_root=${1:-${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}}
qsdk_dir=$source_root/qsdk
jobs=${QSDK_JOBS:-4}
output=${RRDNS_MODERN_OUTPUT:-"$build_dir/candidate-out/rrdns-modern"}

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

[ "$(uname -s)" = Linux ] || fail 'rrdns candidate must be built inside Linux'
[ -f "$qsdk_dir/Makefile" ] || fail "complete QSDK tree is missing: $qsdk_dir"
[ -f "$qsdk_dir/.config" ] || fail 'locked QSDK .config is missing'
"$build_dir/verify-sources.sh"

rpcd_recipe=$qsdk_dir/package/system/rpcd/Makefile
ubus_recipe=$qsdk_dir/package/system/ubus/Makefile
ubox_recipe=$qsdk_dir/package/libs/libubox/Makefile
[ -f "$rpcd_recipe" ] && [ -f "$ubus_recipe" ] && [ -f "$ubox_recipe" ] ||
	fail 'stock rpcd/ubus/libubox recipes are missing'
grep -F -q "PKG_SOURCE_VERSION:=$QSDK_RPCD_COMMIT" "$rpcd_recipe" ||
	fail 'stock rpcd commit differs from the reviewed plugin ABI target'
grep -F -q '$(CP) $(PKG_BUILD_DIR)/include/rpcd $(1)/usr/include/' "$rpcd_recipe" ||
	fail 'stock rpcd recipe no longer stages plugin headers'
grep -F -q "PKG_SOURCE_VERSION:=$QSDK_LIBUBUS_COMMIT" "$ubus_recipe" ||
	fail 'stock libubus commit differs from the reviewed ABI target'
grep -F -q "PKG_ABI_VERSION:=$QSDK_LIBUBUS_ABI" "$ubus_recipe" ||
	fail 'stock libubus SONAME ABI differs from the reviewed target'
grep -F -q "PKG_SOURCE_VERSION:=$QSDK_LIBUBOX_COMMIT" "$ubox_recipe" ||
	fail 'stock libubox commit differs from the reviewed ABI target'
grep -F -q "ABI_VERSION:=$QSDK_LIBUBOX_ABI" "$ubox_recipe" ||
	fail 'stock libubox package ABI differs from the reviewed target'

archive_source=$build_dir/distfiles/$LUCI_ARCHIVE
archive_target=$qsdk_dir/dl/$LUCI_ARCHIVE
if [ -f "$archive_target" ]; then
	[ "$(sha256_file "$archive_target")" = "$LUCI_ARCHIVE_SHA256" ] ||
		fail "QSDK distfile exists with the wrong hash: $archive_target"
else
	cp "$archive_source" "$archive_target"
fi

package_name=sbe-rpcd-mod-rrdns20170710-modern-candidate
package_parent=$qsdk_dir/package/sbe-qsdk-lab
package_target=$package_parent/$package_name
package_source=$build_dir/package-overlay/$package_name
mkdir -p "$package_parent" "$output"
config_backup=$(mktemp "${TMPDIR:-/tmp}/sbe-rrdns-config.XXXXXX")
cp "$qsdk_dir/.config" "$config_backup"

cleanup() {
	if [ -L "$package_target" ] && [ "$(readlink "$package_target")" = "$package_source" ]; then
		rm -f "$package_target"
	fi
	if [ -f "$config_backup" ]; then
		cp "$config_backup" "$qsdk_dir/.config"
		rm -f "$config_backup"
	fi
}
trap cleanup EXIT HUP INT TERM

if [ -L "$package_target" ]; then
	[ "$(readlink "$package_target")" = "$package_source" ] ||
		fail "$package_target points somewhere unexpected"
elif [ -e "$package_target" ]; then
	fail "refusing to replace existing package path: $package_target"
else
	ln -s "$package_source" "$package_target"
fi

cat > "$qsdk_dir/.config" <<'EOF'
CONFIG_TARGET_ipq95xx=y
CONFIG_TARGET_ipq95xx_generic=y
CONFIG_TARGET_ipq95xx_generic_Default=y
CONFIG_DEVEL=y
CONFIG_TOOLCHAINOPTS=y
CONFIG_BINUTILS_USE_VERSION_2_31_1=y
CONFIG_GCC_USE_VERSION_7=y
CONFIG_LIBC_USE_MUSL=y
CONFIG_IPV6=y
CONFIG_PKG_CHECK_FORMAT_SECURITY=y
CONFIG_PKG_ASLR_PIE=y
CONFIG_PKG_CC_STACKPROTECTOR_STRONG=y
CONFIG_PKG_FORTIFY_SOURCE_2=y
CONFIG_PKG_RELRO_FULL=y
CONFIG_PACKAGE_sbe-rpcd-mod-rrdns20170710-modern-candidate=m
EOF
make -C "$qsdk_dir" defconfig

minimal_config=$(mktemp "${TMPDIR:-/tmp}/sbe-rrdns-minimal.XXXXXX")
awk '!/^CONFIG_PACKAGE_kmod-[^=]*=[ym]$/' "$qsdk_dir/.config" > "$minimal_config"
cp "$minimal_config" "$qsdk_dir/.config"
rm -f "$minimal_config"
cp "$qsdk_dir/.config" "$output/CANDIDATE_BUILD_CONFIG"

find "$qsdk_dir/bin" -type f \
	-name 'sbe-rpcd-mod-rrdns20170710-modern-candidate_*.ipk' -delete
find "$output" -maxdepth 1 -type f \
	-name 'sbe-rpcd-mod-rrdns20170710-modern-candidate_*.ipk' -delete

staging_target=$qsdk_dir/staging_dir/target-aarch64_cortex-a73+neon-vfpv4_musl
libubus_header=$staging_target/usr/include/libubus.h
[ -f "$libubus_header" ] || fail 'stock dependency build did not stage libubus.h'
[ "$(sha256_file "$libubus_header")" = "$QSDK_LIBUBUS_H_SHA256" ] ||
	fail 'staged libubus.h differs from the reviewed stock client ABI'
[ "$(sha256_file "$package_source/files/rpcd-plugin-abi.h")" = \
	"$RRDNS_MINIMAL_ABI_HEADER_SHA256" ] ||
	fail 'candidate minimal rpcd plugin ABI header differs from the lock'
make -C "$qsdk_dir" "package/$package_name/clean"
make -C "$qsdk_dir" -j"$jobs" NO_DEPS=1 "package/$package_name/compile" V=s

artifact=$(find "$qsdk_dir/bin" -type f \
	-name 'sbe-rpcd-mod-rrdns20170710-modern-candidate_*.ipk' -print | \
	LC_ALL=C sort | tail -n 1)
[ -n "$artifact" ] || fail 'build completed without the rrdns candidate IPK'
cp "$artifact" "$output/"
artifact=$output/$(basename "$artifact")

control=$(tar -xOzf "$artifact" ./control.tar.gz | tar -xOzf - ./control) ||
	fail 'cannot extract candidate control metadata'
actual_package=$(printf '%s\n' "$control" | sed -n 's/^Package: //p')
[ "$actual_package" = "$package_name" ] ||
	fail "candidate has unexpected package identity: $actual_package"
actual_source=$(printf '%s\n' "$control" | sed -n 's/^Source: //p')
[ "$actual_source" = "$LUCI_ARCHIVE" ] ||
	fail "candidate has unexpected Source metadata: $actual_source"
case "$control" in
	*'/workspace/'*|*'/Users/'*|*'/home/'*|*'/private/tmp/'*|*'BEGIN '*'PRIVATE KEY'*)
		fail 'candidate control metadata leaks a host path or private key'
		;;
esac

(cd "$output" && sha256sum "./$(basename "$artifact")") > \
	"$output/PACKAGE_SHA256SUMS"
printf 'BUILT, NOT APPROVED: current official rpcd-mod-rrdns candidate is in %s\n' "$output"
printf 'No rootfs, image, kernel or device target was invoked.\n'
