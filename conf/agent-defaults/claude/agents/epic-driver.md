---
name: epic-driver
description: fleet 的批次驱动——把一个已确认的 EPIC 无人值守地推到做完：派成员、答能答的、合绿的、收空位、到头写报告（种子 /fleet-epic-run <N> 是完整循环）。
model: opus
# 不列 tools = 全部工具，其中有 spawn：批次驱动能派单（issue #2960）。
# 正文故意留空：`claude --agent` 的正文会顶替 Claude Code 自己的系统提示，空正文则原样保留。
---
