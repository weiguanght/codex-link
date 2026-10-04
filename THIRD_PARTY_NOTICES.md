# 第三方代码与许可证

本项目新增的连接、配对和 iOS 客户端代码遵循根目录 `LICENSE`（MIT）。以下内置组件保留其原始版权与许可证；根目录许可证不替代第三方许可证。

## codex-mobile-bridge

- 上游：https://github.com/try2love/codex-mobile-bridge
- 版本：1.3.2，来自本次目录内提供的源码快照（未联网下载或核验远端 tag）。
- Copyright (c) 2026 try2love；MIT。
- 位置：`vendor/codex-mobile-bridge/bridge/`、`vendor/codex-mobile-bridge/web/`。
- 原始许可证：`vendor/codex-mobile-bridge/LICENSE`。
- 采用 23 个 Python 运行时模块（含 `__init__.py`）及完整网页资源。没有修改这些文件的内容；不包含不使用的 Electron、旧启动器、更新器或部署工具。
- 文件清单、来源记录、SHA-256：`vendor/codex-mobile-bridge/UPSTREAM.json`。这是本地快照完整性校验，不是远端来源真实性证明。

## 随网页内置的组件

| 组件 | 版本 | 许可证路径 |
| --- | --- | --- |
| markdown-it | 15.0.2 | `vendor/codex-mobile-bridge/web/vendor/markdown-it.LICENSE` |
| KaTeX（含随包字体） | 0.18.9 | `vendor/codex-mobile-bridge/web/vendor/katex/LICENSE` |
| markdown-it-texmath | 1.0.0 | `vendor/codex-mobile-bridge/web/vendor/texmath.LICENSE` |

以上原始来源、包完整性和升级说明保留在 `vendor/codex-mobile-bridge/web/vendor/README.md`。运行时从本地服务提供全部网页资源，不依赖 CDN。

没有复制 A 的闭源代码；没有捆绑 Codex Desktop、Python 或 Apple 系统框架。自包含的是本项目的源码与网页依赖，不是整个系统运行环境。
