#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$build_dir/sources.lock"

destination=${1:-"$build_dir/cache"}
mkdir -p "$destination"

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

fetch_one() {
	name=$1
	url=$2
	expected=$3
	target=$destination/$name

	if [ -f "$target" ] && [ "$(sha256_file "$target")" = "$expected" ]; then
		printf 'PASS  cached %s\n' "$name"
		return
	fi

	temporary=$target.part.$$
	rm -f "$temporary"
	trap 'rm -f "$temporary"' EXIT HUP INT TERM
	curl -fL --retry 3 --retry-all-errors --connect-timeout 20 \
		"$url" -o "$temporary"
	actual=$(sha256_file "$temporary")
	[ "$actual" = "$expected" ] || {
		printf 'ERROR: %s SHA-256 is %s, expected %s\n' \
			"$name" "$actual" "$expected" >&2
		exit 1
	}
	mv "$temporary" "$target"
	trap - EXIT HUP INT TERM
	printf 'PASS  fetched %s\n' "$name"
}

fetch_one "$MINIUPNPD_ARCHIVE" "$MINIUPNPD_URL" "$MINIUPNPD_SHA256"
fetch_one "$NTFS3G_ARCHIVE" "$NTFS3G_URL" "$NTFS3G_SHA256"
fetch_one "$NTP_ARCHIVE" "$NTP_URL" "$NTP_SHA256"
