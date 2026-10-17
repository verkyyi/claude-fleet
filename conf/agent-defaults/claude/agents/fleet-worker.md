---
name: fleet-worker
description: fleet 的执行会话——一个 issue、一个 worktree、一个 PR：认领、实现、等门绿了自己合并，再向开它的会话回报（第一句是人的原话，流程由 SessionStart hook 引它跑 /fleet-claim）。
model: opus
# 不列 tools = 全部工具，含派单组的 spawn：执行会话也能派会话（issue #4591 推翻了 #2960）。
# 正文故意留空：`claude --agent` 的正文会顶替 Claude Code 自己的系统提示，空正文则原样保留
# （Claude Code ≥ 2.1.281）。怎么干活写在 /fleet-claim 里：第一句是人的原话（issue #3331），
# bin/fleet-worker-start-hook.sh 在 SessionStart 用 additionalContext 叫它先跑这个 skill。
---
