#!/usr/bin/env python3
"""Package an optional, verified local opkg feed without preinstalling its apps."""
import argparse
import gzip
import hashlib
from pathlib import Path
import re

from build_board_packages import ARCH, gzip_tar
from make_packages_index import build as build_index


def build(feed: Path, output: Path, version: str) -> Path:
    if not re.fullmatch(r'[0-9][A-Za-z0-9.+~-]*', version):
        raise ValueError('invalid offline repository package version')
    if output.exists():
        raise ValueError('refusing to overwrite an offline repository package')
    if any(path.is_symlink() or not path.is_file() for path in feed.iterdir()):
        raise ValueError('repository entries must be regular files')
    index = (feed / 'Packages').read_bytes()
    if gzip.decompress((feed / 'Packages.gz').read_bytes()) != index:
        raise ValueError('compressed feed index differs')
    if build_index(feed).encode() != index:
        raise ValueError('feed index differs from package contents')
    names = re.findall(r'^Filename: (.+)$', index.decode(), re.M)
    if not names:
        raise ValueError('empty repository')
    # Filenames and package architectures have already passed the indexer.
    entries = []
    for name in ['Packages', 'Packages.gz'] + sorted(names):
        path = feed / name
        if not path.is_file() or path.is_symlink():
            raise ValueError('repository entries must be regular files')
        entries.append(('usr/share/sbe-offline-feed/' + name, path.read_bytes(), 0o644, None))
    entries.append(('etc/opkg/sbe-offline.conf',
                    b'src/gz sbe_offline file:///usr/share/sbe-offline-feed\n', 0o644, None))
    size = sum(len(entry[1]) for entry in entries)
    control = (f'Package: sbe-offline-feed\nVersion: {version}\nArchitecture: {ARCH}\n'
               'Maintainer: SBE1V1K community build\nSection: admin\nDepends: opkg\n'
               f'Installed-Size: {size}\nSource: SBE1V1K compatible-feed\n'
               f'Source-Revision: {hashlib.sha256(index).hexdigest()}\n'
               'Description: Optional offline software repository; update package lists after installation\n').encode()
    # Remove only this package's generated index on uninstall, not applications.
    postrm = b'#!/bin/sh\n[ "$1" != remove ] || rm -f "${IPKG_INSTROOT}/var/opkg-lists/sbe_offline"\nexit 0\n'
    controls = gzip_tar([('control', control, 0o644, None), ('postrm', postrm, 0o755, None)])
    result = gzip_tar([('debian-binary', b'2.0\n', 0o644, None),
                      ('control.tar.gz', controls, 0o644, None),
                      ('data.tar.gz', gzip_tar(entries), 0o644, None)])
    output.write_bytes(result)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--feed', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    build(args.feed, args.output, args.version)
    print(f'Packaged optional offline repository: {args.output.name}')


if __name__ == '__main__':
    main()
