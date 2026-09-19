#!/bin/sh
set -eu

lab_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$lab_dir/../.." && pwd)
workspace_root=$(CDPATH= cd -- "$repo_root/.." && pwd)
. "$lab_dir/sources.lock"

source_root=${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}
qsdk_dir=$source_root/qsdk
jobs=${QSDK_JOBS:-4}
output=${QSDK_DROPBEAR_OUTPUT:-"$lab_dir/out/dropbear-forwarding"}
package_parent=$qsdk_dir/package/sbe-qsdk-lab
package_name=sbe-dropbear2026-candidate
package_target=$package_parent/$package_name
package_source=$lab_dir/package-overlay/$package_name
runtime_config=
policy_tmp=
package_linked=0

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

cleanup() {
	if [ "$package_linked" -eq 1 ] && [ -L "$package_target" ] &&
		[ "$(readlink "$package_target")" = "$package_source" ]; then
		make -C "$qsdk_dir" "package/$package_name/clean" >/dev/null 2>&1 || true
		rm -f "$package_target"
	fi
	if [ -n "$runtime_config" ] && [ -f "$runtime_config" ]; then
		cp "$runtime_config" "$qsdk_dir/.config"
		rm -f "$runtime_config"
	fi
	[ -z "$policy_tmp" ] || rm -f "$policy_tmp"
}
trap cleanup EXIT HUP INT TERM

[ "$(uname -s)" = Linux ] || fail 'Dropbear candidate must be built inside Linux'
[ -d "$qsdk_dir" ] || fail "QSDK tree is missing: $qsdk_dir"
[ -f "$qsdk_dir/.config" ] || fail 'run prepare-qsdk-toolchain.sh first'
[ -f "$package_source/Makefile" ] || fail 'Dropbear candidate recipe is missing'
[ ! -e "$output" ] || fail "refusing non-fresh output directory: $output"

QSDK_SOURCE_ROOT=$source_root "$lab_dir/verify-sources.sh"

mkdir -p "$package_parent"
[ ! -e "$package_target" ] && [ ! -L "$package_target" ] || \
	fail "QSDK package path is already occupied: $package_target"
ln -s "$package_source" "$package_target"
package_linked=1

runtime_config=$(mktemp "${TMPDIR:-/tmp}/sbe-dropbear-config.XXXXXX")
cp "$qsdk_dir/.config" "$runtime_config"

cat > "$qsdk_dir/.config" <<'EOF'
CONFIG_TARGET_ipq95xx=y
CONFIG_TARGET_ipq95xx_generic=y
CONFIG_TARGET_ipq95xx_generic_Default=y
CONFIG_DEVEL=y
CONFIG_TOOLCHAINOPTS=y
CONFIG_BINUTILS_USE_VERSION_2_31_1=y
CONFIG_GCC_USE_VERSION_7=y
CONFIG_LIBC_USE_MUSL=y
CONFIG_PKG_CHECK_FORMAT_SECURITY=y
CONFIG_PKG_ASLR_PIE=y
CONFIG_PKG_CC_STACKPROTECTOR_STRONG=y
CONFIG_PKG_FORTIFY_SOURCE_2=y
CONFIG_PKG_RELRO_FULL=y
CONFIG_PACKAGE_sbe-dropbear2026-candidate=m
EOF
make -C "$qsdk_dir" defconfig

mkdir -p "$output"
cp "$qsdk_dir/.config" "$output/CANDIDATE_BUILD_CONFIG"

make -C "$qsdk_dir" "package/$package_name/clean"
make -C "$qsdk_dir" -j"$jobs" "package/$package_name/compile" V=s

ipk=$(find "$qsdk_dir/bin" -type f \
	-name 'sbe-dropbear2026-candidate_2026.94-3_*.ipk' -print | sort)
[ "$(printf '%s\n' "$ipk" | sed '/^$/d' | wc -l | tr -d ' ')" = 1 ] || \
	fail 'expected exactly one release-3 Dropbear IPK in the QSDK output tree'
cp "$ipk" "$output/"
ipk=$output/$(basename "$ipk")

control=$(tar -xOzf "$ipk" ./control.tar.gz | tar -xOzf - ./control) || \
	fail 'cannot extract Dropbear control metadata'
source_field=$(printf '%s\n' "$control" | sed -n 's/^Source: //p')
[ "$source_field" = "dropbear-$DROPBEAR_VERSION.tar.bz2" ] || \
	fail "unexpected Dropbear Source metadata: $source_field"

dropbear_source=$(find "$qsdk_dir/build_dir" -maxdepth 2 -type d \
	-name "dropbear-$DROPBEAR_VERSION" -print | sort | tail -n 1)
[ -n "$dropbear_source" ] || fail 'Dropbear build source directory is missing'
target_cc=$(find "$qsdk_dir/staging_dir" -type f \
	-name aarch64-openwrt-linux-musl-gcc -perm -0100 -print | sort | head -n 1)
[ -n "$target_cc" ] || fail 'locked QSDK AArch64 compiler is missing'
policy_tmp=$(mktemp "${TMPDIR:-/tmp}/sbe-dropbear-policy.XXXXXX")
printf '#include "options.h"\n' | "$target_cc" -dM -E -x c \
	-DLOCALOPTIONS_H_EXISTS=1 -I"$dropbear_source" \
	-I"$dropbear_source/src" - > "$policy_tmp"
: > "$output/DROPBEAR_COMPILE_POLICY"
for setting in \
	DROPBEAR_SVR_PASSWORD_AUTH=1 \
	DROPBEAR_SVR_PAM_AUTH=0 \
	DROPBEAR_SVR_PUBKEY_AUTH=1 \
	DROPBEAR_SVR_LOCALTCPFWD=1 \
	DROPBEAR_SVR_REMOTETCPFWD=1 \
	DROPBEAR_SVR_LOCALSTREAMFWD=1 \
	DROPBEAR_SVR_REMOTESTREAMFWD=1 \
	DROPBEAR_SVR_AGENTFWD=1 \
	DROPBEAR_X11FWD=1 \
	DROPBEAR_USE_PASSWORD_ENV=0 \
	DROPBEAR_DSS=0 \
	DROPBEAR_RSA_SHA1=0 \
	DROPBEAR_ENABLE_CBC_MODE=0 \
	DROPBEAR_SHA1_HMAC=0 \
	DROPBEAR_SHA1_96_HMAC=0
do
	macro=${setting%%=*}
	expected=${setting#*=}
	actual=$(awk -v macro="$macro" \
		'$1 == "#define" && $2 == macro { print $3 }' "$policy_tmp")
	[ "$actual" = "$expected" ] || \
		fail "$macro compiled as $actual instead of $expected"
	printf '%s=%s\n' "$macro" "$actual" >> "$output/DROPBEAR_COMPILE_POLICY"
done

"$lab_dir/audit-dropbear-source-policy.sh" \
	"$dropbear_source" "$output/DROPBEAR_COMPILE_POLICY"
python3 "$lab_dir/audit-dropbear-ipk.py" "$ipk"

printf 'BUILT: release-3 Dropbear forwarding candidate in %s\n' "$output"
