#!/bin/sh
set -eu

lab_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$lab_dir/../.." && pwd)
workspace_root=$(CDPATH= cd -- "$repo_root/.." && pwd)
. "$lab_dir/sources.lock"

stock_config=${1:-${STOCK_KERNEL_CONFIG:-}}
source_root=${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}
kernel_dir=${QSDK_KERNEL_DIR:-"$source_root/qsdk/qca/src/linux-5.4"}
build_dir=${QSDK_KERNEL_BUILD_DIR:-"$lab_dir/work/kernel-stock-passwall"}
output_dir=${QSDK_KMOD_OUTPUT:-"$lab_dir/out/kmods"}
cross=${QSDK_CROSS_COMPILE:-}
jobs=${QSDK_JOBS:-4}
allow_public_config_drift=${QSDK_ALLOW_PUBLIC_KCONFIG_DRIFT:-0}
profile=${QSDK_KMOD_PROFILE:-passwall}
case "$profile" in
	passwall) fragment=$lab_dir/kernel-passwall.fragment ;;
	openwrt-common) fragment=$lab_dir/kernel-openwrt-common.fragment ;;
	*) printf 'ERROR: unknown module profile: %s\n' "$profile" >&2; exit 1 ;;
esac
strip_kmod=$source_root/qsdk/scripts/strip-kmod.sh
compat_header=$lab_dir/passwall-udp-lookup-compat.h
staging_dir=${STAGING_DIR:-"$source_root/qsdk/staging_dir"}
build_timestamp=${KBUILD_BUILD_TIMESTAMP:-'Fri Aug 30 14:35:44 UTC 2024'}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

locked_kernel_git() {
	GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
		git -c safe.directory="$kernel_dir" -C "$kernel_dir" "$@"
}

# Status is a useful diagnostic, but checkout index flags and ignore rules are
# not an integrity boundary.  Force-index every filesystem entry through an
# external empty repository before allowing kernel compilation.
audit_locked_kernel_filesystem() (
	audit_root=$(mktemp -d "${TMPDIR:-/tmp}/sbe-kernel-source-audit.XXXXXX") || exit 1
	trap 'rm -rf "$audit_root"' EXIT HUP INT TERM
	audit_git=$audit_root/repo.git
	audit_index=$audit_root/index
	GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
		git init -q --bare "$audit_git"
	GIT_ATTR_NOSYSTEM=1 GIT_CONFIG_NOSYSTEM=1 \
		GIT_CONFIG_GLOBAL=/dev/null GIT_INDEX_FILE=$audit_index \
		git --git-dir="$audit_git" --work-tree="$kernel_dir" \
		-c core.bare=false -c core.autocrlf=false -c core.filemode=true \
		add -f -A -- . ':(top,exclude).git'
	filesystem_tree=$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
		GIT_INDEX_FILE=$audit_index git --git-dir="$audit_git" write-tree)
	[ "$filesystem_tree" = "$QSDK_KERNEL_TREE" ] || \
		fail "kernel filesystem includes missing, changed, untracked, or ignored entries: $filesystem_tree"
)

[ "$(uname -s)" = Linux ] || fail 'kernel modules must be built in the Linux QSDK container/host'
command -v strings >/dev/null 2>&1 || fail 'strings is required for module privacy checks'
[ -n "$stock_config" ] || fail 'pass STOCK_CONFIG or set STOCK_KERNEL_CONFIG'
[ -f "$stock_config" ] || fail "stock config is missing: $stock_config"
[ -e "$kernel_dir/.git" ] || fail "locked kernel checkout is missing: $kernel_dir"
[ "$(locked_kernel_git rev-parse HEAD)" = "$QSDK_KERNEL_COMMIT" ] || \
	fail 'kernel checkout is not at the locked public QSDK commit'
[ "$(locked_kernel_git rev-parse 'HEAD^{tree}')" = "$QSDK_KERNEL_TREE" ] || \
	fail 'kernel checkout tree does not match the locked public QSDK tree'
[ -z "$(locked_kernel_git status --porcelain --untracked-files=all --ignored=matching)" ] || \
	fail 'kernel checkout has tracked, untracked, or ignored source changes'
audit_locked_kernel_filesystem
[ -n "$cross" ] || fail 'set QSDK_CROSS_COMPILE to the QSDK aarch64 toolchain prefix'
[ -x "${cross}gcc" ] || fail "cross compiler is missing: ${cross}gcc"
[ -x "$strip_kmod" ] || fail "locked QSDK module stripper is missing: $strip_kmod"
[ -f "$compat_header" ] || fail "UDP lookup compatibility overlay is missing: $compat_header"
if command -v sha256sum >/dev/null 2>&1; then
	compat_header_sha=$(sha256sum "$compat_header" | awk '{print $1}')
else
	compat_header_sha=$(shasum -a 256 "$compat_header" | awk '{print $1}')
fi
[ "$compat_header_sha" = "$PASSWALL_UDP_LOOKUP_COMPAT_SHA256" ] || \
	fail "UDP lookup compatibility overlay hash mismatch: $compat_header_sha"
export STAGING_DIR="$staging_dir"
export KBUILD_BUILD_TIMESTAMP="$build_timestamp"
export KBUILD_BUILD_USER=stock-qsdk-lab
export KBUILD_BUILD_HOST=reproducible
export KBUILD_BUILD_VERSION=0

compiler_version=$("${cross}gcc" -dumpfullversion -dumpversion)
[ "$compiler_version" = "$FACTORY_GCC_VERSION" ] || \
	fail "compiler is GCC $compiler_version, expected $FACTORY_GCC_VERSION"
compiler_machine=$("${cross}gcc" -dumpmachine)
case "$compiler_machine" in
	aarch64*) ;;
	*) fail "compiler target is $compiler_machine, expected AArch64" ;;
esac

if [ -d "$output_dir" ] && find "$output_dir" -type f -name '*.ko' -print -quit | grep -q .; then
	fail "refusing to mix with an existing module output: $output_dir"
fi
mkdir -p "$build_dir" "$output_dir"
cp "$stock_config" "$build_dir/.config.stock"

# First prove the requested configuration really is the captured factory
# config plus only the selected additive module symbols. This pre-normalization
# gate is distinct from the effective public-source config below: olddefconfig
# can legitimately expose an unavailable downstream/factory-source mismatch,
# which remains a release blocker rather than being hidden in the feature
# delta.
cp "$stock_config" "$build_dir/.config.factory-plus-passwall-requested"
config_tool=$kernel_dir/scripts/config
[ -x "$config_tool" ] || fail "kernel scripts/config is missing: $config_tool"
while IFS='=' read -r symbol value; do
	[ -n "$symbol" ] || continue
	[ "$value" = m ] || fail "unexpected fragment value for $symbol: $value"
	"$config_tool" --file "$build_dir/.config.factory-plus-passwall-requested" \
		--module "${symbol#CONFIG_}"
done < "$fragment"
"$lab_dir/verify-kconfig-delta.py" \
	--fragment "$fragment" \
	--stock-sha256 "$FACTORY_KERNEL_CONFIG_SHA256" \
	"$build_dir/.config.stock" "$build_dir/.config.factory-plus-passwall-requested"

cp "$stock_config" "$build_dir/.config"

# An explicit empty LOCALVERSION suppresses Git's automatic "+" suffix while
# preserving the factory CONFIG_LOCALVERSION="" policy without writing an
# ignored .scmversion file into the locked source worktree.
make_args="ARCH=arm64 O=$build_dir CROSS_COMPILE=$cross LOCALVERSION="
# Keep DWARF independent of the host checkout.  GCC 7.5 supports
# -fdebug-prefix-map (but predates -fmacro-prefix-map); the QSDK strip step
# below removes debug sections and the post-strip strings gate rejects any
# remaining __FILE__-style absolute path.
export KCFLAGS="-fdebug-prefix-map=$build_dir=/usr/src/linux-build -fdebug-prefix-map=$kernel_dir=/usr/src/linux -fdebug-prefix-map=/kmod-builder=/usr/src/sbe-overlay"
# Normalize the factory config against the locked public kernel before adding
# any candidate symbols.  A public release can legitimately lack downstream
# factory Kconfig symbols; that drift must be recorded and explicitly opted in
# to, never hidden inside the seven-module delta.
# shellcheck disable=SC2086
make -C "$kernel_dir" $make_args olddefconfig
cp "$build_dir/.config" "$build_dir/.config.public-baseline"
if ! diff -u --label factory-stock.config --label public-qsdk-baseline.config \
		"$build_dir/.config.stock" "$build_dir/.config.public-baseline" \
		> "$build_dir/BASELINE-KCONFIG-DRIFT.patch"; then
	if [ "$allow_public_config_drift" != 1 ]; then
		printf '%s\n' \
			'ERROR: public kernel olddefconfig changes the factory config.' \
			"       Review $build_dir/BASELINE-KCONFIG-DRIFT.patch and rerun only for" \
			'evaluation with QSDK_ALLOW_PUBLIC_KCONFIG_DRIFT=1.' >&2
		exit 1
	fi
	printf 'WARNING: evaluating a public-kernel candidate with recorded factory Kconfig drift.\n' >&2
fi

while IFS='=' read -r symbol value; do
	[ -n "$symbol" ] || continue
	[ "$value" = m ] || fail "unexpected fragment value for $symbol: $value"
	"$config_tool" --file "$build_dir/.config" --module "${symbol#CONFIG_}"
done < "$fragment"

# shellcheck disable=SC2086
make -C "$kernel_dir" $make_args olddefconfig
if command -v sha256sum >/dev/null 2>&1; then
	baseline_sha=$(sha256sum "$build_dir/.config.public-baseline" | awk '{print $1}')
else
	baseline_sha=$(shasum -a 256 "$build_dir/.config.public-baseline" | awk '{print $1}')
fi
"$lab_dir/verify-kconfig-delta.py" \
	--fragment "$fragment" \
	--stock-sha256 "$baseline_sha" \
	"$build_dir/.config.public-baseline" "$build_dir/.config"

kernel_release=$(make -s -C "$kernel_dir" $make_args kernelrelease)
[ "$kernel_release" = "$FACTORY_KERNEL_RELEASE" ] || \
	fail "candidate kernel release is $kernel_release, expected $FACTORY_KERNEL_RELEASE"

targets='net/ipv4/netfilter/nf_socket_ipv4.ko
net/ipv6/netfilter/nf_socket_ipv6.ko
net/ipv4/netfilter/nf_tproxy_ipv4.ko
net/ipv6/netfilter/nf_tproxy_ipv6.ko
net/netfilter/xt_socket.ko
net/netfilter/xt_TPROXY.ko
net/netfilter/xt_iprange.ko'
if [ "$profile" = openwrt-common ]; then
	targets=$(cat "$lab_dir/kernel-openwrt-common.targets")
fi

# shellcheck disable=SC2086
make -C "$kernel_dir" $make_args \
	-j"$jobs" modules_prepare
# Partial in-tree builds otherwise omit dependencies on existing factory
# modules. Feed modpost the audited provider inventory; no CRC is fabricated
# (CONFIG_MODVERSIONS is disabled). Never alter the locked kernel source.
set --
if [ -n "${QSDK_STOCK_SYMVERS:-}" ]; then
	[ -s "$QSDK_STOCK_SYMVERS" ] || fail 'stock export inventory is missing'
	set -- "MODPOST=$build_dir/scripts/mod/modpost -i $QSDK_STOCK_SYMVERS -o $build_dir/Module.symvers -s -T -"
fi
# shellcheck disable=SC2086
make -C "$kernel_dir" $make_args \
	-j"$jobs" \
	"$@" \
	"CFLAGS_nf_socket_ipv4.o=-DSBE_UDP_LOOKUP_COMPAT_IPV4=1 -DSBE_COMPAT_SOURCE_DEFINES_PR_FMT=1 -include /kmod-builder/passwall-udp-lookup-compat.h" \
	"CFLAGS_nf_tproxy_ipv4.o=-DSBE_UDP_LOOKUP_COMPAT_IPV4=1 -include /kmod-builder/passwall-udp-lookup-compat.h" \
	"CFLAGS_nf_socket_ipv6.o=-DSBE_UDP_LOOKUP_COMPAT_IPV6=1 -DSBE_COMPAT_SOURCE_DEFINES_PR_FMT=1 -include /kmod-builder/passwall-udp-lookup-compat.h" \
	"CFLAGS_nf_tproxy_ipv6.o=-DSBE_UDP_LOOKUP_COMPAT_IPV6=1 -include /kmod-builder/passwall-udp-lookup-compat.h" \
	$targets

for target in $targets; do
	module=$build_dir/$target
	[ -f "$module" ] || fail "expected module was not built: $target"
	output_module=$output_dir/$(basename -- "$module")
	cp "$module" "$output_module"
	# Match the stock QSDK packaging path.  CONFIG_KALLSYMS=y requires local
	# symbol names to remain stable, while debug sections and absolute build
	# paths must never be shipped in the evaluation payload.
	CROSS=$cross NO_RENAME=1 "$strip_kmod" "$output_module"
	if "${cross}readelf" -SW "$output_module" | grep -Eq '\.debug_|\.zdebug_'; then
		fail "$(basename -- "$module") retains a debug section after QSDK stripping"
	fi
	if strings "$output_module" | grep -E -q \
		'/Users/|/private/tmp/|/home/[^/]+/|/workspace/|/kmod-builder/|/bundle/'; then
		fail "$(basename -- "$module") still contains a host build path after QSDK stripping"
	fi
done

undefined_symbols() {
	"${cross}readelf" -Ws "$1" | awk '$7 == "UND" && $8 != "" { print $8 }' | LC_ALL=C sort -u
}

assert_undefined() {
	module=$1
	symbol=$2
	undefined_symbols "$module" | grep -Fxq "$symbol" || \
		fail "$(basename -- "$module") does not consume required factory export $symbol"
}

assert_not_undefined() {
	module=$1
	symbol=$2
	if undefined_symbols "$module" | grep -Fxq "$symbol"; then
		fail "$(basename -- "$module") still consumes unavailable factory wrapper $symbol"
	fi
}

for module in "$output_dir/nf_socket_ipv4.ko" "$output_dir/nf_tproxy_ipv4.ko"; do
	assert_not_undefined "$module" udp4_lib_lookup
	assert_undefined "$module" __udp4_lib_lookup
	assert_undefined "$module" udp_table
done
for module in "$output_dir/nf_socket_ipv6.ko" "$output_dir/nf_tproxy_ipv6.ko"; do
	assert_not_undefined "$module" udp6_lib_lookup
	assert_undefined "$module" __udp6_lib_lookup
	assert_undefined "$module" udp_table
done

if command -v sha256sum >/dev/null 2>&1; then
	(cd "$output_dir" && sha256sum ./*.ko | LC_ALL=C sort) > "$output_dir/SHA256SUMS"
else
	(cd "$output_dir" && shasum -a 256 ./*.ko | LC_ALL=C sort) > "$output_dir/SHA256SUMS"
fi
printf '%s\n' "$QSDK_KERNEL_COMMIT" > "$output_dir/PUBLIC_QSDK_KERNEL_COMMIT"
printf '%s\n' "$FACTORY_KERNEL_CONFIG_SHA256" > "$output_dir/STOCK_CONFIG_SHA256"
cp "$build_dir/.config.stock" "$output_dir/FACTORY_CONFIG"
cp "$build_dir/.config.public-baseline" "$output_dir/PUBLIC_BASELINE_CONFIG"
cp "$build_dir/.config" "$output_dir/CANDIDATE_CONFIG"
cp "$build_dir/.config.factory-plus-passwall-requested" \
	"$output_dir/FACTORY_PLUS_PASSWALL_REQUESTED_CONFIG"
cp "$build_dir/BASELINE-KCONFIG-DRIFT.patch" "$output_dir/BASELINE-KCONFIG-DRIFT.patch"
cp "$fragment" "$output_dir/FEATURE_FRAGMENT"
printf '%s\n' "$targets" > "$output_dir/BUILD_TARGETS"
if [ -n "${QSDK_STOCK_SYMVERS:-}" ]; then
	cp "$QSDK_STOCK_SYMVERS" "$output_dir/FACTORY_EXPORTS.symvers"
fi
cp "$compat_header" "$output_dir/UDP_LOOKUP_COMPAT.h"
printf '%s\n' "$compat_header_sha" > "$output_dir/UDP_LOOKUP_COMPAT_SHA256"
if [ -s "$output_dir/BASELINE-KCONFIG-DRIFT.patch" ]; then
	printf '%s\n' \
		'This evaluation build uses the locked public kernel, not the exact factory kernel source.' \
		> "$output_dir/PUBLIC_SOURCE_NOT_FACTORY_EXACT"
fi

printf '\nBUILT, NOT APPROVED: %s module candidates are in %s\n' "$profile" "$output_dir"
printf 'Next gate: current-source export/dependency closure and separate RAM-only device qualification.\n'
