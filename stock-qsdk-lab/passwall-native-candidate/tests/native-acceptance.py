#!/usr/bin/env python3
"""Check an extracted final image in a disposable, network-disabled chroot.

This does not start init, the PassWall service, updater, subscriptions, stop/cleanup,
iptables or any module command. It generates loopback-only configuration and
checks the selected core configuration and its loopback-only DNS listeners.
The listener test runs in the caller's network-disabled Docker container.
Temporary default configuration copies exist
only under the caller's disposable extracted root, never in the input image.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import socket
import time


DEPENDS = {
    'libc', 'coreutils', 'coreutils-base64', 'coreutils-nohup',
    'coreutils-timeout', 'curl', 'chinadns-ng', 'dns2socks', 'dnsmasq-full',
    'ip-full', 'libuci-lua', 'lua', 'luci-compat', 'luci-lib-jsonc',
    'microsocks', 'resolveip', 'tcping', 'lyaml',
    'ipset', 'iptables', 'ip6tables', 'ipt2socks', 'sbe-passwall-iptables-extensions',
}
PROGRAMS = {
    'xray-core': '/usr/bin/xray', 'chinadns-ng': '/usr/bin/chinadns-ng',
    'shadowsocks-rust-sslocal': '/usr/bin/sslocal',
    'dns2socks': '/usr/bin/dns2socks', 'microsocks': '/usr/bin/microsocks',
    'tcping': '/usr/bin/tcping', 'ipt2socks': '/usr/bin/ipt2socks',
    'curl': '/usr/bin/curl', 'ip-full': '/usr/libexec/ip-full',
    'resolveip': '/usr/bin/resolveip', 'dnsmasq-full': '/usr/sbin/dnsmasq',
    'coreutils-base64': '/usr/libexec/base64-coreutils',
    'coreutils-nohup': '/usr/libexec/nohup-coreutils',
    'coreutils-timeout': '/usr/libexec/timeout-coreutils',
}
PENDING = [
    'Fresh boot/PID 1, all radio bands, WAN/IPv6, NSS/PPE and thermal soak',
    'IPv4/IPv6 TCP/UDP transparent proxy, DNS/IPSet and NSS coexistence',
    'Real provider/subscription/component updates and RAM backup restore',
    'Enabled service start/stop/reload failure recovery and cleanup isolation',
]


def paragraphs(text):
    result = []
    for block in re.split(r'\n\s*\n', text.strip()):
        fields = {}
        current = None
        for line in block.splitlines():
            if line[:1].isspace() and current:
                fields[current] += '\n' + line
            elif ': ' in line or line.endswith(':'):
                current, value = line.split(':', 1)
                fields[current] = value.strip()
        if fields:
            result.append(fields)
    return result


def names(value):
    return {re.split(r'\s|\(', part.strip(), 1)[0]
            for part in value.split(',') if part.strip()}


def rooted_file(root, path):
    """Resolve absolute symlink destinations inside the extracted image."""
    parts = list(PurePosixPath(path).parts)
    if parts and parts[0] == '/':
        parts.pop(0)
    current = root
    links = 0
    while parts:
        part = parts.pop(0)
        if part == '..':
            current = current.parent
            if current != root and root not in current.parents:
                raise AssertionError('path leaves image: ' + path)
            continue
        if part in ('', '.'):
            continue
        current /= part
        if current.is_symlink():
            links += 1
            if links > 30:
                raise AssertionError('symlink loop: ' + path)
            target = current.readlink()
            current = root if target.is_absolute() else current.parent
            parts = [p for p in target.parts if p != '/'] + parts
    return current


def run(root, *args):
    result = subprocess.run(['chroot', str(root), *args], text=True,
                            capture_output=True, timeout=20)
    if result.returncode:
        raise AssertionError(f'{args!r} failed ({result.returncode}): {result.stderr.strip()}')
    return result.stdout.strip()


def audit(root):
    checks = []
    def check(condition, label):
        if not condition:
            raise AssertionError(label)
        checks.append(label)

    status = {x['Package']: x for x in paragraphs((root / 'usr/lib/opkg/status').read_text())}
    info = root / 'usr/lib/opkg/info'
    app = paragraphs((info / 'luci-app-passwall.control').read_text())[0]
    check(names(app['Depends']) == DEPENDS, '18 upstream dependencies plus five QSDK runtime dependencies')
    required = DEPENDS | set(PROGRAMS) | {'luci-app-passwall', 'luci-i18n-passwall-zh-cn', 'libyaml'}
    for package in sorted(required):
        check(package in status and status[package].get('Status', '').endswith(' installed'),
              package + ': real installed record')
        check((info / (package + '.control')).is_file(), package + ': control exists')
        check((info / (package + '.list')).is_file(), package + ': ownership list exists')
    for old in ('sbe-passwall-bundle', 'sbe-xray-core'):
        check(old not in status, old + ': historical private package absent')
    for package, path in PROGRAMS.items():
        program = rooted_file(root, path)
        check(program.is_file() and bool(program.stat().st_mode & 0o111), path + ': executable')
        check(program.read_bytes()[:4] == b'\x7fELF', path + ': actual ELF, not placeholder')
        owned = (info / (package + '.list')).read_text().splitlines()
        check(path in owned or path.lstrip('/') in owned, path + ': owned by ' + package)
    for name, alias in (('base64', '/bin/base64'), ('nohup', '/usr/bin/nohup'), ('timeout', '/usr/bin/timeout')):
        control = (info / ('coreutils-' + name + '.control')).read_text()
        target = '/usr/libexec/' + name + '-coreutils'
        check(str((root / alias.lstrip('/')).readlink()) == target, alias + ': native Alternative')
        check('300:' + alias + ':' + target in control, alias + ': Alternatives metadata')
    check('Conffiles:' in (info / 'dnsmasq-full.control').read_text() or
          (info / 'dnsmasq-full.conffiles').is_file(), 'dnsmasq-full: conffile ownership')

    controller = (root / 'usr/lib/lua/luci/controller/passwall.lua').read_text()
    for route in ('app_update', 'server', 'node_list', 'node_subscribe', 'acl', 'rule_list'):
        check('"' + route + '"' in controller, 'native controller route: ' + route)
    for method in ('create_backup', 'restore_backup'):
        check('function ' + method + '(' in controller, 'native controller method: ' + method)
    for path in ('usr/share/passwall/subscribe.lua', 'usr/lib/lua/luci/passwall/server_app.lua',
                 'usr/share/passwall/nftables.sh', 'usr/share/passwall/helper_smartdns.sh',
                 'usr/lib/lua/luci/passwall/com.lua', 'usr/lib/lua/luci/i18n/passwall.zh-cn.lmo'):
        check((root / path).is_file(), 'native feature file: ' + path)
    api = (root / 'usr/lib/lua/luci/passwall/api.lua').read_text()
    for unwanted in ('LOCKED', 'curl-sbe', 'SBE_UNSUPPORTED_CONFIG', 'valid_xray_node'):
        check(unwanted not in controller + api, 'no historical user-control restriction: ' + unwanted)

    # Fresh SquashFS may rely on upstream uci-defaults to install this template.
    config = root / 'etc/config/passwall'
    template_only = not config.exists()
    if template_only:
        check((root / 'etc/uci-defaults/luci-app-passwall').is_file(), 'fresh image has native first-install script')
        shutil.copyfile(root / 'usr/share/passwall/0_default_config', config)
    expected = {
        'passwall.@global[0].enabled': '0', 'passwall.@global[0].socks_enabled': '0',
        'passwall.@global[0].acl_enable': '0', 'passwall.@global[0].dns_shunt': 'dnsmasq',
        'passwall.@global[0].dns_mode': 'xray',
        'passwall.@global_app[0].xray_file': '/usr/bin/xray',
        'passwall_server.@global[0].enable': '0',
        'dhcp.lan.dhcpv6': 'server', 'dhcp.lan.ra': 'server',
        'dhcp.lan.ra_slaac': '1', 'dhcp.odhcpd.maindhcp': '0',
    }
    for key, value in expected.items():
        check(run(root, '/sbin/uci', '-q', 'get', key) == value, 'UCI: ' + key + '=' + value)
    for package in ('passwall', 'passwall_server', 'dhcp'):
        run(root, '/sbin/uci', '-q', 'export', package)
        checks.append('UCI parse: ' + package)

    scripts = set((root / 'usr/share/passwall').glob('*.sh'))
    scripts.update(root / path for path in ('etc/init.d/passwall', 'etc/init.d/passwall_server',
                   'usr/libexec/passwall-backup-extract', 'usr/libexec/passwall-core-extract'))
    for path in sorted(scripts):
        run(root, '/bin/sh', '-n', '/' + path.relative_to(root).as_posix())
    checks.append(f'QSDK shell syntax: {len(scripts)} scripts, no execution')
    lua = list((root / 'usr/share/passwall').rglob('*.lua'))
    lua += list((root / 'usr/lib/lua/luci/passwall').rglob('*.lua'))
    lua += list((root / 'usr/lib/lua/luci/model/cbi/passwall').rglob('*.lua'))
    lua.append(root / 'usr/lib/lua/luci/controller/passwall.lua')
    for path in sorted(set(lua)):
        target = '/' + path.relative_to(root).as_posix()
        run(root, '/usr/bin/lua', '-e', 'assert(loadfile(' + json.dumps(target) + '))')
    checks.append(f'QSDK Lua 5.1 syntax: {len(set(lua))} files, no execution')
    check('26.3.27' in run(root, '/usr/bin/xray', 'version'), 'standard Xray version executes')
    check('1.21.2' in run(root, '/usr/bin/sslocal', '--version'), 'standard sslocal version executes')
    check('sing-box' not in status and not (root / 'usr/bin/sing-box').exists(),
          'sing-box is optional in the external feed, not preinstalled')
    for name in ('base64', 'nohup', 'timeout'):
        check('8.32' in run(root, '/usr/libexec/' + name + '-coreutils', '--version'), 'GNU ' + name + ' version executes')
    # Use native UCI's local file backend, not a stub configuration generator.
    # The real LuCI UCI adapter needs ubus/rpcd, absent in this offline chroot.
    # Exercise the shipped generator, including its released-Xray schema fix.
    for core, node_type, utility, command in (
        ('xray', 'Xray', 'util_xray.lua', ('/usr/bin/xray', 'run', '-test', '-config')),
    ):
        section = 'sbe_config_test'
        for key, value in (('', 'nodes'), ('.type', node_type), ('.protocol', 'socks'),
                           ('.address', '127.0.0.1'), ('.port', '19090')):
            run(root, '/sbin/uci', 'set', 'passwall.' + section + key + '=' + value)
        params = {'flag': 'audit', 'node': section, 'local_socks_address': '127.0.0.1',
                  'local_socks_port': '18080', 'dns_listen_port': '15353',
                  'remote_dns_tcp_server': '127.0.0.1', 'remote_dns_tcp_port': '19091',
                  'no_run': True}
        driver = ("package.loaded['luci.model.uci'] = require('uci'); arg={'gen_config'," +
                  json.dumps(json.dumps(params)) + "}; dofile(" +
                  json.dumps('/usr/lib/lua/luci/passwall/' + utility) + ")")
        generated = run(root, '/usr/bin/lua', '-e', driver)
        document = json.loads(generated)
        dns_in = [x for x in document['inbounds'] if x.get('tag') == 'dns-in']
        check(len(dns_in) == 1 and dns_in[0]['settings']['network'] == 'tcp,udp',
              'generated DNS inbound uses the released Xray network field')
        target = '/tmp/' + core + '-generated.json'
        (root / target.lstrip('/')).write_text(generated)
        run(root, *command, target)
        checks.append('PassWall generated SOCKS/DNS configuration accepted by ' + core)
        # -test silently accepts unknown keys: prove the UDP socket is really
        # opened, as well as TCP. No DNS request or upstream connection is sent.
        with (root / 'tmp/xray-listener.log').open('w+') as log:
            for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
                with socket.socket(socket.AF_INET, kind) as probe:
                    probe.bind(('127.0.0.1', 15353))
            process = subprocess.Popen(['chroot', str(root), '/usr/bin/xray', 'run', '-config', target],
                                       stdout=log, stderr=log)
            try:
                bound = set()
                for attempt in range(50):
                    if process.poll() is not None:
                        log.seek(0)
                        raise AssertionError('Xray exited before DNS listener test: ' + log.read())
                    for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
                        with socket.socket(socket.AF_INET, kind) as probe:
                            try:
                                probe.bind(('127.0.0.1', 15353))
                            except OSError as exc:
                                if exc.errno != 98:
                                    raise
                                bound.add(kind)
                    if len(bound) == 2:
                        break
                    time.sleep(0.1)
                check(len(bound) == 2, 'released Xray opens both TCP and UDP DNS listeners')
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
        run(root, '/sbin/uci', 'revert', 'passwall')
    return {'offline_result': 'PASS', 'checks': checks,
            'passwall_configuration': 'native first-install template' if template_only else 'installed config',
            'hardware_pending': PENDING, 'device_access': False, 'services_started': False,
            'isolated_loopback_core_listener_test': True}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--image', required=True, type=Path)
    args = parser.parse_args()
    report = audit(args.root.resolve())
    report['image_sha256'] = hashlib.sha256(args.image.read_bytes()).hexdigest()
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
