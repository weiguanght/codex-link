# Codex 非 Cloud iOS 复刻工程

本轮选择继续现有 `ios/codex-link.xcodeproj`，采用 SwiftUI + Foundation / URLSession / Network / Keychain，保留 Python Mac 网关。该工程已有可用的配对、IPv4/IPv6、任务与项目、聊天、审批、设置能力；复用这些基础比更换技术栈更适合推进可运行的原生客户端。最低 iOS 16，构建工具链 Xcode 15.2 / iOS 17.2 SDK，无新增第三方依赖。

目标是重建非 Cloud 的移动工作流与可验证行为。当前网络协议仍是 codex-link 网关 API + Desktop IPC，尚未替换为原版 Slingshot/SSH app-server 连接；本轮未实现 Cloud、实时语音，也未复制原 App 的品牌资源。反编译的函数名、字段和直接调用是实现证据，不将机器伪代码直接编译进产品。

## 已落地的差距

| 行为 | 反编译证据 | 源码落点 | 本轮结果 |
|---|---|---|---|
| 输入草稿恢复 | `CodexRemoteComposerState._isApplyingMessageDraft`，访问器 RVA `0x23a3944`；`DefaultCodexRemoteMessageDraftStore`，访问器 `0x2f145fc`、witness `0x2dccc1c` | `DraftStore.swift`、`NativeModels.swift`、`CodexLinkApp.swift` | 新增本机文件持久化、恢复提示、切后台刷新、确认发送后清理 |
| 后续消息默认方式 | `CodexRemoteHostManagementViewModel._followUpBehavior` / `_followUpBehaviorSetting`，访问器 `0x210d860` | `NativeSettings.swift`、`ChatDraft` | 新增发送新消息／完成后发送／补充当前任务的默认选择，复用已有 `send/queue/steer` 网关实现 |
| diff 长行换行 | 同一 ViewModel 的 `_diffLineWrappingEnabled` / `_diffLineWrappingSetting` | `NativeDiff.swift`、`NativeComponents.swift`、`NativeSettings.swift` | 新增 `diff/patch` 代码块的增删/文件/hunk 着色、自动换行与横向滚动切换 |
| 证据导航 | `manifest.json`、`function_index.csv`、`direct_calls.jsonl` | `scripts/export-reverse-navigation.py` | 新增有数量上限的 Serena C 导航投影；逐符号回指真实伪代码、汇编与归属证据 |
| 工作区浏览、搜索与编辑 | `CodexRemoteWorkspaceBrowserViewModel` 的目录缓存、搜索和路径回填；访问器 `0x23bfa0c` | `NativeWorkspaceBrowser.swift`、`mac/workspace_reader.py`、`mac/native_http.py` | 新增会话目录浏览、文件名／路径搜索、受修订冲突检查保护的文本预览与编辑 |
| 工作区差异与评论 | `CodexRemoteWorkspaceDiffSheetViewModel`、`CodexRemoteWorkspaceDiffFile`、`CodexRemoteDiffCommentState`；访问器 `0x23bffe8`、`0x2f2f52c`、`0x23c08fc` | 同上，以及 `NativeDiff.swift`、`NativeModels.swift` | 新增未暂存／已暂存文件差异、未跟踪文件预览和文件评论追加草稿；详见 [工作区说明](workspace-browser.md) |

字段与访问器证据可以确认原程序存在这些状态/接口；本项目的文件格式、配对隔离、默认行为和 UI 是独立实现，未声称与原版逐分支一致。`send/queue/steer` 是既有网关取值，未声称就是原版枚举的原始编码。

完整反编译资料位于工作区相邻的 `Payload/ChatGPT.app/codex-remote-analysis/full/`。`报告.md`、`导航.md` 和 `type_fields.json` 是证据入口。

## 草稿语义

- 按配对身份 `serverId + deviceId` 隔离，内部再按 host/thread identity 分离；地址从 IPv4 切到 IPv6不会切换草稿。
- 文件保存在 Application Support 的 ComposerDrafts 目录，目录排除系统备份；文件采用 atomic + completeFileProtectionUntilFirstUserAuthentication。文件名和配对目录使用 SHA-256；这不额外加密文件正文。
- 编辑后 300ms 合并写入；切换会话、进入后台、发起发送时立即刷新。强制终止进程可能丢失尚未刷新的最后一次编辑。
- 恢复文字、工作模式、发送方式、skills；文字消息的待确认 payload 与请求 ID 一并保留。恢复操作不会自动发送，也不会恢复启动新会话时使用的 auto-send 标记。
- 附件只保留文件名提示，不恢复已上传附件 ID、系统文件 URL 或 security-scoped 访问权。重新进入 App 后需要重新选择附件。
- 上次发送未确认时显示核对提示。纯文字原 payload 重试沿用请求 ID；修改 payload 或重新选择附件会创建新请求，需先核对上次消息。
- 确认发送只清理该次提交的文本和附件；发送过程中继续输入的不同文本保留。忘记 Mac 时清除此配对的草稿，并取消延迟保存。读取失败的原草稿文件会保留，直到用户实际编辑输入框，不会被恢复流程的空值覆盖。
- 尚无草稿的新会话使用设置里的默认发送方式；已有草稿保留自己的方式。草稿不会保存配对密钥、Cookie 或认证令牌。

## Serena 的边界与用法

已验证本机 `serena` 是 `/Users/hoto/GitHub/Serena/serena-1.7.0` 的定制 1.7.0。Swift 工程使用 `ios/.serena/project.yml` 的 Swift LSP；daemon 在每次代理任务结束时显式停止。

```sh
serena daemon start /absolute/path/to/codex-link/ios
serena tools call find_symbol /absolute/path/to/codex-link/ios \
  --arguments '{"name_path_pattern":"ChatModel/send","relative_path":"CodexLink/NativeModels.swift","include_body":true}'
serena daemon stop /absolute/path/to/codex-link/ios
```

对原始 `CodexRemoteLocalActivityInterface.c` 的 370 行探针，Serena/clangd 能列出 46 个函数名；语义诊断仍包含未声明 JUMPOUT、未知 __int64/_QWORD 等错误，不能据此获得可靠的类型、数据流或完整调用图。探针保留在反编译输出的 `serena-probe/`。本机 CLI 在返回整文件大量诊断时出现过 JSON 传输截断，因此诊断改为按符号查询，完整错误另用 clangd `--check` 保留。

需要基于二进制证据查直接引用时，使用可重新生成的、限定范围的导航投影：

```sh
python3 scripts/export-reverse-navigation.py \
  --analysis /absolute/path/to/codex-remote-analysis/full \
  --output build/reverse-navigation \
  --address 0x2da5f0c --address 0x2e14788 --address 0x2ddd10c
serena project create /absolute/path/to/codex-link/build/reverse-navigation --ls cpp
# 在该项目 .serena/project.yml 的 ls_specific_settings.cpp 设置 use_xcode_toolchain: true。
serena daemon start /absolute/path/to/codex-link/build/reverse-navigation
serena tools call find_symbol /absolute/path/to/codex-link/build/reverse-navigation \
  --arguments '{"name_path_pattern":"rva_2DA5F0C","relative_path":"EvidenceNavigation.c","include_body":true}'
serena daemon stop /absolute/path/to/codex-link/build/reverse-navigation
```

脚本也支持 `--module CodexRemoteHost --limit 64`。默认上限 64，硬上限 1000，避免重新触发全量语义分析。`mapping.json` 保存每个符号的原始 RVA、直接边、源码证据和伪代码/汇编行号。C 函数体仅表达邻接关系，不恢复条件、参数、间接调用或可执行算法；这些文件不能加入 App target。

## 验证与下一阶段

运行 `bash scripts/test-ios-smoke.sh` 验证真实模拟器上的隔离 TLS 网关；不读取实际 `~/.codex`。本轮扩展的测试通过重建 DraftStore / ChatModel 模拟进程重启，验证配对/host 隔离、附件 ID 不恢复、不自动重发、重试 ID 保持、发送确认清理、取消延迟写入。它不等同于真机断电或系统强杀验收。

`LINK_UI_TEST=1 bash scripts/test-ios-smoke.sh` 执行项目/会话/设置 UI 流程，并在 synthetic diff 内容上验证原生差异视图出现。`bash scripts/build-ios.sh` 生成未签名与 TrollStore 测试 IPA；证书、配对和联网需按已有流程在实际设备验证。

本轮验证结果已落盘：

- 最新模拟器冒烟为 PASS，14 项检查，新增中文／空格／编码／行号文件引用的高亮与授权下载、模型强度选项及默认值联动；保留工作区、草稿、TLS 与发送验证。见 `build/ios-smoke-result.json`、`build/links-model-smoke.log`。
- 最新 UI 流程为 1 项通过、0 失败，耗时 141.341 秒；见 `build/native-ui-test.log`。新增文件引用点击打开系统分享面板、切换模型后的强度菜单、保存及重新打开回读；同时覆盖历史阅读位置、工作区搜索／预览、路径回填、已暂存差异、评论回填、设置与项目创建。
- 产品代码的设备 Release 与普通模拟器 Debug 均构建成功；见 `build/links-model-device-build.log`、`build/links-model-build.log`。两种 IPA 位于 `build/`，SHA-256 记录在 `build/SHA256SUMS.txt`，未执行真机安装。链接与菜单修复只需更新 IPA。
- 最近全量 Python 测试 102 项通过。Xcode、模拟器和设备 Release 构建已通过；生成 IPA 位于本地忽略的 `build/`，真机安装仍需单独验收。日志和验证产物不随源码提交。
- 最新普通 Debug 的 Serena IndexStore 索引包含 150 units、7,980 edges、17,643 occurrences；见 `build/workspace-xcode-index.json`。`workspace-context-callers.json` 已确认聊天界面调用草稿回填方法。该图是本工程编译快照，本轮未启动项目 daemon。
- `build/links-model-verification.json` 汇总本次修复验证及安装包散列；此前工作区验证见 `build/workspace-verification.json`，工作区截图为 `build/workspace-diff.png`、`build/workspace-comment.png`。

当前工作区能力与证据映射见 [工作区说明](workspace-browser.md)。下一阶段可继续补齐分支／单轮差异、多仓库／worktree 导航、后台终端、app-server 请求／通知状态展示与 Live Activity / Widgets。按当前任务范围，原版 SSH／Slingshot 传输与注册／刷新／配对排除在后续实现之外；Cloud 与实时语音继续忽略。
