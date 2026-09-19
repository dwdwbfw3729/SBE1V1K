#!/usr/bin/env python3

import argparse
import os
import struct
import subprocess
from pathlib import Path


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
SHN_UNDEF = 0
STB_GLOBAL = 1
STB_WEAK = 2


class Elf64:
    def __init__(self, path: Path):
        self.path = path
        self.data = path.read_bytes()
        if self.data[:6] != b"\x7fELF\x02\x01":
            raise ValueError("not a little-endian ELF64 file")
        header = struct.unpack_from("<HHIQQQIHHHHHH", self.data, 16)
        machine, phoff, phentsize, phnum = header[1], header[4], header[8], header[9]
        if machine != 183:
            raise ValueError(f"unsupported ELF machine {machine}, expected AArch64")
        self.phdrs = []
        for index in range(phnum):
            off = phoff + index * phentsize
            self.phdrs.append(struct.unpack_from("<IIQQQQQQ", self.data, off))
        self.dynamic = self._read_dynamic()
        self.strtab = self._read_strtab()
        self.needed = [self._string(offset) for offset in self.dynamic.get(DT_NEEDED, [])]
        sonames = self.dynamic.get(DT_SONAME, [])
        self.soname = self._string(sonames[0]) if sonames else None
        self.defined, self.undefined, self.undefined_weak = self._read_symbols()

    def _vaddr_offset(self, address: int) -> int:
        for p_type, _, p_offset, p_vaddr, _, p_filesz, _, _ in self.phdrs:
            if p_type == PT_LOAD and p_vaddr <= address < p_vaddr + p_filesz:
                return p_offset + address - p_vaddr
        raise ValueError(f"virtual address 0x{address:x} is outside PT_LOAD")

    def _read_dynamic(self):
        result = {}
        dynamic_phdr = next((item for item in self.phdrs if item[0] == PT_DYNAMIC), None)
        if dynamic_phdr is None:
            return result
        offset, size = dynamic_phdr[2], dynamic_phdr[5]
        for cursor in range(offset, offset + size, 16):
            tag, value = struct.unpack_from("<QQ", self.data, cursor)
            if tag == DT_NULL:
                break
            result.setdefault(tag, []).append(value)
        return result

    def _read_strtab(self):
        if DT_STRTAB not in self.dynamic:
            return b""
        offset = self._vaddr_offset(self.dynamic[DT_STRTAB][0])
        size = self.dynamic.get(DT_STRSZ, [len(self.data) - offset])[0]
        return self.data[offset : offset + size]

    def _string(self, offset: int) -> str:
        end = self.strtab.find(b"\0", offset)
        if end < 0:
            end = len(self.strtab)
        return self.strtab[offset:end].decode("utf-8", errors="replace")

    def _symbol_count(self) -> int:
        if DT_HASH in self.dynamic:
            offset = self._vaddr_offset(self.dynamic[DT_HASH][0])
            _, chain_count = struct.unpack_from("<II", self.data, offset)
            return chain_count
        if DT_GNU_HASH not in self.dynamic:
            raise ValueError("ELF has neither DT_HASH nor DT_GNU_HASH")
        offset = self._vaddr_offset(self.dynamic[DT_GNU_HASH][0])
        bucket_count, symbol_offset, bloom_size, _ = struct.unpack_from(
            "<IIII", self.data, offset
        )
        buckets_offset = offset + 16 + bloom_size * 8
        buckets = struct.unpack_from(f"<{bucket_count}I", self.data, buckets_offset)
        highest = max(buckets, default=0)
        if highest < symbol_offset:
            return symbol_offset
        chain_offset = buckets_offset + bucket_count * 4
        index = highest
        while True:
            chain = struct.unpack_from(
                "<I", self.data, chain_offset + (index - symbol_offset) * 4
            )[0]
            index += 1
            if chain & 1:
                return index

    def _read_symbols(self):
        defined = set()
        undefined = set()
        undefined_weak = set()
        if DT_SYMTAB not in self.dynamic:
            return defined, undefined, undefined_weak
        offset = self._vaddr_offset(self.dynamic[DT_SYMTAB][0])
        entry_size = self.dynamic.get(DT_SYMENT, [24])[0]
        for index in range(self._symbol_count()):
            entry = struct.unpack_from("<IBBHQQ", self.data, offset + index * entry_size)
            name_offset, info, _, section_index, _, _ = entry
            name = self._string(name_offset)
            binding = info >> 4
            if not name or binding not in (STB_GLOBAL, STB_WEAK):
                continue
            if section_index == SHN_UNDEF:
                (undefined_weak if binding == STB_WEAK else undefined).add(name)
            else:
                defined.add(name)
        return defined, undefined, undefined_weak


def elf_paths(root: Path):
    for path in root.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        try:
            with path.open("rb") as stream:
                if stream.read(6) == b"\x7fELF\x02\x01":
                    yield path
        except OSError:
            continue


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--stock-root", type=Path, required=True)
    parser.add_argument("--overlay-root", type=Path, required=True)
    args = parser.parse_args()

    stock = list(elf_paths(args.stock_root))
    overlay = list(elf_paths(args.overlay_root))
    parsed = {}
    errors = []
    for path in stock + overlay:
        try:
            parsed[path] = Elf64(path)
        except (OSError, ValueError, struct.error) as error:
            errors.append(f"{path}: {error}")

    names = set()
    definitions = set()
    for path, elf in parsed.items():
        names.add(path.name)
        if elf.soname:
            names.add(elf.soname)
        definitions.update(elf.defined)
    for root in (args.stock_root, args.overlay_root):
        for path in root.rglob("*"):
            if path.is_symlink():
                names.add(path.name)

    missing_dependencies = []
    missing_symbols = []
    # Every ELF retained in the final integrated root must still have all of
    # its DT_NEEDED providers.  This catches orphaned factory userland after a
    # management stack is pruned (for example OVS or syslog-ng libraries), not
    # merely ABI mistakes in newly overlaid LuCI packages.
    for path in stock:
        elf = parsed.get(path)
        if elf is None:
            continue
        for needed in elf.needed:
            if needed not in names:
                missing_dependencies.append((path, needed))

    # Strong-symbol compatibility is intentionally checked only for overlaid
    # ELF objects: several factory plugins resolve symbols from their host
    # process and therefore cannot be validated as standalone executables.
    for path in overlay:
        elf = parsed.get(path)
        if elf is None:
            continue
        for symbol in sorted(elf.undefined - definitions):
            missing_symbols.append((path, symbol))

    print(f"stock ELF files:  {len(stock)}")
    print(f"overlay ELF files: {len(overlay)}")
    print(f"available names:   {len(names)}")
    if errors:
        print("\nELF parse errors:")
        for error in errors:
            print(f"  {error}")
    if missing_dependencies:
        print("\nMissing DT_NEEDED providers:")
        for path, name in missing_dependencies:
            print(f"  {path}: {name}")
    if missing_symbols:
        print("\nMissing strong dynamic symbols:")
        for path, name in missing_symbols:
            print(f"  {path}: {name}")
    if errors or missing_dependencies or missing_symbols:
        return 1
    print(
        "\nPASS: all final-root DT_NEEDED entries and overlay strong symbols "
        "are satisfiable."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
