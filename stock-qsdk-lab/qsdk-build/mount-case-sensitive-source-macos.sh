#!/bin/sh
set -eu

lab_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$lab_dir/../.." && pwd)
workspace_root=$(CDPATH= cd -- "$repo_root/.." && pwd)

source_root=${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}
image=${QSDK_SOURCE_IMAGE:-"$repo_root/stock-qsdk-lab/work/qsdk-sources.sparsebundle"}
image_size=${QSDK_SOURCE_IMAGE_SIZE:-80g}
volume_name=${QSDK_SOURCE_VOLUME_NAME:-SBE-QSDK-LOCKED}
action=${1:-status}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[ "$(uname -s)" = Darwin ] || fail 'this helper is only for macOS'

is_mounted() {
	mount | grep -F " on $source_root (" >/dev/null 2>&1
}

verify_mount() {
	is_mounted || fail "$source_root is not mounted"
	diskutil info "$source_root" | grep -q \
		'File System Personality:.*Case-sensitive APFS' || \
		fail "$source_root is mounted, but is not Case-sensitive APFS"
}

mount_image() {
	if is_mounted; then
		verify_mount
		printf 'Already mounted: %s\n' "$source_root"
		return
	fi
	[ -e "$image" ] || fail "sparsebundle is missing: $image"
	if [ -e "$source_root" ]; then
		[ -d "$source_root" ] || fail "mountpoint is not a directory: $source_root"
		[ -z "$(find "$source_root" -mindepth 1 -maxdepth 1 -print -quit)" ] || \
			fail "unmounted mountpoint is not empty: $source_root"
	else
		mkdir "$source_root"
	fi
	hdiutil attach "$image" -mountpoint "$source_root" -nobrowse
	verify_mount
	printf 'Mounted case-sensitive QSDK workspace: %s\n' "$source_root"
}

case "$action" in
	create)
		[ ! -e "$image" ] || fail "refusing to replace existing image: $image"
		if [ -e "$source_root" ]; then
			[ -d "$source_root" ] || fail "mountpoint is not a directory: $source_root"
			[ -z "$(find "$source_root" -mindepth 1 -maxdepth 1 -print -quit)" ] || \
				fail "mountpoint is not empty: $source_root"
		fi
		case "$image_size" in
			*[!0-9gGmM]*) fail "invalid bounded sparsebundle size: $image_size" ;;
		esac
		hdiutil create -size "$image_size" -type SPARSEBUNDLE \
			-fs 'Case-sensitive APFS' -volname "$volume_name" "$image"
		mount_image
		;;
	mount)
		mount_image
		;;
	status)
		printf 'Image:      %s\n' "$image"
		printf 'Mountpoint: %s\n' "$source_root"
		if is_mounted; then
			verify_mount
			printf 'Status:     mounted, Case-sensitive APFS\n'
			df -h "$source_root" | sed -n '1,2p'
		else
			printf 'Status:     not mounted\n'
		fi
		;;
	unmount)
		if ! is_mounted; then
			printf 'Already unmounted: %s\n' "$source_root"
			exit 0
		fi
		device=$(df -P "$source_root" | awk 'NR == 2 {print $1}')
		case "$device" in
			/dev/disk*) ;;
			*) fail "refusing to detach unexpected device: $device" ;;
		esac
		hdiutil detach "$device"
		printf 'Unmounted: %s\n' "$source_root"
		;;
	*)
		fail 'usage: mount-case-sensitive-source-macos.sh create|mount|status|unmount'
		;;
esac
