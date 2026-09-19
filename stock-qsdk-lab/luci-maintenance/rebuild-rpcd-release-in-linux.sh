#!/bin/bash

set -euo pipefail
HERE=/bundle
. "$HERE/common.sh"
. "$HERE/sources.lock"
BUILDER_IMAGE_REF=${SBE_BUILDER_IMAGE:-$BUILDER_IMAGE_REF}

QSDK=/qsdk
PACKAGES_LOCK=$HERE/packages.lock.tsv
OUTPUT=$HERE/candidate-out
JOBS=${QSDK_JOBS:-4}
RPCD_TARGET=package/feeds/luci/rpcd-mod-luci
NETWORK_TARGET=package/feeds/luci/luci-mod-network
STATUS_TARGET=package/feeds/luci/luci-mod-status
BASE_TARGET=package/feeds/luci/luci-base
BUILD_SCOPE=${LUCI_REBUILD_SCOPE:-rpcd-release-only}

case "$BUILD_SCOPE" in
	rpcd-release-only)
		rebuilt_packages=(rpcd-mod-luci)
		build_scope_attestation=full-ab-plus-rpcd-release-ab
		;;
	qca-wireless-only)
		rebuilt_packages=(luci-mod-network rpcd-mod-luci)
		build_scope_attestation=full-ab-plus-qca-wireless-ab
		;;
	network-only)
		rebuilt_packages=(luci-mod-network)
		build_scope_attestation=full-ab-plus-network-ab
		;;
	status-realtime-only)
		rebuilt_packages=(luci-mod-status)
		build_scope_attestation=full-ab-plus-status-realtime-ab
		;;
	base-i18n-only)
		rebuilt_packages=(luci-base luci-i18n-base-zh-cn)
		build_scope_attestation=full-ab-plus-base-i18n-ab
		;;
	*) fail "unsupported targeted rebuild scope: $BUILD_SCOPE" ;;
esac

[ "$(uname -s)" = Linux ] || fail 'rebuild-rpcd-release-in-linux.sh requires Linux'
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

for name in run-a run-b release; do
	dir=$OUTPUT/$name
	[ -d "$dir" ] || fail "existing full A/B output is missing: $dir"
	count=$(find "$dir" -maxdepth 1 -type f -name '*.ipk' | wc -l | tr -d ' ')
	[ "$count" = 20 ] || fail "$name must contain the previous complete 20-package set"
done
[ -f "$OUTPUT/BUILD-ATTESTATION.txt" ] || fail 'previous full-build attestation is missing'
prior_source_hash=$(sed -n 's/^prepared_source_tree_sha256=//p' \
	"$OUTPUT/BUILD-ATTESTATION.txt")
[ -n "$prior_source_hash" ] || fail 'previous source tree hash is missing'

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
declare -a selections
while IFS=$'\t' read -r _target package _version _arch _source; do
	case "${_target:-}" in ''|'#'*) continue ;; esac
	selections+=("CONFIG_PACKAGE_${package}=m")
done < "$PACKAGES_LOCK"
[ "${#selections[@]}" = 20 ] || fail 'packages.lock.tsv must name exactly 20 packages'
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
	log=$round_dir/targeted-rebuild.log
	: > "$log"
	for package in "${rebuilt_packages[@]}"; do
		find "$QSDK/bin/packages" -type f -name "${package}_*.ipk" -delete
		find "$round_dir" -maxdepth 1 -type f -name "${package}_*.ipk" -delete
	done

	if [ "$BUILD_SCOPE" = qca-wireless-only ] || [ "$BUILD_SCOPE" = network-only ]; then
		if ! make -C "$QSDK" NO_DEPS=1 "${selections[@]}" \
			PKG_VERSION="$LUCI_PKG_VERSION" PKG_RELEASE="$LUCI_MOD_NETWORK_PKG_RELEASE" \
			PKG_GITBRANCH="$LUCI_GITBRANCH" \
			"$NETWORK_TARGET/clean" >> "$log" 2>&1; then
			tail -n 120 "$log" >&2
			fail "luci-mod-network clean failed in round $round"
		fi
		if ! make -C "$QSDK" -j"$JOBS" NO_DEPS=1 "${selections[@]}" \
			PKG_VERSION="$LUCI_PKG_VERSION" PKG_RELEASE="$LUCI_MOD_NETWORK_PKG_RELEASE" \
			PKG_GITBRANCH="$LUCI_GITBRANCH" \
			"$NETWORK_TARGET/compile" >> "$log" 2>&1; then
			tail -n 120 "$log" >&2
			fail "luci-mod-network compile failed in round $round"
		fi
	fi

	if [ "$BUILD_SCOPE" = status-realtime-only ]; then
		if ! make -C "$QSDK" NO_DEPS=1 "${selections[@]}" \
			PKG_VERSION="$LUCI_PKG_VERSION" PKG_RELEASE="$LUCI_MOD_STATUS_PKG_RELEASE" \
			PKG_GITBRANCH="$LUCI_GITBRANCH" \
			"$STATUS_TARGET/clean" >> "$log" 2>&1; then
			tail -n 120 "$log" >&2
			fail "luci-mod-status clean failed in round $round"
		fi
		if ! make -C "$QSDK" -j"$JOBS" NO_DEPS=1 "${selections[@]}" \
			PKG_VERSION="$LUCI_PKG_VERSION" PKG_RELEASE="$LUCI_MOD_STATUS_PKG_RELEASE" \
			PKG_GITBRANCH="$LUCI_GITBRANCH" \
			"$STATUS_TARGET/compile" >> "$log" 2>&1; then
			tail -n 120 "$log" >&2
			fail "luci-mod-status compile failed in round $round"
		fi
	elif [ "$BUILD_SCOPE" = base-i18n-only ]; then
		if ! make -C "$QSDK" NO_DEPS=1 "${selections[@]}" \
			PKG_VERSION="$LUCI_PKG_VERSION" PKG_RELEASE="$LUCI_BASE_PKG_RELEASE" \
			PKG_GITBRANCH="$LUCI_GITBRANCH" \
			"$BASE_TARGET/clean" >> "$log" 2>&1; then
			tail -n 120 "$log" >&2
			fail "luci-base clean failed in round $round"
		fi
		if ! make -C "$QSDK" -j"$JOBS" NO_DEPS=1 "${selections[@]}" \
			PKG_VERSION="$LUCI_PKG_VERSION" PKG_RELEASE="$LUCI_BASE_PKG_RELEASE" \
			PKG_GITBRANCH="$LUCI_GITBRANCH" \
			"$BASE_TARGET/compile" >> "$log" 2>&1; then
			tail -n 120 "$log" >&2
			fail "luci-base compile failed in round $round"
		fi
	elif [ "$BUILD_SCOPE" != network-only ]; then
		if ! make -C "$QSDK" NO_DEPS=1 "${selections[@]}" \
			"$RPCD_TARGET/clean" >> "$log" 2>&1; then
			tail -n 120 "$log" >&2
			fail "rpcd-mod-luci release clean failed in round $round"
		fi
		if ! make -C "$QSDK" -j"$JOBS" NO_DEPS=1 "${selections[@]}" \
			"$RPCD_TARGET/compile" >> "$log" 2>&1; then
			tail -n 120 "$log" >&2
			fail "rpcd-mod-luci release compile failed in round $round"
		fi
	fi

	for package in "${rebuilt_packages[@]}"; do
		mapfile -t artifacts < <(find "$QSDK/bin/packages" -type f \
			-name "${package}_*.ipk" -print | LC_ALL=C sort)
		[ "${#artifacts[@]}" = 1 ] ||
			fail "expected one $package IPK in round $round, got ${#artifacts[@]}"
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

for package in "${rebuilt_packages[@]}"; do
	find "$OUTPUT/release" -maxdepth 1 -type f -name "${package}_*.ipk" -delete
	mapfile -t rebuilt < <(find "$OUTPUT/run-a" -maxdepth 1 -type f \
		-name "${package}_*.ipk" -print)
	[ "${#rebuilt[@]}" = 1 ] || fail "run-a is missing rebuilt $package"
	cp "${rebuilt[0]}" "$OUTPUT/release/"
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
	printf 'prior_full_ab_source_tree_sha256=%s\n' "$prior_source_hash"
	printf 'build_scope=%s\n' "$build_scope_attestation"
	printf 'qsdk_config_sha256=%s\n' "$config_hash_before"
	printf 'builder_image=%s\n' "$BUILDER_IMAGE_REF"
	printf 'source_date_epoch=%s\n' "$SOURCE_DATE_EPOCH"
	printf 'build_network=none\n'
	printf 'dependency_mode=NO_DEPS=1\n'
	printf 'kernel_config_state=%s\n' "$kernel_state_before"
	printf 'package_count=20\n'
} > "$OUTPUT/BUILD-ATTESTATION.txt"

"$HERE/audit-artifacts.sh" "$OUTPUT/release" "$OUTPUT/audit"
if [ "$BUILD_SCOPE" = qca-wireless-only ]; then
	printf 'PASS: QCA wireless LuCI two-package IPKs are byte-identical across A/B\n'
elif [ "$BUILD_SCOPE" = status-realtime-only ]; then
	printf 'PASS: luci-mod-status realtime-graph IPK is byte-identical across A/B\n'
elif [ "$BUILD_SCOPE" = base-i18n-only ]; then
	printf 'PASS: luci-base and Simplified Chinese catalog IPKs are byte-identical across A/B\n'
elif [ "$BUILD_SCOPE" = network-only ]; then
	printf 'PASS: luci-mod-network IPK is byte-identical across A/B\n'
else
	printf 'PASS: rpcd-mod-luci release-only IPK is byte-identical across A/B\n'
fi
