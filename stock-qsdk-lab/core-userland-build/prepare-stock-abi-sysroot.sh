#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$build_dir/../.." && pwd)
. "$build_dir/sources.lock"

destination=${1:-"$build_dir/work/stock-abi-sysroot"}
stock_squashfs=${STOCK_P27_SQUASHFS:-"$repo_root/stock-qsdk-lab/cache/stock-1.5.3/stock-rootfs-p27.img"}
iwinfo_ipk=${STOCK_IWINFO_IPK:-"$repo_root/stock-qsdk-lab/cache/ipk/libiwinfo20181126_2019-10-16-07315b6f-1_aarch64_generic.ipk"}

export LC_ALL=C
export TZ=UTC

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

sha256_file() {
	sha256sum "$1" | awk '{print $1}'
}

case "$destination" in
	"$build_dir"/work/*) ;;
	*) fail "ABI sysroot destination must remain below $build_dir/work" ;;
esac

command -v unsquashfs >/dev/null 2>&1 || fail 'unsquashfs is required to read the stock p27 image'
[ -f "$stock_squashfs" ] || fail "stock p27 squashfs is missing: $stock_squashfs"
# Authenticate the link-only library below, not a privately assembled rootfs.
# The release entry also authenticates the complete downloaded vendor image.
stock_image_sha=$(sha256_file "$stock_squashfs")
[ -f "$iwinfo_ipk" ] || fail "factory libiwinfo IPK is missing: $iwinfo_ipk"
[ "$(sha256_file "$iwinfo_ipk")" = "$STOCK_IWINFO_IPK_SHA256" ] || \
	fail 'factory libiwinfo IPK hash differs from the lock'

"$build_dir/verify-sources.sh"

mkdir -p "$build_dir/work"
tmp=$(mktemp -d "$build_dir/work/.stock-abi-sysroot.XXXXXX")
cleanup() {
	case "$tmp" in
		"$build_dir"/work/.stock-abi-sysroot.*) rm -rf "$tmp" ;;
	esac
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$tmp/lib" "$tmp/usr/lib" "$tmp/usr/include/libubox" "$tmp/usr/include/iwinfo"
git -c "safe.directory=$build_dir/sources/ustream-ssl" \
	-C "$build_dir/sources/ustream-ssl" show \
	"$USTREAM_COMMIT:ustream-ssl.h" > "$tmp/usr/include/libubox/ustream-ssl.h"
git -c "safe.directory=$build_dir/sources/iwinfo" \
	-C "$build_dir/sources/iwinfo" show \
	"$IWINFO_COMMIT:include/iwinfo.h" > "$tmp/usr/include/iwinfo.h"
for header in lua.h utils.h; do
	git -c "safe.directory=$build_dir/sources/iwinfo" \
		-C "$build_dir/sources/iwinfo" show \
		"$IWINFO_COMMIT:include/iwinfo/$header" > "$tmp/usr/include/iwinfo/$header"
done

unsquashfs -cat "$stock_squashfs" lib/libustream-ssl.so > "$tmp/lib/libustream-ssl.so"
tar -xOzf "$iwinfo_ipk" ./data.tar.gz | \
	tar -xzOf - ./usr/lib/libiwinfo.so > "$tmp/usr/lib/libiwinfo.so"

[ "$(sha256_file "$tmp/lib/libustream-ssl.so")" = "$STOCK_USTREAM_SSL_SHA256" ] || \
	fail 'extracted stock libustream-ssl differs from the lock'
[ "$(sha256_file "$tmp/usr/lib/libiwinfo.so")" = "$STOCK_IWINFO_SO_SHA256" ] || \
	fail 'extracted factory libiwinfo differs from the lock'

{
	printf 'factory ABI link-only sysroot; never install as a package\n'
	printf 'stock_p27_squashfs_sha256=%s\n' "$stock_image_sha"
	printf 'libustream_ssl_sha256=%s\n' "$STOCK_USTREAM_SSL_SHA256"
	printf 'ustream_header_commit=%s\n' "$USTREAM_COMMIT"
	printf 'libiwinfo_ipk_sha256=%s\n' "$STOCK_IWINFO_IPK_SHA256"
	printf 'libiwinfo_so_sha256=%s\n' "$STOCK_IWINFO_SO_SHA256"
	printf 'iwinfo_header_commit=%s\n' "$IWINFO_COMMIT"
} > "$tmp/MANIFEST"

if [ -e "$destination" ]; then
	rm -rf "$destination"
fi
mv "$tmp" "$destination"
trap - EXIT HUP INT TERM
printf 'Prepared locked factory ABI sysroot at %s\n' "$destination"
