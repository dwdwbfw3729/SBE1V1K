#!/bin/bash
# Offline candidate build only. Does not install, load or publish modules.
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INVENTORY=${1:?usage: build-common-kmods-docker.sh INVENTORY_DIR NEW_OUTPUT_DIR}
DEST=${2:?usage: build-common-kmods-docker.sh INVENTORY_DIR NEW_OUTPUT_DIR}
EXPORTS=${3:-}
QSDK_ROOT=${QSDK_SOURCE_ROOT:-$HERE/../deps/qsdk-spf12.2-locked}
KERNEL_SOURCE=${QSDK_KERNEL_SOURCE:-$QSDK_ROOT/qsdk/qca/src/linux-5.4}
IMAGE=${QSDK_BUILD_IMAGE:-sbe1v1k-qsdk-builder:ubuntu-22.04-arm64}
TOOLCHAIN=qsdk/staging_dir/toolchain-aarch64_cortex-a73+neon-vfpv4_gcc-7.5.0_musl/bin/aarch64-openwrt-linux-musl-

[[ ! -e "$DEST" ]] || { echo 'ERROR: output already exists; preserve previous evidence' >&2; exit 1; }
INVENTORY=$(CDPATH= cd -- "$INVENTORY" && pwd)
QSDK_ROOT=$(CDPATH= cd -- "$QSDK_ROOT" && pwd)
KERNEL_SOURCE=$(CDPATH= cd -- "$KERNEL_SOURCE" && pwd)
docker_export_args=()
if [[ -n "$EXPORTS" ]]; then
    EXPORTS=$(CDPATH= cd -- "$EXPORTS" && pwd)
    docker_export_args=(-v "$EXPORTS:/exports:ro" -e QSDK_STOCK_SYMVERS=/exports/Module.symvers)
fi
python3 - "$INVENTORY" "$EXPORTS" <<'PY'
import hashlib, json, sys
from pathlib import Path
p = Path(sys.argv[1])
s = json.loads((p / 'inventory.json').read_text())['stock']
for filename, key in [('Image', 'kernel_sha256'), ('stock.config', 'config_sha256')]:
    if hashlib.sha256((p / filename).read_bytes()).hexdigest() != s[key]:
        raise SystemExit('ERROR: inventory artifact changed: ' + filename)
if sys.argv[2]:
    exports = Path(sys.argv[2])
    c = json.loads((exports / 'closure.json').read_text())
    if c['stock_kernel_sha256'] != s['kernel_sha256'] or hashlib.sha256(
            (exports / 'Module.symvers').read_bytes()).hexdigest() != c['symvers_sha256']:
        raise SystemExit('ERROR: stock export inventory identity changed')
PY
mkdir -p "$DEST"
DEST=$(CDPATH= cd -- "$DEST" && pwd)
for run in 1 2; do
    mkdir "$DEST/run-$run"
    docker run --rm --network none --tmpfs /build:exec \
        -e QSDK_SOURCE_ROOT=/workspace/qsdk-spf12.2-locked \
        -e QSDK_KERNEL_DIR=/kernel -e QSDK_KERNEL_BUILD_DIR=/build \
        -e QSDK_KMOD_PROFILE=openwrt-common -e QSDK_KMOD_OUTPUT=/output \
        -e QSDK_CROSS_COMPILE="/workspace/qsdk-spf12.2-locked/$TOOLCHAIN" \
        -e QSDK_ALLOW_PUBLIC_KCONFIG_DRIFT=1 -e QSDK_JOBS="${QSDK_JOBS:-4}" \
        "${docker_export_args[@]}" \
        -v "$QSDK_ROOT:/workspace/qsdk-spf12.2-locked:ro" \
        -v "$KERNEL_SOURCE:/kernel:ro" -v "$HERE:/kmod-builder:ro" \
        -v "$INVENTORY:/input:ro" -v "$DEST/run-$run:/output" \
        --entrypoint /bin/bash "$IMAGE" \
        /kmod-builder/build-passwall-kmods.sh /input/stock.config \
        2>&1 | tee "$DEST/run-$run.log"
done
python3 - "$INVENTORY" "$DEST" <<'PY'
import hashlib, json, sys
from pathlib import Path
inventory, output = map(Path, sys.argv[1:])
targets = (output / 'run-1/BUILD_TARGETS').read_text().splitlines()
modules = {}
if targets != (output / 'run-2/BUILD_TARGETS').read_text().splitlines():
    raise SystemExit('ERROR: target lists changed between builds')
for target in targets:
    name = Path(target).name
    a, b = [(output / f'run-{run}' / name).read_bytes() for run in (1, 2)]
    if a != b:
        raise SystemExit('ERROR: clean rebuild differs: ' + name)
    modules[name] = hashlib.sha256(a).hexdigest()
for name in ('FEATURE_FRAGMENT', 'FACTORY_CONFIG', 'PUBLIC_BASELINE_CONFIG', 'CANDIDATE_CONFIG',
             'BASELINE-KCONFIG-DRIFT.patch'):
    if (output / 'run-1' / name).read_bytes() != (output / 'run-2' / name).read_bytes():
        raise SystemExit('ERROR: build inputs changed between clean builds: ' + name)
report = {'format': 1, 'stock': json.loads((inventory / 'inventory.json').read_text())['stock'],
          'public_kernel_commit': (output / 'run-1/PUBLIC_QSDK_KERNEL_COMMIT').read_text().strip(),
          'modules': modules, 'clean_builds_byte_identical': True,
          'runtime_tested': False, 'release_approved': False}
(output / 'build-report.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
print(f'PASS: {len(modules)} candidate modules reproduced in two clean builds; NOT runtime-approved')
PY
