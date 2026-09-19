#!/usr/bin/env python3
"""Verify the actual runtime ABI, without imposing a user-facing policy."""
from pathlib import Path
import re
import subprocess
import sys

root, readelf = Path(sys.argv[1]), sys.argv[2]
count = 0
for path in sorted(root.rglob("*")):
    if not path.is_file() or path.is_symlink():
        continue
    data = path.read_bytes()
    if not data.startswith(b"\x7fELF"):
        continue
    count += 1
    header = subprocess.check_output([readelf, "-h", str(path)], text=True)
    program = subprocess.check_output([readelf, "-lW", str(path)], text=True)
    dynamic = subprocess.check_output([readelf, "-dW", str(path)], text=True)
    assert re.search(r"Class:\s+ELF64", header), path
    assert re.search(r"Machine:\s+AArch64", header), path
    assert not re.search(r"\((?:RPATH|RUNPATH)\)", dynamic), path
    needed = set(re.findall(r"\(NEEDED\).*?\[([^]]+)\]", dynamic))
    if path.name == "chinadns-ng":
        assert not needed and "INTERP" not in program, path
    else:
        expected = {"libc.so", "libgcc_s.so.1"}
        if path.name == "yaml.so":
            expected.add("libyaml-0.so.2")
            symbols = subprocess.check_output([readelf, "-Ws", str(path)], text=True)
            assert re.search(r"GLOBAL\s+DEFAULT\s+\d+\s+luaopen_yaml", symbols), path
        assert needed == expected, (path, needed)
        if "/usr/bin/" in str(path):
            assert "interpreter: /lib/ld-musl-aarch64.so.1" in program, path
        assert "GNU_RELRO" in program and "BIND_NOW" in dynamic, path
        stack = next(line for line in program.splitlines() if "GNU_STACK" in line)
        assert "RWE" not in stack, path
        if path.name.startswith("libyaml-"):
            assert "Library soname: [libyaml-0.so.2]" in dynamic, path
    assert b"/Users/" not in data and b"yangzhg" not in data, path
    print(f"PASS {path.relative_to(root)}: AArch64; NEEDED={','.join(sorted(needed)) or 'static'}")
assert count == 7, count
