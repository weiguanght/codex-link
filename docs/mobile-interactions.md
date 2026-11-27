# 手机审批与 Agent 问答

原生 iOS 客户端现在可以处理共享桌面会话的命令审批、文件审批、本轮权限申请和 Agent 问答。Mac 与手机处理的是同一个请求。一端回应后，另一端在收到解决通知后移除卡片。

## 启用与使用

1. 为启用新的请求转发接口，先重启 Mac 网关。
2. 为使用新的原生交互界面，覆盖安装最新 TrollStore IPA。Bundle ID 和配对钥匙串标识不变。
3. 打开会话后，点击标题栏带数量的手掌按钮，跳到最新消息中的待处理卡片。翻阅历史时不会自动抢走阅读位置。
4. 审批前，查看命令、工作目录、文件差异或申请的权限。按钮仅显示当前请求允许的操作。
5. 回答问题时，选择选项或填写其他回复。多问题需要全部回答。答案支持多行文本，每个答案最多 20000 个字符。点击键盘上方的“完成”收起键盘。

提交后显示“已提交，等待处理…”。连接恢复不会自动重发回应。如果 Mac 已经处理请求，手机会在下一次同步时移除卡片。

## 支持范围

| 请求 | 原生 iOS 操作 |
| --- | --- |
| 命令审批 | 本次允许、拒绝或取消；以 `availableDecisions` 为准。展示命令、工作目录、执行环境、额外权限和网络访问范围 |
| 文件审批 | 本次允许、拒绝或取消；展示申请的目录和可展开的文件差异 |
| 权限申请 | 批准所申请的权限，或拒绝。批准范围固定为本轮，不扩大为会话授权 |
| 阻塞式 `request_user_input` | 单选、其他回复、多行输入、多问题提交；秘密输入使用密码控件 |
| 非阻塞式 Agent 问题 | 任务执行中使用补充输入；任务结束后用新一轮消息提交标准问题回复 |

身份验证、computer-use、MCP 表单和计划批准仍由 Mac 处理。本次修改不改变默认审批策略和沙盒配置。

## 修复点

- 共享桌面网关原先直接丢弃带 `id` 的服务端请求，且 `respond` 一律返回“请在 Mac 处理”。现在保存请求，并发送正确的 JSON-RPC `result` 帧。
- 初始化时声明 `requiredHumanApproval`，接收要求人工处理的命令审批。
- 原生能力投影原先在共享模式中关闭 `respond`。现在为可控会话开放；只读历史和日志视图仍关闭。
- 请求缓存独立于历史快照。订阅期间重放的请求不会丢失，已经解决的请求不会被旧快照恢复。
- 手机使用不透明请求 ID。旧卡片不能在重连后误答另一个复用同一底层 ID 的请求。
- 相同回应只发送一次；不同回应不能覆盖已经提交的决定。未确认的发送不会自动重试。
- 问答草稿按请求保存在内存中。轮询、消息单元格复用和其他请求结束不会清空或错置答案。请求结束、切换会话或清空聊天状态后释放草稿，不写入磁盘草稿。
- 提交前检查会话、连接、回应能力和请求是否仍有效。只接受完整、非空、长度合规的答案。

## 验证

验证使用项目 `build/` 内的临时数据，不连接用户的生产会话或模型服务。

- Python 回归：请求接收与解决、订阅重放、断线、旧 ID、重复与不确定发送、答案格式、权限边界、只读能力和内置运行时完整性。
- 真实运行时：`codex-cli 0.171.0-alpha.13.2`。通过已认证 HTTPS 接口验证命令批准、取消、另一客户端回应同步、重连后的待处理请求恢复、多问题和自定义回答，以及任务执行中和结束后的非阻塞式问答。模型服务是本机测试服务，批准后只运行 `/bin/echo`。测试使用 `tests/mobile-models.json` 声明异步问答工具能力；该文件仅包含本机测试指令，不包含生产模型提示词，也不访问生产模型目录。
- 原生交互用例：`NativeFlows.testMobileApprovalsAndAgentAnswers` 覆盖未答校验、选项、多行回复、其他审批结束后的答案保持、权限批准、拒绝、取消和 Mac 解决后的移除。
- 交付构建：运行 `bash scripts/build-ios.sh`，构建 arm64 Release App、检查压缩包并验证 TrollStore 包签名。

验证日志与结果保留在 `build/mobile-interactions/`；安装包保留在 `build/`。

为了复测请求链路，在项目根目录执行：

```sh
mkdir -p build/mobile-interactions/test-tmp
TMPDIR="$PWD/build/mobile-interactions/test-tmp" PYTHONPATH=tests \
  python3 -m unittest test_mobile_interactions test_shared_desktop test_native test_bundle

TMPDIR="$PWD/build/mobile-interactions/test-tmp" \
  python3 scripts/test-mobile-interactions-runtime.py \
  --runtime /path/to/ChatGPT.app/Contents/Resources/codex-cli/bin/codex

TMPDIR="$PWD/build/mobile-interactions/test-tmp" \
  LINK_UI_TEST=1 \
  LINK_UI_ONLY=1 \
  LINK_UI_TEST_CASE=NativeUITests/NativeFlows/testMobileApprovalsAndAgentAnswers \
  bash scripts/test-ios-smoke.sh
```
