#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
archive_dir=${1:-"$build_dir/distfiles"}
. "$build_dir/sources.lock"

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

command -v gpgv >/dev/null 2>&1 || fail 'gpgv is required for the nano signature gate'
command -v python3 >/dev/null 2>&1 || fail 'python3 is required for the nano key gate'
key=$build_dir/$NANO_SIGNER_KEY
[ -f "$key" ] && [ ! -L "$key" ] || fail "pinned nano signer key is missing: $key"
[ "$(sha256sum "$key" | awk '{print $1}')" = "$NANO_SIGNER_KEY_SHA256" ] ||
	fail 'pinned nano signer key differs from sources.lock'
[ -f "$archive_dir/$NANO_RELEASE_ARCHIVE" ] || fail 'nano release archive is missing'
[ -f "$archive_dir/$NANO_RELEASE_SIGNATURE" ] || fail 'nano release signature is missing'

binary_key=$(mktemp "${TMPDIR:-/tmp}/sbe-nano-key.XXXXXX")
cleanup() {
	rm -f "$binary_key"
}
trap cleanup EXIT HUP INT TERM
"$build_dir/verify-openpgp-key.py" "$key" "$NANO_SIGNER_FINGERPRINT" "$binary_key"
gpgv --keyring "$binary_key" \
	"$archive_dir/$NANO_RELEASE_SIGNATURE" \
	"$archive_dir/$NANO_RELEASE_ARCHIVE"

printf 'PASS: nano %s archive has a valid signature from pinned key %s.\n' \
	"$NANO_VERSION" "$NANO_SIGNER_FINGERPRINT"
