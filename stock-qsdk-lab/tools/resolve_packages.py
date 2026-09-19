#!/usr/bin/env python3

import argparse
import gzip
import re
from pathlib import Path


RELEASE_URL = "https://downloads.openwrt.org/releases/19.07.10"
PACKAGE_FEED_URL = f"{RELEASE_URL}/packages/aarch64_generic"
SPECIAL_INDEX_URLS = {
    # libiwinfo is produced by a target build instead of the architecture feeds.
    # armvirt/64 still publishes it as aarch64_generic and enables the generic
    # nl80211/wext backends used by LuCI/rpcd.
    "armvirt64": f"{RELEASE_URL}/targets/armvirt/64/packages",
}


def parse_records(path: Path):
    with gzip.open(path, "rt", encoding="utf-8", errors="replace") as stream:
        record = {}
        for raw_line in stream:
            line = raw_line.rstrip("\n")
            if not line:
                if record:
                    yield record
                    record = {}
                continue
            if line[:1].isspace() and record:
                last_key = next(reversed(record))
                record[last_key] += "\n" + line.strip()
                continue
            key, separator, value = line.partition(":")
            if separator:
                record[key] = value.strip()
        if record:
            yield record


def dependency_names(value: str):
    for group in value.split(","):
        alternatives = []
        for item in group.split("|"):
            name = re.sub(r"\s*\([^)]*\)\s*$", "", item).strip()
            if name:
                alternatives.append(name)
        if alternatives:
            yield alternatives


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--index-dir", type=Path, required=True)
    parser.add_argument("--provided", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("packages", nargs="+")
    args = parser.parse_args()

    packages = {}
    providers = {}
    for index in sorted(args.index_dir.glob("*.Packages.gz")):
        feed = index.name.removesuffix(".Packages.gz")
        for record in parse_records(index):
            name = record.get("Package")
            filename = record.get("Filename")
            if not name or not filename:
                continue
            record["Feed"] = feed
            packages[name] = record
            providers.setdefault(name, name)
            for virtual in record.get("Provides", "").split(","):
                virtual = re.sub(r"\s*\([^)]*\)\s*$", "", virtual).strip()
                if virtual:
                    providers.setdefault(virtual, name)

    provided = {
        line.strip()
        for line in args.provided.read_text().splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }

    selected = set()
    visiting = set()

    def select(name):
        if name in provided:
            return
        concrete = providers.get(name, name)
        if concrete in provided or concrete in selected:
            return
        if concrete in visiting:
            raise RuntimeError(f"dependency cycle at {concrete}")
        record = packages.get(concrete)
        if not record:
            raise RuntimeError(f"package or provider not found: {name}")
        visiting.add(concrete)
        for alternatives in dependency_names(record.get("Depends", "")):
            choice = next((item for item in alternatives if item in provided), None)
            if choice:
                continue
            choice = next((item for item in alternatives if item in providers), None)
            if not choice:
                raise RuntimeError(
                    f"no dependency alternative for {concrete}: {' | '.join(alternatives)}"
                )
            select(choice)
        visiting.remove(concrete)
        selected.add(concrete)

    for root in args.packages:
        select(root)

    # This resolver combines OpenWrt 19.07 userland with a QSDK Linux 5.4.213
    # base.  The public 19.07 aarch64_generic feeds contain Linux 4.14.275
    # modules, which must never enter this image.  An exact factory/QSDK module
    # may satisfy a dependency only by being listed in --provided, in which
    # case it is intentionally absent from ``selected``.
    unsafe_kernel_packages = sorted(
        name
        for name in selected
        if name == "kernel"
        or name.startswith("kmod-")
        or packages[name].get("Section") == "kernel"
    )
    if unsafe_kernel_packages:
        raise RuntimeError(
            "refusing non-QSDK kernel packages: "
            + ", ".join(unsafe_kernel_packages)
        )

    lines = ["package\tversion\tfeed\tfilename\tsha256\turl"]
    for name in sorted(selected):
        record = packages[name]
        filename = record["Filename"]
        feed = record["Feed"]
        source_url = SPECIAL_INDEX_URLS.get(feed, f"{PACKAGE_FEED_URL}/{feed}")
        lines.append(
            "\t".join(
                [
                    name,
                    record.get("Version", ""),
                    feed,
                    filename,
                    record.get("SHA256sum", ""),
                    f"{source_url}/{filename}",
                ]
            )
        )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines) + "\n")
    print(f"resolved {len(selected)} packages into {args.output}")


if __name__ == "__main__":
    main()
