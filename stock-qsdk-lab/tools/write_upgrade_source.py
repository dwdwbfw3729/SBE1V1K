#!/usr/bin/env python3
"""Install release derived kernel checks for the target-side upgrader."""

import argparse
import hashlib
import json
import re
from pathlib import Path


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived", type=Path, required=True)
    parser.add_argument("--fit", type=Path, required=True)
    parser.add_argument("--wifi", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    source = json.loads(args.derived.read_text())
    if source.get("format") != "sbe1v1k-derived-source-v1":
        raise ValueError("unknown derived stock source format")
    fit = args.fit.read_bytes()
    wifi = args.wifi.read_bytes()
    entry = source["artifacts"]["stock-p25.fit"]
    partition_bytes = source["artifacts"]["vendor-hlos-p25.img"]["size"]
    if entry != {"size": len(fit), "sha256": sha256(fit)} or \
            not 40 <= len(fit) <= partition_bytes or partition_bytes != 7340032:
        raise ValueError("kernel FIT differs from verified vendor source")
    wifi_entry = source["artifacts"]["stock-wifi.squashfs"]
    if wifi_entry != {"size": len(wifi), "sha256": sha256(wifi)} or \
            wifi[:4] != b"hsqs":
        raise ValueError("Wi-Fi firmware differs from verified vendor source")
    release = source["release"]
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", release):
        raise ValueError("invalid stock release identifier")
    target = args.root / "usr/share/sbe-build/upgrade-source.env"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        f"SBE_SOURCE_RELEASE={release}\n"
        f"SBE_FIT_SIZE={len(fit)}\n"
        f"SBE_FIT_SHA256={sha256(fit)}\n"
        f"SBE_P25_CANONICAL_SHA256={sha256(fit + bytes(partition_bytes - len(fit)))}\n"
    )
    target.chmod(0o644)
    (target.parent / "vendor-wifi-source").write_text(
        f"release={release}\nsha256={wifi_entry['sha256']}\n"
    )


if __name__ == "__main__":
    main()
