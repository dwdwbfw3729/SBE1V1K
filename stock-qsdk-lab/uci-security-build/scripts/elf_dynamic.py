#!/usr/bin/env python3
"""Inspect stripped AArch64 ELF dynamic ABI without section headers."""

import argparse
from pathlib import Path
import struct
import sys

PT_LOAD = 1
PT_DYNAMIC = 2
DT_NULL = 0
DT_NEEDED = 1
DT_HASH = 4
DT_STRTAB = 5
DT_SYMTAB = 6
DT_STRSZ = 10
DT_SYMENT = 11
DT_SONAME = 14
DT_GNU_HASH = 0x6FFFFEF5

BINDINGS = {0: "LOCAL", 1: "GLOBAL", 2: "WEAK", 10: "GNU_UNIQUE"}
TYPES = {
    0: "NOTYPE", 1: "OBJECT", 2: "FUNC", 3: "SECTION", 4: "FILE",
    5: "COMMON", 6: "TLS", 10: "GNU_IFUNC",
}
VISIBILITIES = {0: "DEFAULT", 1: "INTERNAL", 2: "HIDDEN", 3: "PROTECTED"}


class ElfError(RuntimeError):
    pass


class Elf64:
    def __init__(self, path: Path):
        self.path = path
        self.data = path.read_bytes()
        if len(self.data) < 64 or self.data[:6] != b"\x7fELF\x02\x01":
            raise ElfError("not a little-endian ELF64 file")
        header = struct.unpack_from("<HHIQQQIHHHHHH", self.data, 16)
        machine, phoff, phentsize, phnum = header[1], header[4], header[8], header[9]
        if machine != 183:
            raise ElfError(f"machine is {machine}, expected AArch64 (183)")
        if phentsize < 56:
            raise ElfError("invalid program-header entry size")
        self.loads = []
        dynamic = None
        for index in range(phnum):
            offset = phoff + index * phentsize
            if offset + 56 > len(self.data):
                raise ElfError("program-header table extends beyond file")
            item = struct.unpack_from("<IIQQQQQQ", self.data, offset)
            if item[0] == PT_LOAD:
                self.loads.append((item[3], item[2], item[5]))
            elif item[0] == PT_DYNAMIC:
                dynamic = (item[2], item[5])
        if dynamic is None:
            raise ElfError("PT_DYNAMIC is missing")
        self.tags = self._read_dynamic(*dynamic)
        self.strings = self._read_strings()
        self.needed = [self._string(value) for value in self.tags.get(DT_NEEDED, [])]
        sonames = self.tags.get(DT_SONAME, [])
        self.soname = self._string(sonames[0]) if sonames else ""

    def _offset(self, address: int, size: int = 1) -> int:
        for vaddr, file_offset, file_size in self.loads:
            if vaddr <= address and address + size <= vaddr + file_size:
                result = file_offset + address - vaddr
                if result + size <= len(self.data):
                    return result
        raise ElfError(f"virtual address 0x{address:x} is outside file-backed LOAD segments")

    def _read_dynamic(self, offset: int, size: int):
        result = {}
        for cursor in range(offset, offset + size, 16):
            if cursor + 16 > len(self.data):
                raise ElfError("dynamic table extends beyond file")
            tag, value = struct.unpack_from("<QQ", self.data, cursor)
            if tag == DT_NULL:
                break
            result.setdefault(tag, []).append(value)
        return result

    def _one(self, tag: int) -> int:
        values = self.tags.get(tag, [])
        if len(values) != 1:
            raise ElfError(f"dynamic tag {tag} count is {len(values)}, expected 1")
        return values[0]

    def _read_strings(self) -> bytes:
        size = self._one(DT_STRSZ)
        offset = self._offset(self._one(DT_STRTAB), size)
        return self.data[offset:offset + size]

    def _string(self, offset: int) -> str:
        if offset >= len(self.strings):
            raise ElfError(f"invalid string offset {offset}")
        end = self.strings.find(b"\0", offset)
        if end < 0:
            raise ElfError("unterminated dynamic string")
        return self.strings[offset:end].decode("utf-8", "surrogateescape")

    def _symbol_count(self) -> int:
        if DT_HASH in self.tags:
            offset = self._offset(self._one(DT_HASH), 8)
            return struct.unpack_from("<II", self.data, offset)[1]
        if DT_GNU_HASH not in self.tags:
            raise ElfError("neither DT_HASH nor DT_GNU_HASH is present")
        offset = self._offset(self._one(DT_GNU_HASH), 16)
        buckets, first_symbol, bloom_size, _ = struct.unpack_from("<IIII", self.data, offset)
        buckets_offset = offset + 16 + bloom_size * 8
        bucket_values = struct.unpack_from(f"<{buckets}I", self.data, buckets_offset)
        highest = max(bucket_values, default=0)
        if highest < first_symbol:
            return first_symbol
        chain_offset = buckets_offset + buckets * 4
        index = highest
        while True:
            value = struct.unpack_from("<I", self.data, chain_offset + (index - first_symbol) * 4)[0]
            index += 1
            if value & 1:
                return index

    def exported_abi(self):
        entry_size = self.tags.get(DT_SYMENT, [24])[0]
        if entry_size != 24:
            raise ElfError(f"unexpected ELF64 symbol size {entry_size}")
        count = self._symbol_count()
        offset = self._offset(self._one(DT_SYMTAB), count * entry_size)
        result = set()
        for index in range(count):
            name_offset, info, other, section, _value, _size = struct.unpack_from(
                "<IBBHQQ", self.data, offset + index * entry_size
            )
            name = self._string(name_offset)
            binding = info >> 4
            visibility = other & 3
            if not name or section == 0 or binding not in (1, 2) or visibility not in (0, 3):
                continue
            result.add((
                BINDINGS.get(binding, str(binding)),
                TYPES.get(info & 15, str(info & 15)),
                VISIBILITIES.get(visibility, str(visibility)),
                name,
            ))
        return sorted(result)


def elf_files(root: Path):
    for path in root.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        try:
            with path.open("rb") as stream:
                header = stream.read(18)
                if (header[:6] == b"\x7fELF\x02\x01" and
                        len(header) == 18 and struct.unpack_from("<H", header, 16)[0] in (2, 3)):
                    yield path
        except OSError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("abi", "needed", "soname"):
        cmd = sub.add_parser(name)
        cmd.add_argument("elf", type=Path)
    consumers = sub.add_parser("consumers")
    consumers.add_argument("root", type=Path)
    consumers.add_argument("soname")
    args = parser.parse_args()

    try:
        if args.command == "consumers":
            for path in elf_files(args.root):
                elf = Elf64(path)
                if args.soname in elf.needed:
                    print("/" + str(path.relative_to(args.root)))
            return 0
        elf = Elf64(args.elf)
        if args.command == "abi":
            for row in elf.exported_abi():
                print("\t".join(row))
        elif args.command == "needed":
            for name in elf.needed:
                print(name)
        else:
            print(elf.soname)
        return 0
    except (OSError, ElfError, struct.error, UnicodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
