#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
archive_dir=${1:-}
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

verify_patch() {
	path=$1
	expected=$2
	[ -f "$path" ] || fail "locked compatibility patch is missing: $path"
	actual=$(sha256_file "$path")
	[ "$actual" = "$expected" ] || fail "compatibility patch hash mismatch: $path"
}

verify_repo() {
	name=$1
	origin=$2
	branch=$3
	commit=$4
	tree=$5
	archive=$6
	expected_sha=$7
	repo=$build_dir/sources/$name

	[ -d "$repo/.git" ] || fail "$name official clone is missing: $repo"
	[ "$(git -C "$repo" remote)" = origin ] || \
		fail "$name must have exactly one remote named origin"
	[ "$(git -C "$repo" config --get remote.origin.url)" = "$origin" ] || \
		fail "$name origin URL is not the locked official URL"
	[ ! -f "$repo/.gitmodules" ] || fail "$name source unexpectedly uses submodules"
	[ -z "$(git -C "$repo" status --porcelain=v1 --untracked-files=all)" ] || \
		fail "$name source worktree is not clean"
	[ "$(git -C "$repo" rev-parse HEAD)" = "$commit" ] || \
		fail "$name HEAD is not the locked commit"
	[ "$(git -C "$repo" cat-file -t "$commit")" = commit ] || \
		fail "$name lock does not name a commit object"
	[ "$(git -C "$repo" rev-parse "$commit^{tree}")" = "$tree" ] || \
		fail "$name tree hash differs from the lock"
	git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch" || \
		fail "$name has no origin/$branch tracking ref"
	git -C "$repo" merge-base --is-ancestor "$commit" "refs/remotes/origin/$branch" || \
		fail "$name commit is not reachable from locked official origin/$branch"

	tmp=$(mktemp "${TMPDIR:-/tmp}/sbe-$name-archive.XXXXXX")
	trap 'rm -f "$tmp"' EXIT HUP INT TERM
	git -C "$repo" archive --format=tar --prefix="$name-$commit/" "$commit" > "$tmp"
	actual_sha=$(sha256_file "$tmp")
	[ "$actual_sha" = "$expected_sha" ] || \
		fail "$name deterministic git archive hash mismatch: $actual_sha"
	if [ -n "$archive_dir" ]; then
		[ -f "$archive_dir/$archive" ] || fail "$archive_dir/$archive is missing"
		[ "$(sha256_file "$archive_dir/$archive")" = "$expected_sha" ] || \
			fail "$archive_dir/$archive hash mismatch"
		cmp -s "$tmp" "$archive_dir/$archive" || \
			fail "$archive_dir/$archive differs despite its digest"
	fi
	rm -f "$tmp"
	trap - EXIT HUP INT TERM
	printf 'verified %-7s commit=%s tree=%s archive=%s\n' \
		"$name" "$commit" "$tree" "$expected_sha"
}

verify_repo uhttpd "$UHTTPD_ORIGIN" "$UHTTPD_BRANCH" "$UHTTPD_COMMIT" \
	"$UHTTPD_TREE" "$UHTTPD_ARCHIVE" "$UHTTPD_SHA256"
verify_repo rpcd "$RPCD_ORIGIN" "$RPCD_BRANCH" "$RPCD_COMMIT" \
	"$RPCD_TREE" "$RPCD_ARCHIVE" "$RPCD_SHA256"
verify_repo odhcpd "$ODHCPD_ORIGIN" "$ODHCPD_BRANCH" "$ODHCPD_COMMIT" \
	"$ODHCPD_TREE" "$ODHCPD_ARCHIVE" "$ODHCPD_SHA256"
verify_repo ustream-ssl "$USTREAM_ORIGIN" "$USTREAM_BRANCH" "$USTREAM_COMMIT" \
	"$USTREAM_TREE" "$USTREAM_ARCHIVE" "$USTREAM_SHA256"
verify_repo iwinfo "$IWINFO_ORIGIN" "$IWINFO_BRANCH" "$IWINFO_COMMIT" \
	"$IWINFO_TREE" "$IWINFO_ARCHIVE" "$IWINFO_SHA256"
verify_repo ppp "$PPP_ORIGIN" "$PPP_BRANCH" "$PPP_COMMIT" \
	"$PPP_TREE" "$PPP_ARCHIVE" "$PPP_SHA256"

ppp_repo=$build_dir/sources/ppp
[ "$(git -C "$ppp_repo" rev-parse "$PPP_BASE_TAG")" = "$PPP_BASE_TAG_OBJECT" ] || \
	fail 'PPP v2.5.3 annotated tag object differs from the lock'
[ "$(git -C "$ppp_repo" rev-parse "$PPP_BASE_TAG^{}")" = "$PPP_BASE_COMMIT" ] || \
	fail 'PPP v2.5.3 tag target differs from the lock'
git -C "$ppp_repo" cat-file -p "$PPP_BASE_TAG" | \
	grep -q '^-----BEGIN PGP SIGNATURE-----$' || \
	fail 'PPP v2.5.3 base tag is not an annotated signed tag object'
git -C "$ppp_repo" merge-base --is-ancestor "$PPP_BASE_COMMIT" "$PPP_COMMIT" || \
	fail 'PPP candidate silently moved behind signed v2.5.3'

verify_patch "$build_dir/package-overlay/sbe-uhttpd2026-candidate/patches/100-ustream-20150806-cipher-api.patch" \
	"$UHTTPD_USTREAM_PATCH_SHA256"
verify_patch "$build_dir/package-overlay/sbe-rpcd2026-candidate/patches/100-libubox-2020-timeout-api.patch" \
	"$RPCD_LIBUBOX_PATCH_SHA256"
verify_patch "$build_dir/package-overlay/sbe-rpcd2026-candidate/patches/110-libiwinfo-20181126-compat.patch" \
	"$RPCD_IWINFO_PATCH_SHA256"
verify_patch "$build_dir/package-overlay/sbe-rpcd2026-candidate/patches/120-opkg-rpcsys-no-firmware-write.patch" \
	"$RPCD_RPCSYS_PATCH_SHA256"
verify_patch "$build_dir/package-overlay/sbe-rpcd2026-candidate/patches/130-factory-iwinfo-link-name.patch" \
	"$RPCD_IWINFO_LINK_PATCH_SHA256"
verify_patch "$build_dir/package-overlay/sbe-rpcd2026-candidate/patches/140-qca-radio-scan-vap.patch" \
	"$RPCD_QCA_SCAN_PATCH_SHA256"
verify_patch "$build_dir/package-overlay/sbe-odhcpd2026-ipv6only-candidate/patches/100-json-c-0.12-fd-compat.patch" \
	"$ODHCPD_JSONC_PATCH_SHA256"
verify_patch "$build_dir/package-overlay/sbe-odhcpd2026-ipv6only-candidate/patches/110-gcc7-libubox2020-compat.patch" \
	"$ODHCPD_COMPAT_PATCH_SHA256"
verify_patch "$build_dir/package-overlay/sbe-ppp254-candidate/patches/100-pppoe-only-build.patch" \
	"$PPP_MINIMAL_PATCH_SHA256"

printf 'PASS: official origins, clean commits, trees, archives, ABI headers, signed PPP base and local patches are locked.\n'
