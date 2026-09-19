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

archive=$build_dir/distfiles/$LUCIHTTP_ARCHIVE
[ -f "$archive" ] || fail "missing locked source archive: $archive"
[ "$(sha256_file "$archive")" = "$LUCIHTTP_ARCHIVE_SHA256" ] || \
	fail 'lucihttp source archive SHA-256 mismatch'

trial_dir=$(mktemp -d "${TMPDIR:-/tmp}/sbe-lucihttp-source.XXXXXX")
cleanup() {
	rm -rf "$trial_dir"
}
trap cleanup EXIT HUP INT TERM
tar -xf "$archive" -C "$trial_dir"
source_dir=$trial_dir/lucihttp-2023-03-15-9b5b683f
[ -d "$source_dir" ] || fail 'source archive has an unexpected top-level directory'

[ "$(sha256_file "$source_dir/CMakeLists.txt")" = "$LUCIHTTP_CMAKE_SHA256" ] || \
	fail 'CMakeLists.txt differs from the reviewed commit'
[ "$(sha256_file "$source_dir/lib/multipart-parser.c")" = "$LUCIHTTP_MULTIPART_SHA256" ] || \
	fail 'multipart parser differs from the reviewed commit'
[ "$(sha256_file "$source_dir/lib/urlencoded-parser.c")" = "$LUCIHTTP_URLENCODED_SHA256" ] || \
	fail 'URL-encoded parser differs from the reviewed commit'
[ "$(sha256_file "$source_dir/lib/utils.c")" = "$LUCIHTTP_UTILS_SHA256" ] || \
	fail 'HTTP utility source differs from the reviewed commit'
[ "$(sha256_file "$source_dir/lib/lua.c")" = "$LUCIHTTP_LUA_SHA256" ] || \
	fail 'Lua binding differs from the reviewed commit'

grep -q 'SOVERSION 0' "$source_dir/CMakeLists.txt" || \
	fail 'locked source no longer declares liblucihttp SONAME ABI 0'
grep -q 'VERSION 0.1' "$source_dir/CMakeLists.txt" || \
	fail 'locked source no longer declares liblucihttp version 0.1'
grep -q 'LUALIB_API int luaopen_lucihttp' "$source_dir/lib/lua.c" || \
	fail 'locked Lua binding no longer exports luaopen_lucihttp'

makefile=$build_dir/package-overlay/sbe-lucihttp2023-security-candidate/Makefile
grep -q "PKG_HASH:=$LUCIHTTP_ARCHIVE_SHA256" "$makefile" || \
	fail 'package recipe does not pin the reviewed source archive'
grep -q -- '-DBUILD_UCODE=OFF' "$makefile" || \
	fail 'unsupported ucode binding is not disabled'
grep -q -- '-DBUILD_TESTS=OFF' "$makefile" || \
	fail 'test executables must not be packaged'
grep -F -q '$(PKG_INSTALL_DIR)/usr/lib/liblucihttp.so.*' "$makefile" || \
	fail 'core candidate does not select only the ABI 0 runtime library'
grep -F -q '$(PKG_INSTALL_DIR)/usr/lib/lua/lucihttp.so' "$makefile" || \
	fail 'Lua candidate does not select the Lua 5.1 runtime binding'

if grep -R -n -E '/Users/|/home/|BEGIN [A-Z ]*PRIVATE KEY|authorized_keys|password' \
	"$build_dir/sources.lock" "$build_dir/package-overlay" >/dev/null 2>&1; then
	fail 'source policy contains a host path or credential marker'
fi

printf 'PASS: locked lucihttp 9b5b683f source and ABI-0/Lua package policy\n'
