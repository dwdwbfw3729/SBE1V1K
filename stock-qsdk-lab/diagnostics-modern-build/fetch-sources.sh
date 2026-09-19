#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
destination=${1:-"$build_dir/distfiles"}
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
	sha256sum "$1" | awk '{print $1}'
}

fetch_repo() {
	name=$1
	origin=$2
	branch=$3
	tag=$4
	commit=$5
	repo=$build_dir/sources/$name

	if [ ! -e "$repo" ]; then
		git clone --no-checkout --branch "$branch" "$origin" "$repo"
	fi
	[ -d "$repo/.git" ] || fail "refusing non-Git source path: $repo"
	[ "$(git -C "$repo" remote)" = origin ] ||
		fail "$name must have exactly one remote named origin"
	[ "$(git -C "$repo" config --get remote.origin.url)" = "$origin" ] ||
		fail "$name origin is not the locked official URL"
	[ -z "$(git -C "$repo" status --porcelain=v1 --untracked-files=all)" ] ||
		fail "$name worktree is dirty; refusing to discard changes"
	git -C "$repo" fetch --force origin \
		"+refs/heads/$branch:refs/remotes/origin/$branch" \
		"+refs/tags/$tag:refs/tags/$tag"
	git -C "$repo" checkout --detach "$commit"
}

fetch_repo mtr "$MTR_ORIGIN" "$MTR_BRANCH" "$MTR_TAG" "$MTR_COMMIT"
fetch_repo htop "$HTOP_ORIGIN" "$HTOP_BRANCH" "$HTOP_TAG" "$HTOP_COMMIT"
fetch_repo nano "$NANO_ORIGIN" "$NANO_BRANCH" "$NANO_TAG" "$NANO_COMMIT"

mkdir -p "$destination"

emit_archive() {
	name=$1
	commit=$2
	archive=$3
	expected=$4
	repo=$build_dir/sources/$name
	tmp=$(mktemp "${TMPDIR:-/tmp}/sbe-diagnostics-$name-archive.XXXXXX")
	trap 'rm -f "$tmp"' EXIT HUP INT TERM
	git -C "$repo" archive --format=tar --prefix="$name-$commit/" \
		--output="$tmp" "$commit"
	actual=$(sha256_file "$tmp")
	[ "$actual" = "$expected" ] ||
		fail "$name deterministic archive hash changed: $actual"
	if [ -f "$destination/$archive" ]; then
		cmp -s "$tmp" "$destination/$archive" ||
			fail "refusing to overwrite mismatched $destination/$archive"
	else
		cp "$tmp" "$destination/$archive"
	fi
	rm -f "$tmp"
	trap - EXIT HUP INT TERM
}

download_locked() {
	url=$1
	filename=$2
	expected=$3
	if [ -f "$destination/$filename" ]; then
		[ "$(sha256_file "$destination/$filename")" = "$expected" ] ||
			fail "refusing mismatched existing $destination/$filename"
		return
	fi
	tmp=$(mktemp "${TMPDIR:-/tmp}/sbe-diagnostics-download.XXXXXX")
	trap 'rm -f "$tmp"' EXIT HUP INT TERM
	curl --fail --location --proto '=https' --tlsv1.2 --output "$tmp" "$url"
	[ "$(sha256_file "$tmp")" = "$expected" ] ||
		fail "downloaded $filename does not match its lock"
	cp "$tmp" "$destination/$filename"
	rm -f "$tmp"
	trap - EXIT HUP INT TERM
}

emit_archive mtr "$MTR_COMMIT" "$MTR_ARCHIVE" "$MTR_ARCHIVE_SHA256"
emit_archive htop "$HTOP_COMMIT" "$HTOP_ARCHIVE" "$HTOP_ARCHIVE_SHA256"
emit_archive nano "$NANO_COMMIT" "$NANO_ARCHIVE" "$NANO_ARCHIVE_SHA256"
download_locked "$MTR_RELEASE_BASE_URL/$MTR_RELEASE_ARCHIVE" \
	"$MTR_RELEASE_ARCHIVE" "$MTR_RELEASE_SHA256"
download_locked "$HTOP_RELEASE_BASE_URL/$HTOP_RELEASE_ARCHIVE" \
	"$HTOP_RELEASE_ARCHIVE" "$HTOP_RELEASE_SHA256"
download_locked "$HTOP_RELEASE_BASE_URL/$HTOP_RELEASE_CHECKSUM" \
	"$HTOP_RELEASE_CHECKSUM" "$HTOP_RELEASE_CHECKSUM_SHA256"
download_locked "$NANO_RELEASE_BASE_URL/$NANO_RELEASE_ARCHIVE" \
	"$NANO_RELEASE_ARCHIVE" "$NANO_RELEASE_SHA256"
download_locked "$NANO_RELEASE_BASE_URL/$NANO_RELEASE_SIGNATURE" \
	"$NANO_RELEASE_SIGNATURE" "$NANO_RELEASE_SIGNATURE_SHA256"

"$build_dir/verify-sources.sh" "$destination"
printf 'Locked diagnostics distfiles written to %s\n' "$destination"
