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

archive=$build_dir/distfiles/$PROCD_ARCHIVE
package_dir=$build_dir/package-overlay/sbe-procd2020-board-candidate
[ -f "$archive" ] || fail "missing locked source archive: $archive"
[ "$(sha256_file "$archive")" = "$PROCD_ARCHIVE_SHA256" ] ||
	fail 'procd source archive SHA-256 mismatch'

patch1=$package_dir/patches/0001-qsdk-watchdog-timeout-reporting.patch
patch2=$package_dir/patches/0002-qsdk-enable-maximum-runqueue.patch
patch3=$package_dir/patches/0003-system-board-report-aarch64.patch
[ "$(sha256_file "$patch1")" = "$QSDK_WATCHDOG_PATCH_SHA256" ] ||
	fail 'QSDK watchdog patch SHA-256 mismatch'
[ "$(sha256_file "$patch2")" = "$QSDK_RUNQUEUE_PATCH_SHA256" ] ||
	fail 'QSDK runqueue patch SHA-256 mismatch'
[ "$(sha256_file "$patch3")" = "$UPSTREAM_AARCH64_PATCH_SHA256" ] ||
	fail 'official AArch64 patch SHA-256 mismatch'

trial=$(mktemp -d "${TMPDIR:-/tmp}/sbe-procd-source.XXXXXX")
cleanup() {
	case "$trial" in
		/tmp/sbe-procd-source.*|/var/tmp/sbe-procd-source.*|/private/tmp/sbe-procd-source.*)
			rm -rf "$trial"
			;;
	esac
}
trap cleanup EXIT HUP INT TERM

tar -xf "$archive" -C "$trial"
source_dir=$trial/procd-$PROCD_COMMIT
[ -d "$source_dir" ] || fail 'source archive has an unexpected top-level directory'
[ "$(sha256_file "$source_dir/system.c")" = "$PROCD_SYSTEM_C_SHA256" ] ||
	fail 'system.c differs from the exact QSDK procd commit'
[ "$(sha256_file "$source_dir/CMakeLists.txt")" = "$PROCD_CMAKE_SHA256" ] ||
	fail 'CMakeLists.txt differs from the exact QSDK procd commit'

for patch_file in "$patch1" "$patch2" "$patch3"; do
	patch -d "$source_dir" -p1 --batch --fuzz=0 < "$patch_file" >/dev/null ||
		fail "patch does not apply exactly: $(basename "$patch_file")"
done

grep -Fq '#ifdef __aarch64__' "$source_dir/system.c" ||
	fail 'patched system.c lacks the AArch64 branch'
grep -Fq 'if (!strcasecmp(key, "CPU revision"))' "$source_dir/system.c" ||
	fail 'patched system.c does not consume the real CPU revision field'
grep -Fq '"ARMv8 Processor rev %lu"' "$source_dir/system.c" ||
	fail 'patched system.c lacks the upstream-compatible system value'
grep -Fq 'strtoul(val + 2, NULL, 16)' "$source_dir/system.c" ||
	fail 'patched system.c does not parse the reported revision value'
grep -Fq 'current_wdt_drv_timeout' "$source_dir/watchdog.c" ||
	fail 'QSDK watchdog behavior was not retained'
grep -Fq 'q.max_running_tasks = get_max_running_tasks();' "$source_dir/rcS.c" ||
	fail 'QSDK multi-core boot behavior was not retained'

if grep -Eiq 'SBE1V1K|IPQ95|Cortex-A73|AP-AL02' "$patch3"; then
	fail 'AArch64 board-info patch hard-codes this router model or CPU part'
fi

makefile=$package_dir/Makefile
grep -Fq "PKG_HASH:=$PROCD_ARCHIVE_SHA256" "$makefile" ||
	fail 'package recipe does not pin the reviewed archive'
grep -Fq '$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/sbin/procd $(1)/sbin/procd' "$makefile" ||
	fail 'candidate payload is not limited to /sbin/procd'

printf 'PASS: exact procd 09b9bd82 source, QSDK patches and official AArch64 backport are locked\n'

