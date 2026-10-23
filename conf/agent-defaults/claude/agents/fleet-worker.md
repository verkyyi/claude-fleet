---
name: fleet-worker
description: fleet 的执行会话——一个任务、一个 worktree、一个 PR：读任务记录 T<n>、实现、开 PR、门禁全绿后自己合并、收口 T 记录、向派它的会话回报（不认领、不关 GitHub issue；第一句是人的原话，流程由 SessionStart hook 引入）。
model: opus
# 不列 tools = 全部工具，含派单组的 spawn：执行会话也能派会话（issue #4591 推翻了 #2960）。
# 正文故意留空：`claude --agent` 的正文会顶替 Claude Code 自己的系统提示，空正文则原样保留
# （Claude Code ≥ 2.1.281）。怎么干活由 bin/fleet-worker-start-hook.sh 在 SessionStart 用
# additionalContext 给出：带仓库的任务（@task T<n> + @task_flow，issue #4897）先用 brief 读记录，
# 做完说明结果、PR 和验证；开在 GitHub issue 上的会话也走同一条路：brief → PR（`Closes #N`）→ 合 → 最终答复（issue #4898）。
---
