# 派单规则（编排）

接手编排的会话（/fleet-orchestrate）怎么派，按这张表；派出去的每张单子末尾写「按规则 N 派发」（`file_issue` 的 `rule: N`）。

- **编号永不复用**：删掉的规则号留空，旧单子上的「按规则 N」永远查得到当时那条。
- **档位**：`auto` 自己定 · `default` 到点按默认走（你可翻案） · `ask` 必须问你 · `off` 不用。
- 这一份是 fleet 自带的（bin/fleet_rules.py 读它；个人层、本机层按编号覆盖，读一版后删 — issue #3114）。

| 编号 | 角色 | 条件 | 动作 | 档位 | 关键词 |
|---|---|---|---|---|---|
| 1 | orchestrator | 一个仓库里的一处改动，已经清楚 | 建单并 spawn：一单一 worker 一 PR，正文写清怎么算做完 | auto | |
| 2 | orchestrator | 几处独立改动，或跨仓库 | 跑 /fleet-epic-plan 出设计页，托管给人看，等确认 | auto | |
| 3 | orchestrator | 已确认的 EPIC | 开驱动会话跑 /fleet-epic-run（--as epic-driver，--repo 是 EPIC 的仓库） | auto | |
| 4 | orchestrator | 值得做但不是现在 | 只建单不 spawn，带 priority；等别的单加 blocked | auto | |
| 5 | orchestrator | 只是个问题，不是活 | 直接回答，不建单 | auto | |
| 6 | orchestrator | 以 Go/TS 为主且有明确测试，或机械性改动（批量改名、补测试、修 lint） | 派给 Codex：加标签 agent:codex | auto | agent:codex |
| 7 | orchestrator | Claude 额度 ≥ 85%（doctor 的 quota 行）时新派的机械性改动 | 派给 Codex：加标签 agent:codex | auto | agent:codex |
| 8 | orchestrator | 其余（跨 bash + 文档 + 多文件、要拿主意、要读很多上下文） | 派给 Claude；一单从头到尾只用一个 agent | auto | |
| 9 | orchestrator | 要产出东西（代码、设计页、报告、长调研）或要跑超过一两分钟 | 派 fleet worker（file_issue 带 spawn），从不用 subagent 干 | auto | |
| 10 | orchestrator | 为回答眼下这段对话要查点东西 | subagent 只做一次只读、有界的查找（Explore / Plan） | auto | |
| 11 | orchestrator | 单子没写优先级 | 问你（mcp__fleet__ask），不替你定默认值 | ask | |
| 12 | orchestrator | 范围、拿不准放哪个仓库 | 问你（mcp__fleet__ask） | ask | |
| 20 | orchestrator | 要管理员能力的活（演练、开号、删号）——worker 被「需要管理员登录（有 sudo）」拒了 | 编排经管理员 SSH（m4-admin / m5-admin）自己跑；不推给人，也不给 worker 的登录加 sudo（#2842） | auto | |
