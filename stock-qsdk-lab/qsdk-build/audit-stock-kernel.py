#!/usr/bin/env python3
"""Compare an authenticated vendor kernel with an actual OpenWrt device image.

Offline only: no firmware binaries execute, and no router is contacted. Package
names alone are not a capability test; built-ins and vendor drivers need explicit
review. The report never promotes a candidate module to runtime-approved status.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import lzma
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile

LAB = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LAB / 'tools'))
from prepare_stock_source import verify_bundle, embedded_fit, kernel_lzma


def digest(data):
    return hashlib.sha256(data).hexdigest()


def kernel_config(image):
    start = image.find(b'IKCFG_ST')
    end = image.find(b'IKCFG_ED', start + 8)
    if start < 0 or end < 0 or image.find(b'IKCFG_ST', start + 8) >= 0:
        raise ValueError('expected one embedded IKCONFIG')
    return gzip.decompress(image[start + 8:end])


def config_values(text):
    result = {}
    for line in text.splitlines():
        m = re.fullmatch(r'(CONFIG_\w+)=(.*)', line)
        n = re.fullmatch(r'# (CONFIG_\w+) is not set', line)
        if m:
            result[m[1]] = m[2]
        elif n:
            result[n[1]] = 'n'
    return result


def apk_packages(text):
    packages = {}
    for record in text.strip().split('\n\n'):
        name, directory, files, version = None, '', [], None
        for line in record.splitlines():
            kind, sep, value = line.partition(':')
            if not sep:
                continue
            if kind == 'P':
                name = value
            elif kind == 'V':
                version = value
            elif kind == 'F':
                directory = value
            elif kind == 'R':
                files.append(directory + '/' + value)
        if name:
            if name in packages:
                raise ValueError('duplicate APK package: ' + name)
            packages[name] = {'version': version, 'files': files}
    return packages


def squashfs_cat(image, path):
    return subprocess.check_output(['unsquashfs', '-cat', str(image), path])


def module_paths(image):
    listing = subprocess.check_output(['unsquashfs', '-lln', str(image), 'lib/modules'], text=True)
    return sorted(re.findall(r'\bsquashfs-root/(lib/modules/[^\n]+\.ko)$', listing, re.M))


def official_root(image, profiles, sums, destination):
    profile = profiles['profiles']['askey_sbe1v1k']
    if 'askey,sbe1v1k' not in profile['supported_devices']:
        raise ValueError('wrong reference device')
    choices = [x for x in profile['images'] if x['type'] == 'sysupgrade' and x['filesystem'] == 'squashfs']
    if len(choices) != 1:
        raise ValueError('reference must specify one SquashFS sysupgrade')
    expected = choices[0]
    data = image.read_bytes()
    if len(data) != expected['size'] or digest(data) != expected['sha256']:
        raise ValueError('reference image differs from profiles.json')
    matching = [line.split()[0] for line in sums.splitlines()
                if len(line.split()) == 2 and line.split()[1].lstrip('*') == expected['name']]
    if matching != [expected['sha256']]:
        raise ValueError('reference checksum manifest does not match profiles.json')
    with tarfile.open(image) as archive:
        members = [m for m in archive.getmembers() if m.name.rstrip('/') == 'sysupgrade-askey_sbe1v1k/root']
        if len(members) != 1 or not members[0].isfile() or not 96 < members[0].size < 256 * 1024**2:
            raise ValueError('invalid reference root member')
        root = archive.extractfile(members[0]).read()
        if root[:4] != b'hsqs':
            raise ValueError('reference root is not SquashFS')
        destination.write_bytes(root)
    return {'filename': expected['name'], 'sha256': expected['sha256'],
            'source_commit': profiles['git_commit'], 'version': profiles['version_code'],
            'kernel': profiles['linux_kernel'], 'root_sha256': digest(root)}


def inspect(args):
    # Verify the SIMG itself, not a mutable derived-source.json alone.
    source_lock = json.loads(args.stock_lock.read_text())
    parts = verify_bundle(args.stock_source.read_bytes(), source_lock)
    _, fit = embedded_fit(parts['hlos-askey'])
    image = lzma.decompress(kernel_lzma(fit), format=lzma.FORMAT_ALONE)
    config = kernel_config(image)
    banners = re.findall(rb'Linux version [^\x00\n]+', image)
    if len(banners) != 1:
        raise ValueError('ambiguous vendor kernel banner')
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise ValueError('output must be a new, empty directory; old evidence is preserved')
    with tempfile.TemporaryDirectory(prefix='sbe-kernel-audit-') as tmp:
        work = Path(tmp)
        stock_root, reference_root = work / 'stock.squashfs', work / 'reference.squashfs'
        stock_root.write_bytes(parts['rootfs-askey'])
        reference, packages = None, {}
        if args.official_image:
            reference = official_root(args.official_image, json.loads(args.official_profiles.read_text()),
                                      args.official_sums.read_text(), reference_root)
            packages = apk_packages(squashfs_cat(reference_root, 'lib/apk/db/installed').decode())
            if not packages or 'kernel' not in packages:
                raise ValueError('reference APK database has no kernel package')
        stock_paths = module_paths(stock_root)
        stock_names = {Path(p).name for p in stock_paths}
        rows = []
        for name, record in sorted(packages.items()):
            if not name.startswith('kmod-'):
                continue
            names = sorted(Path(p).name for p in record['files'] if p.endswith('.ko'))
            rows.append({'package': name, 'reference_modules': names,
                         'same_named_stock_modules': sorted(set(names) & stock_names),
                         'not_in_stock_module_directory': sorted(set(names) - stock_names)})
        provider_dir = args.output / 'provider-modules'
        provider_dir.mkdir()
        providers = {}
        for name in ('x_tables', 'nf_defrag_ipv4', 'nf_defrag_ipv6'):
            paths = [p for p in stock_paths if Path(p).name == name + '.ko']
            if len(paths) != 1:
                raise ValueError('missing or ambiguous stock provider: ' + name)
            data = squashfs_cat(stock_root, paths[0])
            (provider_dir / (name + '.ko')).write_bytes(data)
            providers[name] = {'path': paths[0], 'sha256': digest(data)}
        # Keep actual provider bytes for export/dependency checks, never sparse
        # placeholder files from an earlier filesystem extraction.
        stock_dir = args.output / 'stock-modules'
        stock_dir.mkdir()
        module_hashes = {}
        for path in stock_paths:
            name = Path(path).name
            if name in module_hashes:
                raise ValueError('ambiguous stock module filename: ' + name)
            data = squashfs_cat(stock_root, path)
            if not data.startswith(b'\x7fELF'):
                raise ValueError('stock module is not ELF: ' + path)
            module_hashes[name] = digest(data)
            # macOS checkouts may be case-insensitive: xt_DSCP.ko and
            # xt_dscp.ko must not overwrite each other.
            (stock_dir / (module_hashes[name] + '.ko')).write_bytes(data)
    (args.output / 'Image').write_bytes(image)
    (args.output / 'stock.config').write_bytes(config)
    report = {'format': 1, 'stock': {'release': source_lock['release'],
              'source_sha256': source_lock['sha256'], 'kernel_sha256': digest(image),
              'config_sha256': digest(config), 'banner': banners[0].decode(),
              'modules': stock_paths, 'module_sha256': module_hashes, 'providers': providers},
              'reference': reference, 'official_kmod_comparison': rows,
              'config': config_values(config.decode()),
              'qualification': 'Absent .ko names are not proof of missing functionality; review built-ins and vendor equivalents.',
              'runtime_tested': False}
    (args.output / 'inventory.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'stock_kernel': report['stock']['kernel_sha256'],
                      'stock_config': report['stock']['config_sha256'],
                      'stock_modules': len(stock_paths), 'official_kmod_packages': len(rows),
                      'reference': reference, 'runtime_tested': False}, indent=2))


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--stock-source', type=Path, required=True)
    p.add_argument('--stock-lock', type=Path, default=LAB / 'sources/stock-1.5.3.json')
    p.add_argument('--official-image', type=Path)
    p.add_argument('--official-profiles', type=Path)
    p.add_argument('--official-sums', type=Path)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    if len([x for x in (args.official_image, args.official_profiles, args.official_sums) if x]) not in (0, 3):
        p.error('official comparison needs image, profiles and checksum manifest together')
    inspect(args)
