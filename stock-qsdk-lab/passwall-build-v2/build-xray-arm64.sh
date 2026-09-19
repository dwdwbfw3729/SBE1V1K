#!/bin/sh

set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/scripts/common.sh"
"$HERE/verify-sources.sh"

case "$(uname -s):$(uname -m)" in
	Darwin:arm64) ;;
	*) echo "locked toolchain is go$GO_VERSION for Darwin/arm64; refusing a different host" >&2; exit 1 ;;
esac

toolchain=$WORK_DIR/go-$GO_VERSION
safe_clean_dir "$toolchain"
tar -xzf "$DIST_DIR/$GO_ARCHIVE" -C "$toolchain"
GO=$toolchain/go/bin/go
require_equal "Go toolchain" "$($GO version | awk '{print $3}')" "go$GO_VERSION"

module_stage=$WORK_DIR/xray-module-stage
module_cache=$WORK_DIR/go-mod-cache
home=$WORK_DIR/go-home
safe_clean_dir "$module_stage"
safe_clean_dir "$module_cache"
safe_clean_dir "$home"
tar -xzf "$DIST_DIR/$XRAY_ARCHIVE" -C "$module_stage"
src0=$module_stage/Xray-core-${XRAY_TAG#v}

# This is the only network-permitted build phase. go.sum authenticates every
# module; both actual compiler runs below are forced offline.
downloaded=0
for attempt in 1 2 3 4; do
	if (cd "$src0" && env \
		HOME="$home" GOENV=off GOTOOLCHAIN=local GOPROXY=https://proxy.golang.org,direct \
		GOSUMDB=sum.golang.org GOMODCACHE="$module_cache" \
		"$GO" mod download -modcacherw); then
		downloaded=1
		break
	fi
	echo "module download attempt $attempt failed; retaining verified cache and retrying" >&2
done
[ "$downloaded" = 1 ] || { echo "unable to fill the authenticated module cache" >&2; exit 1; }
(cd "$src0" && env \
	HOME="$home" GOENV=off GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off \
	GOMODCACHE="$module_cache" "$GO" mod verify)

build_one() {
	n=$1
	build_rev=$(printf '%.7s' "$XRAY_COMMIT")
	run=$WORK_DIR/xray-run-$n
	safe_clean_dir "$run"
	mkdir -p "$run/src" "$run/gocache" "$run/out" "$run/home"
	tar -xzf "$DIST_DIR/$XRAY_ARCHIVE" -C "$run/src"
	src=$run/src/Xray-core-${XRAY_TAG#v}
	(
		cd "$src"
		env -i \
			PATH="$toolchain/go/bin:/usr/bin:/bin" \
			HOME="$run/home" GOENV=off GOTOOLCHAIN=local GO111MODULE=on \
			CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
			GOPROXY=off GOSUMDB=off GOMODCACHE="$module_cache" GOCACHE="$run/gocache" \
			SOURCE_DATE_EPOCH="$XRAY_COMMIT_EPOCH" TZ=UTC LC_ALL=C \
			"$GO" build -mod=readonly -trimpath -buildvcs=false \
			-ldflags "-buildid= -s -w -X github.com/xtls/xray-core/core.build=$build_rev" \
			-o "$run/out/xray" ./main
	)
	chmod 0755 "$run/out/xray"
}

build_one 1
build_one 2
cmp "$WORK_DIR/xray-run-1/out/xray" "$WORK_DIR/xray-run-2/out/xray"

mkdir -p "$OUT_DIR"
cp "$WORK_DIR/xray-run-1/out/xray" "$OUT_DIR/xray-26.3.27-linux-arm64"
sha256_file "$OUT_DIR/xray-26.3.27-linux-arm64" > "$OUT_DIR/xray-26.3.27-linux-arm64.sha256"
{
	echo "run1_sha256=$(sha256_file "$WORK_DIR/xray-run-1/out/xray")"
	echo "run2_sha256=$(sha256_file "$WORK_DIR/xray-run-2/out/xray")"
	echo "cmp=byte-identical"
	"$GO" version
	echo "module_cache=forced-clean-and-go-mod-verify-passed"
	echo "build_network=off (both compiler phases)"
} > "$OUT_DIR/xray-reproducibility.txt"
echo "PASS: two forced-clean offline Xray builds are byte-identical"
