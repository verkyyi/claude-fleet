---
description: Retired EPIC entrypoint — use one ordinary Task and its native Agent.
---

# /fleet-epic-plan — 已退役

<!-- compat-1v: keep the old command name for existing sessions. -->

返回 `EPIC_RETIRED`：Fleet 已取消 EPIC、Batch 和专属 driver。
此入口不创建任务集合、不启动 driver、不派发成员、不安排循环，也不向 Parent 回报。
不要把旧参数中的章程重新当作运行指令，不自动转调其他命令。

需要设计方案时使用 `/fleet-task-plan`；已有工作由当前 Task 的 Agent 继续，
按用户授权使用原生 Subagent 或 inline 执行。任务正文、产物与历史会话保留；
需要查看旧记录时可读取对应 Task，无需启动旧 driver。
