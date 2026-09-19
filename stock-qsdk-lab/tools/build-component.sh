#!/bin/bash
# Small adapters for components whose original builder has a container-only CLI.
set -euo pipefail
lab=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_root=${QSDK_SOURCE_ROOT:?run via build.sh}
image=${QSDK_BUILD_IMAGE:?run via build.sh}
component=${1:?component name is required}
mkdir -p "$lab/work/components"
temporary=$(mktemp -d "$lab/work/components/$component.XXXXXX")
container_temporary=/repo/stock-qsdk-lab/${temporary#"$lab/"}

in_builder() {
    docker run --rm --network none --platform linux/arm64 \
        -e HOME=/tmp/sbe-component-home -e QSDK_JOBS="${QSDK_JOBS:-4}" \
        -e QSDK_SOURCE_ROOT=/workspace/qsdk-spf12.2-locked \
        -e GIT_CONFIG_COUNT=6 \
        -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/workspace/qsdk-spf12.2-locked/qsdk \
        -e GIT_CONFIG_KEY_1=safe.directory -e GIT_CONFIG_VALUE_1=/workspace/qsdk-spf12.2-locked/qsdk/qsdk-package \
        -e GIT_CONFIG_KEY_2=safe.directory -e GIT_CONFIG_VALUE_2=/workspace/qsdk-spf12.2-locked/qsdk/qca/src/linux-5.4 \
        -e GIT_CONFIG_KEY_3=safe.directory -e GIT_CONFIG_VALUE_3=/workspace/qsdk-spf12.2-locked/qsdk/qca/feeds/packages \
        -e GIT_CONFIG_KEY_4=safe.directory -e GIT_CONFIG_VALUE_4=/workspace/qsdk-spf12.2-locked/qsdk/qca/feeds/luci \
        -e GIT_CONFIG_KEY_5=safe.directory -e GIT_CONFIG_VALUE_5=/workspace/qsdk-spf12.2-locked/qsdk/qca/configs/qsdk \
        -v "$lab:/repo/stock-qsdk-lab" -v "$source_root:/workspace/qsdk-spf12.2-locked" \
        --entrypoint /bin/bash "$image" "$@"
}

case "$component" in
    dropbear)
        for round in a b; do
            in_builder -c 'export QSDK_DROPBEAR_OUTPUT=$1; exec /repo/stock-qsdk-lab/qsdk-build/build-dropbear-candidate.sh' \
                sh "$container_temporary/$round"
        done
        sh "$lab/qsdk-build/verify-dropbear-repro.sh" "$temporary/a" "$temporary/b"
        python3 "$lab/tools/promote-component.py" dropbear "$temporary/a"
        ;;
    dnsmasq|xtables)
        for round in a b; do
            in_builder -c 'export QSDK_USERLAND_OUTPUT=$1; exec /repo/stock-qsdk-lab/qsdk-build/build-userland-candidates.sh' \
                sh "$container_temporary/$round"
        done
        diff -qr "$temporary/a" "$temporary/b"
        python3 "$lab/tools/promote-component.py" dnsmasq-binary "$temporary/a"
        python3 "$lab/passwall-native-candidate/package-dnsmasq-full.py"
        python3 - "$lab" "$temporary/a/xtables" <<'PY'
import sys, shutil
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'tools'))
from build_release import stage_plan, sha256, local
source = Path(sys.argv[2])
stage = next(s for s in stage_plan() if s['name'] == 'xtables')
for relative, expected in stage['artifacts'].items():
    target = local(relative)
    built = source / target.name
    if sha256(built) != expected:
        raise SystemExit('xtables build differs from artifact lock: ' + target.name)
    if target.exists() and sha256(target) != expected:
        raise SystemExit('refusing to replace existing changed extension: ' + target.name)
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        shutil.copyfile(built, target)
PY
        ;;
    passwall-deps)
        run_id=run-$(basename "$temporary" | tr 'A-Z.' 'a-z-')
        for round in a b; do
            docker run --rm --network none --platform linux/arm64 \
                -v "$source_root/qsdk:/qsdk:ro" \
                -v "$lab/passwall-native-deps-candidate:/candidate" \
                --entrypoint /bin/bash "$image" /candidate/build-in-linux.sh "$run_id-$round"
        done
        for first in "$lab/passwall-native-deps-candidate/out/$run_id-a/"*.ipk; do
            cmp "$first" "$lab/passwall-native-deps-candidate/out/$run_id-b/$(basename "$first")"
        done
        python3 "$lab/tools/promote-component.py" passwall-deps "$lab/passwall-native-deps-candidate/out/$run_id-a"
        ;;
    proxy-cores)
        sh "$lab/passwall-build-v2/build-xray-arm64.sh"
        python3 "$lab/passwall-native-candidate/package-xray.py"
        python3 "$lab/passwall-native-candidate/package-shadowsocks-rust.py"
        python3 "$lab/passwall-native-candidate/package-sing-box.py"
        ;;
    *) echo "unknown component: $component" >&2; exit 2 ;;
esac
