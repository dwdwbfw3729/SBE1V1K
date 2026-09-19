#!/bin/bash

set -euo pipefail
HERE=/bundle
. "$HERE/common.sh"
. "$HERE/sources.lock"
BUILDER_IMAGE_REF=${SBE_BUILDER_IMAGE:-$BUILDER_IMAGE_REF}

QSDK=/qsdk
PACKAGES_LOCK=$HERE/packages.lock.tsv
STAGING_LOCK=$HERE/staging-inputs.lock
HEADER_TREES_LOCK=$HERE/staging-header-trees.lock
LIBRARY_ABI_LOCK=$HERE/staging-library-abi.lock
OUTPUT=$HERE/candidate-out
JOBS=${QSDK_JOBS:-4}

[ "$(uname -s)" = Linux ] || fail 'build-in-linux.sh requires Linux'
[ -n "${EXPECTED_SOURCE_TREE_SHA256:-}" ] ||
	fail 'prepared source tree hash was not supplied'
mkdir -p "$HOME"
git config --global --add safe.directory "$QSDK"
[ "$(sha256_file "$QSDK/.config")" = "$QSDK_BASE_CONFIG_SHA256" ] ||
	fail 'QSDK .config differs from sources.lock'
[ "$(git -C "$QSDK" rev-parse HEAD)" = "$QSDK_TOP_COMMIT" ] ||
	fail 'QSDK commit differs from sources.lock'
[ "$(source_tree_sha256 "$QSDK/qca/feeds/luci")" = "$EXPECTED_SOURCE_TREE_SHA256" ] ||
	fail 'read-only prepared LuCI source tree hash mismatch'

while IFS=$'\t' read -r expected path; do
	case "${expected:-}" in ''|'#'*) continue ;; esac
	[ -f "$QSDK/$path" ] || fail "locked build input is missing: $path"
	actual=$(sha256_file "$QSDK/$path")
	[ "$actual" = "$expected" ] ||
		fail "locked build input changed: $path ($actual)"
done < "$STAGING_LOCK"

while IFS=$'\t' read -r expected path; do
	case "${expected:-}" in ''|'#'*) continue ;; esac
	[ -d "$QSDK/$path" ] || fail "locked header tree is missing: $path"
	actual=$(source_tree_sha256 "$QSDK/$path")
	[ "$actual" = "$expected" ] ||
		fail "locked header tree changed: $path ($actual)"
done < "$HEADER_TREES_LOCK"

TOOLCHAIN_BIN=$QSDK/staging_dir/toolchain-aarch64_cortex-a73+neon-vfpv4_gcc-7.5.0_musl/bin
READELF=$TOOLCHAIN_BIN/aarch64-openwrt-linux-musl-readelf
NM=$TOOLCHAIN_BIN/aarch64-openwrt-linux-musl-nm
while IFS=$'\t' read -r path expected_soname expected_machine expected_symbols; do
	case "${path:-}" in ''|'#'*) continue ;; esac
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

kernel_config_state() {
	(
		find "$QSDK/build_dir" -type f -path '*/linux-5.4.213/.config' -print 2>/dev/null |
			LC_ALL=C sort | while IFS= read -r config; do
				printf '%s\t%s\n' "$(sha256_file "$config")" "${config#"$QSDK/"}"
			done
	) | sha256_stream
}

config_hash_before=$(sha256_file "$QSDK/.config")
kernel_state_before=$(kernel_config_state)
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/run-a" "$OUTPUT/run-b" "$OUTPUT/release" "$OUTPUT/audit"

declare -a package_names luci_targets selections
declare -A target_seen
rpcd_target=
while IFS=$'\t' read -r target package _version _arch _source; do
	case "${target:-}" in ''|'#'*) continue ;; esac
	package_names+=("$package")
	selections+=("CONFIG_PACKAGE_${package}=m")
	if [ "$package" = rpcd-mod-luci ]; then
		rpcd_target=$target
	elif [ -z "${target_seen[$target]:-}" ]; then
		luci_targets+=("$target")
		target_seen[$target]=1
	fi
done < "$PACKAGES_LOCK"
[ "${#package_names[@]}" = 20 ] || fail 'packages.lock.tsv must name exactly 20 packages'
[ -n "$rpcd_target" ] || fail 'rpcd-mod-luci target is missing from packages.lock.tsv'

selections+=(
	CONFIG_PACKAGE_luci-lib-nixio_notls=y
	CONFIG_PACKAGE_luci-lib-nixio_axtls=
	CONFIG_PACKAGE_luci-lib-nixio_cyassl=
	CONFIG_PACKAGE_luci-lib-nixio_openssl=
	CONFIG_LUCI_JSMIN=y
	CONFIG_LUCI_CSSTIDY=y
	CONFIG_LUCI_SRCDIET=
)

for round in a b; do
	round_dir=$OUTPUT/run-$round
	log=$round_dir/build.log
	: > "$log"
	for package in "${package_names[@]}"; do
		find "$QSDK/bin/packages" -type f -name "${package}_*.ipk" -delete
	done

	for target in "${luci_targets[@]}"; do
		# Respect the same per-package releases as the targeted rebuild paths.
		release=$LUCI_PKG_RELEASE
		case "$target" in
			*/luci-base) release=$LUCI_BASE_PKG_RELEASE ;;
			*/luci-mod-status) release=$LUCI_MOD_STATUS_PKG_RELEASE ;;
			*/luci-mod-network) release=$LUCI_MOD_NETWORK_PKG_RELEASE ;;
		esac
		if ! make -C "$QSDK" NO_DEPS=1 "${selections[@]}" \
			PKG_VERSION="$LUCI_PKG_VERSION" PKG_RELEASE="$release" \
			PKG_GITBRANCH="$LUCI_GITBRANCH" "$target/clean" >> "$log" 2>&1; then
			tail -n 120 "$log" >&2
			fail "$target clean failed in round $round"
		fi
		if ! make -C "$QSDK" -j"$JOBS" NO_DEPS=1 "${selections[@]}" \
			PKG_VERSION="$LUCI_PKG_VERSION" PKG_RELEASE="$release" \
			PKG_GITBRANCH="$LUCI_GITBRANCH" "$target/compile" >> "$log" 2>&1; then
			tail -n 120 "$log" >&2
			fail "$target compile failed in round $round"
		fi
	done

	# rpcd-mod-luci has its own version and an explicit patchset release in its
	# Makefile. Do not leak the LuCI aggregate's version override into it.
	if ! make -C "$QSDK" NO_DEPS=1 "${selections[@]}" \
		"$rpcd_target/clean" >> "$log" 2>&1; then
		tail -n 120 "$log" >&2
		fail "rpcd-mod-luci clean failed in round $round"
	fi
	if ! make -C "$QSDK" -j"$JOBS" NO_DEPS=1 "${selections[@]}" \
		"$rpcd_target/compile" >> "$log" 2>&1; then
		tail -n 120 "$log" >&2
		fail "rpcd-mod-luci compile failed in round $round"
	fi

	for package in "${package_names[@]}"; do
		mapfile -t artifacts < <(find "$QSDK/bin/packages" -type f \
			-name "${package}_*.ipk" -print | LC_ALL=C sort)
		[ "${#artifacts[@]}" = 1 ] ||
			fail "expected one $package IPK after round $round, got ${#artifacts[@]}"
		cp "${artifacts[0]}" "$round_dir/"
	done

	if grep -Eq 'make\[[0-9]+\].*(package/kernel/linux|target/linux)|-C .*/linux-5\.4\.213' "$log"; then
		fail "round $round invoked a forbidden kernel target"
	fi
	[ "$(sha256_file "$QSDK/.config")" = "$config_hash_before" ] ||
		fail "QSDK .config changed in round $round"
	[ "$(kernel_config_state)" = "$kernel_state_before" ] ||
		fail "kernel configuration state changed in round $round"
done

printf 'package\tfilename\tsha256_run_a\tsha256_run_b\tresult\n' > "$OUTPUT/REPRODUCIBILITY.tsv"
while IFS=$'\t' read -r _target package _version _arch _source; do
	case "${_target:-}" in ''|'#'*) continue ;; esac
	mapfile -t a_files < <(find "$OUTPUT/run-a" -maxdepth 1 -type f -name "${package}_*.ipk")
	mapfile -t b_files < <(find "$OUTPUT/run-b" -maxdepth 1 -type f -name "${package}_*.ipk")
	[ "${#a_files[@]}" = 1 ] && [ "${#b_files[@]}" = 1 ] ||
		fail "A/B artifact set is incomplete for $package"
	a=${a_files[0]}
	b=${b_files[0]}
	[ "$(basename "$a")" = "$(basename "$b")" ] ||
		fail "A/B filenames differ for $package"
	cmp "$a" "$b" || fail "A/B package bytes differ for $package"
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

{
	printf 'qsdk_commit=%s\n' "$QSDK_TOP_COMMIT"
	printf 'luci_commit=%s\n' "$QSDK_LUCI_COMMIT"
	printf 'patchset_revision=%s\n' "$PATCHSET_REVISION"
	printf 'prepared_source_tree_sha256=%s\n' "$EXPECTED_SOURCE_TREE_SHA256"
	printf 'qsdk_config_sha256=%s\n' "$config_hash_before"
	printf 'builder_image=%s\n' "$BUILDER_IMAGE_REF"
	printf 'source_date_epoch=%s\n' "$SOURCE_DATE_EPOCH"
	printf 'build_network=none\n'
	printf 'dependency_mode=NO_DEPS=1\n'
	printf 'kernel_config_state=%s\n' "$kernel_state_before"
	printf 'package_count=%s\n' "${#package_names[@]}"
} > "$OUTPUT/BUILD-ATTESTATION.txt"

"$HERE/audit-artifacts.sh" "$OUTPUT/release" "$OUTPUT/audit"
printf 'PASS: 20 source-built LuCI IPKs are byte-identical across A/B\n'
