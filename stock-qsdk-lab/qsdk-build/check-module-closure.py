#!/usr/bin/env python3
"""Check candidate imports against verified stock exports; never load modules.

Module.symvers records export ownership with zero CRC because the vendor kernel
has CONFIG_MODVERSIONS disabled. It is input for modpost dependency generation,
NOT an invented ABI checksum or a claim that structure layouts are compatible.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def elf(path, *options):
    return subprocess.check_output(['readelf', *options, str(path)], text=True)


def inspect_module(path):
    data = path.read_bytes()
    if data[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', data, 18)[0] != 183:
        raise ValueError('expected little-endian AArch64 ELF')
    shoff = struct.unpack_from('<Q', data, 40)[0]
    shsize, shcount = struct.unpack_from('<HH', data, 58)
    if shsize != 64 or not shcount or shoff + shsize * shcount > len(data):
        raise ValueError('invalid ELF section table')
    section_data, headers = {}, {}
    for index in range(shcount):
        header = struct.unpack_from('<IIQQQQIIQQ', data, shoff + index * shsize)
        headers[index] = header
        offset, size = header[4:6]
        section_data[str(index)] = data[offset:offset + size]
    sections = {m[1]: m[2] for m in re.finditer(r'^\s*\[\s*(\d+)\]\s+(\S+)',
                                               elf(path, '-SW'), re.M)}
    exports, imports = {}, set()
    # QSDK strip removes local __ksymtab_<name> labels. Parse the actual
    # PREL32 relocations, not every string in __ksymtab_strings (which can
    # also contain namespace names).
    for index, section_name in sections.items():
        if section_name not in {'__ksymtab', '__ksymtab_gpl'}:
            continue
        payload = section_data[index]
        if len(payload) % 12:
            raise ValueError('invalid PREL32 module export table length')
        pointers = {}
        for ri, rh in headers.items():
            if rh[1] != 4 or rh[7] != int(index):  # SHT_RELA, target section
                continue
            if rh[9] != 24:
                raise ValueError('unexpected ELF relocation size')
            symbols = section_data[str(rh[6])]
            for offset in range(0, rh[5], 24):
                target, info, addend = struct.unpack_from('<QQq', section_data[str(ri)], offset)
                if info & 0xffffffff != 261:  # R_AARCH64_PREL32
                    raise ValueError('unexpected export relocation type')
                si = info >> 32
                sym = struct.unpack_from('<IBBHQQ', symbols, si * 24)
                pointers[target] = (str(sym[3]), sym[4] + addend)
        def string_at(target):
            if target not in pointers:
                if struct.unpack_from('<i', payload, target)[0] == 0:
                    return ''
                raise ValueError('export pointer has no relocation')
            section, offset = pointers[target]
            value, separator, _ = section_data[section][offset:].partition(b'\x00')
            if not separator or (value and not re.fullmatch(rb'[A-Za-z_][A-Za-z0-9_]*', value)):
                raise ValueError('invalid export name or namespace')
            return value.decode()
        for offset in range(0, len(payload), 12):
            name, namespace = string_at(offset + 4), string_at(offset + 8)
            if not name or offset not in pointers or name in exports:
                raise ValueError('invalid or duplicate export entry')
            exports[name] = ('gpl' if section_name.endswith('_gpl') else 'ordinary', namespace)
    for line in elf(path, '-Ws').splitlines():
        parts = line.split()
        if len(parts) != 8:
            continue
        name = parts[7]
        if parts[6] == 'UND' and name not in {'$d', '$x'}:
            imports.add(name)
    info = {}
    for line in elf(path, '-p', '.modinfo').splitlines():
        m = re.match(r'\s*\[\s*[0-9a-f]+\]\s+([^=]+)=(.*)', line)
        if m:
            info[m[1]] = m[2]
    return exports, imports, info


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--inventory', type=Path, required=True)
    p.add_argument('--exports', type=Path, required=True)
    p.add_argument('--build', type=Path)
    p.add_argument('--providers-only', action='store_true')
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    if bool(args.build) == args.providers_only:
        p.error('choose --build or --providers-only')
    inventory = json.loads((args.inventory / 'inventory.json').read_text())
    build = (json.loads((args.build / 'build-report.json').read_text()) if args.build
             else {'stock': inventory['stock'], 'modules': {}})
    recovered = json.loads((args.exports / 'provenance.json').read_text())
    kernel = inventory['stock']['kernel_sha256']
    if not kernel == build['stock']['kernel_sha256'] == recovered['stock_kernel_sha256']:
        raise ValueError('evidence belongs to different kernels')
    if inventory['config'].get('CONFIG_MODVERSIONS') != 'n':
        raise ValueError('zero-CRC symvers only valid with CONFIG_MODVERSIONS disabled')
    if sha(args.exports / 'exports.tsv') != recovered['artifacts']['exports.tsv']:
        raise ValueError('export evidence changed')
    stock_exports = {}
    def add(name, provider, kind, namespace=''):
        if name in stock_exports:
            raise ValueError('ambiguous stock export: ' + name)
        stock_exports[name] = (provider, kind, namespace)
    with (args.exports / 'exports.tsv').open() as stream:
        for row in csv.DictReader(stream, delimiter='\t'):
            if row['namespace'] != '-':
                raise ValueError('namespaced stock exports are not supported')
            add(row['symbol'], 'vmlinux', row['export_class'])
    for name, digest in sorted(inventory['stock']['module_sha256'].items()):
        path = args.inventory / 'stock-modules' / (digest + '.ko')
        if sha(path) != digest:
            raise ValueError('stock module changed: ' + name)
        exports, _, _ = inspect_module(path)
        for symbol, (kind, namespace) in exports.items():
            add(symbol, name.removesuffix('.ko'), kind, namespace)
    candidates = {}
    all_exports = dict(stock_exports)
    for name, digest in sorted(build['modules'].items()):
        path = args.build / 'run-1' / name
        if sha(path) != digest or sha(args.build / 'run-2' / name) != digest:
            raise ValueError('candidate does not match both clean builds: ' + name)
        exports, imports, info = inspect_module(path)
        candidates[name] = (imports, info)
        for symbol, (kind, namespace) in exports.items():
            if symbol in all_exports:
                raise ValueError('candidate would replace an existing export: ' + symbol)
            all_exports[symbol] = (name.removesuffix('.ko'), kind, namespace)
    report = {'stock_kernel_sha256': kernel, 'modules': {}, 'runtime_tested': False,
              'providers_only': args.providers_only,
              'scope': 'export-name and dependency closure only; not structure ABI approval'}
    failed = False
    for name, (imports, info) in candidates.items():
        missing = sorted(imports - all_exports.keys())
        providers = sorted({all_exports[s][0] for s in imports if s in all_exports} - {'vmlinux'})
        gpl = any(all_exports[s][1] == 'gpl' for s in imports if s in all_exports)
        if any(all_exports[s][2] for s in imports if s in all_exports) or info.get('import_ns'):
            raise ValueError('candidate namespace imports require explicit review: ' + name)
        if gpl and info.get('license') not in ('GPL', 'GPL v2', 'Dual BSD/GPL', 'Dual MIT/GPL'):
            raise ValueError('GPL export used without a compatible module license: ' + name)
        if info.get('vermagic', '').strip() != '5.4.213 SMP preempt mod_unload aarch64':
            raise ValueError('unexpected candidate vermagic: ' + repr(info.get('vermagic')))
        depends = sorted(filter(None, info.get('depends', '').split(',')))
        report['modules'][name] = {'sha256': build['modules'][name], 'undefined_symbols': len(imports),
                                  'missing_exports': missing, 'provider_modules': providers,
                                  'embedded_dependencies': depends,
                                  'dependencies_complete': depends == providers}
        failed |= bool(missing) or depends != providers
    report['all_imports_resolved'] = not failed
    args.output.mkdir(parents=True, exist_ok=False)
    # Full provider inventory allows a subsequent clean build to embed correct
    # dependencies, including existing nf_tables/x_tables/defragmentation.
    (args.output / 'Module.symvers').write_text(''.join(
        f"0x00000000\t{name}\t{provider}\t{'EXPORT_SYMBOL_GPL' if kind == 'gpl' else 'EXPORT_SYMBOL'}\t{namespace}\n"
        for name, (provider, kind, namespace) in sorted(stock_exports.items())))
    report['symvers_sha256'] = sha(args.output / 'Module.symvers')
    (args.output / 'closure.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print(json.dumps(report, indent=2, sort_keys=True))
    return int(failed)


if __name__ == '__main__':
    raise SystemExit(main())
