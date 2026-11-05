# 会话进入与冷停放

会话的身份是 ID；窗口、工作目录名和 scratch key 都是可替换的承载物。
一个开放的会话可以没有窗口。入口不得因此把它当作已结束，也不得按旧 key
进入另一个会话。本文维护进入协议、排查矩阵和恢复边界（T1309 / JQVH）。

## 进入协议

1. 列表、搜索、历史跳转和网页携带 `<fleet UUID>/<session ID>`。机器和登录来自
   该行的归属，不由当前看台或相同 scratch 编号推断。
2. 看台已有窗口时按 ID 选择。没有窗口时，在目标登录查冷记录：存在则恢复同一
   ID 的窗口，等待停放页确认，再选中。远端 select 和首次 attach/reconnect 的
   `--want` 使用相同恢复入口，链路经直连还是 relay 不改变接收端判断。
3. 多个进入或消息同时到达，由每个 ID 的 `warm.lock` 合并为一次重开。此锁不占用
   session gate 的锁，包装器仍可确认停放。进入只恢复停放页，不发送新话或启动新任务。
4. 没有冷记录，或原始历史、工作区、容量门拒绝重开，保留身份并明确说明窗口暂不可用。
   在详情选择「恢复」，由原有 `reopen --check --rebuild` 检查后执行；机器失联先修复连接。
   不猜测缺失历史，不在其它机器新建一个同名会话冒充恢复。
5. `@peer_cur` 是上次进入的记录，不是窗口仍然存在的证明。重复进入也向目标端确认。

冷停放入口最长容纳重开及停放确认的时间；旧的 3 秒 peer 请求期限不能覆盖这一步。
面板在自己的底部显示「正在唤醒」，等待期间不通过通知增加 tmux 状态行。
返回面板时安排完整重绘，避免尺寸变化后复用旧 curses 画面。排队的 resize 事件不再清除
刚返回的错误消息，只有实际按键才确认它。独立跳转仍使用普通通知。

## 入口 × 状态矩阵

表中「保留」表示既有路径经代码追踪仍适用；「修复」表示本次新增回归覆盖。
这些是实现和隔离演练结论，不把未执行的生产故障注入当作通过。

| 入口 | 本地冷停放 | 远端 / 另一登录冷停放 | 热停放 | 开放 ID 无窗口无冷记录 | 真正已结束 |
| --- | --- | --- | --- | --- | --- |
| 看台面板进入 | 原专用 cold 行能恢复，普通 ID 不能 → 两者均恢复 | 原 select 报已不在 → 目标端恢复后选中（修复） | 选停放页，下一句走 gate（保留） | 原笼统已不在 → 窗口不可用及详情恢复入口（修复） | 展示历史，显式恢复（保留） |
| 手机 Termius 看台 | 与电脑同协议 | 同一远端 select；窄终端隔离实测（修复） | 同一停放页（保留） | 同一明确提示与动作 | 同一历史详情 |
| 搜索 / 更多会话 / 已归档中的开放行 | 同 ID 进入 | 不再用旧 key；归档属性不改变归属（修复） | 与主列表相同 | 不因归档猜测新窗口 | 历史页而非自动新建 |
| 恢复动作 | 原 reopen 校验历史；冷进入优先 warm | 原 worker_resume 在目标登录校验；开放缺窗行也提供恢复 | 有窗口则拒绝重复 reopen | 校验 transcript，必要时显式 rebuild | 同 ID、同 native segment 恢复 |
| 网页会话列表 / web-go / terminal attach | attach `--want` 先恢复（修复） | 网页切往目标登录，再 attach 恢复（修复） | gate/terminal 原路径 | 服务端拒绝而非换到邻居 | 原历史入口 |
| web chat 发一句话 | 原 gate.say 已 warm，但库存 can_talk=false → 允许冷行进入 gate（修复） | hub 发往所属登录，同一 gate | gate 唤醒并确认投递（保留） | gate 返回 no_session；没有提交新对话 | 原关闭/继续规则 |
| MCP send / peer send | 原解析窗口前不 warm → 显式身份发送先 warm（修复） | worker_message 接收端先 warm，再重新按 ID 解析（修复）；relay 使用同接收端 | 原 park wake（保留） | 明确无目标，不发送 | 原关闭及继任规则，不猜 key |
| park wake / 定时任务 | 带 wake 合同的停放禁止冷却，故不产生此组合 | 合同在目标登录本地执行，同一保护 | 原 tick → gate.say（保留） | tick 等 restore；doctor 列出孤儿，不伪造会话 | 停止执行及合同撤销原规则 |
| fleet-open / ticket URL | 只负责送达链接；实际进入走网页或看台上述路径 | 同左，不能用本机 key 替代 URL 身份 | 同左 | 页面历史/恢复或明确拒绝 | 原历史页 |
| hub go / place / move | go 归入进入；place 是新任务/启动，不自动复用冷 ID | go 按目标归属；move 的迁移校验仍要求真实承载 | 保留原门禁 | place/move 明确拒绝缺少承载；先恢复原 ID | 不以旧 key 偷换目标 |
| fleet-history resume | 保留原历史校验；开放冷 ID 从进入路径接回 | 在持有历史的登录执行恢复 | 已有窗口不重复恢复 | exact transcript + 原工作区/rebuild 校验 | 显式恢复，保留 ID 与原对话 |

## 承载异常矩阵

| 异常 | 修前风险 | 现在的边界 / 处理 | 证据 |
| --- | --- | --- | --- |
| 冷窗口被回收 | 看台只会找窗口；远端不可达 | 目标登录先 warm | cold-entry-peer 隔离两个节点、延迟 4 秒、50 列手机画面 |
| 相同 scratch key 复用 | board 按旧 worker key 匹配到不同 ID | ID 不同禁止匹配；进入地址携带 ID | cold-entry 单测、board 测试 |
| 普通 reap 后 ID 仍 open | 没有恢复入口、无人解释 | doctor 命名孤儿；详情恢复校验，不静默关闭 | cold-entry doctor 单测 |
| 重启后整个 tmux 消失 | 进入读不到窗口 | fleet-restore 的原有 admit / unfinished / restore.down 规则；恢复期间进入可重试，doctor 显式列缺窗 | 既有 restore 路径审查；本次不新增自动重启服务 |
| install 换版，旧窗口还在 | 把版本旧当作不可达 | 有窗口直接进入；oldcfg 原有 broken/stale 判断独立 | 不修改启动时固定的工具和 hook 表 |
| relay / SSH 重连 | 仅 select 修复会漏掉首次 attach | `rv_thin_window` 的 `--want` 也恢复；消息接收端同样恢复 | remote select / attach 共享 helper；消息 target 单测 |
| 冷工作区被 autoclean | 没窗口会被判可删，之后 reopen 拒绝 | cold.json 所有者保留目录；目录已缺失则 doctor 报明原因，显式 rebuild 仍由历史证据裁决 | protect-worktree 检查；既有 no-worktree 冷却演练 |
| 手动名称、首句话消失 | reopen 只带 --name，下句话重新写 task_line | 新冷记录保存选项；重开在放行 agent 前从冷记录/ID 手动命名事件恢复 | cold-entry take / legacy title 单测 |
| 并发进入 + 消息 | 重复新建窗口或过早返回 | 单 ID warm 锁，确认后才交给选择/发送 | concurrent enter/send 单测 |
| 面板等待中通知改变尺寸 | curses 阻塞期间通知增加状态行，旧图残留 | popup 自己画进度；通知只入记录；返回安排全图重绘 | 真实 curses 复现 resize 清除错误；修后窄屏进度/失败可见、每行只画一次。不把其它未复现重影归因于此 |

## 守护与存量

`fleet doctor --park` 的 `session-entry` 行检查本登录实际窗口和本地 ID 账本，列出
「ID open + 无窗口 + 无有效 cold.json」以及冷工作区缺失项，并给出恢复命令。
不把 hub 缓存里其它机器的 ID 当成本地孤儿；远端应在各自登录检查。

已有 cold.json 无需迁移：新增选项可缺省，旧记录的手动标题从 ID 命名事件读取。
更新目标节点和看台所在节点后，原冷行在第一次进入或发消息时恢复；无需批量启动 agent，
也无需操作者手工 warm。实际仍无法通过历史校验的记录保留，并由 doctor 和恢复动作说明原因。

回归入口：`fleet-cold-entry-selftest.py`、`fleet-cold-entry-peer-selftest.sh`、
`fleet-park-cold-selftest.py`、`park-cold-inventory-selftest.py`；BREAK-IT `park-cold-entry`。
