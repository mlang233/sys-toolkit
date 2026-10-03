# macOS mihomo 管理器：施工与运行文档

通过 SDD 先确定需求和验收，再实现 macOS 独立脚本，交付原生 launchd 服务管理、可恢复更新和中文操作入口。

## 目录

- [1. 交付范围与施工基线](#1-交付范围与施工基线)
- [2. 环境与快速使用](#2-环境与快速使用)
- [3. 配置与资源更新](#3-配置与资源更新)
- [4. 服务和自启](#4-服务和自启)
- [5. 更新机制与恢复](#5-更新机制与恢复)
- [6. 卸载与数据所有权](#6-卸载与数据所有权)
- [7. 施工与验收记录](#7-施工与验收记录)
- [8. 排障与人工验收](#8-排障与人工验收)
- [9. 参考](#9-参考)

## 1. 交付范围与施工基线

**SDD（Specification-Driven Development）** 将需求规格作为实现和验收的共同依据。先提交 [spec.md](spec.md) 的 R01–R11，再用 [design.md](design.md) 定义目录、权限、状态及更新事务，用 [tasks.md](tasks.md) 跟踪施工任务。发生实现取舍时同步修正设计，不用代码行为倒推未记录的需求。

| 交付物 | 用途 |
|---|---|
| [mihomo-manager.sh](../.mm) | 单脚本分发，交互菜单与可自动化子命令 |
| [规格](spec.md)、[设计](design.md)、[任务](tasks.md) | 需求、设计决策和验收追踪 |
| [集成测试](../../tests/test_mihomo_manager.py) | 无真实网络/服务副作用的故障注入回归 |
| [真实 smoke 测试](../../tests/smoke_mihomo_macos.py) | 下载、代理请求、GEO 加载和 launchd 操作实测 |
| 本文及 [仓库首页](../../README.md) | 安装使用、施工记录、回滚和排障 |

施工分支：`feat/macos-mihomo-sdd`，起点：`0ab23a8`，规格基线：`b8e2b0c`，实现与测试提交：`6b3902a`。本次只创建本地提交，不推送远端。施工中发现 `.gitignore` 被外部加入 `docs/` 和 `tests/` 忽略规则，保留该修改；提交时显式添加本功能文件，不提交整个忽略目录。

## 2. 环境与快速使用

要求 macOS 12+、Apple Silicon 或 Intel、Bash 3.2+、Python 3。`curl`、`gzip`、`shasum`、`launchctl` 和 `plutil` 使用系统工具；Python 仅使用标准库。若没有 Python 3，请按本机习惯安装，例如已安装 Homebrew 时执行 `brew install python`。脚本会报告缺失依赖，不自动安装软件包。

在仓库根目录，使用普通用户执行：

```bash
chmod +x mihomo-manager.sh
./mihomo-manager.sh shortcut
export PATH="$HOME/.local/bin:$PATH"
mm help
mm install
mm config set /absolute/path/config.yaml
mm test
mm start
mm status
```

查看实际运行目录及配置文件位置使用 `mm info`，系统实例使用 `sudo "$HOME/.local/bin/mm" --system info`。输出包括模式、内核版本/安装状态、服务与自启状态、launchd 标识、管理脚本、运行目录（`-d`）、配置文件（`-f`）、内核、资源清单、日志、备份、运行和自启 plist、锁位置；各路径标注“已存在”或“未创建”。订阅来源只显示记录文件路径，不显示 URL 或配置内容。未安装也可以执行，命令不创建目录或获取写锁。

`shortcut` 只安装命令入口，不下载内核；普通模式 `install` 成功后也会自动设置，因此已安装的用户可以直接补运行一次 `./mihomo-manager.sh shortcut`。配置入口保存独立脚本到 `~/.local/bin/mm`，以后移动或删除仓库不影响 `mm` 的执行。新开终端会读取 zsh/Bash 的 PATH 配置；当前终端执行示例中的 export 即可，无需重新加载整份 shell 配置。

zsh 支持 `ZDOTDIR`；Bash 更新现有登录配置和 `.bashrc`。重复安装替换同一段带标记的配置，不重复追加；保留已有内容、文件权限和 rc 符号链接。如果已有其他 mm 命令或明显别名/函数定义，配置入口会报告冲突，内核安装结果保留。系统模式不自动更改 root 或原用户的 shell 配置，使用 `sudo "$HOME/.local/bin/mm" --system ...` 管理系统实例。

`install` 默认解析最新稳定发布，指定版本写为 `install v1.19.32`。Apple Silicon 选择 `darwin-arm64`，Rosetta 会检查硬件架构；Intel 选择 `darwin-amd64-v1`。发布资产没有 SHA-256 digest 时拒绝安装。重复安装只更新内核，不覆盖现有配置。

首次生成 `mixed-port: 7890`、`allow-lan: false`、`MATCH,DIRECT` 的验证配置，不包含代理节点。内核启动成功只能说明本机服务可运行，实际代理节点需要导入自己的配置。脚本不修改系统代理；如需使用，可在 macOS 网络设置中手动指定 HTTP/SOCKS 代理，或对单个命令使用：

```bash
curl --proxy http://127.0.0.1:7890 --max-time 30 https://example.com
```

无参数 `mm` 在终端显示中文菜单；管道或其他非交互环境无参数只显示帮助。子命令适用于自动化，参数错误和更新失败返回非零退出码。

菜单按“服务管理”“配置与更新”“自启与诊断”“卸载与帮助”分组，顶部显示模式、服务状态及自启状态。宽终端为双列，窄于 68 列时为单列；中文按显示宽度对齐。标题和编号为蓝色，启动/启用为绿色，停止/禁用及保留数据卸载为黄色，完全卸载为红色。原操作编号保留，输入 `h`、`help` 或 `?` 查看帮助，`0` 退出。

```bash
mm                 # 自动布局与配色
NO_COLOR=1 mm      # 无色菜单
COLUMNS=40 mm      # 使用窄终端布局
```

输出被重定向、TERM 为 dumb/未设置、或设置了 NO_COLOR（包括空值）时禁用 ANSI 色码。不自动清屏，操作结果仍保留在终端中。脚本更新后，正在运行的旧菜单需先输入 `0` 退出，再执行 `mm` 加载新菜单。

帮助、状态、info、操作过程、错误及日志也采用统一输出样式。标题和输入提示使用蓝色，执行阶段使用青色，完成结果使用绿色，注意/恢复信息使用黄色，错误使用红色。帮助按功能分组并附示例；状态显示概要；info 按“状态概要、运行目录与配置、程序与快捷入口、日志与恢复、服务文件与操作锁”分组，长路径在标签下单独缩进并保持完整可复制。

安装、更新、配置导入等操作依次显示查询/下载/校验/应用阶段，再显示结果和相关文件位置。启动失败提示日志位置，配置失败保留原文件并提示校验日志，恢复失败单独显示保留的备份路径。原生 launchctl/Python 输入诊断会以统一错误上下文和缩进原因显示，失败退出码保持。

`mm logs [行数]` 会显示每个文件的读取范围和位置，空日志/尚无日志会明确提示；已有日志中的 ANSI SGR 仅在展示时剥离，再突出 error/warning，不改写源日志。stdout 和 stderr 分别按各自的实际终端连接决定颜色；例如 stdout 写入文件、stderr 仍连着终端时，错误仍可配色。使用 `NO_COLOR=1 mm info` 或 `NO_COLOR=1 mm logs` 可同时关闭所有输出流的颜色。

## 3. 配置与资源更新

### 3.1 配置来源与订阅

```bash
# 导入完整的 mihomo YAML，而非单个节点链接
mm config set ./config.yaml

# URL 应来自可信提供方；示例中的地址需要替换
mm config set 'https://provider.example/subscription?token=REPLACE_ME'
mm config update
```

HTTPS 导入成功后将来源保存在数据根目录 `config-url`，权限 0600；更新不打印该地址。命令行参数仍可能出现在 shell 历史或本机进程参数中，使用本地文件可避免将订阅 token 写进命令历史。改用本地配置时会清除远程来源，之后 `config update` 将明确报错。

导入先复制运行目录到隔离暂存区，用真实内核执行 `-t -d <暂存run目录> -f <候选配置>`。测试失败写入 `logs/last-test.log`，旧配置和来源不变。测试成功再替换；原服务已加载时自动重启，未加载时保持停止。配置测试不是安全沙箱：可信配置可能下载 provider，绝对路径仍受内核行为控制。

### 3.2 Web 面板配置

导入本地配置或订阅后，执行以下命令，或在菜单选择第 17 项：

```bash
mm config ui
mm start                 # 原本已运行则配置应用时自动重启
```

脚本在实际运行的 `run/config.yaml` 中写入以下配置，不要求原文件已经包含 UI 字段：

```yaml
external-ui: ui
external-controller: 127.0.0.1:9090
external-ui-url: "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
```

下载 URL 始终更新为指定地址；目录和控制器只在缺少或为空时补齐，已有非空值保留。`secret` 和 `external-ui-name` 也保持原样，其他节点、规则、嵌套同名字段、注释与换行保留。默认目录为运行目录下的 `ui/`，默认浏览器地址为 `http://127.0.0.1:9090/ui/`；保留了其他 API 端口时使用实际地址的 `/ui/`，已有密钥时在面板连接设置中填写。字段含义见 [mihomo 官方全局配置](https://wiki.metacubex.one/config/general/)。

命令先补充候选文件，缺少 UI 入口时通过加速列表下载并展开包，调用真实内核校验，再替换并保留备份。运行中的服务自动重启；未运行的服务保持停止。下载、校验或重启失败时恢复旧配置、启用记录和 UI 目录，订阅来源不变。启用记录为数据根目录的 `ui-enabled`（0600），可通过 `mm info` 查看位置；以后 `config set` 和 `config update` 会继续应用同一补充规则。若要停止后续自动补充，先停止管理操作，删除该记录，再导入自己需要的配置。

已有非空 index.html 时保留缓存，更新包执行 `mm update-ui` 或菜单第 18 项。下载目录允许运行目录内的子目录，支持 `external-ui-name`；不接受运行目录本身、目录外路径或配置/GEO 文件作为 UI 目标。默认卸载保留 UI 文件和启用记录，完全卸载删除。

编辑器使用 Python 标准库，支持常见的单文档、顶层不缩进块映射 YAML、单行引号键/值、嵌套配置、块文本及无缩进规则列表；根流式映射、多文档、多行引号/流式集合、重复 UI 键和复杂 UI 值明确拒绝，旧配置保持。遇到此提示应先将配置整理为上述常见写法，再执行命令。

### 3.3 下载加速与自动回退

无需先安装内核即可查看或设置列表；用户模式和系统模式分别保存自己的设置：

```bash
mm download-proxy show
mm download-proxy set gh.mlang.cc ghfast.top
mm download-proxy set 'https://gh.mlang.cc/{url}' 'https://backup.example/{path}'
mm download-proxy reset
mm download-proxy disable
mm update-core
mm update-ui
```

`show` 不创建目录或获取锁；`set` 替换列表，先提供的地址优先，最多 10 项；`reset` 恢复默认；`disable` 清空加速项，只走官方源。菜单第 19 项支持查看、设置、恢复和禁用，输入多个前缀时用空格分隔。默认列表为 gh.mlang.cc、ghfast.top，最终追加官方地址。2026-10-03 已核验 gh.mlang.cc 的 metacubexd 归档请求格式，完整 HTTPS 地址应跟在加速前缀后；使用 `{path}` 可兼容要求去掉原协议的服务。

生效配置保存到数据根目录 `download-proxy.json`（0600），不存在时采用默认列表，路径见 `mm info`：

```json
{
  "mirrors": [
    "https://gh.mlang.cc/{url}",
    "https://ghfast.top/{url}"
  ],
  "connect_timeout": 10,
  "timeout": 60
}
```

`{url}` 替换为完整的原始 `https://github.com/...`；`{path}` 替换为 `github.com/...`。裸域名/HTTPS 前缀自动补 `/{url}`。连接超时允许 1–30 秒，每源总超时允许 10–300 秒，可在无管理操作时编辑 JSON；命令重新设置列表会使用缺省超时。每个来源进行一次下载，超时、HTTP 错误、空文件或包校验失败清理暂存内容后尝试下一个，全部失败不改变正在使用的内核/面板。

内核的版本、资产地址和 SHA-256 始终从官方发布 API 取得；加速只改传输 URL，不改官方地址校验。每个来源均核验 hash 和 gzip，错误页不能冒充内核。UI 检查 ZIP CRC、入口 HTML、最多 20,000 项与展开总大小 512 MiB，拒绝路径穿越、加密条目、符号链接及特殊文件，再剥离单个归档根目录加载静态文件。UI 分支 ZIP 没有固定发布 SHA-256，ZIP 校验不等于来源身份校验。

发布 API、订阅 URL 和 GEO 使用各自原下载流程，不经过加速服务。`external-ui-url` 保留官方地址，面板内置升级调用及直接运行内核的下载不使用脚本列表；要使用多源回退，应执行 `mm update-ui`。这是因为 [mihomo v1.19.32 UIUpdater](https://github.com/MetaCubeX/mihomo/blob/v1.19.32/component/updater/update_ui.go) 只接受单个地址；脚本预加载后内核发现目录非空便跳过首次下载。

### 3.4 GEO 清单与更新

默认清单 `resources.json` 管理四个文件，来源已在施工时核验：

| 本地文件名 | 远程资产 | 用途 |
|---|---|---|
| `geoip.dat` | `geoip.dat` | `geodata-mode: true` 的 GeoIP 数据 |
| `geosite.dat` | `geosite.dat` | GEOSITE 域名数据 |
| `Country.mmdb` | `country.mmdb` | 默认 GeoIP MMDB 数据 |
| `ASN.mmdb` | `GeoLite2-ASN.mmdb` | ASN 数据 |

清单条目格式：

```json
{
  "geoip.dat": {
    "url": "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"
  }
}
```

可添加 `sha256` 字段，其值为预期文件的 64 位十六进制摘要。固定摘要适合固定资源版本，滚动更新地址配固定摘要时，需要在上游内容更新后同步修改摘要。清单只允许上述四个本地文件名，拒绝目录穿越、非 HTTPS、重复参数和未知字段。

```bash
mm update-resources
mm update-resources geoip.dat geosite.dat
```

所有选定资源先下载完、检查非空/非错误页/可选哈希，再执行配置测试，全部通过才替换。若当前配置不引用某种 GEO 文件，`mihomo -t` 无法证明它的格式正确；真实 smoke 测试额外使用 GEOIP/GEOSITE 规则验证两种 `.dat` 的加载。内核的 provider 更新和 `geo-auto-update` 独立于此清单，建议使用脚本更新时关闭内核 GEO 自动更新，避免两个写入者竞争。

## 4. 服务和自启

| 模式 | 权限 | 管理域 | 自启时机 |
|---|---|---|---|
| 普通用户 | 当前用户，无 sudo | `gui/<UID>` | 用户图形登录后 |
| `--system` | root/sudo | `system` | 系统启动时，无需用户登录 |

```bash
mm start
mm stop
mm restart
mm autostart enable
mm autostart status
mm autostart disable
```

`start` 在未启用自启时 bootstrap 数据目录内的临时 plist，下次登录不会自动注册。`autostart enable` 将 plist 放到 `~/Library/LaunchAgents/` 并立即启动。`stop` 通过 bootout 移除当前 job，KeepAlive 不会立即拉起；若保留了持久 plist，下次登录仍会启动。`autostart disable` 停止服务并删除持久 plist。

`stop` 与更新事务在 `bootout` 后轮询 `launchctl print`，等旧 job 真正消失（最多 10 秒）再注册同名服务。若启动报 `Bootstrap failed: 5: Input/output error`，先确认不是旧实例仍在退出（稍后重试）；仍失败时再区分 `gui/<UID>` 未登录图形会话或系统模式未用 `sudo`。

系统模式拥有独立目录 `/Library/Application Support/sys-toolkit/mihomo` 和 `/Library/LaunchDaemons/` plist。每条管理命令都要带 `--system`，不会自动使用原用户的配置：

```bash
# 先停止用户实例，避免两个实例争用同一端口
mm stop
sudo "$HOME/.local/bin/mm" --system install
sudo "$HOME/.local/bin/mm" --system config set /absolute/path/config.yaml
sudo "$HOME/.local/bin/mm" --system autostart enable
sudo "$HOME/.local/bin/mm" --system status
sudo "$HOME/.local/bin/mm" --system autostart disable
```

TUN 需要内核以 root 创建 `utun` 并修改路由，脚本提供系统实例的一键入口，不再要求手工拼装多条命令。用户模式无论配置如何都会在日志中报 `Start TUN listening error: ... operation not permitted`，这不是配置错误。完整切换步骤：

```bash
# 1. 停止用户实例（保留其配置与数据）
mm stop
mm autostart disable

# 2. 导入含 tun 段的配置，并启用 TUN：写入开机自启、立即启动并校验
sudo "$HOME/.local/bin/mm" --system enable-tun "$HOME/Downloads/config.yaml"

# 3. 确认 TUN 实际监听（进程存活不等于 utun 创建成功）
sudo "$HOME/.local/bin/mm" --system status
sudo "$HOME/.local/bin/mm" --system logs 100
```

`enable-tun` 省略配置路径时使用系统实例当前配置；源也可以是 HTTPS 订阅地址，来源会记录在同一事务内。命令要求配置存在顶层 `tun:` 块，它只把该块内的 `enable` 改为 `true`（缺失则按已有缩进插入），`stack`、`dns-hijack`、`auto-route`、节点和规则均保持原样。缺少 `tun:` 块、多个 `tun:`/`enable`、`tun: {...}` 流式写法或异常标量会明确报错，旧文件不变。

关闭 TUN 实例但保留配置：

```bash
sudo "$HOME/.local/bin/mm" --system disable-tun
```

该命令停止服务并移除开机自启 plist，同时把 `tun-mode` 记为 `mode=user`；之后需要临时使用时执行 `sudo mm --system start`。要完全回到普通用户实例，先清空系统实例再重装用户实例：

```bash
sudo "$HOME/.local/bin/mm" --system uninstall --yes
mm install
mm config set /absolute/path/config.yaml
```

两种模式的目录与配置完全独立，系统实例不会自动读取用户实例的配置，因此 `enable-tun` 需要显式传入配置文件（或订阅地址）。“启用 TUN”仅代表服务启动成功，网卡/路由/DNS 是否符合预期需看日志与实际请求；用户模式菜单第 20/21 项会请求管理员密码后转入系统模式执行。系统模式要求数据和程序由 root 拥有且不可由其他用户写入。

启动后最多等待十秒，连续两次观察到 `state = running` 和 PID 才报告成功。这能发现常见的即时启动失败，不能保证远端节点可达。启动/启用自启失败时查看日志；启用自启过程中若已经写入持久 plist，需执行 `autostart disable` 清理后再排查。

## 5. 更新机制与恢复

### 5.1 正常事务与失败回滚

```text
目录锁 -> 同盘暂存 -> 下载/校验 -> 保存旧文件
 -> 记录原 job 是否加载 -> bootout -> rename 目标文件
 -> 若原 job 已加载则 bootstrap + 存活检查
 -> 成功：旧文件存入 backups/previous；释放锁
 -> 失败或 INT/TERM：恢复旧文件与来源，尝试恢复原 job
```

默认数据根目录为 `~/Library/Application Support/sys-toolkit/mihomo`。更新在根目录下创建 `.stage.*`，目标 rename 位于同一文件系统。备份只保留最近一次事务涉及的文件，并在 `backups/previous/targets.txt` 记录范围；一次 GEO 更新可能替换上一次配置备份，因此它不是长期历史仓库。

```bash
mm update-core
mm update-core v1.19.32
```

内核升级先校验压缩包 SHA-256、解压、执行 `-v` 和配置测试。如果替换后服务不能启动，自动恢复旧内核，并尝试重新启动旧服务。SIGKILL、系统崩溃和断电无法触发 shell trap；不承诺多个文件间的断电原子性。

### 5.2 手动恢复最近一次更新

先停止服务，再查看备份清单。以下命令针对用户模式，系统模式需使用对应系统路径及 sudo。示例恢复配置，不盲目递归覆盖整个运行目录：

```bash
mm stop
mihomo_data="$HOME/Library/Application Support/sys-toolkit/mihomo"
cat "$mihomo_data/backups/previous/targets.txt"
cp -p "$mihomo_data/backups/previous/run/config.yaml" "$mihomo_data/run/config.yaml"
# 如果该事务包含 config-url：有备份则恢复；没有备份表示旧来源不存在，应删除现有 config-url
mm test
mm start
```

恢复内核时从 `backups/previous/bin/mihomo` 复制到 `bin/mihomo`，保留执行权限并先运行配置测试。如果最近事务没有更新某文件，备份中不会有该文件，不要把缺失当作“应删除”。仅在 `targets.txt` 中列出、且对应旧文件缺失时，旧状态才是文件不存在。

UI 更新也会将目录（例如 `run/ui`）记入备份清单。恢复时保持服务停止，核对清单和实际 UI 子目录后，用对应备份目录完整替换当前 UI 子目录；恢复配置和 ui-enabled 后再测试、启动。不得把备份目录递归合并进现有面板，否则旧资源可能残留；也不得删除或覆盖整个 run 目录。

自动恢复失败会保留 `.stage.*/rollback` 并报告路径。正常失败回滚使用同样的文件映射；处理断电遗留时核对哪个暂存区包含完整 rollback 和哪些文件已经提交，再逐项恢复。尚未生成 `targets.txt` 的异常暂存区不能直接按“缺失即删除”处理。根目录锁只协调本脚本，不约束内核或外部编辑器。

## 6. 卸载与数据所有权

```bash
mm uninstall
mm uninstall --yes
mm uninstall --purge --yes
```

默认卸载停止 job、删除自启 plist、移除内核与内核备份，保留 `run/` 配置/资源/provider 缓存、订阅来源、资源清单、日志和其他备份。重新执行 `install` 可以恢复内核，既有配置保留。`--purge` 删除本工具固定根目录中的所有内容，管理脚本本身和同级其他工具目录保留。

两种用户卸载方式都会移除本工具的 `~/.local/bin/mm` 及其 PATH 配置块。如果入口已被其他程序替换，则保留该文件；shell 配置中其他内容保留。当前终端 PATH 中可能仍保留 `~/.local/bin`，新终端会采用清理后的配置；目录中的其他工具文件不受影响。之后重新安装需使用仓库脚本或保留的原始下载脚本。

终端卸载需要输入 `yes`；非交互卸载必须显式传 `--yes`。系统实例卸载使用 `sudo "$HOME/.local/bin/mm" --system uninstall ...`，普通实例与系统实例分别清理。系统代理设置若由用户手动配置，卸载后也需由用户自行关闭。

## 7. 施工与验收记录

### 7.1 开发步骤与修正

1. 检查仓库与 Git 状态，沿用独立 Shell 脚本结构；创建功能分支。
2. 核验 GitHub 稳定 Release 资产、GEO 地址、Apple launchd 和配置文档；先提交 SDD 基线。
3. 实现参数入口、平台/权限、固定路径、目录锁、发布下载、更新事务、服务和卸载。
4. 在系统 Bash 3.2 下执行模拟集成测试。发现变量紧接中文字符会被错误识别，统一添加花括号；补充菜单空数组测试，避免 Bash 3.2 与新版本行为差异。
5. 增加启动失败、TERM 中断及恢复失败故障注入，确认旧状态恢复和备份保留。
6. 真实 macOS 下载与服务测试通过后完善运行、恢复和排障文档，记录实测范围。

### 7.2 自动化验证

在仓库根目录执行：

```bash
/bin/bash -n mihomo-manager.sh
shellcheck --shell=bash mihomo-manager.sh
python3 -m unittest discover -s tests -p 'test_mihomo_manager.py' -v
python3 tests/smoke_mihomo_macos.py --resources
python3 tests/smoke_mihomo_macos.py --ui
python3 tests/smoke_mihomo_macos.py --ui --mirror-fallback
git diff --check
```

ShellCheck 是开发检查工具，运行脚本不依赖它。集成测试以系统 `/bin/bash` 运行，临时 HOME/PATH 模拟网络、内核和 launchctl；不更改真实系统服务。真实 smoke 测试下载官方内核与 GEO，使用唯一 label、独立 HOME 和动态端口，结束时 bootout 并删除临时目录；需要当前用户已登录 GUI 域。

| 检查 | 结果与证据 | 需求 |
|---|---|---|
| Bash 语法、ShellCheck | 通过，Bash 3.2.57 | R01、R09 |
| 模拟集成测试 | 26 项全部通过（37.172 秒）；覆盖架构/Rosetta、权限、哈希、菜单、来源、资源、锁、更新中断及卸载 | R01–R10 |
| 模拟集成测试（当前） | 53 项全部通过（93.977 秒）；新增卸载竞争、TUN 启用/关闭与菜单分发；真实 smoke 额外含 5 次运行中事务重启与代理请求 | R04、R18、R19 |
| 真实内核 | 2026-10-03，`sw_vers` 报告 macOS 27.0.1 arm64，v1.19.32 下载与 SHA-256/`-v`/`-t` 通过 | R02、R03 |
| 真实代理请求 | 通过本机 HTTP CONNECT 请求 `https://example.com`，收到 Example Domain | R04 |
| 配置拒绝与导入 | 无效规则配置返回非零，原配置字节保持；合法配置导入后服务恢复 | R05、R10 |
| GEO 资源 | 四文件下载成功；GeoIP/GeoSite 在规则引用下配置测试及重启通过 | R06 |
| 用户服务 | 启停、运行中内核替换、自启 plist 写入/删除、默认和 purge 卸载通过 | R04、R07、R08 |
| 系统服务 | 域/路径/权限入口有模拟覆盖；root 开机、机器重启、TUN 尚未实测 | R01、R07 |

实测资源体积分别为 16,515,432 / 4,253,533 / 7,665,601 / 12,069,758 字节（geoip.dat、geosite.dat、Country.mmdb、ASN.mmdb）；这是本次下载记录，滚动资源今后可能变化。Intel 真机执行、用户注销再登录、系统启动与 TUN 需要按下一节人工验收，不以模拟替代实测。

## 8. 排障与人工验收

追加施工（R12，规格提交 `915c86a`）：新增内核安装前的 `shortcut` 与安装成功后的自动配置，更新文档为 `mm` 操作示例。新增五项集成测试覆盖独立入口、配置幂等、Bash 登录配置、ZDOTDIR/rc 符号链接、冲突保留和清理；最终回归 31 项全部通过（43.040 秒），Bash 语法和 ShellCheck 通过。在当前账户配置真实 `mm` 并执行 `mm help` 验证，shell PATH 块和独立命令入口已创建。

追加施工（R13，规格提交 `ae42495`）：新增只读 `info`，同步帮助及菜单第 16 项，更新本机 mm 入口。33 项集成测试全部通过（47.445 秒），验证未安装查询不创建目录、系统路径、运行中带锁查询不修改文件以及不输出订阅 token/配置内容；Bash 3.2 语法、ShellCheck 和文档检查通过，真实 `mm info` 查询成功。

追加施工（R18/R19）：新增 TUN 一键启用/关闭、`tun-mode` 记录、`status`/`info` 展示与菜单 20/21；同时修复 `bootout` 异步卸载竞态（`unload_job` 轮询等待，`ensure_running` 统一启动）。53 项集成测试全部通过（93.977 秒），新增 7 项覆盖异步卸载后重启（回归真实的 `Bootstrap failed: 5`）、非系统模式拒绝、无 `tun` 段拒绝、翻转 `enable` 保留注释、缺失 `enable` 插入、`disable-tun` 停止并移除自启、系统模式菜单分发。Bash 3.2 语法与 ShellCheck 通过；真实 macOS smoke 通过：官方内核下载/校验、HTTP CONNECT 代理请求、**连续 5 次运行中事务重启后仍可代理**、自启与卸载。真实 root TUN 的网卡/路由/DNS 行为仍属人工验收边界。

### 8.1 排障矩阵

追加施工（R14，规格提交 `1572bfa`）：完成终端菜单分组、中文列宽对齐、实时状态、语义配色和帮助入口。Bash 3.2 语法、ShellCheck 与现有菜单集成测试通过（含安装、状态、info 分发）。真实 PTY 检查通过：80 列彩色双列、40 列单列各行不越界、NO_COLOR 非空/空值禁色、TERM=dumb/空值禁色、stdout 重定向禁色、h 帮助入口。已更新当前账户 mm 独立入口。

追加施工（R15，规格提交 `982e4b3`）：统一菜单之外所有命令的标题、阶段、结果、字段、长路径、提示和错误；原生诊断不再直接混入输出。33 项集成回归通过（47.149 秒），Bash 3.2 语法和 ShellCheck 通过，真实 macOS smoke 完成官方内核下载/配置校验/代理请求/运行中更新/用户自启/卸载。真实 PTY 检查通过：help/status/info/logs 的色彩与重定向、stderr 独立 TTY、NO_COLOR 非空/空值、TERM=dumb/空值、日志级别色彩/原文件不变、空日志提示及 JSON 异常简化。信号测试改为直接对被测管理器 PID 注入 TERM，143 退出码和恢复行为仍通过。

追加施工（R16，规格提交 `0d00fd5`）：新增 `config ui`、菜单第 17 项及 `ui-enabled` 记录；导入与订阅刷新自动补齐面板配置。39 项集成测试通过（69.908 秒），新增六项覆盖缺失/已有/空值/嵌套字段、幂等、私有权限、CRLF/文档结束符、来源保留、刷新及回滚；跨行流式结构拒绝补充后，6 项 UI 回归通过（13.865 秒）。真实 macOS v1.19.32 `--ui` smoke 下载官方 metacubexd 并通过 `/ui/` 返回 HTML，保留动态 API 端口、重新导入补齐、启停、自启及卸载通过。Bash 3.2、ShellCheck 与四份 SDD 文档检查通过。

菜单第 17 项的真实 PTY 分发回归通过（2.386 秒）；已刷新当前账户的独立 mm 脚本，并验证 help/info 的新入口与记录路径。真实用户目录只刷新快捷入口，内核和面板验证在隔离实例执行。

追加施工（R17，规格提交 `559b7b3`）：新增 download-proxy 列表管理、校验失败回退、update-ui 与 UI 目录事务，菜单 18/19 提供入口。46 项集成测试通过（92.708 秒），覆盖坏哈希/HTTP 错误到下一镜像及官方回退、全部失败保留旧内核、列表验证/权限/禁用/只读、订阅隔离、UI 解压/缓存/命名目录、安全路径和目录的启动失败/TERM 回滚。菜单 PTY 回归通过（3.971 秒）。真实 macOS v1.19.32 验证默认 gh.mlang.cc 成功下载内核/UI；另一次首源故意设为不通地址，内核和 UI 均切换至后源，面板更新后 /ui/ 返回 HTML，服务/自启/卸载流程通过。Bash 3.2、ShellCheck、四份文档检查通过；实际 mm show 显示默认列表，入口已刷新。

最终兼容性/诊断调整后，下载及设置/目录回滚专项 4 项通过（8.516 秒）。2026-10-03 ghfast.top 的实际归档 HEAD 请求返回 HTTP 200、application/zip；该结果只说明本次请求可用，不保证未来服务可用性。

| 现象 | 检查证据 | 处理及边界 |
|---|---|---|
| 下载失败 | 网络、GitHub API 访问与限流；现有文件保持 | 等待限流恢复或修复 HTTPS；不跳过哈希 |
| 版本没有 digest | Release Asset API 对应资产的 `digest` | 选择带 SHA-256 的正式版；不安装 alpha |
| `gui/<UID>` bootstrap 失败 | 是否已图形登录；`launchctl print gui/<UID>` | 登录桌面后使用用户模式，登录前任务用系统模式 |
| 配置测试失败 | `logs/last-test.log` | 修正 YAML、节点/规则/provider 路径，旧配置保持 |
| 服务启动失败或循环重启 | `logs/stderr.log`、`logs/stdout.log`、`launchctl print` | 排查端口占用、TUN 权限和文件路径；先 stop 或 disable 自启 |
| `Bootstrap failed: 5: Input/output error` | 紧接 `stop`/更新后的 bootstrap；`launchctl print` 是否仍能找到 job | 多为 `bootout` 尚未完成卸载，稍后重试（脚本已内置等待）；持续出现时确认图形会话或 `--system` 是否使用 sudo |
| TUN 日志报 `operation not permitted` | 运行模式与数据目录 | 用户模式无 root 无法创建 `utun`；改用 `sudo mm --system enable-tun`，不要把该行当成配置错误 |
| `enable-tun` 报缺少/多个 `tun` 段 | 候选配置的顶层键结构 | 整理为单文档块映射 `tun:` 段后重试；流式 `tun: {...}` 与多行引号不支持自动改写 |
| 存在 `.lock` | `.lock/pid` 对应进程、暂存 rollback | 确认无写操作运行，先保存/恢复遗留数据，再手动删除锁 |
| 系统路径所有权错误 | `ls -ld` 数据目录、父目录和 plist | 核对是不是用户模式文件错误放入系统目录；不直接跳过权限检查 |
| 更新回滚未完成 | 输出中保留的 `.stage.*/rollback` 路径 | 停止 job 后逐文件恢复，测试，再启动 |
| 本地运行正常但不能代理 | 配置的节点/策略、应用代理设置、真实请求 | 初始配置只直连；进程运行状态不证明节点可用 |

日志可通过 `mm logs 100` 查看，最大 10,000 行。日志和备份可能包含节点或订阅信息，文件使用私有权限；对外分享前自行脱敏。服务日志为持续追加，首版没有自动轮转，长期使用需监控磁盘并自行归档。

### 8.2 待人工执行的系统验收

1. 在 Intel macOS 上运行安装、配置测试和代理请求，确认 `amd64-v1` 资产真实可执行。
2. 在普通用户真实 HOME 中启用自启，注销并重新图形登录，确认服务运行；disable 后再次登录，确认不运行。
3. 停止用户实例，安装系统实例并启用自启，重启机器；登录后检查 `sudo ... --system status` 和启动日志，确认 LaunchDaemon 注册。
4. 按 [TUN 官方配置](https://wiki.metacubex.one/config/inbound/tun/) 准备配置，先 `mm stop`，再以 `sudo ... --system enable-tun <配置>` 启用，检查路由/DNS 和实际请求；`sudo ... --system disable-tun` 后确认服务停止、开机自启移除，卸载后确认相关网络状态恢复。
5. 执行系统模式保留数据和 purge 卸载，确认 `/Library/LaunchDaemons/` plist 移除，其他客户端的文件和服务仍正常。

这些步骤影响真实登录/启动与网络状态，不属于本次隔离 smoke 测试；尚未执行的部分明确记录为平台验收边界。

## 9. 参考

核验日期：2026-10-03；开发实测内核 v1.19.32。运行时跟随 GitHub 最新稳定版，固定版本需显式指定。

- [mihomo 安装](https://wiki.metacubex.one/startup/)
- [mihomo 发布资产](https://github.com/MetaCubeX/mihomo/releases)
- [mihomo 架构与兼容构建 FAQ](https://github.com/MetaCubeX/mihomo/wiki/FAQ)
- [mihomo GEO 与全局配置](https://wiki.metacubex.one/config/general/)
- [MetaCubeX GEO 资源发布](https://github.com/MetaCubeX/meta-rules-dat/releases/tag/latest)
- [GitHub Release Asset digest API](https://docs.github.com/en/rest/releases/assets?apiVersion=2022-11-28)
- [Apple 创建 LaunchDaemon / LaunchAgent](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
