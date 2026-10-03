#!/bin/bash
# sys-toolkit mihomo managed mm
# macOS Bash 3.2; specification: docs/mihomo/spec.md
set -euo pipefail
umask 077

LABEL=io.github.sys-toolkit.mihomo
SYSTEM=0
BASE='' DOMAIN='' PERSIST='' BIN='' RUN='' WORK='' LOCKED=0 TX_ACTIVE=0 TX_LOADED=0
TX_TARGETS=()
ERROR_REPORTED=0
SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

ui_color() {
    if [[ -t 1 && -n "${TERM:-}" && "${TERM:-}" != dumb && "${NO_COLOR+x}" != x ]]; then
        printf '\033[%sm%s\033[0m' "$1" "$2"
    else
        printf '%s' "$2"
    fi
}
ui_title() { printf '\n  '; ui_color '1;34' "macOS mihomo · $1"; printf '\n'; }
ui_section() { printf '\n  '; ui_color '1' "$1"; printf '\n'; }
ui_message() {
    local level="$1" text="$2" code=36 label=提示
    case "$level" in
        success) code=32; label=完成 ;; step) code=36; label=进行 ;;
        warning) code=33; label=注意 ;; error) code=31; label=错误 ;;
    esac
    printf '  '; ui_color "$code" "[$label]"; printf ' %s\n' "$text"
}
ui_note() { ui_message note "$*"; }
ui_success() { ui_message success "$*"; }
ui_step() { ui_message step "$*"; }
ui_warning() { ui_message warning "$*"; }
ui_error() { ERROR_REPORTED=1; ui_message error "$*"; }
ui_line() {
    printf '  '; ui_color '1' "${1}："; ui_color "${3:-0}" "$2"; printf '\n'
}
ui_detail() {
    local line code esc=$'\033'
    while IFS= read -r line || [[ -n "$line" ]]; do
        code=0
        case "$line" in
            *'[error]'*|*'[ERROR]'*|*'level=error'*|*'level="error"'*|*'level=fatal'*) code=31 ;;
            *'[warning]'*|*'[WARN]'*|*'level=warning'*|*'level="warning"'*) code=33 ;;
        esac
        printf '    '; ui_color "$code" "$line"; printf '\n'
    done < <(printf '%s\n' "$*" | sed -E "s/${esc}\[[0-9;]*m//g")
}
ui_path() { ui_line "$1" ''; printf '    %s\n' "$2"; }
ui_command() { printf '    '; ui_color '36' "$1"; printf '\n'; }
ui_prompt() { printf '\n  '; ui_color '1;34' "$1"; }
die() { ui_error "$*" >&2; exit 1; }
run_checked() {
    local context="$1" output rc
    shift
    if output="$("$@" 2>&1)"; then
        [[ -z "$output" ]] || ui_detail "$output"
    else
        rc=$?
        ui_error "$context" >&2
        # Python 输入异常仅显示最后一行原因，避免 traceback 淹没操作结果。
        if [[ "$output" == *'Traceback (most recent call last)'* ]]; then
            output="$(printf '%s\n' "$output" | tail -n 1)"
        fi
        [[ -z "$output" ]] || ui_detail "$output" >&2
        return "$rc"
    fi
}
python_task() { local context="$1"; shift; run_checked "$context" python3 "$@"; }
help_item() { ui_command "$1"; printf '      %s\n' "$2"; }
usage() {
    ui_title '使用帮助'
    ui_line '用法' 'mm [--system] <命令>'
    ui_note '直接运行 mm 打开菜单；菜单中 h 查看帮助、0 退出。'
    ui_section '服务与诊断'
    help_item 'mm install [vX.Y.Z]' '安装最新稳定版或指定版本；保留既有配置并配置 mm。'
    help_item 'mm start | stop | restart' '启动、停止或重启服务。'
    help_item 'mm status | info' '查看服务概要，或查看运行目录、配置、日志等详细位置。'
    help_item 'mm test | logs [行数]' '测试配置，或读取日志（默认末尾 80 行）。'
    ui_section '配置与更新'
    help_item 'mm config set <文件或HTTPS URL>' '校验并导入完整配置；运行中的服务会重启。'
    help_item 'mm config update' '从保存的 HTTPS 来源更新配置。'
    help_item 'mm config ui' '配置 metacubexd 面板；缺失字段自动补齐，后续导入/订阅更新继续保留。'
    help_item 'mm update-ui' '通过加速源下载并更新 metacubexd 静态资源；失败保留旧面板。'
    help_item 'mm download-proxy show | reset | disable' '查看下载加速列表、恢复默认列表，或仅使用官方源。'
    help_item 'mm download-proxy set <链接1> [链接2...]' '按顺序设置加速前缀；支持 {url}/{path} 模板，最后回退官方源。'
    help_item 'mm update-core [vX.Y.Z]' '更新内核；省略版本使用最新稳定版。'
    help_item 'mm update-resources [文件名...]' '按 resources.json 更新全部或指定 GEO 数据。'
    ui_section '自启与卸载'
    help_item 'mm autostart enable | disable | status' '管理登录自启；--system 模式管理开机自启。'
    help_item 'mm uninstall [--purge] [--yes]' '默认保留数据；--purge 删除数据，--yes 跳过交互确认。'
    help_item 'mm shortcut' '配置或刷新 mm 快捷命令，无需先安装内核。'
    help_item 'mm help | --help | -h' '显示本帮助。'
    ui_section '使用示例'
    ui_command 'mm install'
    # shellcheck disable=SC2016 # 帮助中的命令示例保留用户终端展开的变量。
    ui_command 'mm config set "$HOME/Downloads/config.yaml"'
    ui_command 'mm start'
    # shellcheck disable=SC2016
    ui_command 'sudo "$HOME/.local/bin/mm" --system info'
    ui_section '环境与显示'
    ui_note 'macOS 12+、Bash 3.2+、Python 3，及系统 curl/gzip/shasum/launchctl/plutil。'
    ui_note '普通模式勿使用 sudo；初始配置仅直连，TUN 使用系统模式并自行配置。'
    ui_note 'NO_COLOR=1 mm 关闭颜色；长路径单独显示，输出重定向时为纯文本。'
    printf '\n'
}

manage_shortcut() {
    local action="$1" existing
    # sudo 不应改写 root 或原用户的 shell 配置。
    if [[ "$SYSTEM" -eq 1 ]]; then
        [[ "$action" != install ]] || ui_note '系统模式保留用户 shell 配置；可先用普通模式 shortcut 配置 mm。'
        return 0
    fi
    existing="$(type -P mm || true)"
    python_task '快捷命令配置失败。' - "$action" "$BASE" "$SCRIPT" "$existing" <<'PY' || return 1
import json, os, pathlib, re, shlex, stat, sys, tempfile
action, base, source, existing = sys.argv[1:]
base, source = pathlib.Path(base), pathlib.Path(source)
home = pathlib.Path.home()
entry = home/'.local/bin/mm'
state = base/'shortcut.json'
begin, end = '# >>> sys-toolkit mihomo mm >>>', '# <<< sys-toolkit mihomo mm <<<'
signature = b'# sys-toolkit mihomo managed mm'

def fail(message):
    sys.exit('错误：' + message)

def managed(path):
    return path.is_file() and not path.is_symlink() and signature in path.read_bytes().splitlines()[:2]

def strip_block(text):
    lines = text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if line.rstrip('\r\n') == begin]
    ends = [i for i, line in enumerate(lines) if line.rstrip('\r\n') == end]
    if not starts and not ends:
        return text
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
        fail('mm 配置块不完整，请先检查 shell 配置。')
    return ''.join(lines[:starts[0]] + lines[ends[0] + 1:])

def atomic_write(path, data, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '.', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
        os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)

known = json.loads(state.read_text()) if state.exists() else []
if not isinstance(known, list) or any(not isinstance(p, str) or not pathlib.Path(p).is_absolute() for p in known):
    fail('shortcut.json 格式错误。')
paths = []
if action == 'install':
    shell = pathlib.Path(os.environ.get('SHELL', '/bin/zsh')).name
    if shell == 'zsh':
        dotdir = pathlib.Path(os.environ.get('ZDOTDIR') or str(home))
        if not dotdir.is_absolute():
            fail('ZDOTDIR 必须是绝对目录。')
        paths = [dotdir/'.zshrc']
    elif shell == 'bash':
        login = next((home/n for n in ('.bash_profile', '.bash_login', '.profile') if (home/n).exists()), home/'.bash_profile')
        paths = [login, home/'.bashrc']
    else:
        fail('自动配置 mm 支持 zsh 和 Bash；请使用 SHELL=/bin/zsh 或 SHELL=/bin/bash 运行 shortcut。')
    if entry.is_symlink() or (entry.exists() and not managed(entry)):
        fail('~/.local/bin/mm 已被其他工具使用，未覆盖。')
    if existing and pathlib.Path(existing) != entry:
        fail('PATH 中已有其他 mm 命令，未覆盖。')
else:
    paths = [pathlib.Path(p) for p in known]

edits = []
for path in paths:
    if path.is_symlink() and not path.exists():
        fail('shell 配置包含失效的符号链接。')
    target = path.resolve()
    if target.exists() and (not target.is_file() or target.stat().st_uid != os.geteuid()):
        fail('shell 配置文件类型或所有权不匹配。')
    if target.exists():
        with target.open(newline='') as f:
            text = f.read()
    else:
        text = ''
    cleaned = strip_block(text)
    if action == 'install':
        if re.search(r'(?m)^\s*(?:alias\s+mm\s*=|(?:function\s+)?mm\s*\(\s*\)|function\s+mm\b|mm\s*\{)', cleaned):
            fail('shell 配置已有 mm 别名或函数，未覆盖。')
        if cleaned and not cleaned.endswith('\n'):
            cleaned += '\n'
        cleaned += begin + '\ncase ":${PATH}:" in\n  *":${HOME}/.local/bin:"*) ;;\n  *) export PATH="${HOME}/.local/bin:${PATH}" ;;\nesac\n' + end + '\n'
    mode = stat.S_IMODE(target.stat().st_mode) if target.exists() else 0o600
    if cleaned != text:
        edits.append((target, cleaned.encode(), mode))

if entry.exists() and (action == 'install' or managed(entry)) and entry.stat().st_uid != os.geteuid():
    fail('mm 文件所有权不匹配。')
if action == 'install':
    payload = source.read_bytes()
    atomic_write(entry, payload, 0o755)
for path, data, mode in edits:
    atomic_write(path, data, mode)
if action == 'install':
    atomic_write(state, json.dumps(list(dict.fromkeys(known + [str(p.resolve()) for p in paths]))).encode(), 0o600)
else:
    if managed(entry):
        entry.unlink()
    elif entry.exists() or entry.is_symlink():
        print('mm 已被其他内容替换，保留现有文件。')
    if state.exists():
        state.unlink()
PY
    if [[ "$action" == install ]]; then
        ui_success '已配置 mm 快捷命令；新开终端即可使用。'
        ui_path '命令入口' "$HOME/.local/bin/mm"
        ui_note '让当前终端立即生效：'
        # shellcheck disable=SC2016
        ui_command 'export PATH="$HOME/.local/bin:$PATH"'
    fi
}

loaded() { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }
running() {
    local state
    state="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null)" || return 1
    [[ "$state" == *'state = running'* && "$state" == *'pid = '* ]]
}
stop_job() {
    if loaded; then
        run_checked '停止服务失败。' launchctl bootout "$DOMAIN/$LABEL" || return 1
    fi
}
wait_running() {
    local i hits=0
    for ((i=0; i<10; i++)); do
        if running; then hits=$((hits + 1)); else hits=0; fi
        [[ "$hits" -ge 2 ]] && return 0
        sleep 1
    done
    ui_error '服务未稳定运行，请检查错误日志。' >&2
    ui_path '错误日志' "$BASE/logs/stderr.log" >&2
    ui_command 'mm logs 100' >&2
    return 1
}
boot_job() {
    local plist="$BASE/service.plist"
    [[ -f "$PERSIST" ]] && plist="$PERSIST"
    run_checked '启用 launchd 服务失败。' launchctl enable "$DOMAIN/$LABEL" || return 1
    run_checked '启动服务失败。' launchctl bootstrap "$DOMAIN" "$plist" || return 1
    wait_running
}

cleanup() {
    local rc=$? rel failed=0
    trap - EXIT INT TERM
    set +e
    if [[ "$rc" -ne 0 && "$ERROR_REPORTED" -eq 0 ]]; then
        ui_error "操作未完成（退出码 ${rc}）。" >&2
    fi
    if [[ "$TX_ACTIVE" -eq 1 ]]; then
        ui_warning '更新失败，正在恢复旧文件和原服务状态。' >&2
        stop_job || failed=1
        for rel in "${TX_TARGETS[@]}"; do
            rm -rf "${BASE:?}/$rel" "${BASE:?}/$rel.restore" || failed=1
            if [[ -e "$WORK/rollback/$rel" ]]; then
                cp -pR "$WORK/rollback/$rel" "$BASE/$rel.restore" &&
                    mv -f "$BASE/$rel.restore" "$BASE/$rel" || failed=1
            fi
        done
        if [[ "$TX_LOADED" -eq 1 ]]; then boot_job || failed=1; fi
        [[ "$rc" -ne 0 ]] || rc=1
    fi
    if [[ "$failed" -eq 0 ]]; then
        [[ -z "$WORK" ]] || rm -rf "$WORK"
    else
        ui_error '自动恢复未完成，请按施工文档恢复。' >&2
        ui_path '保留的恢复备份' "$WORK/rollback" >&2
    fi
    if [[ "$LOCKED" -eq 1 ]]; then rm -rf "$BASE/.lock"; fi
    exit "$rc"
}

check_environment() {
    [[ "$(uname -s)" == Darwin ]] || die '本脚本仅支持 macOS。'
    local major uid dep
    major="$(sw_vers -productVersion)"; major="${major%%.*}"
    [[ "$major" =~ ^[0-9]+$ && "$major" -ge 12 ]] || die '需要 macOS 12 或更高版本。'
    uid="$(id -u)"
    if [[ "$SYSTEM" -eq 1 ]]; then
        [[ "$uid" -eq 0 ]] || die '--system 必须通过 sudo/root 运行。'
        BASE='/Library/Application Support/sys-toolkit/mihomo'
        DOMAIN=system
        PERSIST="/Library/LaunchDaemons/$LABEL.plist"
    else
        [[ "$uid" -ne 0 ]] || die '普通模式请勿使用 sudo；开机启动请指定 --system。'
        [[ "${HOME:-}" == /* && "$HOME" != / ]] || die 'HOME 必须为绝对用户目录。'
        BASE="$HOME/Library/Application Support/sys-toolkit/mihomo"
        DOMAIN="gui/$uid"
        PERSIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    fi
    for dep in python3 curl gzip shasum launchctl plutil; do
        command -v "$dep" >/dev/null 2>&1 || die "缺少依赖 ${dep}；请先安装（Python 3 可通过 Homebrew 或 Xcode Command Line Tools 提供）。"
    done
    BIN="$BASE/bin/mihomo"; RUN="$BASE/run"
    # 拒绝管理路径上的符号链接以及非当前用户拥有的文件。
    python_task '管理路径检查失败。' - "$BASE" "$PERSIST" <<'PY'
import os, pathlib, sys
for arg in sys.argv[1:]:
    p = pathlib.Path(arg)
    for part in (p, *p.parents):
        if part.is_symlink():
            sys.exit('错误：管理路径不允许符号链接：' + str(part))
    paths = [p]
    if p.is_dir():
        paths += list(p.rglob('*'))
    for part in paths:
        if part.is_symlink() or (part.exists() and part.stat().st_uid != os.geteuid()):
            sys.exit('错误：路径所有权不匹配或包含符号链接：' + str(part))
        if os.geteuid() == 0 and part.exists() and part.stat().st_mode & 0o022:
            sys.exit('错误：系统模式路径不能由组或其他用户写入：' + str(part))
# 系统数据目录的直接父目录同样必须可信。
if os.geteuid() == 0:
    parent = pathlib.Path(sys.argv[1]).parent
    if parent.exists() and (parent.stat().st_uid != 0 or parent.stat().st_mode & 0o022):
        sys.exit('错误：系统数据父目录必须由 root 拥有且不可由其他用户写入。')
PY
}
lock() {
    mkdir -p "$BASE"
    chmod 700 "$BASE"
    if ! mkdir "$BASE/.lock" 2>/dev/null; then
        ui_error '存在操作锁，请确认持有进程已退出后再处理。' >&2
        ui_path '操作锁' "$BASE/.lock" >&2
        exit 1
    fi
    LOCKED=1
    printf '%s\n' "$$" > "$BASE/.lock/pid"
}
stage() {
    [[ -z "$WORK" ]] || rm -rf "$WORK"
    WORK="$(mktemp -d "$BASE/.stage.XXXXXX")"
    mkdir -p "$WORK/candidate/bin" "$WORK/candidate/run"
    [[ ! -d "$RUN" ]] || cp -R "$RUN/." "$WORK/candidate/run/"
}
need_install() { [[ -x "$BIN" && -f "$RUN/config.yaml" ]] || die '请先运行 install。'; }
https_url() {
    python_task '下载来源检查失败。' - "$1" <<'PY'
import sys, urllib.parse
u = sys.argv[1]
p = urllib.parse.urlsplit(u)
if p.scheme != 'https' or not p.hostname or p.username or p.password or any(c.isspace() or ord(c) < 32 for c in u):
    sys.exit('错误：下载来源必须是无内嵌用户名/密码的有效 HTTPS URL。')
PY
}
download() {
    local url="$1" output="$2"
    https_url "$url"
    # curl 的错误可能含订阅 token，因此不打印原始 stderr。
    if ! curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 300 --retry 2 --output "$output" "$url" 2>"$WORK/curl-error"; then
        die 'HTTPS 下载失败（网络、HTTP 状态或限流）；未替换现有文件。'
    fi
    [[ -s "$output" ]] || die '下载得到空文件。'
}
verify_hash() {
    local file="$1" expected="$2" actual
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die '缺少有效的 SHA-256；拒绝安装未经完整性校验的内核。'
    actual="$(shasum -a 256 "$file")"; actual="${actual%% *}"
    [[ "$actual" == "$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')" ]] || die 'SHA-256 不匹配，保留旧文件。'
}
download_proxy_task() {
    python_task '下载加速处理失败。' - "$BASE" "$@" <<'PY'
import hashlib, json, os, pathlib, shutil, stat, subprocess, sys, urllib.parse, zipfile, zlib
base, action = pathlib.Path(sys.argv[1]), sys.argv[2]
args = sys.argv[3:]
settings_path = base/'download-proxy.json'
defaults = dict(mirrors=['https://gh.mlang.cc/{url}', 'https://ghfast.top/{url}'], connect_timeout=10, timeout=60)

def normalize(value):
    if not isinstance(value, str) or not value or len(value) > 2048:
        raise ValueError('加速地址必须是非空 HTTPS 前缀或模板。')
    if '://' not in value:
        value = 'https://' + value
    if '{url}' not in value and '{path}' not in value:
        value = value.rstrip('/') + '/{url}'
    token = '{url}' if value.endswith('{url}') else '{path}' if value.endswith('{path}') else ''
    prefix = value[:-len(token)] if token else ''
    p = urllib.parse.urlsplit(prefix)
    if not token or '{' in prefix or '}' in prefix or not prefix.endswith('/') or p.scheme != 'https' or not p.hostname or p.username or p.password or p.query or p.fragment or any(c.isspace() or ord(c) < 32 for c in value):
        raise ValueError('加速模板必须为无认证/查询参数的 HTTPS 前缀，末尾使用 {url} 或 {path}。')
    # 同时验证端口，拒绝无效端口而非等到 curl 报错。
    p.port
    return value

def validate(data):
    if not isinstance(data, dict) or set(data) - set(defaults) or not isinstance(data.get('mirrors'), list) or len(data['mirrors']) > 10:
        raise ValueError('download-proxy.json 需要 mirrors 数组（最多 10 项）。')
    data = dict(defaults, **data)
    data['mirrors'] = [normalize(v) for v in data['mirrors']]
    if len(set(data['mirrors'])) != len(data['mirrors']):
        raise ValueError('加速列表含重复地址。')
    for key, low, high in [('connect_timeout', 1, 30), ('timeout', 10, 300)]:
        if type(data[key]) is not int or not low <= data[key] <= high:
            raise ValueError(key + ' 超出允许范围。')
    return data

def unpack_ui(archive, destination):
    with zipfile.ZipFile(archive) as z:
        entries = z.infolist()
        if not entries or len(entries) > 20000 or sum(e.file_size for e in entries) > 512 * 1024 * 1024:
            raise ValueError('UI 包文件数或展开大小异常。')
        names = set()
        for e in entries:
            p = pathlib.PurePosixPath(e.filename)
            mode = stat.S_IFMT(e.external_attr >> 16)
            if not e.filename or '\\' in e.filename or p.is_absolute() or '..' in p.parts or not p.parts or ':' in p.parts[0] or e.flag_bits & 1 or mode not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError('UI ZIP 包含不安全路径或特殊文件。')
            if p.as_posix() in names:
                raise ValueError('UI ZIP 包含重复路径。')
            names.add(p.as_posix())
        if z.testzip() is not None:
            raise ValueError('UI ZIP CRC 校验失败。')
        files = [e for e in entries if not e.is_dir()]
        roots = {pathlib.PurePosixPath(e.filename).parts[0] for e in entries}
        strip = next(iter(roots)) if len(roots) == 1 and all(len(pathlib.PurePosixPath(e.filename).parts) > 1 for e in files) else ''
        def relative(e):
            p = pathlib.PurePosixPath(e.filename)
            return pathlib.PurePosixPath(*p.parts[1:]) if strip else p
        index = next((e for e in files if relative(e).as_posix() == 'index.html'), None)
        if index is None or index.file_size == 0 or index.file_size > 4 * 1024 * 1024:
            raise ValueError('UI ZIP 缺少有效的 index.html。')
        html = z.read(index).lower()
        if b'<html' not in html and b'<!doctype html' not in html:
            raise ValueError('UI 入口不是 HTML 页面。')
        shutil.rmtree(destination, ignore_errors=True)
        destination.mkdir(parents=True)
        for e in files:
            target = destination.joinpath(*relative(e).parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            with z.open(e) as src, target.open('wb') as dst:
                shutil.copyfileobj(src, dst)
            target.chmod(0o600)

try:
    if action in ('set', 'reset', 'disable'):
        settings = validate(dict(defaults, mirrors=args if action == 'set' else [])) if action != 'reset' else defaults
        temp = settings_path.with_suffix('.json.new')
        temp.write_text(json.dumps(settings, indent=2) + '\n')
        temp.chmod(0o600)
        os.replace(temp, settings_path)
    else:
        settings = validate(json.loads(settings_path.read_text())) if settings_path.exists() else defaults
        if action == 'show':
            for i, value in enumerate(settings['mirrors'], 1):
                print(str(i) + '. ' + value)
            print(str(len(settings['mirrors']) + 1) + '. GitHub 官方源（最终回退）')
            print('连接超时：%s 秒；每源总超时：%s 秒。' % (settings['connect_timeout'], settings['timeout']))
        elif action == 'fetch':
            official, output, kind, digest, destination = args
            if not official.startswith('https://github.com/MetaCubeX/') or kind not in ('core', 'ui'):
                raise ValueError('加速下载仅允许指定官方资产。')
            if kind == 'ui' and official != 'https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip':
                raise ValueError('UI 包地址不符合官方地址。')
            candidates = [v.replace('{url}', official).replace('{path}', official[len('https://'):]) for v in settings['mirrors']] + [official]
            output = pathlib.Path(output)
            destination = pathlib.Path(destination)
            for i, url in enumerate(candidates, 1):
                label = urllib.parse.urlsplit(url).netloc
                print('尝试来源 %s/%s：%s' % (i, len(candidates), label), flush=True)
                if output.exists():
                    output.unlink()
                result = subprocess.run(['curl', '--fail', '--silent', '--show-error', '--location', '--proto', '=https', '--proto-redir', '=https',
                    '--connect-timeout', str(settings['connect_timeout']), '--max-time', str(settings['timeout']), '--max-filesize', str(512 * 1024 * 1024),
                    '--output', str(output), url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    if result.returncode or not output.exists() or not output.stat().st_size:
                        raise ValueError('网络/HTTP 错误或空文件')
                    if kind == 'core':
                        with output.open('rb') as f:
                            sha = hashlib.sha256()
                            for chunk in iter(lambda: f.read(1024 * 1024), b''):
                                sha.update(chunk)
                        if sha.hexdigest() != digest.lower():
                            raise ValueError('SHA-256 不匹配')
                        if subprocess.run(['gzip', '-t', str(output)], stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode:
                            raise ValueError('gzip 校验失败')
                    else:
                        unpack_ui(output, destination)
                    print('来源通过下载和包校验：' + label)
                    break
                except (ValueError, OSError, zipfile.BadZipFile, RuntimeError, EOFError, zlib.error) as error:
                    if output.exists():
                        output.unlink()
                    if kind == 'ui':
                        shutil.rmtree(destination, ignore_errors=True)
                    print('来源不可用，尝试下一来源：' + str(error))
            else:
                raise ValueError('所有加速来源和官方源均失败；旧文件保留。')
        else:
            raise ValueError('未知下载加速操作。')
except (ValueError, OSError, RuntimeError) as error:
    sys.exit(str(error))
PY
}
cmd_download_proxy() {
    local action="$1"; shift
    download_proxy_task "$action" "$@"
    [[ "$action" == show ]] || ui_success '下载加速设置已更新。'
    info_path '下载加速设置' "$BASE/download-proxy.json"
}
default_config() {
    cat > "$1" <<'YAML'
# 初始验证配置：只提供直连，不包含代理节点。
mixed-port: 7890
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: info
ipv6: true
geodata-mode: false
geo-auto-update: false
rules:
  - MATCH,DIRECT
YAML
}
default_resources() {
    cat > "$BASE/resources.json" <<'JSON'
{
  "geoip.dat": {"url": "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"},
  "geosite.dat": {"url": "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"},
  "Country.mmdb": {"url": "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb"},
  "ASN.mmdb": {"url": "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb"}
}
JSON
}
write_plist() {
    mkdir -p "$BASE/logs"
    python_task '生成服务配置失败。' - "$BASE" "$LABEL" <<'PY'
import pathlib, plistlib, sys
base, label = pathlib.Path(sys.argv[1]), sys.argv[2]
data = dict(Label=label, ProgramArguments=[str(base/'bin/mihomo'), '-d', str(base/'run'), '-f', str(base/'run/config.yaml')],
    WorkingDirectory=str(base/'run'), RunAtLoad=True, KeepAlive=True, ThrottleInterval=10,
    StandardOutPath=str(base/'logs/stdout.log'), StandardErrorPath=str(base/'logs/stderr.log'), Umask=0o077)
with (base/'service.plist.new').open('wb') as f:
    plistlib.dump(data, f)
PY
    run_checked '服务 plist 校验失败。' plutil -lint "$BASE/service.plist.new" >/dev/null
    mv -f "$BASE/service.plist.new" "$BASE/service.plist"
}
validate_candidate() {
    local binary="$1"
    ui_step '校验候选配置…'
    if ! "$binary" -t -d "$WORK/candidate/run" -f "$WORK/candidate/run/config.yaml" >"$WORK/config-test.log" 2>&1; then
        mkdir -p "$BASE/logs"
        cp "$WORK/config-test.log" "$BASE/logs/last-test.log"
        ui_error '配置测试失败；旧文件保留。' >&2
        ui_path '校验诊断日志' "$BASE/logs/last-test.log" >&2
        ui_command 'mm logs 100' >&2
        exit 1
    fi
    ui_detail '配置校验通过。'
}
commit_files() {
    local rel
    ui_step '应用更新…'
    TX_TARGETS=("$@")
    mkdir -p "$WORK/rollback" "$BASE/backups"
    TX_LOADED=0
    if loaded; then TX_LOADED=1; fi
    for rel in "${TX_TARGETS[@]}"; do
        mkdir -p "$WORK/rollback/$(dirname "$rel")" "$BASE/$(dirname "$rel")"
        [[ ! -e "$BASE/$rel" ]] || cp -pR "$BASE/$rel" "$WORK/rollback/$rel"
    done
    TX_ACTIVE=1
    stop_job
    for rel in "${TX_TARGETS[@]}"; do
        if [[ -d "$BASE/$rel" ]]; then rm -rf "${BASE:?}/$rel"; fi
        if [[ -e "$WORK/candidate/$rel" ]]; then
            mv -f "$WORK/candidate/$rel" "$BASE/$rel"
        else
            rm -rf "${BASE:?}/$rel"
        fi
    done
    if [[ "$TX_LOADED" -eq 1 ]]; then
        ui_step '恢复服务运行状态…'
        boot_job
    fi
    # 单份备份按最近一次更新保存；不存在的旧文件由清单表示。
    printf '%s\n' "${TX_TARGETS[@]}" > "$WORK/rollback/targets.txt"
    rm -rf "$BASE/backups/previous"
    mv "$WORK/rollback" "$BASE/backups/previous"
    TX_ACTIVE=0
}
fetch_core() {
    local version="${1:-latest}" arch api
    if [[ "$version" != latest ]]; then
        [[ "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '版本格式必须为 vX.Y.Z 或 X.Y.Z。'
        [[ "$version" == v* ]] || version="v$version"
    fi
    arch="$(uname -m)"
    if [[ "$arch" == arm64 ]] || [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]]; then
        arch=arm64
    elif [[ "$arch" == x86_64 ]]; then arch=amd64-v1
    else die "不支持的 CPU 架构：$arch"; fi
    api='https://api.github.com/repos/MetaCubeX/mihomo/releases'
    if [[ "$version" == latest ]]; then api="$api/latest"; else api="$api/tags/$version"; fi
    ui_step '查询官方发布信息…'
    download "$api" "$WORK/release.json"
    python_task '发布信息检查失败。' - "$WORK/release.json" "$arch" "$WORK/asset" <<'PY'
import json, pathlib, re, sys
d = json.load(open(sys.argv[1]))
v = d.get('tag_name', '')
if not re.fullmatch(r'v\d+\.\d+\.\d+', v) or d.get('prerelease') or d.get('draft'):
    sys.exit('错误：仅支持官方稳定发布版。')
name = 'mihomo-darwin-' + sys.argv[2] + '-' + v + '.gz'
a = next((a for a in d.get('assets', []) if a.get('name') == name), None)
if not a or not re.fullmatch(r'sha256:[0-9a-fA-F]{64}', a.get('digest') or ''):
    sys.exit('错误：发布版缺少对应架构资产或 SHA-256 digest。')
url = a.get('browser_download_url', '')
if url != 'https://github.com/MetaCubeX/mihomo/releases/download/' + v + '/' + name:
    sys.exit('错误：发布资产 URL 不符合官方地址。')
pathlib.Path(sys.argv[3]).write_text(url + '\n' + a['digest'][7:] + '\n' + v + '\n')
PY
    local url digest resolved
    { IFS= read -r url; IFS= read -r digest; IFS= read -r resolved; } < "$WORK/asset"
    ui_line '候选版本' "$resolved"
    ui_line 'CPU 架构' "$arch"
    ui_step '下载官方内核…'
    download_proxy_task fetch "$url" "$WORK/core.gz" core "$digest" "$WORK/unused"
    ui_step '校验 SHA-256 并解压内核…'
    verify_hash "$WORK/core.gz" "$digest"
    run_checked '内核解压失败。' gzip -t "$WORK/core.gz"
    gzip -dc "$WORK/core.gz" > "$WORK/candidate/bin/mihomo"
    chmod 755 "$WORK/candidate/bin/mihomo"
    "$WORK/candidate/bin/mihomo" -v > "$WORK/version.log" 2>&1 || die '候选内核无法在此 macOS/CPU 上执行。'
}
cmd_install() {
    stage
    fetch_core "${1:-latest}"
    local files=(bin/mihomo)
    if [[ ! -f "$WORK/candidate/run/config.yaml" ]]; then
        default_config "$WORK/candidate/run/config.yaml"
        files+=(run/config.yaml)
    fi
    validate_candidate "$WORK/candidate/bin/mihomo"
    write_plist
    [[ -f "$BASE/resources.json" ]] || default_resources
    commit_files "${files[@]}"
    ui_success '内核已安装。'
    ui_path '内核程序' "$BIN"
    ui_note '首次生成的配置仅直连；导入自己的配置后启动。'
    ui_command 'mm config set ./config.yaml'
    ui_command 'mm start'
    if ! manage_shortcut install; then
        ui_warning '内核安装成功，mm 快捷命令未配置；解决上述冲突后运行 shortcut。' >&2
    fi
}
cmd_update_core() {
    need_install; stage; fetch_core "${1:-latest}"
    validate_candidate "$WORK/candidate/bin/mihomo"
    write_plist
    commit_files bin/mihomo
    ui_success '内核已更新，原服务状态已恢复。'
}
cmd_start() {
    need_install; stage; validate_candidate "$BIN"; write_plist
    if loaded; then
        if ! running; then run_checked '重新启动服务失败。' launchctl kickstart -k "$DOMAIN/$LABEL"; fi
        wait_running
    else boot_job; fi
    ui_success 'mihomo 正在运行。'
}
cmd_test() { need_install; stage; validate_candidate "$BIN"; ui_success '配置测试通过。'; }
status_fields() {
    local mode=用户 version first version_rc
    [[ "$SYSTEM" -eq 0 ]] || mode=系统
    ui_line '模式' "$mode"
    if [[ -x "$BIN" ]]; then
        if version="$("$BIN" -v 2>&1)"; then
            :
        else
            version_rc=$?
            ui_error '读取内核版本失败。' >&2
            [[ -z "$version" ]] || ui_detail "$version" >&2
            return "$version_rc"
        fi
        first="${version%%$'\n'*}"
        ui_line '内核' "$first"
        [[ "$first" == "$version" ]] || ui_detail "${version#*$'\n'}"
    else
        ui_line '内核' '未安装' '90'
    fi
    if running; then ui_line '服务' '运行中' '32';
    elif loaded; then ui_line '服务' '已加载，当前未运行' '33';
    else ui_line '服务' '未加载/已停止' '90'; fi
    autostart_status
}
cmd_status() {
    ui_title '运行状态'
    status_fields
    info_path '数据根目录' "$BASE"
}
info_path() {
    local label="$1" path="$2" state=未创建 code=90
    if [[ -e "$path" ]]; then state=已存在; code=32; fi
    ui_line "$label" ''
    printf '    %s ' "$path"; ui_color "$code" "[$state]"; printf '\n'
}
cmd_info() {
    ui_title '运行信息'
    ui_section '状态概要'
    status_fields
    ui_line 'launchd 服务' "$DOMAIN/$LABEL"
    ui_section '运行目录与配置'
    info_path '数据根目录' "$BASE"
    info_path '运行目录（内核 -d）' "$RUN"
    info_path '配置文件（内核 -f）' "$RUN/config.yaml"
    info_path '资源清单' "$BASE/resources.json"
    info_path '订阅来源记录（不显示内容）' "$BASE/config-url"
    info_path 'UI 自动补充记录' "$BASE/ui-enabled"
    info_path '下载加速设置' "$BASE/download-proxy.json"
    ui_section '程序与快捷入口'
    info_path '内核程序' "$BIN"
    info_path '当前管理脚本' "$SCRIPT"
    if [[ "$SYSTEM" -eq 0 ]]; then
        info_path 'mm 快捷命令' "$HOME/.local/bin/mm"
        info_path 'shell 配置记录' "$BASE/shortcut.json"
    fi
    ui_section '日志与恢复'
    info_path '日志目录' "$BASE/logs"
    info_path '标准输出日志' "$BASE/logs/stdout.log"
    info_path '标准错误日志' "$BASE/logs/stderr.log"
    info_path '最近配置测试错误' "$BASE/logs/last-test.log"
    info_path '最近更新备份' "$BASE/backups/previous"
    ui_section '服务文件与操作锁'
    info_path '运行服务 plist' "$BASE/service.plist"
    info_path '自启 plist' "$PERSIST"
    info_path '操作锁' "$BASE/.lock"
}
autostart_status() {
    local kind=登录
    [[ "$SYSTEM" -eq 0 ]] || kind=开机
    if [[ -f "$PERSIST" ]]; then ui_line "${kind}自启" '已启用' '32'; else ui_line "${kind}自启" '未启用' '90'; fi
}
patch_ui_config() {
    ui_step '补充 Web 面板配置…'
    python_task 'UI 配置补充失败；旧配置保留。' - "$WORK/candidate/run/config.yaml" "$RUN" "$WORK/ui-relative" <<'PY'
import json, pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_bytes().decode('utf-8')
bom = '\ufeff' if text.startswith('\ufeff') else ''
lines = text[len(bom):].splitlines(keepends=True)
newline = '\r\n' if '\r\n' in text else '\n'
defaults = {
    'external-ui': 'ui',
    'external-controller': '127.0.0.1:9090',
    'external-ui-url': '"https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"',
}
key_pattern = re.compile(r'''^(?P<key>[a-zA-Z0-9_<][a-zA-Z0-9_ .<>/-]*|'[^']*'|"[^"\\]*")(?P<sep>\s*:\s*)(?P<value>.*)$''')

def fail(reason):
    sys.exit(reason + ' 请使用单文档、顶层不缩进的块映射 YAML，再运行 config ui。')

def scalar(line):
    # 识别引号及行尾注释；多行引号拒绝，避免将字符串内容误作顶层键。
    quote = None
    flow = []
    i = 0
    while i < len(line):
        c = line[i]
        if quote == '"' and c == '\\':
            i += 2
            continue
        if quote:
            if c == quote:
                if quote == "'" and i + 1 < len(line) and line[i + 1] == "'":
                    i += 2
                    continue
                quote = None
        elif c == '#' and (i == 0 or line[i - 1].isspace()):
            if flow:
                fail('不支持跨行流式集合。')
            return line[:i].rstrip(), line[i:]
        elif c in "\"'" and (i == 0 or line[i - 1].isspace() or line[i - 1] in '[{,:'):
            quote = c
        elif c in '[{':
            flow.append(c)
        elif c in ']}' and flow:
            flow.pop()
        i += 1
    if quote:
        fail('不支持多行引号字符串。')
    if flow:
        fail('不支持跨行流式集合。')
    return line.rstrip(), ''

roots = []
seen = {}
started = ended = False
end_index = len(lines)
block_indent = None
for i, line in enumerate(lines):
    raw = line.rstrip('\r\n')
    stripped = raw.lstrip(' ')
    indent = len(raw) - len(stripped)
    if not stripped or stripped.startswith('#'):
        continue
    if block_indent is not None:
        if indent > block_indent:
            continue
        block_indent = None
    content, _ = scalar(raw)
    if indent == 0:
        if content == '---' and not started and not ended:
            started = True
            continue
        if content == '...' and not ended:
            ended = True
            end_index = i
            continue
        if content.startswith('%') and not started:
            continue
        if ended:
            fail('不支持多个 YAML 文档。')
        match = key_pattern.fullmatch(content)
        if not match:
            # 块映射字段可使用无缩进列表，例如 rules:\n- MATCH,DIRECT。
            if content.startswith('- ') and roots and roots[-1][1] not in defaults:
                continue
            fail('无法识别顶层 YAML 结构。')
        started = True
        key = match['key'].strip("\"'").rstrip()
        roots.append((i, key))
        if key in defaults:
            if key in seen:
                fail('UI 相关顶层键重复：' + key + '。')
            seen[key] = i
    if re.search(r'(?:^|:\s*|\s)[|>][1-9+-]*\s*$', content):
        block_indent = indent
if not roots:
    fail('配置必须包含顶层映射。')

for n, (i, key) in enumerate(roots):
    if key not in defaults:
        continue
    stop = roots[n + 1][0] if n + 1 < len(roots) else end_index
    if any(part.strip() and not part.lstrip().startswith('#') for part in lines[i + 1:stop]):
        fail('UI 字段必须使用单行标量：' + key + '。')
    raw = lines[i].rstrip('\r\n')
    match = key_pattern.fullmatch(raw)
    value, comment = scalar(match['value'])
    if value.startswith(('&', '*', '!', '|', '>', '[', '{')):
        fail('不支持 UI 字段的复杂值：' + key + '。')
    empty = value.lower() in ('', "''", '""', 'null', '~')
    if key == 'external-ui-url' or empty:
        lines[i] = match['key'] + ': ' + defaults[key] + (' ' + comment if comment else '') + newline
missing = [key + ': ' + value + newline for key, value in defaults.items() if key not in seen]
if missing:
    if end_index and not lines[end_index - 1].endswith(('\n', '\r')):
        lines[end_index - 1] += newline
    lines[end_index:end_index] = missing
path.write_bytes((bom + ''.join(lines)).encode('utf-8'))

def string_value(key, default=''):
    # 仅提取 UI 的单行字符串，不解析或重写节点/规则。
    for line in lines:
        match = key_pattern.fullmatch(line.rstrip('\r\n'))
        if match and match['key'].strip("\"'").rstrip() == key:
            value, _ = scalar(match['value'])
            if value.startswith('"'):
                return json.loads(value)
            if value.startswith("'") and value.endswith("'"):
                return value[1:-1].replace("''", "'")
            if value.startswith(('&', '*', '!', '|', '>', '[', '{')):
                fail('UI 路径不支持复杂值。')
            return value if value.lower() not in ('null', '~') else default
    return default

run = pathlib.Path(sys.argv[2]).resolve()
directory = string_value('external-ui', 'ui')
name = string_value('external-ui-name')
if not isinstance(directory, str) or not isinstance(name, str) or (name and (name in ('.', '..') or '/' in name or '\\' in name)):
    fail('UI 目录或 external-ui-name 无效。')
target = pathlib.Path(directory)
if '..' in target.parts:
    fail('UI 目录不能包含路径穿越。')
target = ((target if target.is_absolute() else run/target)/name).resolve()
try:
    relative = target.relative_to(run)
except ValueError:
    fail('自动加载 UI 仅支持运行目录内的子目录。')
if not relative.parts or relative.parts[0] in ('config.yaml', 'geoip.dat', 'geosite.dat', 'Country.mmdb', 'ASN.mmdb'):
    fail('UI 目录不能覆盖运行目录本身或核心配置/资源。')
pathlib.Path(sys.argv[3]).write_text('run/' + relative.as_posix() + '\n')
PY
}
UI_REL='' UI_CHANGED=0
prepare_ui() {
    local force="${1:-0}"
    UI_CHANGED=0
    IFS= read -r UI_REL < "$WORK/ui-relative"
    if [[ "$force" -eq 0 && -s "$WORK/candidate/$UI_REL/index.html" ]]; then
        ui_note '已有 UI 入口，保留面板缓存；需要更新时执行 mm update-ui。'
        return
    fi
    ui_step '下载并加载 metacubexd 面板包…'
    download_proxy_task fetch 'https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip' \
        "$WORK/ui.zip" ui '' "$WORK/candidate/$UI_REL"
    UI_CHANGED=1
}
cmd_config_ui() {
    local force="${1:-0}" files=(run/config.yaml ui-enabled)
    patch_ui_config
    prepare_ui "$force"
    [[ "$UI_CHANGED" -eq 0 ]] || files+=("$UI_REL")
    printf 'metacubexd\n' > "$WORK/candidate/ui-enabled"
    chmod 600 "$WORK/candidate/run/config.yaml" "$WORK/candidate/ui-enabled"
    validate_candidate "$BIN"
    write_plist
    commit_files "${files[@]}"
    ui_success 'Web 面板配置已启用；后续导入与订阅更新会自动补齐。'
    info_path '生效配置' "$RUN/config.yaml"
    info_path '旧配置备份' "$BASE/backups/previous/run/config.yaml"
    ui_note '缺省面板地址：http://127.0.0.1:9090/ui/；已有 API 地址则使用原地址的 /ui/。'
    info_path '面板静态目录' "$BASE/$UI_REL"
    ui_note '面板资源已就绪；更新资源可执行 mm update-ui。'
    ui_command 'mm start'
}
cmd_config() {
    local action="$1" source="${2:-}" files=(run/config.yaml config-url)
    need_install; stage
    case "$action" in
        ui) cmd_config_ui; return ;;
        set) [[ -n "$source" ]] || die 'config set 需要文件路径或 HTTPS URL。' ;;
        update) [[ -s "$BASE/config-url" ]] || die '未保存远程配置来源；先使用 config set <HTTPS URL>。'
            source="$(cat "$BASE/config-url")" ;;
        *) die 'config 子命令必须为 set、update 或 ui。' ;;
    esac
    if [[ "$source" == https://* ]]; then
        ui_step '下载远程配置…'
        download "$source" "$WORK/candidate/run/config.yaml"
        printf '%s\n' "$source" > "$WORK/candidate/config-url"
    else
        ui_step '读取本地配置…'
        [[ "$action" == set && -f "$source" ]] || die '需要存在的本地文件或 HTTPS URL。'
        cp "$source" "$WORK/candidate/run/config.yaml"
    fi
    chmod 600 "$WORK/candidate/run/config.yaml"
    if [[ -f "$BASE/ui-enabled" ]]; then
        patch_ui_config
        prepare_ui
        [[ "$UI_CHANGED" -eq 0 ]] || files+=("$UI_REL")
    fi
    validate_candidate "$BIN"
    write_plist
    commit_files "${files[@]}"
    ui_success '配置已更新。'
    info_path '生效配置' "$RUN/config.yaml"
    info_path '旧配置备份' "$BASE/backups/previous/run/config.yaml"
}
cmd_resources() {
    need_install; stage
    [[ -f "$BASE/resources.json" ]] || die '缺少 resources.json；重新运行 install 生成默认清单。'
    python_task '资源清单检查失败。' - "$BASE/resources.json" "$WORK/resources" "$@" <<'PY'
import json, pathlib, re, sys, urllib.parse
allowed = {'geoip.dat', 'geosite.dat', 'Country.mmdb', 'ASN.mmdb'}
d = json.load(open(sys.argv[1]))
if not isinstance(d, dict) or not d or not set(d) <= allowed:
    sys.exit('错误：资源清单只允许 geoip.dat/geosite.dat/Country.mmdb/ASN.mmdb。')
names = sys.argv[3:] or list(d)
if len(set(names)) != len(names) or any(n not in d for n in names):
    sys.exit('错误：资源名重复或不在清单中。')
lines = []
for name in names:
    entry = d[name]
    if not isinstance(entry, dict) or set(entry) - {'url', 'sha256'}:
        sys.exit('错误：资源条目只允许 url 和 sha256。')
    url, digest = entry.get('url', ''), entry.get('sha256', '-')
    if not isinstance(url, str) or not isinstance(digest, str):
        sys.exit('错误：资源 URL 和 SHA-256 必须为字符串。')
    p = urllib.parse.urlsplit(url)
    if p.scheme != 'https' or not p.hostname or p.username or p.password or any(c.isspace() or ord(c) < 32 for c in url):
        sys.exit('错误：资源必须使用有效 HTTPS URL。')
    if digest != '-' and not re.fullmatch(r'[0-9a-fA-F]{64}', digest):
        sys.exit('错误：资源 SHA-256 格式错误。')
    lines.append('\t'.join((name, url, digest)))
pathlib.Path(sys.argv[2]).write_text('\n'.join(lines) + '\n')
PY
    local name url digest files=() total index=0
    total="$(wc -l < "$WORK/resources")"
    while IFS=$'\t' read -r name url digest; do
        index=$((index + 1))
        ui_step "资源 ${index}/$((total))：下载 ${name}…"
        download "$url" "$WORK/candidate/run/$name"
        python_task '资源内容检查失败。' - "$WORK/candidate/run/$name" <<'PY'
import sys
with open(sys.argv[1], 'rb') as f:
    head = f.read(1024).lstrip().lower()
if head.startswith((b'<', b'{', b'[')):
    sys.exit('错误：资源内容像 HTML/XML/JSON 错误页，拒绝替换。')
PY
        [[ "$digest" == - ]] || verify_hash "$WORK/candidate/run/$name" "$digest"
        ui_detail "${name} 下载检查通过。"
        files+=("run/$name")
    done < "$WORK/resources"
    validate_candidate "$BIN"
    write_plist
    commit_files "${files[@]}"
    ui_success "资源已更新，共 ${index} 个文件。"
    ui_note '未被配置引用的资源仅完成下载/可选哈希检查。'
    info_path '资源保存目录' "$RUN"
}
cmd_autostart() {
    case "$1" in
        enable)
            need_install; stage; validate_candidate "$BIN"; write_plist
            mkdir -p "$(dirname "$PERSIST")"
            cp "$BASE/service.plist" "$PERSIST.new"
            chmod 644 "$PERSIST.new"
            mv -f "$PERSIST.new" "$PERSIST"
            stop_job
            boot_job
            autostart_status ;;
        disable)
            stop_job
            rm -f "$PERSIST"
            ui_success '自启已禁用，服务已停止。' ;;
        status) autostart_status ;;
        *) die 'autostart 子命令必须为 enable/disable/status。' ;;
    esac
}
cmd_logs() {
    local count="${1:-80}" file found=0 content
    [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 && "$count" -le 10000 ]] || die '日志行数必须为 1–10000。'
    ui_line '读取范围' "每个文件末尾 ${count} 行"
    for file in stdout.log stderr.log last-test.log; do
        if [[ -f "$BASE/logs/$file" ]]; then
            found=1
            ui_section "$file"
            ui_path '文件位置' "$BASE/logs/$file"
            if [[ -s "$BASE/logs/$file" ]]; then
                content="$(tail -n "$count" "$BASE/logs/$file")"
                ui_detail "$content"
            else ui_note '日志为空。'; fi
        fi
    done
    [[ "$found" -eq 1 ]] || ui_note '暂无日志；启动服务后可查看运行记录。'
}
cmd_uninstall() {
    local purge=0 yes=0 arg answer
    for arg in "$@"; do
        case "$arg" in --purge) purge=1 ;; --yes) yes=1 ;; *) die "未知卸载选项：$arg" ;; esac
    done
    if [[ "$yes" -eq 0 ]]; then
        [[ -t 0 ]] || die '非交互卸载必须显式指定 --yes。'
        if [[ "$purge" -eq 1 ]]; then
            ui_warning '完全卸载将删除本工具的配置、资源和日志。'
        else ui_note '卸载内核与快捷入口，保留配置、资源和日志。'; fi
        ui_prompt '输入 yes 确认，其他输入取消：'
        IFS= read -r answer
        [[ "$answer" == yes ]] || die '已取消卸载。'
    fi
    stop_job
    rm -f "$PERSIST"
    manage_shortcut remove
    if [[ "$purge" -eq 1 ]]; then
        # BASE 仅来自上述两个固定路径；绝不接受自定义递归删除路径。
        rm -rf "$BASE"
        LOCKED=0
    else
        rm -rf "${BASE:?}/bin" "${BASE:?}/backups/previous/bin"
        rm -f "$BASE/service.plist"
    fi
    ui_success '卸载完成；原始管理脚本保留，可用于重新安装。'
    if [[ "$purge" -eq 0 ]]; then info_path '保留的数据目录' "$BASE"; fi
}
render_menu() {
    local state=已停止 autostart=未启用
    if running; then state=运行中; elif loaded; then state=等待或异常; fi
    [[ ! -f "$PERSIST" ]] || autostart=已启用
    python3 - "$SYSTEM" "$state" "$autostart" <<'PY'
import os, sys, unicodedata
system, state, autostart = sys.argv[1:]
tty = sys.stdout.isatty()
color = tty and os.environ.get('TERM', '') not in ('', 'dumb') and 'NO_COLOR' not in os.environ
palette = {'title': '1;34', 'section': '1', 'number': '1;34', 'good': '32', 'warning': '33', 'danger': '31', 'muted': '90'}

def paint(text, style):
    return '\033[' + palette[style] + 'm' + text + '\033[0m' if color else text

def cells(text):
    return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in text)

try:
    width = os.get_terminal_size(1).columns if tty else 80
except OSError:
    width = 80
try:
    width = int(os.environ.get('COLUMNS', '') or width) or 80
except ValueError:
    pass
wide = width >= 68
column = 30

def row(item):
    key, label, style = item
    number = '[' + str(key).rjust(2) + ']'
    plain = number + ' ' + label
    text = paint(label, style) if style in ('danger', 'warning') else label
    return paint(number, style) + ' ' + text, cells(plain)

def panel(left, right):
    if wide:
        print('  ' + paint(left[0], 'section') + ' ' * (column - cells(left[0])) + '   ' + paint(right[0], 'section'))
        for i in range(max(len(left[1]), len(right[1]))):
            a, n = row(left[1][i]) if i < len(left[1]) else ('', 0)
            b, _ = row(right[1][i]) if i < len(right[1]) else ('', 0)
            print('  ' + a + ' ' * (column - n) + '   ' + b)
    else:
        for title, items in (left, right):
            print('  ' + paint(title, 'section'))
            for item in items:
                print('  ' + row(item)[0])
            print()

service = ('服务管理', [(1, '安装内核', 'number'), (2, '启动服务', 'good'), (3, '停止服务', 'warning'), (4, '重启服务', 'number'), (5, '查看状态', 'number')])
config = ('配置与更新', [(6, '更新内核', 'number'), (7, '导入配置', 'number'), (8, '更新订阅', 'number'), (9, '更新 GEO 资源', 'number'), (12, '测试配置', 'number'), (17, '配置 Web 面板', 'number'), (18, '更新 UI 包', 'number'), (19, '下载加速设置', 'number')])
diagnostics = ('自启与诊断', [(10, '启用自启', 'good'), (11, '禁用自启', 'warning'), (13, '查看日志', 'number'), (16, '运行信息 / 目录', 'number')])
remove = ('卸载与帮助', [(14, '卸载（保留数据）', 'warning'), (15, '完全卸载', 'danger'), ('h', '用法帮助', 'number'), (0, '退出', 'muted')])
kind = '系统模式' if system == '1' else '用户模式'
startup = '开机自启' if system == '1' else '登录自启'
print('\n  ' + paint('mihomo · macOS 管理器', 'title'))
status = '服务：' + paint(state, 'good' if state == '运行中' else 'muted')
if wide:
    print('  ' + kind + '  |  ' + status + '  |  ' + startup + '：' + autostart)
else:
    print('  ' + kind + '  |  ' + status)
    print('  ' + startup + '：' + autostart)
print('  ' + paint('─' * (63 if wide else min(32, max(0, width - 2))), 'muted') + '\n')
panel(service, config)
print()
panel(diagnostics, remove)
hint = '输入编号选择操作；h 查看帮助，0 退出。' if wide else '输入编号；h 帮助，0 退出。'
print('\n  ' + paint(hint, 'muted'))
print('  ' + paint('请选择：', 'title'), end='', flush=True)
PY
}
menu() {
    local choice source version proxy_action links flags=() proxies=()
    [[ "$SYSTEM" -eq 0 ]] || flags=(--system)
    while true; do
        render_menu
        IFS= read -r choice || return 0
        case "$choice" in
            0) return 0 ;;
            1|6) ui_prompt '版本（留空=最新稳定版）：'; IFS= read -r version || return 0
                if [[ "$choice" == 1 ]]; then choice=install; else choice=update-core; fi
                /bin/bash "$SCRIPT" ${flags[@]+"${flags[@]}"} "$choice" "${version:-latest}" || true ;;
            7) ui_prompt '本地配置路径或 HTTPS URL：'; IFS= read -r source || return 0
                /bin/bash "$SCRIPT" ${flags[@]+"${flags[@]}"} config set "$source" || true ;;
            19) /bin/bash "$SCRIPT" ${flags[@]+"${flags[@]}"} download-proxy show || true
                ui_prompt '操作（set 设置 / reset 默认 / disable 禁用 / 回车返回）：'; IFS= read -r proxy_action || return 0
                case "$proxy_action" in
                    '') continue ;;
                    set) ui_prompt '加速前缀或模板，空格分隔（优先项在前）：'; IFS= read -r links || return 0
                        IFS=' ' read -r -a proxies <<< "$links"
                        /bin/bash "$SCRIPT" ${flags[@]+"${flags[@]}"} download-proxy set ${proxies[@]+"${proxies[@]}"} || true ;;
                    reset|disable) /bin/bash "$SCRIPT" ${flags[@]+"${flags[@]}"} download-proxy "$proxy_action" || true ;;
                    *) ui_warning '无效的下载加速操作。' ;;
                esac ;;
            *) case "$choice" in
                2) set -- start ;; 3) set -- stop ;; 4) set -- restart ;; 5) set -- status ;;
                8) set -- config update ;; 9) set -- update-resources ;;
                10) set -- autostart enable ;; 11) set -- autostart disable ;;
                12) set -- test ;; 13) set -- logs ;; 14) set -- uninstall ;;
                15) set -- uninstall --purge ;; 16) set -- info ;; h|help|\?) set -- help ;;
                17) set -- config ui ;;
                18) set -- update-ui ;;
                *) ui_warning '无效选择，请输入菜单编号或 h。'; continue ;;
                esac
                /bin/bash "$SCRIPT" ${flags[@]+"${flags[@]}"} "$@" || true ;;
        esac
    done
}
main() {
    if [[ "${1:-}" == --system ]]; then SYSTEM=1; shift; fi
    local cmd="${1:-}"
    [[ "$#" -eq 0 ]] || shift
    case "$cmd" in help|-h|--help) [[ "$#" -eq 0 ]] || die 'help 不接受参数。'; usage; return ;; esac
    if [[ -z "$cmd" && ! -t 0 ]]; then usage; return; fi
    # 参数检查先于 mkdir/锁，避免拼写错误造成写操作。
    case "$cmd" in
        install|update-core|logs) [[ "$#" -le 1 ]] || die "$cmd 参数过多。" ;;
        start|stop|restart|status|info|test|shortcut|update-ui|'') [[ "$#" -eq 0 ]] || die "$cmd 不接受参数。" ;;
        download-proxy) [[ ( "$#" -ge 2 && "$1" == set ) || ( "$#" -eq 1 && ( "$1" == show || "$1" == reset || "$1" == disable ) ) ]] || die '用法：download-proxy show|reset|disable，或 download-proxy set <链接1> [链接2...]。' ;;
        config) [[ ( "$#" -eq 2 && "$1" == set ) || ( "$#" -eq 1 && ( "$1" == update || "$1" == ui ) ) ]] || die '用法：config set <文件/HTTPS URL>、config update 或 config ui。' ;;
        autostart) [[ "$#" -eq 1 ]] || die '用法：autostart enable|disable|status。' ;;
        update-resources|uninstall) ;;
        *) die "未知命令：${cmd}；使用 help 查看用法。" ;;
    esac
    check_environment
    if [[ -z "$cmd" ]]; then menu; return; fi
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    case "$cmd" in status|info|logs) ;; download-proxy) [[ "$1" == show ]] || lock ;; autostart) [[ "$1" == status ]] || lock ;; *) lock ;; esac
    case "$cmd" in
        install) ui_title '安装内核'; cmd_install "$@" ;;
        update-core) ui_title '更新内核'; cmd_update_core "$@" ;;
        update-ui) ui_title '更新 Web 面板'; need_install; stage; cmd_config_ui 1 ;;
        download-proxy) ui_title '下载加速设置'; cmd_download_proxy "$@" ;;
        start) ui_title '启动服务'; cmd_start ;;
        stop) ui_title '停止服务'; stop_job; ui_success '服务已停止。' ;;
        restart) ui_title '重启服务'; need_install; stop_job; cmd_start ;;
        status) cmd_status ;; test) ui_title '配置测试'; cmd_test ;;
        info) cmd_info ;;
        logs) ui_title '运行日志'; cmd_logs "$@" ;;
        config) ui_title '配置管理'; cmd_config "$@" ;;
        update-resources) ui_title '更新 GEO 资源'; cmd_resources "$@" ;;
        shortcut) ui_title '设置快捷命令'; manage_shortcut install ;;
        autostart) ui_title '自启管理'; cmd_autostart "$@" ;;
        uninstall) ui_title '卸载管理'; cmd_uninstall "$@" ;;
    esac
}
main "$@"
