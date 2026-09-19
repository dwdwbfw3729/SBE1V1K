#!/bin/sh
set -eu

candidate_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dist_dir=${1:-"$candidate_dir/distfiles"}
. "$candidate_dir/sources.lock"

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

verify_hash() {
	file=$1
	expected=$2
	[ -f "$dist_dir/$file" ] || fail "missing source input: $dist_dir/$file"
	actual=$(sha256_file "$dist_dir/$file")
	[ "$actual" = "$expected" ] || fail "$file SHA-256 mismatch: $actual"
}

verify_hash "$OPENSSL_ARCHIVE" "$OPENSSL_SHA256"
verify_hash "$OPENSSL_SIGNATURE" "$OPENSSL_SIGNATURE_SHA256"
verify_hash "$OPENSSL_CHECKSUM" "$OPENSSL_CHECKSUM_SHA256"
verify_hash "$OPENSSL_KEYRING" "$OPENSSL_KEYRING_SHA256"
verify_hash "$CURL_ARCHIVE" "$CURL_SHA256"
verify_hash "$CURL_SIGNATURE" "$CURL_SIGNATURE_SHA256"
verify_hash "$CURL_KEYRING" "$CURL_KEYRING_SHA256"

published=$(awk '{print $1; exit}' "$dist_dir/$OPENSSL_CHECKSUM")
[ "$published" = "$OPENSSL_SHA256" ] || fail "OpenSSL published checksum disagrees with lock"

check_archive_paths() {
	archive=$1
	top=$2
	case "$archive" in
		*.tar.gz) list=$(tar -tzf "$archive") ;;
		*.tar.xz) list=$(tar -tJf "$archive") ;;
		*) fail "unsupported source archive: $archive" ;;
	esac
	printf '%s\n' "$list" | awk -v top="$top" '
		BEGIN { bad=0 }
		/^\// { print "absolute archive path: " $0 > "/dev/stderr"; bad=1 }
		/(^|\/)\.\.($|\/)/ { print "parent traversal: " $0 > "/dev/stderr"; bad=1 }
		$0 !~ ("^" top "/") && $0 != top { print "wrong top directory: " $0 > "/dev/stderr"; bad=1 }
		END { exit bad }
	' || fail "unsafe or unexpected paths in $archive"
}

check_archive_paths "$dist_dir/$OPENSSL_ARCHIVE" "openssl-$OPENSSL_VERSION"
check_archive_paths "$dist_dir/$CURL_ARCHIVE" "curl-$CURL_VERSION"

if command -v gpgv >/dev/null 2>&1; then
	tmp=${TMPDIR:-/tmp}/sbe-tls-source-verify.$$
	mkdir -m 700 "$tmp"
	trap 'rm -rf "$tmp"' EXIT HUP INT TERM
	python3 "$candidate_dir/dearmor.py" "$dist_dir/$OPENSSL_KEYRING" "$tmp/openssl.gpg"
	python3 "$candidate_dir/dearmor.py" "$dist_dir/$CURL_KEYRING" "$tmp/curl.gpg"

	gpgv --status-fd=1 --keyring "$tmp/openssl.gpg" \
		"$dist_dir/$OPENSSL_SIGNATURE" "$dist_dir/$OPENSSL_ARCHIVE" \
		2>"$tmp/openssl.stderr" >"$tmp/openssl.status"
	grep -F "[GNUPG:] VALIDSIG $OPENSSL_SIGNING_SUBKEY " "$tmp/openssl.status" >/dev/null ||
		fail "OpenSSL signing subkey mismatch"
	grep -F " $OPENSSL_PRIMARY_KEY" "$tmp/openssl.status" >/dev/null ||
		fail "OpenSSL primary signing key mismatch"

	gpgv --status-fd=1 --keyring "$tmp/curl.gpg" \
		"$dist_dir/$CURL_SIGNATURE" "$dist_dir/$CURL_ARCHIVE" \
		2>"$tmp/curl.stderr" >"$tmp/curl.status"
	grep -F "[GNUPG:] VALIDSIG $CURL_SIGNING_KEY " "$tmp/curl.status" >/dev/null ||
		fail "curl signing key mismatch"
	printf 'PGP signatures: PASS\n'
else
	printf 'PGP signatures: SKIP (gpgv unavailable; run verify in the Linux container)\n'
fi

printf 'Source hashes and archive paths: PASS\n'

