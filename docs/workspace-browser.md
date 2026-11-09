# 会话工作区与文件差异

从本机桌面会话右上角「···」菜单选择“工作区”。“文件”页顶部提供带放大镜的搜索、可点击面包屑与三点菜单；菜单包括刷新、上一级、导入文件、按名称／修改日期／创建日期／大小／类型排序、切换升降序及显示隐藏项。支持逐层浏览、UTF-8 文本预览与编辑、复制路径和将路径带回输入框。“变更”页区分未暂存与已暂存差异，显示文件数及红绿高亮的增删行数；每个文件右侧也以绿色显示新增、红色显示删除。仓库选择器可切换项目根目录及一至三级子目录中发现的 Git 仓库；未跟踪文件打开当前内容，已跟踪文件打开单文件 diff。新建项目的目录选择复用相同的搜索和面包屑操作。

预览和差异页面顶部提供“将路径带回输入框”，差异页面同时提供“评论此文件”；菜单可切换长行换行和复制路径。评论可附正整数行号，点击“带回输入框”会追加到当前输入草稿，保留原有文字，等待手动发送。路径与评论回填均核对会话身份，避免切换会话后写入另一条对话。当前评论是可编辑的文字上下文，尚未实现原版结构化评论附件与逐行点选。

## 数据与行为

- 数据来自该会话当前工作目录，与历史消息中的文件版本不同。工作区读取使用网关 `/api/native/v1/threads/{id}/workspace/{tree,search,file,repositories,changes,patch}`；不恢复或激活 Codex 会话，不触发模型请求。
- 仅本机可控制的桌面会话提供入口；只读日志、CLI／exec 历史与远端主机不提供当前工作区读取。旧网关不返回 `workspaceRead` 时入口不可用，因此需要同时更新并重启 Mac 网关与覆盖安装 iOS IPA。
- 文件接口只接受工作区相对路径。目录和文件使用逐级 `openat` / `O_NOFOLLOW`，不跟随符号链接，屏蔽 Git 内部目录，不预览设备、管道等非普通文件。
- 目录每页 100 项，扫描上限 6,000 项；名称、修改日期、创建日期、大小和类型排序由 Mac 提供元数据，默认隐藏点文件，启用后可显示（`.git` 始终屏蔽）。搜索匹配整个工作区的文件名或相对路径，上限 100 个结果、6,000 个目录项、12 层，跳过依赖与缓存目录；达到上限时界面提示缩小范围。搜索不读取文件正文。
- 文本预览最多读取 128 KiB；截断时保留完整 UTF-8 字符并提示。二进制及其他编码只显示不支持预览的提示。
- 仅完整、可预览且有修订标识的 UTF-8 普通文件可编辑；保存通过工作区相对路径、读取时的修订散列和原子替换完成。文件在编辑期间被外部修改时保存返回冲突，不覆盖新内容；编辑器保留手机草稿供用户处理。写入上限 128 KiB，并保留 BOM、CRLF 和权限位。
- “导入文件”最多 20 MiB，以二进制上传到当前目录；只允许创建普通新文件，拒绝隐藏目标、路径分隔符、链接及同名覆盖。
- Git 仓库发现扫描项目根目录及三级子目录，跳过依赖／缓存目录和符号链接，识别 `.git` 目录及 worktree 的 `.git` 文件。扫描最多 6,000 项、100 个仓库、1 秒；达到上限有提示。变更页在前台可见且未进入文件详情时，每 5 秒重新发现仓库并读取所选仓库的差异，也可手动刷新。项目根目录无需自身是 Git 仓库。支持未暂存、已暂存和未跟踪文件。每个命令 6 秒、合计输出 1 MiB 上限，最多展示 200 个文件，超限有明确提示。增删行数只累计可计数的文本差异，二进制与未跟踪文件单独标明。
- Git 读取禁用外部 diff、textconv、clean/process filter、fsmonitor、hooks、交互认证与网络协议，并清除继承的 Git 仓库重定向变量。原版包内的 diff 采集脚本也明确禁用外部处理器；本项目独立实现，没有执行或嵌入原版脚本。
- 请求取消、搜索词变化、来源切换均有世代检查，旧请求不会覆盖新的浏览结果。目录分页基于当时目录排序；文件变化后可刷新列表。

选择仓库后的文件路径仍相对于会话项目根目录，预览、编辑、评论回填保持同一工作区范围。位于项目之外的附加 worktree 不自动列出。当前不包含分支对比、最近一轮 diff、暂存／提交／丢弃操作或后台终端控制。

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

测试覆盖文件读取、受限导入、排序元数据、隐藏项过滤、认证／CSRF、token 用量投影、冲突保护和 Git 边界。测试与构建日志位于本地忽略的 `build/` 目录，不作为仓库文档附件提交。

文件页的「···」选项菜单位于页面右上角，与搜索框分离；搜索框只保留放大镜、输入和清除搜索。刷新、返回上一级、导入、排序、升降序和显示隐藏项仍由此菜单进入。
