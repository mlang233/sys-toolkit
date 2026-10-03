# macOS mihomo 管理脚本：设计

本设计将需求规格落实为路径所有权、服务状态和可恢复更新流程；面向维护者，采用 D3 工具/架构深度。

## 目录

- [1. 目录与权限](#1-目录与权限)
- [2. 模块与状态](#2-模块与状态)
- [3. 下载与版本选择](#3-下载与版本选择)
- [4. 更新事务与回滚](#4-更新事务与回滚)
- [5. 取舍与边界](#5-取舍与边界)
- [6. 验证与恢复入口](#6-验证与恢复入口)
- [7. Web 面板配置](#7-web-面板配置)
- [8. 下载加速与 UI 包加载](#8-下载加速与-ui-包加载)
- [9. TUN 模式与系统实例](#9-tun-模式与系统实例)
- [10. 参考](#10-参考)

## 1. 目录与权限

| 对象 | 用户模式 | 系统模式 |
|---|---|---|
| 数据根目录 | `~/Library/Application Support/sys-toolkit/mihomo` | `/Library/Application Support/sys-toolkit/mihomo` |
| 持久 plist | `~/Library/LaunchAgents/io.github.sys-toolkit.mihomo.plist` | `/Library/LaunchDaemons/io.github.sys-toolkit.mihomo.plist` |
| launchd 域 | `gui/<当前UID>` | `system` |
| 程序 | `bin/mihomo` | 同左，相对于各自根目录 |
| 配置和数据 | `run/config.yaml` 与 GEO/provider 缓存 | 同左 |
| 日志 | `logs/stdout.log`、`logs/stderr.log` | 同左 |
| 管理元数据 | `resources.json`、`config-url`、`ui-enabled`、`download-proxy.json`、`service.plist`、`backups/`、`.lock/` | 同左 |
| 快捷命令 | `~/.local/bin/mm` 独立脚本；`shortcut.json` 记录 shell 配置文件路径 | 不改写用户 shell，使用用户入口传入 `--system` |

使用固定目录，避免把任意环境变量路径用于递归卸载。根目录权限 0700；配置和订阅 URL 默认 0600，程序 0755。系统模式拒绝符号链接目录和不属于 root 的现有管理路径，避免 root 执行用户替换的内核。

`info` 根据当前模式计算这些路径并输出存在状态，复用 `status` 显示内核、服务和自启情况。该命令不创建数据目录、不获取写锁、不读出配置或订阅内容；即使尚未安装或存在另一个操作的锁，也可以查询。运行目录对应 launchd 参数 `-d`，配置文件对应 `-f`，普通模式和系统模式分别显示各自实际路径。

菜单使用 Python 标准库渲染，按 Unicode East Asian Width 计算中文占用的终端单元格，再补齐左列宽度，避免按字符串字符数对齐时中文偏移。宽度优先使用有效的 `COLUMNS`，否则读取 stdout 终端尺寸；68 列以上采用双列分组，更窄采用单列并拆分状态栏。仅 stdout 为 TTY、TERM 有效且未设置 NO_COLOR 时输出 ANSI 颜色；各段均重置颜色，不依赖第三方终端库。菜单查询服务和自启状态后展示，保持既有编号，h/help/? 进入帮助。

全局 CLI 使用 `ui_title / ui_section / ui_line / ui_path / ui_message / ui_detail / ui_prompt` 公共函数，统一标题、字段、路径、阶段/结果和输入层级。长路径在标签下单独缩进，保持完整路径便于复制；`info` 按用途分组，`status` 显示概要，帮助命令及描述分行。颜色根据每次输出的实际目标 fd 判断：stdout 重定向不影响仍连接 TTY 的 stderr，NO_COLOR 则同时关闭两者。

`run_checked` 捕获 launchctl 和 Python 校验的诊断，保留失败退出码，以错误上下文加缩进原因呈现；Python 输入异常仅显示最后一行原因，避免 traceback 淹没结果。日志按文件名/路径/行数分段，显示空日志提示，展示时移除已有 ANSI SGR 再按 error/warning 级别配色，不改写文件。SIGTERM 故障注入直接向测试管理器 PID 发信号，确保诊断捕获子进程不会改变测试目标；回滚、只读和订阅隐私仍由原集成场景验证。

## 2. 模块与状态

```text
命令/中文菜单
  -> 平台、权限、依赖检查
  -> 固定目录检查 + 写操作目录锁
  -> HTTPS 下载 / 本地导入 -> 同盘暂存区
  -> SHA-256 / 文件检查 / mihomo -t
  -> 文件替换 -> launchctl 恢复原运行状态
  -> 成功：保存一代备份；失败：回滚并记录日志
```

脚本不 fork 自管后台进程。`start` 用数据目录的 plist 注册临时 job，未启用自启时不会在下次登录/开机注册。启用自启将 plist 放入系统扫描目录，并 bootstrap。`stop` 和禁用自启使用 bootout，因此 KeepAlive 不会与用户停止操作竞争；持久 plist 仍存在时，下次登录/启动会重新运行。

Apple launchd 的 `bootout` 是异步的：命令返回成功时旧 job 不保证已从域中移除。立即用同一 label 执行 `bootstrap` 会被拒绝，表现为 `Bootstrap failed: 5: Input/output error`（本机日志同时出现 “Caller tried to import service with same label as an existing service”）。因此 `unload_job` 在 `bootout` 成功后轮询 `launchctl print`，直到 job 真正消失（最多 10 秒），超时则明确失败，`stop` / 更新事务 / 自启切换都复用它。`bootstrap` 失败时除原因外额外提示区分“旧实例仍在退出”与“域/权限错误”。

`KeepAlive=true` 用于意外退出后的重启，`ThrottleInterval=10` 限制失败重启频率。启动后连续两次观察运行状态，最多等待十秒；只检查进程存活，端口冲突和节点故障仍需看日志/代理请求。

## 3. 下载与版本选择

通过 `api.github.com/repos/MetaCubeX/mihomo/releases/latest` 或指定 `tags/vX.Y.Z` 取得 JSON，Python 标准库解析资产名、官方下载 URL 与 digest。Apple Silicon（包括 Rosetta）选择 darwin-arm64，Intel 选择 darwin-amd64-v1，避免依赖更高 CPU 指令集。缺少 SHA-256 的旧发布版拒绝安装，不自动降低校验要求。

curl 连接超时 15 秒、总超时 300 秒、重试两次。失败只报告下载类别，不把订阅 URL 打印到错误中。GEO URL 默认来自 MetaCubeX/meta-rules-dat，用户可编辑 JSON；可选 SHA-256 固定内容版本。无 SHA-256 时仅保证 HTTPS、非空、非 HTML 和当前配置测试，未引用资源的格式不能由 `mihomo -t` 证明。

## 4. 更新事务与回滚

先复制 `run/` 到暂存区，使相对 provider 路径和 GEO 查找保持一致，再测试候选配置/内核。更新仅替换目标文件，避免把检查期间产生的 provider 缓存覆盖生产缓存。配置来源和配置内容一起回滚。

提交阶段保存目标的旧状态；若 job 已加载则停止，逐个同盘 rename，再按旧加载状态启动。任一步失败，EXIT trap 恢复旧文件和旧服务；INT/TERM 以非零结束并走同一回滚。不存在的旧资源用“旧文件缺失”状态记录，回滚时移除新文件。成功后将旧文件保存到 `backups/`。

目录锁阻止本工具并发写入；锁中记录 PID，存在锁就拒绝操作，不自动抢占。遗留锁要求用户核对后手动清理，避免 PID 复用或进程检查误判。SIGKILL/断电无法被 trap 捕获，暂存区可能遗留，应按施工文档恢复，不承诺跨多个文件的崩溃原子性。

## 5. 取舍与边界

选择原生 launchd 而非 nohup/PID 文件，获得进程监督和明确停止语义；代价是普通模式需要图形登录域，SSH 会话没有 GUI 域时启动会失败并给出 launchctl 日志。系统模式无需图形域，但配置以 root 执行，需要可信的配置来源。

选择单 Bash 脚本嵌入 Python 标准库，保持与仓库脚本分发形式一致，并可靠处理 JSON/XML；代价是要求 Python 3，macOS 不保证预装。首版不实现系统代理开关，用户按自身网络服务名称设置，避免卸载时破坏既有代理配置。

不自动运行定时订阅更新，也不混合更新 rule/proxy providers：其 URL、间隔和格式由 mihomo 配置管理。可手动执行 `config update` 和 `update-resources`；若自行启用内核 GEO 自动更新，应避免同时运行脚本资源更新。

`shortcut` 在内核安装前即可复制当前脚本到 `~/.local/bin/mm`。普通安装成功后自动执行相同配置；候选内核失败时不创建快捷入口。zsh 写入 `${ZDOTDIR:-$HOME}/.zshrc`，Bash 使用已有的首个 `.bash_profile` / `.bash_login` / `.profile` 和 `.bashrc`，避免新建登录文件遮挡用户原来的登录流程。PATH 配置块通过唯一标记替换，重复 source 不重复添加 PATH；脚本进程无法修改父终端，需要当前终端执行提示的 export，或重新开终端。

快捷入口包含所有实现，移动仓库不影响执行。替换通过同目录临时文件和 rename 完成，保留 shell 配置块以外的文本与权限；rc 符号链接写入其当前用户拥有的目标，不移除链接。已有其他 mm 文件、PATH 命令或明显别名/函数定义时拒绝配置，内核安装仍可成功。卸载根据 `shortcut.json` 去除配置块，只删除带本工具签名的入口；入口已被其他内容替换则保留。系统模式不处理用户的这些文件。

## 6. 验证与恢复入口

需求与测试对应见 [任务计划](tasks.md)，具体运行/排障/恢复见 [施工文档](construction.md)。实现前后分别提交 Git，发布说明中记录真实验证与模拟验证的区别。

模拟测试运行真实系统 Bash，网络、操作系统查询和 launchctl 使用临时 PATH 中的替身；故障注入覆盖内核哈希、配置测试、启动失败和 TERM。真实 smoke 测试使用独立 HOME、唯一 label 和空闲端口，校验内核实际下载、HTTP CONNECT 转发、资源加载和服务重启。它不会验证机器重启后持久 plist 的自动扫描，需要单独的系统/登录验收。

## 7. Web 面板配置

`config ui` 使用固定官方 metacubexd 下载地址；缺省静态目录为工作目录下的 `ui`，缺省 API 仅监听本机 `127.0.0.1:9090`。不改写既有非空目录、API 地址、secret 或 external-ui-name。只编辑顶层字段，嵌套的同名字段、注释、节点和规则保持；标准库文本编辑器处理常见块映射 YAML，不支持的根流式映射、多文档、复杂目标值或多行引号明确拒绝，不尝试猜测 YAML 语义。最终由实际 mihomo 进行配置校验。

启用后保存私有 `ui-enabled` 记录；配置导入与订阅刷新在校验前应用同一补充规则。UI 命令的配置、记录和首次下载的目录纳入原有事务，来源 URL 不参与替换；失败时恢复配置、记录和目录。缺少入口文件时由脚本预先下载，已有缓存不因改写下载地址而强制刷新；强制更新使用 `update-ui`。默认卸载保留数据，完全卸载删除。

参考：[mihomo 官方外部用户界面与控制器配置](https://wiki.metacubex.one/config/general/)。

## 8. 下载加速与 UI 包加载

加速设置保存为根目录的 `download-proxy.json`，默认有序列表为 gh.mlang.cc、ghfast.top；每个模板用 `{url}` 拼接原始 HTTPS 地址，或 `{path}` 拼接去除协议后的地址。不存在记录时使用默认值；禁用使用空列表；始终追加官方地址作最后候选。发布 API 保持官方连接以取得资产地址和 digest，订阅和 GEO 保持原下载流程。每次候选下载都有超时，校验失败与网络失败都清理候选并切换下一源，旧版本不受影响。

mihomo v1.19.32 的 UIUpdater 只接受一个 URL，且目录非空时跳过首次下载。因此多源回退由脚本实施：`config ui` 在无 index.html 时预先下载官方 metacubexd ZIP；`update-ui` 强制下载并替换。external-ui-url 保留原始官方地址，面板内置升级操作不继承脚本回退列表。脚本支持运行目录以内的 UI 子目录及 external-ui-name；目录外路径明确拒绝自动加载，避免递归替换任意外部目录。

UI ZIP 在替换前检查 CRC、入口页面、文件数量及总大小，拒绝绝对路径、路径穿越、符号链接和特殊文件；单个归档根目录剥离后加载静态文件。事务扩展为同时备份/恢复普通文件和 UI 目录，启动失败或可捕获信号连同配置/启用记录回滚。UI 分支 ZIP 没有固定发布 digest，验证的是 HTTPS 传输、ZIP 完整性和目录结构；内核仍使用官方 SHA-256。

依据：[v1.19.32 UIUpdater 源码](https://github.com/MetaCubeX/mihomo/blob/v1.19.32/component/updater/update_ui.go)。

## 9. TUN 模式与系统实例

macOS 创建 `utun` 和修改全局路由需要 root，因此 TUN 只能由 `--system` 实例提供；用户模式实例无论配置如何都会在日志中报 `Start TUN listening error: operation not permitted`。脚本区分两种运行状态，在数据根目录记录 `tun-mode`（0600）：`mode=persistent` 表示系统实例已启用 TUN 且写入开机自启，`mode=user`（或文件缺失）表示当前宿主没有由 root 托管的 TUN；`status` 与 `info` 据此显示，而不去解析配置或探测网卡（进程存活与权限错误以日志为准）。

```text
mm stop                                    用户实例停止，腾出端口
sudo mm --system enable-tun <配置路径>       导入配置 + tun.enable=true + 开机自启 + 启动校验
sudo mm --system disable-tun               停止、移除开机自启、保留配置
```

`enable-tun` 在系统模式内完成一个事务：必要时先 `install`；把源配置（本地文件或 HTTPS，保留订阅来源）放入暂存区；用文本编辑器把顶层 `tun` 段的 `enable` 设为 `true`，缺失则按已有缩进插入，其余字段、注释与节点不变；启用过 `config ui` 时同步补齐面板；写入 `tun-mode` 与 `service.plist`；用真实内核 `mihomo -t` 校验；替换文件后写入开机自启 plist 并启动，未稳定运行则以非零退出。冲突输入（无 `tun` 段、多个 `tun`、多个 `enable`、`tun: {…}` 流式映射、异常标量）在校验前拒绝，旧文件不变。

`disable-tun` 先把 `tun-mode` 记为 `mode=user`，删除持久 plist（因此 KeepAlive 与下次开机都不会重启），停止当前 job 后再进入事务替换，使 `TX_LOADED=0`、事务不按旧状态重启。两种模式目录独立，互不影响；从 TUN 回到普通实例的完整回退是 `sudo mm --system uninstall --yes` 后 `mm install`。

两种模式均可通过匿名交互菜单（第 20/21 项）入口启用或关闭 TUN：系统模式直接执行，用户模式调用 `sudo` 重新进入系统模式，因此菜单不绕过 root 权限，也不修改用户 shell。

## 10. 参考

核验日期：2026-10-03，开发下载基准 v1.19.32。

- [Apple：launchd 的进程监督、plist 和启动目录](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- [GitHub：发布资产 SHA-256 digest](https://docs.github.com/en/rest/releases/assets?apiVersion=2022-11-28)
- [mihomo：架构与构建标签](https://github.com/MetaCubeX/mihomo/wiki/FAQ)
- [mihomo：GEO 模式和资源配置](https://wiki.metacubex.one/config/general/)
