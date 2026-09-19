#!/bin/sh
set -eu

usage() {
	cat >&2 <<'EOF'
usage: verify-feed.sh --feed DIR [--public-key FILE] [--usign FILE]

Verify a standard opkg feed and, when Packages.sig is present, its usign
signature. Unsigned feeds are valid unless a public key was explicitly given.
EOF
	exit 2
}

feed=
public_key=
usign_bin=${USIGN_BIN:-usign}
while [ "$#" -gt 0 ]; do
	case "$1" in
		--feed) [ "$#" -ge 2 ] || usage; feed=$2; shift 2 ;;
		--public-key) [ "$#" -ge 2 ] || usage; public_key=$2; shift 2 ;;
		--usign) [ "$#" -ge 2 ] || usage; usign_bin=$2; shift 2 ;;
		*) usage ;;
	esac
done

[ -d "$feed" ] || { echo "feed directory does not exist" >&2; exit 1; }
[ -s "$feed/Packages" ] || { echo "feed has no Packages index" >&2; exit 1; }
[ -s "$feed/Packages.gz" ] || { echo "feed has no Packages.gz index" >&2; exit 1; }
[ -s "$feed/SHA256SUMS" ] || { echo "feed has no SHA256SUMS" >&2; exit 1; }

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d /tmp/opkg-feed-verify.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
(
	ulimit -f 16384
	gzip -dc "$feed/Packages.gz" > "$work/Packages.from-gzip"
) || { echo "Packages.gz is corrupt or exceeds 8 MiB" >&2; exit 1; }
[ "$(wc -c < "$work/Packages.from-gzip" | tr -d ' ')" -le 8388608 ] || {
	echo "Packages.gz exceeds 8 MiB" >&2
	exit 1
}
cmp "$feed/Packages" "$work/Packages.from-gzip" >/dev/null || {
	echo "Packages and Packages.gz contain different indexes" >&2
	exit 1
}

signature_files=
if [ -e "$feed/Packages.sig" ]; then
	[ -s "$feed/Packages.sig" ] && [ ! -L "$feed/Packages.sig" ] || {
		echo "Packages.sig is not a regular signature file" >&2
		exit 1
	}
	[ -f "$public_key" ] || {
		echo "--public-key is required to verify Packages.sig" >&2
		exit 1
	}
	command -v "$usign_bin" >/dev/null 2>&1 || {
		echo "usign executable not found: $usign_bin" >&2
		exit 1
	}
	$usign_bin -V -q -m "$feed/Packages" -p "$public_key" -x "$feed/Packages.sig" || {
		echo "feed signature verification failed" >&2
		exit 1
	}
	[ -s "$feed/SIGNING_KEY_FINGERPRINT" ] || {
		echo "signed feed has no signing-key fingerprint" >&2
		exit 1
	}
	[ "$(sed -n '1p' "$feed/SIGNING_KEY_FINGERPRINT")" = \
		"$($usign_bin -F -p "$public_key")" ] || {
		echo "signing-key fingerprint does not match the verifier key" >&2
		exit 1
	}
	signature_files='Packages.sig SIGNING_KEY_FINGERPRINT'
elif [ -n "$public_key" ]; then
	echo "a public key was supplied but the feed is unsigned" >&2
	exit 1
fi

python3 "$script_dir/make_packages_index.py" \
	--input "$feed" --output "$work/Packages.rebuilt" >/dev/null
cmp "$feed/Packages" "$work/Packages.rebuilt" >/dev/null || {
	echo "Packages is not the deterministic index of the published IPKs" >&2
	exit 1
}

{
	printf '%s\n' Packages Packages.gz SHA256SUMS $signature_files
	sed -n 's/^Filename: //p' "$feed/Packages"
} | LC_ALL=C sort -u > "$work/expected-inventory"
: > "$work/actual-inventory"
for entry in "$feed"/* "$feed"/.[!.]* "$feed"/..?*; do
	[ -e "$entry" ] || [ -L "$entry" ] || continue
	[ -f "$entry" ] && [ ! -L "$entry" ] || {
		echo "feed contains a non-regular object: ${entry##*/}" >&2
		exit 1
	}
	printf '%s\n' "${entry##*/}" >> "$work/actual-inventory"
done
LC_ALL=C sort -u "$work/actual-inventory" -o "$work/actual-inventory"
cmp "$work/expected-inventory" "$work/actual-inventory" >/dev/null || {
	echo "feed contains missing or unexpected files" >&2
	exit 1
}
(
	cd "$feed"
	sha256sum -c SHA256SUMS >/dev/null
) || { echo "feed SHA256SUMS verification failed" >&2; exit 1; }

if [ -n "$signature_files" ]; then
	printf 'verified standard signed opkg feed (key %s)\n' \
		"$(sed -n '1p' "$feed/SIGNING_KEY_FINGERPRINT")"
else
	echo "verified standard opkg feed"
fi
