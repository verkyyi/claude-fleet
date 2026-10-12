# 文档 · Docs

两处，按读者分（EPIC #3569，#3576 定）：

| 目录 | 写给谁 | 内容 |
|---|---|---|
| [`public/`](public/) | 用 fleet 的人：自托管团队、托管客户的管理员、成员 | 快速开始、安装部署、日常使用、管理员手册、问答、排障（C5 起逐篇补齐；中文先行，英文在 `public/en/`） |
| [`dev/`](dev/) | 开发和维护 fleet 的人 | 设计、协议、运维手册、弄坏它的方式——下表 |

对外页面不链进 `dev/`；开发者文档直接看代码仓库。

## 开发文档（`dev/`）

**先读**

- [ARCHITECTURE.md](dev/ARCHITECTURE.md) — 整体设计
- [INSTALL.md](dev/INSTALL.md) — 安装 / 卸载步骤（CLAUDE.md 让 agent 照它装）
- [TERMS.md](dev/TERMS.md) — 术语表
- [BREAK-IT.md](dev/BREAK-IT.md) — 已知的每一种弄坏方式、后果、自愈与演练
- [DECISIONS.md](dev/DECISIONS.md) — 决定的格式、默认拍板

**会话与工具**

- [FLEET-MCP.md](dev/FLEET-MCP.md) — 会话用的 `fleet` 工具服务
- [STATE.md](dev/STATE.md) — 窗口上的 Claude 状态怎么刷新
- [CLEANUP.md](dev/CLEANUP.md) · [REAP-SAFETY.md](dev/REAP-SAFETY.md) — 合并后的回收与回收安全
- [WORKER-SLEEP.md](dev/WORKER-SLEEP.md) — worker 休眠与唤醒
- [SESSION-TRANSFER.md](dev/SESSION-TRANSFER.md) · [CODEX-RUNTIME.md](dev/CODEX-RUNTIME.md) — Claude / Codex 之间换手
- [AGENT-CONFIG.md](dev/AGENT-CONFIG.md) — agent 配置的团队 / 个人 / 本机三层
- [ISSUE-BRIDGE.md](dev/ISSUE-BRIDGE.md) · [WEBHOOK.md](dev/WEBHOOK.md) · [EMIT.md](dev/EMIT.md) — issue 事件、PR / CI 状态、会话事实外送

**客户端**

- [CLIENT.md](dev/CLIENT.md) — 客户端与按键
- [CLIENT-LOGS.md](dev/CLIENT-LOGS.md) — 客户端自己的日志
- [LOCAL-AND-HUB.md](dev/LOCAL-AND-HUB.md) — 本机模式与联机模式

**入口与机器**

- [FLEET-HUB.md](dev/FLEET-HUB.md) — 入口（hub）
- [MANAGED-NODE.md](dev/MANAGED-NODE.md) · [MANAGED-LINUX.md](dev/MANAGED-LINUX.md) — 托管机器（macOS / Linux）
- [HOST.md](dev/HOST.md) — 只跑会话的 Mac 怎么设
- [SHARED-MACHINE.md](dev/SHARED-MACHINE.md) — 一台机器一人一个登录
- [MULTI-MACHINE-OPS.md](dev/MULTI-MACHINE-OPS.md) — 多机运维手册
- [MULTI-ACCOUNT.md](dev/MULTI-ACCOUNT.md) — 多个订阅账号与自动切换
- [CRED-SEPARATE.md](dev/CRED-SEPARATE.md) · [CRED-RELAY.md](dev/CRED-RELAY.md) — 凭据隔离、凭据转发
- [PHONE-MCP.md](dev/PHONE-MCP.md) — 手机 MCP

**记录与计划**

- [OSS-PACKAGING-PLAN.md](dev/OSS-PACKAGING-PLAN.md) — 开源打包计划（第三章是瘦身定案）
- [OSS-INVENTORY.md](dev/OSS-INVENTORY.md) — 仓库里的内部名字和地址 · 清单（`bin/oss-scan.sh`）
- [USAGE-EVIDENCE.md](dev/USAGE-EVIDENCE.md) — 使用实证
- [CLAIM-MEASUREMENT.md](dev/CLAIM-MEASUREMENT.md) — 认领与摸底的测量方法

新文档放进上面两处之一，链接用相对路径；`bin/docs-links-selftest.sh` 在每个 PR 上读一遍所有链接。
