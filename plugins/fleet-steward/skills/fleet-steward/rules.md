# 答题规则（管家）

管家哪些自己答 / 按默认 / 必须问你，按这张表。`ask` 行写了 `never:<类>` 的，关键词命中任何一个，那个问题就判为 `never:<类>`，永不按默认、永不自答。

- **编号永不复用**：删掉的规则号留空，旧单子上的「按规则 N」永远查得到当时那条。
- **档位**：`auto` 自己定 · `default` 到点按默认走（你可翻案） · `ask` 必须问你 · `off` 不用。
- 这一份是 fleet 自带的（bin/fleet_rules.py 读它；个人层、本机层按编号覆盖，读一版后删 — issue #3114）。

| 编号 | 角色 | 条件 | 动作 | 档位 | 关键词 |
|---|---|---|---|---|---|
| 13 | steward | 批次 parent 的共同约定、发起人拍板或它链接的设计页写明了答案 | 自己答，附出处 | auto | |
| 14 | steward | 问题带了建议或默认，到点没人答 | 按默认走，在批次 parent 记「默认拍板」，你可翻案 | default | |
| 15 | steward | 问题没带默认（旧格式的提问） | 等你，从不按默认 | ask | |
| 16 | steward | 改 fleet 的铁律 | 必须问你（never:rule） | ask | claude.md, agents.md, break-it, 铁律, 改约定, 删约定 |
| 17 | steward | 花钱 | 必须问你（never:money） | ask | 付费, 花钱, 云机器, 购买, 充值, 账单, 预算, billing, purchase, paid plan |
| 18 | steward | 对外发布 | 必须问你（never:publish） | ask | stable, 发布, 对外, 公开, publish, release |
| 19 | steward | 批次收尾留下的 followup（发布检查没过、要不要重部署入口） | 只进决定单，从不自答 | ask | |
| 21 | steward | worker 报「需要管理员登录（有 sudo）」、问谁来跑演练 | 不是「只能人做」：转给编排按规则 20 跑；只有编排也没有管理员 SSH 时才进决定单 | auto | |
