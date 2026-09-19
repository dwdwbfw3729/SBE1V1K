#!/bin/sh
set -eu

lab_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$lab_dir/../.." && pwd)
workspace_root=$(CDPATH= cd -- "$repo_root/.." && pwd)
. "$lab_dir/sources.lock"

source_root=${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}
qsdk_dir=$source_root/qsdk
jobs=${QSDK_JOBS:-4}
output=${QSDK_USERLAND_OUTPUT:-"$lab_dir/out/userland-candidates"}
backup=${QSDK_CONFIG_BACKUP:-"$lab_dir/work/qsdk-config-before-userland"}
kernel_build_dir=${QSDK_KERNEL_BUILD_DIR:-"$source_root/candidate-work/kernel-stock-passwall"}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
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
	case "$actual" in
		/*|*'/workspace/'*|*'/Users/'*|*'/home/'*|*'/private/tmp/'*)
			fail "$ipk leaks an absolute build path in Source metadata"
			;;
	esac
}

[ "$(uname -s)" = Linux ] || fail 'userland candidates must be built inside Linux'
QSDK_SOURCE_ROOT=$source_root "$lab_dir/verify-sources.sh"
[ -f "$qsdk_dir/.config" ] || fail 'run prepare-qsdk-toolchain.sh first'
grep -q '^CONFIG_TARGET_ipq95xx=y$' "$qsdk_dir/.config" || fail 'QSDK target is not ipq95xx'
grep -q '^CONFIG_TARGET_ipq95xx_generic=y$' "$qsdk_dir/.config" || fail 'QSDK subtarget is not generic/64-bit'
[ -f "$kernel_build_dir/.config" ] || fail "candidate kernel config is missing: $kernel_build_dir/.config"
[ -f "$kernel_build_dir/modules.builtin" ] || fail "candidate modules.builtin is missing: $kernel_build_dir/modules.builtin"
[ -d "$kernel_build_dir/user_headers/include" ] || fail "candidate kernel user headers are missing: $kernel_build_dir/user_headers/include"
grep -q '^# CONFIG_LOCALVERSION_AUTO is not set$' "$kernel_build_dir/.config" || \
	fail 'candidate kernel config has an unexpected LOCALVERSION_AUTO policy'

package_parent=$qsdk_dir/package/sbe-qsdk-lab
mkdir -p "$package_parent"
runtime_backup=$(mktemp "${TMPDIR:-/tmp}/sbe-qsdk-config.XXXXXX")
policy_tmp=
cp "$qsdk_dir/.config" "$runtime_backup"
cleanup() {
	for package in sbe-dnsmasq293-candidate sbe-dropbear2026-candidate; do
		target=$package_parent/$package
		source=$lab_dir/package-overlay/$package
		if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then
			rm -f "$target"
		fi
	done
	if [ -f "$runtime_backup" ]; then
		cp "$runtime_backup" "$qsdk_dir/.config"
		rm -f "$runtime_backup"
	fi
	[ -z "$policy_tmp" ] || rm -f "$policy_tmp"
}
trap cleanup EXIT HUP INT TERM

for package in sbe-dnsmasq293-candidate sbe-dropbear2026-candidate; do
	target=$package_parent/$package
	source=$lab_dir/package-overlay/$package
	if [ -e "$target" ] && [ ! -L "$target" ]; then
		fail "refusing to replace existing package path: $target"
	fi
	if [ ! -e "$target" ]; then
		ln -s "$source" "$target"
	fi
	[ "$(readlink "$target")" = "$source" ] || fail "$target points somewhere unexpected"
done

mkdir -p "$(dirname -- "$backup")"
[ -e "$backup" ] || cp "$qsdk_dir/.config" "$backup"

# The Premium profile selects hundreds of unrelated kernel packages.  A
# package-only candidate build must use the minimum ipq95xx profile or a
# request for iptables can try to package every Premium module.  The original
# release config is restored by the trap above.
{
	printf '%s\n' \
		'CONFIG_TARGET_ipq95xx=y' \
		'CONFIG_TARGET_ipq95xx_generic=y' \
		'CONFIG_TARGET_ipq95xx_generic_Default=y' \
		'CONFIG_DEVEL=y' \
		'CONFIG_TOOLCHAINOPTS=y' \
		'CONFIG_BINUTILS_USE_VERSION_2_31_1=y' \
		'CONFIG_GCC_USE_VERSION_7=y' \
		'CONFIG_LIBC_USE_MUSL=y' \
		'CONFIG_PKG_CHECK_FORMAT_SECURITY=y' \
		'CONFIG_PKG_ASLR_PIE=y' \
		'CONFIG_PKG_CC_STACKPROTECTOR_STRONG=y' \
		'CONFIG_PKG_FORTIFY_SOURCE_2=y' \
		'CONFIG_PKG_RELRO_FULL=y'
	cat "$lab_dir/passwall-userland.config"
} > "$qsdk_dir/.config"
make -C "$qsdk_dir" defconfig

# Kernel binaries are built separately from the factory config.  Suppress all
# OpenWrt kmod packaging after dependency resolution; emitted userland IPKs
# keep their runtime dependency metadata, while no public-QSDK kmod IPK can be
# mistaken for a factory-compatible artifact.
minimal_config=$(mktemp "${TMPDIR:-/tmp}/sbe-qsdk-minimal.XXXXXX")
awk '!/^CONFIG_PACKAGE_kmod-[^=]*=[ym]$/' "$qsdk_dir/.config" > "$minimal_config"
cp "$minimal_config" "$qsdk_dir/.config"
rm -f "$minimal_config"
mkdir -p "$output"
cp "$qsdk_dir/.config" "$output/CANDIDATE_BUILD_CONFIG"

# Rebuild all three candidate sources from their locked archives on every run.
# Shared toolchain/dependency staging remains cached, while stale configure or
# unstripped package output cannot silently satisfy a reproducibility check.
make -C "$qsdk_dir" \
	package/network/utils/iptables/clean \
	package/sbe-dnsmasq293-candidate/clean \
	package/sbe-dropbear2026-candidate/clean

# The iptables build supplies only the 1.8.3 xtables plugin candidates.  Any
# kmod IPKs emitted transitively are quarantined and must never be installed.
make -C "$qsdk_dir" -j"$jobs" LINUX_DIR="$kernel_build_dir" \
	package/network/utils/iptables/compile V=s
make -C "$qsdk_dir" -j"$jobs" LINUX_DIR="$kernel_build_dir" \
	package/sbe-dnsmasq293-candidate/compile V=s
make -C "$qsdk_dir" -j"$jobs" LINUX_DIR="$kernel_build_dir" \
	package/sbe-dropbear2026-candidate/compile V=s

mkdir -p "$output/xtables"
strip_tool=
for candidate in \
	"$qsdk_dir"/staging_dir/toolchain-*/bin/aarch64-openwrt-linux-musl-strip
do
	[ -x "$candidate" ] || continue
	strip_tool=$candidate
	break
done
[ -n "$strip_tool" ] || fail 'locked QSDK AArch64 strip tool is missing'
for plugin in libxt_socket.so libxt_TPROXY.so libxt_iprange.so; do
	path=$(find "$qsdk_dir/build_dir" -type f -path '*/iptables-1.8.3/extensions/*' \
		-name "$plugin" -print -quit)
	[ -n "$path" ] || fail "iptables build did not produce $plugin"
	cp "$path" "$output/xtables/$plugin"
	# The raw extensions retain DWARF paths from the musl CRT objects.  Strip
	# only non-runtime sections with the same locked target toolchain before
	# they leave the candidate build directory.
	"$strip_tool" --strip-unneeded "$output/xtables/$plugin"
done
find "$qsdk_dir/bin" -type f \( \
	-name 'sbe-dnsmasq293-candidate_*.ipk' -o \
	-name 'sbe-dropbear2026-candidate_*.ipk' \) \
	-exec cp '{}' "$output/" ';'

# Prove that the names used by the recipe are real upstream 2026.94 feature
# switches and that the translation unit sees the intended final values.  A
# typo in localoptions.h would otherwise appear in that file while leaving the
# corresponding server feature at its default.
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
	grep -Eq "^[[:space:]]*#define[[:space:]]+$macro[[:space:]]" \
		"$dropbear_source/src/default_options.h" || \
		fail "$macro is not an upstream Dropbear 2026.94 option"
	actual=$(awk -v macro="$macro" \
		'$1 == "#define" && $2 == macro { print $3 }' "$policy_tmp")
	[ "$actual" = "$expected" ] || \
		fail "$macro compiled as $actual instead of $expected"
	printf '%s=%s\n' "$macro" "$actual" >> "$output/DROPBEAR_COMPILE_POLICY"
done

dnsmasq_ipk=$(find "$output" -maxdepth 1 -type f \
	-name 'sbe-dnsmasq293-candidate_*.ipk' -print | sort | tail -n 1)
dropbear_ipk=$(find "$output" -maxdepth 1 -type f \
	-name 'sbe-dropbear2026-candidate_*.ipk' -print | sort | tail -n 1)
audit_ipk_source "$dnsmasq_ipk" "dnsmasq-$DNSMASQ_VERSION.tar.xz"
audit_ipk_source "$dropbear_ipk" "dropbear-$DROPBEAR_VERSION.tar.bz2"

printf 'BUILT, NOT APPROVED: isolated userland candidates are in %s\n' "$output"
printf 'Do not install emitted QSDK kmod IPKs.  Run target chroot and RAM gates first.\n'
