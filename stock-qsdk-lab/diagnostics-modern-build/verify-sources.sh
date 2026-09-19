#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
archive_dir=${1:-"$build_dir/distfiles"}
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

verify_tag() {
	name=$1
	tag=$2
	tag_object=$3
	commit=$4
	tag_type=$5
	signed=$6
	repo=$build_dir/sources/$name

	[ "$(git -C "$repo" rev-parse "$tag")" = "$tag_object" ] ||
		fail "$name tag object differs from the lock"
	[ "$(git -C "$repo" rev-parse "$tag^{}")" = "$commit" ] ||
		fail "$name tag target differs from the locked release commit"
	[ "$(git -C "$repo" cat-file -t "$tag")" = "$tag_type" ] ||
		fail "$name release tag type differs from the lock"
	if [ "$signed" = yes ]; then
		git -C "$repo" cat-file -p "$tag" |
			grep -q '^-----BEGIN PGP SIGNATURE-----$' ||
			fail "$name release tag lost its embedded OpenPGP signature"
	else
		if git -C "$repo" cat-file -p "$tag" | grep -q 'BEGIN PGP SIGNATURE'; then
			fail "$name tag gained a signature; review and update its trust policy"
		fi
	fi
}

verify_release_file() {
	name=$1
	file=$2
	expected=$3
	[ -f "$archive_dir/$file" ] || fail "$archive_dir/$file is missing"
	[ "$(sha256_file "$archive_dir/$file")" = "$expected" ] ||
		fail "official $name release file $file differs from the lock"
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
	[ "$(git -C "$repo" remote)" = origin ] ||
		fail "$name must have exactly one remote named origin"
	[ "$(git -C "$repo" config --get remote.origin.url)" = "$origin" ] ||
		fail "$name origin is not the locked official URL"
	[ ! -f "$repo/.gitmodules" ] || fail "$name unexpectedly uses submodules"
	[ -z "$(git -C "$repo" status --porcelain=v1 --untracked-files=all)" ] ||
		fail "$name source worktree is not clean"
	[ "$(git -C "$repo" rev-parse HEAD)" = "$commit" ] ||
		fail "$name HEAD is not the locked release commit"
	[ "$(git -C "$repo" cat-file -t "$commit")" = commit ] ||
		fail "$name lock does not name a commit object"
	[ "$(git -C "$repo" rev-parse "$commit^{tree}")" = "$tree" ] ||
		fail "$name tree differs from the lock"
	git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch" ||
		fail "$name has no origin/$branch tracking ref"
	git -C "$repo" merge-base --is-ancestor "$commit" "refs/remotes/origin/$branch" ||
		fail "$name release is not reachable from origin/$branch"

	tmp=$(mktemp "${TMPDIR:-/tmp}/sbe-diagnostics-$name-archive.XXXXXX")
	trap 'rm -f "$tmp"' EXIT HUP INT TERM
	git -C "$repo" archive --format=tar --prefix="$name-$commit/" \
		--output="$tmp" "$commit"
	actual_sha=$(sha256_file "$tmp")
	[ "$actual_sha" = "$expected_sha" ] ||
		fail "$name deterministic git archive changed: $actual_sha"
	[ -f "$archive_dir/$archive" ] || fail "$archive_dir/$archive is missing"
	[ "$(sha256_file "$archive_dir/$archive")" = "$expected_sha" ] ||
		fail "$archive_dir/$archive hash differs from the lock"
	cmp -s "$tmp" "$archive_dir/$archive" ||
		fail "$archive_dir/$archive differs from the deterministic Git archive"
	rm -f "$tmp"
	trap - EXIT HUP INT TERM
	printf 'verified %-4s commit=%s tree=%s archive=%s\n' \
		"$name" "$commit" "$tree" "$expected_sha"
}

verify_repo mtr "$MTR_ORIGIN" "$MTR_BRANCH" "$MTR_COMMIT" "$MTR_TREE" \
	"$MTR_ARCHIVE" "$MTR_ARCHIVE_SHA256"
verify_repo htop "$HTOP_ORIGIN" "$HTOP_BRANCH" "$HTOP_COMMIT" "$HTOP_TREE" \
	"$HTOP_ARCHIVE" "$HTOP_ARCHIVE_SHA256"
verify_repo nano "$NANO_ORIGIN" "$NANO_BRANCH" "$NANO_COMMIT" "$NANO_TREE" \
	"$NANO_ARCHIVE" "$NANO_ARCHIVE_SHA256"

verify_tag mtr "$MTR_TAG" "$MTR_TAG_OBJECT" "$MTR_COMMIT" tag no
verify_tag htop "$HTOP_TAG" "$HTOP_TAG_OBJECT" "$HTOP_COMMIT" commit no
verify_tag nano "$NANO_TAG" "$NANO_TAG_OBJECT" "$NANO_COMMIT" tag yes

[ "$(cat "$build_dir/sources/mtr/.tarball-version")" = "$MTR_VERSION" ] ||
	fail 'mtr source version marker differs from v0.96'
grep -F -q "m4_define([htop_release_version], [$HTOP_VERSION])" \
	"$build_dir/sources/htop/configure.ac" ||
	fail 'htop source version marker differs from 3.5.3'
grep -F -q "GNU nano $NANO_VERSION" "$build_dir/sources/nano/NEWS" ||
	fail 'nano source version marker differs from 9.2'

verify_release_file mtr "$MTR_RELEASE_ARCHIVE" "$MTR_RELEASE_SHA256"
verify_release_file htop "$HTOP_RELEASE_ARCHIVE" "$HTOP_RELEASE_SHA256"
verify_release_file htop "$HTOP_RELEASE_CHECKSUM" \
	"$HTOP_RELEASE_CHECKSUM_SHA256"
expected_htop_checksum="$HTOP_RELEASE_SHA256  $HTOP_RELEASE_ARCHIVE"
[ "$(cat "$archive_dir/$HTOP_RELEASE_CHECKSUM")" = "$expected_htop_checksum" ] ||
	fail 'official htop checksum file does not name the locked release archive/hash'

nano_release=$archive_dir/$NANO_RELEASE_ARCHIVE
nano_signature=$archive_dir/$NANO_RELEASE_SIGNATURE
verify_release_file nano "$NANO_RELEASE_ARCHIVE" "$NANO_RELEASE_SHA256"
verify_release_file nano "$NANO_RELEASE_SIGNATURE" \
	"$NANO_RELEASE_SIGNATURE_SHA256"
nano_signer_key=$build_dir/$NANO_SIGNER_KEY
[ -f "$nano_signer_key" ] && [ ! -L "$nano_signer_key" ] ||
	fail 'pinned nano signer public key is missing or is a symlink'
[ "$(sha256_file "$nano_signer_key")" = "$NANO_SIGNER_KEY_SHA256" ] ||
	fail 'pinned nano signer public key differs from sources.lock'
nano_keyring=$(mktemp "${TMPDIR:-/tmp}/sbe-nano-keyring.XXXXXX")
trap 'rm -f "$nano_keyring"' EXIT HUP INT TERM
python3 "$build_dir/verify-openpgp-key.py" "$nano_signer_key" \
	"$NANO_SIGNER_FINGERPRINT" "$nano_keyring"
rm -f "$nano_keyring"
trap - EXIT HUP INT TERM
"$build_dir/verify-openpgp-issuer.py" "$nano_signature" \
	"$NANO_SIGNER_FINGERPRINT"
tag_signature=$(mktemp "${TMPDIR:-/tmp}/sbe-nano-tag-signature.XXXXXX")
trap 'rm -f "$tag_signature"' EXIT HUP INT TERM
git -C "$build_dir/sources/nano" cat-file -p "$NANO_TAG" |
	sed -n '/^-----BEGIN PGP SIGNATURE-----$/,/^-----END PGP SIGNATURE-----$/p' \
	> "$tag_signature"
"$build_dir/verify-openpgp-issuer.py" "$tag_signature" \
	"$NANO_SIGNER_FINGERPRINT"
rm -f "$tag_signature"
trap - EXIT HUP INT TERM

PYTHONPYCACHEPREFIX=${TMPDIR:-/tmp}/sbe-diagnostics-pycache \
	python3 "$build_dir/verify-release-archives.py" "$archive_dir"

printf 'PASS: official origins, release tags, release assets, checksums and deterministic archives are locked.\n'
