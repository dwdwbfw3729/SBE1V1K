#!/bin/sh
set -eu

candidate_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$candidate_dir/sources.lock"
dist=$candidate_dir/distfiles
archive=$dist/$COREUTILS_ARCHIVE
mkdir -p "$dist"

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

if [ ! -f "$archive" ]; then
	curl -fL --retry 2 --connect-timeout 15 --max-time 180 \
		--proto '=https' --proto-redir '=https' \
		"https://ftp.gnu.org/gnu/coreutils/$COREUTILS_ARCHIVE" \
		-o "$archive.part"
	mv "$archive.part" "$archive"
fi

actual=$(sha256_file "$archive")
[ "$actual" = "$COREUTILS_ARCHIVE_SHA256" ] || {
	printf 'ERROR: coreutils archive checksum mismatch: %s\n' "$actual" >&2
	exit 1
}
printf '%s  %s\n' "$actual" "$COREUTILS_ARCHIVE"

fetch_build_dependency() {
	name=$1
	digest=$2
	url=$3
	path=$dist/$name
	if [ ! -f "$path" ]; then
		curl -fL --retry 2 --connect-timeout 15 --max-time 180 \
			--proto '=https' --proto-redir '=https' "$url" -o "$path.part"
		mv "$path.part" "$path"
	fi
	actual=$(sha256_file "$path")
	[ "$actual" = "$digest" ] || {
		printf 'ERROR: build-dependency archive checksum mismatch: %s\n' "$name" >&2
		exit 1
	}
	printf '%s  %s\n' "$actual" "$name"
}

fetch_build_dependency "$ATTR_ARCHIVE" "$ATTR_ARCHIVE_SHA256" \
	"https://sources.openwrt.org/$ATTR_ARCHIVE"
fetch_build_dependency "$ACL_ARCHIVE" "$ACL_ARCHIVE_SHA256" \
	"https://sources.openwrt.org/$ACL_ARCHIVE"
