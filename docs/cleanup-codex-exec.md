# 双击清理 codex exec 对话

文件：[`清理CodexExec对话.command`](../清理CodexExec对话.command)，位于项目根目录。

## 使用

1. 退出 Codex Desktop、所有 Codex CLI / exec / app-server 和 codex-link 网关。
2. 在 Finder 中双击 **清理CodexExec对话.command**。
3. 脚本直接删除匹配记录，终端显示完成数量或错误。

**不预览、不备份、不要求输入确认、不移入废纸篓。** 双击就是执行，删除后不能依靠本脚本恢复。脚本不会替你结束正在运行的进程。

这是一个可单独复制使用的 `.command` 文件，已赋予可执行权限，不依赖单独的 `.py` 文件。内部调用本机 **Python 3.10+ 标准库**处理 SQLite / JSON；不需要 pip 依赖。默认检查 Homebrew、`/usr/local/bin` 和系统 Python 路径。找不到兼容 Python 时只报错，不执行删除。

默认数据目录为 `$CODEX_HOME`，没有设置时使用 `~/.codex`。一般无需输入命令；特殊目录仍支持：

```sh
# 以下命令同样直接删除，没有预览或确认步骤
./清理CodexExec对话.command --codex-home /path/to/.codex
./清理CodexExec对话.command --database state_5.sqlite
```

多个 `state_*.sqlite` 并存时必须明确指定文件名，不猜测哪个版本正在使用；也可设置 `CODEX_STATE_DATABASE`。旧的 `scripts/cleanup-codex-exec.py` 已被这个单文件入口替代，旧预览／备份／确认参数不再提供。

## 删除范围

- 以 `threads.source = 'exec'` 为主要依据，也识别精确的 JSON 字符串 `"exec"`。
- 只有 `source` 缺失或为空时，才使用精确的 `originator = 'codex_exec'` 作为兼容依据；不会覆盖明确的 `cli` 或 `vscode` 来源。
- 扫描 `sessions/` 和 `archived_sessions/` 的 JSONL 第一条 `session_meta`，包括归档记录、同一会话的多个日志副本、仅日志存在的 exec 会话。
- 已经缺失日志的 exec 数据库记录也会清理。
- 删除匹配的数据库 `threads` 行，以及对应的 `thread_dynamic_tools`、`thread_attachments`、`thread_spawn_edges` 关联记录。
- 从 `session_index.jsonl` 去掉匹配 ID 的标题索引，保留其他行和无法解析的行。

**不按标题或正文是否包含 `codex exec` 筛选，不按只读标记筛选。** 非 exec 的 CLI、桌面对话、子代理对话和项目不删除。删除父子关系边不会自动删除另一端的会话。

不修改账号、配置、`.local/`、独立诊断 `logs_*.sqlite`、`history.jsonl`、全局 UI 偏好或迁移状态；不删除已有旧备份目录。未执行 `VACUUM` 或安全擦除，数据库文件大小不保证立即缩小。

## 校验和失败行为

没有预览／确认步骤，但仍保留必要的删除范围校验：

- 使用 SQLite 当前数据库及 WAL，不复制数据库；获取写事务后筛选目标。
- 路径／来源冲突、同一日志被其他会话引用、未知关联表或未审查触发器会中止，避免扩大删除范围。
- 不跟随符号链接；无法分类、元信息过大或损坏的日志会跳过并显示警告。
- 在删除文件前先校验 SQL、外键及日志是否仍是刚扫描的文件。
- 标题索引使用临时文件原子替换；临时文件只保存要保留的行，不是备份，正常结束会清理。

**数据库事务和文件删除不是一个原子事务。** 出错时，尚未提交的数据库操作尽量回滚，但已经删除的日志或已经改写的索引不会恢复。错误会报告已永久删除的日志数量及数据库／索引状态，不会假称全部恢复。遇到提交中断或进程被强制终止，需要检查实际状态；所有写入进程应保持关闭。

操作完成后重新启动 Codex / 网关并刷新会话列表。

## 验证

14 项清理测试只使用一次性合成 HOME：

- 真正执行 `.command`（复制到含空格的独立目录），不提供 stdin 或确认参数，验证没有独立 `.py` 依赖。
- exec 精确筛选、归档／孤立／重复／缺失日志、关联表和标题索引、WAL 中的记录。
- 不创建备份，保留非 exec 会话和项目。
- 日志变化中止、部分删除失败如实报告、来源和路径冲突、未知结构拒绝。

```sh
python3 -m unittest discover -s tests -p test_cleanup_exec.py -v
python3 -m unittest discover -s tests -v
python3 scripts/test-standalone.py
```

本次开发没有对真实 Codex 目录执行该 `.command`，没有删除真实对话，也没有自动结束生产进程。
