# 验证记录

## 新版桌面随状态栏网关启动（2026-11-21）

- 本机「Codex网关.app」升级至 1.1，沿用原 LaunchAgent 和配对目录。通过 launchctl 启动后，状态栏进程运行正常，18443 上的 HTTPS 身份接口返回 200。已打开的生产桌面继续运行。
- 在独立数据目录验证 Intel `26.1117.41037`。无 daemon 时，后台网关启动内置 App Server，桌面以 WebSocket 成功握手，HTTPS 身份接口返回 200，退出网关时释放端口。本机既有 daemon 的 App Server 握手也通过。
- 桌面相关 Python 测试 20 项通过。全量共 175 项，历史提交 `4253556` 修改了 `bridge/create.py`，留下 1 项上游快照校验失败。TrollStore IPA 构建和归档校验通过。

## 首页与消息页顶部布局（2026-11-21）

- 首页和消息页共用固定标题栏，滚动区从标题栏下缘开始。iPhone 15（iOS 17.2）模拟器通过 2 项定向 UI 测试，覆盖首条消息、反复打开会话和返回首页、边缘滑动及标题栏菜单。测试结果保存在 `build/top-layout/ui-005656.xcresult` 和 `build/top-layout/menu.xcresult`。
- arm64 Release 构建、TrollStore 签名和 IPA 校验通过。覆盖安装即可生效。构建日志位于 `build/top-layout/release.log`。

## 1 MB 以上的冷门语法改用轻量高亮（2026-11-21）

- Dart、Elm、R 改用 Highlight.js，Bicep、Pascal、Zig 改用 Prism。移除 21.9 MiB 的生成解析器源码。模拟器定向 smoke 验证了 60 种高亮模式，覆盖新替换语法的代表性 token、扩展名和 SQL 编辑撤销。日志见 `build/syntax-1mb/syntax-smoke.log`。
- 正式构建从空的应用包开始生成资源。归档内已清除两轮移除的语法查询资源，arm64 构建、TrollStore 签名和 SHA-256 校验通过。与上一版相比，IPA 从 7.49 MiB 降至约 7.07 MiB，解包体积从 52.79 MiB 降至 49.36 MiB。构建日志见 `build/syntax-1mb/release-final.log`。

## iOS 轻量语法高亮（2026-11-20）

- 11 个 Tree-sitter 语法目标改用轻量分词，删除 293.6 MiB 的生成解析器源码。Highlight.js 和 Prism 的离线 JavaScript 资源合计 179.9 KiB。替换范围和编辑功能差异见 [语法高亮](docs/syntax-highlighting.md)。
- 同一构建脚本生成的 TrollStore IPA 从 12.0 MiB 降至 7.5 MiB，解包体积从 111.7 MiB 降至 52.8 MiB。
- Python 测试 174 项通过，见 `build/lightweight-syntax/python.log`。arm64 Release、IPA 归档、TrollStore 签名和 SHA-256 校验通过，见 `build/lightweight-syntax/release-final.log`、`build/SHA256SUMS.txt`。
- iOS 模拟器 smoke 26 项通过，定向 smoke 覆盖 60 种高亮模式和 SQL 编辑撤销。截图确认撤销后无需滚动即可恢复着色。日志和截图见 `build/lightweight-syntax/full-smoke.log`、`build/lightweight-syntax/syntax-smoke-final.log` 和 `build/lightweight-syntax/sql-editor-final.png`。
- 安装包位于 `build/codex-link-0.1.0-TrollStore.ipa`，覆盖安装后启用新版高亮。

## 新版桌面共用本地 App Server（2026-11-20）

- 在 Mac 上用独立 Codex 数据目录启动 Intel 桌面 `26.1117.31558` 与随带的 `0.171.0-alpha.13`，用本地测试模型服务完成对话。桌面与网关通过同一 Unix socket 握手。用配对后的 HTTPS 接口和实际桌面 UI 验证同一会话双向更新。
- 验证了新建空会话、重复创建和提交去重、首轮分页、恢复现有会话、补充、停止、模型推理强度确认和归档恢复。桌面打开同一会话后，网关发起的消息出现在桌面，桌面发送的新消息出现在网关时间线。记录见 `build/shared-bidirectional.log`。
- 以同样方式验证复用本机管理的 `0.171.0` daemon。关闭共享网关后，独立启动的 daemon 继续运行。记录见 `build/shared-daemon-integration.log`。
- Python 测试 174 项通过。Release 构建、IPA 归档与 TrollStore 签名校验通过。
- 此次使用本地测试模型服务与手机同款 HTTPS 请求，尚未用 iPhone 和生产模型验收。保留生产桌面 `26.1111.21308`，它的 IPC 握手通过。

## 桌面实时接口不可用时保留历史（2026-11-20）

- 本机 Intel 桌面 `26.1117.31558`（29513）正常运行，但原桌面 IPC 返回 `ECONNREFUSED`。经过证书绑定和设备认证的请求仍可加载首页及真实会话历史。另有一个常驻 App Server 的控制 socket，当前桌面则通过 stdio 连接自身的运行时。
- 网关识别 socket 缺失和拒绝连接。桌面进程已运行但没有 IPC 监听时，连接操作立即返回具体原因，手机继续显示已保存的历史。真实会话历史接口返回 200，连接操作在 0.17 秒内返回 409。记录见 `build/desktop-connection-live.log`。
- 从 Intel 更新源取得 OpenAI 签名的 `26.1111.21308`（27194），在独立配置目录确认 IPC 握手成功。同一构建此前通过真实会话的版本 13 快照验证。此次未验证回退后能否接续当前正在运行的任务。
- Python 测试 171 项通过，iOS 模拟器 smoke 26 项通过。Release 构建及 TrollStore 签名校验通过。日志见 `build/desktop-connection-tests.log`、`build/desktop-connection-smoke.log` 和 `build/desktop-connection-build.log`。

## 任务过程分组与按需读取（2026-11-18）

- iOS 按轮次显示用户发起消息、耗时摘要和最终回答；中途模型／用户消息、工具调用与文件变更收进过程区块。运行中默认展开，完成后默认收起，展开时分页读取过程。过程行继续由 UIKit 复用，开合与插入保留阅读锚点。
- 原生时间线通过 `projection=turns` 启用分组，受认证的 `process` 接口按轮次分页；原有网页时间线、全文 Markdown 复制及消息详情仍读取原始记录。历史索引保留明确的 turn ID，按内容去除事件镜像，保留同轮的补充输入；耗时保留日志开始／结束时间，桌面快照缺少时可复用已载入历史的时间字段。
- 全量 Python **157 项通过**（`build/turn-process-python.log`）；随后新增运行中结束计时回归，最终耗时补全与桌面流相关回归 **15 项通过**（`build/turn-process-final-regressions.log`）。覆盖首尾投影、活跃过程更新、整轮分页、过程字节上限、展开详情、懒读取、补充消息、认证与只读边界。
- 原生 smoke **25 项通过**（`build/ios-smoke-result.json`），含完成轮次不预取过程、懒加载工具详情／差异统计、中途模型与用户消息归组、运行中自动展开和完成后自动收起。开合 UI 测试 **1 项通过**（`build/native-ui-20261118-173926.xcresult`）；本轮未跑完整 UI 套件。
- arm64 Release、IPA 归档和 TrollStore 签名检查通过；构建日志 `build/turn-process-build.log`，最新包 `build/codex-link-0.1.0-TrollStore.ipa`，校验 `build/SHA256SUMS.txt`。
- 安装新版 IPA 并重启 Mac 网关后生效；不需重新配对。

## 自动命名会话创建失败（2026-11-18）

- 复现为桌面运行时 `codex-cli 0.169.0-alpha.11.1` 创建留空名称的 paginated 会话后，`thread/read(includeTurns: true)` 报 `list_turns is not supported yet`。新会话及 rollout 已创建，但旧流程把后续读取错误当作创建失败，未将会话交给桌面 App。
- 仅对该精确的 `list_turns` 未实现错误回退至 `thread/read(includeTurns: false)`；其他读取错误仍原样报出。该读取确认会话元数据，不启动 turn。自定义名称流程不变。
- 新增 3 项回归：fallback 成功、无关错误不被吞掉、fallback 元数据读取失败时继续报错。全量 Python **148 项通过**（`build/create-chat-tests.log`）。
- 使用本机 `0.169.0-alpha.11.1`，在隔离 HOME 和离线 provider 下验证留空／自定义名称的新建：rollout 写入、桌面 `thread/resume` 恢复同一空会话、名称正确；未触发模型轮次。记录：`build/create-chat-runtime-check.json`。
- 此修复位于 Mac 网关；需重启 Mac 网关后生效。iOS 安装包不含此 Python 修复。

## 新建会话、发送方式与用户消息复制（2026-11-18）

- 新建会话支持自定义名称，留空时保留 Codex 自动命名；可不选择项目直接创建。本机会话支持模型、推理强度、审批策略和沙盒选择，参数传入 `thread/start`。
- 任务结束后，补充／排队方式按普通消息发送；补充请求遇到任务结束竞态时自动改为普通发送。结果尚未确认的请求重试保留原 ID 和 payload。
- 用户长消息默认最多显示 5 行，可展开，使用独立的一键复制按钮；复制显示屏幕中央确认动效和触觉反馈。模型回复保留原生文本选择。
- 全量 Python **145 项通过**；iOS 原生 smoke 通过，覆盖任务结束回退、竞态回退和未确认请求重试。目标 UI 测试 `NativeUITests/NativeFlows/testNewChatOptionsAndUserMessageCopy` **1 项通过**，覆盖无项目创建、名称／模型／权限选择、长消息折叠和复制确认；本轮未重跑整套 UI 测试。结果：`build/native-ui-20261118-042851.xcresult`。
- arm64 Release、两种 IPA 归档和 TrollStore 签名校验通过。安装包：`build/codex-link-0.1.0-TrollStore.ipa`，校验：`build/SHA256SUMS.txt`，构建日志：`build/ios-delivery-build.log`。新建会话参数需要重启 Mac 网关，界面改动需要覆盖安装 IPA。
- 固定交付流程写入项目 `AGENTS.md`：每次修改后完成相关验证、构建 IPA、提交并推送源码。

## 输入与滚动的渲染隔离（2026-11-17）

- 每个历史消息由 UIKit 表格的可复用单元格承载，SwiftUI 只负责单条消息内容；输入草稿由独立观察对象驱动。删除逐像素页面状态更新及手写滚动偏移控制。
- 合成 80 条混合消息的 UI 回归：输入 256 字符前后，消息 body、文本测量、UIKit 单元格配置数完全不变（`[14,97,301,100,216]`）；四次拖动后整页 body 只增 1 次，新增可见内容产生 23 次消息 body、47 次测量。计数结果：`build/native-transcript-counts.txt`，测试：`build/native-transcript-20261117-202139.xcresult`。
- 慢响应分页 UI 回归通过：页面延迟 5 秒，加载前后同一条可见消息的屏幕 Y 坐标均为 `29.5pt`；连续静默预取两页的 UI 回归通过：`build/native-transcript-20261117-202414.xcresult`、`build/native-transcript-20261117-202919.xcresult`。发送菜单及会话返回 UI 回归也通过。模拟器未测量真机帧率。
- 消息顶部留白 UI 回归发现并移除 `UIRefreshControl`：它的原生大号 spinner 会把首条消息向下推约 60pt，且与静默预取重复。现在列表顶部 inset 为 0，cell 内容向顶部对齐；首条消息 cell 的 `minY` 与列表顶部一致（2pt 容差），正文也通过顶部位置检查。静默历史预取和重复打开会话回归均通过：`build/native-transcript-20261117-220313.xcresult`。修复前后截图：`build/top-inset-failure.png`、`build/top-inset-fixed.png`。
- 原生 smoke **22 项通过**（`build/ios-smoke-result.json`），全量 Python **142 项通过**（`build/native-transcript-python.log`）。
- arm64 Release、IPA 归档、包内签名和 TrollStore entitlements 比对通过。无顶部刷新指示器版本安装包 `build/codex-link-0.1.0-no-top-spinner-TrollStore.ipa`，SHA-256 `479278556fc7dbd817589df3abc13682c3d992f7a1ceed62a7f91a38cf0fb5e6`。覆盖安装，无需重启 Mac 网关。
- 文件预览组合 UI 回归仍未通过：Markdown 文件在表格列表中可见，但嵌套在单个 UIKit cell 的文件操作没有可命中的测试触点；文件预览组合流程尚未验证。布局截图见 `build/native-transcript-file-layout.png`，失败记录 `build/native-transcript-20261117-205616.xcresult`。

## 历史列表滑动性能（2026-11-15）

- 本节记录的 `LazyVStack` 方案已于 2026-11-17 替换为可复用的 UIKit 消息列表。
- 先前慢响应位置测试跑在普通 `VStack` 版本上，不作为本版本的验证结果。
- 当前版本原生 smoke **22 项通过**，包括滚动锚点几何补偿；arm64 Release、IPA 归档与包内 TrollStore 签名检查通过。没有声称模拟器验证了真实手指跟手感。
- 安装包 `build/codex-link-0.1.0-smooth-scroll-TrollStore.ipa`，校验见同名 `.sha256`。覆盖安装即可，无需重启 Mac 网关。

## 桌面实时流版本 13 兼容（2026-11-14）

- 桌面 App 已更新至 `26.1111.21308`（构建 27194）。真实 IPC 发来 `thread-stream-state-changed` 版本 13，旧网关只接受版本 11，因而反复将正常快照判为断线。本次与之前超大日志导致桌面丢弃快照的原因不同。
- 新增第一方 `DesktopBridge`，仅为已验证的版本 13 适配上游版本检查；保留主机、来源所有者、修订号及增量补丁校验。版本 11 继续支持，未知版本拒绝并记录具体版本。桌面发送、审批、停止等操作版本经桌面源码核对均保持原有值，未修改上游快照。
- 新增 6 项回归，覆盖快照、版本 13 补丁、所有者／主机隔离、修订号不匹配后恢复、未知版本及所有者断线。真实会话经完整 `timeline_read` 路径验证：已连接、30 条消息、所有者存在、连接错误为空；未发送模型消息。结果见 `build/stream-v13-live-verification.json`。
- 全量 Python **142 项通过**（`build/stream-v13-tests.log`），运行时检查通过；本机与局域网的已固定证书 HTTPS 身份接口均返回 200。
- 常驻 Mac 网关已正常重启并载入适配，保留原配对及证书；无需重装 IPA。

## 首页请求超时与超大历史记录（2026-11-12）

- 常驻网关持续占用约一个 CPU 核心；线程采样定位到后台历史读取的字节拼接和分行。真实日志总长约 303 MB，其中一条记录约 296 MB，触发上游反向读行算法的反复复制／扫描。
- 本机桌面历史改用第一方 `DesktopSessionStore`：固定块反向扫描，跳过超过 8 MiB 的单条记录并记录告警，保留正常消息和轮次；不改上游快照、原始日志和配对身份。相同真实日志读取约 0.35 秒完成。
- 全量 Python **136 项通过**，含跨块边界、未终止末行、超大首／末记录、内存上限和正常轮次兼容性。隔离的本机 TLS 网关通过正式设备认证流程读取真实数据：并行历史读取时，首页连续三次约 0.44～0.71 秒返回；消息接口返回 30 条消息并接收到桌面实时快照。未发送模型消息或触发真实会话写操作。日志：`build/gateway-fix-tests.log`、`build/gateway-readonly-probe.log`。
- 已重启常驻 Mac 网关，配对信息、服务器身份和证书校验保持一致。本次无需重新构建或安装 IPA；手机端恢复情况待用户确认。
- 后续针对会话 `01a1c5a9-a560-71c2-9640-6aefe2cde517` 检查发现另一层限制：桌面日志明确记录 `thread-stream-state-changed` 的 297,860,775 字节快照超过 268,435,456 字节发送上限，被桌面主动丢弃。来源和权限判定正常，仍无法取得实时快照；前面的历史读取修复解决了首页超时，尚未解决这场会话的连接。
- 超大内容来自删除 `.ida-analysis/MT.asm` 的一条文件变更展示记录，并同时存在于派生历史缓存。用户确认后，已在 `.local/session-repair/01a1c5a9-a560-71c2-9640-6aefe2cde517/` 完整备份原始日志及该会话的派生缓存行，再应用约 7 MB 的修复副本；2352 条记录保留，仅替换一个超大字符串，前后其余字节校验一致。只清除该会话的派生缓存以重建，其他会话行数校验不变；桌面 App 和网关均已重启。
- 修复后真实 IPC 快照缩小至 1,699,928 字节，接收到版本 11 的实时快照；5 个轮次、30 条消息的网关投影成功，来源与权限判定为可交互。历史缓存已重建为 729 项，最大项 67,065 字节。修复日志哈希与准备副本一致。未发送模型消息。备份目录中的 `plan.json`、`apply-status.json` 和 `verification.json` 保存执行及校验结果。

## 消息布局与原生菜单（2026-11-09）

- 移除消息页闲置时包裹整页的投影、输入区 `regularMaterial` 底板、通知提示卡片背景及命令行半透明底。输入控件自身仍保留实色圆角背景。
- 消息滚动视口延伸到安全区域底部，输入区作为透明 overlay 悬浮其上；按实时测量的 composer 高度在滚动内容末尾加入间距，保证最后一条消息能滚出输入控件下方。
- 右上角改为 SwiftUI 原生 `Menu`，删除自定义固定宽度浮层、材质背景和外部阴影，使用系统默认菜单尺寸与外观；入口与对话操作菜单沿用同一行标签。
- 原生 smoke **22 项通过**，包括工具栏菜单与会话入口相关检查；菜单、发送设置及工作区入口 UI XCTest 通过（`build/chat-surface-menu-ui.log`、`build/native-ui-test.log`）。arm64 Release、TrollStore IPA 归档与签名检查通过：`build/codex-link-0.1.0-chat-surface-menu-TrollStore.ipa`，校验文件 `build/SHA256SUMS-chat-surface-menu.txt`。未进行真机手势和视觉验收。

## 消息正文选区复制（2026-11-09）

- Markdown 正文与用户消息改用只读 `UITextView`，由系统处理长按选词、选区手柄和复制菜单；不支持文本编辑、粘贴或改写。对 `UIResponder` 动作仅放行 Copy，整条回复的复制／分享／分支按钮不变。
- 没有单独安装 `UIEditMenuInteraction`：只读文本选择使用 UIKit 文本视图原生菜单即可，避免自定义手势与选区手柄冲突。
- 原生 smoke **22 项通过**，含“可选择、不可编辑且仅允许复制”的动作检查；模拟器 UI 构建通过。未声称 UI 自动化验证长按实际选区菜单；该交互仍需设备手感验收。
- 原生 smoke 22 项通过；arm64 Release 构建、IPA 归档及签名验证通过。安装包 `build/codex-link-0.1.0-text-selection-TrollStore.ipa`，SHA-256 `build/SHA256SUMS-text-selection.txt`；安装后可在消息正文上长按选词，再使用系统「复制」。

## Token 与 API 参考费用（2026-11-09）

- 输入框上下文使用日志最近一轮 `last_token_usage.total_tokens` 和 `model_context_window`；计费用量则将累计快照差分，跳过重复快照，并在累计量复位后重新建立基线，跨 `turn_context` 模型／服务档位分别计价。缓存输入拆出单独价格，推理不在输出之外重复收费。
- 参考 cc-sessions-viewer（MIT，读取参考检出版本 `669ff4784ca97e94d59cf59a369e7b3d9bbc58d0`）的模型切换、快照差分与重置思路，以本地实现重写，未复制其源码；仅对精确公开模型 ID 和日期后缀匹配，不继承其他型号费率。
- `mac/data/model-pricing.json` 含 29 个 OpenAI 官方短上下文价目表型号；`python3 scripts/update-pricing.py` 可经指定 Jina URL 刷新，解析校验通过后才原子替换。价格日期和来源在会话详情显示。未知模型／档位、快照缺少 input/output 拆分、或计费不可完整估算时不伪报总额；缓存写入缺少实际保留时长，因此不估价。API 参考金额不是订阅账单，亦未涵盖长上下文、工具、地区附加价格。
- `/status` 是 CLI 本地命令，本实现不向模型发送 `/status` 或新增 App Server 接口；上下文读取相同日志字段。应用显示原始已用／窗口比例，CLI 剩余比例会扣除 12K 基线，故两者百分比不应视为逐字相同。
- 全量 Python **132 项通过**，包含模型／缓存／档位、恢复重置、重复快照及价格解析；隔离运行通过。原生 smoke **22 项通过**（K/M 边界及上下文），会话菜单／详情 UI XCTest **通过**。记录：`build/usage-pricing-python-final.log`、`build/usage-pricing-standalone.log`、`build/ios-smoke-result.json`、`build/native-ui-test.log`。未进行真机安装。
- arm64 Release 和 TrollStore IPA 重新构建、归档与签名验证通过，包名 `build/codex-link-0.1.0-usage-pricing-TrollStore.ipa`，SHA-256 `build/SHA256SUMS-usage-pricing.txt`。新统计需重启 Mac 网关并安装此 IPA；单独刷新价格快照不需重启。

## 下拉菜单样式调整（2026-11-09）

- 右上角下拉菜单宽度由 1/2 调整为当前页面的 3/5，文字和图标统一为 16pt，与消息页顶部标题同字号。外层菜单与“对话操作”入口共用标签布局、44pt 行高和按压反馈；行间使用完整分隔线，去掉原来的分组留白和描边，统一圆角材质样式。外层仍使用 SwiftUI 浮层以精确控制宽度。
- 更新现有 UI 回归的 3/5 宽度断言；专用 UI 测试通过菜单宽度、设置与工作区入口、上下文提示、长按发送和取消保留草稿，日志 `build/chat-menu-style-ui-passed.log`，结果包 `build/native-ui-20261109-031729.xcresult`。截图 `build/chat-menu-style-verified.png` 已检查。
- arm64 Release 与模拟器 UI 目标构建通过，原生冒烟 **22 项通过**；新包 `build/codex-link-0.1.0-menu-style-TrollStore.ipa` 已检查归档、签名与 SHA-256，校验记录 `build/SHA256SUMS-menu-style.txt`。本轮仅改 iOS 样式和说明文档，未修改后端，无需重启 Mac 网关；未安装真机、未提交或推送。

## 会话菜单、上下文提示与发送手势（2026-11-09）

- 消息页右上角集中为「···」半屏浮层，菜单项左侧文字右侧图标，工作区、模型与推理、消息发送设置、对话操作和新建对话从此进入；模型及发送设置从 composer 下方移除。只读／未连接时按能力禁用相应入口。
- 空输入框显示浅色已用上下文／窗口及百分比；日志解析最新有效 `last_token_usage.total_tokens` 与 `model_context_window`，不误用累计计费用量，支持压缩后数值下降，缺失时明确显示暂无数据。打开后读取并每 15 秒更新。
- 轻点发送沿用默认方式；长按 450ms 弹出底部菜单，选择仅本次发送新消息／排队／补充，保持默认偏好和既有草稿幂等行为。取消消息正文的复制／编辑／分支长按菜单，保留系统文本选择、底部回复操作和独立编辑入口。
- 全量 Python **126 项通过**，日志 `build/chat-menu-python.log`；上下文日志／HTTP 测试覆盖最近一轮、累计计费区分、压缩、无效窗口与仅更新限额的事件不清空有效样本。原生冒烟 **22 项通过**，包含百分比、缺失数据与本次发送覆盖后恢复默认方式，记录 `build/chat-menu-smoke-result.json`。
- 专用 UI XCTest 通过半屏菜单宽度断言、上下文占位提示、设置与工作区入口、长按选方式、取消保留草稿及轻点发送，日志 `build/chat-menu-ui-final-passed.log`，结果包 `build/native-ui-20261109-030350.xcresult`。
- arm64 Release、模拟器和 UI 测试目标构建通过；TrollStore／未签名 IPA 归档及签名检查通过。明确命名的新包为 `build/codex-link-0.1.0-chat-menu-TrollStore.ipa`，校验记录 `build/SHA256SUMS-chat-menu.txt`。未执行真机安装验收。
- 上下文数据投影需重启 Mac 网关，界面变更需覆盖安装新 IPA；未重启生产服务、未操作真实会话、未提交或推送。

## 静默历史预取、返回与只读删除（2026-11-09）

- 历史分页替代旧的三分之一屏阈值：仅主动向更早消息滚动，距顶部约 8 条消息时预取；同一时间只请求一页，初始布局、空轮询与向新消息滚动不触发。连续工具调用仍按单条消息计算距离和锚点。
- 应用响应前记录首条可见消息 ID 与屏幕 Y，关闭位置动画，按重排后的像素差补偿 contentOffset；懒布局暂时移除锚点时先按内容高度补偿，再按消息定位，保留继续拖动／惯性位移。新历史仅 180ms 淡入。顶部保底提示采用平方根阻尼、54pt 轻触反馈临界点、36pt 加载悬停和阻尼 0.8 弹簧回收。
- 移除整个会话身份切换时的广泛动画，并保护空会话访问；返回改用独立双层布局，底层 30% 视差、35%→0% 遮罩、38% 或右甩判定。会话反复打开、取消侧滑、完成返回和只读删除菜单的 XCTest 已通过，日志 `build/navigation-delete-ui-passed.log`。没有真实设备崩溃日志，不能据此认定已确认所有闪退原因。
- 本机只读历史新增二次确认永久删除，包括仅存 JSONL 的记录；后端跳过桌面 owner 激活，保留活动／审批／结果不明阻断、精确删除与恢复备份。全量 Python **125 项通过**，日志 `build/navigation-delete-python.log`，仅使用临时合成数据。
- 最终代码原生冒烟 **22 项通过**，包含 20 条不同高度消息前插后的精确偏移补偿，以及后续高度修正的像素锚定，记录 `build/history-prefetch-smoke-final.json`。短距离主动滚动预取两页的 XCTest 首次运行与最终版本复验均通过，日志 `build/history-prefetch-ui-final-pass.log`，结果包 `build/native-ui-20261109-022040.xcresult`。
- arm64 Release 与模拟器 UI 目标构建通过；两个 IPA 的归档、TrollStore 签名与 SHA-256 检查通过，新增明确命名产物 `build/codex-link-0.1.0-silent-history-TrollStore.ipa`，校验记录 `build/SHA256SUMS-silent-history.txt`。阻尼、轻触反馈和加载悬停的真机手感仍需设备验收。
- 未操作真实会话、未自动安装真机、未重启生产网关、未提交或推送。历史加载与返回改动覆盖安装 IPA 生效；只读删除的后端能力需要重启 Mac 网关。

## 消息导航与历史手势（2026-11-08）

- 历史分页继续监听原生滚动视图 pan 手势，触发阈值改为屏幕高度三分之一；会话页左上角改为返回按钮，返回与边缘侧滑增加跟手偏移和弹性过渡。首页移除“你的工作空间”标题行，设置入口保留在导航栏；消息行移除重复的右箭头，仅保留三个点菜单。
- iOS 模拟器和 UI 测试目标 `build-for-testing` 编译通过；随后 CoreSimulator 在安装 smoke app 时挂起，停止挂起任务后未能完成本轮 UI 测试及设备内 smoke。Release arm64 **BUILD SUCCEEDED**，TrollStore／未签名 IPA 已重建，签名、归档和 SHA-256 校验通过。返回动画仍需设备视觉验收。

## 消息阅读与文件预览更新（2026-11-07）

- 历史分页改为：在消息顶部向下拖动至少半个屏幕高度，松开后才加载一页。短拖动和横向滑动不触发，保留加载前的阅读锚点。此历史阈值已于 2026-11-08 改为三分之一屏。
- 消息及 Markdown 文件预览支持原生 GFM 表格、列对齐、行内格式、横向滚动，处理转义管道符与行内代码；代码围栏内的表格保持源码。
- 对话文件按最长文件名形成居中的共享列，其余左对齐。已授权文件引用和列表共用图片／文本预览；预览保留完成、系统打开菜单，图片提供缩放与添加相册权限。文本预览上限 2 MiB，系统打开保留完整原件。
- 工作区文件选项菜单已移到右上角，搜索框只保留搜索和清除。
- Python 全量 **123 项通过**，日志 `build/message-preview-python-final.log`。设置服务的合成测试将进程启动容差单独设为 2 秒，实际 RPC 超时断言保持 100 毫秒；产品设置传输未改。
- iPhone arm64 Release、模拟器应用和 UI 测试目标已构建通过；原生 smoke **22 项通过**，覆盖半屏手势边界、表格解析、图片／文本／UTF-16／压缩包分流。两个 IPA 的归档完整性、TrollStore 签名和 SHA-256 校验通过。
- 实际 smoke 发现并修复了清空会话后旧正文分页任务访问空会话导致的崩溃：取消旧任务，并在请求前后验证会话身份与加载代次。完整 smoke 已复验通过。模拟器截图确认表格、文件列布局和文本预览正常；专用 UI 测试已走通表格断言、文件列对齐、文本预览、完成按钮及系统打开菜单，但系统分享 sheet 与返回后打开 Markdown／图片预览的流程受 iOS Simulator 无障碍命中测试失败阻断，未验收。工作区工具栏位置已有布局断言但同样未在该流程中执行。半屏手势边界通过原生 smoke，真实触屏仍需设备验收。
- 不修改真实会话数据，不自动安装真机或重启网关。本轮阅读功能需要覆盖安装新的 IPA。

## 当前工作区快照（2026-11-07 会话操作更新）

- iOS 原生首页任务行、侧栏会话行和聊天顶栏新增完整会话菜单：重命名、置顶、未读／打开自动已读、项目归属、从最新完成轮次分支、复制深层链接／Markdown／工作目录、归档和二次确认永久删除。
- 永久删除限定本机桌面会话和精确 UUID；只删数据库中匹配的会话、历史、日志、索引、匹配的 session JSONL 与关联记录。先在 `.local/deletion-backups/` 保存逐行恢复数据；活动、审批或结果不明的会话拒绝删除。未对真实 `~/.codex` 执行删除。
- Python 全量 **123 项通过**，独立副本 **123 项通过**。定向删除覆盖精确行匹配、自动化目标、主机隔离、JSONL 匹配、WAL、符号链接、确认权限、活动会话阻断、并发日志更新和部分提交恢复。
- iPhone arm64 Release 编译及两个 IPA 构建、归档完整性和 SHA-256 校验通过；产物见 `build/codex-link-0.1.0-TrollStore.ipa` 与 `build/codex-link-0.1.0-unsigned.ipa`。
- iOS UI 测试源码已添加会话操作流程，但模拟器 UI 自动化未验收：一次性模拟器首次数据迁移耗时过长，随后安装流程未完成。既有 UI 会话流测试曾在原工作区项目流程断言失败，不应算作本次菜单通过。
- 未重启现有 Mac 网关、未真机安装、未提交或推送。生效需重启 Mac 网关并覆盖安装 IPA；配对凭据保留。实现边界见 [项目与对话操作](docs/workspace-actions.md)。

## 当前工作区快照（2026-11-05）

- 全量 Python 回归：102 项通过；隔离独立副本：102 项通过。
- iOS 模拟器构建、14 项原生冒烟检查及 iPhone arm64 Release／IPA 构建通过。TrollStore 安装和真实设备行为仍需设备验收。
- 工具／命令渲染、文件预览编辑、模型强度菜单、历史滚动与工作区能力的当前范围见 [原生 iOS 说明](docs/native-ios.md)。
- 本文以下内容是按开发阶段追加的历史记录，保留当时测试数量和边界；不得将旧计数、旧 IPA 路径或未注明状态的阶段性功能视为当前状态。
- codex exec 清理命令当前不在仓库中；相关历史章节仅记录过去实现与测试，不提供可执行入口。

## 原生 Codex Remote iOS 客户端

- iOS 已从 WKWebView 替换为 SwiftUI；Mac 上原浏览器界面仍保留。任务首页、新任务输入、项目／会话分页、原生会话流、状态页、审批、Codex 设置与附件分享均使用系统控件及网关 API。
- 对 ChatGPT.app 1.2026.300 的 ChatGPT.framework 按 Codex Remote 符号与本地化字符串定点检查：定位任务首页 composer、任务行状态、最近／项目列表、主机过滤、项目排序／分页、会话状态 sheet 和审批组件。没有复制闭源代码或资源。xref 和有限函数伪代码位于 `build/remote-analysis/`。
- Xcode iOS Simulator **build-for-testing 成功**；原生网关契约 **6 项通过**；Chromium 与 WebKit 网页回归均通过。
- IPv4／IPv6 模拟器 smoke **8 项检查通过**：Keychain、固定 TLS 与错误证书拒绝、认证和 bootstrap、项目／会话列表、只读历史、设置读回、幂等发送／重试、停止及审批响应。
- 原生 UI XCTest **1 项通过**，确认没有 WKWebView，并实际走通任务创建／发送、会话状态、设置草稿放弃确认及新建项目。日志：`build/native-ui-test.log`；结果包：`build/native-ui-20261105-005827.xcresult`。
- arm64 Release **BUILD SUCCEEDED**；已生成 `build/codex-link-0.1.0-unsigned.ipa` 与经 ad-hoc 签名校验的 `build/codex-link-0.1.0-TrollStore.ipa`，校验值见 `build/SHA256SUMS.txt`。未安装真机；TrollStore 安装及真机 Keychain 行为仍待设备验证。
- 本轮未安装真机、未连接生产网关、未改动真实 `~/.codex`、未提交或推送。

## 历史记录：双击直接清理 exec 对话（当前版本未包含）

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
- 该阶段的说明文档与清理入口已从当前仓库移除。

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
