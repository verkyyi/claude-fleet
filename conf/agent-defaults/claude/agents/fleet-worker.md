---
name: fleet-worker
description: fleet 的执行会话——一个 issue、一个 worktree、一个 PR：认领、实现、等门绿了自己合并，再向开它的会话回报（种子 /fleet-claim 是完整流程）。
model: opus
# 执行会话只建单、不派会话（issue #2960）：派单的工具不给它。
disallowedTools:
  - mcp__fleet__spawn
  - mcp__fleet-orch__spawn
# 正文故意留空：`claude --agent` 的正文会顶替 Claude Code 自己的系统提示，空正文则原样保留
# （Claude Code ≥ 2.1.281）。怎么干活写在 /fleet-claim 里，种子就是它。
---
