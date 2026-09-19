#!/usr/bin/env python3
"""List normalized ELF64 dynamic symbols without relying on section headers.

OpenWrt's sstrip removes section headers from release ELFs.  The dynamic
loader still has PT_DYNAMIC, DT_HASH, DT_SYMTAB and DT_STRTAB, so parse those
structures directly and emit a stable symbol ABI representation.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import struct


PT_LOAD = 1
PT_DYNAMIC = 2
DT_NULL = 0
DT_HASH = 4
DT_STRTAB = 5
DT_SYMTAB = 6
DT_STRSZ = 10
DT_SYMENT = 11

BINDINGS = {
    0: "LOCAL",
    1: "GLOBAL",
    2: "WEAK",
    10: "GNU_UNIQUE",
}
TYPES = {
    0: "NOTYPE",
    1: "OBJECT",
    2: "FUNC",
    3: "SECTION",
    4: "FILE",
    5: "COMMON",
    6: "TLS",
    10: "GNU_IFUNC",
}
VISIBILITIES = {0: "DEFAULT", 1: "INTERNAL", 2: "HIDDEN", 3: "PROTECTED"}


class ElfError(RuntimeError):
    pass


def parse_symbols(path: Path) -> list[tuple[str, str, str, str, str]]:
    data = path.read_bytes()
    if len(data) < 64 or data[:4] != b"\x7fELF":
        raise ElfError("not an ELF file")
    if data[4] != 2:
        raise ElfError("only ELF64 is supported")
    if data[5] != 1:
        raise ElfError("only little-endian ELF is supported")

    header = struct.unpack_from("<HHIQQQIHHHHHH", data, 16)
    e_phoff = header[4]
    e_phentsize = header[8]
    e_phnum = header[9]
    if e_phentsize < 56:
        raise ElfError("invalid program-header entry size")

    loads: list[tuple[int, int, int, int]] = []
    dynamic: tuple[int, int] | None = None
    for index in range(e_phnum):
        offset = e_phoff + index * e_phentsize
        if offset + 56 > len(data):
            raise ElfError("program-header table extends beyond file")
        p_type, _flags, p_offset, p_vaddr, _paddr, p_filesz, _memsz, _align = (
            struct.unpack_from("<IIQQQQQQ", data, offset)
        )
        if p_type == PT_LOAD:
            loads.append((p_vaddr, p_offset, p_filesz, len(data)))
        elif p_type == PT_DYNAMIC:
            dynamic = (p_offset, p_filesz)

    if dynamic is None:
        raise ElfError("PT_DYNAMIC is missing")

    def vaddr_to_offset(address: int, size: int = 1) -> int:
        for vaddr, file_offset, file_size, total_size in loads:
            if vaddr <= address and address + size <= vaddr + file_size:
                result = file_offset + address - vaddr
                if result + size <= total_size:
                    return result
        raise ElfError(f"virtual address 0x{address:x} is outside file-backed LOAD segments")

    tags: dict[int, list[int]] = {}
    dynamic_offset, dynamic_size = dynamic
    for offset in range(dynamic_offset, dynamic_offset + dynamic_size, 16):
        if offset + 16 > len(data):
            raise ElfError("dynamic table extends beyond file")
        tag, value = struct.unpack_from("<QQ", data, offset)
        if tag == DT_NULL:
            break
        tags.setdefault(tag, []).append(value)

    def one(tag: int) -> int:
        values = tags.get(tag, [])
        if len(values) != 1:
            raise ElfError(f"dynamic tag {tag} count is {len(values)}, expected 1")
        return values[0]

    hash_offset = vaddr_to_offset(one(DT_HASH), 8)
    _bucket_count, symbol_count = struct.unpack_from("<II", data, hash_offset)
    string_address = one(DT_STRTAB)
    string_size = one(DT_STRSZ)
    symbol_address = one(DT_SYMTAB)
    symbol_size = one(DT_SYMENT)
    if symbol_size != 24:
        raise ElfError(f"unexpected ELF64 symbol size: {symbol_size}")
    string_offset = vaddr_to_offset(string_address, string_size)
    strings = data[string_offset : string_offset + string_size]
    symbol_offset = vaddr_to_offset(symbol_address, symbol_count * symbol_size)

    result: list[tuple[str, str, str, str, str]] = []
    for index in range(symbol_count):
        offset = symbol_offset + index * symbol_size
        name_offset, info, other, section_index, _value, _size = struct.unpack_from(
            "<IBBHQQ", data, offset
        )
        if name_offset >= len(strings):
            raise ElfError(f"symbol {index} has invalid string offset")
        end = strings.find(b"\0", name_offset)
        if end < 0:
            raise ElfError(f"symbol {index} name is unterminated")
        name = strings[name_offset:end].decode("utf-8", "surrogateescape")
        if not name:
            continue
        kind = "undefined" if section_index == 0 else "defined"
        binding = BINDINGS.get(info >> 4, str(info >> 4))
        symbol_type = TYPES.get(info & 0x0F, str(info & 0x0F))
        visibility = VISIBILITIES.get(other & 0x03, str(other & 0x03))
        result.append((kind, binding, symbol_type, visibility, name))
    return sorted(set(result))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("elf", type=Path)
    parser.add_argument("--kind", choices=("defined", "undefined"))
    args = parser.parse_args()
    try:
        symbols = parse_symbols(args.elf)
    except (OSError, ElfError, struct.error) as exc:
        parser.error(f"{args.elf}: {exc}")
    for row in symbols:
        if args.kind is None or row[0] == args.kind:
            print("\t".join(row))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

