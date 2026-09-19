#!/bin/sh
# Offline checks with an isolated loopback core: no device, init, module or boot action.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAB=$(CDPATH= cd -- "$HERE/../.." && pwd)
[ "$#" -eq 1 ] || { echo 'usage: sh native-acceptance.sh FINAL.root.squashfs' >&2; exit 2; }
[ -f "$1" ] || { echo 'SquashFS input does not exist' >&2; exit 2; }
IMAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$1")" && pwd)
IMAGE_NAME=$(basename -- "$1")
docker run --rm --network none --read-only --tmpfs /tmp:exec,dev \
  --platform linux/arm64 -e PYTHONDONTWRITEBYTECODE=1 \
  -v "$LAB:/lab:ro" -v "$IMAGE_DIR:/input:ro" \
  --entrypoint sh sbe1v1k-stock-rootfs-builder:ubuntu-24.04 -eu -c '
    image=$1
    work=$(mktemp -d /tmp/passwall-native-acceptance.XXXXXX)
    unsquashfs -d "$work/root" "$image" >/dev/null
    mkdir -p "$work/root/tmp/etc" "$work/root/tmp/log" "$work/root/tmp/lock"
    mknod -m 666 "$work/root/dev/null" c 1 3
    mknod -m 666 "$work/root/dev/urandom" c 1 9
    python3 /lab/passwall-native-candidate/tests/native-acceptance.py \
      --root "$work/root" --image "$image"
  ' sh "/input/$IMAGE_NAME"
