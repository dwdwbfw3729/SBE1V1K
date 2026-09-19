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

archive=$build_dir/distfiles/$UBUS_ARCHIVE
[ -f "$archive" ] || fail "missing locked source archive: $archive"
[ "$(sha256_file "$archive")" = "$UBUS_ARCHIVE_SHA256" ] || \
	fail 'ubus source archive SHA-256 mismatch'

trial_dir=$(mktemp -d "${TMPDIR:-/tmp}/sbe-ubus-source.XXXXXX")
cleanup() {
	rm -rf "$trial_dir"
}
trap cleanup EXIT HUP INT TERM

(cd "$build_dir" && while read -r expected relative; do
	[ -n "$expected" ] || continue
	[ "$(sha256_file "$relative")" = "$expected" ] || \
		fail "patch SHA-256 mismatch: $relative"
done < patches.lock)

patch_count=$(wc -l < "$build_dir/patches.lock" | tr -d ' ')
[ "$patch_count" = "$UBUS_PATCH_COUNT" ] ||
	fail "locked patch count changed: $patch_count"
provenance=$build_dir/patch-provenance.lock.tsv
[ "$(sha256_file "$provenance")" = "$UBUS_PATCH_PROVENANCE_SHA256" ] ||
	fail 'patch provenance register SHA-256 mismatch'
awk -F '\t' '!/^#/ { print "package-overlay/sbe-ubus2022-security-candidate/patches/" $1 }' \
	"$provenance" | LC_ALL=C sort > "$trial_dir.provenance"
awk '{print $2}' "$build_dir/patches.lock" | LC_ALL=C sort > "$trial_dir.locked-provenance"
cmp -s "$trial_dir.provenance" "$trial_dir.locked-provenance" ||
	fail 'patch provenance register and patches.lock are not an exact set'
[ "$(awk -F '\t' '!/^#/ && $2 == "exact-backport" { n++ } END { print n + 0 }' "$provenance")" -eq 22 ] ||
	fail 'exact-backport provenance count changed'
[ "$(awk -F '\t' '!/^#/ && $2 == "baseline-adaptation" { n++ } END { print n + 0 }' "$provenance")" -eq 5 ] ||
	fail 'baseline-adaptation provenance count changed'
find "$build_dir/package-overlay/sbe-ubus2022-security-candidate/patches" \
	-maxdepth 1 -type f -name '*.patch' -print | sed "s#^$build_dir/##" | \
	LC_ALL=C sort > "$trial_dir.files" 2>/dev/null || true
awk '{print $2}' "$build_dir/patches.lock" | LC_ALL=C sort > "$trial_dir.locked" 2>/dev/null || true
cmp -s "$trial_dir.files" "$trial_dir.locked" ||
	fail 'patch directory and patches.lock are not an exact set'

composite=$({
	printf '%s\n' "$UBUS_BASE_COMMIT"
	cat "$build_dir/patches.lock"
} | {
		if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi
	} | awk '{print $1}')
[ "$composite" = "$UBUS_COMPOSITE_SOURCE_REVISION" ] || \
	fail 'composite source revision is inconsistent'

tar -xf "$archive" -C "$trial_dir"
source_dir=$trial_dir/ubus-2022-02-21-b32a0e17
[ -d "$source_dir" ] || fail 'source archive has an unexpected top-level directory'

while read -r expected relative; do
	[ -n "$expected" ] || continue
	patch -d "$source_dir" -p1 --forward --batch < "$build_dir/$relative" >/dev/null || \
		fail "patch does not apply exactly once: $relative"
done < "$build_dir/patches.lock"

[ "$(sha256_file "$source_dir/libubus.c")" = "$UBUS_PATCHED_LIBUBUS_SHA256" ] || \
	fail 'patched libubus.c does not match the reviewed result'
[ "$(sha256_file "$source_dir/libubus-io.c")" = "$UBUS_PATCHED_LIBUBUS_IO_SHA256" ] || \
	fail 'patched libubus-io.c does not match the reviewed result'
[ "$(sha256_file "$source_dir/libubus-req.c")" = "$UBUS_PATCHED_LIBUBUS_REQ_SHA256" ] || \
	fail 'patched libubus-req.c does not match the reviewed result'
[ "$(sha256_file "$source_dir/libubus-acl.c")" = "$UBUS_PATCHED_LIBUBUS_ACL_SHA256" ] || \
	fail 'patched libubus-acl.c does not match the reviewed result'
[ "$(sha256_file "$source_dir/ubusd.c")" = "$UBUS_PATCHED_DAEMON_SHA256" ] || \
	fail 'patched ubusd.c does not match the reviewed result'
[ "$(sha256_file "$source_dir/ubusd.h")" = "$UBUS_PATCHED_DAEMON_HEADER_SHA256" ] || \
	fail 'patched ubusd.h does not match the reviewed result'
[ "$(sha256_file "$source_dir/ubusd_acl.c")" = "$UBUS_PATCHED_ACL_SHA256" ] || \
	fail 'patched ubusd_acl.c does not match the reviewed result'
[ "$(sha256_file "$source_dir/ubusd_event.c")" = "$UBUS_PATCHED_EVENT_SHA256" ] || \
	fail 'patched ubusd_event.c does not match the reviewed result'
[ "$(sha256_file "$source_dir/ubusd_main.c")" = "$UBUS_PATCHED_MAIN_SHA256" ] || \
	fail 'patched ubusd_main.c does not match the reviewed result'
[ "$(sha256_file "$source_dir/ubusd_monitor.c")" = "$UBUS_PATCHED_MONITOR_SHA256" ] || \
	fail 'patched ubusd_monitor.c does not match the reviewed result'
[ "$(sha256_file "$source_dir/ubusd_obj.c")" = "$UBUS_PATCHED_OBJ_SHA256" ] || \
	fail 'patched ubusd_obj.c does not match the reviewed result'
[ "$(sha256_file "$source_dir/ubusd_proto.c")" = "$UBUS_PATCHED_PROTO_SHA256" ] || \
	fail 'patched ubusd_proto.c does not match the reviewed result'

grep -q 'if (!msg)' "$source_dir/ubusd_event.c" || \
	fail 'NULL event-data guard is absent'
grep -q 'if (!len)' "$source_dir/ubusd_event.c" || \
	fail 'CVE-2025-62526 empty-event guard is absent'
grep -q 'if (!len)' "$source_dir/ubusd_acl.c" || \
	fail 'empty ACL-pattern guard is absent'
grep -q 'if (!len)' "$source_dir/ubusd_proto.c" || \
	fail 'empty lookup-pattern guard is absent'
grep -q 'if (ubusd_acl_check(cl, pattern, NULL, UBUS_ACL_LISTEN))' \
	"$source_dir/ubusd_event.c" || fail 'wildcard listen ACL fix is absent'
if grep -q 'if (pattern\[0\] && ubusd_acl_check' "$source_dir/ubusd_event.c"; then
	fail 'vulnerable wildcard listen ACL bypass remains'
fi
grep -q 'uloop_fd_delete(&ctx->sock);' "$source_dir/libubus.c" ||
	fail 'libubus teardown still leaves a registered uloop fd'
grep -q 'ctx->sock.fd = -1;' "$source_dir/libubus.c" ||
	fail 'libubus shutdown is not idempotent'
grep -q 'ctx->msgbuf.data = NULL;' "$source_dir/libubus.c" ||
	fail 'libubus shutdown retains a freed message pointer'
grep -q 'if (!pending)' "$source_dir/libubus.c" ||
	fail 'queued-message OOM guard is absent'
grep -q 'struct blob_attr \*new_blob = blob_memdup(msg);' "$source_dir/libubus-acl.c" ||
	fail 'ACL refresh does not allocate stable state before freeing old state'
grep -q 'fcntl(ctx->sock.fd, F_SETFD, FD_CLOEXEC)' "$source_dir/libubus-io.c" ||
	fail 'ubus socket FD_CLOEXEC fix is absent'
grep -q 'recv_fd = -1;' "$source_dir/libubus-io.c" ||
	fail 'received descriptor ownership reset is absent'
grep -q 'if (fd >= 0)' "$source_dir/libubus-req.c" ||
	fail 'request descriptor cleanup is absent'
grep -q 'static int sighup_pipe\[2\]' "$source_dir/ubusd_main.c" ||
	fail 'async-signal-safe ACL reload bridge is absent'
grep -q 'ssize_t txq_len;' "$source_dir/ubusd.h" ||
	fail 'partial-write queue length remains unsigned'
grep -q 'if (!ubl->msg)' "$source_dir/ubusd.c" ||
	fail 'queued message reference OOM guard is absent'
grep -q 'delete_no_retmsg:' "$source_dir/ubusd_proto.c" ||
	fail 'new-client resource cleanup labels are absent'
grep -q 'size_t len = strlen(obj);' "$source_dir/ubusd_acl.c" ||
	fail 'ACL allocation length still has variadic type mismatch'

makefile=$build_dir/package-overlay/sbe-ubus2022-security-candidate/Makefile
grep -q "PKG_HASH:=$UBUS_ARCHIVE_SHA256" "$makefile" || \
	fail 'package recipe does not pin the reviewed archive'
grep -q "PKG_ABI_VERSION:=$UBUS_ABI_VERSION" "$makefile" || \
	fail 'package recipe changes the factory libubus ABI version'
grep -q "PKG_VERSION:=$UBUS_PACKAGE_VERSION" "$makefile" || \
	fail 'package recipe version differs from the locked candidate version'
grep -q "PKG_RELEASE:=$UBUS_PACKAGE_RELEASE" "$makefile" || \
	fail 'package recipe release differs from the locked candidate release'
grep -q 'BuildPackage,sbe-libubus-lua2022-comparison-only' "$makefile" ||
	fail 'the local Lua artifact is not explicitly comparison-only'
grep -q -- '-DBUILD_EXAMPLES=OFF' "$makefile" || \
	fail 'package recipe unexpectedly builds examples'

if grep -R -n -E '/Users/|/home/|BEGIN [A-Z ]*PRIVATE KEY|authorized_keys|password' \
	"$build_dir/sources.lock" "$build_dir/patches.lock" \
	"$build_dir/package-overlay" >/dev/null 2>&1; then
	fail 'source policy contains a host path or credential marker'
fi

printf 'PASS: locked ubus b32a0e17 source plus 27 hash-locked security patches\n'
