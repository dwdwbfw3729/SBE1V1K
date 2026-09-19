#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$build_dir/../.." && pwd)
workspace_parent=$(CDPATH= cd -- "$repo_root/.." && pwd)
. "$build_dir/sources.lock"

source_root=${1:-${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}}
qsdk_dir=$source_root/qsdk
jobs=${QSDK_JOBS:-4}
diagnostic_package=${CORE_USERLAND_DIAGNOSTIC_PACKAGE:-}
kernel_build_dir=${QSDK_KERNEL_BUILD_DIR:-"$source_root/candidate-work/kernel-stock-passwall"}
output=${CORE_USERLAND_OUTPUT:-"$build_dir/candidate-out/core-userland-2026"}
abi_sysroot=${SBE_STOCK_ABI_SYSROOT:-"$build_dir/work/stock-abi-sysroot"}

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

audit_ipk_source() {
	ipk=$1
	expected=$2
	[ -f "$ipk" ] || fail "candidate IPK is missing: $ipk"
	control=$(tar -xOzf "$ipk" ./control.tar.gz | tar -xOzf - ./control) || \
		fail "cannot extract control metadata from $ipk"
	actual=$(printf '%s\n' "$control" | sed -n 's/^Source: //p')
	[ "$actual" = "$expected" ] || \
		fail "$ipk has unexpected Source metadata: $actual"
	case "$control" in
		*'/workspace/'*|*'/Users/'*|*'/home/'*|*'/private/tmp/'*|*'BEGIN '*'PRIVATE KEY'*)
			fail "$ipk control metadata leaks a host path or private key"
			;;
	esac
}

[ "$(uname -s)" = Linux ] || \
	fail 'core-userland candidates must be built inside Linux'
[ -f "$qsdk_dir/Makefile" ] || fail "complete QSDK tree is missing: $qsdk_dir"
[ -f "$qsdk_dir/.config" ] || fail 'locked QSDK .config is missing'
[ -f "$kernel_build_dir/.config" ] || \
	fail "factory-derived kernel config is missing: $kernel_build_dir/.config"
[ -f "$kernel_build_dir/modules.builtin" ] || \
	fail "factory-derived modules.builtin is missing: $kernel_build_dir/modules.builtin"
[ -d "$kernel_build_dir/user_headers/include" ] || \
	fail "factory-derived kernel user headers are missing: $kernel_build_dir/user_headers/include"
[ "$(sha256_file "$abi_sysroot/lib/libustream-ssl.so")" = "$STOCK_USTREAM_SSL_SHA256" ] || \
	fail 'factory libustream-ssl ABI sysroot is missing or changed'
[ "$(sha256_file "$abi_sysroot/usr/lib/libiwinfo.so")" = "$STOCK_IWINFO_SO_SHA256" ] || \
	fail 'factory libiwinfo ABI sysroot is missing or changed'
[ -f "$abi_sysroot/usr/include/libubox/ustream-ssl.h" ] || \
	fail 'locked factory ustream-ssl header is missing'
[ -f "$abi_sysroot/usr/include/iwinfo.h" ] || \
	fail 'locked factory iwinfo header is missing'
grep -q '^# CONFIG_LOCALVERSION_AUTO is not set$' "$kernel_build_dir/.config" || \
	fail 'factory-derived candidate kernel config has unexpected LOCALVERSION_AUTO policy'

"$build_dir/verify-sources.sh"
"$build_dir/fetch-sources.sh" "$qsdk_dir/dl"

package_parent=$qsdk_dir/package/sbe-qsdk-lab
mkdir -p "$package_parent"
config_backup=$(mktemp "${TMPDIR:-/tmp}/sbe-core-userland-config.XXXXXX")
cp "$qsdk_dir/.config" "$config_backup"

packages='sbe-uhttpd2026-candidate
sbe-rpcd2026-candidate
sbe-odhcpd2026-ipv6only-candidate
sbe-ppp254-candidate'

compile_packages=$packages
if [ -n "$diagnostic_package" ]; then
	printf '%s\n' "$packages" | grep -qxF "$diagnostic_package" || \
		fail "unknown diagnostic package: $diagnostic_package"
	compile_packages=$diagnostic_package
fi

cleanup() {
	printf '%s\n' "$packages" | while IFS= read -r package; do
		[ -n "$package" ] || continue
		target=$package_parent/$package
		source=$build_dir/package-overlay/$package
		if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then
			rm -f "$target"
		fi
	done
	if [ -f "$config_backup" ]; then
		cp "$config_backup" "$qsdk_dir/.config"
		rm -f "$config_backup"
	fi
}
trap cleanup EXIT HUP INT TERM

printf '%s\n' "$packages" | while IFS= read -r package; do
	[ -n "$package" ] || continue
	target=$package_parent/$package
	source=$build_dir/package-overlay/$package
	if [ -e "$target" ] && [ ! -L "$target" ]; then
		fail "refusing to replace existing package path: $target"
	fi
	if [ ! -e "$target" ]; then
		ln -s "$source" "$target"
	fi
	[ "$(readlink "$target")" = "$source" ] || \
		fail "$target points somewhere unexpected"
done

# A package-only build uses the minimal 64-bit ipq95xx profile. It never
# invokes world, image, rootfs or kernel-module packaging targets.
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
CONFIG_PACKAGE_sbe-uhttpd2026-candidate=m
CONFIG_PACKAGE_sbe-uhttpd2026-mod-ubus-candidate=m
CONFIG_PACKAGE_sbe-rpcd2026-candidate=m
CONFIG_PACKAGE_sbe-rpcd2026-mod-file-candidate=m
CONFIG_PACKAGE_sbe-rpcd2026-mod-rpcsys-candidate=m
CONFIG_PACKAGE_sbe-rpcd2026-mod-iwinfo-candidate=m
CONFIG_PACKAGE_sbe-odhcpd2026-ipv6only-candidate=m
CONFIG_PACKAGE_sbe-ppp254-candidate=m
CONFIG_PACKAGE_sbe-ppp254-mod-pppoe-candidate=m
EOF
make -C "$qsdk_dir" defconfig

# Dependencies may select public-QSDK kmods. Remove their package selections
# after defconfig: this build consumes only the factory config/headers above.
minimal_config=$(mktemp "${TMPDIR:-/tmp}/sbe-core-userland-minimal.XXXXXX")
awk '!/^CONFIG_PACKAGE_kmod-[^=]*=[ym]$/' "$qsdk_dir/.config" > "$minimal_config"
cp "$minimal_config" "$qsdk_dir/.config"
rm -f "$minimal_config"

mkdir -p "$output"
cp "$qsdk_dir/.config" "$output/CANDIDATE_BUILD_CONFIG"

grep -q '^CONFIG_PACKAGE_libustream-openssl=m$' "$qsdk_dir/.config" || \
	fail 'uhttpd did not select the OpenSSL ustream ABI'
grep -q '^# CONFIG_PACKAGE_libustream-mbedtls is not set$' "$qsdk_dir/.config" || \
	fail 'uhttpd unexpectedly selected mbedTLS'

# Remove only prior artifacts carrying these isolated candidate names. A
# successful run must therefore have rebuilt every copied IPK below.
for pattern in \
	'sbe-uhttpd2026*_*.ipk' \
	'sbe-rpcd2026*_*.ipk' \
	'sbe-odhcpd2026-ipv6only-candidate_*.ipk' \
	'sbe-ppp254*_*.ipk'
do
	find "$qsdk_dir/bin" -type f -name "$pattern" -delete
	find "$output" -maxdepth 1 -type f -name "$pattern" -delete
done

if [ -n "$diagnostic_package" ]; then
	make -C "$qsdk_dir" "package/$diagnostic_package/clean"
else
	make -C "$qsdk_dir" \
		package/sbe-uhttpd2026-candidate/clean \
		package/sbe-rpcd2026-candidate/clean \
		package/sbe-odhcpd2026-ipv6only-candidate/clean \
		package/sbe-ppp254-candidate/clean
fi

printf '%s\n' "$compile_packages" | while IFS= read -r package; do
	[ -n "$package" ] || continue
	make -C "$qsdk_dir" -j"$jobs" NO_DEPS=1 LINUX_DIR="$kernel_build_dir" \
		SBE_STOCK_ABI_SYSROOT="$abi_sysroot" \
		"package/$package/compile" V=s
done

if [ -n "$diagnostic_package" ]; then
	printf 'DIAGNOSTIC ONLY: %s compiled after its package clean.\n' "$diagnostic_package"
	exit 0
fi

expected='sbe-uhttpd2026-candidate_*.ipk
sbe-uhttpd2026-mod-ubus-candidate_*.ipk
sbe-rpcd2026-candidate_*.ipk
sbe-rpcd2026-mod-file-candidate_*.ipk
sbe-rpcd2026-mod-rpcsys-candidate_*.ipk
sbe-rpcd2026-mod-iwinfo-candidate_*.ipk
sbe-odhcpd2026-ipv6only-candidate_*.ipk
sbe-ppp254-candidate_*.ipk
sbe-ppp254-mod-pppoe-candidate_*.ipk'

printf '%s\n' "$expected" | while IFS= read -r pattern; do
	[ -n "$pattern" ] || continue
	artifact=$(find "$qsdk_dir/bin" -type f -name "$pattern" -print | \
		LC_ALL=C sort | tail -n 1)
	[ -n "$artifact" ] || fail "build completed without $pattern"
	cp "$artifact" "$output/"
done

audit_ipk_source "$(find "$output" -maxdepth 1 -name 'sbe-uhttpd2026-candidate_*.ipk' -print -quit)" "$UHTTPD_ARCHIVE"
audit_ipk_source "$(find "$output" -maxdepth 1 -name 'sbe-rpcd2026-candidate_*.ipk' -print -quit)" "$RPCD_ARCHIVE"
audit_ipk_source "$(find "$output" -maxdepth 1 -name 'sbe-odhcpd2026-ipv6only-candidate_*.ipk' -print -quit)" "$ODHCPD_ARCHIVE"
audit_ipk_source "$(find "$output" -maxdepth 1 -name 'sbe-ppp254-candidate_*.ipk' -print -quit)" "$PPP_ARCHIVE"

(cd "$output" && sha256sum ./*.ipk | LC_ALL=C sort -k2) > "$output/PACKAGE_SHA256SUMS"
printf 'BUILT, NOT APPROVED: nine isolated core-userland IPKs are in %s\n' "$output"
printf 'No rootfs/image/device target was invoked; run reproducibility, ABI and RAM gates.\n'
