#!/bin/sh
set -eu

candidate_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cache_dir=${1:-"$candidate_dir/cache"}
. "$candidate_dir/sources.lock"

hash_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

verify_path() {
	file=$1
	expected=$2
	name=$3
	[ -f "$file" ] || {
		printf 'ERROR: locked source is missing: %s\n' "$file" >&2
		exit 1
	}
	actual=$(hash_file "$file")
	[ "$actual" = "$expected" ] || {
		printf 'ERROR: SHA256 mismatch for %s: %s\n' "$name" "$actual" >&2
		exit 1
	}
}

verify_one() {
	name=$1
	expected=$2
	verify_path "$cache_dir/$name" "$expected" "$name"
}

verify_one "$BUSYBOX_ARCHIVE" "$BUSYBOX_SHA256"
patch_count=0
while IFS="	" read -r patch_name patch_sha extra; do
	case "$patch_name" in ''|'#'*) continue ;; esac
	[ -z "${extra:-}" ] && [ -n "$patch_sha" ] || {
		printf 'ERROR: malformed patches.lock row: %s\n' "$patch_name" >&2
		exit 1
	}
	verify_one "$patch_name" "$patch_sha"
	patch_count=$((patch_count + 1))
done < "$candidate_dir/patches.lock"
[ "$patch_count" -eq 16 ] || {
	printf 'ERROR: expected 16 locked OpenWrt patches, found %s\n' "$patch_count" >&2
	exit 1
}

local_patch_count=0
while IFS="	" read -r patch_name patch_sha provenance; do
	case "$patch_name" in ''|'#'*) continue ;; esac
	[ -n "$patch_sha" ] && [ -n "$provenance" ] || {
		printf 'ERROR: malformed local-patches.lock row: %s\n' "$patch_name" >&2
		exit 1
	}
	verify_path "$candidate_dir/local-patches/$patch_name" "$patch_sha" "$patch_name"
	local_patch_count=$((local_patch_count + 1))
done < "$candidate_dir/local-patches.lock"
[ "$local_patch_count" -eq 1 ] || {
	printf 'ERROR: expected one locked local compatibility patch, found %s\n' "$local_patch_count" >&2
	exit 1
}
printf 'Verified BusyBox %s, %s OpenWrt patches at %s, and %s local compatibility patch.\n' \
	"$BUSYBOX_VERSION" "$patch_count" "$OPENWRT_COMMIT" "$local_patch_count"
