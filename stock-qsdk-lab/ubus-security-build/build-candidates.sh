#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$build_dir/../.." && pwd)
workspace_parent=$(CDPATH= cd -- "$repo_root/.." && pwd)
. "$build_dir/sources.lock"

source_root=${1:-${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}}
qsdk_dir=$source_root/qsdk
jobs=${QSDK_JOBS:-4}
output=${UBUS_SECURITY_OUTPUT:-"$build_dir/candidate-out/ubus-security"}
target_build_root=$qsdk_dir/build_dir/target-aarch64_cortex-a73+neon-vfpv4_musl
ubus_build_tree=$target_build_root/ubus-2022-02-21-b32a0e17
build_log=$output/BUILD.log

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

[ "$(uname -s)" = Linux ] || fail 'ubus candidates must be built inside Linux'
[ -f "$qsdk_dir/Makefile" ] || fail "complete QSDK tree is missing: $qsdk_dir"
[ -f "$qsdk_dir/.config" ] || fail 'locked QSDK .config is missing'
"$build_dir/verify-sources.sh"

archive_source=$build_dir/distfiles/$UBUS_ARCHIVE
archive_target=$qsdk_dir/dl/$UBUS_ARCHIVE
if [ -f "$archive_target" ]; then
	[ "$(sha256_file "$archive_target")" = "$UBUS_ARCHIVE_SHA256" ] || \
		fail "QSDK distfile exists with the wrong hash: $archive_target"
else
	cp "$archive_source" "$archive_target"
fi

package_name=sbe-ubus2022-security-candidate
package_parent=$qsdk_dir/package/sbe-qsdk-lab
package_target=$package_parent/$package_name
package_source=$build_dir/package-overlay/$package_name
mkdir -p "$package_parent" "$output"
rm -f "$output/ARTIFACT-AUDIT.txt" "$output/REPRODUCIBILITY.txt" \
	"$output/PACKAGE_SHA256SUMS" "$build_log"
config_backup=$(mktemp "${TMPDIR:-/tmp}/sbe-ubus-config.XXXXXX")
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
CONFIG_PACKAGE_sbe-ubus2022-security-candidate=m
CONFIG_PACKAGE_sbe-ubusd2022-security-candidate=m
CONFIG_PACKAGE_sbe-libubus20210603-security-candidate=m
CONFIG_PACKAGE_sbe-libubus-lua2022-comparison-only=m
EOF
make -C "$qsdk_dir" defconfig

minimal_config=$(mktemp "${TMPDIR:-/tmp}/sbe-ubus-minimal.XXXXXX")
awk '!/^CONFIG_PACKAGE_kmod-[^=]*=[ym]$/' "$qsdk_dir/.config" > "$minimal_config"
cp "$minimal_config" "$qsdk_dir/.config"
rm -f "$minimal_config"
cp "$qsdk_dir/.config" "$output/CANDIDATE_BUILD_CONFIG"

for pattern in \
	'sbe-ubus2022-security-candidate_*.ipk' \
	'sbe-ubusd2022-security-candidate_*.ipk' \
	'sbe-libubus20210603-security-candidate_*.ipk' \
	'sbe-libubus-lua2022-comparison-only_*.ipk' \
	'sbe-libubus-lua2022-security-candidate_*.ipk'
do
	find "$qsdk_dir/bin" -type f -name "$pattern" -delete
	find "$output" -maxdepth 1 -type f -name "$pattern" -delete
done

make -C "$qsdk_dir" NO_DEPS=1 "package/$package_name/clean" >"$build_log" 2>&1
case "$ubus_build_tree" in "$target_build_root"/*) ;;
	*) fail "unsafe generated build-tree purge target: $ubus_build_tree" ;;
esac
[ "${ubus_build_tree##*/}" = ubus-2022-02-21-b32a0e17 ] ||
	fail "unexpected generated ubus build-tree basename"
rm -rf -- "$ubus_build_tree"
[ ! -e "$ubus_build_tree" ] || fail 'failed to purge generated ubus build tree'
if ! make -C "$qsdk_dir" -j"$jobs" NO_DEPS=1 \
	"package/$package_name/compile" V=s >>"$build_log" 2>&1; then
	tail -n 180 "$build_log" >&2
	fail 'package-only ubus compile failed'
fi
[ -d "$ubus_build_tree" ] || fail 'clean source was not reconstructed from the locked archive'

while read -r relative expected_sha; do
	[ -n "$relative" ] || continue
	[ "$(sha256_file "$ubus_build_tree/$relative")" = "$expected_sha" ] ||
		fail "compiled source differs from the reviewed patch result: $relative"
done <<EOF
libubus.c $UBUS_PATCHED_LIBUBUS_SHA256
libubus-io.c $UBUS_PATCHED_LIBUBUS_IO_SHA256
libubus-req.c $UBUS_PATCHED_LIBUBUS_REQ_SHA256
libubus-acl.c $UBUS_PATCHED_LIBUBUS_ACL_SHA256
ubusd.c $UBUS_PATCHED_DAEMON_SHA256
ubusd.h $UBUS_PATCHED_DAEMON_HEADER_SHA256
ubusd_acl.c $UBUS_PATCHED_ACL_SHA256
ubusd_event.c $UBUS_PATCHED_EVENT_SHA256
ubusd_main.c $UBUS_PATCHED_MAIN_SHA256
ubusd_monitor.c $UBUS_PATCHED_MONITOR_SHA256
ubusd_obj.c $UBUS_PATCHED_OBJ_SHA256
ubusd_proto.c $UBUS_PATCHED_PROTO_SHA256
EOF

if grep -Eq \
	'make\[[0-9]+\].*(package/kernel|target/linux)|-C .*/linux-5\.4\.213|package/(kernel|network/config/wifi-scripts/mac80211).*/compile|qca/.*/compile' \
	"$build_log"; then
	fail 'package-only build log shows a forbidden kernel/QCA/wireless target'
fi

expected='sbe-ubus2022-security-candidate_*.ipk
sbe-ubusd2022-security-candidate_*.ipk
sbe-libubus20210603-security-candidate_*.ipk
sbe-libubus-lua2022-comparison-only_*.ipk'
printf '%s\n' "$expected" | while IFS= read -r pattern; do
	[ -n "$pattern" ] || continue
	artifact_count=$(find "$qsdk_dir/bin" -type f -name "$pattern" -print | \
		wc -l | tr -d ' ')
	[ "$artifact_count" -eq 1 ] ||
		fail "build must emit exactly one $pattern artifact, found $artifact_count"
	artifact=$(find "$qsdk_dir/bin" -type f -name "$pattern" -print | \
		LC_ALL=C sort | tail -n 1)
	cp "$artifact" "$output/"
done

ipk_count=$(find "$output" -maxdepth 1 -type f -name '*.ipk' -print | \
	wc -l | tr -d ' ')
[ "$ipk_count" -eq 4 ] || fail "candidate output must contain exactly four IPKs, found $ipk_count"
for ipk in "$output"/*.ipk; do
	control=$(tar -xOzf "$ipk" ./control.tar.gz | tar -xOzf - ./control) || \
		fail "cannot extract control metadata from $ipk"
	actual_source=$(printf '%s\n' "$control" | sed -n 's/^Source: //p')
	[ "$actual_source" = "$UBUS_ARCHIVE" ] || \
		fail "$ipk has unexpected Source metadata: $actual_source"
	case "$control" in
		*'/repo/'*|*'/workspace/'*|*'/Users/'*|*'/Volumes/'*|*'/home/'*|*'/private/tmp/'*|*'BEGIN '*'PRIVATE KEY'*|*'OPENSSH PRIVATE KEY'*)
			fail "$ipk control metadata leaks a host path or private key"
			;;
	esac
done

(cd "$output" && sha256sum ./*.ipk | LC_ALL=C sort -k2) > \
	"$output/PACKAGE_SHA256SUMS"
"$build_dir/audit-artifacts.sh" "$output"
printf 'BUILT, NOT APPROVED: four audited ubus security IPKs are in %s\n' "$output"
printf 'The three native artifacts are an atomic candidate; this directory\047s Lua binding is comparison-only.\n'
printf 'No rootfs, image, kernel or device target was invoked.\n'
