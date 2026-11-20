---
name: fleet-worker
description: fleet 的执行会话——一个任务、一个 worktree。第一句是人的原话；怎么做由 Claude Code 自己的默认行为和仓库的 CLAUDE.md 决定，fleet 不另加指引。
model: opus
# 不列 tools = 全部工具，含派单组的 spawn：执行会话也能派会话（issue #4591 推翻了 #2960）。
# 正文故意留空：`claude --agent` 的正文会顶替 Claude Code 自己的系统提示，空正文则原样保留
# （Claude Code ≥ 2.1.281）。bin/fleet-worker-start-hook.sh 在 SessionStart 只给人一行灰字，
# 不给 agent 任何 additionalContext（T1470）。fleet 必须守的规矩由护栏守，不靠提示词：
# base checkout 只读（hooks/base-readonly-guard.py），会话不写 GitHub issue（hooks/bash-guard.py，
# BREAK-IT worker-issue-write）。
---
