#!/usr/bin/env python3
"""Recover the ARM64 PREL32 kernel export table from the locked factory Image."""

import argparse
import csv
import re
import struct
from pathlib import Path
from typing import Optional


ARM64_MAGIC_OFFSET = 0x38
ARM64_MAGIC = b"ARM\x64"
ARM64_IMAGE_SIZE_OFFSET = 0x10
STRUCT_SIZE = 12
STEXT_FILE_OFFSET = 0x800
LOCKED_TABLE_START = 0x94CE80
LOCKED_TABLE_END = 0x965A50
LOCKED_TABLE_ENTRIES = 8445
LOCKED_GPL_TABLE_START = 0x959FE4
LOCKED_STRING_TABLE_START = 0x965A5C
LOCKED_STRING_TABLE_END = 0x98E0B3
SYMBOL_NAME = re.compile(rb"[A-Za-z_][A-Za-z0-9_]*")


def c_string(image: bytes, offset: int, maximum: int = 256) -> Optional[bytes]:
    if offset < 0 or offset >= len(image):
        return None
    end = image.find(b"\0", offset, min(len(image), offset + maximum))
    if end < 0:
        return None
    return image[offset:end]


def parse_entry(image: bytes, image_size: int, offset: int):
    if offset < 0 or offset + STRUCT_SIZE > len(image):
        return None
    value_rel, name_rel, namespace_rel = struct.unpack_from("<iii", image, offset)
    value_offset = offset + value_rel
    name_offset = offset + 4 + name_rel
    namespace_offset = offset + 8 + namespace_rel if namespace_rel else None
    if not (0 <= value_offset < image_size and 0 <= name_offset < len(image)):
        return None
    name = c_string(image, name_offset)
    if name is None or SYMBOL_NAME.fullmatch(name) is None:
        return None
    namespace = b""
    if namespace_offset is not None:
        namespace = c_string(image, namespace_offset)
        if namespace is None or (namespace and SYMBOL_NAME.fullmatch(namespace) is None):
            return None
    return {
        "name": name.decode("ascii"),
        "entry_offset": offset,
        "value_offset": value_offset,
        "name_offset": name_offset,
        "namespace_offset": namespace_offset,
        "namespace": namespace.decode("ascii"),
    }


def load_kallsyms(path: Path):
    records = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if len(fields) >= 3:
            records.setdefault(fields[2], []).append(int(fields[0], 16))
    return records


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("raw_image", type=Path)
    parser.add_argument("static_kallsyms", type=Path)
    parser.add_argument("output_tsv", type=Path)
    parser.add_argument("--discover", action="store_true",
                        help="Derive table boundaries for another verified stock Image; retain structural checks")
    args = parser.parse_args()

    image = args.raw_image.read_bytes()
    if image[ARM64_MAGIC_OFFSET : ARM64_MAGIC_OFFSET + 4] != ARM64_MAGIC:
        raise SystemExit("raw input is not an ARM64 Linux Image")
    image_size = struct.unpack_from("<Q", image, ARM64_IMAGE_SIZE_OFFSET)[0]
    if image_size < len(image):
        raise SystemExit("ARM64 header image_size is smaller than the raw file")

    kallsyms = load_kallsyms(args.static_kallsyms)
    stext = kallsyms.get("_stext", [])
    stack_fail = kallsyms.get("__stack_chk_fail", [])
    if len(set(stext)) != 1 or len(set(stack_fail)) != 1:
        raise SystemExit("static kallsyms lacks unique _stext/__stack_chk_fail anchors")
    virtual_base = stext[0] - STEXT_FILE_OFFSET
    stack_fail_file_offset = stack_fail[0] - virtual_base

    anchors = []
    for offset in range(0, len(image) - STRUCT_SIZE, 4):
        entry = parse_entry(image, image_size, offset)
        if (
            entry
            and entry["name"] == "__stack_chk_fail"
            and entry["value_offset"] == stack_fail_file_offset
        ):
            anchors.append(offset)
    if len(anchors) != 1 or (not args.discover and anchors != [0x94DF00]):
        raise SystemExit(f"unexpected PREL32 export anchor candidates: {anchors!r}")

    start = anchors[0]
    while parse_entry(image, image_size, start - STRUCT_SIZE):
        start -= STRUCT_SIZE
    end = anchors[0]
    while parse_entry(image, image_size, end + STRUCT_SIZE):
        end += STRUCT_SIZE
    entry_count = (end - start) // STRUCT_SIZE + 1
    if not args.discover and (start, end, entry_count) != (
        LOCKED_TABLE_START,
        LOCKED_TABLE_END,
        LOCKED_TABLE_ENTRIES,
    ):
        raise SystemExit(
            "factory PREL32 export table boundary changed: "
            f"start={start:#x} end={end:#x} entries={entry_count}"
        )

    entries = []
    seen_names = set()
    for offset in range(start, end + 1, STRUCT_SIZE):
        entry = parse_entry(image, image_size, offset)
        if entry is None:
            raise SystemExit(f"invalid PREL32 export entry at {offset:#x}")
        if entry["name"] in seen_names:
            raise SystemExit(f"duplicate exported symbol: {entry['name']}")
        seen_names.add(entry["name"])
        symbol_addresses = kallsyms.get(entry["name"], [])
        expected_file_offsets = {address - virtual_base for address in symbol_addresses}
        if expected_file_offsets and entry["value_offset"] not in expected_file_offsets:
            raise SystemExit(
                f"PREL32 value/kallsyms disagreement for {entry['name']}: "
                f"{entry['value_offset']:#x} not in {sorted(expected_file_offsets)!r}"
            )
        entries.append(entry)

    resets = [
        index
        for index in range(1, len(entries))
        if entries[index]["name"] <= entries[index - 1]["name"]
    ]
    if len(resets) != 1 or (not args.discover and (
        resets != [4467] or entries[resets[0]]["entry_offset"] != LOCKED_GPL_TABLE_START
    )):
        raise SystemExit(f"unexpected ordinary/GPL export-table split: {resets!r}")
    gpl_start = entries[resets[0]]["entry_offset"]
    if any(entry["namespace_offset"] is not None for entry in entries):
        raise SystemExit("factory export table unexpectedly contains a namespace offset")
    string_start = min(entry["name_offset"] for entry in entries)
    if string_start <= end + STRUCT_SIZE - 1:
        raise SystemExit("export strings overlap the export table")
    if not args.discover and string_start != LOCKED_STRING_TABLE_START:
        raise SystemExit("locked export string table start changed")
    string_cursor = string_start
    for entry in sorted(entries, key=lambda item: item["name_offset"]):
        if entry["name_offset"] != string_cursor:
            raise SystemExit(
                "factory export-name strings are not a closed contiguous table: "
                f"expected {string_cursor:#x}, got {entry['name_offset']:#x}"
            )
        string_cursor += len(entry["name"]) + 1
    if not args.discover and string_cursor != LOCKED_STRING_TABLE_END:
        raise SystemExit(
            f"factory export-name string table ends at {string_cursor:#x}, "
            f"expected {LOCKED_STRING_TABLE_END:#x}"
        )

    args.output_tsv.parent.mkdir(parents=True, exist_ok=True)
    with args.output_tsv.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream, delimiter="\t", lineterminator="\n")
        writer.writerow(
            (
                "symbol",
                "entry_file_offset",
                "value_file_offset",
                "name_file_offset",
                "namespace_file_offset",
                "namespace",
                "export_class",
                "kallsyms_value_match",
            )
        )
        for entry in entries:
            writer.writerow(
                (
                    entry["name"],
                    f"0x{entry['entry_offset']:x}",
                    f"0x{entry['value_offset']:x}",
                    f"0x{entry['name_offset']:x}",
                    (
                        f"0x{entry['namespace_offset']:x}"
                        if entry["namespace_offset"] is not None
                        else "-"
                    ),
                    entry["namespace"] or "-",
                    "gpl" if entry["entry_offset"] >= gpl_start else "ordinary",
                    "yes" if entry["name"] in kallsyms else "not-listed-data-or-nontext",
                )
            )
    print(
        f"PASS: recovered {entry_count} unique ARM64 PREL32 exports "
        f"from {start:#x}..{end + STRUCT_SIZE:#x}; "
        f"name table {string_start:#x}..{string_cursor:#x}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
