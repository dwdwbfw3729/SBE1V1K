#!/bin/bash
# Reproducible host tool for the sysupgrade packager, built only in Docker.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test "$(git -C "$here/sources/fwtool" rev-parse HEAD)" = 04cd252e4e9394ffacd51f56f1f124abc534f715
test -z "$(git -C "$here/sources/fwtool" status --porcelain)"
mkdir -p "$here/out"
docker run --rm --network none --platform linux/arm64 \
    -v "$here/sources/fwtool:/src:ro" -v "$here/out:/out" \
    --entrypoint /bin/bash "${QSDK_BUILD_IMAGE:-openwrt-builder:ubuntu-22.04-arm64}" -euo pipefail -c '
    export SOURCE_DATE_EPOCH=1788883544 TZ=UTC LC_ALL=C
    for run in a b; do
        gcc -Os -Wall -Werror -Wextra -Wno-unused-parameter \
            -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
            -Wl,-z,now,-z,relro,-z,noexecstack \
            /src/fwtool.c -o /out/fwtool-$run
    done
    cmp /out/fwtool-a /out/fwtool-b
    cp /out/fwtool-a /out/fwtool
    sha256sum /out/fwtool
    '
