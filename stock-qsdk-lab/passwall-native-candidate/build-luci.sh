#!/bin/bash
# Package-only build. Run exclusively with respect to other QSDK make jobs.
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORKSPACE_PARENT=$(CDPATH= cd -- "$HERE/../../.." && pwd)
QSDK=${QSDK_SOURCE_ROOT:-$HERE/../deps/qsdk-spf12.2-locked}/qsdk
IMAGE=${QSDK_BUILD_IMAGE:-openwrt-builder:ubuntu-22.04-arm64}
export PYTHONDONTWRITEBYTECODE=1
python3 "$HERE/prepare.py"
test "$(git -C "$QSDK" rev-parse HEAD)" = e1bc332529d3e4b0ef27173a8549a87ee7490878
test "$(git -C "$QSDK/qca/feeds/luci" rev-parse HEAD)" = 4b50d7975bd312fd0e5b28b95b67fb372cfa9da7
config_sha=$(shasum -a 256 "$QSDK/.config" | awk '{print $1}')
mountpoint=$QSDK/package/luci-app-passwall-native
test ! -e "$mountpoint"
mkdir "$mountpoint"
trap 'rmdir "$mountpoint" 2>/dev/null || true' EXIT INT TERM
mkdir -p "$HERE/candidate-out"
docker run --rm --network none \
    -e EXPECTED_CONFIG="$config_sha" \
    -v "$QSDK:/qsdk" \
    -v "$HERE/work/prepared/luci-app-passwall:/qsdk/package/luci-app-passwall-native:ro" \
    -v "$HERE:/candidate" \
    --entrypoint /bin/bash "$IMAGE" -euo pipefail -c '
    cd /qsdk
    export SOURCE_DATE_EPOCH=1788883544 TZ=UTC LC_ALL=C
    export GNUPGHOME=/tmp/passwall-native-gnupg
    export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=/qsdk
    export GIT_CONFIG_KEY_1=safe.directory GIT_CONFIG_VALUE_1=/qsdk/qca/feeds/luci
    mkdir -p /tmp/passwall-native-home "$GNUPGHOME"
    common=(NO_DEPS=1 CONFIG_PACKAGE_luci-app-passwall=m CONFIG_PACKAGE_luci-i18n-passwall-zh-cn=m)
    for run in 1 2; do
        test "$(sha256sum .config | cut -d " " -f1)" = "$EXPECTED_CONFIG"
        make "${common[@]}" package/luci-app-passwall-native/clean > /candidate/candidate-out/clean-run${run}.log 2>&1
        if ! make -j4 "${common[@]}" package/luci-app-passwall-native/compile V=s > /candidate/candidate-out/build-run${run}.log 2>&1; then
            tail -n 80 /candidate/candidate-out/build-run${run}.log
            exit 1
        fi
        for package in luci-app-passwall luci-i18n-passwall-zh-cn; do
            name=${package}_26.9.9-1-qsdk6_all.ipk
            found=$(find bin -type f -name "$name" -print -quit)
            test -n "$found"
            cp "$found" "/candidate/candidate-out/${package}.run${run}.ipk"
        done
    done
    test "$(sha256sum .config | cut -d " " -f1)" = "$EXPECTED_CONFIG"
    for package in luci-app-passwall luci-i18n-passwall-zh-cn; do
        cmp /candidate/candidate-out/${package}.run1.ipk /candidate/candidate-out/${package}.run2.ipk
        cp /candidate/candidate-out/${package}.run1.ipk /candidate/candidate-out/${package}_26.9.9-1-qsdk6_all.ipk
    done
    sha256sum /candidate/candidate-out/*_all.ipk
    '
test "$(shasum -a 256 "$QSDK/.config" | awk '{print $1}')" = "$config_sha"
