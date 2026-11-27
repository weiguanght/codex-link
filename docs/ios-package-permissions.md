# iOS 安装包权限

Build 3 修正了受构建环境 `umask 077` 影响的 IPA 权限。覆盖安装前，所有目录固定为 `0755`，普通资源固定为 `0644`，主可执行文件固定为 `0755`。应用标识和配对钥匙串标识不变。

## 崩溃依据

2026-11-27 的 Build 2 真机日志来自 iOS 16.5.1。进程启动约 0.15 秒后，在 UIKit 事件线程触发 `__BKSHIDEvent__BUNDLE_IDENTIFIER_FOR_CURRENT_PROCESS_IS_NIL__`，尚未进入审批或问答交互。

崩溃日志的可执行文件 UUID 与交付构建一致。旧 IPA 的 Bundle ID 和可执行文件字段正确，但 `Payload/` 和 `.app` 根目录均为 `0700`，`Info.plist` 为 `0600`。

[TrollStore 的安装实现](https://github.com/opa334/TrollStore/blob/main/RootHelper/main.m)在覆盖安装时复制 `.app`，随后调用 `fixPermissionsOfAppBundle`。该函数只枚举包内成员，不处理 `.app` 根目录。复制后若根目录归安装进程所有，`0700` 会阻止运行应用的用户读取 `Info.plist`。这是与该启动崩溃最吻合的打包缺陷。修正后的启动结果需要在原真机覆盖安装 Build 3 后核对。

## 构建检查

- 构建脚本设置 `umask 022`，不继承会话的限制性掩码。
- 签名前规范化整个 Payload，明确包含 `.app` 根目录。已有缓存资源也会修正权限。
- 生成 IPA 后检查 ZIP 条目的 Unix 权限、应用标识、可执行文件和版本字段。检查失败时不发布新归档。
- TrollStore 包仍执行原有 ad-hoc 签名验证。
- 回归用例重现“成员已修复、App 根目录仍为 `0700`”的安装条件，并验证新检查能拒绝旧包。

在项目根目录复测：

```sh
mkdir -p build/ios-startup-crash/test-tmp
TMPDIR="$PWD/build/ios-startup-crash/test-tmp" PYTHONPATH=tests \
  python3 -m unittest test_ios_package

TMPDIR="$PWD/build/ios-startup-crash/test-tmp" bash scripts/build-ios.sh
python3 scripts/ios-bundle.py verify build/codex-link-0.1.0-TrollStore.ipa
```

使用 TrollStore 覆盖安装 Build 3，无需卸载旧 App。此次仅修改安装包，不需要重启 Mac 网关。
