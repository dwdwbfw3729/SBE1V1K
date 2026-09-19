#!/bin/sh

set -eu

if [ -n "${HERE:-}" ] && [ -f "$HERE/sources.lock" ]; then
	BUNDLE_DIR=$HERE
else
	SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
	BUNDLE_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
fi
DIST_DIR=$BUNDLE_DIR/distfiles
WORK_DIR=$BUNDLE_DIR/work
OUT_DIR=$BUNDLE_DIR/out
WORKSPACE_DIR=$(CDPATH= cd -- "$BUNDLE_DIR/../../.." && pwd)
QSDK_SOURCE_ROOT_DEFAULT=$BUNDLE_DIR/../deps/qsdk-spf12.2-locked

# sources.lock is maintained in this repository, not obtained from a download.
. "$BUNDLE_DIR/sources.lock"

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

file_size() {
	wc -c < "$1" | tr -d '[:space:]'
}

require_equal() {
	sbe_req_label=$1 sbe_req_actual=$2 sbe_req_expected=$3
	if [ "$sbe_req_actual" != "$sbe_req_expected" ]; then
		echo "FAIL: $sbe_req_label: got $sbe_req_actual, expected $sbe_req_expected" >&2
		exit 1
	fi
}

safe_clean_dir() {
	target=$1
	case "$target" in
		"$WORK_DIR"/*|"$OUT_DIR"/*) ;;
		*) echo "refusing unsafe clean target: $target" >&2; exit 1 ;;
	esac
	rm -rf -- "$target"
	mkdir -p -- "$target"
}
