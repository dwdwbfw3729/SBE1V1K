#!/usr/bin/env python3
"""Package the verified dnsmasq 2.93 full-configurable variant and QSDK service.

No device access, build-system mutation or live configuration import is used.
"""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
LAB = HERE.parent
EPOCH = 1788883544
VERSION = '2.93-1-qsdk3'
ARCH = 'aarch64_cortex-a73_neon-vfpv4'
NAME = f'dnsmasq-full_{VERSION}_{ARCH}.ipk'
LOCKED_SERVICE_IPK = LAB / 'cache/ipk/dnsmasq-dhcpv6_2.80-16.3_aarch64_generic.ipk'
LOCKED_BINARY_IPK = LAB / 'cache/candidates/dnsmasq-2.93-bd5566f8.ipk'


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


archive = module('native_xray_packaging', HERE / 'package-xray.py').archive


def payload(path, expected):
    data = path.read_bytes()
    assert hashlib.sha256(data).hexdigest() == expected, path
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        inner = tar.extractfile('./data.tar.gz').read()
    files = {}
    with tarfile.open(fileobj=io.BytesIO(inner)) as tar:
        for info in tar:
            if info.isdir():
                continue
            assert info.isfile(), info.name
            name = info.name.removeprefix('./')
            assert not name.startswith('/') and '..' not in Path(name).parts
            files[name] = (tar.extractfile(info).read(), info.mode)
    return files


def build():
    files = payload(LOCKED_SERVICE_IPK, 'b1835f6123fdb913cedfc97f9ba38b6f231a0fa48d4428eb2f282f65c84b299f')
    binary = payload(LOCKED_BINARY_IPK, 'bd5566f85e107c38aac012012b72af0a48dad8d4216bc229970e956567ea9410')
    data = binary['usr/libexec/sbe-qsdk-lab/dnsmasq-2.93'][0]
    assert hashlib.sha256(data).hexdigest() == '8348f2957816dad03240f4a17ef3ddde1de64aea4ea5b1c63a28f2fdd7a78fe1'
    files['usr/sbin/dnsmasq'] = data, 0o755
    original_init = files['etc/init.d/dnsmasq'][0]
    assert hashlib.sha256(original_init).hexdigest() == '87eab5b0393fabef42902d5fa59e12d90d236f4e39b9ca48409103605799f52e'
    # Reproduce the same established resolver-directory correction from source.
    # Only this function is called, only in the disposable directory below.
    patcher = module('native_dnsmasq_rootfs_patch', LAB / 'tools/patch_stock_rootfs.py')
    with tempfile.TemporaryDirectory(prefix='native-dnsmasq-init-') as name:
        root = Path(name)
        init = root / 'etc/init.d/dnsmasq'
        init.parent.mkdir(parents=True)
        init.write_bytes(original_init)
        patcher.patch_dnsmasq_runtime_resolver(root)
        corrected = init.read_bytes()
    # Derived service bytes are covered by the generated package provenance
    # and deterministic-build test, not a stale output hash in the recipe.
    files['etc/init.d/dnsmasq'] = corrected, 0o755
    config, mode = files['etc/config/dhcp']
    assert config.count(b'/tmp/resolv.conf.auto') == 1
    files['etc/config/dhcp'] = config.replace(
        b'/tmp/resolv.conf.auto', b'/tmp/resolv.conf.d/resolv.conf.auto'), mode
    control = f'''Package: dnsmasq-full
Version: {VERSION}
Architecture: {ARCH}
Depends: libc, libgcc1, libubox20191228, libubus20210603, libnetfilter-conntrack3, libnfnetlink0, kmod-ipt-ipset, sbe-platform (>= 1.0.1-1)
Provides: dnsmasq, dnsmasq-dhcpv6
Conflicts: dnsmasq, dnsmasq-dhcpv6
Replaces: dnsmasq, dnsmasq-dhcpv6
Section: net
Priority: optional
Require-User: dnsmasq=453:dnsmasq=453
License: GPL-2.0-or-later
Source: https://thekelleys.org.uk/dnsmasq/dnsmasq-2.93.tar.xz
Source-Revision: 0c00d4e5c97c8306e5fb932b348b34269c9c29a0e7df0e8e82958b407092bc19
Installed-Size: {sum(len(data) for data, _ in files.values())}
Description: DNS and DHCP server, configurable full variant for QSDK.
 Includes IPv6, DHCPv4/v6, TFTP, UBus, auth, IPSet and conntrack.
 Built without DNSSEC and nftset for the current fw3/IPSet system.
'''.encode()
    postinst = b'''#!/bin/sh
# Apply updated service/sandbox settings through the normal init service.
[ -n "$IPKG_INSTROOT" ] && exit 0
. /lib/functions.sh
add_group_and_user dnsmasq-full
/etc/init.d/dnsmasq enable
/etc/init.d/dnsmasq restart
'''
    prerm = b'''#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
[ "$PKG_UPGRADE" = 1 ] && exit 0
[ "$1" = remove ] || exit 0
/etc/init.d/dnsmasq stop
/etc/init.d/dnsmasq disable
'''
    controls = [('./control', control, 0o644),
                ('./conffiles', b'/etc/config/dhcp\n/etc/dnsmasq.conf\n', 0o644),
                ('./postinst', postinst, 0o755), ('./prerm', prerm, 0o755)]
    result = archive([('./debian-binary', b'2.0\n', 0o644),
                      ('./control.tar.gz', archive(controls, EPOCH), 0o644),
                      ('./data.tar.gz', archive([('./' + path, data, mode) for path, (data, mode) in sorted(files.items())], EPOCH), 0o644)], EPOCH)
    return result, files


if __name__ == '__main__':
    result, files = build()
    assert result == build()[0], 'two package preparations differ'
    out = HERE / 'candidate-out'
    out.mkdir(exist_ok=True)
    target = out / NAME
    if target.exists() and target.read_bytes() != result:
        raise ValueError('candidate output already exists with different contents')
    target.write_bytes(result)
    target.chmod(0o644)
    manifest = {'package': NAME, 'sha256': hashlib.sha256(result).hexdigest(),
                'files': {path: hashlib.sha256(data).hexdigest() for path, (data, _) in sorted(files.items())},
                'build_options': '-DHAVE_UBUS -DHAVE_CONNTRACK -DNO_ID -DNO_DNSSEC -DNO_NFTSET',
                'service_source': str(LOCKED_SERVICE_IPK.relative_to(LAB)),
                'binary_source': str(LOCKED_BINARY_IPK.relative_to(LAB)),
                'live_install_tested': False}
    (out / 'dnsmasq-full.manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))
