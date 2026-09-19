#!/bin/bash

set -euo pipefail
HERE=/bundle
. "$HERE/common.sh"
. "$HERE/sources.lock"
. "$HERE/runtime-sources.lock"
BUILDER_IMAGE_REF=${SBE_BUILDER_IMAGE:-$BUILDER_IMAGE_REF}

# The generic LuCI lock uses the LuCI feed commit time.  These four runtime
# sources come from the newer QSDK top-level commit, so use its separately
# locked epoch after sourcing both lock files (sources.lock assigns its own
# SOURCE_DATE_EPOCH unconditionally).
SOURCE_DATE_EPOCH=$RUNTIME_SOURCE_DATE_EPOCH
export SOURCE_DATE_EPOCH

QSDK=/qsdk
QSDK_ORIGINAL=/qsdk-original
PACKAGES_LOCK=$HERE/runtime-packages.lock.tsv
DISTFILES_LOCK=$HERE/runtime-distfiles.lock
TOOLS_LOCK=$HERE/runtime-tools.lock
HEADER_TREES_LOCK=$HERE/staging-header-trees.lock
LIBRARY_ABI_LOCK=$HERE/staging-library-abi.lock
LUA_PATCHES_LOCK=$HERE/runtime-lua-patches.lock.tsv
QSDK_EXTENSION_PATCHES_LOCK=$HERE/runtime-qsdk-extension-patches.lock.tsv
OUTPUT=$HERE/runtime-candidate-out
JOBS=${QSDK_JOBS:-4}

[ "$(uname -s)" = Linux ] || fail 'build-runtime-in-linux.sh requires Linux'
[ -n "${EXPECTED_RUNTIME_SOURCE_TREE_SHA256:-}" ] ||
	fail 'prepared runtime source tree hash was not supplied'
mkdir -p "$HOME"
git config --global --add safe.directory "$QSDK"
git config --global --add safe.directory "$QSDK_ORIGINAL"
git config --global --add safe.directory "$QSDK_ORIGINAL/qca/feeds/luci"
[ "$(sha256_file "$QSDK/.config")" = "$QSDK_BASE_CONFIG_SHA256" ] ||
	fail 'QSDK .config differs from sources.lock'
[ "$(git -C "$QSDK_ORIGINAL" rev-parse HEAD)" = "$QSDK_TOP_COMMIT" ] ||
	fail 'QSDK commit differs from sources.lock'
[ -z "$(git -C "$QSDK_ORIGINAL" status --porcelain --untracked-files=all)" ] ||
	fail 'original QSDK source is dirty before runtime build'
[ -z "$(git -C "$QSDK_ORIGINAL/qca/feeds/luci" status --porcelain --untracked-files=all)" ] ||
	fail 'original QSDK LuCI source is dirty before runtime build'
[ "$(source_tree_sha256 /runtime-source)" = "$EXPECTED_RUNTIME_SOURCE_TREE_SHA256" ] ||
	fail 'read-only prepared runtime source tree hash mismatch'

for lock in "$DISTFILES_LOCK" "$TOOLS_LOCK"; do
	while IFS=$'\t' read -r expected path; do
		case "${expected:-}" in ''|'#'*) continue ;; esac
		[ -f "$QSDK/$path" ] || fail "locked runtime build input is missing: $path"
		actual=$(sha256_file "$QSDK/$path")
		[ "$actual" = "$expected" ] ||
			fail "locked runtime build input changed: $path ($actual)"
	done < "$lock"
done

while IFS=$'\t' read -r expected path; do
	case "${expected:-}" in ''|'#'*) continue ;; esac
	[ -d "$QSDK/$path" ] || fail "locked runtime header tree is missing: $path"
	actual=$(source_tree_sha256 "$QSDK/$path")
	[ "$actual" = "$expected" ] ||
		fail "locked runtime header tree changed: $path ($actual)"
done < "$HEADER_TREES_LOCK"

while IFS=$'\t' read -r expected path semantic; do
	case "${expected:-}" in ''|'#'*) continue ;; esac
	[ -n "$semantic" ] || fail "Lua patch semantic is empty: $path"
	[ -f "/runtime-source/$path" ] || fail "locked QSDK Lua patch is missing: $path"
	[ "$(sha256_file "/runtime-source/$path")" = "$expected" ] ||
		fail "locked QSDK Lua patch changed: $path"
done < "$LUA_PATCHES_LOCK"

while IFS=$'\t' read -r expected path semantic; do
	case "${expected:-}" in ''|'#'*) continue ;; esac
	[ -n "$semantic" ] || fail "QSDK extension patch semantic is empty: $path"
	[ -f "$QSDK/$path" ] || fail "locked QSDK extension patch is missing: $path"
	[ "$(sha256_file "$QSDK/$path")" = "$expected" ] ||
		fail "locked QSDK extension patch changed: $path"
done < "$QSDK_EXTENSION_PATCHES_LOCK"

TOOLCHAIN_BIN=$QSDK/staging_dir/toolchain-aarch64_cortex-a73+neon-vfpv4_gcc-7.5.0_musl/bin
READELF=$TOOLCHAIN_BIN/aarch64-openwrt-linux-musl-readelf
NM=$TOOLCHAIN_BIN/aarch64-openwrt-linux-musl-nm
TARGET_BUILD_ROOT=$QSDK/build_dir/target-aarch64_cortex-a73+neon-vfpv4_musl
LUA_BUILD_TREE=$TARGET_BUILD_ROOT/lua-5.1.5
UBUS_BUILD_TREE=$TARGET_BUILD_ROOT/ubus-2022-02-21-b32a0e17
UCI_BUILD_TREE=$TARGET_BUILD_ROOT/uci-2019-09-01-415f9e48
IWINFO_BUILD_TREE=$TARGET_BUILD_ROOT/libiwinfo-2019-10-16-07315b6f

# Package clean targets in an old, already-used QSDK tree are not sufficient
# evidence that the next compile unpacked the locked distfile.  Remove only
# these four exact generated target-source directories before every round.
# Never use a wildcard here: the kernel and vendor build trees share the
# parent directory.
purge_runtime_build_trees() {
	local tree base
	for tree in "$LUA_BUILD_TREE" "$UBUS_BUILD_TREE" "$UCI_BUILD_TREE" "$IWINFO_BUILD_TREE"; do
		case "$tree" in "$TARGET_BUILD_ROOT"/*) ;;
			*) fail "unsafe runtime build-tree purge target: $tree" ;;
		esac
		base=${tree##*/}
		case "$base" in
			lua-5.1.5|ubus-2022-02-21-b32a0e17|uci-2019-09-01-415f9e48|libiwinfo-2019-10-16-07315b6f) ;;
			*) fail "unexpected runtime build-tree basename: $base" ;;
		esac
		rm -rf -- "$tree"
		[ ! -e "$tree" ] || fail "failed to purge generated runtime build tree: $tree"
	done
}

security_semantic() {
	local round=$1 component=$2 tree=$3 file=$4 pattern=$5 semantic=$6
	[ -f "$tree/$file" ] || fail "$component source is missing after round $round: $file"
	grep -F -q -- "$pattern" "$tree/$file" ||
		fail "$component security semantic is missing after round $round: $semantic"
	printf '%s\t%s\t%s\t%s\t%s\tpass\n' "$round" "$component" "$file" \
		"$(sha256_file "$tree/$file")" "$semantic" >> "$OUTPUT/audit/security-source-semantics.tsv"
}

verify_security_source_semantics() {
	local round=$1
	security_semantic "$round" lua "$LUA_BUILD_TREE" src/ldo.c \
		'p->maxstacksize + p->numparams' CVE-2014-5461-fixed-parameter-stack-bound
	security_semantic "$round" lua "$LUA_BUILD_TREE" src/lparser.c \
		'setsvalue2s(L, L->top, tname);' CVE-2025-49844-parser-name-anchored
	security_semantic "$round" lua "$LUA_BUILD_TREE" src/lparser.c \
		'--L->top;' CVE-2025-49844-parser-anchor-released
	security_semantic "$round" lua "$LUA_BUILD_TREE" src/lbaselib.c \
		'n = (unsigned int)e - (unsigned int)i;' unpack-signed-overflow-eliminated
	security_semantic "$round" lua "$LUA_BUILD_TREE" src/llex.c \
		'luaX_lexerror(ls, "chunk has too many lines", 0);' parser-line-overflow-safe-error
	security_semantic "$round" ubus-lua "$UBUS_BUILD_TREE" lua/ubus.c \
		'if (!lua_istable(L, 2))' non-table-object-map-rejected
	security_semantic "$round" ubus-lua "$UBUS_BUILD_TREE" lua/ubus.c \
		'struct ubus_method *m = NULL;' method-array-initialized
	security_semantic "$round" ubus-lua "$UBUS_BUILD_TREE" lua/ubus.c \
		'free(m);' method-array-freed-on-type-allocation-failure
	security_semantic "$round" uci-lua "$UCI_BUILD_TREE" lua/uci.c \
		'free(config);' changes-list-freed
	security_semantic "$round" uci-lua "$UCI_BUILD_TREE" lua/uci.c \
		'Cannot set an uci option to an empty table value' empty-table-error-path-present
	security_semantic "$round" iwinfo "$IWINFO_BUILD_TREE" iwinfo_lua.c \
		'luaopen_iwinfo' locked-binding-source-reconstructed
	security_semantic "$round" iwinfo "$IWINFO_BUILD_TREE" iwinfo_nl80211.c \
		'memset(e, 0, sizeof(*e));' wpactl-scan-entry-initialized
}
verify_staging_abis() {
	local mode=${1:-strict}
	while IFS=$'\t' read -r path expected_soname expected_machine expected_symbols; do
		case "${path:-}" in ''|'#'*) continue ;; esac
		if [ "$mode" = bootstrap ] && [ ! -f "$QSDK/$path" ]; then
			case "$path" in
				*/usr/lib/liblua.so|*/usr/lib/libubus.so|*/usr/lib/libuci.so) continue ;;
			esac
		fi
		[ -f "$QSDK/$path" ] || fail "locked ABI library is missing: $path"
		actual_soname=$($READELF -d "$QSDK/$path" |
			sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
		actual_soname=${actual_soname:--}
		actual_machine=$($READELF -h "$QSDK/$path" | sed -n 's/^ *Machine: *//p')
		actual_symbols=$($NM -D --defined-only "$QSDK/$path" |
			sed -E 's/^[0-9a-fA-F]+[[:space:]]+//' | LC_ALL=C sort -u |
			sha256sum | cut -c1-64)
		[ "$actual_soname" = "$expected_soname" ] ||
			fail "staged library SONAME changed: $path ($actual_soname)"
		[ "$actual_machine" = "$expected_machine" ] ||
			fail "staged library machine changed: $path ($actual_machine)"
		[ "$actual_symbols" = "$expected_symbols" ] ||
			fail "staged library exported ABI changed: $path ($actual_symbols)"
	done < "$LIBRARY_ABI_LOCK"
}
# A previously interrupted package clean may legitimately have removed the
# three InstallDev outputs owned by this same four-target build.  All external
# providers remain mandatory here; the three runtime libraries become strict
# again after every complete round.
verify_staging_abis bootstrap

kernel_config_state() {
	(
		find "$QSDK/build_dir" -type f -path '*/linux-5.4.213/.config' -print 2>/dev/null |
			LC_ALL=C sort | while IFS= read -r config; do
				printf '%s\t%s\n' "$(sha256_file "$config")" "${config#"$QSDK/"}"
			done
	) | sha256_stream
}

kernel_artifact_state() {
	(
		find "$QSDK/bin" -type f \( -name 'kmod-*.ipk' -o -name 'kernel_*.ipk' \) \
			-print 2>/dev/null | LC_ALL=C sort | while IFS= read -r artifact; do
				printf '%s\t%s\n' "$(sha256_file "$artifact")" "${artifact#"$QSDK/"}"
			done
	) | sha256_stream
}

config_hash_before=$(sha256_file "$QSDK/.config")
kernel_state_before=$(kernel_config_state)
kernel_artifacts_before=$(kernel_artifact_state)
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/run-a" "$OUTPUT/run-b" "$OUTPUT/release" "$OUTPUT/audit"
printf 'round\tcomponent\tfile\tsha256\tsemantic\tresult\n' > "$OUTPUT/audit/security-source-semantics.tsv"

declare -a package_names config_symbols build_targets selections
declare -A target_seen
while IFS=$'\t' read -r target config_symbol package _version _arch _source _source_name _baseline _baseline_version; do
	case "${target:-}" in ''|'#'*) continue ;; esac
	package_names+=("$package")
	config_symbols+=("$config_symbol")
	selections+=("CONFIG_PACKAGE_${config_symbol}=m")
	if [ -z "${target_seen[$target]:-}" ]; then
		build_targets+=("$target")
		target_seen[$target]=1
	fi
done < "$PACKAGES_LOCK"
[ "${#package_names[@]}" = 6 ] || fail 'runtime-packages.lock.tsv must name exactly 6 packages'
[ "${#build_targets[@]}" = 4 ] || fail 'runtime package set must use exactly 4 source targets'

# These command-line values select only the six release packages.  The
# cfg80211 value is solely the upstream iwinfo Makefile's switch for its
# nl80211 backend and libnl-tiny dependency.  NO_DEPS prevents it from
# traversing or building the kernel package; the log and kernel-state checks
# below enforce that boundary.
selections+=(
	CONFIG_PACKAGE_luac=
	CONFIG_PACKAGE_lua-examples=
	CONFIG_PACKAGE_libubus=
	CONFIG_PACKAGE_ubus=
	CONFIG_PACKAGE_ubusd=
	CONFIG_PACKAGE_libuci=
	CONFIG_PACKAGE_uci=
	CONFIG_PACKAGE_iwinfo=
	CONFIG_PACKAGE_kmod-cfg80211=m
	CONFIG_PACKAGE_kmod-brcm-wl=
	CONFIG_PACKAGE_kmod-brcm-wl-mini=
	CONFIG_PACKAGE_kmod-brcm-wl-mimo=
	# libiwinfo declares PKG_FLAGS:=nonshared, so this older buildroot only
	# emits its IPKs for built-in (y), not module (m), selections.
	CONFIG_PACKAGE_libiwinfo=y
	CONFIG_PACKAGE_libiwinfo-lua=y
)

for round in a b; do
	round_dir=$OUTPUT/run-$round
	log=$round_dir/build.log
	: > "$log"
	for package in "${package_names[@]}"; do
		# PKG_FLAGS:=nonshared sends iwinfo to bin/targets/.../packages;
		# ordinary packages go to bin/packages.  Search the complete bin tree.
		find "$QSDK/bin" -type f -name "${package}_*.ipk" -delete
	done

	for target in "${build_targets[@]}"; do
		if ! make -C "$QSDK" NO_DEPS=1 "${selections[@]}" \
			"$target/clean" >> "$log" 2>&1; then
			tail -n 120 "$log" >&2
			fail "$target clean failed in round $round"
		fi
	done
	purge_runtime_build_trees
	for target in "${build_targets[@]}"; do
		if ! make -C "$QSDK" -j"$JOBS" V=s NO_DEPS=1 "${selections[@]}" \
			"$target/compile" >> "$log" 2>&1; then
			tail -n 160 "$log" >&2
			fail "$target compile failed in round $round"
		fi
	done
	verify_security_source_semantics "$round"

	for package in "${package_names[@]}"; do
		mapfile -t artifacts < <(find "$QSDK/bin" -type f \
			-name "${package}_*.ipk" -print | LC_ALL=C sort)
		[ "${#artifacts[@]}" = 1 ] ||
			fail "expected one $package IPK after round $round, got ${#artifacts[@]}"
		cp "${artifacts[0]}" "$round_dir/"
	done

	if grep -Eq \
		'make\[[0-9]+\].*(package/kernel|target/linux)|-C .*/linux-5\.4\.213|package/(kernel|network/config/wifi-scripts/mac80211).*/compile' \
		"$log"; then
		fail "round $round invoked a forbidden kernel target"
	fi
	[ "$(sha256_file "$QSDK/.config")" = "$config_hash_before" ] ||
		fail "QSDK .config changed in round $round"
	[ "$(kernel_config_state)" = "$kernel_state_before" ] ||
		fail "kernel configuration state changed in round $round"
	[ "$(kernel_artifact_state)" = "$kernel_artifacts_before" ] ||
		fail "kernel package artifact state changed in round $round"
	[ -z "$(git -C "$QSDK_ORIGINAL" status --porcelain --untracked-files=all)" ] ||
		fail "original QSDK source changed in round $round"
	[ -z "$(git -C "$QSDK_ORIGINAL/qca/feeds/luci" status --porcelain --untracked-files=all)" ] ||
		fail "original LuCI source changed in round $round"
	verify_staging_abis
done

printf 'package\tfilename\tsha256_run_a\tsha256_run_b\tresult\n' > "$OUTPUT/REPRODUCIBILITY.tsv"
while IFS=$'\t' read -r _target _config package _version _arch _source _source_name _baseline _baseline_version; do
	case "${_target:-}" in ''|'#'*) continue ;; esac
	mapfile -t a_files < <(find "$OUTPUT/run-a" -maxdepth 1 -type f -name "${package}_*.ipk")
	mapfile -t b_files < <(find "$OUTPUT/run-b" -maxdepth 1 -type f -name "${package}_*.ipk")
	[ "${#a_files[@]}" = 1 ] && [ "${#b_files[@]}" = 1 ] ||
		fail "A/B runtime artifact set is incomplete for $package"
	a=${a_files[0]}
	b=${b_files[0]}
	[ "$(basename "$a")" = "$(basename "$b")" ] ||
		fail "A/B runtime filenames differ for $package"
	cmp "$a" "$b" || fail "A/B runtime package bytes differ for $package"
	sha_a=$(sha256_file "$a")
	sha_b=$(sha256_file "$b")
	printf '%s\t%s\t%s\t%s\tbyte-identical\n' \
		"$package" "$(basename "$a")" "$sha_a" "$sha_b" >> "$OUTPUT/REPRODUCIBILITY.tsv"
	cp "$a" "$OUTPUT/release/"
done < "$PACKAGES_LOCK"

(
	cd "$OUTPUT/release"
	sha256sum ./*.ipk | LC_ALL=C sort -k2
) > "$OUTPUT/PACKAGE_SHA256SUMS"

lua_tree=$LUA_BUILD_TREE
[ -d "$lua_tree" ] || fail 'patched Lua target source tree is missing after build'
printf 'semantic\tevidence\tresult\n' > "$OUTPUT/audit/lua-patch-semantics.tsv"
lua_semantic() {
	local semantic=$1 pattern=$2 file=$3
	grep -F -q -- "$pattern" "$lua_tree/$file" ||
		fail "Lua semantic marker is missing: $semantic"
	printf '%s\t%s:%s\tpass\n' "$semantic" "$file" "$pattern" >> "$OUTPUT/audit/lua-patch-semantics.tsv"
}
lua_semantic double-number '# define LNUM_DOUBLE' src/lnum_config.h
lua_semantic int32-fast-path '# define LNUM_INT32' src/lnum_config.h
lua_semantic internal-integer-tag-nine '#define LUA_TINT 9' src/lua.h
lua_semantic endian-aware-bytecode 'S->swap=(s[6]!=h[6]);' src/lundump.c
lua_semantic fixed-width-bytecode-string 'unsigned int size;' src/lundump.c
lua_semantic openwrt-module-root '#define LUA_ROOT' src/luaconf.h
lua_semantic computed-goto '#define COMPUTED_GOTO 1' src/lvm.c
if grep -Eq '^#define[[:space:]]+LUA_USE_READLINE' "$lua_tree/src/luaconf.h"; then
	fail 'Lua target unexpectedly enables readline'
fi
printf 'no-readline\tsrc/luaconf.h:LUA_USE_READLINE absent\tpass\n' >> "$OUTPUT/audit/lua-patch-semantics.tsv"

{
	printf 'qsdk_commit=%s\n' "$QSDK_TOP_COMMIT"
	printf 'runtime_patchset_revision=%s\n' "$RUNTIME_PATCHSET_REVISION"
	printf 'prepared_runtime_source_tree_sha256=%s\n' "$EXPECTED_RUNTIME_SOURCE_TREE_SHA256"
	printf 'qsdk_config_sha256=%s\n' "$config_hash_before"
	printf 'builder_image=%s\n' "$BUILDER_IMAGE_REF"
	printf 'source_date_epoch=%s\n' "$SOURCE_DATE_EPOCH"
	printf 'build_network=none\n'
	printf 'baseline_usage=separate-post-build-audit-container\n'
	printf 'dependency_mode=NO_DEPS=1\n'
	printf 'iwinfo_backends=wext,nl80211\n'
	printf 'kernel_config_state=%s\n' "$kernel_state_before"
	printf 'kernel_artifact_state=%s\n' "$kernel_artifacts_before"
	printf 'package_count=%s\n' "${#package_names[@]}"
} > "$OUTPUT/BUILD-ATTESTATION.txt"

"$HERE/tests/runtime-smoke.sh" "$OUTPUT/release" "$OUTPUT/audit/lua-runtime-smoke.txt"
printf 'PASS: 6 source-built Lua/LuCI runtime IPKs are byte-identical across A/B\n'
