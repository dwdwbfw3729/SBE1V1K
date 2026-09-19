#!/usr/bin/env python3
"""Package verified, retained QSDK tools without guessing upstream versions."""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

from build_board_packages import ARCH, data_entries, install_record, write_ipk

LAB = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LAB / 'tools'))
from populate_stock_package_files import root_file, elf_needed


def capture(root: Path, output: Path, definitions: dict) -> None:
    for definition in definitions.values():
        for relative in definition['files']:
            source = root / relative
            # All selected links point at another explicitly selected payload.
            resolved = root_file(root, '/' + relative)
            for node in (source, resolved):
                target = output / node.relative_to(root)
                if target.exists() or target.is_symlink():
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(node, target, follow_symlinks=False)


def build(root: Path, original: Path, source: dict, output: Path, definitions: dict) -> list[Path]:
    if source.get('format') != 'sbe1v1k-derived-source-v1':
        raise ValueError('verified vendor source manifest required')
    # This is explicitly a vendor revision, not an invented upstream release.
    version = '0~stock' + source['release'] + '-1'
    owned = {}
    for record in (root / 'usr/lib/opkg/info').glob('*.list'):
        for name in record.read_text().splitlines():
            owned.setdefault(name.lstrip('/'), []).append(record.stem)
    for name, definition in definitions.items():
        for path in definition['files']:
            if path in owned:
                raise ValueError(f'{name}: path already owned: {path}: {owned[path]}')
            current = root_file(root, '/' + path)
            vendor = root_file(original, '/' + path)
            if current.read_bytes() != vendor.read_bytes():
                raise ValueError(f'{name}: retained payload differs from verified vendor: {path}')
            for tree in (root, original):
                leaf = tree / path
                if leaf.is_symlink() != (root / path).is_symlink():
                    raise ValueError(f'{name}: vendor link type changed: {path}')
                if leaf.is_symlink() and leaf.readlink() != (root / path).readlink():
                    raise ValueError(f'{name}: vendor link target changed: {path}')
        for path, expected in definition.get('elf_needed', {}).items():
            if elf_needed(root_file(root, '/' + path)) != sorted(expected):
                raise ValueError(f'{name}: ELF dependency drift: {path}')
    output.mkdir(parents=True, exist_ok=True)
    packages = []
    for name, definition in definitions.items():
        paths = definition['files']
        package = output / f'{name}_{version}_{ARCH}.ipk'
        write_ipk(package, name, version, definition['description'], source['source_sha256'],
                  data_entries(root, paths), depends=definition['depends'],
                  provides=definition.get('provides', ''))
        install_record(root, name, version, paths, package)
        packages.append(package)
    return packages


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', type=Path)
    parser.add_argument('--root', type=Path)
    parser.add_argument('--vendor-root', type=Path)
    parser.add_argument('--derived', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    definitions = json.loads((LAB / 'feed/base-userland-packages.json').read_text())
    if args.capture:
        capture(args.capture, args.output, definitions)
        sys.exit(0)
    if not all((args.root, args.vendor_root, args.derived)):
        parser.error('--root, --vendor-root and --derived are required when not capturing')
    for package in build(args.root, args.vendor_root, json.loads(args.derived.read_text()),
                         args.output, definitions):
        print(f'packaged {package.name} {hashlib.sha256(package.read_bytes()).hexdigest()}')
