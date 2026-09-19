#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$build_dir/../.." && pwd)
workspace_parent=$(CDPATH= cd -- "$repo_root/.." && pwd)
source_root=${1:-${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}}
qsdk_dir=$source_root/qsdk
. "$build_dir/sources.lock"

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

sha256_file() {
	sha256sum "$1" | awk '{print $1}'
}

[ -f "$qsdk_dir/Makefile" ] || fail "locked QSDK tree is missing: $qsdk_dir"
[ -f "$qsdk_dir/.config" ] || fail 'shared QSDK .config is missing'
[ "$(sha256_file "$qsdk_dir/.config")" = "$QSDK_BASE_CONFIG_SHA256" ] ||
	fail 'shared QSDK .config differs from the released lock'

ncurses_recipe=$qsdk_dir/package/libs/ncurses/Makefile
stock_mtr_recipe=$qsdk_dir/qca/feeds/packages/net/mtr/Makefile
stock_htop_recipe=$qsdk_dir/qca/feeds/packages/admin/htop/Makefile
stock_nano_recipe=$qsdk_dir/qca/feeds/packages/utils/nano/Makefile
for recipe in "$ncurses_recipe" "$stock_mtr_recipe" "$stock_htop_recipe" "$stock_nano_recipe"
do
	[ -f "$recipe" ] || fail "required QSDK recipe is missing: $recipe"
done

[ "$(sha256_file "$ncurses_recipe")" = "$QSDK_NCURSES_RECIPE_SHA256" ] ||
	fail 'stock ncurses recipe changed since ABI review'
[ "$(sha256_file "$stock_mtr_recipe")" = "$QSDK_STOCK_MTR_RECIPE_SHA256" ] ||
	fail 'stock mtr baseline recipe changed'
[ "$(sha256_file "$stock_htop_recipe")" = "$QSDK_STOCK_HTOP_RECIPE_SHA256" ] ||
	fail 'stock htop baseline recipe changed'
[ "$(sha256_file "$stock_nano_recipe")" = "$QSDK_STOCK_NANO_RECIPE_SHA256" ] ||
	fail 'stock nano baseline recipe changed'

grep -F -q "PKG_VERSION:=$QSDK_NCURSES_VERSION" "$ncurses_recipe" ||
	fail 'stock ncurses version differs from the ABI lock'
grep -F -q "ABI_VERSION:=$QSDK_NCURSES_ABI" "$ncurses_recipe" ||
	fail 'stock libncurses ABI differs from the lock'
grep -q '^\s*--enable-widec' "$ncurses_recipe" ||
	fail 'stock ncurses no longer builds the wide-character ABI'
grep -q '^\s*--disable-rpath' "$ncurses_recipe" ||
	fail 'stock ncurses no longer disables RPATH'
grep -q '^CONFIG_PACKAGE_libncurses=m$' "$qsdk_dir/.config" ||
	fail 'released QSDK config does not retain libncurses as a module'

printf 'PASS: released QSDK config and stock ncurses %s ABI %s are unchanged; no build ran.\n' \
	"$QSDK_NCURSES_VERSION" "$QSDK_NCURSES_ABI"
