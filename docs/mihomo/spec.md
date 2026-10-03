# macOS mihomo 管理脚本：需求规格

以规格驱动开发（Specification-Driven Development，SDD）交付独立 Bash 脚本；本文件定义可验收行为，设计、施工任务和实现应与需求编号对应。

## 目录

- [1. 目标与边界](#1-目标与边界)
- [2. 功能与验收](#2-功能与验收)
- [3. 非功能要求](#3-非功能要求)
- [4. 验证策略](#4-验证策略)
- [5. 参考与基准](#5-参考与基准)

## 1. 目标与边界

面向 macOS 用户及脚本维护者，提供内核下载、服务管理、配置和 GEO 资源更新、自启与卸载。支持 Apple Silicon 和 Intel，兼容系统 Bash 3.2，要求 macOS 12+ 和 Python 3；Python 只使用标准库。下载使用官方 GitHub HTTPS 地址，不自动安装 Homebrew 或其他依赖。

普通模式管理当前用户的 LaunchAgent；`--system` 模式要求 root，管理 LaunchDaemon，覆盖登录前启动及用户自行配置的 TUN 场景。默认不修改 macOS 系统代理、DNS 或路由，不生成代理节点，不安装独立 GUI 应用，支持内核托管的静态 Web 面板配置，不管理其他客户端。

## 2. 功能与验收

| 编号 | 需求 | 验收标准 |
|---|---|---|
| R01 | 平台、权限、路径隔离 | 非 macOS 拒绝执行；普通模式拒绝 root；系统模式要求 root；路径含空格可用 |
| R02 | 安装与下载 | `install [版本]` 默认最新稳定版；识别 arm64 / Intel v1；校验 GitHub asset SHA-256；生成仅本机、直连的初始配置；重复安装不覆盖既有配置 |
| R03 | 内核升级与恢复 | `update-core [版本]` 在隔离目录下载、校验及试运行；配置测试失败不改变旧内核；运行中升级失败恢复旧内核并尝试恢复服务 |
| R04 | 启停与诊断 | `start / stop / restart / status / logs / test` 使用 launchd 管理单实例；显式停止不被 KeepAlive 拉起；停止后等待 launchd 卸载完成再注册同名服务，避免 `Bootstrap failed: 5`；运行检查失败返回非零 |
| R05 | 配置导入与订阅更新 | `config set <本地路径或HTTPS URL>`、`config update`；校验成功才替换；保留单份旧配置；本地导入清除远程订阅来源；不输出订阅 URL |
| R06 | 资源更新 | `update-resources [文件名...]` 支持 `geoip.dat`、`geosite.dat`、`Country.mmdb`、`ASN.mmdb`；URL 与可选 SHA-256 存于 JSON 清单；下载失败、空文件、HTML、校验失败不替换任何资源 |
| R07 | 两种自启 | `autostart enable / disable / status`；用户模式明确为登录自启；系统模式为开机自启；启用后立即运行；禁用后停止并删除持久 plist |
| R08 | 卸载 | `uninstall [--purge] [--yes]` 先停止和删除自启；默认保留配置、资源和日志；purge 只删除本工具固定数据目录；非交互场景必须显式 `--yes` |
| R09 | 操作体验 | 无参数在终端显示中文菜单；非交互无参数显示帮助；子命令参数错误返回非零；`help` 无需平台或依赖检查 |
| R10 | 更新可靠性 | 写操作使用目录锁；临时文件在同一文件系统；更新记录恢复所需备份，普通失败与可捕获信号触发回滚；不声称断电原子性 |
| R11 | 可追溯交付 | 先提交规格/设计/任务，再提交实现和测试，最后提交施工记录；每个需求有测试或明确的人工验收边界 |
| R12 | `mm` 快捷命令 | 普通模式 `install` 自动复制独立管理脚本到 `~/.local/bin/mm`；`shortcut` 可在下载内核前配置入口；为 zsh/Bash 添加可重复执行的 PATH 配置块，支持 ZDOTDIR、现有 Bash 登录配置和符号链接 rc；已有其他 mm 文件/命令/明显别名定义时保留并报告；卸载仅移除本工具入口和配置块；系统模式不修改用户 shell |
| R13 | 运行信息 | `info` 显示模式、内核版本/安装状态、服务/自启状态、launchd 服务标识、当前管理脚本及数据/运行/配置/内核/日志/资源清单/订阅来源记录/备份/plist/锁路径；标明路径是否存在；不显示订阅 URL 或配置内容；未安装也可查询，不创建目录或获取写锁；帮助和菜单提供入口 |
| R14 | 菜单布局与配色 | 按服务、配置更新、自启诊断、卸载帮助分组；宽终端两列且按中文显示宽度对齐，窄终端单列；标题显示模式/服务/自启状态；TTY 中启用 ANSI 配色，重定向、TERM=dumb/未设置或 NO_COLOR 时禁用；保留原编号，新增 h/help/? 帮助入口 |
| R15 | 全局输出样式 | 帮助按功能分组并提供例子；状态显示概要与内核构建信息；info 按用途分组，长路径单独缩进；操作显示标题、阶段、结果及相关路径/后续命令；错误、回滚和原生工具诊断采用一致格式；日志显示文件及行数、空日志提示和级别配色；交互输入采用统一提示；按实际 stdout/stderr TTY 分别决定配色，NO_COLOR/TERM=dumb/未设置/重定向时禁色；保持退出码、只读契约和订阅隐私 |
| R16 | Web 面板配置 | `config ui` 写入指定的 metacubexd gh-pages.zip 地址；缺少或为空时补 external-ui=ui、external-controller=127.0.0.1:9090；保留已有非空目录、控制器、secret、external-ui-name 和其他 YAML 内容；重复执行不重复键；启用后 config set/update 自动补回；来源记录不变；校验后事务替换，重启失败连同启用记录回滚；帮助、菜单、info 和施工文档提供入口；不支持的 YAML 结构明确拒绝，旧配置不变 |
| R17 | 下载加速与回退 | `download-proxy show/set/reset/disable` 管理多个有序 HTTPS 加速前缀或模板；默认 gh.mlang.cc、ghfast.top，最终回退 GitHub 官方源；只加速内核资产和官方 metacubexd ZIP，不代理发布 API/订阅；超时、HTTP 错误、空文件、哈希或包校验失败尝试下一源；内核以官方 API digest 校验；UI 拒绝路径穿越/符号链接/异常包，隔离解压并随配置事务替换；config ui 首次缺失面板时下载，update-ui 强制更新；已有面板/配置在失败时恢复；列表私有保存，两种模式独立；帮助、菜单、info、施工文档同步 |
| R18 | TUN 一键启用 | `mm --system enable-tun [配置文件或HTTPS URL]` 仅在系统模式可用，非系统模式明确报错且不创建系统目录；未安装时先完成系统实例安装；可导入指定配置（本地或 HTTPS，保存订阅来源）；以常见块映射 YAML 识别顶层 `tun` 段，把 `enable` 设为 `true`（缺失则插入，保留原有缩进、同行注释与其他 `tun` 字段），缺少 `tun` 段、多个 `tun` 段、多个 `enable` 键、非块映射 `tun` 或无法安全改写的值明确拒绝且旧配置不变；随后写入开机自启 plist、经真实内核 `-t` 校验、事务替换并启动校验；成功输出生效配置、TUN 记录与开机自启路径，失败时回滚文件 |
| R19 | TUN 关闭与回退 | `mm --system disable-tun` 仅在系统模式可用；停止 TUN 实例、移除开机自启 plist，并记录系统实例已改为手动启动；保留 `tun` 配置与其他数据；`status`/`info` 显示 TUN 记录路径与状态；用户模式提示使用系统模式 |

GEO 清单中的文件名区分大小写；rule-provider/proxy-provider 更新由 mihomo 自身配置控制，不属于此清单。

## 3. 非功能要求

- 下载设置连接超时、总超时和重试，HTTPS 重定向也限制为 HTTPS；不使用 `curl | bash`。
- 配置、来源记录、备份和日志使用用户私有权限；系统服务 plist 为 root 拥有、0644，程序路径为绝对路径。
- 不执行下载的配置或 JSON；JSON/版本号/资源文件名做白名单验证；不使用 `eval`。
- 服务状态依据 `launchctl print` 的运行状态/PID；这是进程存活检查，不等于远端节点可用性。
- 保留一代文件备份和启动失败日志；不宣称所有未被配置引用的 GEO 文件均经过语义验证。

## 4. 验证策略

使用 Python 标准库测试驱动，以隔离 HOME 和 PATH 模拟网络、内核与 launchctl，验证权限、下载完整性、状态转换、失败回滚和卸载边界。真实 macOS 验证下载、配置测试、plist 校验；实际服务启停只在隔离测试实例中执行。root 开机启动、重启机器和 TUN 验收如未实测，施工文档明确列为人工步骤。

## 5. 参考与基准

核验日期：2026-10-03。开发时 GitHub API 最新稳定版为 v1.19.32；运行时动态解析，不硬编码此版本。

- [mihomo 官方安装说明](https://wiki.metacubex.one/startup/)
- [mihomo 发布资产与架构](https://github.com/MetaCubeX/mihomo/releases)
- [mihomo 全局配置与 GEO 下载地址](https://wiki.metacubex.one/config/general/)
- [Apple：LaunchDaemon 与 LaunchAgent](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- [GitHub Release Asset API：digest](https://docs.github.com/en/rest/releases/assets?apiVersion=2022-11-28)
