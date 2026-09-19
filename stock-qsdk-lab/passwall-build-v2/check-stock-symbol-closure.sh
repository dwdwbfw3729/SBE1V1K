#!/bin/bash

set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/scripts/common.sh"
. "$HERE/stock-kallsyms-recovery.lock"

MODE=${1:-}
DEFAULT_EVIDENCE=$OUT_DIR/stock-p25-kernel-evidence
DEFAULT_STOCK_ROOT=$HERE/../work/v5-root-inspect
DEFAULT_PROVIDER=$OUT_DIR/stock-p27-provider-modules
IMAGE=${QSDK_BUILD_IMAGE:-openwrt-builder:ubuntu-22.04-arm64}
REPORT_DIR=$OUT_DIR/netfilter-stock-symbol-evidence
ATTESTATION=$OUT_DIR/netfilter-stock-preload-export-evidence.attestation
BLOCKED=$OUT_DIR/netfilter-stock-preload-export-evidence.blocked

fail() { echo "FAIL: $*" >&2; exit 1; }
field() { sed -n "s/^$1=//p" "$2"; }

# A failed preflight must never leave a PASS from an older input set behind.
rm -f -- "$ATTESTATION" "$BLOCKED" "$OUT_DIR/netfilter-stock-symbol-closure.attestation"

case "$MODE" in
	--static-recovered)
		EVIDENCE_DIR=${2:-$DEFAULT_EVIDENCE}
		STOCK_ROOT=${3:-$DEFAULT_STOCK_ROOT}
		PROVIDER_DIR=${4:-$DEFAULT_PROVIDER}
		KALLSYMS=$EVIDENCE_DIR/stock-p25-static.kallsyms
		EVIDENCE_KIND=static-recovered
		;;
	--live-proc)
		KALLSYMS=${2:?--live-proc requires a collector-produced kallsyms file}
		STOCK_ROOT=${3:-$DEFAULT_STOCK_ROOT}
		PROVIDER_DIR=${4:-$DEFAULT_PROVIDER}
		EVIDENCE_DIR=${5:-$DEFAULT_EVIDENCE}
		EVIDENCE_KIND=live-proc
		META=$KALLSYMS.meta
		[[ -f "$META" ]] || fail "live capture metadata is missing: $META"
		[[ "$(field evidence_kind "$META")" = live-proc-kallsyms ]] || fail "capture metadata is not live-proc evidence"
		[[ "$(field source "$META")" = /proc/kallsyms ]] || fail "capture metadata has the wrong source"
		[[ "$(field kernel_release "$META")" = 5.4.213 ]] || fail "live capture kernel release mismatch"
		[[ "$(field machine "$META")" = aarch64 ]] || fail "live capture architecture mismatch"
		[[ "$(field kallsyms_sha256 "$META")" = "$(sha256_file "$KALLSYMS")" ]] || fail "live capture hash/metadata mismatch"
		[[ "$(sha256_file "$KALLSYMS")" != "$STOCK_P25_STATIC_KALLSYMS_SHA256" ]] || fail "the static-recovery file was mislabeled as a live capture"
		;;
	*) fail "usage: check-stock-symbol-closure.sh --static-recovered [EVIDENCE_DIR [STOCK_ROOT [PROVIDER_DIR]]] | --live-proc KALLSYMS [STOCK_ROOT [PROVIDER_DIR [EVIDENCE_DIR]]]" ;;
esac

MODULES=$OUT_DIR/netfilter-candidates/kmods/modules
BUILTIN_EXPORTS=$EVIDENCE_DIR/factory-builtin-exports.tsv
RAW_KERNEL=$EVIDENCE_DIR/Image

[[ -f "$KALLSYMS" ]] || fail "kallsyms input is missing: $KALLSYMS"
[[ -f "$RAW_KERNEL" ]] || fail "locked factory raw Image evidence is missing"
[[ -f "$BUILTIN_EXPORTS" ]] || fail "factory PREL32 export evidence is missing"
[[ -d "$STOCK_ROOT/lib/modules/5.4.213" ]] || fail "stock inspection module tree is missing"
[[ -d "$PROVIDER_DIR" ]] || fail "exact stock provider module directory is missing"
[[ -d "$MODULES" ]] || fail "candidate modules are missing"
provider_ko_set=$(
	cd "$PROVIDER_DIR"
	find . -type f -name '*.ko' -print | LC_ALL=C sort
)
require_equal "exact supplemental provider module set" "$provider_ko_set" \
"./nf_defrag_ipv4.ko
./nf_defrag_ipv6.ko
./x_tables.ko"
for provider_module in x_tables.ko nf_defrag_ipv4.ko nf_defrag_ipv6.ko; do
	[[ -s "$PROVIDER_DIR/$provider_module" ]] || \
		fail "supplemental provider is empty or missing: $provider_module"
done
require_equal "factory raw Image sha256" "$(sha256_file "$RAW_KERNEL")" "$STOCK_P25_RAW_KERNEL_SHA256"
require_equal "factory PREL32 export TSV sha256" "$(sha256_file "$BUILTIN_EXPORTS")" "$STOCK_P25_PREL32_EXPORT_TSV_SHA256"
require_equal "stock x_tables provider sha256" "$(sha256_file "$PROVIDER_DIR/x_tables.ko")" "$STOCK_P27_X_TABLES_SHA256"
require_equal "stock nf_defrag_ipv4 provider sha256" "$(sha256_file "$PROVIDER_DIR/nf_defrag_ipv4.ko")" "$STOCK_P27_NF_DEFRAG_IPV4_SHA256"
require_equal "stock nf_defrag_ipv6 provider sha256" "$(sha256_file "$PROVIDER_DIR/nf_defrag_ipv6.ko")" "$STOCK_P27_NF_DEFRAG_IPV6_SHA256"
if [[ "$MODE" = --static-recovered ]]; then
	require_equal "static kallsyms sha256" "$(sha256_file "$KALLSYMS")" "$STOCK_P25_STATIC_KALLSYMS_SHA256"
	require_equal "static kallsyms line count" "$(wc -l < "$KALLSYMS" | tr -d '[:space:]')" "$STOCK_P25_STATIC_KALLSYMS_LINES"
fi

safe_clean_dir "$REPORT_DIR"

docker run --rm --network none \
	-v "$MODULES:/candidate:ro" \
	-v "$STOCK_ROOT/lib/modules/5.4.213:/stock-modules:ro" \
	-v "$PROVIDER_DIR:/provider-modules:ro" \
	-v "$KALLSYMS:/input/kallsyms:ro" \
	-v "$BUILTIN_EXPORTS:/input/factory-builtin-exports.tsv:ro" \
	-v "$HERE/classify-stock-symbol-evidence.py:/audit/classify.py:ro" \
	-v "$REPORT_DIR:/report" \
	--entrypoint /bin/bash "$IMAGE" -euo pipefail -c \
	'python3 /audit/classify.py \
		--candidate-dir /candidate \
		--stock-module-dir /stock-modules \
		--provider-module-dir /provider-modules \
		--builtin-export-tsv /input/factory-builtin-exports.tsv \
		--kallsyms /input/kallsyms \
		--evidence-kind "$1" \
		--output-dir /report' _ "$EVIDENCE_KIND" \
	| tee "$REPORT_DIR/run.log"

SUMMARY=$REPORT_DIR/summary.json
[[ -f "$SUMMARY" ]] || fail "classifier did not produce summary.json"
summary_sha=$(sha256_file "$SUMMARY")
if jq -e '
  .pass_attestation_allowed == true and
  .preload_export_evidence_gate == "pass-export-provider-inventory-only" and
  .external_symbol_evidence.kallsyms_name_only == 0 and
  .external_symbol_evidence.no_provider_or_name_evidence == 0 and
  .external_symbol_evidence.unproven_for_module_resolution == 0 and
  .external_symbol_evidence.load_abi_tested == false and
  .stock_modules.discovered == 277 and
  .stock_modules.zero_byte_placeholders_skipped == 222 and
  .stock_modules.nonempty == 55 and
  .stock_modules.nonempty_parseable == 55 and
  .stock_modules.nonempty_readelf_errors == 0 and
  .stock_modules.input_inventory_valid == true and
  .supplemental_provider_modules.actual_names ==
    ["nf_defrag_ipv4.ko", "nf_defrag_ipv6.ko", "x_tables.ko"] and
  .supplemental_provider_modules.count == 3 and
  .supplemental_provider_modules.exact_expected_set == true and
  .supplemental_provider_modules.zero_byte == 0 and
  .supplemental_provider_modules.nonempty == 3 and
  .supplemental_provider_modules.nonempty_parseable == 3 and
  .supplemental_provider_modules.nonempty_readelf_errors == 0 and
  .supplemental_provider_modules.modules_with_export_table == 3 and
  .supplemental_provider_modules.input_inventory_valid == true and
  .factory_builtin_exports.table_entries == 8445 and
  .factory_builtin_exports.unique_symbols == 8445 and
  .factory_builtin_exports.class_counts.ordinary == 4467 and
  .factory_builtin_exports.class_counts.gpl == 3978 and
  .factory_builtin_exports.contiguous_prel32_entries == true and
  .factory_builtin_exports.single_ordinary_gpl_split == true and
  .factory_builtin_exports.contiguous_name_strings == true
' "$SUMMARY" >/dev/null; then
	{
		echo "result=pass"
		echo "scope=preload-export-provider-inventory"
		echo "evidence_kind=$EVIDENCE_KIND-plus-factory-prel32-and-stock-module-exports"
		echo "kernel_release=5.4.213"
		echo "load_abi_proven=false"
		echo "kallsyms_name_only_used_for_pass=0"
		echo "kallsyms_sha256=$(sha256_file "$KALLSYMS")"
		echo "factory_raw_kernel_sha256=$STOCK_P25_RAW_KERNEL_SHA256"
		echo "factory_builtin_exports_sha256=$STOCK_P25_PREL32_EXPORT_TSV_SHA256"
		echo "stock_x_tables_sha256=$STOCK_P27_X_TABLES_SHA256"
		echo "stock_nf_defrag_ipv4_sha256=$STOCK_P27_NF_DEFRAG_IPV4_SHA256"
		echo "stock_nf_defrag_ipv6_sha256=$STOCK_P27_NF_DEFRAG_IPV6_SHA256"
		echo "module_manifest_sha256=$(sha256_file "$OUT_DIR/netfilter-candidates/kmods/SHA256SUMS")"
		echo "classifier_summary_sha256=$summary_sha"
	} > "$ATTESTATION"
	echo "PASS: wrote a hash-bound pre-load export-provider inventory attestation"
	echo "BLOCKED: load ABI is still untested; only RAM-only insmod can test it"
	exit 0
fi

{
	echo "result=blocked"
	echo "scope=preload-export-provider-inventory"
	echo "evidence_kind=$EVIDENCE_KIND-plus-factory-prel32-and-stock-module-exports"
	echo "load_abi_proven=false"
	echo "kallsyms_name_only_used_for_pass=0"
	echo "module_manifest_sha256=$(sha256_file "$OUT_DIR/netfilter-candidates/kmods/SHA256SUMS")"
	echo "classifier_summary_sha256=$summary_sha"
} > "$BLOCKED"
echo "BLOCKED: no PASS attestation written; see $REPORT_DIR/REPORT.md" >&2
exit 3
