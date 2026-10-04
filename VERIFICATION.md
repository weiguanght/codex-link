# 验证记录

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
