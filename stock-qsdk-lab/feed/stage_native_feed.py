#!/usr/bin/env python3
"""Stage byte-preserved native IPKs and the verified xtables package."""

from __future__ import annotations

import argparse
import csv
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from make_packages_index import IndexError, read_ipk


RECORD_NAME = "Native-Packages.tsv"


@dataclass(frozen=True)
class Input:
    package: str
    install: str
    kind: str
    source: str


def read_manifest(path: Path) -> list[Input]:
    rows: list[Input] = []
    seen: set[str] = set()
    with path.open(newline="", encoding="utf-8") as stream:
        for number, fields in enumerate(csv.reader(stream, delimiter="\t"), 1):
            if not fields or fields[0].startswith("#"):
                continue
            if len(fields) != 4:
                raise SystemExit(f"{path}:{number}: expected four tab-separated fields")
            row = Input(*fields)
            if row.package in seen:
                raise SystemExit(f"{path}:{number}: duplicate package {row.package}")
            if row.install not in {"manual", "auto", "no"}:
                raise SystemExit(f"{path}:{number}: install must be manual, auto or no")
            if row.kind not in {"copy", "xtables"}:
                raise SystemExit(f"{path}:{number}: unsupported input kind {row.kind}")
            source = Path(row.source)
            if source.is_absolute() or ".." in source.parts:
                raise SystemExit(f"{path}:{number}: source must stay relative to the lab root")
            seen.add(row.package)
            rows.append(row)
    if not rows:
        raise SystemExit(f"native feed manifest is empty: {path}")
    return rows


def resolve_under(lab: Path, relative: str) -> Path:
    lab = lab.resolve()
    path = (lab / relative).resolve()
    try:
        path.relative_to(lab)
    except ValueError as error:
        raise SystemExit(f"feed input escapes the lab root: {relative}") from error
    return path


def stage_one(row: Input, lab: Path, stage: Path) -> Path:
    source = resolve_under(lab, row.source)
    if row.kind == "copy":
        if not source.is_file():
            raise SystemExit(f"missing native feed input for {row.package}: {source}")
        target = stage / source.name
        shutil.copy2(source, target)
        return target

    if not source.is_dir():
        raise SystemExit(f"missing xtables input for {row.package}: {source}")
    packager = lab / "feed/package_passwall_bundle.py"
    subprocess.run(
        [sys.executable, str(packager), "--xtables", str(source), "--output", str(stage)],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    candidates = sorted(stage.glob(f"{row.package}_*.ipk"))
    if len(candidates) != 1:
        raise SystemExit(f"xtables packager emitted {len(candidates)} candidates for {row.package}")
    return candidates[0]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lab", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()

    lab = args.lab.resolve()
    manifest = args.manifest or lab / "feed/native-feed-inputs.tsv"
    rows = read_manifest(manifest)
    args.output.mkdir(parents=True, exist_ok=True)
    if next(args.output.iterdir(), None) is not None:
        raise SystemExit(f"native feed output is not empty: {args.output}")

    records: list[str] = [
        "package\tinstall\tfilename\tsha256\tversion\tarchitecture\tsource\tdepends"
    ]
    with tempfile.TemporaryDirectory(prefix=".native-feed.", dir=args.output.parent) as temporary:
        stage = Path(temporary)
        filenames: set[str] = set()
        for row in rows:
            candidate = stage_one(row, lab, stage)
            if candidate.name in filenames:
                raise SystemExit(f"duplicate native feed filename: {candidate.name}")
            filenames.add(candidate.name)
            try:
                fields = read_ipk(candidate)
            except IndexError as error:
                raise SystemExit(str(error)) from error
            if fields["Package"] != row.package:
                raise SystemExit(
                    f"{row.source}: expected Package {row.package}, got {fields['Package']}"
                )
            expected_name = "_".join(
                (fields["Package"], fields["Version"], fields["Architecture"])
            ) + ".ipk"
            if candidate.name != expected_name:
                raise SystemExit(
                    f"{row.source}: package metadata expects filename {expected_name}, "
                    f"got {candidate.name}"
                )
            records.append(
                "\t".join(
                    (
                        row.package,
                        row.install,
                        candidate.name,
                        fields["SHA256sum"],
                        fields["Version"],
                        fields["Architecture"],
                        row.source,
                        fields.get("Depends", ""),
                    )
                )
            )

        for candidate in sorted(stage.glob("*.ipk")):
            shutil.copy2(candidate, args.output / candidate.name)
        (args.output / RECORD_NAME).write_text("\n".join(records) + "\n", encoding="utf-8")

    print(f"staged {len(rows)} native feed packages in {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
