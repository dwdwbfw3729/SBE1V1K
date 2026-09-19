#!/usr/bin/env python3
"""Classify candidate module UND symbols without treating kallsyms names as exports."""

import argparse
import csv
import hashlib
import json
import os
import re
import subprocess
from collections import defaultdict
from pathlib import Path


EXPECTED_MODULES = (
    "nf_socket_ipv4.ko",
    "nf_socket_ipv6.ko",
    "nf_tproxy_ipv4.ko",
    "nf_tproxy_ipv6.ko",
    "xt_TPROXY.ko",
    "xt_iprange.ko",
    "xt_socket.ko",
)
EXPECTED_SUPPLEMENTAL_PROVIDER_MODULES = (
    "nf_defrag_ipv4.ko",
    "nf_defrag_ipv6.ko",
    "x_tables.ko",
)
EXPECTED_BUILTIN_EXPORT_FIELDS = (
    "symbol",
    "entry_file_offset",
    "value_file_offset",
    "name_file_offset",
    "namespace_file_offset",
    "namespace",
    "export_class",
    "kallsyms_value_match",
)
PSEUDO_UNDEFINED = {"$d", "$x", ""}
STRING_ENTRY = re.compile(r"^\s*\[\s*[0-9a-fA-F]+\]\s+(\S+)\s*$")
SYMBOL_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
HEX_OFFSET = re.compile(r"^0x[0-9a-f]+$")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def readelf(path: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["readelf", *arguments, os.fspath(path)],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"readelf failed for {path}: {detail}")
    return result.stdout


def undefined_symbols(path: Path) -> set[str]:
    symbols: set[str] = set()
    for line in readelf(path, "-Ws").splitlines():
        fields = line.split(None, 7)
        if len(fields) >= 8 and fields[6] == "UND":
            name = fields[7]
            if name not in PSEUDO_UNDEFINED:
                symbols.add(name)
    return symbols


def exported_symbols(path: Path) -> set[str]:
    sections = readelf(path, "-SW")
    if "__ksymtab_strings" not in sections:
        return set()
    symbols: set[str] = set()
    for line in readelf(path, "-p", "__ksymtab_strings").splitlines():
        match = STRING_ENTRY.match(line)
        if match:
            symbols.add(match.group(1))
    return symbols


def write_tsv(path: Path, header: tuple[str, ...], rows) -> None:
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream, delimiter="\t", lineterminator="\n")
        writer.writerow(header)
        writer.writerows(rows)


def joined(values) -> str:
    return ",".join(sorted(values)) or "-"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate-dir", type=Path, required=True)
    parser.add_argument("--stock-module-dir", type=Path, required=True)
    parser.add_argument("--provider-module-dir", type=Path, action="append", default=[])
    parser.add_argument("--builtin-export-tsv", type=Path, required=True)
    parser.add_argument("--kallsyms", type=Path, required=True)
    parser.add_argument(
        "--evidence-kind",
        choices=("static-recovered", "live-proc"),
        required=True,
    )
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    candidate_files = sorted(args.candidate_dir.glob("*.ko"), key=lambda p: p.name)
    actual_names = tuple(path.name for path in candidate_files)
    if actual_names != EXPECTED_MODULES:
        raise SystemExit(
            "candidate directory is not the exact seven-module set: "
            + ",".join(actual_names)
        )

    required_by: dict[str, set[str]] = defaultdict(set)
    candidate_exports: dict[str, set[str]] = defaultdict(set)
    candidate_export_rows = []
    for module in candidate_files:
        if module.stat().st_size == 0:
            raise SystemExit(f"candidate module is empty: {module.name}")
        for symbol in undefined_symbols(module):
            required_by[symbol].add(module.name)
        for symbol in exported_symbols(module):
            candidate_exports[symbol].add(module.name)
            candidate_export_rows.append((symbol, module.name))

    # `stock_exports` is the union of concrete module export tables.  Keep the
    # sparse inspection tree and the byte-exact supplemental providers separate
    # as well, so an extracted provider can never disguise a placeholder.
    stock_exports: dict[str, set[str]] = defaultdict(set)
    inspection_exports: dict[str, set[str]] = defaultdict(set)
    supplemental_exports: dict[str, set[str]] = defaultdict(set)
    stock_export_rows = []
    inventory_rows = []
    provider_inventory = []
    stock_stats = {
        "discovered": 0,
        "zero_byte": 0,
        "nonempty": 0,
        "parseable": 0,
        "unparseable": 0,
        "with_export_table": 0,
    }
    provider_stats = {
        "discovered": 0,
        "zero_byte": 0,
        "nonempty": 0,
        "parseable": 0,
        "unparseable": 0,
        "with_export_table": 0,
    }

    def scan_module_tree(
        root: Path,
        source: str,
        rows: list,
        source_exports: dict[str, set[str]],
        stats: dict[str, int],
    ) -> None:
        for module in sorted(root.rglob("*.ko"), key=lambda p: os.fspath(p)):
            relative = module.relative_to(root).as_posix()
            provider = f"{source}:{relative}"
            size = module.stat().st_size
            digest = sha256_file(module)
            stats["discovered"] += 1
            if size == 0:
                stats["zero_byte"] += 1
                row = (source, relative, size, digest, "zero-byte-placeholder-skipped", 0)
                rows.append(row)
                continue
            stats["nonempty"] += 1
            try:
                exports = exported_symbols(module)
            except RuntimeError:
                stats["unparseable"] += 1
                row = (source, relative, size, digest, "nonempty-readelf-error", 0)
                rows.append(row)
                continue
            stats["parseable"] += 1
            if exports:
                stats["with_export_table"] += 1
            disposition = "parsed-export-table" if exports else "parsed-no-export-table"
            row = (source, relative, size, digest, disposition, len(exports))
            rows.append(row)
            for symbol in sorted(exports):
                stock_exports[symbol].add(provider)
                source_exports[symbol].add(provider)
                stock_export_rows.append((symbol, provider))

    scan_module_tree(
        args.stock_module_dir,
        "stock-inspection-root",
        inventory_rows,
        inspection_exports,
        stock_stats,
    )
    for index, provider_root in enumerate(args.provider_module_dir, start=1):
        scan_module_tree(
            provider_root,
            f"supplemental-provider-{index}",
            provider_inventory,
            supplemental_exports,
            provider_stats,
        )

    provider_names = sorted(row[1] for row in provider_inventory)
    provider_module_names = sorted(Path(relative).name for relative in provider_names)
    provider_roots_exist = bool(args.provider_module_dir) and all(
        root.is_dir() for root in args.provider_module_dir
    )
    provider_paths_are_flat = all(
        relative == Path(relative).name for relative in provider_names
    )
    provider_exact_set = (
        tuple(provider_module_names) == EXPECTED_SUPPLEMENTAL_PROVIDER_MODULES
        and provider_paths_are_flat
    )
    provider_inputs_valid = (
        provider_roots_exist
        and provider_exact_set
        and provider_stats["zero_byte"] == 0
        and provider_stats["nonempty"] == len(EXPECTED_SUPPLEMENTAL_PROVIDER_MODULES)
        and provider_stats["parseable"] == len(EXPECTED_SUPPLEMENTAL_PROVIDER_MODULES)
        and provider_stats["unparseable"] == 0
        and provider_stats["with_export_table"]
        == len(EXPECTED_SUPPLEMENTAL_PROVIDER_MODULES)
    )

    builtin_exports: dict[str, set[str]] = defaultdict(set)
    builtin_entry_offsets: list[int] = []
    builtin_name_ranges: list[tuple[int, int]] = []
    builtin_class_counts: dict[str, int] = defaultdict(int)
    builtin_seen_gpl = False
    with args.builtin_export_tsv.open("r", encoding="utf-8", newline="") as stream:
        reader = csv.DictReader(stream, delimiter="\t")
        if tuple(reader.fieldnames or ()) != EXPECTED_BUILTIN_EXPORT_FIELDS:
            raise SystemExit("built-in export TSV has an unexpected header")
        for row_number, row in enumerate(reader, start=2):
            if None in row or any(
                row[field] is None for field in EXPECTED_BUILTIN_EXPORT_FIELDS
            ):
                raise SystemExit(
                    f"built-in export TSV row {row_number} has an unexpected field count"
                )
            symbol = row["symbol"]
            if SYMBOL_NAME.fullmatch(symbol) is None:
                raise SystemExit(
                    f"built-in export TSV row {row_number} has an invalid symbol"
                )
            if symbol in builtin_exports:
                raise SystemExit(f"duplicate built-in export symbol: {symbol}")
            for field in (
                "entry_file_offset",
                "value_file_offset",
                "name_file_offset",
            ):
                if HEX_OFFSET.fullmatch(row[field]) is None:
                    raise SystemExit(
                        f"built-in export TSV row {row_number} has an invalid {field}"
                    )
            if row["namespace_file_offset"] != "-" or row["namespace"] != "-":
                raise SystemExit(
                    "factory PREL32 export evidence unexpectedly contains a namespace"
                )
            if row["export_class"] not in {"ordinary", "gpl"}:
                raise SystemExit(
                    f"built-in export TSV row {row_number} has an invalid export class"
                )
            if row["export_class"] == "gpl":
                builtin_seen_gpl = True
            elif builtin_seen_gpl:
                raise SystemExit(
                    "built-in PREL32 export classes do not have one ordinary/GPL split"
                )
            if row["kallsyms_value_match"] not in {
                "yes",
                "not-listed-data-or-nontext",
            }:
                raise SystemExit(
                    f"built-in export TSV row {row_number} has an invalid match status"
                )
            entry_offset = int(row["entry_file_offset"], 16)
            if entry_offset % 4:
                raise SystemExit(
                    f"built-in export TSV row {row_number} has an unaligned entry offset"
                )
            builtin_entry_offsets.append(entry_offset)
            builtin_name_ranges.append(
                (int(row["name_file_offset"], 16), len(symbol.encode("ascii")) + 1)
            )
            builtin_class_counts[row["export_class"]] += 1
            evidence = (
                "factory-prel32-"
                + row["export_class"]
                + "-ksymtab@"
                + row["entry_file_offset"]
                + "->"
                + row["value_file_offset"]
            )
            builtin_exports[symbol].add(evidence)

    if any(
        current - previous != 12
        for previous, current in zip(builtin_entry_offsets, builtin_entry_offsets[1:])
    ):
        raise SystemExit("built-in PREL32 export entries are not a contiguous 12-byte table")
    sorted_name_ranges = sorted(builtin_name_ranges)
    if any(
        current_offset != previous_offset + previous_length
        for (previous_offset, previous_length), (current_offset, _)
        in zip(sorted_name_ranges, sorted_name_ranges[1:])
    ):
        raise SystemExit("built-in PREL32 export names are not a contiguous string table")

    # The root count deliberately describes the sparse inspection tree only;
    # separately extracted provider modules never hide its empty placeholders.

    kallsyms_records: dict[str, set[str]] = defaultdict(set)
    kallsyms_line_count = 0
    malformed_kallsyms_count = 0
    with args.kallsyms.open("r", encoding="utf-8", errors="strict") as stream:
        for line in stream:
            fields = line.split()
            if len(fields) < 3 or not re.fullmatch(r"[0-9a-fA-F]+", fields[0]):
                malformed_kallsyms_count += 1
                continue
            address, symbol_type, name = fields[:3]
            kallsyms_line_count += 1
            kallsyms_records[name].add(f"{address.lower()}:{symbol_type}")

    report_rows = []
    class_counts: dict[str, int] = defaultdict(int)
    candidate_internal_count = 0
    external_export_supported_count = 0
    external_name_only_count = 0
    external_no_evidence_count = 0
    for symbol in sorted(required_by):
        candidate_providers = candidate_exports.get(symbol, set())
        stock_providers = stock_exports.get(symbol, set())
        builtin_providers = builtin_exports.get(symbol, set())
        name_records = kallsyms_records.get(symbol, set())
        marker_name = "__ksymtab_" + symbol
        marker_records = kallsyms_records.get(marker_name, set())
        if candidate_providers:
            classification = "candidate-set-export-table"
            preload_status = "candidate-provider-present"
            candidate_internal_count += 1
        elif stock_providers:
            classification = "stock-module-export-table"
            preload_status = "stock-module-export-provider-present"
            external_export_supported_count += 1
        elif builtin_providers:
            classification = "factory-built-in-prel32-export-table"
            preload_status = "factory-built-in-export-provider-present"
            external_export_supported_count += 1
        elif marker_records or name_records:
            classification = (
                "kallsyms-export-marker-name-only"
                if marker_records
                else "kallsyms-name-only"
            )
            preload_status = "unproven-kallsyms-name-is-not-export-evidence"
            external_name_only_count += 1
        else:
            classification = "no-provider-or-name-evidence"
            preload_status = "unproven-no-evidence"
            external_no_evidence_count += 1
        class_counts[classification] += 1
        report_rows.append(
            (
                symbol,
                joined(required_by[symbol]),
                joined(candidate_providers),
                joined(stock_providers),
                joined(builtin_providers),
                joined(name_records),
                joined(f"{marker_name}@{record}" for record in marker_records),
                classification,
                preload_status,
                "not-tested-requires-ram-insmod",
            )
        )

    write_tsv(
        args.output_dir / "symbol-evidence.tsv",
        (
            "symbol",
            "required_by",
            "candidate_export_providers",
            "stock_module_export_providers",
            "factory_builtin_export_evidence",
            "kallsyms_name_records",
            "kernel_export_marker_records",
            "classification",
            "preload_resolution_status",
            "load_abi_status",
        ),
        report_rows,
    )
    write_tsv(
        args.output_dir / "stock-module-inventory.tsv",
        ("source", "relative_path", "size_bytes", "sha256", "disposition", "export_count"),
        inventory_rows,
    )
    write_tsv(
        args.output_dir / "supplemental-provider-inventory.tsv",
        ("source", "relative_path", "size_bytes", "sha256", "disposition", "export_count"),
        provider_inventory,
    )
    write_tsv(
        args.output_dir / "stock-module-exports.tsv",
        ("symbol", "provider"),
        sorted(stock_export_rows),
    )
    write_tsv(
        args.output_dir / "candidate-module-exports.tsv",
        ("symbol", "provider"),
        sorted(candidate_export_rows),
    )

    unique_undefined_count = len(required_by)
    external_count = unique_undefined_count - candidate_internal_count
    external_unproven_count = external_name_only_count + external_no_evidence_count
    stock_inputs_valid = (
        args.stock_module_dir.is_dir()
        and stock_stats["discovered"] > 0
        and stock_stats["unparseable"] == 0
        and stock_stats["zero_byte"] + stock_stats["parseable"]
        == stock_stats["discovered"]
    )
    preload_gate = (
        "pass-export-provider-inventory-only"
        if external_count == external_export_supported_count
        and stock_inputs_valid
        and provider_inputs_valid
        and malformed_kallsyms_count == 0
        else "blocked"
    )
    generated = {
        filename: sha256_file(args.output_dir / filename)
        for filename in (
            "symbol-evidence.tsv",
            "stock-module-inventory.tsv",
            "stock-module-exports.tsv",
            "candidate-module-exports.tsv",
            "supplemental-provider-inventory.tsv",
        )
    }
    summary = {
        "format": 1,
        "report_result": "blocked-load-abi-not-tested",
        "preload_export_evidence_gate": preload_gate,
        "evidence_kind": args.evidence_kind,
        "interpretation": (
            "A kallsyms name match is name-only evidence. It is not counted as an "
            "exported provider and cannot support a PASS attestation."
        ),
        "kallsyms": {
            "sha256": sha256_file(args.kallsyms),
            "parsed_lines": kallsyms_line_count,
            "malformed_lines": malformed_kallsyms_count,
            "unique_names": len(kallsyms_records),
            "kernel_export_marker_names": sum(
                1 for name in kallsyms_records if name.startswith("__ksymtab_")
            ),
        },
        "candidate_modules": {
            "count": len(candidate_files),
            "unique_undefined_symbols": unique_undefined_count,
            "candidate_set_export_supported": candidate_internal_count,
            "external_symbols": external_count,
        },
        "stock_modules": {
            "discovered": stock_stats["discovered"],
            "zero_byte_placeholders_skipped": stock_stats["zero_byte"],
            "nonempty": stock_stats["nonempty"],
            "nonempty_parseable": stock_stats["parseable"],
            "nonempty_readelf_errors": stock_stats["unparseable"],
            "modules_with_export_table": stock_stats["with_export_table"],
            "unique_exported_symbols": len(inspection_exports),
            "input_inventory_valid": stock_inputs_valid,
        },
        "supplemental_provider_modules": {
            "expected_names": list(EXPECTED_SUPPLEMENTAL_PROVIDER_MODULES),
            "actual_relative_paths": provider_names,
            "actual_names": provider_module_names,
            "count": provider_stats["discovered"],
            "roots_exist": provider_roots_exist,
            "paths_are_flat": provider_paths_are_flat,
            "exact_expected_set": provider_exact_set,
            "zero_byte": provider_stats["zero_byte"],
            "nonempty": provider_stats["nonempty"],
            "nonempty_parseable": provider_stats["parseable"],
            "nonempty_readelf_errors": provider_stats["unparseable"],
            "modules_with_export_table": provider_stats["with_export_table"],
            "unique_exported_symbols": len(supplemental_exports),
            "input_inventory_valid": provider_inputs_valid,
        },
        "concrete_module_exports": {
            "unique_symbols": len(stock_exports),
            "export_pairs": len(stock_export_rows),
        },
        "factory_builtin_exports": {
            "table_entries": sum(len(values) for values in builtin_exports.values()),
            "unique_symbols": len(builtin_exports),
            "class_counts": dict(sorted(builtin_class_counts.items())),
            "contiguous_prel32_entries": True,
            "single_ordinary_gpl_split": True,
            "contiguous_name_strings": True,
            "tsv_sha256": sha256_file(args.builtin_export_tsv),
        },
        "external_symbol_evidence": {
            "stock_module_or_kernel_export_supported": external_export_supported_count,
            "kallsyms_name_only": external_name_only_count,
            "no_provider_or_name_evidence": external_no_evidence_count,
            "unproven_for_module_resolution": external_unproven_count,
            "load_abi_tested": False,
        },
        "classification_counts": dict(sorted(class_counts.items())),
        "generated_file_sha256": generated,
        "pass_attestation_allowed": preload_gate == "pass-export-provider-inventory-only",
    }
    summary_path = args.output_dir / "summary.json"
    summary_path.write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    markdown = f"""# Stock symbol evidence classification

Result: **BLOCKED**. No load ABI test was performed.

- Evidence kind: `{args.evidence_kind}`
- Candidate unique UND symbols: {unique_undefined_count}
- Resolved inside the seven-module candidate set: {candidate_internal_count}
- External UND symbols: {external_count}
- Backed by an actual stock module export table or factory PREL32 built-in export entry: {external_export_supported_count}
- Kallsyms name-only matches (not export proof): {external_name_only_count}
- No provider or name evidence: {external_no_evidence_count}
- External symbols still unproven for module resolution/load ABI: {external_unproven_count}
- Stock `.ko` inventory: {stock_stats['discovered']} total, {stock_stats['zero_byte']} zero-byte placeholders skipped, {stock_stats['nonempty']} non-empty, {stock_stats['parseable']} parsed
- Supplemental exact provider modules: {provider_stats['discovered']} (strict input valid: {str(provider_inputs_valid).lower()})
- Pre-load export-provider inventory gate: `{preload_gate}`

The recovered/live kallsyms namespace is not the kernel module export table. A
plain name match never contributes to a PASS decision. Even concrete export-table
evidence is only a pre-load inventory; successful RAM-only `insmod` is required to
test the running kernel ABI.
"""
    (args.output_dir / "REPORT.md").write_text(markdown, encoding="utf-8")

    print(
        "BLOCKED: "
        f"{unique_undefined_count} unique UND = {candidate_internal_count} candidate-set exports + "
        f"{external_export_supported_count} concrete stock exports + "
        f"{external_name_only_count} kallsyms name-only + {external_no_evidence_count} no evidence"
    )
    print(
        f"STOCK MODULES: skipped {stock_stats['zero_byte']} zero-byte placeholders; "
        f"parsed {stock_stats['parseable']}/{stock_stats['nonempty']} non-empty modules"
    )
    print(
        "SUPPLEMENTAL PROVIDERS: "
        f"exact={str(provider_exact_set).lower()} "
        f"parsed={provider_stats['parseable']}/{provider_stats['nonempty']} "
        f"zero-byte={provider_stats['zero_byte']} valid={str(provider_inputs_valid).lower()}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
