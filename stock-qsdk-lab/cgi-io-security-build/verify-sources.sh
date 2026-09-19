#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$build_dir/sources.lock"

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

archive=$build_dir/distfiles/$CGI_IO_ARCHIVE
[ -f "$archive" ] || fail "missing locked source archive: $archive"
[ "$(sha256_file "$archive")" = "$CGI_IO_ARCHIVE_SHA256" ] || \
	fail 'cgi-io source archive SHA-256 mismatch'

trial_dir=$(mktemp -d "${TMPDIR:-/tmp}/sbe-cgi-io-source.XXXXXX")
cleanup() {
	rm -rf "$trial_dir"
}
trap cleanup EXIT HUP INT TERM
tar -xf "$archive" -C "$trial_dir"
source_dir=$trial_dir/cgi-io-$CGI_IO_COMMIT
[ -d "$source_dir" ] || fail 'source archive has an unexpected top-level directory'

[ "$(sha256_file "$source_dir/main.c")" = "$CGI_IO_MAIN_SHA256" ] || \
	fail 'main.c differs from the reviewed commit'
[ "$(sha256_file "$source_dir/util.c")" = "$CGI_IO_UTIL_SHA256" ] || \
	fail 'util.c differs from the reviewed commit'
[ "$(sha256_file "$source_dir/CMakeLists.txt")" = "$CGI_IO_CMAKE_SHA256" ] || \
	fail 'CMakeLists.txt differs from the reviewed commit'

[ "$(grep -c 'return failure(400, 0, "Invalid form data")' "$source_dir/main.c")" -eq 3 ] || \
	fail 'download, backup and exec do not all fail closed on malformed POST data'
grep -q 'canonicalize_path(fields\[3\], strlen(fields\[3\]))' "$source_dir/main.c" || \
	fail 'download path is not canonicalized before its ACL check'
grep -q 'canon = canonicalize_path(args\[0\], exelen)' "$source_dir/main.c" || \
	fail 'exec path is not canonicalized before its ACL check'
grep -F -q 'fields[(i * 2) + 1] = NULL;' "$source_dir/util.c" || \
	fail 'failed URL decoding leaves stale field pointers'

makefile=$build_dir/package-overlay/sbe-cgi-io2026-security-candidate/Makefile
grep -q "PKG_HASH:=$CGI_IO_ARCHIVE_SHA256" "$makefile" || \
	fail 'package recipe does not pin the reviewed source archive'
grep -F -q '$(1)/usr/libexec/cgi-io' "$makefile" || \
	fail 'candidate does not install exactly the CGI executable'

if grep -R -n -E '/Users/|/home/|BEGIN [A-Z ]*PRIVATE KEY|authorized_keys|password' \
	"$build_dir/sources.lock" "$build_dir/package-overlay" >/dev/null 2>&1; then
	fail 'source policy contains a host path or credential marker'
fi

printf 'PASS: locked cgi-io 31cb3c89 source contains all 2026 security fixes\n'
