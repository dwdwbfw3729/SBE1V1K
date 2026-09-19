#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$build_dir/sources.lock"

source_dir=${1:-"$build_dir/cache"}

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

verify_one() {
	name=$1
	expected=$2
	path=$source_dir/$name
	[ -f "$path" ] || {
		printf 'ERROR: missing source archive: %s\n' "$path" >&2
		exit 1
	}
	actual=$(sha256_file "$path")
	[ "$actual" = "$expected" ] || {
		printf 'ERROR: %s SHA-256 is %s, expected %s\n' \
			"$name" "$actual" "$expected" >&2
		exit 1
	}
	printf 'PASS  %s %s\n' "$name" "$actual"
}

verify_one "$MINIUPNPD_ARCHIVE" "$MINIUPNPD_SHA256"
verify_one "$NTFS3G_ARCHIVE" "$NTFS3G_SHA256"
verify_one "$NTP_ARCHIVE" "$NTP_SHA256"
