#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$build_dir/sources.lock"

export LC_ALL=C
export TZ=UTC
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

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

mkdir -p "$build_dir/sources" "$build_dir/distfiles"
repo=$build_dir/sources/luci
if [ ! -d "$repo/.git" ]; then
	[ ! -e "$repo" ] || fail "refusing to overwrite non-Git source path: $repo"
	git clone --no-tags --single-branch --branch master \
		--shallow-since="$LUCI_SHALLOW_SINCE" "$LUCI_ORIGIN" "$repo"
else
	[ "$(git -C "$repo" remote)" = origin ] ||
		fail 'existing LuCI checkout must have exactly one origin remote'
	[ "$(git -C "$repo" config --get remote.origin.url)" = "$LUCI_ORIGIN" ] ||
		fail 'existing LuCI checkout does not use the official locked origin'
	[ -z "$(git -C "$repo" status --porcelain=v1 --untracked-files=all)" ] ||
		fail 'existing LuCI checkout is not clean'
	git -C "$repo" fetch --no-tags --shallow-since="$LUCI_SHALLOW_SINCE" origin master
fi

git -C "$repo" cat-file -e "$LUCI_COMMIT^{commit}" 2>/dev/null ||
	fail 'locked LuCI commit was not fetched from official master'
git -C "$repo" checkout --detach "$LUCI_COMMIT"

archive=$build_dir/distfiles/$LUCI_ARCHIVE
tmp=$(mktemp "${TMPDIR:-/tmp}/sbe-rrdns-archive.XXXXXX")
cleanup() {
	case "$tmp" in
		*/sbe-rrdns-archive.*) rm -f "$tmp" ;;
	esac
}
trap cleanup EXIT HUP INT TERM
git -C "$repo" -c tar.umask=0002 archive --format=tar \
	--prefix="luci-$LUCI_COMMIT/" \
	-o "$tmp" "$LUCI_COMMIT" libs/rpcd-mod-rrdns/src
[ "$(sha256_file "$tmp")" = "$LUCI_ARCHIVE_SHA256" ] ||
	fail 'official deterministic Git archive differs from the lock'
if [ -f "$archive" ]; then
	cmp -s "$tmp" "$archive" || fail 'existing locked archive differs from official Git output'
else
	mv "$tmp" "$archive"
fi
trap - EXIT HUP INT TERM

"$build_dir/verify-sources.sh"
