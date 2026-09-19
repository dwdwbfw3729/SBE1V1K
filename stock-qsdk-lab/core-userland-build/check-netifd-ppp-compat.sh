#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_root=${1:-${QSDK_SOURCE_ROOT:-}}
[ -n "$source_root" ] || {
	printf 'usage: %s QSDK_SOURCE_ROOT\n' "$0" >&2
	exit 2
}

script=$source_root/qsdk/package/network/services/ppp/files/ppp.sh
recipe=$build_dir/package-overlay/sbe-ppp254-candidate/Makefile
[ -f "$script" ] || {
	printf 'ERROR: locked QSDK PPP netifd helper is missing: %s\n' "$script" >&2
	exit 1
}

require() {
	grep -Fq -- "$2" "$1" || {
		printf 'ERROR: %s lacks compatibility contract: %s\n' "$1" "$2" >&2
		exit 1
	}
}

require "$script" 'plugin rp-pppoe.so'
require "$script" 'rp_pppoe_ac "$ac"'
require "$script" 'rp_pppoe_service "$service"'
require "$script" 'pppoe-padi-attempts $padi_attempts'
require "$script" 'pppoe-padi-timeout $padi_timeout'
require "$script" '[ -f /usr/lib/pppd/*/rp-pppoe.so ] && add_protocol pppoe'
require "$recipe" '--with-plugin-dir=/usr/lib/pppd/2.5.4'
require "$recipe" '$(1)/usr/lib/pppd/2.5.4/rp-pppoe.so'

printf 'PASS: locked QSDK 19.07 netifd helper names rp-pppoe.so by basename and discovers the 2.5.4 wildcard plugin directory.\n'
printf 'BLOCKED: actual ISP PADI/PADO/PADR/PADS negotiation remains a RAM-only hardware gate.\n'
