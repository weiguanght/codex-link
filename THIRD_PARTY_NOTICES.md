# 第三方代码与许可证

本项目新增的连接、配对和 iOS 客户端代码遵循根目录 `LICENSE`（MIT）。以下内置组件保留其原始版权与许可证；根目录许可证不替代第三方许可证。

## codex-mobile-bridge

- 上游：https://github.com/try2love/codex-mobile-bridge
- 版本：1.3.2，来自本次目录内提供的源码快照（未联网下载或核验远端 tag）。
- Copyright (c) 2026 try2love；MIT。
- 位置：`vendor/codex-mobile-bridge/bridge/`、`vendor/codex-mobile-bridge/web/`。
- 原始许可证：`vendor/codex-mobile-bridge/LICENSE`。
- 采用 23 个 Python 运行时模块（含 `__init__.py`）及完整网页资源。为新建会话功能扩展了 `bridge/create.py`、`bridge/httpd.py` 和 `bridge/service.py`，其余快照文件未修改；不包含不使用的 Electron、旧启动器、更新器或部署工具。
- 文件清单、来源记录、SHA-256：`vendor/codex-mobile-bridge/UPSTREAM.json`。这是本地快照完整性校验，不是远端来源真实性证明。
- `web/link-presentation.js` 基于该版本的 `web/presentation.js` 改编，沿用其 MIT 许可证与版权；移除了思考摘要显示设置。
- `web/link-timeline.js` 的分页投影与正文展开逻辑基于该版本的 `web/timeline.js` 改编，沿用其 MIT 许可证与版权；新增默认收起的工具活动分组。

## iOS 代码高亮

| 组件 | 版本 | 许可证路径 |
| --- | --- | --- |
| Highlight.js（核心与所选语言） | 11.12.0 | `ios/CodexLink/SyntaxAssets/HighlightJS-LICENSE`（BSD-3-Clause） |
| Prism（核心与 Agda、Bicep、Pascal、Zig） | 1.30.0 | `ios/CodexLink/SyntaxAssets/Prism-LICENSE`（MIT） |

`scripts/bundle-syntax.py` 从固定 SHA-256 的 npm 归档生成内置资源。Runestone、Tree-sitter 语法的来源记录与许可证位于 `ios/Packages/Runestone/`。

## iOS 数学公式

iOS-LaTeX Light 使用 RaTeX 0.1.16 和 CoreText。iOS-LaTeX 与 RaTeX 使用 MIT 许可证，KaTeX 字体使用 SIL OFL 1.1。内置来源和许可文件随应用发布。[iOS-LaTeX 来源说明](ios/Packages/iOS-LaTeX/UPSTREAM.md)

## 随网页内置的组件

| 组件 | 版本 | 许可证路径 |
| --- | --- | --- |
| markdown-it | 15.0.2 | `vendor/codex-mobile-bridge/web/vendor/markdown-it.LICENSE` |
| KaTeX（含随包字体） | 0.18.9 | `vendor/codex-mobile-bridge/web/vendor/katex/LICENSE` |
| markdown-it-texmath | 1.0.0 | `vendor/codex-mobile-bridge/web/vendor/texmath.LICENSE` |

以上原始来源、包完整性和升级说明保留在 `vendor/codex-mobile-bridge/web/vendor/README.md`。运行时从本地服务提供全部网页资源，不依赖 CDN。

没有复制 A 的闭源代码；没有捆绑 Codex Desktop、Python 或 Apple 系统框架。自包含的是本项目的源码与网页依赖，不是整个系统运行环境。
