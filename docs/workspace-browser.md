# 会话工作区与文件差异

从本机桌面会话右上角的文件夹按钮进入“工作区”。“文件”页支持逐层浏览、按文件名或相对路径搜索、UTF-8 文本预览、复制路径和将路径带回输入框。“变更”页区分未暂存与已暂存差异，显示文件数及增删行数；未跟踪文件打开当前内容，已跟踪文件打开单文件 diff。

预览和差异页面顶部提供“将路径带回输入框”，差异页面同时提供“评论此文件”；菜单可切换长行换行和复制路径。评论可附正整数行号，点击“带回输入框”会追加到当前输入草稿，保留原有文字，等待手动发送。路径与评论回填均核对会话身份，避免切换会话后写入另一条对话。当前评论是可编辑的文字上下文，尚未实现原版结构化评论附件与逐行点选。

## 数据与行为

- 数据来自该会话当前工作目录，与历史消息中的文件版本不同。工作区读取使用网关 `/api/native/v1/threads/{id}/workspace/{tree,search,file,changes,patch}`；不恢复或激活 Codex 会话，不触发模型请求。
- 仅本机可控制的桌面会话提供入口；只读日志、CLI／exec 历史与远端主机不提供当前工作区读取。旧网关不返回 `workspaceRead` 时不会展示入口，因此需要同时更新并重启 Mac 网关与覆盖安装 iOS IPA。
- 文件接口只接受工作区相对路径。目录和文件使用逐级 `openat` / `O_NOFOLLOW`，不跟随符号链接，屏蔽 Git 内部目录，不预览设备、管道等非普通文件。
- 目录每页 100 项，扫描上限 6,000 项。搜索匹配整个工作区的文件名或相对路径，上限 100 个结果、6,000 个目录项、12 层，跳过 `.git`、`node_modules`、`.build`、`.venv`、`__pycache__`；达到上限时界面提示缩小范围。搜索不读取文件正文。
- 文本预览最多读取 128 KiB；截断时保留完整 UTF-8 字符并提示。二进制及其他编码只显示不支持预览的提示。
- Git 差异只支持工作目录本身为仓库根目录的本机仓库；支持未暂存、已暂存和未跟踪文件。每个命令 6 秒、合计输出 1 MiB 上限，最多展示 200 个文件，超限有明确提示。增删行数只累计可计数的文本差异，二进制与未跟踪文件单独标明。
- Git 读取禁用外部 diff、textconv、clean/process filter、fsmonitor、hooks、交互认证与网络协议，并清除继承的 Git 仓库重定向变量。原版包内的 diff 采集脚本也明确禁用外部处理器；本项目独立实现，没有执行或嵌入原版脚本。
- 请求取消、搜索词变化、来源切换均有世代检查，旧请求不会覆盖新的浏览结果。目录分页基于当时目录排序；文件变化后可刷新列表。

当前不包含分支对比、最近一轮 diff、多仓库／附加 worktree 导航、文件写入、暂存／提交／丢弃操作或后台终端控制。

## 反编译依据

| 行为 | 证据 | 实现 |
|---|---|---|
| 目录浏览与搜索 | `types/CodexRemoteThread.md:984` 的 `CodexRemoteWorkspaceBrowserViewModel`：`_searchText`、`_visibleEntries`、目录缓存、搜索任务、文件打开任务、`insertPathIntoChatHandler`；类型访问器 `0x23bfa0c`，直接关联 witness `0x2246720` | `NativeWorkspaceBrowser.swift` / `WorkspaceReader.tree/search/file` |
| 来源选择与文件差异 | `CodexRemoteWorkspaceDiffSheetSource` 的 `unstaged/staged/branch/lastTurn`；`CodexRemoteWorkspaceDiffSheetViewModel` 的 `_selectedSource`、`sourceLoadID`、`_cancelsPreviousStorage_sourceLoadTask`，访问器 `0x23bffe8`，witness `0x22498a0` | 本轮实现其中 `unstaged/staged`，单文件按需读取 |
| 文件与行数摘要 | `types/CodexRemoteCore.md:2429` 的 `CodexRemoteWorkspaceDiffFile`：`path`、`isUntracked`、`linesAdded/Removed`、`documentDiff`、过大／省略标记；访问器 `0x2f2f52c` | `WorkspaceChange`、摘要和大小上限提示 |
| 评论与回填 | `CodexRemoteDiffCommentState` 的 `_commentsByFilePath`、`attachComment/removeComment`，访问器 `0x23c08fc`；工作区浏览器的 `insertPathIntoChatHandler` | 独立实现路径／文件评论追加到本机草稿，不自动发送 |
| Git 读取边界 | 包内 `resources/workspace_repository_diff_snapshot.sh` 的 `read_git`、过滤器禁用、输出预算与 diff source | 第一方 `mac/workspace_reader.py` |

证据目录为相邻 `Payload/ChatGPT.app/codex-remote-analysis/full/`。上述 witness 主要用于确认类型关联，具体 UI 与本轮网关响应结构由本项目独立实现。

## 验证入口

`tests/test_workspace_reader.py` 使用临时目录和临时 Git 仓库验证目录分页、搜索、UTF-8 截断、二进制提示、路径／符号链接／管道边界、已暂存与工作区差异、特殊文件名、过滤器不执行及输出上限。`tests/test_native.py` 验证真实隔离 TLS 上的认证、来源限制、相对路径与只读 GET。

`bash scripts/test-ios-smoke.sh` 验证 iOS 的实际解码、模型调用、文件预览、两种差异和保留草稿的回填。`LINK_UI_TEST=1 bash scripts/test-ios-smoke.sh` 额外验证工作区入口、搜索、预览、回填路径、已暂存差异、评论回填，以及原有历史滚动回归。

本轮结果：上述 98 项 Python 回归通过，模拟器冒烟 12 项检查通过，UI 流程 1 项通过、0 失败（118.675 秒），产品 Release／普通 Debug 构建成功。汇总见 `build/workspace-verification.json`。全目录测试另有既有清理模块因缺少 `清理CodexExec对话.command` 无法加载，本轮未改动该工具；详情见 `build/workspace-python-tests.log`。
