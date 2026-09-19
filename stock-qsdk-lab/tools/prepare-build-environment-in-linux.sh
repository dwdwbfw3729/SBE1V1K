#!/bin/bash
set -euo pipefail
lab=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_root=${QSDK_SOURCE_ROOT:?}
qsdk=$source_root/qsdk
jobs=${QSDK_JOBS:-4}
# Per-process Git settings survive source verifiers that disable global config.
# Bound safe.directory entries to initialized sources mounted by the wrapper.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=0
allow_source() {
    export "GIT_CONFIG_KEY_${GIT_CONFIG_COUNT}=safe.directory"
    export "GIT_CONFIG_VALUE_${GIT_CONFIG_COUNT}=$1"
    GIT_CONFIG_COUNT=$((GIT_CONFIG_COUNT + 1))
}
allow_source "$qsdk"
while IFS= read -r directory; do
    allow_source "$directory"
done < <(python3 - "$lab" <<'PY'
import json, sys
from pathlib import Path
lab = Path(sys.argv[1])
for item in json.loads((lab / 'sources/dependencies.json').read_text())['git']:
    print(lab / item['path'])
PY
)
for path in qsdk-package qca/src/linux-5.4 qca/feeds/packages qca/feeds/luci qca/configs/qsdk; do
    allow_source "$qsdk/$path"
done

"$lab/qsdk-build/prepare-qsdk-toolchain.sh"
config_copy=$(mktemp /tmp/sbe-bootstrap-config.XXXXXX)
cp "$qsdk/.config" "$config_copy"
trap 'cp "$config_copy" "$qsdk/.config"; rm -f "$config_copy"' EXIT

# Prepare headers before package metadata, without compiling a kernel/modules.
make -C "$qsdk" -j"$jobs" tools/install V=s
"$lab/tools/prepare-userland-headers.sh"
header_context=$source_root/candidate-work/kernel-stock-passwall
# Explicit, dependency-ordered userspace targets. NO_DEPS prevents runtime
# +kmod dependencies (notably libnetfilter-conntrack) from building the kernel.
for target in package/libs/toolchain/compile package/libs/zlib/compile \
    package/libs/libjson-c/compile package/libs/libubox/compile \
    package/utils/lua/compile package/system/ubus/compile package/system/uci/compile \
    package/libs/libnl-tiny/compile package/network/utils/iwinfo/compile \
    package/system/rpcd/compile package/libs/mbedtls/compile \
    package/libs/ustream-ssl/compile \
    package/libs/libmnl/compile package/libs/libnfnetlink/compile \
    package/libs/libnetfilter-conntrack/compile \
    package/libs/ncurses/compile; do
    make -C "$qsdk" -j"$jobs" NO_DEPS=1 LINUX_DIR="$header_context" "$target" V=s
done

for component in core-userland-build diagnostics-modern-build rrdns-modern-build tls-curl-candidate; do
    "$lab/$component/fetch-sources.sh"
done
# LuCI's native host minifiers and catalog compiler are standard feed tools.
for target in package/feeds/luci/luci-base/host/compile \
    package/feeds/packages/luasrcdiet/host/compile; do
    make -C "$qsdk" -j"$jobs" "$target" V=s
done
printf 'PASS: source-locked build environment is prepared\n'
