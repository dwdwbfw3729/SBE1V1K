#!/bin/sh

set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/scripts/common.sh"
mkdir -p "$DIST_DIR"

fetch_one() {
	name=$1 url=$2 expected=$3 dest_dir=${4:-$DIST_DIR}
	dst=$dest_dir/$name
	case "$url" in
		https://codeload.github.com/Openwrt-Passwall/*|https://codeload.github.com/XTLS/*|https://go.dev/dl/*|https://sources.openwrt.org/*|https://github.com/jirutka/luasrcdiet/archive/v1.0.0.tar.gz) ;;
		*) echo "refusing non-allowlisted source URL: $url" >&2; exit 1 ;;
	esac
	mkdir -p "$dest_dir"
	if [ -f "$dst" ] && [ "$(sha256_file "$dst")" = "$expected" ]; then
		echo "verified cached $name"
		return
	fi
	rm -f "$dst.part"
	curl --fail --location --proto '=https' --tlsv1.2 -o "$dst.part" "$url"
	require_equal "$name sha256" "$(sha256_file "$dst.part")" "$expected"
	mv "$dst.part" "$dst"
}

fetch_one "$PASSWALL_ARCHIVE" "$PASSWALL_ARCHIVE_URL" "$PASSWALL_ARCHIVE_SHA256"
fetch_one "$XRAY_ARCHIVE" "$XRAY_ARCHIVE_URL" "$XRAY_ARCHIVE_SHA256"
fetch_one "$GO_ARCHIVE" "$GO_ARCHIVE_URL" "$GO_ARCHIVE_SHA256"
"$HERE/verify-sources.sh"
