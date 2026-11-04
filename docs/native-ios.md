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

源二进制是闭源 framework；本项目没有复制其实现或资源。定点 xref 和反编译代码片段保存在本次工作区 `build/remote-analysis/`，可用其中 `workdir.txt` 找到 IDA 临时工作目录。上述组件证据支持交互结构参考，不用于声称像素级复刻；视觉细节根据 iOS 系统控件和可访问性尺寸重新实现。

## 原生实现

- 首页按最近任务／项目浏览；任务列表服务端分页，每页最多 100 项，提供更多加载和项目钻取。
- 会话页用原生消息、折叠执行过程、待审批请求、运行状态、停止操作和 composer。
- 按钮、菜单、sheet、项目目录选择器、文件导入、分享、设置均为系统原生控件。
- iOS 的 JSON API 是版本化读取投影 `/api/native/v1`；已有的会话、设置和项目接口继续执行写操作，不代理任意 RPC。
- URLSession 使用配对期间固定的 TLS 证书；Cookie 仅驻留内存。局域网 IPv4／外出 IPv6 仍由现有发现和地址选择逻辑管理。

## 保留边界

- 非桌面来源和显式日志视图为只读，不恢复桌面执行 owner。
- 命令、文件和权限审批及用户输入可在手机处理；computer-use、部分 MCP／结构化请求与计划批准仍由 Mac 处理。
- 未发送草稿在进程生命周期内按会话保留；不写入磁盘。传输断开时不自动重放写操作，发送请求 ID 保持稳定，未确认草稿留给用户重试。
- Markdown 覆盖常用标题、列表、行内格式、链接和代码区块；表格与数学公式不在当前排版范围。
- 创建任务、浏览完整项目目录、覆盖 IPA 安装和账号切换之外的账户管理仍受现有 Mac 网关能力约束。

## 验证

运行 `bash scripts/test-ios-smoke.sh` 做隔离 IPv4／IPv6 网络、Keychain 与原生 API 冒烟。运行 `LINK_UI_TEST=1 bash scripts/test-ios-smoke.sh` 额外打开合成 UI fixture，执行新建项目、输入框发送、状态页面、设置草稿放弃确认等 XCTest UI 流程，并保存截图附件。fixture 使用临时 HOME、TLS 服务和会话，测试不读写实际 `~/.codex`，不连接生产网关或物理手机。

IPA 构建使用 `bash scripts/build-ios.sh`。原生 UI 必须覆盖安装新 IPA；Bundle ID、Keychain service/account 和配对凭据标识不变，不需重新配对。
