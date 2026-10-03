# macOS mihomo 管理脚本：施工任务

依照 `spec.md -> design.md -> tasks.md -> 实现 -> 验收记录` 推进，变更需求时同步修改规格及测试。

## 1. 任务清单

- [x] T01：检查仓库、核验官方发布/API/launchd 依据，创建独立 Git 分支（R11）。
- [x] T02：提交需求规格、设计与施工任务作为实现基线（R01–R11）。
- [x] T03：实现 Bash 3.2 入口、模式/权限/依赖、固定目录、锁与帮助/菜单（R01、R09、R10）。
- [x] T04：实现 Release 资产选择、SHA-256 和内核安装升级（R02、R03）。
- [x] T05：实现 launchd 启停、状态/日志、两种自启（R04、R07）。
- [x] T06：实现配置导入、来源保存、GEO 清单、更新事务与回滚（R05、R06、R10）。
- [x] T07：实现保留数据/完全清理卸载，更新 README（R08）。
- [x] T08：运行 Bash 3.2 语法、ShellCheck 和 26 项模拟集成测试；修复缺陷并提交实现（R01–R10）。
- [x] T09：执行隔离 macOS 实测，完善施工记录、运行手册和人工验收边界，提交文档（R11）。

## 2. 验收场景

| 场景 | 关联需求 | 方法 |
|---|---|---|
| arm64/Intel/Rosetta、非 macOS、root 模式限制 | R01、R02 | 模拟系统命令；本机平台实测 |
| 初装、重复安装、指定版、缺少 digest/错误 digest | R02、R03 | 模拟 HTTP 及真实发布资产下载 |
| 临时启动、停止、重启、启动失败 | R04 | 模拟 launchctl；隔离实例实测 |
| 合法/非法配置、来源更换、URL 更新、服务失败回滚 | R05、R10 | 模拟内核校验及运行失败 |
| 资源部分下载失败、HTML/空文件、路径穿越、哈希错误 | R06、R10 | 模拟资源端点及 JSON 清单 |
| 两种 plist、启用/禁用、停止后不被重启 | R07 | 模拟 launchctl；真实 plist lint；系统模式人工验收 |
| 默认卸载保留数据、purge 范围、无确认拒绝 | R08 | 隔离 HOME 与模拟服务 |
| 空格路径、错误参数、菜单退出、活锁 | R01、R09、R10 | 集成测试 |
| Git 提交与文档引用 | R11 | Git log、文档检查与 diff 审阅 |

## 3. Git 检查点

1. `docs(mihomo): define macOS manager specification and design`
2. `feat(mihomo): implement transactional macOS lifecycle manager`
3. `test(mihomo): verify lifecycle and failure recovery`（若测试与实现一并提交，可合并到第二步）
4. `docs(mihomo): record validation and operating guide`

每个检查点查看 `git diff --check` 和 `git status`，只暂存本次交付文件，不推送远端。

实际检查点：规格 `b8e2b0c`；实现和测试合并提交 `6b3902a`；施工记录随最终文档提交。26 项集成测试通过，真实用户服务/GEO/代理请求验证通过；重启、Intel 真机及 root TUN 保留为文档中的人工平台验收边界。

## 4. 参考

- [需求规格与来源](spec.md)
- [施工文档与实测结果](construction.md)
- [mihomo 官方发布资产](https://github.com/MetaCubeX/mihomo/releases)

## 5. 快捷命令追加施工

- [x] T10：追加 R12，定义 `mm` 安装、冲突处理、独立分发和卸载契约。
- [x] T11：实现 `shortcut` 与 install 自动配置，保存 shell 配置路径并按标记清理。
- [x] T12：验证 zsh/Bash、重复安装、rc 符号链接、命令冲突、源脚本移动和卸载，同步运行手册并提交。

追加验证：31 项集成测试全部通过（43.040 秒），Bash 3.2 语法和 ShellCheck 通过；在当前账户执行 `shortcut` 并验证真实 `mm help`，入口与 shell PATH 块已生效。追加规格提交 `915c86a`，实现记录见后续 Git 提交。

## 6. info 追加施工

- [x] T13：追加 R13，明确路径信息、隐私与只读契约。
- [x] T14：实现 `info`，同步帮助、菜单、快捷入口及运行文档，验证未安装/系统模式/订阅隐私及无写操作。

追加验证：33 项集成测试通过（47.445 秒），包含未安装时不创建目录、系统模式路径、运行中带锁只读查询和订阅内容脱敏；Bash 3.2 语法、ShellCheck 和文档检查通过；当前账户实际执行 `mm info` 成功。规格提交 `ae42495`。

## 7. 菜单展示追加施工

- [x] T15：追加 R14，确定分组布局、中文宽度对齐、终端色彩与兼容性。
- [x] T16：实现菜单渲染及帮助选择，执行已有菜单集成验证与真实 PTY 宽/窄终端、颜色禁用检查，更新 mm 和文档。

追加验证：现有菜单集成测试通过（2.009 秒），Bash 3.2 和 ShellCheck 通过；真实 PTY 的 80/40 列、ANSI 配色、NO_COLOR、TERM、stdout 重定向和 h 帮助检查通过。本次仅调整菜单展示及帮助选择，未新增镜像实现的单元测试。规格提交 `1572bfa`。

## 8. 全局输出追加施工

- [x] T17：追加 R15，定义帮助、状态、路径、阶段、结果、错误、日志与输入的统一呈现。
- [x] T18：实现公共输出函数并覆盖各子命令及原生诊断，保持运行行为和隐私契约。
- [x] T19：执行已有集成回归、真实 PTY/纯文本/日志和错误呈现验证，更新 mm、文档及 Git 记录。

追加验证：33 项集成回归通过（47.149 秒），Bash 3.2 与 ShellCheck 通过；真实 macOS 生命周期 smoke 通过；PTY 验证 help/status/info/logs、独立 stderr、NO_COLOR/TERM、重定向、日志内容保持和简化 JSON 诊断。规格提交 `982e4b3`。

## 9. Web 面板配置追加施工

- [x] T20：追加 R16，明确缺省补充、已有字段保留、订阅持久化及失败回滚契约。
- [x] T21：实现 config ui、启用记录与导入补充，更新帮助、菜单和 info。
- [x] T22：验证缺失/已有/嵌套/重复字段、来源保留、幂等、订阅更新、拒绝边界和事务回滚；执行真实内核面板 smoke，更新 mm 和施工记录。

追加验证：39 项集成测试通过（69.908 秒）；补充跨行流式结构拒绝后，6 项 UI 场景回归通过（13.865 秒）。真实 macOS `--ui` smoke 通过：保留动态 API 端口，官方 ZIP 下载后 `/ui/` 返回 HTML，再次导入不含 UI 的配置自动补齐，完整启停/自启/卸载成功。Bash 3.2、ShellCheck 和四份 SDD 文档检查通过；规格提交 `0d00fd5`。

菜单第 17 项的 PTY 分发测试通过（2.386 秒）；已更新当前账户 `~/.local/bin/mm`，实际 help/info 可显示新命令和 UI 记录位置。

## 10. 下载加速追加施工

- [x] T23：追加 R17，核验加速链接格式及 UIUpdater 行为，提交规格与设计。
- [x] T24：实现多源配置/下载/校验回退、UI 包加载及目录事务，更新命令与菜单。
- [x] T25：验证有序回退、损坏包/哈希、代理设置、订阅隔离、路径安全与 UI 目录回滚；真实 macOS 下载及面板 smoke；更新 mm、文档和 Git。

追加验证：46 项集成测试通过（92.708 秒）；菜单 18/19 的 PTY 分发通过（3.971 秒）。真实 macOS `--ui` 与 `--ui --mirror-fallback` smoke 均通过：gh.mlang.cc 下载内核并符合官方 digest、UI ZIP 加载/更新后返回 HTML；首个来源连接失败后实际切换后续来源，完整生命周期通过。Bash 3.2、ShellCheck、四份 SDD 文档检查通过，已更新当前用户的独立 mm 入口。规格提交 `559b7b3`。

最终下载/设置/目录回滚专项 4 项通过（8.516 秒）；ghfast.top 的实际归档 HEAD 请求返回 HTTP 200、application/zip，确认备用前缀格式。

## 11. TUN 简化与启停竞态追加施工

- [x] T26：追加 R18/R19，确定 TUN 一键启用/关闭的权限、拒绝边界与状态记录，提交规格与设计（R02、R04、R18、R19）。
- [x] T27：修复 `bootout` 异步卸载竞态：抽出 `unload_job` 轮询等待，`ensure_running` 统一启动/续跑，重构自启安装复用（R04）。
- [x] T28：实现 `enable-tun` / `disable-tun`、`tun-mode` 记录、`status`/`info` 展示、菜单 20/21 与帮助入口（R18、R19）。
- [x] T29：新增模拟用例并回归，执行真实 macOS smoke（含 5 次运行中事务重启与代理请求），更新 mm 入口与文档（R04、R18、R19）。

新增 7 项模拟用例：`bootout` 异步卸载后仍可重启（回归 `Bootstrap failed: 5`）、非系统模式拒绝 `enable-tun`、无 `tun` 段拒绝、导入并翻转 `enable` 且保留注释、缺失 `enable` 自动插入并先装系统实例、`disable-tun` 停止并移除自启、系统模式菜单第 20 项真实分发。
