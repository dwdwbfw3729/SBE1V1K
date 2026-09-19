#!/usr/bin/env python3
"""Recover a verified inventory's export table, offline and without booting it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

LAB = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('inventory', type=Path)
    p.add_argument('peewee_wheel', type=Path)
    p.add_argument('output', type=Path)
    args = p.parse_args()
    inventory = args.inventory.resolve()
    report = json.loads((inventory / 'inventory.json').read_text())
    image = inventory / 'Image'
    if sha(image) != report['stock']['kernel_sha256']:
        raise ValueError('kernel differs from audited source')
    # Reuse the existing dependency lock, not its historical firmware hashes.
    lock = dict(line.split('=', 1) for line in
                (LAB / 'passwall-build-v2/stock-kallsyms-recovery.lock').read_text().splitlines()
                if line and not line.startswith('#'))
    if sha(args.peewee_wheel) != lock['PEEWEE_WHEEL_SHA256']:
        raise ValueError('dependency wheel differs from lock')
    source = LAB / 'tools/vendor/vmlinux-to-elf'
    def git(*opts):
        return subprocess.check_output(['git', '-C', str(source), *opts], text=True).strip()
    if (git('rev-parse', 'HEAD') != lock['VMLINUX_TO_ELF_COMMIT'] or
        git('rev-parse', 'HEAD^{tree}') != lock['VMLINUX_TO_ELF_TREE'] or
        git('status', '--porcelain', '--untracked-files=all')):
        raise ValueError('symbol extractor differs from dependency lock')
    args.output.mkdir(parents=True, exist_ok=False)
    output = args.output.resolve()
    with tempfile.TemporaryDirectory(prefix='sbe-symbol-deps-') as tmp:
        with zipfile.ZipFile(args.peewee_wheel) as wheel:
            # Read one known pure-Python member; do not extract archive paths.
            (Path(tmp) / 'peewee.py').write_bytes(wheel.read('peewee.py'))
        env = dict(os.environ, PYTHONPATH=os.pathsep.join((str(source), tmp)),
                   PYTHONDONTWRITEBYTECODE='1')
        commands = [
            [sys.executable, '-m', 'vmlinux_to_elf.scripts.kallsyms_finder', str(image),
             '--output', str(output / 'stock.kallsyms')],
            [sys.executable, '-m', 'vmlinux_to_elf.scripts.vmlinux_to_elf', str(image),
             str(output / 'stock.elf')],
            [sys.executable, str(LAB / 'passwall-build-v2/parse-factory-prel32-exports.py'),
             str(image), str(output / 'stock.kallsyms'), str(output / 'exports.tsv'), '--discover'],
        ]
        for number, command in enumerate(commands, 1):
            with (output / f'step-{number}.log').open('w') as log:
                subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    files = {name: sha(output / name) for name in ('stock.kallsyms', 'stock.elf', 'exports.tsv')}
    provenance = {'stock_kernel_sha256': sha(image), 'artifacts': files,
                  'extractor_commit': lock['VMLINUX_TO_ELF_COMMIT'],
                  'dependency_sha256': lock['PEEWEE_WHEEL_SHA256'],
                  'scope': 'static exports only; not structure ABI or runtime load approval'}
    (output / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    print((output / 'step-3.log').read_text(), end='')


if __name__ == '__main__':
    main()
