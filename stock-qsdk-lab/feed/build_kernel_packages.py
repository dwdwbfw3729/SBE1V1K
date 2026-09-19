#!/usr/bin/env python3
"""Package qualified additive modules; never rebuild or replace the kernel.

The installed kernel identity is image metadata, not a downloadable empty IPK
that could make an incompatible router satisfy an ABI dependency. Existing
vendor modules are retained byte-for-byte. No firmware/boot partition is used.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from build_board_packages import ARCH, data_entries, install_record, write_ipk


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def package(root, output, name, version, paths, source, depends='', install=True, essential=False):
    ipk = output / f'{name}_{version}_{ARCH}.ipk'
    write_ipk(ipk, name, version, 'SBE1V1K QSDK: ' + name, source,
              data_entries(root, paths), depends=depends, essential=essential)
    if install:
        install_record(root, name, version, paths, ipk)


def build(root, output, modules, lock, derived, factory):
    if lock['format'] != 1 or lock['release'] != derived['release'] or lock['source_sha256'] != derived['source_sha256']:
        raise ValueError('kernel qualification does not belong to the selected vendor image')
    for name, row in lock['modules'].items():
        if not row['dependencies_complete'] or row['missing_exports'] or sha(modules / name) != row['sha256']:
            raise ValueError('unqualified or changed kernel module: ' + name)
    version = lock['kernel_release'] + '-1-sbe' + lock['kernel_sha256'][:16]
    base = 'lib/modules/' + lock['kernel_release']
    original_modules = {p.name: sha(p) for p in (root / base).glob('*.ko')}
    if set(original_modules) & lock['modules'].keys():
        raise ValueError('additive module would replace an existing vendor module')
    for name, digest in lock['retained_modules'].items():
        if original_modules.get(name) != digest:
            raise ValueError('vendor provider differs from qualified bytes: ' + name)
    owners = {name: pkg for pkg, names in lock['packages'].items() for name in names}
    if len(owners) != sum(map(len, lock['packages'].values())):
        raise ValueError('duplicate module package ownership')
    output.mkdir(parents=True, exist_ok=True)
    for name in lock['modules']:
        shutil.copyfile(modules / name, root / base / name)
        (root / base / name).chmod(0o644)
    for pkg, names in lock['packages'].items():
        paths = [base + '/' + name + '.ko' for name in names]
        dependencies = {'kernel (= ' + version + ')'}
        additions = [n for n in names if n + '.ko' in lock['modules']]
        for name in additions:
            for provider in lock['modules'][name + '.ko']['provider_modules']:
                if provider in owners and owners[provider] != pkg:
                    dependencies.add(owners[provider])
        # kmodloader resolves .modinfo dependencies; no private init service.
        # Only new modules need a new autoload entry. Keep vendor entries intact.
        if additions:
            autoload = 'etc/modules.d/99-' + pkg.removeprefix('kmod-')
            target = root / autoload
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists():
                raise ValueError('autoload entry already exists: ' + autoload)
            target.write_text('\n'.join(additions) + '\n')
            paths.append(autoload)
        package(root, output, pkg, version, paths, lock['public_kernel_commit'], ', '.join(sorted(dependencies)))

    # Existing conntrack plugins, including the case-sensitive CONNMARK target.
    # Verify against the selected source filesystem, not a historical version.
    paths = ['usr/lib/iptables/libxt_' + name + '.so'
             for name in ('connbytes', 'connlimit', 'connmark', 'CONNMARK', 'helper', 'recent')]
    for path in paths:
        original = subprocess.check_output(['unsquashfs', '-cat', str(factory), path])
        if (root / path).read_bytes() != original:
            raise ValueError('conntrack userspace changed from vendor: ' + path)
    package(root, output, 'iptables-mod-conntrack-extra', '1.8.3-1-sbe1', paths,
            lock['source_sha256'], 'iptables, kmod-ipt-conntrack-extra')

    # Explicit compatibility metapackages: the three plugin files keep their
    # existing sole owner. Each standard feature requires its real kernel part;
    # this does not falsely advertise a userspace-only extension as functional.
    installed = (root / 'usr/lib/opkg/status').read_text()
    for feature in ('tproxy', 'socket', 'iprange'):
        package(root, output, 'iptables-mod-' + feature, '1.8.3-1-sbe1', [],
                lock['public_kernel_commit'], 'sbe-passwall-iptables-extensions, kmod-ipt-' + feature,
                install='Package: sbe-passwall-iptables-extensions\n' in installed)

    identity = 'usr/share/sbe-build/kernel-support.json'
    (root / identity).parent.mkdir(parents=True, exist_ok=True)
    (root / identity).write_text(json.dumps(lock, indent=2, sort_keys=True) + '\n')
    # Existing modules with independent package owners stay with those owners.
    owned = set()
    for path in (root / 'usr/lib/opkg/info').glob('*.list'):
        owned.update(line.lstrip('/') for line in path.read_text().splitlines())
    kernel_paths = [identity] + [base + '/' + name for name in original_modules
                                 if base + '/' + name not in owned]
    with tempfile.TemporaryDirectory(prefix='sbe-kernel-record-') as temporary:
        package(root, Path(temporary), 'kernel', version, kernel_paths,
                lock['source_sha256'], essential=True)
    for name, digest in original_modules.items():
        if sha(root / base / name) != digest:
            raise ValueError('vendor module changed during packaging: ' + name)
    print(f'PASS: {len(lock["modules"])} additive modules; all {len(original_modules)} vendor modules unchanged')


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('root', 'output', 'modules', 'lock', 'derived', 'factory'):
        p.add_argument('--' + name, type=Path, required=True)
    args = p.parse_args()
    build(args.root, args.output, args.modules, json.loads(args.lock.read_text()),
          json.loads(args.derived.read_text()), args.factory)
