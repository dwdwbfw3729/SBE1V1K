#!/bin/bash
# A headers-only kernel context for userspace recipes. Never publish its kmods.
set -euo pipefail
lab=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_root=${QSDK_SOURCE_ROOT:?}
qsdk=$source_root/qsdk
kernel=${QSDK_KERNEL_DIR:-$qsdk/qca/src/linux-5.4}
output=${QSDK_KERNEL_BUILD_DIR:-$source_root/candidate-work/kernel-stock-passwall}
cross=$qsdk/staging_dir/toolchain-aarch64_cortex-a73+neon-vfpv4_gcc-7.5.0_musl/bin/aarch64-openwrt-linux-musl-
stock=$lab/cache/stock-1.5.3
. "$lab/passwall-build-v2/netfilter-candidates.lock"
export STAGING_DIR=$qsdk/staging_dir
mkdir -p "$output"
if [ -f "$output/.config" ]; then
    actual=$(sha256sum "$output/.config" | awk '{print $1}')
    test -f "$output/.config.stock" && test "$actual" = "$PASSWALL_CANDIDATE_CONFIG_SHA256" || {
        echo 'ERROR: existing kernel-header configuration differs; preserved' >&2
        exit 1
    }
fi
temporary=$(mktemp -d /tmp/sbe-userland-headers.XXXXXX)
trap 'rm -rf "$temporary"' EXIT
python3 - "$lab" "$stock" "$temporary/Image" <<'PY'
import json, lzma, sys
from pathlib import Path
lab, stock, output = map(Path, sys.argv[1:])
sys.path.insert(0, str(lab / 'tools'))
from prepare_stock_source import digest, kernel_lzma
fit = (stock / 'stock-p25.fit').read_bytes()
derived = json.loads((stock / 'derived-source.json').read_text())
if digest(fit) != derived['artifacts']['stock-p25.fit']['sha256']:
    raise SystemExit('stock FIT differs from the authenticated vendor extraction')
output.write_bytes(lzma.decompress(kernel_lzma(fit), format=lzma.FORMAT_ALONE))
PY
"$kernel/scripts/extract-ikconfig" "$temporary/Image" > "$temporary/stock.config"
test -s "$temporary/stock.config"
if [ -e "$output/.config.stock" ]; then
    cmp "$temporary/stock.config" "$output/.config.stock"
    if [ -f "$output/.config" ] && [ -f "$output/modules.builtin" ] && [ -d "$output/user_headers/include" ]; then
        echo 'PASS: existing source-locked header context reused without changes'
        exit 0
    fi
else
    cp "$temporary/stock.config" "$output/.config.stock"
fi
cp "$temporary/stock.config" "$output/.config"
"$kernel/scripts/config" --file "$output/.config" --disable LOCALVERSION_AUTO
while IFS='=' read -r symbol value; do
    [ -n "$symbol" ] || continue
    test "$value" = m || { echo "ERROR: invalid header fragment: $symbol" >&2; exit 1; }
    "$kernel/scripts/config" --file "$output/.config" --module "${symbol#CONFIG_}"
done < "$lab/qsdk-build/kernel-passwall.fragment"
make -C "$kernel" O="$output" ARCH=arm64 CROSS_COMPILE="$cross" LOCALVERSION= olddefconfig
actual=$(sha256sum "$output/.config" | awk '{print $1}')
test "$actual" = "$PASSWALL_CANDIDATE_CONFIG_SHA256" || {
    echo 'ERROR: generated kernel-header configuration differs from the independent lock' >&2
    exit 1
}
make -C "$kernel" O="$output" ARCH=arm64 CROSS_COMPILE="$cross" LOCALVERSION= \
    INSTALL_HDR_PATH="$output/user_headers" headers_install
# QSDK parses this during userspace package metadata generation. This context
# contains no compiled kernel/module inventory; an empty list is intentional.
# The release manifest admits no .ko from this output tree.
if [ ! -e "$output/modules.builtin" ]; then
    : > "$output/modules.builtin"
fi
printf 'Headers-only public QSDK context; not a kernel ABI approval.\n' > "$output/SBE-HEADERS-ONLY"
