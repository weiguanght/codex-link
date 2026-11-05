# 原生 iOS 客户端

codex-link iOS 使用 SwiftUI 原生界面，通过证书固定的 HTTPS 客户端调用 Mac 网关。iOS 不加载 WKWebView；Mac 浏览器界面仍保留，两者共用设备配对、读取发现和桌面 Codex IPC。

## Codex Remote 参考

参考目标为 `ChatGPT.app` 1.2026.300 的 `ChatGPT.framework`。用 `ida-domain` 对 framework 的 arm64 Mach-O 静态字符串引用进行定点分析，定位到以下 Codex Remote 组件和界面路径：

- `CodexHomeTaskList`、`CodexHomeStartContent`、`CodexHomeDraftContent`：任务首页及新建任务输入区。
- `CodexRemoteTaskRowContent` 与 `CodexRemoteTaskRowTrailingStateIndicatorsPart`：任务行和状态提示。
- `CodexRemoteThreadListFilterMenuContent`、`CodexRemoteHostFilterButton`、`CodexRemoteHostFilterRow`：列表组织及主机筛选。
- `CodexRemoteProjectSortOrder`、`CodexTaskListProjectPagination`：项目排序和分页。
- `CodexRemoteStatusSheet`、`CodexRemoteThreadView`、`CodexRemoteComposerState`：任务状态、对话和输入流程。
- 字符串引用定位到最近排序、项目任务加载更多、重命名、审批卡片和后续消息行为等 UI 路径。

源二进制是闭源 framework；本项目没有复制其实现或资源。定点 xref 和反编译代码片段保存在本次工作区 `build/remote-analysis/`，可用其中 `workdir.txt` 找到 IDA 临时工作目录。新的完整证据导出位于相邻 `Payload/ChatGPT.app/codex-remote-analysis/full/`；本轮源码映射、Serena 用法和新增行为见 [复刻工程进展](reverse-reconstruction.md)。上述组件证据支持交互结构参考，不用于声称像素级复刻；视觉细节根据 iOS 系统控件和可访问性尺寸重新实现。

## 原生实现

- 首页按最近任务／项目浏览；任务列表服务端分页，每页最多 100 项，提供更多加载和项目钻取。
- 会话页用原生消息、折叠执行过程、待审批请求、运行状态、停止操作和 composer。
- 自动滚动只响应实际可见消息变化；上翻历史时暂停跟随，空轮询不改变阅读位置。点击“回到最新消息”或主动发送后恢复跟随。
- 回复中的 Markdown 链接以蓝色下划线显示。本机文件引用支持中文、空格、编码路径及行号后缀，点击后通过当前会话的已授权文件 ID 下载，打开系统分享面板；文件过期或不在可下载列表时显示错误。
- 命令、MCP、动态工具与文件变更显示独立输入／输出区，命令和参数使用代码语法着色；状态、失败退出码、耗时和输出均可扫读。终端 ANSI SGR 前景色与粗体保留，OSC 和光标控制码被移除。
- 文件预览使用本地 Runestone／Tree-sitter 编辑器，支持 Swift、Rust、Python、Bash、JS／TS、JSON、YAML、TOML、C、HTML、CSS 与 Markdown 语法高亮、行号、折叠、搜索和换行。完整 UTF-8 文件可编辑；最大 128 KiB，按 Mac 原子保存，基于读取修订值拒绝覆盖冲突。文件 BOM、权限位和换行符按原样保留。Markdown 可切换源码／渲染视图。
- 输入区的模型入口打开“模型与推理”，推理强度使用下拉菜单，优先采用所选模型目录提供的选项；切换模型保留兼容强度，否则采用模型默认值。目录没有强度信息时保留旧版通用选项作为回退。
- 本机桌面会话的文件夹入口提供工作区浏览、文件名搜索、文本预览、已暂存／未暂存差异，以及路径与评论回填，见 [工作区使用说明](workspace-browser.md)。
- 按钮、菜单、sheet、项目目录选择器、文件导入、分享、设置均为系统原生控件。
- iOS 的 JSON API 是版本化读取投影 `/api/native/v1`；已有的会话、设置和项目接口继续执行写操作，不代理任意 RPC。
- 文件编辑仅开放于已认证并通过 CSRF 校验的本机可控会话；以工作区相对路径和文件修订散列限制读写，只接受单链接 UTF-8 普通文件，读写上限 128 KiB，不提供任意文件访问或命令执行。文件预览编辑需要随 IPA 更新并重启 Mac 网关。
- URLSession 使用配对期间固定的 TLS 证书；Cookie 仅驻留内存。局域网 IPv4／外出 IPv6 仍由现有发现和地址选择逻辑管理。

## 保留边界

- 非桌面来源和显式日志视图为只读，不恢复桌面执行 owner。
- 命令、文件和权限审批及用户输入可在手机处理；computer-use、部分 MCP／结构化请求与计划批准仍由 Mac 处理。
- 未发送草稿按配对身份、主机和会话保存在本机；恢复时不自动发送，附件需重新选择。文字消息未确认时保留 payload 与请求 ID，供核对后重试。详见 [复刻工程与行为证据](reverse-reconstruction.md)。
- Markdown 覆盖常用标题、列表、行内格式、链接和代码区块；表格与数学公式不在当前排版范围。
- 创建任务、浏览完整项目目录、覆盖 IPA 安装和账号切换之外的账户管理仍受现有 Mac 网关能力约束。

## 验证

Runestone 与 TreeSitterLanguages 按固定版本源码随工程集成：Runestone 与所选语法包许可及来源 SHA-256 见 `ios/Packages/Runestone/`。随包提供 15 种所选语法，不在构建时联网解析依赖。

运行 `bash scripts/test-ios-smoke.sh` 做隔离 IPv4／IPv6 网络、Keychain 与原生 API 冒烟。运行 `LINK_UI_TEST=1 bash scripts/test-ios-smoke.sh` 额外验证工具、代码、文件编辑／保存、历史滚动和工作区流程。fixture 使用临时 HOME、TLS 服务与合成会话，不读取实际 `~/.codex`。

IPA 构建使用 `bash scripts/build-ios.sh`。原生 UI 必须覆盖安装新 IPA；Bundle ID、Keychain service/account 和配对凭据标识不变，不需重新配对。

文件链接与强度菜单的修复仅涉及 iOS 客户端，使用现有文件下载与会话设置接口，不需要为这两处修复更新 Mac 网关。
