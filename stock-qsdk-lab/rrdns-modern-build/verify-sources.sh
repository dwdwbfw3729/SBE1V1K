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

archive=$build_dir/distfiles/$LUCI_ARCHIVE
repo=$build_dir/sources/luci
package_source=$repo/libs/rpcd-mod-rrdns
acl=$repo/modules/luci-mod-status/root/usr/share/rpcd/acl.d/luci-mod-status.json
compat_patch=$build_dir/package-overlay/sbe-rpcd-mod-rrdns20170710-modern-candidate/patches/100-cmake-minimum-for-qsdk.patch
hardening_patch=$build_dir/package-overlay/sbe-rpcd-mod-rrdns20170710-modern-candidate/patches/110-validate-address-array-and-local-resolver.patch
abi_patch=$build_dir/package-overlay/sbe-rpcd-mod-rrdns20170710-modern-candidate/patches/120-use-locked-minimal-rpcd-abi-header.patch
abi_header=$build_dir/package-overlay/sbe-rpcd-mod-rrdns20170710-modern-candidate/files/rpcd-plugin-abi.h
recipe=$build_dir/package-overlay/sbe-rpcd-mod-rrdns20170710-modern-candidate/Makefile

[ -f "$archive" ] || fail "missing locked source archive: $archive"
[ "$(sha256_file "$archive")" = "$LUCI_ARCHIVE_SHA256" ] ||
	fail 'locked source archive SHA-256 mismatch'
[ -d "$repo/.git" ] || fail 'official LuCI checkout is missing Git metadata'
[ "$(git -C "$repo" remote)" = origin ] ||
	fail 'LuCI checkout must have exactly one remote named origin'
[ "$(git -C "$repo" config --get remote.origin.url)" = "$LUCI_ORIGIN" ] ||
	fail 'LuCI checkout origin differs from the official locked URL'
[ ! -f "$repo/.gitmodules" ] || fail 'LuCI checkout unexpectedly uses submodules'
[ -z "$(git -C "$repo" status --porcelain=v1 --untracked-files=all)" ] ||
	fail 'LuCI checkout is not clean'
[ "$(git -C "$repo" rev-parse HEAD)" = "$LUCI_COMMIT" ] ||
	fail 'LuCI checkout HEAD differs from the locked commit'
[ "$(git -C "$repo" rev-parse "$LUCI_COMMIT^{tree}")" = "$LUCI_TREE" ] ||
	fail 'LuCI checkout tree differs from the lock'
git -C "$repo" show-ref --verify --quiet refs/remotes/origin/master ||
	fail 'LuCI checkout lacks origin/master'
git -C "$repo" merge-base --is-ancestor "$LUCI_COMMIT" refs/remotes/origin/master ||
	fail 'locked LuCI commit is not reachable from official origin/master'

[ "$(sha256_file "$package_source/Makefile")" = "$RRDNS_MAKEFILE_SHA256" ] ||
	fail 'official rpcd-mod-rrdns package Makefile differs from the reviewed commit'
[ "$(sha256_file "$package_source/src/CMakeLists.txt")" = "$RRDNS_CMAKE_SHA256" ] ||
	fail 'official CMakeLists.txt differs from the reviewed commit'
[ "$(sha256_file "$package_source/src/rrdns.c")" = "$RRDNS_C_SHA256" ] ||
	fail 'official rrdns.c differs from the reviewed commit'
[ "$(sha256_file "$package_source/src/rrdns.h")" = "$RRDNS_H_SHA256" ] ||
	fail 'official rrdns.h differs from the reviewed commit'
[ "$(sha256_file "$acl")" = "$RRDNS_ACL_SHA256" ] ||
	fail 'official LuCI status ACL differs from the reviewed commit'
[ "$(sha256_file "$repo/LICENSE")" = "$LUCI_LICENSE_SHA256" ] ||
	fail 'official LuCI Apache-2.0 license context differs from the reviewed commit'
[ "$(sha256_file "$repo/NOTICE")" = "$LUCI_NOTICE_SHA256" ] ||
	fail 'official LuCI notice context differs from the reviewed commit'
[ "$(sha256_file "$compat_patch")" = "$RRDNS_CMAKE_COMPAT_PATCH_SHA256" ] ||
	fail 'local QSDK CMake compatibility patch differs from the lock'
[ "$(sha256_file "$hardening_patch")" = "$RRDNS_HARDENING_PATCH_SHA256" ] ||
	fail 'local rrdns input/endpoint hardening patch differs from the lock'
[ "$(sha256_file "$abi_patch")" = "$RRDNS_ABI_INCLUDE_PATCH_SHA256" ] ||
	fail 'local rpcd ABI include patch differs from the lock'
[ "$(sha256_file "$abi_header")" = "$RRDNS_MINIMAL_ABI_HEADER_SHA256" ] ||
	fail 'minimal rpcd plugin ABI header differs from the lock'

tmp=$(mktemp -d "${TMPDIR:-/tmp}/sbe-rrdns-source.XXXXXX")
cleanup() {
	case "$tmp" in
		*/sbe-rrdns-source.*)
			rm -rf "$tmp"
			;;
	esac
}
trap cleanup EXIT HUP INT TERM

regenerated=$tmp/$LUCI_ARCHIVE
git -C "$repo" -c tar.umask=0002 archive --format=tar \
	--prefix="luci-$LUCI_COMMIT/" \
	-o "$regenerated" "$LUCI_COMMIT" libs/rpcd-mod-rrdns/src
[ "$(sha256_file "$regenerated")" = "$LUCI_ARCHIVE_SHA256" ] ||
	fail 'deterministic official Git subtree archive differs from the lock'
cmp -s "$regenerated" "$archive" ||
	fail 'locked archive is not byte-identical to the official Git subtree archive'

tar tf "$archive" | LC_ALL=C sort > "$tmp/archive-list"
{
	prefix=luci-$LUCI_COMMIT
	printf '%s/\n' "$prefix"
	printf '%s/libs/\n' "$prefix"
	printf '%s/libs/rpcd-mod-rrdns/\n' "$prefix"
	printf '%s/libs/rpcd-mod-rrdns/src/\n' "$prefix"
	printf '%s/libs/rpcd-mod-rrdns/src/CMakeLists.txt\n' "$prefix"
	printf '%s/libs/rpcd-mod-rrdns/src/rrdns.c\n' "$prefix"
	printf '%s/libs/rpcd-mod-rrdns/src/rrdns.h\n' "$prefix"
} | LC_ALL=C sort > "$tmp/expected-list"
cmp -s "$tmp/archive-list" "$tmp/expected-list" ||
	fail 'source archive contains members outside the reviewed three-file source subtree'

tar -xf "$archive" -C "$tmp"
archive_root=$tmp/luci-$LUCI_COMMIT
source_dir=$archive_root/libs/rpcd-mod-rrdns/src
[ -d "$source_dir" ] || fail 'source archive has an unexpected top-level directory'
[ "$(sha256_file "$source_dir/CMakeLists.txt")" = "$RRDNS_CMAKE_SHA256" ] ||
	fail 'archived CMakeLists.txt differs from the reviewed snapshot'
[ "$(sha256_file "$source_dir/rrdns.c")" = "$RRDNS_C_SHA256" ] ||
	fail 'archived rrdns.c differs from the reviewed snapshot'
[ "$(sha256_file "$source_dir/rrdns.h")" = "$RRDNS_H_SHA256" ] ||
	fail 'archived rrdns.h differs from the reviewed snapshot'

grep -qxF "PKG_VERSION:=$RRDNS_PKG_VERSION" "$package_source/Makefile" ||
	fail 'official package version is no longer the locked 20170710 value'
grep -qxF '  DEPENDS:=+rpcd +libubox +libubus' "$package_source/Makefile" ||
	fail 'official rpcd/libubox/libubus dependencies changed'
grep -F -q '$(INSTALL_BIN) $(PKG_BUILD_DIR)/rrdns.so $(1)/usr/lib/rpcd/' \
	"$package_source/Makefile" || fail 'official module install path changed'

grep -qxF '#define RRDNS_MAX_TIMEOUT 5000' "$source_dir/rrdns.h" ||
	fail 'maximum global timeout is no longer 5000 ms'
grep -qxF '#define RRDNS_DEF_TIMEOUT 250' "$source_dir/rrdns.h" ||
	fail 'default global timeout is no longer 250 ms'
grep -qxF '#define RRDNS_MAX_LIMIT 1000' "$source_dir/rrdns.h" ||
	fail 'maximum address limit is no longer 1000'
grep -qxF '#define RRDNS_DEF_LIMIT 10' "$source_dir/rrdns.h" ||
	fail 'default address limit is no longer 10'
grep -F -q 'if (limit <= 0 || limit > RRDNS_MAX_LIMIT)' "$source_dir/rrdns.c" ||
	fail 'address limit range check is missing'
grep -F -q 'if (timeout <= 0 || timeout > RRDNS_MAX_TIMEOUT)' "$source_dir/rrdns.c" ||
	fail 'timeout range check is missing'
grep -F -q 'uloop_timeout_set(&rctx->timeout, timeout);' "$source_dir/rrdns.c" ||
	fail 'global timeout is not armed on the deferred request'
grep -F -q 'while (limit--)' "$source_dir/rrdns.c" ||
	fail 'address processing is no longer bounded by limit'
grep -F -q 'unsigned char res[512];' "$source_dir/rrdns.c" ||
	fail 'reviewed 512-byte UDP DNS response bound changed'
grep -F -q '[RPC_L_ADDRS]   = { .name = "addrs",   .type = BLOBMSG_TYPE_ARRAY  }' \
	"$source_dir/rrdns.c" || fail 'outer addrs blob policy changed'
grep -F -q '[RPC_L_SERVER]  = { .name = "server",  .type = BLOBMSG_TYPE_STRING }' \
	"$source_dir/rrdns.c" || fail 'server blob policy changed'
grep -F -q '[RPC_L_PORT]    = { .name = "port",    .type = BLOBMSG_TYPE_INT16  }' \
	"$source_dir/rrdns.c" || fail 'port blob policy changed'
grep -F -q 'addr = blobmsg_get_string(rctx->addr_cur);' "$source_dir/rrdns.c" ||
	fail 'reviewed array-element handling changed; repeat the input audit'
if grep -E 'blobmsg_(type|check_attr).*rctx->addr_cur' "$source_dir/rrdns.c" >/dev/null 2>&1; then
	fail 'array element validation changed; repeat the input audit and update the lock'
fi
grep -F -q 'rctx->socket.fd = usock(USOCK_UDP, server, usock_port(port));' \
	"$source_dir/rrdns.c" || fail 'custom DNS server/port behavior changed'
grep -F -q 'UBUS_METHOD("lookup", rpc_rrdns_lookup, rpc_lookup_policy)' \
	"$source_dir/rrdns.c" || fail 'lookup method registration changed'
grep -F -q '.name = "network.rrdns"' "$source_dir/rrdns.c" ||
	fail 'network.rrdns object registration changed'
grep -F -q 'rpc_rrdns_api_init(const struct rpc_daemon_ops *o, struct ubus_context *ctx)' \
	"$source_dir/rrdns.c" || fail 'stock rpcd plugin init signature changed'
grep -F -q '.init = rpc_rrdns_api_init' "$source_dir/rrdns.c" ||
	fail 'stock rpcd plugin initializer changed'

[ "$(grep -F -c '"network.rrdns": [ "lookup" ]' "$acl")" -eq 1 ] ||
	fail 'LuCI status ACL is not the exact single network.rrdns lookup grant'

patch --dry-run -s -p1 -d "$archive_root" < "$compat_patch" ||
	fail 'CMake compatibility patch no longer applies cleanly'
patch -s -p1 -d "$archive_root" < "$compat_patch"
grep -qxF 'cmake_minimum_required(VERSION 3.10)' "$source_dir/CMakeLists.txt" ||
	fail 'CMake compatibility patch did not produce the reviewed baseline'
[ "$(sha256_file "$source_dir/rrdns.c")" = "$RRDNS_C_SHA256" ] ||
	fail 'build compatibility patch unexpectedly modified rrdns.c'

patch --dry-run -s -p1 -d "$archive_root" < "$hardening_patch" ||
	fail 'rrdns input/endpoint hardening patch no longer applies cleanly'
patch -s -p1 -d "$archive_root" < "$hardening_patch"
grep -F -q 'blobmsg_check_array(tb[RPC_L_ADDRS], BLOBMSG_TYPE_STRING) < 0' \
	"$source_dir/rrdns.c" || fail 'patched source does not validate address element types'
grep -F -q 'if (tb[RPC_L_SERVER] || tb[RPC_L_PORT])' "$source_dir/rrdns.c" ||
	fail 'patched source does not reject custom DNS endpoints'
grep -F -q 'usock(USOCK_UDP, server, usock_port(53))' "$source_dir/rrdns.c" ||
	fail 'patched source does not constrain DNS requests to port 53'

patch --dry-run -s -p1 -d "$archive_root" < "$abi_patch" ||
	fail 'minimal rpcd ABI include patch no longer applies cleanly'
patch -s -p1 -d "$archive_root" < "$abi_patch"
[ "$(sha256_file "$source_dir/rrdns.c")" = "$RRDNS_PATCHED_C_SHA256" ] ||
	fail 'patched rrdns.c differs from the independently locked result'
grep -F -q '#include "rpcd-plugin-abi.h"' "$source_dir/rrdns.c" ||
	fail 'patched source does not use the locked minimal rpcd ABI header'
grep -qxF 'struct rpc_daemon_ops;' "$abi_header" ||
	fail 'minimal ABI header does not keep rpc_daemon_ops opaque'
grep -Eq '^[[:space:]]+struct list_head list;$' "$abi_header" ||
	fail 'minimal ABI header does not begin with the stock list node'
grep -Eq '^[[:space:]]+int \(\*init\)\(const struct rpc_daemon_ops \*ops, struct ubus_context \*ctx\);$' \
	"$abi_header" || fail 'minimal ABI header has a different init callback signature'
[ "$(sha256_file "$source_dir/rrdns.h")" = "$RRDNS_H_SHA256" ] ||
	fail 'local patches unexpectedly modified rrdns.h'

grep -F -q "PKG_HASH:=$LUCI_ARCHIVE_SHA256" "$recipe" ||
	fail 'candidate recipe does not pin the reviewed source archive'
grep -qxF '  SOURCE:=$(PKG_SOURCE)' "$recipe" ||
	fail 'candidate package metadata does not bind Source to the locked archive'
grep -qxF '  DEPENDS:=+rpcd +libubox +libubus' "$recipe" ||
	fail 'candidate recipe does not retain the official dependencies'
grep -F -q '$(INSTALL_BIN) $(PKG_BUILD_DIR)/rrdns.so $(1)/usr/lib/rpcd/rrdns.so' \
	"$recipe" || fail 'candidate recipe does not install the one canonical module path'
grep -F -q '$(CP) ./files/rpcd-plugin-abi.h $(PKG_BUILD_DIR)/$(CMAKE_SOURCE_SUBDIR)/rpcd-plugin-abi.h' \
	"$recipe" || fail 'candidate recipe does not stage the locked minimal ABI header'

if grep -R -n -E '/Users/|/home/|BEGIN [A-Z0-9 ]*PRIVATE KEY|OPENSSH PRIVATE KEY|authorized_keys' \
	"$build_dir/sources.lock" "$build_dir/package-overlay" \
	>/dev/null 2>&1; then
	fail 'locked source policy contains a host path or credential marker'
fi

printf 'PASS: official LuCI %s rpcd-mod-rrdns source, bounds, ACL context, archive and local patches are hash locked\n' \
	"$LUCI_COMMIT"
