#!/bin/bash
# Bootstrap only tools, headers and userspace dependencies, never a vendor image.
set -euo pipefail
lab=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_root=${QSDK_SOURCE_ROOT:?run via build.sh}
image=${QSDK_BUILD_IMAGE:?run via build.sh}
python3 "$lab/tools/prepare-component-sources.py" --qsdk-source-root "$source_root"

# All source acquisition is outside the network-disabled component builds.
for component in busybox-candidate logd-candidate userland-build coreutils-native-candidate \
    passwall-native-deps-candidate passwall-build-v2; do
    sh "$lab/$component/fetch-sources.sh"
done

docker run --rm --platform linux/arm64 \
    -e QSDK_JOBS="${QSDK_JOBS:-4}" \
    -e QSDK_SOURCE_ROOT=/workspace/qsdk-spf12.2-locked \
    -v "$lab:/repo/stock-qsdk-lab" -v "$source_root:/workspace/qsdk-spf12.2-locked" \
    --entrypoint /bin/bash "$image" /repo/stock-qsdk-lab/tools/prepare-build-environment-in-linux.sh
