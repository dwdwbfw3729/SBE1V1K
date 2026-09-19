#!/bin/sh
set -eu

candidate_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$candidate_dir/sources.lock"
cache_dir=${LOGD_SOURCE_CACHE:-"$candidate_dir/cache"}
archive=$cache_dir/$UBOX_ARCHIVE

mkdir -p "$cache_dir"
if [ -f "$archive" ] && printf '%s  %s\n' "$UBOX_SHA256" "$archive" | shasum -a 256 -c - >/dev/null 2>&1; then
	printf 'Source already verified: %s\n' "$archive"
	exit 0
fi

tmp=$archive.tmp.$$
trap 'rm -f "$tmp"' EXIT HUP INT TERM
curl --fail --location --proto '=https' --tlsv1.2 \
	--output "$tmp" "$UBOX_SOURCE_URL"
printf '%s  %s\n' "$UBOX_SHA256" "$tmp" | shasum -a 256 -c -
mv "$tmp" "$archive"
trap - EXIT HUP INT TERM
printf 'Fetched and verified: %s\n' "$archive"

