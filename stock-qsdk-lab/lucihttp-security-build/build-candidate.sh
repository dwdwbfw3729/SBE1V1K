#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$build_dir/../.." && pwd)
workspace_parent=$(CDPATH= cd -- "$repo_root/.." && pwd)
. "$build_dir/sources.lock"

source_root=${1:-${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}}
qsdk_dir=$source_root/qsdk
jobs=${QSDK_JOBS:-4}
output=${LUCIHTTP_SECURITY_OUTPUT:-"$build_dir/candidate-out/lucihttp-security"}

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

[ "$(uname -s)" = Linux ] || fail 'lucihttp candidate must be built inside Linux'
[ -f "$qsdk_dir/Makefile" ] || fail "complete QSDK tree is missing: $qsdk_dir"
[ -f "$qsdk_dir/.config" ] || fail 'locked QSDK .config is missing'
"$build_dir/verify-sources.sh"

archive_source=$build_dir/distfiles/$LUCIHTTP_ARCHIVE
archive_target=$qsdk_dir/dl/$LUCIHTTP_ARCHIVE
if [ -f "$archive_target" ]; then
	[ "$(sha256_file "$archive_target")" = "$LUCIHTTP_ARCHIVE_SHA256" ] || \
		fail "QSDK distfile exists with the wrong hash: $archive_target"
else
	cp "$archive_source" "$archive_target"
fi

package_dir=sbe-lucihttp2023-security-candidate
package_parent=$qsdk_dir/package/sbe-qsdk-lab
package_target=$package_parent/$package_dir
package_source=$build_dir/package-overlay/$package_dir
mkdir -p "$package_parent" "$output"
config_backup=$(mktemp "${TMPDIR:-/tmp}/sbe-lucihttp-config.XXXXXX")
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
CONFIG_PACKAGE_sbe-liblucihttp2023-abi0-candidate=m
CONFIG_PACKAGE_sbe-liblucihttp-lua2023-abi0-candidate=m
EOF
make -C "$qsdk_dir" defconfig

minimal_config=$(mktemp "${TMPDIR:-/tmp}/sbe-lucihttp-minimal.XXXXXX")
awk '!/^CONFIG_PACKAGE_kmod-[^=]*=[ym]$/' "$qsdk_dir/.config" > "$minimal_config"
cp "$minimal_config" "$qsdk_dir/.config"
rm -f "$minimal_config"
cp "$qsdk_dir/.config" "$output/CANDIDATE_BUILD_CONFIG"

for pattern in \
	'sbe-liblucihttp2023-abi0-candidate_*.ipk' \
	'sbe-liblucihttp-lua2023-abi0-candidate_*.ipk'
do
	find "$qsdk_dir/bin" -type f -name "$pattern" -delete
	find "$output" -maxdepth 1 -type f -name "$pattern" -delete
done

make -C "$qsdk_dir" "package/$package_dir/clean"
make -C "$qsdk_dir" -j"$jobs" NO_DEPS=1 "package/$package_dir/compile" V=s

for pattern in \
	'sbe-liblucihttp2023-abi0-candidate_*.ipk' \
	'sbe-liblucihttp-lua2023-abi0-candidate_*.ipk'
do
	artifact=$(find "$qsdk_dir/bin" -type f -name "$pattern" -print | \
		LC_ALL=C sort | tail -n 1)
	[ -n "$artifact" ] || fail "build completed without $pattern"
	cp "$artifact" "$output/"
done

core_ipk=$(find "$output" -maxdepth 1 -name 'sbe-liblucihttp2023-abi0-candidate_*.ipk' -print -quit)
lua_ipk=$(find "$output" -maxdepth 1 -name 'sbe-liblucihttp-lua2023-abi0-candidate_*.ipk' -print -quit)
for ipk in "$core_ipk" "$lua_ipk"; do
	control=$(tar -xOzf "$ipk" ./control.tar.gz | tar -xOzf - ./control) || \
		fail "cannot extract candidate control metadata: $ipk"
	actual_source=$(printf '%s\n' "$control" | sed -n 's/^Source: //p')
	[ "$actual_source" = "$LUCIHTTP_ARCHIVE" ] || \
		fail "$ipk has unexpected Source metadata: $actual_source"
	case "$control" in
		*'/workspace/'*|*'/Users/'*|*'/home/'*|*'/private/tmp/'*|*'BEGIN '*'PRIVATE KEY'*)
			fail "$ipk control metadata leaks a host path or private key"
			;;
	esac
done

audit_root=$(mktemp -d "${TMPDIR:-/tmp}/sbe-lucihttp-abi.XXXXXX")
rm_audit_root() {
	rm -rf "$audit_root"
}
trap 'rm_audit_root; cleanup' EXIT HUP INT TERM
mkdir -p "$audit_root/stock" "$audit_root/candidate"

stock_core_ipk=$(find "$repo_root/stock-qsdk-lab/cache/ipk" -maxdepth 1 \
	-name 'liblucihttp0_2019-07-05-a34a17d5-1_*.ipk' -print -quit)
stock_lua_ipk=$(find "$repo_root/stock-qsdk-lab/cache/ipk" -maxdepth 1 \
	-name 'liblucihttp-lua_2019-07-05-a34a17d5-1_*.ipk' -print -quit)
[ -n "$stock_core_ipk" ] && [ -n "$stock_lua_ipk" ] || \
	fail 'locked stock lucihttp comparison packages are missing'

tar -xOzf "$stock_core_ipk" ./data.tar.gz | tar -xzf - -C "$audit_root/stock"
tar -xOzf "$stock_lua_ipk" ./data.tar.gz | tar -xzf - -C "$audit_root/stock"
tar -xOzf "$core_ipk" ./data.tar.gz | tar -xzf - -C "$audit_root/candidate"
tar -xOzf "$lua_ipk" ./data.tar.gz | tar -xzf - -C "$audit_root/candidate"

[ "$(readlink "$audit_root/candidate/usr/lib/liblucihttp.so.0")" = 'liblucihttp.so.0.1' ] || \
	fail 'candidate ABI-0 symlink target changed'
candidate_paths=$(find "$audit_root/candidate" \( -type f -o -type l \) -print | \
	sed "s#^$audit_root/candidate##" | LC_ALL=C sort)
expected_paths='/usr/lib/liblucihttp.so.0
/usr/lib/liblucihttp.so.0.1
/usr/lib/lua/lucihttp.so'
[ "$candidate_paths" = "$expected_paths" ] || \
	fail "candidate payload escaped the allowlist: $candidate_paths"

python3 "$build_dir/audit-abi.py" \
	--elf-audit-dir "$repo_root/stock-qsdk-lab/tools" \
	--stock-core "$audit_root/stock/usr/lib/liblucihttp.so.0.1" \
	--stock-lua "$audit_root/stock/usr/lib/lua/lucihttp.so" \
	--candidate-core "$audit_root/candidate/usr/lib/liblucihttp.so.0.1" \
	--candidate-lua "$audit_root/candidate/usr/lib/lua/lucihttp.so"

readelf=$(find "$qsdk_dir/staging_dir" -type f \
	-name 'aarch64-openwrt-linux-musl-readelf' -print | LC_ALL=C sort | head -n 1)
[ -n "$readelf" ] || fail 'QSDK AArch64 readelf is missing'
for elf in \
	"$audit_root/candidate/usr/lib/liblucihttp.so.0.1" \
	"$audit_root/candidate/usr/lib/lua/lucihttp.so"
do
	"$readelf" -h "$elf" | grep -q 'Machine:.*AArch64' || \
		fail "$elf is not AArch64"
	"$readelf" -lW "$elf" | grep -q 'GNU_RELRO' || \
		fail "$elf lacks GNU_RELRO"
	"$readelf" -dW "$elf" | grep -Eq 'BIND_NOW|FLAGS.*NOW' || \
		fail "$elf lacks immediate binding"
	"$readelf" -lW "$elf" | grep 'GNU_STACK' | grep -qv 'RWE' || \
		fail "$elf has an executable stack"
done

(cd "$output" && sha256sum ./*.ipk | LC_ALL=C sort -k2) > "$output/PACKAGE_SHA256SUMS"
printf 'BUILT, NOT APPROVED: lucihttp ABI-0/Lua candidate pair is in %s\n' "$output"
printf 'No rootfs, image, kernel or device target was invoked.\n'
