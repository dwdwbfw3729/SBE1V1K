#!/bin/sh
set -eu

candidate_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$candidate_dir/../.." && pwd)
workspace_parent=$(CDPATH= cd -- "$repo_root/.." && pwd)
. "$candidate_dir/sources.lock"

source_root=${1:-${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}}
qsdk=$source_root/qsdk
packages=$qsdk/qca/feeds/packages
luci=$qsdk/qca/feeds/luci
output=${DDNS_NATIVE_OUTPUT:-"$candidate_dir/candidate-out/ddns-native"}
jobs=${QSDK_JOBS:-4}

export LC_ALL=C
export TZ=UTC
export SOURCE_DATE_EPOCH

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

sha256_file() {
	sha256sum "$1" | awk '{print $1}'
}

assert_sha256() {
	actual=$(sha256_file "$1")
	[ "$actual" = "$2" ] || fail "source hash mismatch: $1"
}

[ "$(uname -s)" = Linux ] || fail 'native DDNS IPKs must be built inside Linux'
[ -f "$qsdk/Makefile" ] || fail "locked QSDK tree is missing: $qsdk"
[ -f "$qsdk/.config" ] || fail 'locked QSDK .config is missing'
[ "$(git -C "$qsdk" rev-parse HEAD)" = "$QSDK_TOP_COMMIT" ] || fail 'wrong QSDK commit'
[ "$(git -C "$packages" rev-parse HEAD)" = "$QSDK_PACKAGES_COMMIT" ] || fail 'wrong packages feed commit'
[ "$(git -C "$luci" rev-parse HEAD)" = "$QSDK_LUCI_COMMIT" ] || fail 'wrong LuCI commit'
[ "$(git -C "$packages" rev-parse 'HEAD:net/ddns-scripts')" = "$DDNS_SCRIPTS_TREE" ] || fail 'wrong ddns-scripts source tree'
[ "$(git -C "$luci" rev-parse 'HEAD:applications/luci-app-ddns')" = "$LUCI_APP_DDNS_TREE" ] || fail 'wrong luci-app-ddns source tree'
[ "$(git -C "$luci" rev-parse 'HEAD:libs/luci-lib-ipkg')" = "$LUCI_LIB_IPKG_TREE" ] || fail 'wrong luci-lib-ipkg source tree'
[ "$(sha256_file "$qsdk/.config")" = "$QSDK_BASE_CONFIG_SHA256" ] || fail 'shared QSDK .config is not the released baseline'

assert_sha256 "$packages/net/ddns-scripts/Makefile" "$DDNS_MAKEFILE_SHA256"
assert_sha256 "$packages/net/ddns-scripts/files/services" "$DDNS_SERVICES4_SHA256"
assert_sha256 "$packages/net/ddns-scripts/files/services_ipv6" "$DDNS_SERVICES6_SHA256"
assert_sha256 "$packages/net/ddns-scripts/files/update_cloudflare_com_v4.sh" "$DDNS_CLOUDFLARE_V4_SHA256"
assert_sha256 "$luci/applications/luci-app-ddns/Makefile" "$LUCI_APP_DDNS_MAKEFILE_SHA256"
assert_sha256 "$luci/applications/luci-app-ddns/po/zh_Hans/ddns.po" "$LUCI_DDNS_ZH_HANS_SHA256"
assert_sha256 "$luci/libs/luci-lib-ipkg/Makefile" "$LUCI_LIB_IPKG_MAKEFILE_SHA256"

mkdir -p "$output"
config_backup=$(mktemp "${TMPDIR:-/tmp}/sbe-ddns-native-config.XXXXXX")
old_config_backup=$(mktemp "${TMPDIR:-/tmp}/sbe-ddns-native-old-config.XXXXXX")
defconfig_log=$(mktemp "${TMPDIR:-/tmp}/sbe-ddns-native-defconfig.XXXXXX")
cp "$qsdk/.config" "$config_backup"
had_old_config=0
if [ -f "$qsdk/.config.old" ]; then
	had_old_config=1
	cp "$qsdk/.config.old" "$old_config_backup"
fi

cleanup() {
	cp "$config_backup" "$qsdk/.config"
	if [ "$had_old_config" -eq 1 ]; then
		cp "$old_config_backup" "$qsdk/.config.old"
	else
		rm -f "$qsdk/.config.old"
	fi
	rm -f "$config_backup" "$old_config_backup" "$defconfig_log"
}
trap cleanup EXIT HUP INT TERM

cp "$candidate_dir/candidate.config" "$qsdk/.config"
make -C "$qsdk" defconfig >"$defconfig_log" 2>&1 || {
	cat "$defconfig_log" >&2
	fail 'QSDK defconfig failed for native DDNS packages'
}

for selected in \
	CONFIG_PACKAGE_ddns-scripts=m \
	CONFIG_PACKAGE_ddns-scripts_cloudflare.com-v4=m \
	CONFIG_PACKAGE_luci-lib-ipkg=m \
	CONFIG_PACKAGE_luci-app-ddns=m \
	CONFIG_PACKAGE_luci-i18n-ddns-zh-cn=m; do
	grep -Fqx "$selected" "$qsdk/.config" || fail "defconfig did not retain $selected"
done
for excluded in \
	CONFIG_PACKAGE_ddns-scripts_freedns_42_pl \
	CONFIG_PACKAGE_ddns-scripts_godaddy.com-v1 \
	CONFIG_PACKAGE_ddns-scripts_nsupdate \
	CONFIG_PACKAGE_ddns-scripts_route53-v1; do
	if grep -Eq "^${excluded}=[ym]$" "$qsdk/.config"; then
		fail "defconfig unexpectedly selected optional provider extension $excluded"
	fi
done

cp "$qsdk/.config" "$output/CANDIDATE_BUILD_CONFIG"
build_config_sha=$(sha256_file "$qsdk/.config")

make -C "$qsdk" package/feeds/packages/ddns-scripts/clean
make -C "$qsdk" package/feeds/luci/luci-lib-ipkg/clean
make -C "$qsdk" package/feeds/luci/luci-app-ddns/clean

make -C "$qsdk" -j"$jobs" NO_DEPS=1 \
	package/feeds/packages/ddns-scripts/compile \
	package/feeds/luci/luci-lib-ipkg/compile \
	package/feeds/luci/luci-app-ddns/compile V=s

[ "$(sha256_file "$qsdk/.config")" = "$build_config_sha" ] || fail 'temporary build configuration changed during compilation'

find "$output" -maxdepth 1 -type f -name '*.ipk' -delete
found=0
for pattern in \
	'ddns-scripts_2.7.8-14_all.ipk' \
	'ddns-scripts_cloudflare.com-v4_2.7.8-14_all.ipk' \
	'luci-lib-ipkg_*_all.ipk' \
	'luci-app-ddns_2.4.9-7_all.ipk' \
	'luci-i18n-ddns-zh-cn_2.4.9-7_all.ipk'; do
	artifact=$(find "$qsdk/bin" -type f -name "$pattern" | LC_ALL=C sort)
	[ "$(printf '%s\n' "$artifact" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 1 ] || fail "expected one artifact matching $pattern"
	cp "$artifact" "$output/"
	found=$((found + 1))
done
[ "$found" -eq 5 ] || fail "expected five native DDNS IPKs, found $found"

(cd "$output" && sha256sum ./*.ipk > PACKAGE_SHA256SUMS)
printf 'BUILT, NOT DEPLOYED: five source-bound native DDNS IPKs are in %s\n' "$output"
printf 'No image, kernel, rootfs, device, or network DDNS operation was invoked.\n'
