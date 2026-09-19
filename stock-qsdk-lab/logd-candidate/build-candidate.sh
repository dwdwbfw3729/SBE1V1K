#!/bin/sh
set -eu

candidate_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_root=${1:-${QSDK_SOURCE_ROOT:-}}
output_dir=${LOGD_CANDIDATE_OUTPUT:-"$candidate_dir/out"}
builder_image=${LOGD_BUILDER_IMAGE:-openwrt-builder:ubuntu-22.04-arm64}

[ -n "$source_root" ] || {
	printf 'usage: %s QSDK_SOURCE_ROOT\n' "$0" >&2
	exit 2
}
toolchain=$source_root/qsdk/staging_dir/toolchain-aarch64_cortex-a73+neon-vfpv4_gcc-7.5.0_musl
target=$source_root/qsdk/staging_dir/target-aarch64_cortex-a73+neon-vfpv4_musl
[ -x "$toolchain/bin/aarch64-openwrt-linux-musl-gcc" ] || {
	printf 'ERROR: locked QSDK AArch64 musl toolchain is missing under %s\n' "$source_root" >&2
	exit 1
}
[ -x "$target/usr/sbin/ubusd" ] || {
	printf 'ERROR: locked QSDK ubusd test dependency is missing under %s\n' "$source_root" >&2
	exit 1
}
command -v docker >/dev/null 2>&1 || {
	printf 'ERROR: Docker is required on macOS.\n' >&2
	exit 1
}

"$candidate_dir/fetch-sources.sh"
"$candidate_dir/verify-sources.sh" "$candidate_dir/cache" "$source_root"
mkdir -p "$output_dir"

docker image inspect "$builder_image" >/dev/null 2>&1 || {
	printf 'ERROR: builder image is not present: %s\n' "$builder_image" >&2
	exit 1
}

docker run --rm --platform linux/arm64 \
	--network none \
	--user 0:0 \
	--entrypoint /bin/sh \
	-v "$candidate_dir:/candidate:ro" \
	-v "$source_root:/qsdk-source:ro" \
	-v "$output_dir:/out" \
	"$builder_image" \
	/candidate/build-in-linux.sh /qsdk-source /candidate/cache /out
