# 程序文件归属盘点

由 `python3 bin/fleet-bin-inventory.py --markdown > docs/dev/BIN-INVENTORY.md` 生成。
这是生成时分支的快照；实时数据用 `--summary` / `--tsv`，逐文件全部引用用 `--references`。
组件、类别与归属模式来自 [COMPONENTS.md](COMPONENTS.md)，规则按表顺序首个匹配。

```text
总数	1303
已归类	1302
待删候选	19
未归类	0
```

已归类与待删候选可以重叠；未归类 = 既无组件、也无候选理由的文件。
覆盖 bin/ 的全部 Git 非忽略文件（含隐藏助手、数据、自测和新增未提交文件）；
统计会随主干增加/删除文件变化，不把历史 1104 当成固定分母。

## 如何读调用方

扫描 bin、hooks、launchd、systemd、commands、skills、plugins、mod、conf、
tokenledger、extras、.github 和 shell；按完整文件名 token 匹配 source / exec / 路径引用，
并匹配 Python 模块名。自身引用不计，每个引用文件只计一次。
调用方是静态引用文件，包含注释和文档提及，不能证明实际执行或可达；
动态拼接、外部安装、操作者直接调用可能没有字面引用，候选不是删除许可。
通用拷贝/打包不是调用；文档中的盘点表不反过来充当调用方。
CI 的 `*-selftest.sh` 通配符发现单独计为 run-selftests.sh 引用；
自测优先继承同名被测脚本（允许省略 fleet- 前缀），再取最长被测名称前缀；
其余依显式规则，跨组件检查归构建与验证。被 CI 自测引用链触达的测试/夹具保留；
只有测试引用的生产文件仍列候选，不能据此删除测试专用依赖。

## 组件汇总

| 组件 | 类别 | 文件数 |
|---|---|---:|
| EPIC 批次（`fleet-epic`） | 按需 | 16 |
| Fleet MCP（status / where / context / open / show） | 核心 | 22 |
| GitHub 工作流（issue-bridge / pr-refresh / webhook） | 核心 | 21 |
| Hub（`tokenledger`） | 核心 | 72 |
| Web 接入（web-chat / web-console） | 核心 | 11 |
| 上下文连续性（`fleet-handoff` / `fleet-compact-resume` / `fleet-context` / `handoff`） | 核心 | 29 |
| 仓库接入与帮助（`fleet-add-repo` / `fleet-help`） | 按需 | 14 |
| 休眠（sleep） | 待定 | 10 |
| 会话恢复与事件记录（`fleet-codex-session.py`、`fleet-emit.sh`、`handoff-latch-reset-hook.sh`、`fleet_loop_mark.py`、历史/退出/压缩钩子） | 核心 | 66 |
| 会话状态钩子（`set-claude-state.sh`） | 核心 | 1 |
| 会话迁移与历史（`fleet-move` / `fleet-history`） | 核心 | 18 |
| 内容送达与阅读（`fleet-open` / `doc-preview`） | 按需 | 9 |
| 凭据代理（cred-proxy） | 核心 | 5 |
| 压缩后任务恢复（`bin/refocus-hook.sh`） | 核心 | 2 |
| 反馈（`fleet-feedback`） | 按需 | 3 |
| 宿主清理与保护（memguard / diskguard / cleanup / worktree-autoclean） | 核心 | 65 |
| 待删候选（暂无组件） | — | 1 |
| 执行会话与跨会话协作 MCP（claim / issue / PR / evidence / spawn / await / children / send / report / file_issue / ask） | 核心 | 63 |
| 执行会话（`fleet-claim` / worker start hook） | 核心 | 42 |
| 承载节点（managed-node / spot-node） | 核心 | 94 |
| 接入中继（cred-relay / gh-relay） | 核心 | 10 |
| 操作者终端集成（iterm2 / laptop-url-opener.sh） | 按需 | 2 |
| 操作者设备位置（`mod/fleet/hooks/where.ts` / `bin/fleet-where-hook.sh`） | 核心 | 5 |
| 收集与账本观察（collect / ledger-watch） | 待定 | 17 |
| 更新说明（`whats_new` / `bin/fleet-whats-new.sh`） | 按需 | 2 |
| 构建与验证（ci-runner / workflows / 默认安装审计） | 核心 | 312 |
| 浏览器（`fleet-browser`） | 按需 | 2 |
| 版本维护（install-sync / base-sync） | 核心 | 58 |
| 登录说明规则块（`CLAUDE.md` / `AGENTS.md` 的 `fleet:agent-defaults` 块） | 移除 | 2 |
| 终端状态与节点连接（spinner / peerlink） | 待定 | 11 |
| 终端看台与薄客户端 | 核心 | 168 |
| 编排特殊实现（`fleet-orchestrate` 插件、角色座位、状态快照） | 移除 | 2 |
| 账号与代理启动 | 核心 | 81 |
| 配置与插件装配 | 核心 | 34 |
| 项目依赖复用 | 按需 | 4 |
| 额度观察（quotawatch） | 核心 | 13 |
| 首次使用（`fleet-onboard`） | 核心 | 16 |

## 待删候选（逐项复核，未删除任何文件）

| 文件 | 组件 | 类型 | 引用文件数 | 首个引用 | 候选理由 |
|---|---|---|---:|---|---|
| `bin/classify-hook.sh` | 会话恢复与事件记录（`fleet-codex-session.py`、`fleet-emit.sh`、`handoff-latch-reset-hook.sh`、`fleet_loop_mark.py`、历史/退出/压缩钩子） | 程序/数据 | 0 | `—` | 扫描范围内无静态引用；复核外部入口及动态拼接 |
| `bin/fixtures/claim-grounding/missing-usage.jsonl` | 构建与验证（ci-runner / workflows / 默认安装审计） | 测试/夹具 | 0 | `—` | 扫描范围内无静态引用；复核外部入口及动态拼接 |
| `bin/fixtures/claim-grounding/sidecar.jsonl` | 构建与验证（ci-runner / workflows / 默认安装审计） | 测试/夹具 | 0 | `—` | 扫描范围内无静态引用；复核外部入口及动态拼接 |
| `bin/fixtures/crash/panic-full-2026-10-03-094530.0002.panic` | 构建与验证（ci-runner / workflows / 默认安装审计） | 测试/夹具 | 0 | `—` | 扫描范围内无静态引用；复核外部入口及动态拼接 |
| `bin/fleet-bin-inventory.py` | 构建与验证（ci-runner / workflows / 默认安装审计） | 程序/数据 | 1 | `bin/fleet-bin-inventory-selftest.sh` | 仅测试/夹具引用；复核人工入口及测试专用依赖 |
| `bin/fleet-claim-grounding-measure.sh` | 构建与验证（ci-runner / workflows / 默认安装审计） | 程序/数据 | 1 | `bin/fleet-claim-grounding-measure-selftest.py` | 仅测试/夹具引用；复核人工入口及测试专用依赖 |
| `bin/fleet-guide.sh` | 首次使用（`fleet-onboard`） | 程序/数据 | 1 | `bin/fleet-one-per-login-selftest.sh` | 仅测试/夹具引用；复核人工入口及测试专用依赖 |
| `bin/fleet-hub-latency.sh` | Hub（`tokenledger`） | 程序/数据 | 0 | `—` | 扫描范围内无静态引用；复核外部入口及动态拼接 |
| `bin/fleet-hub-service.py` | Hub（`tokenledger`） | 程序/数据 | 2 | `bin/daemon-nofile-selftest.sh` | 仅测试/夹具引用；复核人工入口及测试专用依赖 |
| `bin/fleet-list.sh` | 终端看台与薄客户端 | 程序/数据 | 2 | `bin/pool-not-a-fleet-selftest.sh` | 仅测试/夹具引用；复核人工入口及测试专用依赖 |
| `bin/fleet-machine-policy.sh` | 承载节点（managed-node / spot-node） | 程序/数据 | 2 | `bin/fleet-break-it-hub-selftest.sh` | 仅测试/夹具引用；复核人工入口及测试专用依赖 |
| `bin/fleet-native-plugin-cli-selftest.py` | 构建与验证（ci-runner / workflows / 默认安装审计） | 测试/夹具 | 0 | `—` | 扫描范围内无静态引用；复核外部入口及动态拼接 |
| `bin/fleet-node-supervisor-counterexample-envelope.py` | 承载节点（managed-node / spot-node） | 程序/数据 | 1 | `bin/fleet-node-supervisor-selftest-budget.py` | 仅测试/夹具引用；复核人工入口及测试专用依赖 |
| `bin/fleet-phone-mcp.py` | Fleet MCP（status / where / context / open / show） | 程序/数据 | 1 | `bin/fleet-phone-mcp-selftest.sh` | 仅测试/夹具引用；复核人工入口及测试专用依赖 |
| `bin/fleet-report-stats.sh` | 收集与账本观察（collect / ledger-watch） | 程序/数据 | 0 | `—` | 扫描范围内无静态引用；复核外部入口及动态拼接 |
| `bin/fleet_native_continue.py` | 待复核 | 程序/数据 | 4 | `bin/fleet-native-cleanup-selftest.py` | 仅测试/夹具引用；复核人工入口及测试专用依赖 |
| `bin/no-direct-gh.baseline` | 构建与验证（ci-runner / workflows / 默认安装审计） | 程序/数据 | 2 | `bin/fleet-break-it-selftest.sh` | 仅测试/夹具引用；复核人工入口及测试专用依赖 |
| `bin/nogh_live_driver.py` | 构建与验证（ci-runner / workflows / 默认安装审计） | 程序/数据 | 2 | `bin/nogh-live-selftest.py` | 仅测试/夹具引用；复核人工入口及测试专用依赖 |
| `bin/session-shell/codex` | 执行会话（`fleet-claim` / worker start hook） | 程序/数据 | 1 | `bin/fleet-session-shell-agent-selftest.sh` | 仅测试/夹具引用；复核人工入口及测试专用依赖 |

## 未归类

无。
