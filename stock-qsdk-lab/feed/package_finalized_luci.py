#!/usr/bin/env python3
"""Publish the locked final LuCI payload, retaining upstream package metadata.

Raw candidate IPKs with post-promotion differences are private build inputs,
never feed artifacts. Apply only the existing reviewed finalization lock to
those inputs so reinstalling a released IPK cannot undo the image's fixes.
"""
import argparse
import csv
import hashlib
import io
import json
import tarfile
from pathlib import Path, PurePosixPath

from build_board_packages import gzip_tar


def entries(payload):
    result = []
    seen = set()
    with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as archive:
        for item in archive:
            name = item.name.removeprefix('./').rstrip('/')
            if name in ('', '.') and item.isdir():
                continue
            path = PurePosixPath(name)
            if path.is_absolute() or '..' in path.parts or name in seen:
                raise ValueError('unsafe or duplicate archive member: ' + name)
            seen.add(name)
            if not (item.isfile() or item.isdir() or item.issym()):
                raise ValueError('unsupported archive member: ' + name)
            result.append((name, archive.extractfile(item).read() if item.isfile() else None,
                           item.mode, item.linkname if item.issym() else None))
    return result


def finalize(raw, root, rows):
    outer = entries(raw)
    blobs = {name: payload for name, payload, _, _ in outer}
    data = entries(blobs['data.tar.gz'])
    pending = {row['path'].lstrip('/'): row for row in rows}
    output = []
    for name, payload, mode, link in data:
        row = pending.pop(name, None)
        if row:
            if row['raw_kind'] != 'file' or row['final_kind'] != 'file' or payload is None or link:
                raise ValueError('only reviewed regular-file replacements are supported: ' + name)
            if hashlib.sha256(payload).hexdigest() != row['raw_value'] or f'{mode:04o}' != row['raw_mode']:
                raise ValueError('raw LuCI payload differs from lock: ' + name)
            target = root / name
            if target.is_symlink() or not target.is_file():
                raise ValueError('final LuCI payload is not a regular file: ' + name)
            payload = target.read_bytes()
            mode = target.stat().st_mode & 0o7777
            if hashlib.sha256(payload).hexdigest() != row['final_value'] or f'{mode:04o}' != row['final_mode']:
                raise ValueError('final LuCI payload differs from lock: ' + name)
        output.append((name, payload, mode, link))
    if pending:
        raise ValueError('locked LuCI paths absent from package: ' + ', '.join(pending))
    return gzip_tar([(name, gzip_tar(output) if name == 'data.tar.gz' else payload, mode, link)
                     for name, payload, mode, link in outer])


def build(root, lab, profile, rows, output):
    packages = {}
    for row in rows:
        packages.setdefault(row['owner'], []).append(row)
    output.mkdir(parents=True, exist_ok=True)
    for name, changes in sorted(packages.items()):
        inputs = [entry for entry in profile['artifacts']
                  if entry['component'] == 'source-luci-' + name]
        if len(inputs) != 1:
            raise ValueError('expected exactly one raw candidate: ' + name)
        entry = inputs[0]
        candidate = lab / entry['path']
        raw = candidate.read_bytes()
        if hashlib.sha256(raw).hexdigest() != entry['sha256']:
            raise ValueError('raw candidate checksum mismatch: ' + name)
        target = output / candidate.name
        if target.exists():
            raise ValueError('raw/finalized feed package collision: ' + name)
        target.write_bytes(finalize(raw, root, changes))
        print('packaged finalized ' + target.name)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ('root', 'lab', 'profile', 'lock', 'output'):
        parser.add_argument('--' + option, required=True, type=Path)
    args = parser.parse_args()
    with args.lock.open() as stream:
        rows = list(csv.DictReader(stream, delimiter='\t'))
    build(args.root, args.lab, json.loads(args.profile.read_text()), rows, args.output)
