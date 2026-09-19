#!/bin/bash

set -euo pipefail
HERE=/bundle
. "$HERE/common.sh"

ARTIFACT_DIR=${1:?runtime release directory is required}
REPORT=${2:?runtime smoke report path is required}
QSDK=/qsdk
TARGET_STAGING=$QSDK/staging_dir/target-aarch64_cortex-a73+neon-vfpv4_musl
TOOLCHAIN=$QSDK/staging_dir/toolchain-aarch64_cortex-a73+neon-vfpv4_gcc-7.5.0_musl
LOADER=$TOOLCHAIN/lib/ld-musl-aarch64.so.1

[ -x "$LOADER" ] || fail "target musl loader is missing: $LOADER"
tmp=$(mktemp -d /tmp/sbe-luci-runtime-smoke.XXXXXX)
ubusd_pid=
cleanup() {
	if [ -n "$ubusd_pid" ]; then
		kill "$ubusd_pid" 2>/dev/null || true
		wait "$ubusd_pid" 2>/dev/null || true
	fi
	rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
root=$tmp/root
config=$tmp/config
state=$tmp/state
mkdir -p "$root" "$config" "$state"

for ipk in "$ARTIFACT_DIR"/*.ipk; do
	tar -xOzf "$ipk" ./data.tar.gz | tar -xzf - -C "$root"
done
[ -x "$root/usr/bin/lua" ] || fail 'source-built target Lua interpreter is missing'

printf "config interface 'lan'\n\toption proto 'static'\n\toption ipaddr '192.0.2.1'\n" > "$config/network"
libpath=$root/usr/lib:$TARGET_STAGING/usr/lib:$TARGET_STAGING/root-ipq95xx/lib:$TOOLCHAIN/lib
ubus_socket=$tmp/ubus.sock
ubusd=$TARGET_STAGING/usr/sbin/ubusd
[ -x "$ubusd" ] || fail 'locked target ubusd test daemon is missing'
"$LOADER" --library-path "$libpath" "$ubusd" -s "$ubus_socket" > "$tmp/ubusd.log" 2>&1 &
ubusd_pid=$!
for _ in $(seq 1 50); do
	[ -S "$ubus_socket" ] && break
	kill -0 "$ubusd_pid" 2>/dev/null || {
		cat "$tmp/ubusd.log" >&2
		fail 'target ubusd exited before creating its test socket'
	}
	sleep 0.02
done
[ -S "$ubus_socket" ] || fail 'target ubusd test socket was not created'

: > "$REPORT"
env -u LUA_PATH -u LUA_CPATH -u LUA_INIT \
	"$LOADER" --library-path "$libpath" "$root/usr/bin/lua" -e '
assert(_VERSION == "Lua 5.1")
assert(package.path:find("/usr/share/lua/?.lua", 1, true))
assert(package.cpath:find("/usr/lib/lua/?.so", 1, true))
assert(type(1) == "number")
assert(tostring(1) == "1")
assert(tonumber("2147483648") == 2147483648)
local source = assert(loadstring("return 2147483647 + 1"))
local loaded = assert(loadstring(string.dump(source)))
assert(loaded() == 2147483648)
print("lua_version=" .. _VERSION)
print("default_paths=openwrt-unversioned")
print("lnum_integer_boundary=pass")
print("bytecode_roundtrip=pass")
' >> "$REPORT"

LUA_CPATH="$root/usr/lib/lua/?.so" LUA_PATH=';;' LUA_INIT= \
	"$LOADER" --library-path "$libpath" "$root/usr/bin/lua" \
	"$HERE/tests/runtime-smoke.lua" "$config" "$state" "$ubus_socket" >> "$REPORT"

grep -F -q 'uci_read=pass' "$REPORT"
grep -F -q 'ubus_module=pass' "$REPORT"
grep -F -q 'iwinfo_module=pass' "$REPORT"
grep -F -q 'lua_cve_2014_5461=pass' "$REPORT"
grep -F -q 'lua_cve_2025_49844_gc_stress=pass' "$REPORT"
grep -F -q 'lua_unpack_overflow=pass' "$REPORT"
grep -F -q 'uci_lua_error_paths=pass' "$REPORT"
grep -F -q 'ubus_lua_invalid_object=pass' "$REPORT"
printf 'PASS: target Lua 5.1 semantics and uci/ubus/iwinfo module loading\n'
