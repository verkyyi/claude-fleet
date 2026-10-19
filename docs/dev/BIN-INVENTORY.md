# 程序文件归属盘点

由 `python3 bin/fleet-bin-inventory.py --markdown > docs/dev/BIN-INVENTORY.md` 生成。
这是生成时分支的快照；实时数据用 `--summary` / `--tsv`，逐文件全部引用用 `--references`。
组件、类别与归属模式来自 [COMPONENTS.md](COMPONENTS.md)，规则按表顺序首个匹配。

```text
总数	1269
已归类	1269
待删候选	3
人工入口	10
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
另外三种引用也算：`fleet <词>` 按命令写出时（行首、引号、括号里）指 bin/fleet 分派到的
`fleet-<词>.{py,sh}`；按目录读的夹具/放上 PATH 的目录，引用目录即引用其下全部文件；
CI 自测引用链读到的数据文件（基线、夹具、表）。没人按名调用、由人手动运行的程序
在文件头写 `# bin-inventory: 人工入口 — <谁在用>`，单列「人工入口」，不计候选。

## 组件汇总

| 组件 | 类别 | 文件数 |
|---|---|---:|
| EPIC 批次（`fleet-epic`） | 按需 | 16 |
| Fleet MCP（status / where / context / open / show） | 核心 | 18 |
| GitHub 工作流（issue-bridge / pr-refresh / webhook） | 核心 | 26 |
| Hub（`tokenledger`） | 核心 | 69 |
| Web 接入（web-chat / web-console） | 核心 | 9 |
| 上下文连续性（`fleet-handoff` / `fleet-compact-resume` / `fleet-context` / `handoff`） | 核心 | 31 |
| 仓库接入与帮助（`fleet-add-repo` / `fleet-help`） | 按需 | 15 |
| 休眠（sleep） | 待定 | 10 |
| 会话恢复与事件记录（`fleet-codex-session.py`、`fleet-emit.sh`、`handoff-latch-reset-hook.sh`、`fleet_loop_mark.py`、历史/退出/压缩钩子） | 核心 | 59 |
| 会话状态钩子（`set-claude-state.sh`） | 核心 | 1 |
| 会话迁移与历史（`fleet-move` / `fleet-history`） | 核心 | 18 |
| 内容送达与阅读（`fleet-open`） | 按需 | 9 |
| 凭据代理（cred-proxy） | 核心 | 5 |
| 压缩后任务恢复（`bin/refocus-hook.sh`） | 核心 | 2 |
| 宿主清理与保护（memguard / diskguard / cleanup / worktree-autoclean） | 核心 | 63 |
| 执行会话与跨会话协作 MCP（claim / issue / PR / evidence / spawn / await / children / send / report / file_issue / ask） | 核心 | 63 |
| 执行会话（`fleet-claim` / worker start hook） | 核心 | 46 |
| 承载节点（managed-node） | 核心 | 84 |
| 接入中继（cred-relay / gh-relay） | 核心 | 10 |
| 操作者终端集成（iterm2 / laptop-url-opener.sh） | 按需 | 2 |
| 操作者设备位置（`mod/fleet/hooks/where.ts` / `bin/fleet-where-hook.sh`） | 核心 | 5 |
| 收集与账本观察（collect / ledger-watch） | 待定 | 17 |
| 更新说明（`bin/fleet-whats-new.sh`） | 移除 | 1 |
| 构建与验证（ci-runner / workflows / 默认安装审计） | 核心 | 307 |
| 浏览器（`fleet-browser`） | 按需 | 2 |
| 版本维护（install-sync / base-sync） | 核心 | 58 |
| 登录说明规则块（`CLAUDE.md` / `AGENTS.md` 的 `fleet:agent-defaults` 块） | 移除 | 2 |
| 终端状态与节点连接（spinner / peerlink） | 待定 | 11 |
| 终端看台与薄客户端 | 核心 | 172 |
| 编排特殊实现（`fleet-orchestrate` 插件、角色座位、状态快照） | 移除 | 1 |
| 账号与代理启动 | 核心 | 80 |
| 配置与插件装配 | 核心 | 34 |
| 项目依赖复用 | 按需 | 4 |
| 额度观察（quotawatch） | 核心 | 13 |
| 首次使用（`fleet-onboard`） | 核心 | 6 |

## 待删候选（逐项复核，未删除任何文件）

| 文件 | 组件 | 类型 | 引用文件数 | 首个引用 | 候选理由 |
|---|---|---|---:|---|---|
| `bin/fleet-client-stats.py` | 终端看台与薄客户端 | 程序/数据 | 1 | `bin/fleet-client-stats-selftest.sh` | 仅测试/夹具引用；复核人工入口及测试专用依赖 |
| `bin/tokenledger-flaky.sh` | 构建与验证（ci-runner / workflows / 默认安装审计） | 程序/数据 | 2 | `bin/no-direct-gh-selftest.sh` | 仅测试/夹具引用；复核人工入口及测试专用依赖 |
| `bin/tokenledger-split-agent.sh` | 构建与验证（ci-runner / workflows / 默认安装审计） | 程序/数据 | 2 | `bin/fleet-break-it-ci-selftest.sh` | 仅测试/夹具引用；复核人工入口及测试专用依赖 |

## 人工入口（不计候选）

| 文件 | 组件 | 谁在用 |
|---|---|---|
| `bin/fleet-bin-inventory.py` | 构建与验证（ci-runner / workflows / 默认安装审计） | 维护者重生成 docs/dev/BIN-INVENTORY.md（--markdown），见 COMPONENTS.md |
| `bin/fleet-claim-grounding-measure.sh` | 构建与验证（ci-runner / workflows / 默认安装审计） | 认领/落地测量，docs/dev/CLAIM-MEASUREMENT.md |
| `bin/fleet-hub-service.py` | Hub（`tokenledger`） | 管理员装 hub 的 launchd 服务，docs/dev/FLEET-HUB.md · INSTALL.md |
| `bin/fleet-list.sh` | 终端看台与薄客户端 | 列出 fleet，README「bin/fleet-list.sh」 |
| `bin/fleet-machine-policy.sh` | 承载节点（managed-node） | 管理员设每人可用机器，docs/public/*/admin/machines.md |
| `bin/fleet-native-plugin-cli-selftest.py` | 构建与验证（ci-runner / workflows / 默认安装审计） | 显式运行的原生插件探针，docs/dev/NATIVE-AGENT-BOUNDARY.md |
| `bin/fleet-report-stats.sh` | 收集与账本观察（collect / ledger-watch） | EPIC #935 回报质量指标，docs/dev/ARCHITECTURE.md |
| `bin/fleet-whats-new.sh` | 更新说明（`bin/fleet-whats-new.sh`） | 旧会话 hook 表里的静默兼容入口（#4324），下一批删 |
| `bin/fleet_native_continue.py` | 执行会话（`fleet-claim` / worker start hook） | 旧 Codex 会话一次续接（#4775），docs/dev/NATIVE-OBSERVE.md |
| `bin/nogh_live_driver.py` | 构建与验证（ci-runner / workflows / 默认安装审计） | C9 实测由 owner 手动跑（它的镜像与文档随 #4904 去掉） |

## 未归类

无。
