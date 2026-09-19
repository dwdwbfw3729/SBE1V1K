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

ensure_clone() {
	name=$1
	origin=$2
	branch=$3
	commit=$4
	repo=$build_dir/sources/$name

	if [ ! -e "$repo" ]; then
		git clone --filter=blob:none --no-checkout --branch "$branch" \
			"$origin" "$repo"
		git -C "$repo" checkout --detach "$commit"
	fi
	[ -d "$repo/.git" ] || fail "refusing non-git source path: $repo"
}

ensure_clone uhttpd "$UHTTPD_ORIGIN" "$UHTTPD_BRANCH" "$UHTTPD_COMMIT"
ensure_clone rpcd "$RPCD_ORIGIN" "$RPCD_BRANCH" "$RPCD_COMMIT"
ensure_clone odhcpd "$ODHCPD_ORIGIN" "$ODHCPD_BRANCH" "$ODHCPD_COMMIT"
ensure_clone ustream-ssl "$USTREAM_ORIGIN" "$USTREAM_BRANCH" "$USTREAM_COMMIT"
ensure_clone iwinfo "$IWINFO_ORIGIN" "$IWINFO_BRANCH" "$IWINFO_COMMIT"
ensure_clone ppp "$PPP_ORIGIN" "$PPP_BRANCH" "$PPP_COMMIT"

"$build_dir/verify-sources.sh"
mkdir -p "$destination"

emit_archive() {
	name=$1
	commit=$2
	archive=$3
	expected=$4
	repo=$build_dir/sources/$name
	tmp=$(mktemp "${TMPDIR:-/tmp}/sbe-$name-archive.XXXXXX")
	trap 'rm -f "$tmp"' EXIT HUP INT TERM

	git -C "$repo" archive --format=tar --prefix="$name-$commit/" "$commit" > "$tmp"
	actual=$(sha256sum "$tmp" | awk '{print $1}')
	[ "$actual" = "$expected" ] || fail "$name archive digest changed: $actual"
	if [ -f "$destination/$archive" ]; then
		cmp -s "$tmp" "$destination/$archive" || \
			fail "refusing to overwrite mismatched $destination/$archive"
	else
		cp "$tmp" "$destination/$archive"
	fi
	rm -f "$tmp"
	trap - EXIT HUP INT TERM
}

emit_archive uhttpd "$UHTTPD_COMMIT" "$UHTTPD_ARCHIVE" "$UHTTPD_SHA256"
emit_archive rpcd "$RPCD_COMMIT" "$RPCD_ARCHIVE" "$RPCD_SHA256"
emit_archive odhcpd "$ODHCPD_COMMIT" "$ODHCPD_ARCHIVE" "$ODHCPD_SHA256"
emit_archive ustream-ssl "$USTREAM_COMMIT" "$USTREAM_ARCHIVE" "$USTREAM_SHA256"
emit_archive iwinfo "$IWINFO_COMMIT" "$IWINFO_ARCHIVE" "$IWINFO_SHA256"
emit_archive ppp "$PPP_COMMIT" "$PPP_ARCHIVE" "$PPP_SHA256"

"$build_dir/verify-sources.sh" "$destination"
printf 'Locked core-userland distfiles written to %s\n' "$destination"
