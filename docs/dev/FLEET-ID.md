# 一个窗口一个 ID：节点账本与原生段

EPIC T497 的 C1（节点账本）、C2（hub 镜像）、C3（⌘P 面板的编号列）、C4（结果、父子、通信）、C5（EPIC 批次）与 C6（迁移命令与切换开关）。设计页：「会话与 hub 任务（T）的关系 · 设计稿」第 6 版（§3、§4.1、§4.2、§4.6）。
这一层目前**只双写**：旧 T 记录与执行权照旧，谁都不读这里做决定，直到 C7 打开切换开关。

## ID 与短码

- 完整 ID 就是窗口的 `@fleet_id`（UUIDv4，`fleet_fid_mint` 开窗时铸），形状不变。
- 短码 = `T-` + 完整 ID 的小写 Crockford base32 前缀（去掉 `i l o u`），默认 5 位；
  本登录已知的另一个 ID 与它同前缀时加长一位，以此类推（像 git 的短 SHA）。
- 「已知」= 账本里的 ID + `ids/.known`（hub 镜像回写，C2）+ 活着的窗口。
- 寻址接受短码或完整 ID：`fleet_win_for_addr`、`fleet-peer-send.sh`、MCP `send` 的 `to`。
  一个短码对上两个 ID 就拒绝并列出两个候选（rc 2），从不猜。输入大小写不敏感，`i/l/o` 按 `1/1/0` 读。
- 窗口上 `@task_short` 记它的短码（开窗时 `fleet-id.sh open` 盖，之后钩子补）。

## 账本

`$FLEET_CONF_DIR/ids/<ID>.ndjson`，一行一个事件，每个带 `(id, seq)`，追加时持 flock：

| 事件 | 谁写 | 内容 |
|---|---|---|
| `opened` | 两个 spawner（`dash-issue-session.sh` / `dash-raw-session.sh`，后台）；没有时由钩子补一条 `lazy` | agent（解析后的）· window · repo · title · key · task · short |
| `native` | SessionStart 钩子 | 新的一段（agent · 原生 id · trigger · seg），或 `compact: true` 给当前段记一次压缩 |
| `result` | `fleet-id.sh result`（C4 接 report） | state · summary · pr |
| `closed` | `fleet-id.sh close`（C4 接回收） | reason |
| `short` | `fleet-id.sh push`（hub 回告） | hub 给的更长短码（只会变长） |
| `moved` | fleet-move 的新机器（待接） | hub 把这个 ID 改挂到新机器 |

## 原生段怎么追加（§4.2）

`hooks/settings-hooks.json` 的 SessionStart（不带 matcher，每种 source 都跑）调 `fleet-id.sh hook`；
Codex 用同一张表，在每个线程的第一轮跑到它。

| 进来的 | 做什么 |
|---|---|
| Claude `startup` | 没有段 ⇒ 段 1（startup）；同一个原生 id ⇒ 不动；另一个 ⇒ 新段 resume |
| Claude `resume` | 另一个 id ⇒ 新段 resume，记下它原来属于哪个 ID 的哪一段（`from`），那一段还活着就记 `conflict` |
| Claude `clear` | 新段；handoff 周期打的 `/clear`（它盖的 `@id_next_trigger handoff:<epoch>`，10 分钟内有效，读即删；或 `@handoff_cycle`）⇒ handoff，否则 clear |
| Claude `compact` | 当前段压缩 +1，不开段 |
| Codex（`FLEET_CODEX_LAUNCHER_PID` 与窗口的 `@cc_launcher_pid` 对得上） | 另一个 id ⇒ 新段：startup ⇒ new（同窗口的新线程），resume ⇒ resume |
| 任意 | agent 与上一段不同 ⇒ transfer |

钩子永不挡 Agent、永不输出：不在 tmux、headless 的 `claude -p`、坏 stdin 都直接退出 0；
写不进账本时把这一段记在窗口的 `@id_retry`，下一次钩子先补写。`FLEET_ID_HOOK=0` 关掉它。

## 命令

```
fleet-id.sh get <ID | T-code> [--json]   ID、短码、opened、各段（agent · 原生 id · 起止 · trigger · 压缩次数）、结果
fleet-id.sh resolve <ID | T-code>        → 完整 ID；rc 1 没有，rc 2 有歧义（候选在 stderr）
fleet-id.sh short <ID>
fleet-id.sh open|native|result|close …   见脚本头
fleet-id.sh push [<ID>…]                 把账本推给 hub 镜像（C2）
fleet-id.sh status|route|children|await|history|continue|reopen …   结果、父子、接班（C4，下节）
```

## 结果、父子、通信（C4，§4.3–§4.5）

- **结果挂在 ID 上**：会话自己的 `report`（`fleet-report-parent.sh`，没有 `--win`；已接任务那条路在
  `fleet_task_control.py report` 里）在 ID 账本上写一条 `result`（state · summary · pr · agent），
  可以多次，**最新的算**（S2）；合并检查改判的状态（armed ⇒ waiting）照实写。仍双写旧 T 记录。
- **关窗即结束**：fleet 有意关窗（回收 `dash-reap.sh`、合并后 `fleet-cleanup.sh`、`fleet-worker-stop.sh`、
  agent 退出 `session-end-hook.sh`、闲置回收）走 `fleet_win_retire <win> <sock> <why>`，第三个词让账本记 `closed`；
  move / migrate / park 不给 why，ID 在下一个窗口接着用。关了没报过结果 = **已退出**（S7）。
- **状态**（`fleet-id.sh status`）：冲突（等你）＞ 最新结果（已完成 / 失败 / 等你）＞ 活着 = 运行中 ＞ 已退出。
  **冲突**：两个活着的 ID 当前段是同一个原生会话；关掉一个，另一个恢复（S9）。
- **接班与转交**（`fleet-id.sh route`，`fleet_id_take`）：发给一个 ID 的回报 / 消息——它开着就给它；
  关了就顺「谁的 prev 是它」找最新的活 ID（接班）；没有就交给它的 `parent`（同样规则往上）；
  再没有 ⇒ 你的提醒（`global/orphan-reports.ndjson`）。本机账本不认识的 ID 走旧路（hub、键）。
  `fleet-report-parent.sh`、`fleet_task_control.py receive`、`fleet-peer-send.sh T-<code>` 都按它走；
  已接任务的回报**不再核父任务代次与原生进程**——/clear、交接、换 Agent、重开都不换 ID（BREAK-IT `report-parent-cleared`）。
- **父子**：两个派单入口开账本时记 `--parent`（派它的会话的 ID，`fleet_spawn_parent_id`：交来的 worker_id 的后半；
  否则 `--origin` 本身就是 ID 时就是它——编排、驱动、no-repo 会话这类没有键的父会话，`task` 派单都走这条；
  否则那个键对上的唯一窗口的 ID。hub 派的没有父）；`fleet-id.sh children <ID>` /
  `fleet-children.sh --ids` 列出 parent 是它的 ID。C9 之前 `task` 派出的子 ID 没记上父：
  `fleet-id.sh parents [--apply]` 按它 `opened` 的 `task` 读 hub 记录的 parent_session（后半）补一条只填空的
  `opened {parent}` 并推给 hub 镜像（默认只列不写；没有 hub ⇒ 3）。
- **等待**：`fleet-await.sh T-<code> | fid:<ID> | <ID>` → `fleet-id.sh await`：有不是回合边界（waiting / idle）的
  结果就答（MERGED / SUCCEEDED 0，其余 1），关了没结果 EXITED 4，超时 3；本机没有账本时读 hub 镜像那一条。
- **历史**（`fleet-history.sh ids|show|continue|reopen`）：按 ID 一行（短码 · 状态 · 结果 · 关闭时间 · 标题），
  `show` 展开原生段。「从这一段继续」= `continue <ID> --seg N --exec`：新窗口、新 ID、`prev` = 它，它保持已关（S8）；
  「恢复这个窗口」= `reopen <ID> --exec`：同一个 ID 续最新一段，账本记 `reopened`（hub 同样清掉关闭）。
  开窗经 `dash-raw-session.sh --resume <原生 id> --prev <ID> | --fid <ID>`；一个 `--resume` 的开窗（以及别的窗口里手动
  `claude --resume`）自动把被续那一段的 ID 记成 prev。
- **worktree 记 ID**：`fleet_worktree_id_mark` 在 worktree 的 git 目录写 `fleet-id`（旁边的 `fleet-task` 照旧）。

`bin/fleet-id-results-selftest.sh` 钉住 S2、S7、S8、S9、接班 / parent / 提醒、父 /clear 后回报照常送达、task 派发的子 ID 带 parent 与回填（TASKPAR）。

## EPIC 批次（C5）

批次的父任务 T<n> 是记录，父 **ID** 是驱动窗口的 ID（父记录 worker_id 的后半，短码就是 ⌘P 上那一行）；
每个成员的会话是一个子 ID。`fleet-epic-tick.py` 每个 tick 读一次 `fleet-id.sh family <父 ID> <子记录的 ID>…`：
本机账本 + hub 的 `GET /v1/node/ids?parent=<父 ID>&id=<ID>…`（父是它的、点名的、以及顺 `prev` 接上它们的每一个 ID；
旧 hub 不认这个查询时逐个读点名的）。

- **成员 = 一串棒**：它的记录按先后排，每条记录后面跟着顺 `prev` 接上它的 ID（重做、「从这一段继续」）；
  **最新一棒说了算**。一棒的结局：记录有 outcome 用记录的；没有就看 ID 最新结果（merged / succeeded ⇒ 成、
  failed ⇒ 败）；ID 关了没结果 ⇒ `exited`，算一次失败（BREAK-IT `epic-member-dead-record`）。
- **重做 = 新 ID**：重试的派单正文末尾带 `<!-- fleet:prev <上一棒 ID> -->`，`dash-raw-session.sh` 对带 `--task`
  的话读出它当 `--prev`，新窗口的账本记 prev。
- **依赖按 ID 解除**（拍板 6）：章程「依赖顺序」表（或成员段的 `**依赖**` 行）里的成员键；被依赖的成员最新一棒成了才放行，
  之前是 `waiting`；被依赖的卡住 ⇒ 它也卡住。表外的单（T493 这类）留给驱动判断。
- **批次标记**：`epic-running.d/<slug>-T-xxxxx`（tick 的 `mark`，父 ID 的短码）带一行 `task: T<n>`；
  盖新标记时删掉同一批旧的 `<slug>-T<n>`，`--clear T<n>` 也清得掉它。
- tick 的 JSON 多了 `parent_id` · `parent_short` · `mark`，每个成员的 `id` · `short` · `ids`（每一棒，带 prev），
  重试项的 `prev`。没有 ID、没有 hub ⇒ 只读记录，跟以前一样。

`bin/fleet-epic-id-selftest.sh` 是演练批次：两个成员从规划到报告，其中一个重做一次。

## hub 镜像（C2）

hub 只是镜像：`fleet_ids`（完整 ID 主键 · owner · short · machine · login · title · agent · repo ·
issues · body · parent · prev · aliases · asked · parked · opened_at · closed_at · close_reason · seq）+
`fleet_id_natives`（段）+ `fleet_id_results`（结果），都由节点账本按 `(ID, seq)` 折叠而来，
随时能从账本重放（`tokenledger/hub/store/fleet_ids.go`）。旧 `fleet_tasks` 不动。

- **推送**：`fleet-id.sh push [<ID>…]` 从 hub 上次说它有的 seq（`ids/.hub/<ID>.seq`）接着推
  `POST /v1/node/ids {id, events}`（节点令牌，只在 `fleet-id.sh _post` 里读）。重推的部分 hub 跳过，
  中间缺了 hub 回它的 seq、节点从那儿重推；hub 重建成空的会再收到整本账。开窗（open）、钩子、
  result、close 后台各推一次；清理 tick 每轮把所有账本补推一遍——hub 断着时开的窗口恢复后补齐（S10）。
  没有 hub / 节点令牌 ⇒ exit 3，什么都不发；hub 没应 ⇒ 75，下一轮接着推。`FLEET_ID_PUSH=0` 关掉自动推送。
- **短码在用户内唯一**：hub 登记时按本 owner 全部 ID 核一次，撞了就把**后登记的**加长；
  回答里带上，节点写一条 `short` 事件并改窗口的 `@task_short`（S12）。`GET /v1/node/ids` 是本 owner
  的 ID 表，每 10 分钟最多拉一次写进 `ids/.known`，本机选短码、解析短码都把它算进去——5 位对上两个就拒绝并列候选。
  `GET /v1/node/ids/<ID|T-code>` 读一条，歧义回 409 `AMBIGUOUS`。
- **完整 ID 重复即拒**：hub 已有、来自另一台机器（或另一个 owner）的同一个完整 ID ⇒ 409 `DUPLICATE_ID`，
  什么都不存（整机克隆，S13）。节点记 `ids/.hub/<ID>.refused`、在那个窗口上盖 `@id_hub_error`、
  发一条 `id-duplicate` 提醒，这本账不再推；窗口照常跑，新开的窗口不受影响。只有以 `moved` 开头的推送能把 ID 改挂到别的机器。
- **issues**（§3.5）：opened 的 `issue` / `ticket_ref` / `issue-<N>` 键 + repo，result 的 `issues`
  （`fleet-id.sh result --issues o/r#N,…`，PR 正文的 Fixes/Closes）。

`bin/fleet-id-hub-selftest.sh` 钉节点这一半的 S10、S12、S13；hub 那一半是
`hub/store/fleet_ids_test.go`、`hub/api/fleet_node_ids_test.go`。

## 面板（C3）

⌘P 每一行的编号列就是窗口自己的短码（`fleet_view.py` 的 `id_*`，读的是这本账，不另存一份）：
本地行取窗口的 `@fleet_id`，别的机器的行取 worker_id 的后半；账本的 `short`（hub 加长过的那个）与本机已知 ID
算出的最短前缀取较长者。没有 ID 的窗口编号列留空——不显示 issue 号、不显示前任、不写 `T?`；hub 任务的
`T<n>` 只当别名，搜得到、行上不画（保留一个版本）。

| 列 / 状态 | 从哪来 |
|---|---|
| Agent | 最新原生段的 agent；没有段取 `opened` 的；都没有写灰色「未知」。没有账本的旧窗口照旧读 `@cc_agent` |
| 状态 | 活着的窗口：在干活 / 等你照 tmux；空闲时最新一条结果说了算（`failed` ⇒ ✗，`merged`/`succeeded`/`done` ⇒ ✓，`blocked` ⇒ 等你，S2）。已回收的行：账本 `closed` 且没结果 ⇒ ◌ 已退出（S7） |
| 冲突 | 两个活着的窗口最新段是同一个原生 id ⇒ 两行都进「等你」、红 `!`，操作页写原因；关掉一个另一个就恢复（S9） |
| 搜索 | 行自己的 issue + 账本的 issues（opened 的 issue / ticket_ref / `issue-<N>` 键、result 的 issues、派单原话里的 `#N`），整数精确匹配；短码、完整 ID、别名也搜得到 |

Tab 操作页在动作下面列出：编号 + 完整 ID、别名、每一段（agent · 起止 · trigger · 压缩次数）；
`ids/.hub/<ID>.seq` 还没有 ⇒「未登记到 hub」，`.refused` ⇒ 红字「hub 拒收」（S13）。离线时这些都照常，
只是读本机账本。`bin/fleet-view-id-selftest.sh` 钉住它。

`bin/fleet-id-selftest.sh` 钉住 §4.6 的 S1、S3–S6、S11 与短码/寻址/钩子的规矩。

## 迁移与切换开关（C6，设计页 §5、§5.1）

**迁移**：`fleet-id.sh migrate [--apply] [--only T1,T2] [--json]` → `POST /v1/node/ids/migrate`
（节点令牌；运营方的机器看所有人的记录，别人只看自己的）。hub 把每条还没迁过的旧 T 记录按一张表定成：

| 旧记录 | 定成 | 依据 |
|---|---|---|
| 已终态（不管 execution_owner） | 照抄结果、已关闭 | 记录本身 |
| 有 worker，节点答窗口在 | 活着 → 那个窗口的 ID（短码），旧 T 号记成它的别名 | 节点 tmux 的正面回答 |
| 有 worker，节点答 tmux 正常、没有窗口带它 | 已退出（有 cancel_request 记已取消）、已关闭 | 节点的正面回答 |
| 从未认领（没有 worker） | 已关闭 · 没开起来 | 记录本身 |
| 节点不回答（失联、tmux 没起、旧 agent） | **不迁**，下次再跑 | 失联不是证据 |

- 节点只问一次、只读：控制连接上的 `id_presence`（`control.ReadMethods`；`fleet_control.py` 列出每个 fleet 的窗口和
  它们的 `@fleet_id`）。一台机器的 fleet tmux 没起（down）或答不出，它的记录一条不动——**已终态的也不动**（反例：停掉一台机器的节点）。
  窗口还在、记录却已终态（如 T488）⇒ 活着，结果照抄在旁边，从不在活窗口底下关记录。
- dry-run 只打印、什么都不写；`--apply` 对每条写一行 `fleet_operations`（`action=id_migrate`，`idem=id_migrate:T<n>`：
  迁前整条记录、定成什么、证据原文、操作者），只在记录还没有终态时写它的 `outcome` 与 `state=closed`，
  活着的把 `T<n>` 加进 `fleet_ids.aliases`。有这一行的记录不再列出；重复 apply 不会第二次写。没有「强制收」的路。
- 规则在 `hub/store/fleet_id_migrate.go`（`ClassifyIDMigration`），节点只负责打印。

**切换开关**：hub 设置 `fleet.id_switch`（`on`，否则关）。`fleet-id.sh switch [status|on|off]` → `/v1/node/ids/switch`
（GET 谁都能读，设置只有运营方的机器；也可 `PUT /v1/fleet/settings`），两条都记审计 `id_switch`。

- **关（默认）**：旧行为，一个字节不差。
- **开**：门只看「窗口有 ID」。hub 拒收执行权命令——认领、转移、重试、stop/cancel 确认、带围栏的回报
  （`MutateFleetTask` / `RecordFleetTaskReport` → 409 `{code: ID_SWITCH}`），派单不再签启动合约（`launchContract`）；
  已排队的子回报照常送给父会话（不丢）；记录的终态改读它对应 ID 的最新结果（`IDTaskOutcome`：窗口 `opened` 记的 `task`，
  或迁移给活窗口加的别名；merged/succeeded ⇒ succeeded，failed ⇒ failed），所以 `await T<n>`、回收、⌘P 照常。
- 节点把 hub 的话记在 `ids/.switch`：清理 tick 每轮问一次，任何一次被 ID_SWITCH 拒收也写下（`fleet-task-record.sh`）。
  开：派单开窗不认领（`fleet_launch.py local` / `admit`），`fleet_task_control.py report` 答 5，`fleet-report-parent.sh`
  把回报写成窗口 ID 的结果（`--outcome` 成为结果状态，PR 照旧核 merged）。关回来：带 `@launch` 的窗口照走旧路。
  来回切不丢会话：窗口、ID、账本都不动（BREAK-IT `id-switch-flip-report`）。
- 打开开关（迁移 `--apply` + `switch on`，§5.1 第 5 步）由操作者 MacBook 上、不在任何 fleet 里的会话来做（C7），照 [ID-SWITCH.md](ID-SWITCH.md) 做；出问题 `switch off` 回退，旧表没删、写侧双写还在。

`bin/fleet-id-migrate-selftest.sh` 钉节点这一半；hub 那一半是 `hub/store/fleet_id_migrate_test.go`（§5 样例表逐条、
反例、apply 一次、开关两轮）与 `hub/api/fleet_id_migrate_test.go`（机器只问一次、失联不动、开关两轮下旧路拒收、记录读 ID 的结果）。
