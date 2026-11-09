# codex-link

**让 iPhone 接着使用 Mac 上的 Codex：局域网自动发现，首次确认后免输密码，外出通过 IPv6 直连。**

codex-link 是一个基于 [codex-mobile-bridge](https://github.com/try2love/codex-mobile-bridge) 二次开发的社区项目，由 **Mac 网关、iOS 客户端和共享聊天网页**组成。任务仍由电脑上的 Codex 执行，手机负责查看会话、发送消息和处理交互。

当前版本：**0.1.0**。当前实现面向 **macOS + iOS**，不是已经完成五端适配的通用客户端。

项目目录、Xcode 工程与 App 显示名称统一为 **codex-link**。内部 Swift 源码目录／模块名 `CodexLink`、Bundle ID `local.codex.link`、Keychain 标识和设备协议保持不变，以兼容已安装客户端及已有配对。

> 本项目与 OpenAI 无隶属关系，不包含 Codex Desktop，不提供模型账号、API 密钥或模型额度。构建和自动测试通过，不代表已经完成所有真机与网络环境的验证。

[快速开始](#快速开始) · [对话读取](docs/history-reading.md) · [Codex 设置](docs/codex-settings.md) · [平台支持](#平台支持) · [构建与测试](#构建与测试) · [安全与限制](#安全与限制) · [验证记录](VERIFICATION.md)

## 项目特点

- **自动发现**：通过 Bonjour/mDNS 寻找同一局域网中的 Mac；发现一台时自动发起配对，多台时手动选择。
- **无需扫码或密码**：首次只需在 Mac 上点一次“允许”，后续使用设备凭据自动认证。
- **内外网切换**：优先局域网 IPv4，不可用时尝试已保存的公网 IPv6；不需要域名或中转服务。
- **地址自动同步**：连接成功后同步 Mac 地址，优先记录非临时公网 IPv6。
- **设备身份绑定**：iOS 使用 Keychain 保存凭据与证书指纹；后续连接拒绝不匹配的证书。
- **原生 Codex Remote 工作流**：iOS 用 SwiftUI 呈现任务首页、项目与会话、执行过程、审批和输入区；通过固定版本的网关 API 获取数据，继续复用既有设备认证和 Codex Desktop IPC。
- **更完整的本机历史**：数据库与 JSONL 元信息结合发现，支持来源／归档／内部会话筛选；项目索引不受前 100 条限制，正文按页读取、长消息分段展开。
- **阅读与控制分离**：CLI、exec 等历史只读，不自动恢复任务；原桌面会话仍走原 IPC 控制边界，也可切换到只读日志视图。
- **项目与会话操作**：新建项目、浏览 Mac 目录、项目内新建对话、独立操作菜单、排序、多选、置顶与隐藏恢复；本机桌面会话支持归档／取消归档。
- **真实 Codex 设置**：全局默认模型、推理、搜索、权限与开发者指令可保存并回读；支持技能开关、项目配置来源和 MCP 只读状态。
- **命令与差异详情**：消息中命令只占一行，点击后在统一详情页查看完整命令和输出，均无行号；支持自动换行设置。文件变更以独立页面按文件渲染语法着色、增删底色和统计。
- **文件分享**：iOS 支持前台文件下载后调用系统分享菜单。
- **会话工作区**：原生浏览／搜索会话目录、预览并编辑 UTF-8 文本文件、查看 Git 未暂存／已暂存差异；路径与文件评论可追加到输入草稿。文件写入有 128 KiB 上限和修订冲突检查。使用方法与边界见 [工作区浏览与差异](docs/workspace-browser.md)。此功能需同时更新 Mac 网关和 iOS。
- **交互边界**：CLI／exec 来源默认按只读历史打开，可转换的本机会话在后台转换后刷新；需在 Mac 确认的高级审批仍引导用户到桌面处理。原生 Markdown 支持常用段落、列表、链接、代码块与表格，暂不支持数学排版。
- **源码自包含**：运行所需的上游 Python 模块、网页、字体及许可证已内置，不依赖旁边的其他项目目录。

“免密码”指用户不需要输入密码，**不是允许任何人匿名控制电脑**。

## 移动端界面

新增完全原生的 SwiftUI iOS 客户端：任务首页、最近任务／项目视图、分页列表、状态详情、原生消息流与执行过程、审批、模型设置、附件分享和系统配置。Mac 上的共享网页保留给浏览器使用；iOS 不再通过 WKWebView 套壳。

消息支持 Markdown 表格；主动向上翻阅至距顶部约 8 条消息时，后台静默预取更早记录，按消息 ID 与屏幕偏移补偿插入高度；仅抵达顶部仍在等待时显示小型加载器。对话文件与回复引用中的图片、文本优先使用应用内预览，图片可保存到相册，其他文件类型使用系统打开面板。工作区文件菜单位于页面右上角。消息页右上角「···」使用系统默认宽度和外观的菜单，集中工作区、模型与发送设置；空输入框显示上下文占用，发送按钮长按可选择仅本次的发送方式。消息长按保留文本选择，复制／分享／分支使用下方按钮。

[查看原生界面与验证说明](docs/native-ios.md) · [复刻工程进展与反编译证据](docs/reverse-reconstruction.md)。原生客户端需要重新构建并覆盖安装 IPA；保留相同 Bundle ID 和钥匙串条目，不需重新配对。

上下文和会话 Token 统一用 K／M 显示。上下文与 CLI `/status` 读取同一组用量字段，界面百分比为已用／窗口原始比例。会话详情按各轮模型与服务档位统计 API 参考费用，可展开明细；缓存输入单独计价，推理不重复收费。价格快照来自 [OpenAI 官方价格页](https://developers.openai.com/api/docs/pricing?latest-pricing-expanded=true)，2026-11-09 更新，覆盖 29 个模型。未知模型、缺失档位或无法完整计价时明确提示，不将部分金额当总额。

在项目根目录运行 `python3 scripts/update-pricing.py` 可通过用户指定的 Jina 地址更新价格快照，下载或解析失败会保留旧文件；新版网关会按文件变更重新载入价格。首次启用本轮统计需要重启 Mac 网关并安装新版 IPA。费用采用公开短上下文 API 价格，不是订阅账户账单，未包含工具、长上下文、地区等附加费用；缓存写入缺少保留时长时不估价。

## 对话读取

本机默认展示全部来源的未归档、非内部会话。数据库 `threads` 为主要元信息来源，递归扫描 `sessions/`、`archived_sessions/` 补全发现，打开历史时按需读取 JSONL 正文。

- **项目页**展示完整筛选集合的项目分组和数量，点击项目进入分页列表。
- **只读历史**不会连接执行 owner，输入框和写操作不可用；缺失日志会明确提示，不能恢复已删除的正文。
- **桌面会话**保留原有交互；详情中的“只读查看完整日志”可查看日志而不额外恢复任务。
- 扩大发现范围仅适用于当前 Mac；SSH 主机暂保留原上游桌面范围。搜索还不支持正文全文检索。

列表扩展仍由 Mac 网关提供；原生 iOS 更新需覆盖安装 IPA。原有设备凭据与配对状态保留。

数据源、只读边界、性能限制与验收步骤见 [对话发现与历史读取](docs/history-reading.md)；改造前诊断见 [列表不完整分析](docs/session-discovery-analysis.md)。

## 项目与会话管理

工作空间标题旁点 **「＋ 项目」**，输入名称并选择 Mac 目录。默认添加已有目录；勾选后才创建新文件夹。空项目也会展示，并可直接在该目录新建对话。

项目和会话旁的 **「···」** 提供各自操作；**「筛选与排序」** 中可切换归档／隐藏列表、排序与多选。原生菜单支持重命名、置顶、未读、项目归属、分支、复制深层链接／Markdown／工作目录、归档和永久删除。只读历史可以整理列表和复制；本机只读会话支持二次确认永久删除，包括仅存 JSONL 的历史。只读会话仍不能重命名原始对话、分支或归档。

项目登记、置顶、未读、项目归属与隐藏等偏好保存在 `.local/workspace.json`，不直接改写 Codex Desktop 项目配置或原工作目录。永久删除仅针对二次确认的本机会话 ID，先在 `.local/deletion-backups/` 备份对应记录；隐藏仍只影响列表，不删除数据。详情和能力差异见 [项目与对话操作说明](docs/workspace-actions.md)。

## Codex 设置

在工作空间底部 **Codex 设置**，或 **界面设置 → Codex 默认行为、Skills 与 MCP** 中打开。全局配置通过原生 app-server 接口保存，带版本校验与回读；失败保留草稿，权限变更需再次确认。

项目有效配置当前只读：本机 0.160.0 原生接口拒绝项目配置写入。技能开关是用户级设置；MCP 是查询进程的只读状态。保存不热更新或接管当前桌面会话，桌面可能需重新加载配置。支持范围与验收见 [Codex 设置说明](docs/codex-settings.md)。

原生 iOS 更新需覆盖安装 IPA；同一安装身份保留已有配对。设置能力仍按网关版本和 Codex Runtime 返回结果显示。

## 平台支持

| 平台 | 当前状态 | 说明 |
| --- | --- | --- |
| macOS | 已有网关启动入口 | 通过 Python / `.command` 运行；尚无独立 `.app` 或 `.dmg` 打包流程 |
| iOS / iPadOS | 已有原生源码与 IPA 构建流程 | SwiftUI / URLSession / Network / Keychain，最低 iOS 16.0；真机安装及兼容性仍需验证 |
| Windows | 尚未完成适配 | 上游保留部分 Windows 通信实现，但本项目启动器、配对和网络发现依赖 macOS |
| Linux | 尚未完成适配 | 需要系统适配，并验证目标 Codex 运行方式与 IPC |
| Android | 尚未实现 | 当前没有 Android 客户端源码或构建工程 |

共享 Python 网关和网页可以复用，但不能仅更换打包目标就得到五端应用。当前不包含上游 Electron 桌面壳。

## 工作原理

```text
                    iPhone / iPad
                    原生 SwiftUI
                        │
              首次局域网自动发现
              Mac 确认 → 保存设备凭据
                        │
           ┌────────────┴────────────┐
           │                         │
      局域网 IPv4                公网 IPv6
       优先使用                 已保存地址
           │                         │
           └────────────┬────────────┘
                        │ HTTPS + 设备认证
                        ▼
                Mac Python 网关
                    原生 IPC
                        │ Unix Socket
                        ▼
                  Codex 桌面版
```

- Mac 广播服务类型为 `_codexlink._tcp`。
- 初次配对只允许通过 Mac 直接连接的 IPv4 局域网，公网 IPv6 不接受首次配对。
- 手机在前台每 15 秒触发连接探测，网络变化和返回前台也会尝试连接；实际切换时间受网络超时影响。
- 认证后原生 API 与浏览器网页共用网关设备会话 Cookie；原生 POST 继续提交 Origin 和 CSRF 校验。
- 自动重连不会重发聊天消息、审批或其他 Codex 写操作。

## 环境要求

### Mac 运行环境

- macOS，能够显示首次配对确认弹窗的用户会话。
- Python **3.9+**。
- 已安装并能正常使用的 **Codex 桌面版**及其所需账号配置。
- macOS 系统工具：`dns-sd`、`osascript`、`ifconfig`、`openssl`。
- Mac、Codex 和网关在使用期间保持运行；外网访问时电脑不能休眠或断网。

网关 Python 代码只依赖标准库，正常运行不需要 `pip install`、Node.js、npm 或 Electron。源码自包含不表示捆绑了 Python、系统工具或 Codex。

### 手机与网络

- iOS / iPadOS **16.0+**，arm64 设备。
- 使用适合自己设备的 IPA 安装方式；TrollStore 本身还受设备和系统版本限制。
- 首次配对时，手机与 Mac 位于可以互访的同一 IPv4 局域网，并允许 App 访问本地网络。
- 外网直连需要 Mac 拥有可达的公网 IPv6，且手机当前网络支持访问该 IPv6。

编译 iOS 需要完整 Xcode。已记录的构建环境为 **Xcode 15.2 / iOS 17.2 SDK**，不承诺其他工具链版本已验证。

## 快速开始

以下命令均在 `codex-link` 项目根目录执行。

### 1. 检查内置运行时

```sh
python3 --version
python3 run-mac.py --check-runtime
```

正常输出的运行时路径应指向本项目内的：

```text
vendor/codex-mobile-bridge
```

`--check-runtime` 不启动网络监听，也不读取配对数据。

### 2. 启动 Mac 网关

先打开 Codex 桌面版，然后双击 [启动Mac网关.command](启动Mac网关.command)，或运行：

```sh
python3 run-mac.py
```

默认提供 **HTTPS，TCP 18443**，同时监听 IPv4 和 IPv6。终端会显示当前地址。保留这个进程，按 `Ctrl-C` 停止。

如果 macOS 防火墙询问 Python 的传入连接，请按需要允许。程序不会自动关闭防火墙、修改路由器、设置开机启动或阻止电脑休眠。

### 3. 安装 iOS 客户端

构建产物位于 `build/`：

| 文件 | 用途 |
| --- | --- |
| `codex-link-<版本>-TrollStore.ipa` | 带 ad-hoc 签名及专属 Keychain 组，供已有 TrollStore 环境测试 |
| `codex-link-<版本>-unsigned.ipa` | 未签名产物，需按自己的安装方式处理签名 |
| `SHA256SUMS.txt` | 上述两个 IPA 的 SHA-256 校验值 |

如果目录中没有 IPA，请先按下文的构建步骤生成。`build/` 默认不纳入版本控制，本文不假设已有在线发布下载地址。

App 显示名称为 **codex-link**，Bundle ID 为 `local.codex.link`。TrollStore 包不是 Apple 开发者签名，不申请 root、绕过沙盒或访问任意 Keychain 组的权限；安装及真机 Keychain 行为仍需验证。

### 4. 首次连接

1. 手机加入 Mac 所在的局域网，打开 codex-link。
2. 允许“本地网络”访问。
3. 等待自动发现；如果有多台 Mac，选择需要连接的一台。
4. 确认是自己的手机后，在 Mac 弹窗中点一次 **“允许”**。
5. 手机进入原生任务首页，顶栏显示工作区与 Mac 会话状态。

首次连接不需要手动填写地址、扫码或输入密码。建议先只检查会话列表，再在专门的测试会话中验证消息与审批操作，避免干扰正在执行的任务。

### 5. 外网 IPv6 连接

出门前，在客户端设置页确认已经保存 Mac 的公网 IPv6，并在 macOS／路由器的 IPv6 防火墙中按需放行 **Mac 的 TCP 18443**。不要关闭整个防火墙。

关闭手机 Wi-Fi 后，App 会尝试保存的 IPv6 地址。**能 ping 通 IPv6，不代表 TCP 18443 已经可达。**

本项目不使用域名、DDNS、云端地址发现服务或 IPv4 中转。如果外出期间 Mac 的 IPv6 或运营商前缀变化，手机可能无法再连接；需要回到局域网同步新地址。

## 启动参数

```sh
python3 run-mac.py --help
```

| 参数 | 默认值／作用 |
| --- | --- |
| `--port` | `18443`，HTTPS 监听端口 |
| `--codex-home` | 使用 `CODEX_HOME` 环境变量；未设置时为 `~/.codex` |
| `--data` | 项目下 `.local/`，保存证书、设备授权与网关状态 |
| `--check-runtime` | 只检查运行时依赖，不启动网关 |
| `--list-devices` | 列出已授权及已撤销的设备 |
| `--revoke DEVICE_ID` | 撤销指定设备的授权 |
| `--bridge PATH` | 开发者显式覆盖内置运行时路径，普通使用无需指定 |

示例：

```sh
python3 run-mac.py --port 18443 --codex-home ~/.codex
```

请尽量固定端口。如果在手机无法连接时更换端口，保存的外网入口也会失效。

## 设备管理与备份

### 查看和撤销设备

```sh
python3 run-mac.py --list-devices

# 把 DEVICE_UUID 替换成上一步列出的设备 ID
python3 run-mac.py --revoke DEVICE_UUID
```

如果启动时使用了自定义 `--data`，管理命令也要指定同一数据目录。

撤销标记运行中生效：后续设备认证和旧 Cookie 的新请求都会失效，SSE 在下一轮检查时关闭；已经开始的下载或响应不保证立即中断。被撤销的设备 ID 不会自动恢复授权，需要手机“忘记此 Mac”后生成新凭据，在局域网重新配对。

手机上的“忘记此 Mac”只清除客户端记录，**不等于在 Mac 上撤销旧授权**。

### 数据位置

默认保存在项目的隐藏目录 `.local/`：

| 文件／目录 | 内容 |
| --- | --- |
| `server.key`、`server.crt` | Mac 的 TLS 私钥与证书 |
| `identity.json` | 稳定的服务身份 |
| `devices.json` | 设备记录及随机设备凭据的哈希 |
| `revoked/` | 设备撤销标记 |
| `auth-sessions.json` | 网页会话与访问控制状态 |
| `bridge/` | 网关工作状态 |
| `workspace.json` | 新建项目登记、显示名称、置顶、未读、项目归属与隐藏等列表偏好 |

凭据文件使用 `0600` 权限，新建私有目录使用 `0700` 权限。手机侧凭据保存在 Keychain。

**备份时应保护整个 `.local/`，不要把它提交到仓库、打进分发包或附在问题反馈中。** 不要随意删除或重新生成证书；已配对手机会拒绝不同的 Mac 身份。

## 源码自包含与迁移

运行所需的上游依赖位于 `vendor/codex-mobile-bridge/`，约 **2.5 MB**，包括 23 个 Python 模块、完整网页资源、字体及原始许可证。

- 不需要父目录保留 `codex-mobile-bridge-1.3.2/`。
- 不依赖原上游的 Electron 安装包，也不依赖 `codex-mobile-assistant` 的 Windows EXE 或手机安装包。
- 移动项目时，停止网关，再移动整个 `codex-link/`，包括自己的 `.local/`；自定义数据目录需另外保留。
- 从早期外部依赖版本升级时，应先重启网关，确认使用内置路径，再删除外面的旧源码目录。
- 仅改变源码依赖位置不改变客户端协议，不需要因此重装 iOS App 或重新配对。

默认启动没有父目录回退或自动联网下载依赖的逻辑。

从旧目录名 `mac-ios-link` 更名时，如果有网关正在运行，旧路径可能暂时保留为指向 `codex-link` 的兼容符号链接，不是第二份源码。停止旧进程并从新目录重新启动后，可以删除这个旧链接；不要删除它指向的真实目录。已有 `.local/` 无需重建。手机上的旧 App 名称只有覆盖安装新 IPA 后才会更新，不要为了改名先卸载并清除数据。

## 技术栈与目录结构

| 部分 | 技术 |
| --- | --- |
| Mac 网关 | Python 标准库、HTTPS、设备认证、Bonjour/mDNS |
| Codex 通信 | 内置上游网关、Unix Socket、会话数据读取 |
| 聊天网页 | 原生 HTML / CSS / JavaScript，SSE／轮询 |
| iOS 客户端 | Swift / SwiftUI、URLSession、Network、Keychain、证书绑定 |
| 构建 | Python 辅助脚本、Xcode / xcodebuild、codesign |

```text
codex-link/
├── run-mac.py                     # Mac 启动及设备管理入口
├── 启动Mac网关.command            # 双击启动入口
├── mac/
│   ├── runtime.py                 # 内置运行时定位
│   ├── network.py                 # 网卡发现和局域网判断
│   ├── devices.py                 # 配对确认、凭据哈希、撤销
│   ├── web_ui.py                  # 组合上游页面与第一方界面资源
│   ├── history_catalog.py         # 本机发现、能力判定与完整项目索引
│   ├── history_reader.py          # 只读 JSONL 正文分页与长消息
│   ├── history_http.py            # 历史接口与只读写操作保护
│   ├── native_http.py             # 原生客户端状态、模型、使用量与设置接口
│   ├── pricing.py                 # 模型价格快照读取与费用估算
│   ├── workspace.py               # 项目登记、列表偏好和目录浏览
│   ├── workspace_reader.py        # 工作区文件、Git 仓库与差异读取
│   ├── workspace_http.py          # 项目管理、会话整理、归档与确认删除接口
│   ├── session_delete.py          # 精确清理单个会话及对应记录的恢复备份
│   ├── data/model-pricing.json    # 官方模型价格快照
│   └── server.py                  # TLS 双栈服务及设备认证适配
├── ios/
│   ├── CodexLink/                 # Swift 客户端及资源
│   ├── codex-link.xcodeproj/       # Xcode 工程
│   └── TrollStore.entitlements    # TrollStore 专用签名配置
├── vendor/codex-mobile-bridge/    # 固定版本上游运行时与网页
├── web/                           # 第一方 UI 与历史读取交互，无外部依赖
├── docs/                          # 界面说明、预览、历史读取及问题分析
├── scripts/                       # 构建、价格快照维护及隔离测试脚本
├── tests/                         # 配对、接口、资源完整性测试
├── build/                         # 构建产物和日志，不提交
├── .local/                        # 私有运行数据，不提交或分发
├── VERIFICATION.md               # 详细验证记录
├── THIRD_PARTY_NOTICES.md         # 第三方组件声明
└── LICENSE
```

## 构建与测试

### 构建 iOS IPA

在已安装完整 Xcode 的 Mac 上执行：

```sh
./scripts/build-ios.sh
```

脚本从 `Info.plist` 读取版本，生成图标和 Xcode 工程，编译 arm64 Release，并输出未签名与 TrollStore 两种 IPA。脚本检查归档完整性和 TrollStore ad-hoc 签名，成功后原子更新 IPA 与 `SHA256SUMS.txt`。无需 CocoaPods、npm 或 xcodegen。

也可以打开 `ios/codex-link.xcodeproj`。采用普通 Apple 签名时，请配置自己的开发者 Team 和适用的 Bundle ID／签名设置，**不要把 `TrollStore.entitlements` 中的合成身份当作真实开发者身份使用**。

Xcode 工程由 `scripts/generate-project.py` 生成；需长期保留的构建设置应同步修改生成脚本，避免下次构建覆盖手动修改。

### 后端与隔离测试

```sh
# 配对、认证、CSRF、IPv6、历史读取和快照完整性测试
python3 -m unittest discover -s tests -v

# 在没有上游目录、空 HOME 的独立副本中再次验证
python3 scripts/test-standalone.py
```

这些测试仅使用回环监听、假 Codex 和临时数据，不向真实 Codex 发消息。隔离测试不会复制 `.local/`，也不会搬动正在使用的项目。

### iOS 模拟器测试

需要 Xcode 中安装可用的 iOS Simulator Runtime：

```sh
./scripts/test-ios-smoke.sh
```

默认创建一次性模拟器，验证 Keychain、证书绑定、错误证书拒绝，以及原生 API 在 IPv4／IPv6 回环下的认证、会话与设置读写。`LINK_UI_TEST=1 bash scripts/test-ios-smoke.sh` 还会运行 SwiftUI 原生交互 UI 测试。测试使用临时合成会话，不连接用户的 Codex；不验证真实蜂窝网络或路由器可达性。

### 已记录的验证结果

| 验证项目 | 结果 |
| --- | --- |
| iOS arm64 Release 构建 | 通过 |
| TrollStore 包 ad-hoc 签名完整性检查 | 通过，不代表真机安装已验证 |
| 全量 Python 后端、历史读取、项目操作、设置与工作区测试 | 132 项通过（2026-11-09，隔离环境） |
| 无外部上游目录的隔离运行测试 | 通过 |
| Chromium / WebKit 模拟会话 UI 回归 | 通过，详见界面说明 |
| iOS 模拟器 Keychain、固定证书、IPv4／IPv6 原生 API 冒烟 | 通过 |
| 真机 Bonjour、配对弹窗、蜂窝 IPv6、实际 Codex 操作 | 尚需设备与环境验证 |

详细范围与历史记录见 [VERIFICATION.md](VERIFICATION.md)。历史读取测试使用合成日志；本机数量排查仅读取元信息，不代表真实完整对话或真实发送操作已验收。

## 安全与限制

### 安全边界

- **仅在可信局域网首次配对。** 初次信任依赖 Bonjour 中的身份信息与 Mac 本地确认，属于 TOFU（首次使用时建立信任），不能保证抵御恶意局域网的首次中间人攻击。
- 后续连接绑定已保存的证书，不自动接受替换证书，也不全局忽略 TLS 错误。
- 设备认证请求不跟随重定向；Mac 不信任外部伪造的转发 IP 头来判断局域网资格。
- 网页接口保留同源和 CSRF 校验，旧密码／二维码登录入口在此适配服务中禁用。
- 授权手机能操作 Codex 及其有权访问的项目，设备丢失时应及时撤销授权。不要批准不认识的配对请求。

### 当前限制

- 客户端一次保存并控制一台 Mac；切换 Mac 需要忘记旧记录并重新配对。
- IPv6 变更后无法保证从外网找回新地址，IPv4-only 外部网络没有中转兜底。
- Mac 必须保持在线；本版没有开机自启、后台常驻服务安装或自动防休眠。
- iOS 进入后台后不保证维持连接；没有后台通知或后台文件续传。
- 设备地址切换可能中断正在进行的请求；文本草稿按配对、主机和会话保存在本机，恢复时不自动发送，附件需重新选择。
- 文件能力沿用上游边界，不是其他手机助手项目完整文件管理和断点续传功能的复刻。
- Codex 桌面版接口变化可能导致不兼容；本项目不能保证支持所有 Codex 版本。
- 历史日志缺失无法恢复正文；未知日志格式、超大单条记录及特别大的活跃日志可能影响读取，详见 [读取限制](docs/history-reading.md#性能与格式限制)。

## 常见问题

### 找不到 Mac

检查 Mac 网关是否运行、手机本地网络权限是否开启，以及两端是否在可互访的局域网。访客 Wi-Fi、AP 隔离、VPN 或多播过滤可能影响 Bonjour。Mac 可以有线连接、手机使用 Wi-Fi，只要网络允许互通。

### 配对被拒绝或超时

确认 Mac 的弹窗没有被忽略。必要时在手机设置页“忘记此 Mac”后重新发现。服务有配对限频，连续尝试失败后应等待一段时间再试，不要持续重复提交。

### 局域网可以用，外网不通

确认手机已保存公网 IPv6、Mac 仍在线、当前 IPv6 未变化，并检查 TCP 18443 的入站规则和手机网络的 IPv6 路由。仅测试 ping 不足以确认服务可达。

### 出现证书不匹配

先确认连接目标和网络是否可信，检查是否更换了 Mac 或删除过 `.local/`。不要通过忽略证书校验解决。确需更换身份时，回到可信局域网重新配对。

### 能连接网关，但无法读取或控制 Codex

检查 Codex 桌面版是否正常运行、`CODEX_HOME`／`--codex-home` 是否正确，以及当前 Codex 版本与上游 IPC 是否兼容。优先在独立测试会话中排查。

### 可以直接用浏览器打开地址吗

本适配入口面向已配对的原生客户端，使用客户端绑定的证书和设备凭据。普通浏览器没有配对凭据，不能把该地址当作无需认证的控制页面。

## 后续跨平台方向

以下是可继续开发的方向，**不是当前已提供的功能或交付承诺**：

- Windows／Linux 的网卡发现、mDNS、配对确认、进程锁、证书与数据目录适配。
- macOS／Windows／Linux 桌面壳、内置 Python 和安装包构建。
- Android 客户端的设备发现、安全存储、证书绑定、WebView 与文件分享。
- 各平台 CI、签名、升级机制和真实 Codex 兼容性测试。

建议继续共享 Python 网关、设备协议和网页界面，将操作系统差异放在独立适配层，避免重写聊天核心。

## 二次开发与上游维护

当前内置上游版本为 **codex-mobile-bridge 1.3.2**。文件来自随项目提供的本地源码快照，保留原始字节及许可证，没有联网核验远端 tag。

- 优先在 `mac/`、`ios/` 中修改本项目逻辑，保持设备认证和证书校验边界。
- 修改协议后，应同时检查客户端、网关、CSRF 与撤销行为，并更新测试和文档。
- 上游快照清单及 SHA-256 位于 `vendor/codex-mobile-bridge/UPSTREAM.json`；本地哈希用于检测文件变化，不是来源真实性证明。
- 正常使用不需要重新生成快照。维护者可明确指定经过审查的上游源码，输出到新目录：

```sh
python3 scripts/vendor-bridge.py /path/to/upstream-source --output /path/to/new-snapshot
```

脚本当前只接受 1.3.2，拒绝原地覆盖。升级其他版本需要审查依赖、动态资源和 Codex 协议，再完成回归测试；不要直接覆盖正在运行的网关代码。

反馈问题时，请提供操作系统、iOS、Python／Xcode、Codex 版本及脱敏后的错误信息；**不要上传私钥、设备凭据、会话 Cookie、Codex 账号文件或完整 `.local/`**。

## 致谢与许可证

感谢 [try2love/codex-mobile-bridge](https://github.com/try2love/codex-mobile-bridge) 提供开源的 Codex 手机网关。项目的使用场景也参考了 [Abyxs/codex-mobile-assistant](https://github.com/Abyxs/codex-mobile-assistant)；本项目没有复制其闭源程序代码，也不依赖其安装包。

本项目新增代码采用 [MIT License](LICENSE)。内置上游及 markdown-it、KaTeX、markdown-it-texmath 等组件保留各自的原始版权与许可证，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
