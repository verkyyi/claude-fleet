# 文档 · Docs

两处，按读者分（EPIC #3569，#3576 定）：

| 目录 | 写给谁 | 内容 |
|---|---|---|
| [`public/`](public/) | 用 fleet 的人：自托管团队、托管客户的管理员、成员 | 按读者分三路（[`public/zh/index.md`](public/zh/index.md)）：自托管 · 托管管理员 · 成员，各有一篇快速开始；安装部署、日常使用、管理员手册、问答、排障、安全逐篇补齐。中文先行，英文在 `public/en/`，缺的英文页构建时显示「准备中」 |
| [`dev/`](dev/) | 开发和维护 fleet 的人 | 设计、协议、运维手册、弄坏它的方式——下表 |

对外页面不链进 `dev/`；开发者文档直接看代码仓库。`bin/docs-build.sh` 把 `public/` 渲成静态 HTML（每页同时保留 `.md`），地址 `/docs/<读者>/<篇>` 与 `/en/docs/…`，`bin/docs-build-selftest.sh` 守着它。问答只写在 `public/<lang>/faq.md`（官网问答、FAQPage、llms.txt 由 `bin/docs-faq.py` 从它生成）；`public/zh/troubleshooting.md` 给 `fleet doctor` 的每一行一节，体检新加一行而页面没跟上时 `bin/docs-faq-selftest.sh` 会红，`bin/docs-build.sh --troubleshooting-skeleton` 打出缺的骨架。

## 开发文档（`dev/`）

**先读**

- [PRODUCT-DIRECTION.md](dev/PRODUCT-DIRECTION.md) — 产品方向与设计原则（后续设计的依据）
- [AGENT-ADAPTER.md](dev/AGENT-ADAPTER.md) — 两种 Agent 有什么不同：适配表每列为什么不同、Codex 独有部分、原生迁移边界
- [BIN-INVENTORY.md](dev/BIN-INVENTORY.md) — 程序归属汇总、静态调用方及待删候选
- [COMPONENTS.md](dev/COMPONENTS.md) — 组件类别与保留理由（核心 / 按需 / 移除 / 待定）
- [ARCHITECTURE.md](dev/ARCHITECTURE.md) — 整体设计
- [INSTALL.md](dev/INSTALL.md) — 安装 / 卸载步骤（CLAUDE.md 让 agent 照它装）
- [TERMS.md](dev/TERMS.md) — 术语表
- [BREAK-IT.md](dev/BREAK-IT.md) — 已知的每一种弄坏方式、后果、自愈与演练
- [CI.md](dev/CI.md) — 开 PR、列车、每晚各跑什么；唯一必过的「CI 结论」、每个检查的触发规则、怎么加一个

**会话与工具**

- [FLEET-MCP.md](dev/FLEET-MCP.md) — 会话用的 `fleet` 工具服务
- [STATE.md](dev/STATE.md) — 窗口上的 Claude 状态怎么刷新
- [CLEANUP.md](dev/CLEANUP.md) · [REAP-SAFETY.md](dev/REAP-SAFETY.md) — 合并后的回收与回收安全
- [FLEET-ID.md](dev/FLEET-ID.md) — 一个窗口一个 ID：节点账本、短码与原生段
- [ID-SWITCH.md](dev/ID-SWITCH.md) — 切到「一个窗口一个 ID」：MacBook 会话照做的切换说明书（迁移 + 开关 + 回退）
- [WORKER.md](dev/WORKER.md) — 执行会话的规则背景与排障（流程由 SessionStart hook 给出）
- [TASK-LIST-DESIGN.md](dev/TASK-LIST-DESIGN.md) — Terminal / Web 任务列表设计与交互原型
- [Hub 任务完整调整方案](dev/HUB-TASK-IMPLEMENTATION-DESIGN.md) — 最终交互、唯一执行权、Hub 订阅、停止、迁移与验收。
- [HUB-TASK-SIMPLIFY.md](dev/HUB-TASK-SIMPLIFY.md) — Hub 任务与编排减法提案：原生协作、统一事件、可关闭的任务
- [TASK-ACCEPTANCE.md](dev/TASK-ACCEPTANCE.md) — 无 GitHub 任务控制：夹具验收与独立的 live 演练单
- [CODEX-AUTH-RECOVERY.md](dev/CODEX-AUTH-RECOVERY.md) — Codex 认证拒绝的恢复与验收
- [SESSION-TRANSFER.md](dev/SESSION-TRANSFER.md) — Claude / Codex 之间换手
- [CODEX-RUNTIME.md](dev/CODEX-RUNTIME.md) · [NATIVE-AGENT-BOUNDARY.md](dev/NATIVE-AGENT-BOUNDARY.md) — 已合进 AGENT-ADAPTER.md，只留指路
- [CODEX-AUTH-RECOVERY.md](dev/CODEX-AUTH-RECOVERY.md) — Codex 认证恢复与后续设计
- [AGENT-CONFIG.md](dev/AGENT-CONFIG.md) — agent 配置的团队 / 个人 / 本机三层
- [EMIT.md](dev/EMIT.md) — 会话事实外送

**客户端**

- [CLIENT.md](dev/CLIENT.md) — 客户端与按键
- [CLIENT-LOGS.md](dev/CLIENT-LOGS.md) — 客户端自己的日志
- [WEB-CHAT.md](dev/WEB-CHAT.md) — 浏览器里和会话对话（最小版）
- [WEB-TERMINAL.md](dev/WEB-TERMINAL.md) — 浏览器里打开自己的终端（中继、授权、视图）
- [LOCAL-AND-HUB.md](dev/LOCAL-AND-HUB.md) — 本机模式与联机模式

**入口与机器**

- [FLEET-HUB.md](dev/FLEET-HUB.md) — 入口（hub）
- [MANAGED-NODE.md](dev/MANAGED-NODE.md) · [MANAGED-LINUX.md](dev/MANAGED-LINUX.md) — 托管机器（macOS / Linux）
- [DOOR-SIMPLIFY.md](dev/DOOR-SIMPLIFY.md) — 门简化方案（设计，待确认）
- [HOST.md](dev/HOST.md) — 只跑会话的 Mac 怎么设
- [SHARED-MACHINE.md](dev/SHARED-MACHINE.md) — 一台机器一人一个登录
- [MULTI-MACHINE-OPS.md](dev/MULTI-MACHINE-OPS.md) — 多机运维手册
- [MULTI-ACCOUNT.md](dev/MULTI-ACCOUNT.md) — 订阅由池子挑（凭据代理）
- [CRED-SEPARATE.md](dev/CRED-SEPARATE.md) · [CRED-RELAY.md](dev/CRED-RELAY.md) — 凭据隔离、凭据转发

**记录与计划**

- [OSS-PACKAGING-PLAN.md](dev/OSS-PACKAGING-PLAN.md) — 开源打包计划（第三章是瘦身定案）
- [OSS-INVENTORY.md](dev/OSS-INVENTORY.md) — 仓库里的内部名字和地址 · 清单（`bin/oss-scan.sh`）
- [OSS-DRILL.md](dev/OSS-DRILL.md) — 外人照对外文档从零装一遍的演练单（自托管 · 托管管理员）
- [USAGE-EVIDENCE.md](dev/USAGE-EVIDENCE.md) — 使用实证

新文档放进上面两处之一，链接用相对路径；`bin/docs-links-selftest.sh` 在每个 PR 上读一遍所有链接。

- [报告监督委托：授权、读回与撤销](dev/REPORT-DELEGATION.md)
