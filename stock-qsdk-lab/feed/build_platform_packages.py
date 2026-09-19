#!/usr/bin/env python3
"""Give existing board adaptations normal ownership and updateable IPKs."""
import argparse
import json
import re
from pathlib import Path

from build_board_packages import ARCH, data_entries, install_record, write_ipk


def build(root, output, source_commit, definitions):
    if not re.fullmatch('[0-9a-f]{40}', source_commit):
        raise ValueError('a full source commit is required')
    owners = {}
    for listing in (root / 'usr/lib/opkg/info').glob('*.list'):
        for path in listing.read_text().splitlines():
            owners.setdefault(path.lstrip('/'), []).append(listing.stem)
    # Validate all packages before changing the installed database.
    for name, spec in definitions.items():
        for path in spec['files']:
            if path in owners:
                raise ValueError(f'{name}: path is already owned: {path}: {owners[path]}')
            owners[path] = [name]
        data_entries(root, spec['files'])
    output.mkdir(parents=True, exist_ok=True)
    for name, spec in definitions.items():
        version = spec['version']
        package = output / f'{name}_{version}_{ARCH}.ipk'
        # Standard OpenWrt hooks respect IPKG_INSTROOT and enable services on
        # installation. Their live restart behavior is not run by this builder.
        scripts = {hook: (
            '#!/bin/sh\n[ "${IPKG_NO_SCRIPT:-0}" = 1 ] && exit 0\n'
            '. "${IPKG_INSTROOT}/lib/functions.sh"\n'
            f'default_{hook} "$0" "$@"\n'
        ).encode() for hook in ('postinst', 'prerm')}
        write_ipk(package, name, version, spec['description'], source_commit,
                  data_entries(root, spec['files']), depends=spec['depends'],
                  conffiles=spec.get('conffiles'), scripts=scripts,
                  source='SBE1V1K stock-qsdk-lab board adaptations')
        install_record(root, name, version, spec['files'], package)
        print('packaged ' + package.name)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--source-commit', required=True)
    args = parser.parse_args()
    build(args.root, args.output, args.source_commit,
          json.loads(Path(__file__).with_name('platform-packages.json').read_text()))
