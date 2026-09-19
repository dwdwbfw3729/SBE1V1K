#!/bin/sh
set -eu

candidate_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$candidate_dir/sources.lock"
cache_dir=${1:-"$candidate_dir/cache"}
source_root=${2:-}

[ -f "$cache_dir/$UBOX_ARCHIVE" ] || {
	printf 'ERROR: missing source archive: %s\n' "$cache_dir/$UBOX_ARCHIVE" >&2
	exit 1
}
printf '%s  %s\n' "$UBOX_SHA256" "$cache_dir/$UBOX_ARCHIVE" | sha256sum -c -

if [ -n "$source_root" ]; then
	qsdk_makefile=$source_root/qsdk/package/system/ubox/Makefile
	qsdk_init=$source_root/qsdk/package/system/ubox/files/log.init
	[ -f "$qsdk_makefile" ] && [ -f "$qsdk_init" ] || {
		printf 'ERROR: locked QSDK ubox package is missing under %s\n' "$source_root" >&2
		exit 1
	}
	grep -qx "PKG_SOURCE_DATE:=$UBOX_SOURCE_DATE" "$qsdk_makefile"
	grep -qx "PKG_SOURCE_VERSION:=$UBOX_SOURCE_VERSION" "$qsdk_makefile"
	grep -qx "PKG_MIRROR_HASH:=$UBOX_SHA256" "$qsdk_makefile"
	grep -qx "PKG_RELEASE:=$QSDK_UBOX_PACKAGE_RELEASE" "$qsdk_makefile"
	printf '%s  %s\n' "$QSDK_LOG_INIT_SHA256" "$qsdk_init" | sha256sum -c -
	cmp -s "$candidate_dir/rootfs-payload/etc/init.d/log" "$qsdk_init" || {
		printf 'ERROR: candidate log init differs from the locked QSDK file.\n' >&2
		exit 1
	}
fi
