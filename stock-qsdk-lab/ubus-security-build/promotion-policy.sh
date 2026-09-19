#!/bin/sh
set -eu

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

channel=${1:-}
[ -n "$channel" ] || {
	printf 'usage: %s {native-atomic|comparison-only} PACKAGE...\n' "$0" >&2
	exit 2
}
shift

case "$channel" in
	native-atomic)
		[ "$#" -eq 3 ] ||
			fail 'native promotion must contain exactly client, daemon and libubus'
		tmp=$(mktemp -d /tmp/sbe-ubus-promotion.XXXXXX)
		cleanup() {
			case "$tmp" in
				/tmp/sbe-ubus-promotion.*|/var/tmp/sbe-ubus-promotion.*)
					rm -rf "$tmp"
					;;
			esac
		}
		trap cleanup EXIT HUP INT TERM
		printf '%s\n' "$@" | LC_ALL=C sort > "$tmp/actual"
		cat > "$tmp/expected" <<'EOF'
sbe-libubus20210603-security-candidate
sbe-ubus2022-security-candidate
sbe-ubusd2022-security-candidate
EOF
		cmp -s "$tmp/expected" "$tmp/actual" ||
			fail 'native promotion differs from the locked three-package atomic set'
		printf 'PASS: native client, daemon and libubus selection is atomic\n'
		;;
	comparison-only)
		[ "$#" -eq 1 ] ||
			fail 'comparison-only selection must contain exactly one package'
		[ "$1" = sbe-libubus-lua2022-comparison-only ] ||
			fail 'only this build\047s Lua binding is comparison-only'
		printf 'PASS: local Lua binding is comparison-only and not promotable\n'
		;;
	*)
		printf 'usage: %s {native-atomic|comparison-only} PACKAGE...\n' "$0" >&2
		exit 2
		;;
esac
