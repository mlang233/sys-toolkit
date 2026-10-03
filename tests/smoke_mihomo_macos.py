#!/usr/bin/env python3
"""Real macOS smoke test using an isolated HOME, unique label and unused port.

Downloads the official core via configured mirrors with official fallback.
--resources also downloads the default GEO files; --ui verifies panel loading.
Never runs sudo or modifies the real HOME / system proxy. Always removes its job.
"""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resources', action='store_true')
    parser.add_argument('--ui', action='store_true', help='Configure and fetch the real metacubexd dashboard.')
    parser.add_argument('--mirror-fallback', action='store_true', help='Verify real fallback after an unreachable first mirror.')
    args = parser.parse_args()
    if os.uname().sysname != 'Darwin' or os.geteuid() == 0:
        parser.error('Run as a logged-in, non-root macOS user.')
    root = Path(tempfile.mkdtemp(prefix='sys-toolkit-mihomo-smoke-')).resolve()
    label = 'io.github.sys-toolkit.mihomo.smoke.' + str(os.getpid())
    domain = 'gui/' + str(os.geteuid())
    home = root/'home'
    home.mkdir()
    base = home/'Library/Application Support/sys-toolkit/mihomo'
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    script = root/'manager.sh'
    text = (ROOT/'mihomo-manager.sh').read_text()
    text = text.replace('LABEL=io.github.sys-toolkit.mihomo\n', 'LABEL=' + label + '\n')
    text = text.replace('mixed-port: 7890', 'mixed-port: ' + str(port))
    script.write_text(text)
    env = dict(os.environ, HOME=str(home))

    def run(*command, expected=0, environment=None, timeout=360):
        result = subprocess.run(command, env=environment or env, capture_output=True, text=True, timeout=timeout)
        print('$', ' '.join(str(c) for c in command), flush=True)
        print(result.stdout + result.stderr, end='', flush=True)
        if result.returncode != expected:
            raise RuntimeError('Unexpected exit status: ' + str(result.returncode))
        return result

    def manager(*command, expected=0):
        return run('/bin/bash', str(script), *command, expected=expected)

    try:
        print('Platform:', subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(), os.uname().machine, flush=True)
        manager('download-proxy', 'show')
        if args.mirror_fallback:
            manager('download-proxy', 'set', 'https://127.0.0.1:9', 'gh.mlang.cc')
        manager('install')
        manager('test')
        run('plutil', '-lint', str(base/'service.plist'))
        manager('start')
        assert '服务：运行中' in manager('status').stdout
        run('curl', '--fail', '--silent', '--show-error', '--noproxy', '', '--max-time', '30',
            '--proxy', 'http://127.0.0.1:' + str(port), '--output', str(root/'response'), 'https://example.com')
        assert b'Example Domain' in (root/'response').read_bytes()
        print('PASS: HTTP CONNECT request through mihomo', flush=True)
        old = (base/'run/config.yaml').read_bytes()
        bad = root/'bad.yaml'
        bad.write_text('rules: [invalid-rule]\n')
        manager('config', 'set', str(bad), expected=1)
        assert (base/'run/config.yaml').read_bytes() == old
        valid = root/'valid.yaml'
        valid.write_bytes(old + b'\n# smoke imported config\n')
        manager('config', 'set', str(valid))
        manager('update-core')
        # 反复重启验证 bootout 异步卸载竞态：之前会在 bootstrap 报 5: Input/output error。
        for cycle in range(5):
            valid.write_bytes(old + ('\n# smoke restart cycle ' + str(cycle) + '\n').encode())
            manager('config', 'set', str(valid))
        assert '服务：运行中' in manager('status').stdout
        run('curl', '--fail', '--silent', '--show-error', '--noproxy', '', '--max-time', '30',
            '--proxy', 'http://127.0.0.1:' + str(port), '--output', str(root/'response2'), 'https://example.com')
        assert b'Example Domain' in (root/'response2').read_bytes()
        print('PASS: 5 transactional restarts keep the proxy serving', flush=True)
        if args.ui:
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                api_port = sock.getsockname()[1]
            valid.write_bytes(old + ('\nexternal-controller: 127.0.0.1:' + str(api_port) + '\n').encode())
            manager('config', 'set', str(valid))
            manager('config', 'ui')
            config = (base/'run/config.yaml').read_text()
            assert 'external-controller: 127.0.0.1:' + str(api_port) in config
            assert 'external-ui: ui' in config
            assert 'external-ui-url:' in config
            panel_url = 'http://127.0.0.1:' + str(api_port) + '/ui/'
            deadline = time.monotonic() + 120
            while True:
                result = subprocess.run(['curl', '--fail', '--silent', '--show-error', '--noproxy', '*',
                    '--max-time', '5', panel_url], capture_output=True)
                if result.returncode == 0 and b'<html' in result.stdout.lower():
                    break
                if time.monotonic() > deadline:
                    manager('logs', '100')
                    raise RuntimeError('Dashboard did not become available: ' + result.stderr.decode())
                time.sleep(2)
            print('PASS: real metacubexd dashboard served at /ui/', flush=True)
            manager('update-ui')
            run('curl', '--fail', '--silent', '--show-error', '--noproxy', '*', '--max-time', '10',
                '--output', str(root/'dashboard'), panel_url)
            assert b'<html' in (root/'dashboard').read_bytes().lower()
            print('PASS: transactional UI update through configured mirrors', flush=True)
            # 后续导入不带 UI 的配置仍会自动补回；保留空闲 API 端口。
            manager('config', 'set', str(valid))
            assert 'external-ui-url:' in (base/'run/config.yaml').read_text()
        if args.resources:
            manager('update-resources')
            for name in ('geoip.dat', 'geosite.dat', 'Country.mmdb', 'ASN.mmdb'):
                print(name, (base/'run'/name).stat().st_size, 'bytes', flush=True)
            # 确实引用 GEO 数据进行语义测试，避免只测试直连配置。
            valid.write_text('mixed-port: ' + str(port) + '\nallow-lan: false\ngeodata-mode: true\ngeo-auto-update: false\nrules:\n  - GEOSITE,cn,DIRECT\n  - GEOIP,CN,DIRECT\n  - MATCH,DIRECT\n')
            if args.ui:
                with valid.open('a') as config:
                    config.write('external-controller: 127.0.0.1:' + str(api_port) + '\n')
            manager('config', 'set', str(valid))
        manager('autostart', 'enable')
        persistent = home/'Library/LaunchAgents'/ (label + '.plist')
        assert plistlib.loads(persistent.read_bytes())['Label'] == label
        manager('stop')
        assert persistent.exists()
        manager('start')
        manager('autostart', 'disable')
        assert not persistent.exists()
        manager('uninstall', '--yes')
        assert (base/'run/config.yaml').exists()
        manager('uninstall', '--purge', '--yes')
        assert not base.exists()
        print('PASS: isolated macOS smoke test', flush=True)
    finally:
        subprocess.run(['launchctl', 'bootout', domain + '/' + label], capture_output=True)
        shutil.rmtree(root)


if __name__ == '__main__':
    main()
