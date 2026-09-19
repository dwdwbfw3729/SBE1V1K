#!/bin/sh
set -eu

lab_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$lab_dir/sources.lock"

fit=${1:?usage: extract-stock-kconfig.sh HLOS_FIT OUTPUT_CONFIG}
output=${2:?usage: extract-stock-kconfig.sh HLOS_FIT OUTPUT_CONFIG}

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

[ -f "$fit" ] || fail "FIT image does not exist: $fit"
[ ! -e "$output" ] || fail "refusing to overwrite existing output: $output"
command -v dumpimage >/dev/null 2>&1 || fail 'dumpimage is required (U-Boot tools)'
command -v xz >/dev/null 2>&1 || fail 'xz is required'
command -v curl >/dev/null 2>&1 || fail 'curl is required'

tmp=$(mktemp -d "${TMPDIR:-/tmp}/sbe-kconfig.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

dumpimage -T flat_dt -p 0 -o "$tmp/kernel.lzma" "$fit" >/dev/null
xz --format=lzma --decompress --stdout "$tmp/kernel.lzma" > "$tmp/Image"

extractor=$tmp/extract-ikconfig
curl -fL --retry 3 --retry-all-errors --connect-timeout 20 \
	"$EXTRACT_IKCONFIG_URL" -o "$extractor"
[ "$(sha256_file "$extractor")" = "$EXTRACT_IKCONFIG_SHA256" ] || \
	fail 'pinned extract-ikconfig checksum differs'
chmod 0755 "$extractor"

LC_ALL=C "$extractor" "$tmp/Image" > "$tmp/stock.config"
actual=$(sha256_file "$tmp/stock.config")
[ "$actual" = "$FACTORY_KERNEL_CONFIG_SHA256" ] || \
	fail "extracted config SHA-256 is $actual, expected $FACTORY_KERNEL_CONFIG_SHA256"
lines=$(wc -l < "$tmp/stock.config" | tr -d ' ')
[ "$lines" = "$FACTORY_KERNEL_CONFIG_LINES" ] || \
	fail "extracted config has $lines lines, expected $FACTORY_KERNEL_CONFIG_LINES"

mkdir -p "$(dirname -- "$output")"
mv "$tmp/stock.config" "$output"
printf 'PASS: exact stock kernel config written to %s\n' "$output"
printf 'SHA-256: %s\n' "$actual"
