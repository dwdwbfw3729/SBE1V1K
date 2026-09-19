#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
lab_dir=$(CDPATH= cd -- "$build_dir/.." && pwd)

source_root=${1:-${QSDK_SOURCE_ROOT:-}}
[ -n "$source_root" ] || {
	printf 'usage: %s QSDK_SOURCE_ROOT\n' "$0" >&2
	printf 'QSDK_SOURCE_ROOT must contain the locked public QSDK tree at qsdk/.\n' >&2
	exit 2
}
[ "$(uname -s)" = Linux ] || {
	printf 'ERROR: QSDK candidates must be built inside Linux (Docker on macOS is supported).\n' >&2
	exit 1
}
qsdk_dir=$source_root/qsdk
jobs=${QSDK_JOBS:-4}
kernel_build_dir=${QSDK_KERNEL_BUILD_DIR:-"$source_root/candidate-work/kernel-stock-passwall"}
output=${QSDK_EXTRA_USERLAND_OUTPUT:-"$build_dir/out"}

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
[ -f "$qsdk_dir/Makefile" ] || {
	printf 'ERROR: complete QSDK build tree is missing: %s\n' "$qsdk_dir" >&2
	exit 1
}
[ -f "$qsdk_dir/.config" ] || {
	printf 'ERROR: run Qualcomm setup-environment for ipq95xx/64/premium first; .config is absent.\n' >&2
	exit 1
}
[ -f "$kernel_build_dir/.config" ] || {
	printf 'ERROR: candidate kernel config is missing: %s\n' "$kernel_build_dir/.config" >&2
	exit 1
}
[ -f "$kernel_build_dir/modules.builtin" ] || {
	printf 'ERROR: candidate modules.builtin is missing: %s\n' "$kernel_build_dir/modules.builtin" >&2
	exit 1
}
[ -d "$kernel_build_dir/user_headers/include" ] || {
	printf 'ERROR: candidate kernel user headers are missing: %s\n' "$kernel_build_dir/user_headers/include" >&2
	exit 1
}

QSDK_SOURCE_ROOT=$source_root "$lab_dir/qsdk-build/verify-sources.sh"
"$build_dir/fetch-sources.sh" "$qsdk_dir/dl"

mini_link=$qsdk_dir/package/sbe-miniupnpd2311-candidate
ntfs_link=$qsdk_dir/package/sbe-ntfs3g2026-candidate
ntp_link=$qsdk_dir/package/sbe-ntpdate4218-candidate
[ ! -e "$mini_link" ] && [ ! -L "$mini_link" ] || {
	printf 'ERROR: refusing existing package path: %s\n' "$mini_link" >&2
	exit 1
}
[ ! -e "$ntfs_link" ] && [ ! -L "$ntfs_link" ] || {
	printf 'ERROR: refusing existing package path: %s\n' "$ntfs_link" >&2
	exit 1
}
[ ! -e "$ntp_link" ] && [ ! -L "$ntp_link" ] || {
	printf 'ERROR: refusing existing package path: %s\n' "$ntp_link" >&2
	exit 1
}

config_backup=$(mktemp "${TMPDIR:-/tmp}/sbe-qsdk-config.XXXXXX")
cp "$qsdk_dir/.config" "$config_backup"
cleanup() {
	rm -f "$mini_link" "$ntfs_link" "$ntp_link"
	if [ -f "$config_backup" ]; then
		cp "$config_backup" "$qsdk_dir/.config"
		rm -f "$config_backup"
	fi
}
trap cleanup EXIT HUP INT TERM

ln -s "$build_dir/package-overlay/sbe-miniupnpd2311-candidate" "$mini_link"
ln -s "$build_dir/package-overlay/sbe-ntfs3g2026-candidate" "$ntfs_link"
ln -s "$build_dir/package-overlay/sbe-ntpdate4218-candidate" "$ntp_link"

# Use the minimum ipq95xx profile for candidate-only package builds.  The
# QSDK Premium profile otherwise pulls unrelated public-kernel IPKs into this
# userland evaluation.  The release config is restored by the trap.
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
		'CONFIG_PKG_RELRO_FULL=y' \
		'CONFIG_PACKAGE_sbe-miniupnpd2311-candidate=m' \
		'CONFIG_PACKAGE_sbe-ntfs3g2026-candidate=m' \
		'CONFIG_PACKAGE_sbe-ntpdate4218-candidate=m'
} > "$qsdk_dir/.config"
make -C "$qsdk_dir" defconfig

# Kernel modules remain separately stock-configured candidates.  Keep their
# runtime dependency metadata, but suppress all QSDK kmod packaging here.
minimal_config=$(mktemp "${TMPDIR:-/tmp}/sbe-qsdk-minimal.XXXXXX")
awk '!/^CONFIG_PACKAGE_kmod-[^=]*=[ym]$/' "$qsdk_dir/.config" > "$minimal_config"
cp "$minimal_config" "$qsdk_dir/.config"
rm -f "$minimal_config"
mkdir -p "$output"
cp "$qsdk_dir/.config" "$output/CANDIDATE_BUILD_CONFIG"

# Clean only the three isolated candidate build directories.  This prevents
# a prior configure probe (especially MiniUPnPd's optional NFCT detection)
# from changing a later candidate without touching the shared toolchain.
make -C "$qsdk_dir" \
	package/sbe-miniupnpd2311-candidate/clean \
	package/sbe-ntfs3g2026-candidate/clean \
	package/sbe-ntpdate4218-candidate/clean

make -C "$qsdk_dir" -j"$jobs" LINUX_DIR="$kernel_build_dir" \
	package/sbe-miniupnpd2311-candidate/compile V=s
make -C "$qsdk_dir" -j"$jobs" LINUX_DIR="$kernel_build_dir" \
	package/sbe-ntfs3g2026-candidate/compile V=s
make -C "$qsdk_dir" -j"$jobs" LINUX_DIR="$kernel_build_dir" \
	package/sbe-ntpdate4218-candidate/compile V=s

found=0
for pattern in \
	'sbe-miniupnpd2311-candidate_*.ipk' \
	'sbe-ntfs3g2026-candidate_*.ipk' \
	'sbe-ntpdate4218-candidate_*.ipk'
do
	artifact=$(find "$qsdk_dir/bin" -type f -name "$pattern" -print | sort | tail -n 1)
	[ -n "$artifact" ] || {
		printf 'ERROR: build completed without %s\n' "$pattern" >&2
		exit 1
	}
	cp "$artifact" "$output/"
	found=$((found + 1))
done
[ "$found" -eq 3 ]

mini_ipk=$(find "$output" -maxdepth 1 -type f \
	-name 'sbe-miniupnpd2311-candidate_*.ipk' -print | sort | tail -n 1)
ntfs_ipk=$(find "$output" -maxdepth 1 -type f \
	-name 'sbe-ntfs3g2026-candidate_*.ipk' -print | sort | tail -n 1)
ntp_ipk=$(find "$output" -maxdepth 1 -type f \
	-name 'sbe-ntpdate4218-candidate_*.ipk' -print | sort | tail -n 1)
audit_ipk_source "$mini_ipk" "miniupnpd-2.3.11.tar.gz"
audit_ipk_source "$ntfs_ipk" "ntfs-3g_ntfsprogs-2026.7.7.tgz"
audit_ipk_source "$ntp_ipk" "ntp-4.2.8p18.tar.gz"

printf 'Candidate IPKs written to %s\n' "$output"
printf 'They remain evaluation-only; do not install or bake them before target gates.\n'
