#!/usr/bin/env python3
"""Compare the candidate lucihttp pair with the exact stock LuCI packages."""

import argparse
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--elf-audit-dir", required=True, type=Path)
    parser.add_argument("--stock-core", required=True, type=Path)
    parser.add_argument("--stock-lua", required=True, type=Path)
    parser.add_argument("--candidate-core", required=True, type=Path)
    parser.add_argument("--candidate-lua", required=True, type=Path)
    args = parser.parse_args()

    sys.path.insert(0, str(args.elf_audit_dir))
    from audit_elf_abi import Elf64  # pylint: disable=import-error

    stock_core = Elf64(args.stock_core)
    stock_lua = Elf64(args.stock_lua)
    candidate_core = Elf64(args.candidate_core)
    candidate_lua = Elf64(args.candidate_lua)

    if stock_core.soname != "liblucihttp.so.0":
        raise SystemExit("stock core library has an unexpected SONAME")
    if candidate_core.soname != stock_core.soname:
        raise SystemExit("candidate changed the liblucihttp ABI SONAME")
    if stock_lua.soname != "lucihttp.so" or candidate_lua.soname != "lucihttp.so":
        raise SystemExit("Lua binding SONAME changed")

    missing_core = sorted(stock_core.defined - candidate_core.defined)
    if missing_core:
        raise SystemExit("candidate dropped core exports: " + ", ".join(missing_core))
    added_core = candidate_core.defined - stock_core.defined
    allowed_added = {"lh_mpart_init", "lh_urldec_init"}
    unexpected_added = sorted(added_core - allowed_added)
    if unexpected_added:
        raise SystemExit(
            "candidate added unreviewed core exports: " + ", ".join(unexpected_added)
        )
    if candidate_lua.defined != stock_lua.defined:
        raise SystemExit("candidate changed the Lua binding export surface")

    if set(candidate_core.needed) - set(stock_core.needed):
        raise SystemExit("candidate core library introduced a new DT_NEEDED provider")
    if set(candidate_lua.needed) - set(stock_lua.needed):
        raise SystemExit("candidate Lua binding introduced a new DT_NEEDED provider")
    for required in ("liblucihttp.so.0", "liblua.so.5.1.5"):
        if required not in candidate_lua.needed:
            raise SystemExit(f"candidate Lua binding does not require {required}")

    print("PASS: 2023 lucihttp retains the 2019 ABI-0 and Lua 5.1 surfaces")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
