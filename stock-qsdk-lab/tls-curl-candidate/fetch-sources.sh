#!/bin/sh
set -eu

candidate_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dist_dir=${1:-"$candidate_dir/distfiles"}
. "$candidate_dir/sources.lock"
mkdir -p "$dist_dir"

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
	if [ -f "$dist_dir/$name" ] && [ "$(sha256_file "$dist_dir/$name")" = "$expected" ]; then
		printf 'verified cached %s\n' "$name"
		return
	fi
	tmp="$dist_dir/.$name.part.$$"
	trap 'rm -f "$tmp"' EXIT HUP INT TERM
	curl --proto '=https' --tlsv1.2 --fail --location --retry 3 \
		--connect-timeout 20 --output "$tmp" "$url"
	actual=$(sha256_file "$tmp")
	[ "$actual" = "$expected" ] || {
		printf 'ERROR: %s SHA-256 mismatch: %s\n' "$name" "$actual" >&2
		exit 1
	}
	mv "$tmp" "$dist_dir/$name"
	trap - EXIT HUP INT TERM
}

fetch_one "$OPENSSL_ARCHIVE" "$OPENSSL_URL" "$OPENSSL_SHA256"
fetch_one "$OPENSSL_SIGNATURE" "$OPENSSL_SIGNATURE_URL" "$OPENSSL_SIGNATURE_SHA256"
fetch_one "$OPENSSL_CHECKSUM" "$OPENSSL_CHECKSUM_URL" "$OPENSSL_CHECKSUM_SHA256"
fetch_one "$OPENSSL_KEYRING" "$OPENSSL_KEYRING_URL" "$OPENSSL_KEYRING_SHA256"
fetch_one "$CURL_ARCHIVE" "$CURL_URL" "$CURL_SHA256"
fetch_one "$CURL_SIGNATURE" "$CURL_SIGNATURE_URL" "$CURL_SIGNATURE_SHA256"
fetch_one "$CURL_KEYRING" "$CURL_KEYRING_URL" "$CURL_KEYRING_SHA256"

"$candidate_dir/verify-sources.sh" "$dist_dir"

