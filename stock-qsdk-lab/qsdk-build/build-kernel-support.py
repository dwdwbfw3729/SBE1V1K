#!/usr/bin/env python3
"""One-click offline kernel-module stage after source initialization.

Downloads only a locked pure-Python analysis dependency if absent. Compilation
and ELF inspection use network-disabled Linux Docker containers. This never
contacts a router. Build outputs must reproduce the reviewed qualification lock.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.request

LAB = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*args):
    subprocess.run(list(map(str, args)), check=True)


def main():
    source = json.loads((LAB / 'sources/stock-1.5.3.json').read_text())
    lock = json.loads((LAB / 'sources/kernel-support-1.5.3.json').read_text())
    dependency = dict(line.split('=', 1) for line in
                      (LAB / 'passwall-build-v2/stock-kallsyms-recovery.lock').read_text().splitlines()
                      if line and not line.startswith('#'))
    cache = LAB / 'cache/kernel-support'
    cache.mkdir(parents=True, exist_ok=True)
    wheel = cache / dependency['PEEWEE_WHEEL_FILENAME']
    if not wheel.exists():
        with urllib.request.urlopen('https://pypi.org/pypi/peewee/4.0.1/json', timeout=30) as response:
            files = json.load(response)['urls']
        matches = [f for f in files if f['filename'] == wheel.name and
                   f['digests']['sha256'] == dependency['PEEWEE_WHEEL_SHA256']]
        if len(matches) != 1 or not matches[0]['url'].startswith('https://files.pythonhosted.org/'):
            raise ValueError('locked symbol-analysis dependency not found')
        with tempfile.NamedTemporaryFile(dir=cache) as download:
            run('curl', '--fail', '--location', '--retry', '3', '--output', download.name, matches[0]['url'])
            if sha(Path(download.name)) != dependency['PEEWEE_WHEEL_SHA256']:
                raise ValueError('downloaded analysis dependency differs from lock')
            shutil.copyfile(download.name, wheel)
    if sha(wheel) != dependency['PEEWEE_WHEEL_SHA256']:
        raise ValueError('cached analysis dependency differs; preserved')
    work_base = LAB / 'work/kernel-support'
    work_base.mkdir(parents=True, exist_ok=True)
    # Preserve diagnostics after failures; never reuse a half-finished build.
    work = Path(tempfile.mkdtemp(prefix='build-', dir=work_base))
    print('Kernel evidence: ' + str(work.relative_to(LAB)), flush=True)
    builder = os.environ.get('QSDK_BUILD_IMAGE', 'sbe1v1k-qsdk-builder:ubuntu-22.04-arm64')
    def docker(*command):
        run('docker', 'run', '--rm', '--network', 'none', '--platform', 'linux/arm64',
            '-e', 'PYTHONDONTWRITEBYTECODE=1', '-v', f'{LAB}:/lab:ro', '-v', f'{work}:/work',
            '--entrypoint', 'python3', builder, *command)
    docker('/lab/qsdk-build/audit-stock-kernel.py', '--stock-source',
           '/lab/cache/stock-1.5.3/' + source['filename'], '--output', '/work/inventory')
    run(sys.executable, LAB / 'qsdk-build/recover-kernel-exports.py', work / 'inventory', wheel, work / 'exports')
    common = ['/lab/qsdk-build/check-module-closure.py', '--inventory', '/work/inventory',
              '--exports', '/work/exports']
    docker(*common, '--providers-only', '--output', '/work/providers')
    run('bash', LAB / 'qsdk-build/build-common-kmods-docker.sh', work / 'inventory', work / 'build', work / 'providers')
    docker(*common, '--build', '/work/build', '--output', '/work/closure')
    closure = json.loads((work / 'closure/closure.json').read_text())
    if closure['stock_kernel_sha256'] != lock['kernel_sha256'] or closure['modules'] != lock['modules']:
        raise ValueError('fresh kernel support differs from reviewed qualification; preserved for review')
    destination = LAB / 'qsdk-build/out/kernel-support-1.5.3'
    destination.mkdir(parents=True, exist_ok=True)
    for name, row in lock['modules'].items():
        target = destination / name
        if target.exists() and sha(target) != row['sha256']:
            raise ValueError('different existing artifact preserved: ' + name)
        if not target.exists():
            shutil.copyfile(work / 'build/run-1' / name, target)
    print('PASS: two clean Docker builds and complete module dependencies match the qualification lock')


if __name__ == '__main__':
    main()
