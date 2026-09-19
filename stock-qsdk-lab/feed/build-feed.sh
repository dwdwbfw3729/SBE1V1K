#!/bin/sh
set -eu

usage() {
	cat >&2 <<'EOF'
usage: build-feed.sh --input DIR --output DIR [--private-key FILE --public-key FILE] [--usign FILE]

Build a standard opkg feed from every IPK in DIR. Signing is optional; when
enabled, both an existing usign private key and its public key are required.
EOF
	exit 2
}

input=
output=
private_key=
public_key=
usign_bin=${USIGN_BIN:-usign}
while [ "$#" -gt 0 ]; do
	case "$1" in
		--input) [ "$#" -ge 2 ] || usage; input=$2; shift 2 ;;
		--output) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
		--private-key) [ "$#" -ge 2 ] || usage; private_key=$2; shift 2 ;;
		--public-key) [ "$#" -ge 2 ] || usage; public_key=$2; shift 2 ;;
		--usign) [ "$#" -ge 2 ] || usage; usign_bin=$2; shift 2 ;;
		*) usage ;;
	esac
done

[ -d "$input" ] || { echo "input directory does not exist: $input" >&2; exit 1; }
[ -n "$output" ] || usage
[ ! -e "$output" ] || { echo "refusing to overwrite output: $output" >&2; exit 1; }
case "$private_key:$public_key" in
	:) signed=0 ;;
	:*) echo "--private-key is required with --public-key" >&2; exit 1 ;;
	*:) echo "--public-key is required with --private-key" >&2; exit 1 ;;
	*) signed=1 ;;
esac

if [ "$signed" -eq 1 ]; then
	[ -f "$private_key" ] || { echo "private key does not exist" >&2; exit 1; }
	[ -f "$public_key" ] || { echo "public key does not exist" >&2; exit 1; }
	command -v "$usign_bin" >/dev/null 2>&1 || {
		echo "usign executable not found: $usign_bin" >&2
		exit 1
	}
	private_fingerprint=$($usign_bin -F -s "$private_key")
	public_fingerprint=$($usign_bin -F -p "$public_key")
	[ "$private_fingerprint" = "$public_fingerprint" ] || {
		echo "public key does not match the private key" >&2
		exit 1
	}
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output_parent=$(dirname -- "$output")
mkdir -p "$output_parent"
stage=$(mktemp -d "$output_parent/.opkg-feed.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM

for package in "$input"/*.ipk; do
	[ -f "$package" ] || continue
	cp -p "$package" "$stage/"
done
python3 "$script_dir/make_packages_index.py" \
	--input "$stage" --output "$stage/Packages"
gzip -9 -n -c "$stage/Packages" > "$stage/Packages.gz"

signed_files=
if [ "$signed" -eq 1 ]; then
	$usign_bin -S -m "$stage/Packages" -s "$private_key" -x "$stage/Packages.sig"
	$usign_bin -V -q -m "$stage/Packages" -p "$public_key" -x "$stage/Packages.sig"
	printf '%s\n' "$public_fingerprint" > "$stage/SIGNING_KEY_FINGERPRINT"
	signed_files='Packages.sig SIGNING_KEY_FINGERPRINT'
fi

(
	cd "$stage"
	# Package filenames have already been validated by make_packages_index.py.
	sha256sum Packages Packages.gz $signed_files ./*.ipk | LC_ALL=C sort -k2
) > "$stage/SHA256SUMS"
chmod 0644 "$stage"/*
mv "$stage" "$output"
trap - EXIT HUP INT TERM

if [ "$signed" -eq 1 ]; then
	printf 'published standard signed opkg feed: %s (key %s)\n' "$output" "$public_fingerprint"
else
	printf 'published standard opkg feed: %s\n' "$output"
fi
