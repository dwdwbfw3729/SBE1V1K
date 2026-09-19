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

fetch_one() {
	url=$1
	name=$2
	expected=$3
	case "$name" in
		''|*[!A-Za-z0-9._-]*)
			printf 'ERROR: unsafe locked filename: %s\n' "$name" >&2
			exit 1
			;;
	esac
	destination=$cache_dir/$name
	if [ -f "$destination" ] && [ "$(hash_file "$destination")" = "$expected" ]; then
		printf 'verified cached %s\n' "$name"
		return
	fi
	temporary=$cache_dir/.$name.part.$$
	rm -f "$temporary"
	trap 'rm -f "$temporary"' EXIT HUP INT TERM
	curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
		--output "$temporary" "$url"
	actual=$(hash_file "$temporary")
	[ "$actual" = "$expected" ] || {
		printf 'ERROR: SHA256 mismatch for %s: %s\n' "$name" "$actual" >&2
		exit 1
	}
	mv "$temporary" "$destination"
	trap - EXIT HUP INT TERM
	printf 'downloaded and verified %s\n' "$name"
}

mkdir -p "$cache_dir"
fetch_one "$BUSYBOX_URL" "$BUSYBOX_ARCHIVE" "$BUSYBOX_SHA256"

while IFS="	" read -r patch_name patch_sha extra; do
	case "$patch_name" in ''|'#'*) continue ;; esac
	[ -z "${extra:-}" ] && [ -n "$patch_sha" ] || {
		printf 'ERROR: malformed patches.lock row: %s\n' "$patch_name" >&2
		exit 1
	}
	fetch_one "$OPENWRT_PATCH_BASE/$patch_name" "$patch_name" "$patch_sha"
done < "$candidate_dir/patches.lock"

"$candidate_dir/verify-sources.sh" "$cache_dir"

