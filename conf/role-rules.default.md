# 规则表（自带）

编排会话怎么派、管家哪些自己答 / 按默认 / 必须问你，都按这张表（issue #2786）。
派出去的每张单子末尾写「按规则 N 派发」。

- **编号永不复用**：删掉的规则号留空，旧单子上的「按规则 N」永远查得到当时那条。
- **你的改动按编号覆盖**：同号整行换掉；档位写 `off` 就是删掉这条；你新加的从 100 起编。
- **档位**：`auto` 自己定 · `default` 到点按默认走（你可翻案） · `ask` 必须问你 · `off` 不用。
- **关键词**：`ask` 行写了 `never:<类>` 的，关键词命中任何一个，那个问题就判为 `never:<类>`，
  永不按默认、永不自答——不管提问的会话怎么声明。

| 编号 | 角色 | 条件 | 动作 | 档位 | 关键词 |
|---|---|---|---|---|---|
| 1 | orchestrator | 一个仓库里的一处改动，已经清楚 | 建单并 spawn：一单一 worker 一 PR，正文写清怎么算做完 | auto | |
| 2 | orchestrator | 几处独立改动，或跨仓库 | 跑 /fleet-epic-plan 出设计页，托管给人看，等确认 | auto | |
| 3 | orchestrator | 已确认的 EPIC | 开驱动会话跑 /fleet-epic-run（--role epic-driver，--repo 是 EPIC 的仓库） | auto | |
| 4 | orchestrator | 值得做但不是现在 | 只建单不 spawn，带 priority；可自动开工的加 autofill，等别的单加 blocked | auto | |
| 5 | orchestrator | 只是个问题，不是活 | 直接回答，不建单 | auto | |
| 6 | orchestrator | 以 Go/TS 为主且有明确测试，或机械性改动（批量改名、补测试、修 lint） | 派给 Codex：加标签 agent:codex | auto | agent:codex |
| 7 | orchestrator | Claude 额度 ≥ 85%（doctor 的 quota 行）时新派的机械性改动 | 派给 Codex：加标签 agent:codex | auto | agent:codex |
| 8 | orchestrator | 其余（跨 bash + 文档 + 多文件、要拿主意、要读很多上下文） | 派给 Claude；一单从头到尾只用一个 agent | auto | |
| 9 | orchestrator | 要产出东西（代码、设计页、报告、长调研）或要跑超过一两分钟 | 派 fleet worker（file_issue 带 spawn），从不用 subagent 干 | auto | |
| 10 | orchestrator | 为回答眼下这段对话要查点东西 | subagent 只做一次只读、有界的查找（Explore / Plan） | auto | |
| 11 | orchestrator | 单子没写优先级 | 问你（mcp__fleet__ask），不替你定默认值 | ask | |
| 12 | orchestrator | 范围、拿不准放哪个仓库 | 问你（mcp__fleet__ask） | ask | |
| 13 | steward | 批次 parent 的共同约定、发起人拍板或它链接的设计页写明了答案 | 自己答，附出处 | auto | |
| 14 | steward | 问题带了建议或默认，到点没人答 | 按默认走，在批次 parent 记「默认拍板」，你可翻案 | default | |
| 15 | steward | 问题没带默认（旧格式的提问） | 等你，从不按默认 | ask | |
| 16 | steward | 改 fleet 的铁律 | 必须问你（never:rule） | ask | claude.md, agents.md, break-it, 铁律, 改约定, 删约定 |
| 17 | steward | 花钱 | 必须问你（never:money） | ask | 付费, 花钱, 云机器, 购买, 充值, 账单, 预算, billing, purchase, paid plan |
| 18 | steward | 对外发布 | 必须问你（never:publish） | ask | stable, 发布, 对外, 公开, publish, release |
| 19 | steward | 批次收尾留下的 followup（发布检查没过、要不要重部署入口） | 只进决定单，从不自答 | ask | |
| 20 | orchestrator | 要管理员能力的活（演练、开号、删号）——worker 被「需要管理员登录（有 sudo）」拒了 | 编排经管理员 SSH（m4-admin / m5-admin）自己跑；不推给人，也不给 worker 的登录加 sudo（#2842） | auto | |
| 21 | steward | worker 报「需要管理员登录（有 sudo）」、问谁来跑演练 | 不是「只能人做」：转给编排按规则 20 跑；只有编排也没有管理员 SSH 时才进决定单 | auto | |
