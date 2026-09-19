#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$build_dir/../.." && pwd)
workspace_parent=$(CDPATH= cd -- "$repo_root/.." && pwd)
. "$build_dir/sources.lock"

source_root=${1:-${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}}
qsdk_dir=$source_root/qsdk
jobs=${QSDK_JOBS:-4}
output=${CGI_IO_SECURITY_OUTPUT:-"$build_dir/candidate-out/cgi-io-security"}

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

[ "$(uname -s)" = Linux ] || fail 'cgi-io candidate must be built inside Linux'
[ -f "$qsdk_dir/Makefile" ] || fail "complete QSDK tree is missing: $qsdk_dir"
[ -f "$qsdk_dir/.config" ] || fail 'locked QSDK .config is missing'
"$build_dir/verify-sources.sh"

archive_source=$build_dir/distfiles/$CGI_IO_ARCHIVE
archive_target=$qsdk_dir/dl/$CGI_IO_ARCHIVE
if [ -f "$archive_target" ]; then
	[ "$(sha256_file "$archive_target")" = "$CGI_IO_ARCHIVE_SHA256" ] || \
		fail "QSDK distfile exists with the wrong hash: $archive_target"
else
	cp "$archive_source" "$archive_target"
fi

package_name=sbe-cgi-io2026-security-candidate
package_parent=$qsdk_dir/package/sbe-qsdk-lab
package_target=$package_parent/$package_name
package_source=$build_dir/package-overlay/$package_name
mkdir -p "$package_parent" "$output"
config_backup=$(mktemp "${TMPDIR:-/tmp}/sbe-cgi-io-config.XXXXXX")
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

if [ -e "$package_target" ] && [ ! -L "$package_target" ]; then
	fail "refusing to replace existing package path: $package_target"
fi
if [ ! -e "$package_target" ]; then
	ln -s "$package_source" "$package_target"
fi
[ "$(readlink "$package_target")" = "$package_source" ] || \
	fail "$package_target points somewhere unexpected"

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
CONFIG_PACKAGE_sbe-cgi-io2026-security-candidate=m
EOF
make -C "$qsdk_dir" defconfig

minimal_config=$(mktemp "${TMPDIR:-/tmp}/sbe-cgi-io-minimal.XXXXXX")
awk '!/^CONFIG_PACKAGE_kmod-[^=]*=[ym]$/' "$qsdk_dir/.config" > "$minimal_config"
cp "$minimal_config" "$qsdk_dir/.config"
rm -f "$minimal_config"
cp "$qsdk_dir/.config" "$output/CANDIDATE_BUILD_CONFIG"

find "$qsdk_dir/bin" -type f \
	-name 'sbe-cgi-io2026-security-candidate_*.ipk' -delete
find "$output" -maxdepth 1 -type f \
	-name 'sbe-cgi-io2026-security-candidate_*.ipk' -delete
make -C "$qsdk_dir" "package/$package_name/clean"
make -C "$qsdk_dir" -j"$jobs" NO_DEPS=1 "package/$package_name/compile" V=s

artifact=$(find "$qsdk_dir/bin" -type f \
	-name 'sbe-cgi-io2026-security-candidate_*.ipk' -print | \
	LC_ALL=C sort | tail -n 1)
[ -n "$artifact" ] || fail 'build completed without the cgi-io candidate IPK'
cp "$artifact" "$output/"
artifact=$output/$(basename "$artifact")

control=$(tar -xOzf "$artifact" ./control.tar.gz | tar -xOzf - ./control) || \
	fail 'cannot extract candidate control metadata'
actual_source=$(printf '%s\n' "$control" | sed -n 's/^Source: //p')
[ "$actual_source" = "$CGI_IO_ARCHIVE" ] || \
	fail "candidate has unexpected Source metadata: $actual_source"
case "$control" in
	*'/workspace/'*|*'/Users/'*|*'/home/'*|*'/private/tmp/'*|*'BEGIN '*'PRIVATE KEY'*)
		fail 'candidate control metadata leaks a host path or private key'
		;;
esac

(cd "$output" && sha256sum "./$(basename "$artifact")") > \
	"$output/PACKAGE_SHA256SUMS"
printf 'BUILT, NOT APPROVED: cgi-io security IPK is in %s\n' "$output"
printf 'No rootfs, image, kernel or device target was invoked.\n'
