#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/sources.lock"
WORKSPACE=$(CDPATH= cd -- "$HERE/../../.." && pwd)
QSDK_TOP=${QSDK_TOP:-"${QSDK_SOURCE_ROOT:-$HERE/../deps/qsdk-spf12.2-locked}/qsdk"}
IMAGE=${BUILDER_IMAGE:-openwrt-builder:ubuntu-22.04-arm64}
UID_GID=$(id -u):$(id -g)

[ -d "$QSDK_TOP" ] || {
	echo "ERROR: locked QSDK tree is unavailable: $QSDK_TOP" >&2
	exit 1
}
[ "$(git -C "$HERE/upstream" rev-parse HEAD)" = "$UPSTREAM_COMMIT" ] || {
	echo 'ERROR: LuCI VXLAN source commit mismatch' >&2
	exit 1
}
[ -z "$(git -C "$HERE/upstream" status --porcelain --untracked-files=all)" ] || {
	echo 'ERROR: LuCI VXLAN source checkout is dirty' >&2
	exit 1
}

docker run --rm --platform linux/arm64 --network none --user "$UID_GID" \
	-v "$HERE:/candidate" \
	-v "$QSDK_TOP:/qsdk:ro" \
	--entrypoint /bin/sh "$IMAGE" \
	/candidate/build-in-linux.sh /qsdk /candidate/out
