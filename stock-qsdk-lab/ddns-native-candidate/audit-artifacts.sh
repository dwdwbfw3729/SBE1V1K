#!/bin/sh
set -eu

candidate_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$candidate_dir/sources.lock"
output=${1:-"$candidate_dir/candidate-out/ddns-native"}
source_root=${2:-${QSDK_SOURCE_ROOT:-}}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

find_one() {
	result=$(find "$output" -maxdepth 1 -type f -name "$1" | LC_ALL=C sort)
	[ "$(printf '%s\n' "$result" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 1 ] || fail "expected one artifact matching $1"
	printf '%s\n' "$result"
}

control_text() {
	tar -xOzf "$1" ./control.tar.gz | tar -xOzf - ./control
}

payload_list() {
	tar -xOzf "$1" ./data.tar.gz | tar -tzf -
}

has_payload() {
	payload_list "$1" | grep -Fqx ".$2" || fail "missing payload $2 in $(basename "$1")"
}

ddns=$(find_one 'ddns-scripts_2.7.8-14_all.ipk')
cloudflare=$(find_one 'ddns-scripts_cloudflare.com-v4_2.7.8-14_all.ipk')
ipkg=$(find_one 'luci-lib-ipkg_*_all.ipk')
app=$(find_one 'luci-app-ddns_2.4.9-7_all.ipk')
zhcn=$(find_one 'luci-i18n-ddns-zh-cn_2.4.9-7_all.ipk')

ddns_control=$(control_text "$ddns")
cloudflare_control=$(control_text "$cloudflare")
ipkg_control=$(control_text "$ipkg")
app_control=$(control_text "$app")
zhcn_control=$(control_text "$zhcn")

printf '%s\n' "$ddns_control" | grep -Fqx 'Package: ddns-scripts' || fail 'wrong ddns-scripts package name'
printf '%s\n' "$ddns_control" | grep -Fqx "Version: $DDNS_SCRIPTS_VERSION" || fail 'wrong ddns-scripts version'
printf '%s\n' "$ddns_control" | grep -q '^Depends:' && fail 'locked ddns-scripts unexpectedly gained a hard dependency'
printf '%s\n' "$cloudflare_control" | grep -Fqx 'Package: ddns-scripts_cloudflare.com-v4' || fail 'wrong Cloudflare extension package name'
printf '%s\n' "$cloudflare_control" | grep -Fqx "Version: $DDNS_SCRIPTS_VERSION" || fail 'wrong Cloudflare extension version'
for dep in ddns-scripts curl; do
	printf '%s\n' "$cloudflare_control" | grep -Eq "^Depends: .*${dep}" || fail "Cloudflare extension lacks dependency $dep"
done
printf '%s\n' "$ipkg_control" | grep -Fqx 'Package: luci-lib-ipkg' || fail 'wrong luci-lib-ipkg package name'
printf '%s\n' "$ipkg_control" | grep -Eq '^Version: git-22\.283\.[0-9]{5}-4b50d79-1$' || fail 'luci-lib-ipkg is not bound to LuCI 4b50d79'
printf '%s\n' "$ipkg_control" | grep -Eq '^Depends: .*luci-base' || fail 'luci-lib-ipkg lacks luci-base dependency'
printf '%s\n' "$app_control" | grep -Fqx 'Package: luci-app-ddns' || fail 'wrong luci-app-ddns package name'
printf '%s\n' "$app_control" | grep -Fqx "Version: $LUCI_APP_DDNS_VERSION" || fail 'wrong luci-app-ddns version'
for dep in luci-compat luci-lib-ipkg luci-mod-admin-full ddns-scripts; do
	printf '%s\n' "$app_control" | grep -Eq "^Depends: .*${dep}" || fail "luci-app-ddns lacks dependency $dep"
done
printf '%s\n' "$zhcn_control" | grep -Fqx 'Package: luci-i18n-ddns-zh-cn' || fail 'wrong Chinese translation package name'
printf '%s\n' "$zhcn_control" | grep -Fqx "Version: $LUCI_APP_DDNS_VERSION" || fail 'wrong Chinese translation version'
printf '%s\n' "$zhcn_control" | grep -Eq '^Depends: .*luci-app-ddns' || fail 'Chinese translation lacks luci-app-ddns dependency'

for path in \
	/etc/config/ddns \
	/etc/ddns/services \
	/etc/ddns/services_ipv6 \
	/etc/hotplug.d/iface/95-ddns \
	/etc/init.d/ddns \
	/usr/lib/ddns/dynamic_dns_functions.sh \
	/usr/lib/ddns/dynamic_dns_lucihelper.sh \
	/usr/lib/ddns/dynamic_dns_updater.sh; do
	has_payload "$ddns" "$path"
done
has_payload "$ipkg" /usr/lib/lua/luci/model/ipkg.lua
has_payload "$app" /usr/lib/lua/luci/controller/ddns.lua
has_payload "$app" /usr/lib/lua/luci/model/cbi/ddns/detail.lua
has_payload "$app" /usr/lib/lua/luci/tools/ddns.lua
has_payload "$zhcn" /usr/lib/lua/luci/i18n/ddns.zh-cn.lmo
has_payload "$cloudflare" /etc/uci-defaults/ddns_cloudflare.com-v4
has_payload "$cloudflare" /usr/lib/ddns/update_cloudflare_com_v4.sh

if payload_list "$ddns" | grep -Eq 'sbe-ddns|cloudflare'; then
	fail 'core DDNS artifact contains custom or optional Cloudflare payload'
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/sbe-ddns-native-audit.XXXXXX")
cleanup() {
	case "$tmp" in */sbe-ddns-native-audit.*) rm -rf "$tmp" ;; esac
}
trap cleanup EXIT HUP INT TERM
for pair in "$ddns:ddns" "$cloudflare:cloudflare" "$ipkg:ipkg" "$app:app" "$zhcn:zhcn"; do
	ipk_path=${pair%%:*}
	name=${pair#*:}
	mkdir -p "$tmp/$name"
	tar -xOzf "$ipk_path" ./data.tar.gz | tar -xzf - -C "$tmp/$name"
done

services4=$(awk '/^"/{n++} END{print n+0}' "$tmp/ddns/etc/ddns/services")
services6=$(awk '/^"/{n++} END{print n+0}' "$tmp/ddns/etc/ddns/services_ipv6")
[ "$services4" -eq 72 ] || fail "expected 72 IPv4 provider definitions, found $services4"
[ "$services6" -eq 34 ] || fail "expected 34 IPv6 provider definitions, found $services6"
grep -Fq 'io.open("/etc/ddns/services", "r")' "$tmp/app/usr/lib/lua/luci/model/cbi/ddns/detail.lua" || fail 'LuCI no longer consumes the matching provider format'
grep -Fq 'io.open("/etc/ddns/services_ipv6", "r")' "$tmp/app/usr/lib/lua/luci/model/cbi/ddns/detail.lua" || fail 'LuCI no longer consumes the matching IPv6 provider format'
grep -Eq '^[[:space:]]*option[[:space:]]+enabled' "$tmp/ddns/etc/config/ddns" && fail 'sample DDNS services unexpectedly default to enabled'
[ -s "$tmp/zhcn/usr/lib/lua/luci/i18n/ddns.zh-cn.lmo" ] || fail 'Chinese translation catalog is empty'

cf=$tmp/cloudflare/usr/lib/ddns/update_cloudflare_com_v4.sh
grep -Fq 'https://api.cloudflare.com/client/v4' "$cf" || fail 'Cloudflare extension no longer targets API v4'
grep -Fq 'X-Auth-Email:' "$cf" || fail 'Cloudflare extension authentication shape changed'
grep -Fq 'X-Auth-Key:' "$cf" || fail 'Cloudflare extension authentication shape changed'
grep -Fq '/zones?name=' "$cf" || fail 'Cloudflare zone lookup endpoint shape changed'
grep -Fq '/dns_records?name=' "$cf" || fail 'Cloudflare record lookup endpoint shape changed'
grep -Fq -- '--request PUT' "$cf" || fail 'Cloudflare record overwrite endpoint shape changed'
grep -Fq '[ $use_https -eq 0 ] && use_https=1' "$cf" || fail 'Cloudflare extension no longer forces HTTPS'

if [ -n "$source_root" ]; then
	[ "$(git -C "$source_root/qsdk/qca/feeds/packages" rev-parse 'HEAD:net/ddns-scripts')" = "$OPENWRT_1907_DDNS_SCRIPTS_TREE" ] || fail 'built ddns-scripts source is not the locked official 19.07 tree'
	[ "$(git -C "$source_root/qsdk/qca/feeds/luci" rev-parse 'HEAD:applications/luci-app-ddns')" = "$OPENWRT_1907_LUCI_APP_DDNS_TREE" ] || fail 'built LuCI DDNS source is not the locked official 19.07 tree'
	luac=$source_root/qsdk/staging_dir/hostpkg/bin/luac
	if [ -x "$luac" ]; then
		find "$tmp/app" "$tmp/ipkg" -type f -name '*.lua' -exec "$luac" -p '{}' '+'
	fi
fi

printf 'PASS: package identity, dependencies, native payload, provider-format pairing, disabled defaults, Cloudflare API-v4 request shape, Chinese catalog, and source binding verified\n'
printf 'NOTE: 72/34 counts are historical provider definitions, not a claim that every 2026 provider API remains operational.\n'
printf 'NOTE: the optional Cloudflare helper uses a legacy Global API Key, not a scoped Bearer token; it is built for compatibility and remains disabled until configured.\n'
