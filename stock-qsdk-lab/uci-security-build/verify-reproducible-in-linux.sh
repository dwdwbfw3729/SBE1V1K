#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$build_dir/sources.lock"
source_root=${1:-${QSDK_SOURCE_ROOT:-}}
[ -n "$source_root" ] || { printf 'usage: %s QSDK_SOURCE_ROOT\n' "$0" >&2; exit 2; }

work=$(mktemp -d /tmp/sbe-uci-repro.XXXXXX)
cleanup() {
	case "$work" in /tmp/sbe-uci-repro.*|/var/tmp/sbe-uci-repro.*) rm -rf "$work" ;; esac
}
trap cleanup EXIT HUP INT TERM

round1=$work/round1
round2=$work/round2
UCI_SECURITY_OUTPUT=$round1 /bin/sh "$build_dir/build-candidate-in-linux.sh" "$source_root"
UCI_SECURITY_OUTPUT=$round2 /bin/sh "$build_dir/build-candidate-in-linux.sh" "$source_root"

for name in \
	libuci20130104_2019-09-01-415f9e48-5_aarch64_cortex-a73_neon-vfpv4.ipk \
	libuci.so uci-cli.test-only PREPARED-SOURCE-SHA256SUMS CLEAN-GATE.txt; do
	cmp -s "$round1/$name" "$round2/$name" || {
		printf 'ERROR: forced-clean A/B bytes differ: %s\n' "$name" >&2
		exit 1
	}
done

final=$build_dir/candidate-out/libuci-security
rm -rf "$final"
mkdir -p "$final"
cp "$round2"/* "$final/"
{
	printf 'libuci forced-clean reproducibility: PASS\n'
	printf 'rounds=2\n'
	printf 'clean_target=package/system/uci/clean\n'
	printf 'build_target=package/system/uci/compile\n'
	printf 'source_date_epoch=%s\n' "$SOURCE_DATE_EPOCH"
	printf 'byte_identical=ipk,libuci.so,uci-cli.test-only,prepared-source-manifest\n'
	printf 'round_a_package_sha256=%s\n' "$(sha256sum "$round1"/*.ipk | awk '{print $1}')"
	printf 'round_b_package_sha256=%s\n' "$(sha256sum "$round2"/*.ipk | awk '{print $1}')"
	printf 'round_a_libuci_sha256=%s\n' "$(sha256sum "$round1/libuci.so" | awk '{print $1}')"
	printf 'round_b_libuci_sha256=%s\n' "$(sha256sum "$round2/libuci.so" | awk '{print $1}')"
	printf 'round_a_test_cli_sha256=%s\n' "$(sha256sum "$round1/uci-cli.test-only" | awk '{print $1}')"
	printf 'round_b_test_cli_sha256=%s\n' "$(sha256sum "$round2/uci-cli.test-only" | awk '{print $1}')"
} > "$final/REPRODUCIBILITY.txt"

/bin/sh "$build_dir/audit-artifact-in-linux.sh" "$final"
