#!/usr/bin/env python3
"""Isolated integration tests: real Bash 3.2, fake OS/network/launchd/core."""
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import pty
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CORE = b'''#!/bin/bash
if [[ "$1" == -v ]]; then echo 'Mihomo fixture'; exit 0; fi
if [[ "$1" == -t ]]; then
  [[ "${FAKE_BAD_CORE:-0}" == 0 ]] || exit 1
  grep -q INVALID "$5" && exit 1
  exit 0
fi
exit 0
'''
MOCK = '''#!/usr/bin/env python3
import gzip, hashlib, io, json, os, pathlib, plistlib, signal, sys, zipfile
name = pathlib.Path(sys.argv[0]).name
a = sys.argv[1:]
root = pathlib.Path(os.environ['FAKE_ROOT'])
if name == 'uname':
    print(os.environ.get('FAKE_OS', 'Darwin') if a == ['-s'] else os.environ.get('FAKE_ARCH', 'arm64'))
elif name == 'sw_vers': print(os.environ.get('FAKE_MACOS', '14.7'))
elif name == 'id': print(os.environ.get('FAKE_UID', '501'))
elif name == 'sysctl': print(os.environ.get('FAKE_ARM', '0'))
elif name == 'sleep': pass
elif name == 'curl':
    url = a[-1]
    out = pathlib.Path(a[a.index('--output') + 1])
    with (root/'requests').open('a') as f: f.write(url + '\\n')
    if os.environ.get('FAKE_FAIL_URL') and os.environ['FAKE_FAIL_URL'] in url:
        sys.stderr.write('secret-url=' + url)
        sys.exit(22)
    core = (root/'core.gz').read_bytes()
    digest = 'sha256:' + hashlib.sha256(core).hexdigest()
    if os.environ.get('FAKE_DIGEST') == 'bad': digest = 'sha256:' + '0'*64
    if os.environ.get('FAKE_DIGEST') == 'missing': digest = None
    if 'api.github.com/repos/MetaCubeX/mihomo/releases' in url:
        v = 'v1.2.3' if url.endswith('/latest') else url.rsplit('/',1)[-1]
        assets = []
        for arch in ('arm64', 'amd64-v1'):
            n = 'mihomo-darwin-' + arch + '-' + v + '.gz'
            assets.append(dict(name=n, digest=digest, browser_download_url='https://github.com/MetaCubeX/mihomo/releases/download/' + v + '/' + n))
        out.write_text(json.dumps(dict(tag_name=v, assets=assets)))
    elif os.environ.get('FAKE_MIRROR_BAD') and os.environ['FAKE_MIRROR_BAD'] in url: out.write_bytes(b'<!DOCTYPE html>mirror error')
    elif url.endswith('.gz'): out.write_bytes(core)
    elif 'metacubexd/archive' in url:
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as z:
            z.writestr('metacubexd-gh-pages/index.html', '<html>' + os.environ.get('FAKE_UI_TEXT', 'fixture dashboard') + '</html>')
            z.writestr('metacubexd-gh-pages/assets/app.js', 'console.log("fixture")')
            if os.environ.get('FAKE_UI_BAD') == 'traversal': z.writestr('../escape', 'bad')
            if os.environ.get('FAKE_UI_BAD') == 'symlink':
                link = zipfile.ZipInfo('metacubexd-gh-pages/link')
                link.create_system = 3
                link.external_attr = 0o120777 << 16
                z.writestr(link, '/etc/passwd')
        out.write_bytes(data.getvalue())
    elif 'subscription' in url: out.write_bytes(b'INVALID' if os.environ.get('FAKE_INVALID') else b'rules: [MATCH,DIRECT]\\n')
    elif os.environ.get('FAKE_RESOURCE') == 'html': out.write_bytes(b'<!DOCTYPE html>error')
    elif os.environ.get('FAKE_RESOURCE') == 'empty': out.write_bytes(b'')
    else: out.write_bytes(b'\\x00fixture-geodata')
elif name == 'launchctl':
    statefile = root/'launch-state.json'
    state = json.loads(statefile.read_text()) if statefile.exists() else {}
    with (root/'launch-calls').open('a') as f: f.write(' '.join(a) + '\\n')

    def save():
        statefile.write_text(json.dumps(state))
    if a[0] == 'print':
        value = state.get(a[1])
        if value is None: sys.exit(113)
        # 模拟真实 launchd：bootout 返回后 job 仍需若干次查询才真正消失。
        if str(value).startswith('unloading:'):
            left = int(str(value).split(':', 1)[1]) - 1
            if left <= 0:
                state.pop(a[1], None)
                save()
                sys.exit(113)
            state[a[1]] = 'unloading:' + str(left)
            save()
            print('state = running\\npid = 42')
            sys.exit(0)
        print('state = running\\npid = 42' if value == 'running' else 'state = waiting')
    elif a[0] == 'bootout':
        if os.environ.get('FAKE_BOOTOUT_FAIL'): sys.exit(5)
        if os.environ.get('FAKE_UNLOAD_LAG'): state[a[1]] = 'unloading:' + os.environ['FAKE_UNLOAD_LAG']
        else: state.pop(a[1], None)
        save()
    elif a[0] == 'bootstrap':
        p = plistlib.load(open(a[2], 'rb'))
        key = a[1] + '/' + p['Label']
        if os.environ.get('FAKE_FAIL_BOOT_ONCE') and not (root/'boot-failed').exists():
            (root/'boot-failed').touch()
            sys.exit(5)
        if os.environ.get('FAKE_TERM_BOOT_ONCE') and not (root/'term-sent').exists():
            (root/'term-sent').touch()
            # 直接向被测管理器发信号，避免诊断捕获子进程改变父 PID。
            manager_pid = int((root/'active-manager-pid').read_text())
            os.kill(manager_pid, signal.SIGTERM)
            sys.exit(5)
        if state.get(key) is not None: sys.exit(5)
        state[key] = 'waiting' if os.environ.get('FAKE_NOT_RUNNING') else 'running'
        save()
    elif a[0] == 'kickstart': state[a[-1]] = 'running'
    save()
else: sys.exit('Unexpected mock tool: ' + name)
'''


class ManagerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='mihomo tests ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.home = self.root/'home with spaces'
        self.home.mkdir()
        mockbin = self.root/'mockbin'
        mockbin.mkdir()
        for tool in ('uname', 'sw_vers', 'id', 'sysctl', 'sleep', 'curl', 'launchctl'):
            p = mockbin/tool
            p.write_text(MOCK)
            p.chmod(0o755)
        (self.root/'core.gz').write_bytes(gzip.compress(CORE))
        self.env = dict(os.environ, HOME=str(self.home), SHELL='/bin/zsh', FAKE_ROOT=str(self.root), PATH=str(mockbin) + ':' + os.environ['PATH'])
        self.env.pop('ZDOTDIR', None)
        self.script = self.root/'manager.sh'
        # Rewrite only fixed system paths in a test copy, never allow production path overrides.
        text = (ROOT/'mihomo-manager.sh').read_text()
        text = text.replace("BASE='/Library/Application Support/sys-toolkit/mihomo'", "BASE='" + str(self.root/'system data/mihomo') + "'")
        text = text.replace('PERSIST="/Library/LaunchDaemons/$LABEL.plist"', 'PERSIST="' + str(self.root) + '/system agents/$LABEL.plist"')
        self.script.write_text(text)
        self.base = self.home/'Library/Application Support/sys-toolkit/mihomo'
        self.persist = self.home/'Library/LaunchAgents/io.github.sys-toolkit.mihomo.plist'

    def run_cmd(self, *args, ok=True, extra=None):
        env = self.env.copy()
        env.update(extra or {})
        with subprocess.Popen(['/bin/bash', str(self.script), *args], env=env, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, errors='replace') as process:
            (self.root/'active-manager-pid').write_text(str(process.pid))
            try:
                stdout, stderr = process.communicate(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
                raise
            r = subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)
        if ok:
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        else:
            self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        return r

    def install(self):
        self.run_cmd('install')

    def config_file(self, content):
        p = self.root/'my config.yaml'
        p.write_text(content)
        return str(p)

    def assert_clean(self):
        self.assertFalse((self.base/'.lock').exists())
        self.assertEqual(list(self.base.glob('.stage.*')), [])

    def assert_clean_base(self, base):
        self.assertFalse((base/'.lock').exists())
        self.assertEqual(list(base.glob('.stage.*')), [])

    def base_system(self):
        return self.root/'system data/mihomo'

    def persist_system(self):
        return self.root/'system agents/io.github.sys-toolkit.mihomo.plist'

    def test_help_without_platform_or_dependencies(self):
        self.assertIn('macOS', self.run_cmd('help', extra={'FAKE_OS': 'Linux'}).stdout)
        self.assertIn('用法', self.run_cmd().stdout)

    def test_ui_missing_fields_idempotent_and_private(self):
        self.install()
        original = (self.base/'run/config.yaml').read_bytes()
        self.run_cmd('config', 'ui')
        config = self.base/'run/config.yaml'
        patched = config.read_bytes()
        self.assertTrue(patched.startswith(original))
        for field in ('external-ui: ui', 'external-controller: 127.0.0.1:9090',
                      'external-ui-url: "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"'):
            self.assertEqual(patched.decode().count(field), 1)
        self.assertEqual(config.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.base/'ui-enabled').stat().st_mode & 0o777, 0o600)
        self.run_cmd('config', 'ui')
        self.assertEqual(config.read_bytes(), patched)
        self.assertIn('UI 自动补充记录', self.run_cmd('info').stdout)
        self.assert_clean()

    def test_download_proxy_settings_read_only_validation_and_modes(self):
        r = self.run_cmd('download-proxy', 'show')
        self.assertIn('https://gh.mlang.cc/{url}', r.stdout)
        self.assertFalse(self.base.exists())
        self.run_cmd('download-proxy', 'set', 'gh.mlang.cc', 'https://other.example/{path}')
        settings = self.base/'download-proxy.json'
        data = json.loads(settings.read_text())
        self.assertEqual(data['mirrors'], ['https://gh.mlang.cc/{url}', 'https://other.example/{path}'])
        self.assertEqual(settings.stat().st_mode & 0o777, 0o600)
        old = settings.read_bytes()
        for args in [('http://bad.example',), ('https://user:password@host/',),
                     ('https://host/{url}/{url}',), ('https://host/?token=secret',),
                     ('https://same.example', 'same.example')]:
            self.run_cmd('download-proxy', 'set', *args, ok=False)
            self.assertEqual(settings.read_bytes(), old)
        self.run_cmd('download-proxy', 'disable')
        self.assertEqual(json.loads(settings.read_text())['mirrors'], [])
        self.run_cmd('download-proxy', 'reset')
        self.assertEqual(json.loads(settings.read_text())['mirrors'][0], 'https://gh.mlang.cc/{url}')
        self.assert_clean()

    def test_core_mirror_corruption_fallback_and_official_digest(self):
        self.run_cmd('download-proxy', 'set', 'gh.mlang.cc', 'https://second.example/{path}')
        r = self.run_cmd('install', extra={'FAKE_MIRROR_BAD': 'gh.mlang.cc'})
        requests = (self.root/'requests').read_text().splitlines()
        self.assertTrue(requests[0].startswith('https://api.github.com/'))
        self.assertIn('https://gh.mlang.cc/https://github.com/', requests[1])
        self.assertIn('https://second.example/github.com/', requests[2])
        self.assertIn('SHA-256 不匹配', r.stdout)
        self.assertIn('来源通过下载和包校验：second.example', r.stdout)
        self.assertEqual((self.base/'bin/mihomo').read_bytes(), CORE)

    def test_core_all_mirrors_fail_then_official_or_preserve_old(self):
        self.run_cmd('install', extra={'FAKE_FAIL_URL': '/https://github.com/'})
        requests = (self.root/'requests').read_text().splitlines()
        self.assertTrue(requests[-1].startswith('https://github.com/MetaCubeX/mihomo/releases/'))
        old = (self.base/'bin/mihomo').read_bytes()
        self.run_cmd('update-core', ok=False, extra={'FAKE_FAIL_URL': '.gz'})
        self.assertEqual((self.base/'bin/mihomo').read_bytes(), old)
        self.assert_clean()

    def test_ui_package_fallback_cache_and_named_directory(self):
        self.install()
        self.run_cmd('config', 'set', self.config_file("external-ui: 'custom panel'\nexternal-ui-name: xd\nrules: []\n"))
        self.run_cmd('config', 'ui', extra={'FAKE_MIRROR_BAD': 'gh.mlang.cc'})
        ui = self.base/'run/custom panel/xd'
        self.assertIn('fixture dashboard', (ui/'index.html').read_text())
        self.assertTrue((ui/'assets/app.js').exists())
        self.assertFalse((ui/'metacubexd-gh-pages').exists())
        requests = (self.root/'requests').read_text()
        self.assertIn('https://ghfast.top/https://github.com/MetaCubeX/metacubexd/', requests)
        self.run_cmd('config', 'ui', extra={'FAKE_FAIL_URL': 'metacubexd'})
        self.assertEqual((self.root/'requests').read_text(), requests)
        self.run_cmd('update-ui', extra={'FAKE_UI_TEXT': 'new dashboard'})
        self.assertIn('new dashboard', (ui/'index.html').read_text())

    def test_ui_unsafe_packages_and_paths_preserve_files(self):
        self.install()
        old_config = (self.base/'run/config.yaml').read_bytes()
        for kind in ('traversal', 'symlink'):
            self.run_cmd('config', 'ui', ok=False, extra={'FAKE_UI_BAD': kind})
            self.assertEqual((self.base/'run/config.yaml').read_bytes(), old_config)
            self.assertFalse((self.base/'ui-enabled').exists())
            self.assertFalse((self.base/'run/ui').exists())
            self.assertFalse((self.base/'escape').exists())
            self.assert_clean()
        for target in ('.', '../outside', str(self.root/'outside'), 'config.yaml'):
            self.run_cmd('config', 'set', self.config_file('external-ui: ' + json.dumps(target) + '\nrules: []\n'))
            old_config = (self.base/'run/config.yaml').read_bytes()
            self.run_cmd('config', 'ui', ok=False)
            self.assertEqual((self.base/'run/config.yaml').read_bytes(), old_config)
            self.assertFalse((self.root/'outside').exists())

    def test_ui_directory_restart_failure_and_term_roll_back(self):
        self.install()
        self.run_cmd('config', 'ui')
        self.run_cmd('start')
        ui = self.base/'run/ui'
        before = {str(p.relative_to(ui)): p.read_bytes() for p in ui.rglob('*') if p.is_file()}
        old_config = (self.base/'run/config.yaml').read_bytes()
        for failure in ('FAKE_FAIL_BOOT_ONCE', 'FAKE_TERM_BOOT_ONCE'):
            r = self.run_cmd('update-ui', ok=False, extra={failure: '1', 'FAKE_UI_TEXT': 'replacement'})
            if failure == 'FAKE_TERM_BOOT_ONCE':
                self.assertEqual(r.returncode, 143)
            self.assertEqual({str(p.relative_to(ui)): p.read_bytes() for p in ui.rglob('*') if p.is_file()}, before)
            self.assertEqual((self.base/'run/config.yaml').read_bytes(), old_config)
            self.assertTrue((self.base/'ui-enabled').exists())
            self.assertIn('服务：运行中', self.run_cmd('status').stdout)
            self.assert_clean()

    def test_download_proxies_never_receive_subscription_or_disabled_assets(self):
        self.run_cmd('download-proxy', 'disable')
        self.install()
        self.run_cmd('config', 'set', 'https://subscription.example/?token=private')
        self.run_cmd('config', 'ui')
        requests = (self.root/'requests').read_text().splitlines()
        self.assertFalse(any('gh.mlang.cc' in url or 'ghfast.top' in url for url in requests))
        self.assertEqual([url for url in requests if 'subscription' in url], ['https://subscription.example/?token=private'])

    def test_ui_preserves_existing_fields_and_nested_content(self):
        self.install()
        content = '''---
# subscription comment
external-ui: "custom panel" # keep directory
'external-controller': "127.0.0.1:9191" # keep port
"external-ui-url": "https://old.example/ui.zip" # update URL
external-ui-name: xd
secret: "keep#secret"
proxy-providers:
  example:
    external-ui-url: nested-value
    note: |-
      external-ui: text in scalar
      "unclosed quote in literal
rules:
- MATCH,DIRECT
...
'''
        self.run_cmd('config', 'set', self.config_file(content))
        self.run_cmd('config', 'ui')
        patched = (self.base/'run/config.yaml').read_text()
        expected = content.replace('https://old.example/ui.zip',
            'https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip')
        self.assertEqual(patched, expected)

    def test_ui_empty_fields_and_document_end(self):
        self.install()
        content = '---\r\nexternal-ui: "" # directory\r\nexternal-controller: null\r\nrules: [MATCH,DIRECT]\r\n...\r\n'
        path = Path(self.config_file(''))
        path.write_bytes(content.encode())
        self.run_cmd('config', 'set', str(path))
        self.run_cmd('config', 'ui')
        patched = (self.base/'run/config.yaml').read_bytes()
        self.assertIn(b'external-ui: ui # directory\r\n', patched)
        self.assertIn(b'external-controller: 127.0.0.1:9090\r\n', patched)
        self.assertTrue(patched.endswith(b'gh-pages.zip"\r\n...\r\n'))

    def test_ui_source_persistence_and_subscription_refresh(self):
        self.install()
        self.run_cmd('config', 'set', 'https://subscription.example/?token=private')
        source = (self.base/'config-url').read_bytes()
        self.run_cmd('config', 'ui')
        self.assertEqual((self.base/'config-url').read_bytes(), source)
        self.run_cmd('config', 'update')
        self.assertIn('external-ui: ui', (self.base/'run/config.yaml').read_text())
        self.assertEqual((self.base/'config-url').read_bytes(), source)
        self.run_cmd('config', 'set', self.config_file('rules: [MATCH,DIRECT]\n'))
        self.assertIn('external-ui-url:', (self.base/'run/config.yaml').read_text())
        self.assertFalse((self.base/'config-url').exists())

    def test_ui_rejects_ambiguous_yaml_without_changes(self):
        self.install()
        for content in ('{rules: [MATCH,DIRECT]}\n',
                        'rules: [MATCH,DIRECT]\n---\nrules: []\n',
                        'external-ui: first\nexternal-ui: second\nrules: []\n',
                        'external-ui: |\n  multiline\nrules: []\n',
                        'external-ui: *alias\nrules: []\n',
                        'nested: {\nexternal-ui: hidden,\nvalue: ok}\nrules: []\n',
                        'description: "multiline\nexternal-ui: fake\nvalue"\nrules: []\n'):
            with self.subTest(content=content):
                self.run_cmd('config', 'set', self.config_file(content))
                original = (self.base/'run/config.yaml').read_bytes()
                self.run_cmd('config', 'ui', ok=False)
                self.assertEqual((self.base/'run/config.yaml').read_bytes(), original)
                self.assertFalse((self.base/'ui-enabled').exists())
                self.assert_clean()

    def test_ui_validation_and_restart_failure_roll_back_marker(self):
        self.install()
        self.run_cmd('start')
        original = (self.base/'run/config.yaml').read_bytes()
        self.run_cmd('config', 'ui', ok=False, extra={'FAKE_BAD_CORE': '1'})
        self.assertEqual((self.base/'run/config.yaml').read_bytes(), original)
        self.assertFalse((self.base/'ui-enabled').exists())
        self.run_cmd('config', 'ui', ok=False, extra={'FAKE_FAIL_BOOT_ONCE': '1'})
        self.assertEqual((self.base/'run/config.yaml').read_bytes(), original)
        self.assertFalse((self.base/'ui-enabled').exists())
        self.assertIn('服务：运行中', self.run_cmd('status').stdout)
        self.assert_clean()

    def test_info_before_install_is_read_only_in_both_modes(self):
        r = self.run_cmd('info')
        self.assertIn('内核：未安装', r.stdout)
        self.assertIn(str(self.base/'run/config.yaml') + ' [未创建]', r.stdout)
        self.assertFalse(self.base.exists())
        r = self.run_cmd('--system', 'info', extra={'FAKE_UID': '0'})
        self.assertIn('launchd 服务：system/', r.stdout)
        self.assertIn(str(self.root/'system data/mihomo/run'), r.stdout)
        self.assertFalse((self.root/'system data').exists())
        self.run_cmd('info', 'extra', ok=False)
        self.assertFalse(self.base.exists())

    def test_info_with_running_service_and_lock_preserves_files_and_redacts_source(self):
        self.install()
        self.run_cmd('config', 'set', 'https://example.com/subscription?token=PRIVATE_TOKEN')
        self.run_cmd('start')
        lock = self.base/'.lock'
        lock.mkdir()
        (lock/'pid').write_text(str(os.getpid()))
        def snapshot():
            return {str(p.relative_to(self.base)): (p.stat().st_mode, p.read_bytes() if p.is_file() else None)
                    for p in self.base.rglob('*')}
        before = snapshot()
        r = self.run_cmd('info')
        self.assertIn('服务：运行中', r.stdout)
        self.assertIn(str(self.base/'config-url') + ' [已存在]', r.stdout)
        self.assertNotIn('PRIVATE_TOKEN', r.stdout + r.stderr)
        self.assertNotIn('rules: [MATCH,DIRECT]', r.stdout + r.stderr)
        self.assertEqual(snapshot(), before)

    def test_menu_dispatch_with_bash32_empty_mode_array(self):
        master, slave = pty.openpty()
        try:
            os.write(master, b'1\n\n5\n16\n17\n19\ndisable\n18\n0\n')
            r = subprocess.run(['/bin/bash', str(self.script)], env=self.env, stdin=slave,
                               capture_output=True, text=True, timeout=30)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('内核已安装', r.stdout)
            self.assertIn('服务：未加载', r.stdout)
            self.assertIn('运行目录（内核 -d）', r.stdout)
            self.assertIn('Web 面板配置已启用', r.stdout)
            self.assertTrue((self.base/'ui-enabled').exists())
            self.assertEqual(json.loads((self.base/'download-proxy.json').read_text())['mirrors'], [])
            self.assertIn('macOS mihomo · 更新 Web 面板', r.stdout)
            self.assertTrue((self.base/'bin/mihomo').exists())
        finally:
            os.close(master)
            os.close(slave)

    def test_unload_waits_for_async_bootout_before_restart(self):
        # 回归：bootout 成功但 launchd 尚未卸载完成时，立即 bootstrap 会返回
        # Bootstrap failed: 5: Input/output error；修复后应先等待卸载完成。
        self.install()
        self.run_cmd('start')
        old = (self.base/'run/config.yaml').read_bytes()
        r = self.run_cmd('config', 'set', self.config_file('rules: [MATCH,DIRECT]\n# async unload\n'),
                         extra={'FAKE_UNLOAD_LAG': '3'})
        self.assertIn('配置已更新', r.stdout)
        self.assertNotEqual((self.base/'run/config.yaml').read_bytes(), old)
        self.assertIn('服务：运行中', self.run_cmd('status').stdout)
        self.assert_clean()

    def test_enable_tun_requires_system_mode(self):
        # 用户模式必须在建目录/取锁之前拒绝，避免留下半成品状态。
        for cmd in ('enable-tun', 'disable-tun'):
            with self.subTest(cmd=cmd):
                r = self.run_cmd(cmd, ok=False)
                self.assertIn('sudo mm --system ' + cmd, r.stdout + r.stderr)
        self.assertFalse(self.base.exists())
        self.assertFalse((self.root/'system data').exists())

    def test_enable_tun_rejects_config_without_tun_section(self):
        env = {'FAKE_UID': '0'}
        self.run_cmd('--system', 'install', extra=env)
        r = self.run_cmd('--system', 'enable-tun', self.config_file('rules: [MATCH,DIRECT]\n'), ok=False, extra=env)
        self.assertIn('没有顶层 tun 段', r.stdout + r.stderr)
        self.assertFalse(self.persist_system().exists())
        self.assert_clean_base(self.base_system())

    def test_enable_tun_imports_config_flips_enable_and_sets_autostart(self):
        env = {'FAKE_UID': '0'}
        source = self.config_file('mixed-port: 7892\ntun:\n  enable: false # 保持注释\n  stack: mixed\n  auto-route: true\n  dns-hijack:\n    - any:53\nrules:\n  - MATCH,DIRECT\n')
        self.run_cmd('--system', 'install', extra=env)
        self.run_cmd('--system', 'enable-tun', source, extra=env)
        base = self.base_system()
        config = (base/'run/config.yaml').read_text()
        self.assertIn('  enable: true # 保持注释', config)
        self.assertIn('  stack: mixed', config)
        self.assertIn('  dns-hijack:', config)
        self.assertEqual((base/'tun-mode').read_text(), 'mode=persistent\n')
        self.assertTrue(self.persist_system().exists())
        self.assertIn('bootstrap system ', (self.root/'launch-calls').read_text())
        self.assertIn('TUN 模式：已启用（系统实例 + 开机自启）', self.run_cmd('--system', 'status', extra=env).stdout)
        self.assertIn('TUN 模式记录', self.run_cmd('--system', 'info', extra=env).stdout)
        self.assert_clean_base(base)

    def test_enable_tun_inserts_enable_when_missing_and_installs_first(self):
        env = {'FAKE_UID': '0'}
        source = self.config_file('tun:\n  stack: system\n  auto-route: true\nrules:\n  - MATCH,DIRECT\n')
        self.run_cmd('--system', 'enable-tun', source, extra=env)
        base = self.base_system()
        self.assertTrue((base/'bin/mihomo').exists())
        self.assertIn('  enable: true', (base/'run/config.yaml').read_text())
        self.assertEqual((base/'tun-mode').read_text(), 'mode=persistent\n')

    def test_disable_tun_stops_service_and_removes_autostart(self):
        env = {'FAKE_UID': '0'}
        source = self.config_file('tun:\n  enable: true\n  stack: system\nrules:\n  - MATCH,DIRECT\n')
        self.run_cmd('--system', 'enable-tun', source, extra=env)
        base = self.base_system()
        self.assertIn('服务：运行中', self.run_cmd('--system', 'status', extra=env).stdout)
        self.run_cmd('--system', 'disable-tun', extra=env)
        self.assertFalse(self.persist_system().exists())
        self.assertEqual((base/'tun-mode').read_text(), 'mode=user\n')
        status = self.run_cmd('--system', 'status', extra=env).stdout
        self.assertIn('TUN 模式：系统实例仅手动启动', status)
        self.assertIn('服务：未加载', status)
        self.assert_clean_base(base)

    def test_menu_enable_tun_dispatch_in_system_mode(self):
        env = dict(self.env, FAKE_UID='0')
        self.run_cmd('--system', 'install', extra={'FAKE_UID': '0'})
        self.run_cmd('--system', 'config', 'set',
                     self.config_file('tun:\n  enable: false\n  stack: system\nrules:\n  - MATCH,DIRECT\n'),
                     extra={'FAKE_UID': '0'})
        master, slave = pty.openpty()
        try:
            os.write(master, b'20\n0\n')
            r = subprocess.run(['/bin/bash', str(self.script), '--system'], env=env, stdin=slave,
                               capture_output=True, text=True, timeout=30)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('TUN 模式已启用', r.stdout)
        finally:
            os.close(master)
            os.close(slave)
        self.assertIn('  enable: true', (self.base_system()/'run/config.yaml').read_text())
        self.assertTrue(self.persist_system().exists())

    def test_platform_and_permission_guards(self):
        for extra, args in [({'FAKE_OS': 'Linux'}, ['install']), ({'FAKE_MACOS': '11.7'}, ['install']),
                            ({'FAKE_UID': '0'}, ['install']), ({}, ['--system', 'install'])]:
            with self.subTest(extra=extra, args=args):
                self.run_cmd(*args, ok=False, extra=extra)
                self.assertFalse(self.base.exists())

    def test_install_private_config_and_plist(self):
        self.install()
        self.assertEqual((self.base/'run/config.yaml').stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.base.stat().st_mode & 0o777, 0o700)
        p = plistlib.loads((self.base/'service.plist').read_bytes())
        self.assertEqual(p['ProgramArguments'][0], str(self.base/'bin/mihomo'))
        self.assertTrue(p['KeepAlive'])
        self.assertFalse(self.persist.exists())
        self.assert_clean()

    def test_install_sets_standalone_mm_and_idempotent_zsh_path(self):
        rc = self.home/'.zshrc'
        rc.write_bytes(b'# existing settings\r\nexport CUSTOM=value\r\n')
        rc.chmod(0o640)
        self.install()
        entry = self.home/'.local/bin/mm'
        self.assertTrue(os.access(entry, os.X_OK))
        self.assertEqual(entry.read_bytes(), self.script.read_bytes())
        first = rc.read_bytes()
        self.assertTrue(first.startswith(b'# existing settings\r\nexport CUSTOM=value\r\n'))
        self.install()
        self.assertEqual(rc.read_bytes(), first)
        self.assertEqual(rc.stat().st_mode & 0o777, 0o640)
        r = subprocess.run(['/bin/zsh', '-f', '-c', 'source "$HOME/.zshrc"; mm help'],
                           env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('macOS mihomo', r.stdout)
        self.script.unlink()
        self.run_cmd_from_entry(entry, 'status')

    def run_cmd_from_entry(self, entry, *args):
        r = subprocess.run([str(entry), *args], env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r

    def test_shortcut_before_core_install_and_bash_login_profile(self):
        profile = self.home/'.bash_login'
        profile.write_text('# preserve login profile\n')
        self.run_cmd('shortcut', extra={'SHELL': '/bin/bash'})
        self.assertFalse((self.base/'bin/mihomo').exists())
        self.assertFalse((self.home/'.bash_profile').exists())
        self.assertIn('sys-toolkit mihomo mm', profile.read_text())
        self.assertIn('sys-toolkit mihomo mm', (self.home/'.bashrc').read_text())
        entry = self.home/'.local/bin/mm'
        self.run_cmd_from_entry(entry, 'install')
        self.assertTrue((self.base/'bin/mihomo').exists())
        self.run_cmd_from_entry(entry, 'uninstall', '--yes')
        self.assertFalse(entry.exists())
        self.assertEqual(profile.read_text(), '# preserve login profile\n')
        self.assertNotIn('sys-toolkit mihomo mm', (self.home/'.bashrc').read_text())

    def test_shortcut_respects_zdotdir_and_symlinked_rc(self):
        dotdir = self.home/'dot files'
        dotdir.mkdir()
        real = dotdir/'real-zshrc'
        real.write_text('# original\n')
        rc = dotdir/'.zshrc'
        rc.symlink_to(real)
        self.run_cmd('shortcut', extra={'ZDOTDIR': str(dotdir)})
        self.assertTrue(rc.is_symlink())
        self.assertIn('sys-toolkit mihomo mm', real.read_text())
        self.run_cmd('uninstall', '--purge', '--yes')
        self.assertEqual(real.read_text(), '# original\n')
        self.assertTrue(rc.is_symlink())

    def test_existing_mm_binary_or_alias_is_preserved(self):
        entry = self.home/'.local/bin/mm'
        entry.parent.mkdir(parents=True)
        entry.write_text('#!/bin/bash\necho other-tool\n')
        entry.chmod(0o755)
        before = entry.read_bytes()
        self.run_cmd('shortcut', ok=False)
        r = self.run_cmd('install')
        self.assertIn('快捷命令未配置', r.stderr)
        self.assertEqual(entry.read_bytes(), before)
        self.assertTrue((self.base/'bin/mihomo').exists())
        entry.unlink()
        rc = self.home/'.zshrc'
        rc.write_text("alias mm='other-tool'\n")
        self.run_cmd('shortcut', ok=False)
        self.assertEqual(rc.read_text(), "alias mm='other-tool'\n")
        self.assertFalse(entry.exists())

    def test_shortcut_refuses_path_conflict_and_retains_replaced_entry(self):
        other = self.root/'mockbin/mm'
        other.write_text('#!/bin/bash\necho existing\n')
        other.chmod(0o755)
        self.run_cmd('shortcut', ok=False)
        self.assertFalse((self.home/'.zshrc').exists())
        other.unlink()
        self.run_cmd('shortcut')
        entry = self.home/'.local/bin/mm'
        entry.write_text('#!/bin/bash\necho replaced\n')
        self.run_cmd('uninstall', '--purge', '--yes')
        self.assertIn('replaced', entry.read_text())
        self.assertNotIn('sys-toolkit mihomo mm', (self.home/'.zshrc').read_text())

    def test_repeat_install_preserves_config(self):
        self.install()
        self.run_cmd('config', 'set', self.config_file('rules: [MATCH,DIRECT]\n# custom\n'))
        before = (self.base/'run/config.yaml').read_bytes()
        self.install()
        self.assertEqual((self.base/'run/config.yaml').read_bytes(), before)

    def test_architecture_asset_selection(self):
        for arch, arm, expected in [('arm64', '0', 'darwin-arm64'), ('x86_64', '0', 'darwin-amd64-v1'), ('x86_64', '1', 'darwin-arm64')]:
            with self.subTest(arch=arch, arm=arm):
                self.run_cmd('install', '1.2.4', extra={'FAKE_ARCH': arch, 'FAKE_ARM': arm})
                self.assertIn(expected + '-v1.2.4.gz', (self.root/'requests').read_text().splitlines()[-1])

    def test_digest_missing_or_wrong_preserves_core(self):
        self.install()
        before = (self.base/'bin/mihomo').read_bytes()
        for digest in ('bad', 'missing'):
            self.run_cmd('update-core', ok=False, extra={'FAKE_DIGEST': digest})
            self.assertEqual((self.base/'bin/mihomo').read_bytes(), before)
            self.assert_clean()

    def test_failed_download_redacts_secret(self):
        self.install()
        r = self.run_cmd('config', 'set', 'https://example.com/subscription?token=MYSECRET', ok=False, extra={'FAKE_FAIL_URL': 'subscription'})
        self.assertNotIn('MYSECRET', r.stdout + r.stderr)
        self.assert_clean()

    def test_invalid_candidate_core_preserves_config_and_core(self):
        self.install()
        old = (self.base/'bin/mihomo').read_bytes()
        self.run_cmd('update-core', ok=False, extra={'FAKE_BAD_CORE': '1'})
        self.assertEqual((self.base/'bin/mihomo').read_bytes(), old)
        self.assertTrue((self.base/'logs/last-test.log').exists())

    def test_start_stop_restart_idempotence(self):
        self.install()
        for cmd in ('start', 'start', 'restart'):
            self.run_cmd(cmd)
            self.assertIn('服务：运行中', self.run_cmd('status').stdout)
        for _ in range(2):
            self.run_cmd('stop')
        self.assertIn('服务：未加载', self.run_cmd('status').stdout)
        self.assertFalse(self.persist.exists())

    def test_start_liveness_failure_returns_nonzero(self):
        self.install()
        self.run_cmd('start', ok=False, extra={'FAKE_NOT_RUNNING': '1'})
        self.assertIn('当前未运行', self.run_cmd('status').stdout)

    def test_remote_config_update_and_local_clear_source(self):
        self.install()
        self.run_cmd('config', 'set', 'https://example.com/subscription?token=private')
        self.assertEqual((self.base/'config-url').stat().st_mode & 0o777, 0o600)
        self.run_cmd('config', 'update')
        self.run_cmd('config', 'set', self.config_file('rules: [MATCH,DIRECT]\n'))
        self.assertFalse((self.base/'config-url').exists())
        self.run_cmd('config', 'update', ok=False)

    def test_invalid_config_preserves_source_and_file(self):
        self.install()
        self.run_cmd('config', 'set', 'https://example.com/subscription')
        old = (self.base/'run/config.yaml').read_bytes()
        self.run_cmd('config', 'set', self.config_file('INVALID'), ok=False)
        self.assertEqual((self.base/'run/config.yaml').read_bytes(), old)
        self.assertTrue((self.base/'config-url').exists())
        self.assert_clean()

    def test_running_config_failure_rolls_back_source_and_service(self):
        self.install()
        self.run_cmd('start')
        old = (self.base/'run/config.yaml').read_bytes()
        self.run_cmd('config', 'set', 'https://example.com/subscription', ok=False, extra={'FAKE_FAIL_BOOT_ONCE': '1'})
        self.assertEqual((self.base/'run/config.yaml').read_bytes(), old)
        self.assertFalse((self.base/'config-url').exists())
        self.assertIn('服务：运行中', self.run_cmd('status').stdout)
        self.assert_clean()

    def test_running_core_failure_rolls_back_binary(self):
        self.install()
        self.run_cmd('start')
        old = (self.base/'bin/mihomo').read_bytes()
        (self.root/'core.gz').write_bytes(gzip.compress(CORE + b'# changed\n'))
        self.run_cmd('update-core', ok=False, extra={'FAKE_FAIL_BOOT_ONCE': '1'})
        self.assertEqual((self.base/'bin/mihomo').read_bytes(), old)
        self.assertIn('服务：运行中', self.run_cmd('status').stdout)

    def test_term_during_commit_restores_files_and_service(self):
        self.install()
        self.run_cmd('start')
        old = (self.base/'run/config.yaml').read_bytes()
        r = self.run_cmd('config', 'set', 'https://example.com/subscription', ok=False, extra={'FAKE_TERM_BOOT_ONCE': '1'})
        self.assertEqual(r.returncode, 143)
        self.assertEqual((self.base/'run/config.yaml').read_bytes(), old)
        self.assertFalse((self.base/'config-url').exists())
        self.assertIn('服务：运行中', self.run_cmd('status').stdout)
        self.assert_clean()

    def test_recovery_failure_preserves_staging_backup(self):
        self.install()
        self.run_cmd('start')
        r = self.run_cmd('config', 'set', 'https://example.com/subscription', ok=False, extra={'FAKE_BOOTOUT_FAIL': '1'})
        self.assertIn('自动恢复未完成', r.stderr)
        stages = list(self.base.glob('.stage.*'))
        self.assertEqual(len(stages), 1)
        self.assertTrue((stages[0]/'rollback/run/config.yaml').exists())
        self.assertFalse((self.base/'.lock').exists())

    def test_resource_download_failure_is_all_or_nothing(self):
        self.install()
        p = self.base/'run/geoip.dat'
        p.write_bytes(b'OLD')
        self.run_cmd('update-resources', 'geoip.dat', 'geosite.dat', ok=False, extra={'FAKE_FAIL_URL': 'geosite.dat'})
        self.assertEqual(p.read_bytes(), b'OLD')
        self.assertFalse((self.base/'run/geosite.dat').exists())
        self.assert_clean()

    def test_html_empty_hash_and_traversal_resource_rejected(self):
        self.install()
        for val in ('html', 'empty'):
            self.run_cmd('update-resources', 'geoip.dat', ok=False, extra={'FAKE_RESOURCE': val})
        (self.base/'resources.json').write_text(json.dumps({'../evil': {'url': 'https://example.com/evil'}}))
        self.run_cmd('update-resources', ok=False)
        (self.base/'resources.json').write_text(json.dumps({'geoip.dat': {'url': 'https://example.com/geo', 'sha256': '0'*64}}))
        self.run_cmd('update-resources', ok=False)
        self.assertFalse((self.base/'run/geoip.dat').exists())

    def test_resource_success_and_absent_file_rollback(self):
        self.install()
        self.run_cmd('update-resources', 'geoip.dat')
        self.assertTrue((self.base/'run/geoip.dat').exists())
        self.run_cmd('start')
        self.run_cmd('update-resources', 'geosite.dat', ok=False, extra={'FAKE_FAIL_BOOT_ONCE': '1'})
        self.assertFalse((self.base/'run/geosite.dat').exists())
        self.assertIn('服务：运行中', self.run_cmd('status').stdout)

    def test_autostart_enable_disable_user(self):
        self.install()
        self.run_cmd('autostart', 'enable')
        self.assertEqual(self.persist.stat().st_mode & 0o777, 0o644)
        self.assertIn('登录自启：已启用', self.run_cmd('autostart', 'status').stdout)
        self.run_cmd('stop')
        self.assertTrue(self.persist.exists())
        self.run_cmd('autostart', 'disable')
        self.assertFalse(self.persist.exists())
        self.assertIn('服务：未加载', self.run_cmd('status').stdout)

    def test_system_mode_uses_system_domain_and_fixed_paths(self):
        env = {'FAKE_UID': '0'}
        self.run_cmd('--system', 'install', extra=env)
        self.assertFalse((self.home/'.zshrc').exists())
        self.assertFalse((self.home/'.local/bin/mm').exists())
        self.run_cmd('--system', 'autostart', 'enable', extra=env)
        persist = self.root/'system agents/io.github.sys-toolkit.mihomo.plist'
        p = plistlib.loads(persist.read_bytes())
        self.assertIn('system data', p['ProgramArguments'][0])
        self.assertIn('bootstrap system ', (self.root/'launch-calls').read_text())
        self.run_cmd('--system', 'autostart', 'disable', extra=env)
        self.assertFalse(persist.exists())

    def test_uninstall_retains_data_then_purge_is_scoped(self):
        self.install()
        self.run_cmd('autostart', 'enable')
        unrelated = self.base.parent/'other-tool'
        unrelated.mkdir()
        self.run_cmd('uninstall', ok=False)
        self.assertTrue((self.base/'bin/mihomo').exists())
        self.run_cmd('uninstall', '--yes')
        self.assertTrue((self.base/'run/config.yaml').exists())
        self.assertFalse((self.base/'bin').exists())
        self.assertFalse(self.persist.exists())
        self.run_cmd('uninstall', '--purge', '--yes')
        self.assertFalse(self.base.exists())
        self.assertTrue(unrelated.exists())

    def test_lock_refuses_parallel_operation(self):
        self.install()
        (self.base/'.lock').mkdir()
        (self.base/'.lock/pid').write_text(str(os.getpid()))
        self.run_cmd('update-core', ok=False)
        self.assertEqual((self.base/'.lock/pid').read_text(), str(os.getpid()))

    def test_symlink_directory_and_config_refused(self):
        self.base.parent.mkdir(parents=True)
        self.base.symlink_to(self.root)
        self.run_cmd('install', ok=False)
        self.base.unlink()
        self.install()
        config = self.base/'run/config.yaml'
        config.unlink()
        config.symlink_to(self.root/'outside')
        self.run_cmd('uninstall', '--purge', '--yes', ok=False)
        self.assertTrue(self.base.exists())

    def test_invalid_arguments_and_http_sources(self):
        for args in [('unknown',), ('start', 'extra'), ('install', 'latest', 'extra'), ('config',),
                     ('autostart',), ('install', '../../escape')]:
            self.run_cmd(*args, ok=False)
        self.install()
        self.run_cmd('config', 'set', 'http://example.com/subscription', ok=False)
        self.run_cmd('config', 'set', 'https://user:pass@example.com/subscription', ok=False)
        self.run_cmd('logs', '0', ok=False)
        self.run_cmd('logs', '10')
        self.assert_clean()


if __name__ == '__main__':
    unittest.main(verbosity=2)
