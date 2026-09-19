#!/bin/bash
# Package-only, two clean Docker builds. Never flash or alter the live router.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
qsdk=${QSDK_SOURCE_ROOT:-$here/../deps/qsdk-spf12.2-locked}/qsdk
revision=b6ae9ffaeb0e18e9fa3d5be62faa8d3c9f340a58
test "$(git -C "$here/sources/odhcp6c" rev-parse HEAD)" = "$revision"
test -z "$(git -C "$here/sources/odhcp6c" status --porcelain)"
test "$(git -C "$qsdk" rev-parse HEAD)" = e1bc332529d3e4b0ef27173a8549a87ee7490878
test "$(shasum -a 256 "$qsdk/package/network/ipv6/odhcp6c/files/dhcpv6.sh" | cut -d ' ' -f1)" = 20c2cf97ee573edcf59f6339ce86853f5ca51fc5e3325343410107fee8af40ee
test "$(shasum -a 256 "$qsdk/package/network/ipv6/odhcp6c/files/dhcpv6.script" | cut -d ' ' -f1)" = ecc9b1c5ecc1c1356701fd7b7969df1f6e4c47a40fff2886ecab2b5344b1e940
mkdir -p "$here/work/hooks" "$here/candidate-out"
git -C "$here/sources/odhcp6c" archive --format=tar "$revision" > "$here/work/source.tar"
cp "$qsdk/package/network/ipv6/odhcp6c/files/dhcpv6.sh" "$qsdk/package/network/ipv6/odhcp6c/files/dhcpv6.script" "$here/work/hooks/"
config_sha=$(shasum -a 256 "$qsdk/.config" | cut -d ' ' -f1)
docker run --rm --network none \
    -e EXPECTED_CONFIG="$config_sha" \
    -v "$qsdk:/qsdk" -v "$here:/candidate" \
    -v "$here/package:/qsdk/package/network/ipv6/odhcp6c:ro" \
    --entrypoint /bin/bash "${QSDK_BUILD_IMAGE:-openwrt-builder:ubuntu-22.04-arm64}" -euo pipefail -c '
    cd /qsdk
    export SOURCE_DATE_EPOCH=1788883544 TZ=UTC LC_ALL=C
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=/qsdk
    common=(NO_DEPS=1 CONFIG_PACKAGE_odhcp6c=m CONFIG_IPV6=y)
    for run in 1 2; do
        test "$(sha256sum .config | cut -d " " -f1)" = "$EXPECTED_CONFIG"
        make "${common[@]}" package/network/ipv6/odhcp6c/clean > /candidate/candidate-out/clean-$run.log 2>&1
        if ! make -j4 "${common[@]}" package/network/ipv6/odhcp6c/compile V=s > /candidate/candidate-out/build-$run.log 2>&1; then
            tail -n 80 /candidate/candidate-out/build-$run.log
            exit 1
        fi
        name=odhcp6c_2024-09-25-b6ae9ffa-1-sbe1_aarch64_cortex-a73_neon-vfpv4.ipk
        found=$(find bin -type f -name "$name" -print -quit)
        test -n "$found"
        cp "$found" /candidate/candidate-out/run-$run.ipk
    done
    cmp /candidate/candidate-out/run-1.ipk /candidate/candidate-out/run-2.ipk
    cp /candidate/candidate-out/run-1.ipk "/candidate/candidate-out/$name"
    test "$(sha256sum .config | cut -d " " -f1)" = "$EXPECTED_CONFIG"
    sha256sum "/candidate/candidate-out/$name"
    '
test "$(shasum -a 256 "$qsdk/.config" | cut -d ' ' -f1)" = "$config_sha"
