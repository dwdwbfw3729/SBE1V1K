#!/usr/bin/env python3
"""Check package ownership and ABI rejection in a disposable final-image root."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

root, feed, lock_path = map(Path, sys.argv[1:])
lock = json.loads(lock_path.read_text())
base = 'lib/modules/' + lock['kernel_release']
info = root / 'usr/lib/opkg/info'
for name, row in lock['modules'].items():
    assert hashlib.sha256((root / base / name).read_bytes()).hexdigest() == row['sha256'], name
for name, digest in lock['retained_modules'].items():
    assert hashlib.sha256((root / base / name).read_bytes()).hexdigest() == digest, name
owners = {}
for listing in info.glob('*.list'):
    for name in listing.read_text().splitlines():
        owners.setdefault(name.lstrip('/'), set()).add(listing.stem)
for package, names in lock['packages'].items():
    for name in names:
        assert owners.get(base + '/' + name + '.ko') == {package}, (name, owners.get(base + '/' + name + '.ko'))
for feature in ('tproxy', 'socket', 'iprange', 'conntrack-extra'):
    control = (info / ('iptables-mod-' + feature + '.control')).read_text()
    assert 'kmod-ipt-' + feature in control
assert not list(feed.glob('kernel_*.ipk')), 'kernel identity must not be a downloadable dummy package'
assert 'Essential: yes' in (info / 'kernel.control').read_text()
modules = list(feed.glob('kmod-ipt-iprange_*.ipk'))
assert len(modules) == 1
shutil.copyfile(modules[0], root / 'tmp/kmod-test.ipk')
command = ['chroot', str(root), '/bin/opkg', '--force-reinstall', 'install', '/tmp/kmod-test.ipk']
env = dict(os.environ, IPKG_INSTROOT='/')
subprocess.run(command, check=True, env=env, timeout=30, capture_output=True)
status = root / 'usr/lib/opkg/status'
original = status.read_bytes()
try:
    blocks = original.decode().split('\n\n')
    matches = [n for n, block in enumerate(blocks) if block.startswith('Package: kernel\n')]
    assert len(matches) == 1
    blocks[matches[0]] = re.sub(r'^Version: .+$', 'Version: 0-incompatible-fixture', blocks[matches[0]], flags=re.M)
    status.write_text('\n\n'.join(blocks))
    result = subprocess.run(command, env=env, timeout=30, text=True, capture_output=True)
    assert result.returncode != 0 and 'kernel' in result.stderr + result.stdout, result
finally:
    status.write_bytes(original)
    # opkg may remove the old package's ownership file before rejecting a
    # forced reinstall. Restore the disposable fixture with the valid ABI so
    # subsequent package tests do not inherit deliberately damaged metadata.
    subprocess.run(command, check=True, env=env, timeout=30, capture_output=True)
    assert (info / 'kmod-ipt-iprange.list').is_file()
print('PASS: module hashes/ownership, standard dependencies, same-ABI reinstall and wrong-kernel rejection')
