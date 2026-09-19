#!/bin/sh
set -eu

candidate_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$candidate_dir/../.." && pwd)
qsdk_root=${QSDK_SOURCE_ROOT:-"$repo_dir/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}
image=${TLS_CURL_BUILD_IMAGE:-openwrt-builder:ubuntu-22.04-arm64}
run_name=${1:-run-1}
output_dir="$candidate_dir/out/$run_name"
toolchain_rel=qsdk/staging_dir/toolchain-aarch64_cortex-a73+neon-vfpv4_gcc-7.5.0_musl
target_rel=qsdk/staging_dir/target-aarch64_cortex-a73+neon-vfpv4_musl

[ -d "$qsdk_root/$toolchain_rel" ] || {
	printf 'ERROR: missing QSDK toolchain under %s\n' "$qsdk_root" >&2
	exit 1
}
[ -d "$qsdk_root/$target_rel" ] || {
	printf 'ERROR: missing QSDK target staging under %s\n' "$qsdk_root" >&2
	exit 1
}

mkdir -p "$candidate_dir/out"
docker run --rm --network none --platform linux/arm64 \
	-v "$repo_dir:/repo" \
	-v "$qsdk_root:/qsdk:ro" \
	"$image" \
	/repo/stock-qsdk-lab/tls-curl-candidate/build-in-linux.sh \
	/repo/stock-qsdk-lab/tls-curl-candidate/distfiles \
	"/qsdk/$toolchain_rel" "/qsdk/$target_rel" \
	"/repo/stock-qsdk-lab/tls-curl-candidate/out/$run_name"

"$candidate_dir/audit-in-linux.sh" "$output_dir" "$qsdk_root/$toolchain_rel"

printf 'Built and audited isolated candidate: %s\n' "$output_dir"
