#!/bin/sh
set -eu

candidate_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
lab_dir=$(CDPATH= cd -- "$candidate_dir/.." && pwd)
source_root=${1:-${QSDK_SOURCE_ROOT:-}}
stock_image=${2:-${SBE_STOCK_P27:-}}
binary=${3:-"$candidate_dir/out/busybox-1.37.0-qsdk-candidate"}
output_dir=${BUSYBOX_CANDIDATE_AUDIT_OUTPUT:-"$candidate_dir/out/candidate-audit"}
audit_image=${BUSYBOX_AUDIT_IMAGE:-sbe1v1k-stock-rootfs-builder:ubuntu-24.04}
. "$candidate_dir/factory-baseline.env"

[ -n "$source_root" ] && [ -n "$stock_image" ] || {
	printf 'usage: %s QSDK_SOURCE_ROOT STOCK_P27_IMAGE [CANDIDATE_BINARY]\n' "$0" >&2
	exit 2
}
[ -f "$stock_image" ] && [ -f "$binary" ] || {
	printf 'ERROR: stock image or candidate binary is missing.\n' >&2
	exit 1
}
source_root=$(CDPATH= cd -- "$source_root" && pwd)
stock_parent=$(CDPATH= cd -- "$(dirname -- "$stock_image")" && pwd)
stock_image=$stock_parent/$(basename -- "$stock_image")
binary_parent=$(CDPATH= cd -- "$(dirname -- "$binary")" && pwd)
binary=$binary_parent/$(basename -- "$binary")
if command -v sha256sum >/dev/null 2>&1; then
	stock_sha=$(sha256sum "$stock_image" | awk '{print $1}')
else
	stock_sha=$(shasum -a 256 "$stock_image" | awk '{print $1}')
fi
[ "$stock_sha" = "$FACTORY_P27_SHA256" ] || {
	printf 'ERROR: input is not the locked factory p27 image: %s\n' "$stock_sha" >&2
	exit 1
}
toolchain_dir=$source_root/qsdk/staging_dir/toolchain-aarch64_cortex-a73+neon-vfpv4_gcc-7.5.0_musl
[ -d "$toolchain_dir" ] || {
	printf 'ERROR: QSDK toolchain is missing: %s\n' "$toolchain_dir" >&2
	exit 1
}
mkdir -p "$output_dir"
# A failed rerun must not leave an earlier PASS summary looking current.
rm -f "$output_dir/audit-summary.env" "$output_dir/semantic-summary.env"

docker run --rm --platform linux/arm64 \
	--network none \
	--tmpfs /scratch:rw,exec,dev,nosuid,size=512m \
	--entrypoint /bin/sh \
	-v "$candidate_dir:/candidate:ro" \
	-v "$lab_dir/overlay:/overlay:ro" \
	-v "$source_root:/qsdk-source:ro" \
	-v "$stock_image:/input/stock-p27.img:ro" \
	-v "$binary:/input/busybox-candidate:ro" \
	-v "$output_dir:/out" \
	"$audit_image" \
	/candidate/audit-candidate-in-linux.sh \
		/input/stock-p27.img /input/busybox-candidate /qsdk-source /out
