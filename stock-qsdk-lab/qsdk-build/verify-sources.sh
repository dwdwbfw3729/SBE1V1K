#!/bin/sh
set -eu

lab_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$lab_dir/../.." && pwd)
workspace_root=$(CDPATH= cd -- "$repo_root/.." && pwd)
. "$lab_dir/sources.lock"

source_root=${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}
qsdk_dir=$source_root/qsdk
source_prep_gate=0

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

# Rebuild the tracked tree through a clean external Git directory.  This does
# not trust the checkout index (and therefore cannot be bypassed with
# assume-unchanged or skip-worktree bits), nor any system/global/local filter
# configuration.  Untracked and ignored entries are inventoried separately.
verify_source_prep_tree() (
	label=$1
	directory=$2
	expected_tree=$3

	audit_root=$(mktemp -d "$source_root/.sbe-source-audit.XXXXXX") || exit 1
	trap 'rm -rf "$audit_root"' EXIT HUP INT TERM
	audit_git=$audit_root/repo.git
	audit_index=$audit_root/index
	GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
		git init -q --bare "$audit_git"
	source_git=$(git -C "$directory" rev-parse --absolute-git-dir)
	source_objects=$(CDPATH= cd -- "$source_git/objects" && pwd -P)

	GIT_ALTERNATE_OBJECT_DIRECTORIES=$source_objects \
		GIT_ATTR_NOSYSTEM=1 GIT_CONFIG_NOSYSTEM=1 \
		GIT_CONFIG_GLOBAL=/dev/null GIT_INDEX_FILE=$audit_index \
		git --git-dir="$audit_git" read-tree "$expected_tree"
	GIT_ALTERNATE_OBJECT_DIRECTORIES=$source_objects \
		GIT_ATTR_NOSYSTEM=1 GIT_CONFIG_NOSYSTEM=1 \
		GIT_CONFIG_GLOBAL=/dev/null GIT_INDEX_FILE=$audit_index \
		git --git-dir="$audit_git" --work-tree="$directory" \
		-c core.bare=false -c core.autocrlf=false -c core.filemode=true \
		add -u -- .
	actual_tree=$(GIT_ALTERNATE_OBJECT_DIRECTORIES=$source_objects \
		GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
		GIT_INDEX_FILE=$audit_index \
		git --git-dir="$audit_git" write-tree)
	[ "$actual_tree" = "$expected_tree" ] || \
		fail "$label source-preparation filesystem tree differs: $actual_tree"

	# The OpenWrt root deliberately contains five separately locked worktrees
	# beneath ignored paths.  Exclude exactly those roots here; each is audited
	# independently by verify_repo.  Everything else, including ignored build
	# output, remains forbidden at the preparation gate.
	if [ "$label" = OpenWrt ]; then
		unexpected=$(
			GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
				git -C "$directory" ls-files --others --exclude-standard -- . \
				':(top,exclude)qsdk-package/**' \
				':(top,exclude)qca/src/linux-5.4/**' \
				':(top,exclude)qca/feeds/packages/**' \
				':(top,exclude)qca/feeds/luci/**' \
				':(top,exclude)qca/configs/qsdk/**'
			GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
				git -C "$directory" ls-files --others --ignored \
				--exclude-standard -- . \
				':(top,exclude)qsdk-package/**' \
				':(top,exclude)qca/src/linux-5.4/**' \
				':(top,exclude)qca/feeds/packages/**' \
				':(top,exclude)qca/feeds/luci/**' \
				':(top,exclude)qca/configs/qsdk/**'
			printf '%s\n' __SBE_INVENTORY_END__
		)
	else
		unexpected=$(
			GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
				git -C "$directory" ls-files --others --exclude-standard
			GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
				git -C "$directory" ls-files --others --ignored \
				--exclude-standard
			printf '%s\n' __SBE_INVENTORY_END__
		)
	fi
	[ "$unexpected" = __SBE_INVENTORY_END__ ] || {
		printf '%s\n' "$unexpected" >&2
		fail "$label source-preparation gate found untracked or ignored residue"
	}
)

verify_repo() {
	label=$1
	directory=$2
	expected_url=$3
	expected_mirror=$4
	expected_proxy=$5
	expected_cn_mirror=$6
	expected_commit=$7
	expected_tree=$8

	[ -d "$directory/.git" ] || fail "$label repository is missing: $directory"
	actual_url=$(git -C "$directory" remote get-url origin)
	[ "$actual_url" = "$expected_url" ] || fail "$label origin differs: $actual_url"
	actual_mirror=$(git -C "$directory" remote get-url mirror 2>/dev/null || true)
	[ "$actual_mirror" = "$expected_mirror" ] || \
		fail "$label verified transport mirror differs: ${actual_mirror:-missing}"
	actual_proxy=$(git -C "$directory" remote get-url proxy 2>/dev/null || true)
	if [ -n "$actual_proxy" ]; then
		[ "$actual_proxy" = "$expected_proxy" ] || \
			fail "$label proxy transport differs: $actual_proxy"
	fi
	actual_cn_mirror=$(git -C "$directory" remote get-url cnmirror 2>/dev/null || true)
	if [ -n "$actual_cn_mirror" ]; then
		[ -n "$expected_cn_mirror" ] && [ "$actual_cn_mirror" = "$expected_cn_mirror" ] || \
			fail "$label China mirror transport differs: $actual_cn_mirror"
	fi
	[ "$(git -C "$directory" config --local --get core.autocrlf 2>/dev/null || true)" = false ] || \
		fail "$label must disable autocrlf for byte-exact source trees"
	actual_locked=$(git -C "$directory" rev-parse refs/sbe/locked 2>/dev/null || true)
	[ "$actual_locked" = "$expected_commit" ] || \
		fail "$label locked ref differs: ${actual_locked:-missing}"
	actual_tree=$(git -C "$directory" rev-parse "$expected_commit^{tree}")
	if [ -n "$expected_tree" ]; then
		[ "$actual_tree" = "$expected_tree" ] || fail "$label tree differs: $actual_tree"
	fi

	metadata=$(git -C "$directory" config --bool --get sbe.metadataOnly 2>/dev/null || true)
	if [ "$metadata" != true ]; then
		actual_head=$(git -C "$directory" rev-parse HEAD)
		[ "$actual_head" = "$expected_commit" ] || fail "$label HEAD differs: $actual_head"
		[ -z "$(git -C "$directory" status --porcelain --untracked-files=no)" ] || \
			fail "$label tracked worktree is incomplete or dirty"
		if [ "$source_prep_gate" = 1 ]; then
			[ "$(git -C "$directory" config --get sbe.materializedTree 2>/dev/null || true)" = \
				"$expected_tree" ] || fail "$label has no matching clean-materialisation seal"
			verify_source_prep_tree "$label" "$directory" "$expected_tree"
		fi
	fi
	printf 'PASS  %-12s %s\n' "$label" "$expected_commit"
}

verify_repo OpenWrt "$qsdk_dir" "$QSDK_OPENWRT_URL" "$QSDK_OPENWRT_MIRROR_URL" \
	"$QSDK_OPENWRT_PROXY_URL" "$QSDK_OPENWRT_CN_MIRROR_URL" \
	"$QSDK_OPENWRT_COMMIT" "$QSDK_OPENWRT_TREE"
verify_repo patches "$qsdk_dir/qsdk-package" "$QSDK_PATCHES_URL" "$QSDK_PATCHES_MIRROR_URL" \
	"$QSDK_PATCHES_PROXY_URL" "$QSDK_PATCHES_CN_MIRROR_URL" \
	"$QSDK_PATCHES_COMMIT" "$QSDK_PATCHES_TREE"
verify_repo kernel "$qsdk_dir/qca/src/linux-5.4" "$QSDK_KERNEL_URL" "$QSDK_KERNEL_MIRROR_URL" \
	"$QSDK_KERNEL_PROXY_URL" "$QSDK_KERNEL_CN_MIRROR_URL" \
	"$QSDK_KERNEL_COMMIT" "$QSDK_KERNEL_TREE"
verify_repo packages "$qsdk_dir/qca/feeds/packages" "$QSDK_PACKAGES_URL" "$QSDK_PACKAGES_MIRROR_URL" \
	"$QSDK_PACKAGES_PROXY_URL" "$QSDK_PACKAGES_CN_MIRROR_URL" \
	"$QSDK_PACKAGES_COMMIT" "$QSDK_PACKAGES_TREE"
verify_repo LuCI "$qsdk_dir/qca/feeds/luci" "$QSDK_LUCI_URL" "$QSDK_LUCI_MIRROR_URL" \
	"$QSDK_LUCI_PROXY_URL" "$QSDK_LUCI_CN_MIRROR_URL" \
	"$QSDK_LUCI_COMMIT" "$QSDK_LUCI_TREE"
verify_repo configs "$qsdk_dir/qca/configs/qsdk" "$QSDK_CONFIGS_URL" "$QSDK_CONFIGS_MIRROR_URL" \
	"$QSDK_CONFIGS_PROXY_URL" "$QSDK_CONFIGS_CN_MIRROR_URL" \
	"$QSDK_CONFIGS_COMMIT" "$QSDK_CONFIGS_TREE"

manifest=$source_root/release-manifest/$QSDK_MANIFEST_XML
[ -f "$manifest" ] || fail "release manifest is missing: $manifest"
[ "$(sha256_file "$manifest")" = "$QSDK_MANIFEST_XML_SHA256" ] || \
	fail 'release manifest checksum differs'

metadata=$(git -C "$qsdk_dir" config --bool --get sbe.metadataOnly 2>/dev/null || true)
if [ "$metadata" = true ]; then
	printf '\nPASS: locked Git objects verified in metadata-only mode.\n'
	printf 'Run fetch-sources.sh without QSDK_METADATA_ONLY before content/build checks.\n'
	exit 0
fi

kernel_makefile=$qsdk_dir/qca/src/linux-5.4/Makefile
[ -f "$kernel_makefile" ] || fail 'kernel checkout is metadata-only; a build checkout is required'
version=$(awk '$1 == "VERSION" {print $3; exit}' "$kernel_makefile")
patchlevel=$(awk '$1 == "PATCHLEVEL" {print $3; exit}' "$kernel_makefile")
sublevel=$(awk '$1 == "SUBLEVEL" {print $3; exit}' "$kernel_makefile")
[ "$version.$patchlevel.$sublevel" = "$FACTORY_KERNEL_RELEASE" ] || \
	fail "public kernel reports $version.$patchlevel.$sublevel, expected $FACTORY_KERNEL_RELEASE"

grep -q 'ifeq ($(PKG_VERSION),7.5.0)' "$qsdk_dir/toolchain/gcc/common.mk" || \
	fail 'locked OpenWrt tree does not contain the GCC 7.5.0 recipe'
grep -q 'PKG_VERSION:=1.1.24' "$qsdk_dir/toolchain/musl/common.mk" || \
	fail 'locked OpenWrt tree does not contain musl 1.1.24'
grep -q 'PKG_SOURCE_VERSION:=ea9525c8bcf6170df59364c4bcd616de1acf8703' \
	"$qsdk_dir/toolchain/musl/common.mk" || fail 'musl source revision differs'
grep -q 'PKG_VERSION:=1.8.3' "$qsdk_dir/package/network/utils/iptables/Makefile" || \
	fail 'iptables source is not the factory-compatible 1.8.3 line'
grep -q 'CONFIG_NF_TPROXY_IPV4' "$qsdk_dir/include/netfilter.mk" || \
	fail 'QSDK netfilter definitions do not include NF_TPROXY_IPV4'
grep -q 'CONFIG_NETFILTER_XT_MATCH_IPRANGE' "$qsdk_dir/include/netfilter.mk" || \
	fail 'QSDK netfilter definitions do not include xt_iprange'

setup=$qsdk_dir/qca/configs/qsdk/setup-environment
[ "$(sha256_file "$setup")" = "$QSDK_SETUP_ENVIRONMENT_SHA256" ] || \
	fail 'Qualcomm setup-environment checksum differs'

for pair in \
	"clo/qsdk/oss/system/openwrt_repo $QSDK_OPENWRT_COMMIT" \
	"clo/qsdk/oss/system/openwrt-patches $QSDK_PATCHES_COMMIT" \
	"clo/qsdk/oss/kernel/linux-ipq-5.4 $QSDK_KERNEL_COMMIT" \
	"clo/qsdk/oss/system/feeds/packages $QSDK_PACKAGES_COMMIT" \
	"clo/qsdk/oss/system/feeds/luci $QSDK_LUCI_COMMIT" \
	"clo/qsdk/oss/releases/configs/qsdk $QSDK_CONFIGS_COMMIT"
do
	project=${pair% *}
	commit=${pair#* }
	grep -q "name=\"$project\".*revision=\"$commit\"" "$manifest" || \
		fail "release manifest does not lock $project at $commit"
done

if [ "$FACTORY_OPENWRT_COMMIT" = "$QSDK_OPENWRT_COMMIT" ]; then
	fail 'factory/private and public OpenWrt commits unexpectedly collapsed'
fi

printf '\nPASS: public QSDK 12.2 sources are internally exact.\n'
if [ "$source_prep_gate" = 1 ]; then
	printf 'PASS: source-preparation gate found no tracked, untracked, or ignored residue.\n'
fi
printf 'BLOCKED: they are not proven identical to factory OpenWrt %s.\n' "$FACTORY_OPENWRT_COMMIT"
printf '         Kernel modules still require stock-config and RAM-only ABI gates.\n'
