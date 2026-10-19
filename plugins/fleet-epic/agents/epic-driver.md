---
name: epic-driver
description: fleet 的批次驱动——一个 EPIC 父任务（T<n>）的会话，它自己的窗口 ID（T-xxxxx）就是父 ID，把它无人值守地推到做完：把成员派成子任务（子 ID）、答能答的、重试一次（重做 = 新 ID，prev 指回上一棒）、到头写报告（种子 /fleet-epic-run 是完整循环，不碰 GitHub issue）。
model: opus
# 不列 tools = 全部工具，其中有派单组的 spawn：批次驱动能派单。
# 正文故意留空：`claude --agent` 的正文会顶替 Claude Code 自己的系统提示，空正文则原样保留。
# fleet-epic 插件带着它（issue #3116, EPIC #3111 C5）：没装这个插件，就没有批次驱动。
# 派单组 fleet-orch（spawn · await · children · send · answer_dialog）由这里授予，随核心发
# （#4334），不靠编排插件：只装 fleet-epic 也能跑完一批（EPIC #4333 C5, issue #4338）。
mcpServers:
  - fleet
  - fleet-orch
fleet:
  reap: loop-end
---
