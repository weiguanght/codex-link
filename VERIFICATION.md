# 验证记录

## 原生 Codex Remote iOS 客户端

- iOS 已从 WKWebView 替换为 SwiftUI；Mac 上原浏览器界面仍保留。任务首页、新任务输入、项目／会话分页、原生会话流、状态页、审批、Codex 设置与附件分享均使用系统控件及网关 API。
- 对 ChatGPT.app 1.2026.300 的 ChatGPT.framework 按 Codex Remote 符号与本地化字符串定点检查：定位任务首页 composer、任务行状态、最近／项目列表、主机过滤、项目排序／分页、会话状态 sheet 和审批组件。没有复制闭源代码或资源。xref 和有限函数伪代码位于 `build/remote-analysis/`。
- Xcode iOS Simulator **build-for-testing 成功**；原生网关契约 **6 项通过**；Chromium 与 WebKit 网页回归均通过。
- IPv4／IPv6 模拟器 smoke **8 项检查通过**：Keychain、固定 TLS 与错误证书拒绝、认证和 bootstrap、项目／会话列表、只读历史、设置读回、幂等发送／重试、停止及审批响应。
- 原生 UI XCTest **1 项通过**，确认没有 WKWebView，并实际走通任务创建／发送、会话状态、设置草稿放弃确认及新建项目。日志：`build/native-ui-test.log`；结果包：`build/native-ui-20261105-005827.xcresult`。
- arm64 Release **BUILD SUCCEEDED**；已生成 `build/codex-link-0.1.0-unsigned.ipa` 与经 ad-hoc 签名校验的 `build/codex-link-0.1.0-TrollStore.ipa`，校验值见 `build/SHA256SUMS.txt`。未安装真机；TrollStore 安装及真机 Keychain 行为仍待设备验证。
- 完整 Python unittest 收集到 91 项，90 项实际用例通过；唯一导入错误来自仓库缺失的 `清理CodexExec对话.command`。独立跑其他模块期间有两项设置 RPC 的 0.1 秒超时测试受模拟器启动负载影响而失败；完整回归中的这两项通过。没有重建或伪造该删除脚本。
- 本轮未安装真机、未连接生产网关、未改动真实 `~/.codex`、未提交或推送。

## 后续更新：双击直接清理 exec 对话

- 按用户要求改为根目录单文件 `清理CodexExec对话.command`，权限 `0755`；双击直接删除，无预览、备份或确认输入。旧独立 `.py` 入口已移除。
- 内部调用现有 Python 3.10+ 标准库；不复制数据库，不移动日志到备份，不进入废纸篓。仍保留精确来源、路径和关联结构校验。
- 清理专项 **14 项通过**；完整回归 **98 项通过**；独立副本 **98 项通过**。日志 `build/cleanup-command-tests.log`、`build/cleanup-command-standalone.log`。
- 实际 `.command` 仅对合成 HOME 执行，覆盖无 stdin 直接删除、单文件独立运行、WAL、非 exec 保留及不可恢复的部分失败提示。
- 没有对真实数据执行删除、没有自动停止 Codex / 网关或提交推送。网页和 iOS 未修改，本轮不重复浏览器及模拟器验证。


## 历史版本：exec 对话清理 Python 脚本（已由 command 替代）

- 新增 `scripts/cleanup-codex-exec.py`，默认预览，实际执行需确认并先停止写入；SQLite backup API 备份 WAL 一致快照，日志移入私有备份后清除对应数据库及索引记录。
- 新增 13 项临时合成 HOME 测试：精确来源、归档／孤立／缺失／重复日志、关联表／标题索引、WAL、并发变化中止、失败恢复、路径／来源冲突、结构检查和确认要求。
- 完整 Python 回归 **97 项通过**；独立副本 **97 项通过**。日志 `build/cleanup-exec-tests.log`、`build/cleanup-exec-standalone.log`。网页及原生客户端未改动，本轮未重复浏览器和模拟器测试。
- 真实 HOME 仅预览：匹配 304 条 exec 数据库记录、300 个日志文件，4 条已无日志；未执行真实删除，没有停止生产进程或提交推送。
- 使用边界与恢复注意事项见 [exec 对话清理说明](docs/cleanup-codex-exec.md)。

## 后续更新：Codex 设置接口

- 全局默认设置通过 `config/read` / `config/batchWrite` 接入，带版本检查、权限确认、保存后独立回读；项目配置只读，显示来源和限制。
- Skills 列表／开关、模型目录及 MCP 只读摘要已接入。当前会话仍沿用原桌面控制路径，不通过设置进程 resume 或启动 turn。
- Python **84 项通过**，独立副本 **84 项通过**；日志 `build/settings-unittest.log`、`build/settings-standalone.log`。
- Chromium／WebKit 合成端到端回归通过：覆盖保存、冲突草稿、权限取消和确认、技能、MCP、项目只读与 320–1280px。WebKit 日志 `build/settings-webkit.log`。
- 真实 `codex-cli 0.160.0`、一次性空 HOME 的原生契约测试通过：读写／移除覆盖／回读、原生版本冲突、项目只读和技能开关。日志 `build/settings-native.log`。没有读取真实账号、运行模型或改变真实用户配置。
- iOS 一次性模拟器 IPv4／IPv6 回环认证及设置资源加载通过；日志 `build/settings-ios-smoke.log`，结果 `build/ios-smoke-result.json`。没有安装真机。
- 没有自动重启生产网关、改变配对方案、修改 vendor 或提交推送。限制与验收见 [Codex 设置接入](docs/codex-settings.md)。

## 后续更新：项目与会话操作补全

- 新建项目登记、选择／显式创建 Mac 目录、空项目展示、项目内新建对话、项目与会话菜单、排序、多选、置顶、隐藏恢复已接入持久后端。
- 本机桌面会话归档／取消归档通过明确确认调用 Codex RPC；不通过 SQL 篡改归档状态，不为只读历史开放写能力。原始文件永久删除和 AGENTS.md 编辑未实现，不用模拟按钮冒充。
- Python **66 项通过**，独立副本 **66 项通过**；日志 `build/workspace-tests.txt`、`build/workspace-standalone.txt`。
- Chromium／WebKit 合成数据端到端操作回归通过；涵盖创建失败保留表单、目录选择、项目改名／隐藏恢复、指定项目新建对话、会话改名／置顶／归档恢复、多选和只读限制。
- iOS 一次性模拟器验证新增管理入口加载及 IPv4／IPv6 回环认证通过，日志 `build/workspace-ios-smoke.txt`。未重新打包 IPA，未安装真机。
- 上游快照与配对方案不变。没有实际操作用户的项目／会话、没有自动重启生产网关或提交推送。实现边界与验收说明见 [项目与对话操作](docs/workspace-actions.md)。

## 后续更新：对话发现与只读历史

- 本机数据库全来源发现、JSONL 元信息兜底、完整项目索引、正文分页及只读边界已接入。实现与限制见 [对话发现与历史读取](docs/history-reading.md)。
- Python 后端与资源回归 **52 项通过**；空 HOME、无外部上游目录的独立副本同样 **52 项通过**。日志：`build/history-tests.txt`、`build/history-standalone.txt`。
- Chromium／WebKit 在合成 API 下通过完整项目索引、分页、只读无激活／写入、桌面显式日志视图，以及原有草稿、发送失败重试、停止、审批等界面回归。没有向真实 Codex 发消息。
- 一次性 iOS 模拟器：Keychain、固定证书、错误证书拒绝、IPv4／IPv6 回环网页认证，以及 `LinkReading` 和来源筛选控件加载通过。日志：`build/history-ios-smoke.txt`、`build/ios-smoke-result.json`。初次运行在 10 秒 UI 等待内未就绪；测试加入诊断并将等待上限调整到 30 秒后重跑通过，没有放宽 TLS、CSP 或认证。
- 本机仅做元信息聚合：默认集合 1835 条、原桌面可控范围 67 条、其中 1543 条可定位有效日志、347 个历史项目分组。这是变化中的快照，不是完整真实正文验收。
- 内置上游快照及哈希不变；未修改原 `~/.codex` 数据，未重启现有网关，未安装手机或提交／推送。此次读取功能不需重新构建 IPA；重启 Mac 网关并刷新 iOS 页面生效。

以下为此前版本的历史验证记录，测试数量和构建记录保留原值。

## 后续更新：项目更名为 codex-link

- 实际项目目录由 `mac-ios-link` 更名为 `codex-link`。运行中的网关未被中断，旧路径暂时保留为兼容符号链接；停止旧进程并从新路径启动后可删除旧链接。
- 文档、Mac 配对弹窗和启动提示、iOS 显示名称、Xcode 工程／target 名称和 IPA 文件名已统一。
- 内部 Swift 模块／可执行文件仍为 `CodexLink`，Bundle ID `local.codex.link`、签名身份、Keychain 服务、Bonjour 类型及设备协议不变。
- `.local/` 随实际目录移动，没有重新生成证书或配对凭据；重命名前后关键数据文件的 inode 一致。
- 新路径下的运行时检查和隔离环境 **23 项测试通过**，见 `build/rename-standalone-tests.log`。
- 新工程 `ios/codex-link.xcodeproj` 的 arm64 Release **BUILD SUCCEEDED**，见 `build/rename-ios-build.log`。新 IPA：`build/codex-link-0.1.0-TrollStore.ipa`、`build/codex-link-0.1.0-unsigned.ipa`，校验值已更新到 `build/SHA256SUMS.txt`。
- iOS 手机显示名称需要覆盖安装新 IPA 才会更新；本次未执行真机安装，也未重复运行模拟器。

## 后续更新：源码自包含

- 已将上游 1.3.2 所需的 23 个 Python 模块、完整网页与字体资源、原始许可证内置到 `vendor/codex-mobile-bridge/`，共 110 个快照文件（另有 `UPSTREAM.json` 清单）。
- 快照逐文件保留原始字节，SHA-256 由新增测试核对；依赖闭包、静态资源和许可证检查通过。
- `run-mac.py` 和测试默认只使用内置路径。`--bridge` 仅是开发者显式覆盖，没有父目录回退。
- `python3 run-mac.py --check-runtime` 通过：不启动服务、不访问配对数据。
- `python3 scripts/test-standalone.py` **通过**：仅复制运行文件到临时目录，无上游兄弟目录，使用空 HOME、清除外部 Python 配置，以 `python -I -B` 执行运行时检查和全部 **23 项测试**。真实项目及 `.local/` 没有被复制、移动或删除。
- 日志：`build/standalone-tests.log`。未重新构建或修改 iOS IPA，因为 HTTP 协议与客户端未变。
- 检测到已有生产网关正在运行，本次没有停止它或删除旧源码。**请先关闭并重新启动网关，再删除外部上游目录。** 现有 `.local/` 的证书和配对数据保持不变。

以下是首版的历史验证记录；本次没有重复执行模拟器或声称新增真机验证。

## 本次实际完成

### 构建

- Xcode 15.2，iOS 17.2 SDK，最低 iOS 16.0，arm64 Release：**BUILD SUCCEEDED**。
- 输出 `build/codex-link-0.1.0-unsigned.ipa` 与 `build/codex-link-0.1.0-TrollStore.ipa`。
- TrollStore 包添加 ad-hoc 签名及专属 Keychain group；`codesign --verify --strict` 校验通过。
- Release 不包含模拟器 smoke 入口；SHA-256 在 `build/SHA256SUMS.txt`。
- 配对弹窗的 AppleScript 使用 `osacompile` 做了语法检查（没有实际弹窗、没有自动批准真实手机）。

### Python：18 项通过

命令：`python3 -m unittest discover -s tests -v`

- 直接 IPv4 子网判断，IPv4-mapped IPv6 地址规范化。
- 排除 VPN、inactive 网卡、link-local / deprecated IPv6；稳定 IPv6 排在 temporary 地址前。
- 首次批准、拒绝、超时、限制同时出现的确认请求。
- 只持久化随机设备密钥的哈希；凭据文件权限为 0600。
- 凭据持久化及撤销标记重启后有效。
- TLS 上的配对、自动发网页 Cookie、读取 B 的模拟会话列表。
- 禁止匿名读聊天，禁止旧密码／二维码登录路由。
- 拒绝浏览器 Origin、错误 Host、缺失原生请求标记。
- 拒绝不在本机 IPv4 子网中的初次配对，忽略伪造 X-Forwarded-For。
- B 的聊天写请求仍要求正确 Origin 与 CSRF；只对 fake bridge 发送测试请求。
- 撤销后设备凭据和旧 Cookie 都失效。
- 错误设备密钥不能认证；每设备网页会话有数量上限。
- 地址刷新能通过 status 更新，status 不创建新会话。
- 真实 IPv6 回环 TLS，以及首次 IPv6 配对拒绝。

测试没有连接真实 Codex，没有修改聊天、模型、账号或权限。

### iOS 模拟器：通过

命令：`./scripts/test-ios-smoke.sh`

使用一次性的 iPhone SE / iOS 17.2 模拟器、假 Mac 服务和临时证书。

`build/ios-smoke-result.json` 结果：**PASS**。

1. Keychain 读写与删除。
2. URLSession 通过已固定证书连接 IPv4 HTTPS。
3. 错误证书指纹被拒绝。
4. IPv4 上 WKWebView 接收安全 Cookie，加载 B 网页并得到 `authenticated: true`。
5. 切换到 IPv6 回环后再次自动认证，WKWebView 同样得到 `authenticated: true`。

开发中发现模拟器不能直接使用真机式 ad-hoc entitlement 签名；已改为让 Xcode 生成模拟器的 `__TEXT,__entitlements`。真机 TrollStore 包仍使用独立打包流程。测试模拟器已停止并删除。

**这里验证的是 IPv4 / IPv6 回环和真实 WebKit，不是手机移动网络公网可达性。**

## 仍需你的设备验证

- TrollStore 真机安装及 Keychain 可用性。
- iOS 本地网络隐私授权后的 Bonjour 自动发现。
- Mac 上实际首次配对弹窗、iPhone 前后台切换和再次启动免密码连接。
- 路由器 / macOS 防火墙 TCP 18443 放行后的公网 IPv6 可达性。
- 实际 Codex 版本的读取会话、发送、审批、停止、上传及下载。
- 网络切换时 UI 和草稿行为（本版切换来源会重载网页，不承诺保留草稿）。

## 建议验收顺序

1. 打开 Codex 桌面版，启动本目录 `启动Mac网关.command`。
2. iPhone 安装 codex-link 并允许本地网络，在同一 Wi-Fi 自动发现；Mac 点一次允许。
3. 顶栏应显示“局域网 IPv4”。先只检查会话列表，再在专门测试会话发送一条无副作用的消息。
4. 退出并重新打开手机 App：不应再次要求 Mac 确认，不应要求密码。
5. 关闭 iPhone Wi-Fi，使用支持 IPv6 的移动网络：应自动切换为“IPv6 直连”。如果不通，先检查 **TCP 18443**，不要关闭整个防火墙。
6. 最后可用 `--revoke 设备UUID` 验证撤销。重新配对需要手机忘记 Mac 后回到局域网。

本次没有启动生产网关、修改系统证书、修改防火墙或路由器，也没有替换目录中的 A/B 安装包与源码。
