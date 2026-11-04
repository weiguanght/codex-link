# Mac 网关状态栏程序

已安装到 `~/Applications/Codex网关.app`，通过用户 LaunchAgent `com.hoto.codex-link.gateway` 登录后启动。无需终端常驻，也无需管理员授权。

状态栏网络图标提供运行状态、查看日志和退出网关。网关异常退出后自动重试；从菜单主动退出后，本次登录不再自动启动，下次登录恢复启动。双击项目原有的 `启动Mac网关.command` 会打开状态栏程序。

运行时仍使用本项目 `run-mac.py`、原 `.local` 配对数据及默认端口 18443。网关位于下载目录，需保留项目路径；移动项目后须更新 App 内 `Contents/Resources/gateway.json` 的路径并重新签名。首次出现下载目录访问提示时，需要允许。

日志：`~/Library/Logs/CodexLink/gateway.log`，状态栏程序日志为同目录 `statusbar.log`。启动记录可能包含本机网络地址，日志目录权限为 700。

自启配置：`~/Library/LaunchAgents/com.hoto.codex-link.gateway.plist`。要取消登录自启并停止后台程序，可运行：

```sh
launchctl bootout "gui/$(id -u)/com.hoto.codex-link.gateway"
rm ~/Library/LaunchAgents/com.hoto.codex-link.gateway.plist
```

取消自启后仍可手动打开状态栏 App。需要恢复原终端方式时，在项目目录运行 `python3 run-mac.py`，不要与正在运行的网关重复启动。

首次构建安装命令为 `python3 mac/statusbar/install.py`，需要 Xcode 命令行工具。安装脚本遇到已有 App 或自启文件时会停止，以免覆盖现有安装。

改动范围：新增状态栏 App 及构建安装脚本；原 `.command` 在 App 存在时打开 App，未安装 App 时保留原来的终端启动方式。未修改网关服务实现、配对数据、网络或 RustDesk。登录自启已注册；尚未通过重启 Mac 实测。

实际验证：Swift 编译、App 签名和 LaunchAgent plist 检查通过；launchd 任务处于 running、enabled 状态；18443 监听进程的父进程为状态栏程序，本机和局域网 HTTPS 身份接口均返回 200；切换前后配对数据校验一致。原终端进程已结束，当前网关无需终端保持打开。RustDesk 后台服务及安卓 USB 连接保持正常。
