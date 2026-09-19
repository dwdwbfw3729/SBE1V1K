#!/bin/sh
set -eu

candidate_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_root=${1:-${QSDK_SOURCE_ROOT:-}}
stock_image=${2:-${SBE_STOCK_P27:-}}
output_dir=${BUSYBOX_CANDIDATE_OUTPUT:-"$candidate_dir/out"}
builder_image=${BUSYBOX_BUILDER_IMAGE:-openwrt-builder:ubuntu-22.04-arm64}

[ -n "$source_root" ] || {
	printf 'usage: %s QSDK_SOURCE_ROOT [STOCK_P27_IMAGE]\n' "$0" >&2
	exit 2
}
[ -x "$source_root/qsdk/staging_dir/toolchain-aarch64_cortex-a73+neon-vfpv4_gcc-7.5.0_musl/bin/aarch64-openwrt-linux-musl-gcc" ] || {
	printf 'ERROR: locked QSDK AArch64 musl toolchain is missing under %s\n' "$source_root" >&2
	exit 1
}
cmp -s "$candidate_dir/rootfs-payload/etc/init.d/sysntpd" \
	"$source_root/qsdk/package/utils/busybox/files/sysntpd" || {
	printf 'ERROR: sysntpd payload differs from the locked QSDK source.\n' >&2
	exit 1
}
cmp -s "$candidate_dir/rootfs-payload/usr/sbin/ntpd-hotplug" \
	"$source_root/qsdk/package/utils/busybox/files/ntpd-hotplug" || {
	printf 'ERROR: ntpd-hotplug payload differs from the locked QSDK source.\n' >&2
	exit 1
}
command -v docker >/dev/null 2>&1 || {
	printf 'ERROR: Docker is required on macOS.\n' >&2
	exit 1
}

"$candidate_dir/fetch-sources.sh"
mkdir -p "$output_dir"

docker image inspect "$builder_image" >/dev/null 2>&1 || {
	printf 'ERROR: builder image is not present: %s\n' "$builder_image" >&2
	exit 1
}

docker run --rm --platform linux/arm64 \
	--network none \
	--entrypoint /bin/sh \
	-v "$candidate_dir:/candidate:ro" \
	-v "$source_root:/qsdk-source:ro" \
	-v "$output_dir:/out" \
	"$builder_image" \
	/candidate/build-in-linux.sh /qsdk-source /candidate/cache /out

if [ -n "$stock_image" ]; then
	"$candidate_dir/audit-candidate.sh" "$source_root" "$stock_image" \
		"$output_dir/busybox-1.37.0-qsdk-candidate"
else
	printf 'Build gates passed. Chroot gate was skipped because STOCK_P27_IMAGE was not supplied.\n'
	printf 'The candidate remains quarantined and must not be integrated.\n'
fi
