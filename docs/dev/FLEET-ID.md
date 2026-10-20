# 一个窗口一个 ID：节点账本与原生段

EPIC T497 的 C1（节点账本）、C2（hub 镜像）、C3（⌘P 面板的编号列）、C4（结果、父子、通信）、C5（EPIC 批次）、C6（迁移命令与切换开关）、C8（删执行权层）与 C11（一律用短码称呼会话）。设计页：「会话与 hub 任务（T）的关系 · 设计稿」第 6 版（§3、§4.1、§4.2、§4.6、§6）。
开关 2026-10-20 打开（C7）；C8 起节点上不再有执行权：窗口的 ID 就是会话，任务记录 T<n> 只是派单的 ticket（见文末「C8」）。

## ID 与短码（设计页 §3.1a；C11 起的规则）

- 完整 ID 就是窗口的 `@fleet_id`（UUIDv4，`fleet_fid_mint` 开窗时铸），形状不变（128 位）。
- **短码**是从完整 ID **重新算出的显示码**，不另存一列、不是真相：把 128 位按比例铺到 26 位上——第 1 位取 22 个字母之一、
  后 25 位是 base32（Crockford，**大写**，不用 `I L O U`）——所以**第一位永远是字母**，短码永远不是纯数字，
  不和 issue / PR 号混（搜 `4539` 不会命中 ID），而且前缀仍是 ID 自己的前缀、顺序与 ID 一致。
  默认取前 **4 位**；本登录已知的另一个 ID 与它同前缀时加长一位，以此类推（像 git 的短 SHA），只在同一用户内唯一。
  `fleet_id.py encode` / hub 的 `FleetIDCode` 逐字节相同（`TestFleetIDCodeMatchesNode`）。
- **怎么写**：面板与编号列、回报里**不带前缀**——⌘P 编号列只显示 `K3F9`；纯文字消息里写 `#K3F9`（`fleet_id.tag`），
  如 `[child-report] #K3F9 · acme/app issue #12 "…" (别名 T486)`、`id: #K3F9 (<完整 ID>)`、send 回执 `sent → #K3F9 (…)`。
  hub 任务记录的 `T<n>` 只作别名附注（一个版本后去掉，见 [ID-SWITCH.md](ID-SWITCH.md)「短码与旧 T 号的退场」）。
- 「已知」= 账本里的 ID + `ids/.known`（hub 镜像回写，C2）+ 活着的窗口。
- **寻址**接受短码或完整 ID：`fleet_win_for_addr`、`fleet-peer-send.sh`、`fleet-await.sh`、`fleet-children.sh`、
  `fleet-clear-send.sh`、MCP `send` 的 `to` / `await` 的 `id` / `clear` 的 `id`（`fleet_is_idcode` 认得：`#K3F9`、裸 `K3F9`、
  旧 `T-…`；键总带 `-` 或 `:`，两者不会撞）。输入大小写都认，`I/L` 读作 `1`、`O` 读作 `0`；`#` 可带可不带
  （`#4539` 首位是数字，仍是 issue）。MCP `send` 的 `to` 里裸写要大写（`K3F9`），小写要带 `#`——一个普通英文词不会被当成短码。
  一个短码对上两个 ID 就拒绝并列出两个候选（rc 2），从不猜。
- **旧写法兼容一个版本**（compat-1v）：`T-hfkc7`（`T-` + 完整 ID 的**小写** base32 前缀，C1–C10 用的那种）照样寻址——
  按旧编码（`legacy_encode` / `FleetIDLegacyCode`，同样是算出来的）比前缀；⌘P 搜得到，Tab 页把它列在别名里。
- **已存的旧短码怎么过渡**：账本里 `opened.short` 与 `short` 事件存的 `T-xxxxx`、窗口的 `@task_short` 都**按没有读**——
  显示时重新算新短码；下一次钩子把 `@task_short` 改成新码；hub 镜像 `fleet_ids` 的 `code` / `short` 两列在 hub 启动时
  就地改成新码（`backfillFleetIDCodes`：认首位不是大写字母的行，按 owner、开窗先后重算，撞了加长后来的；幂等）。
  ID 本身不动；旧 hub 回的 `T-…` 短码节点也按没有读（`hub_short`）。
- 窗口上 `@task_short` 记它的短码（开窗时 `fleet-id.sh open` 盖，之后钩子补）。

## 账本

`$FLEET_CONF_DIR/ids/<ID>.ndjson`，一行一个事件，每个带 `(id, seq)`，追加时持 flock：

| 事件 | 谁写 | 内容 |
|---|---|---|
| `opened` | 两个 spawner（`dash-issue-session.sh` / `dash-raw-session.sh`，后台）；没有时由钩子补一条 `lazy` | agent（解析后的）· window · repo · title · key · task · short |
| `native` | SessionStart 钩子 | 新的一段（agent · 原生 id · trigger · seg），或 `compact: true` 给当前段记一次压缩 |
| `result` | `fleet-id.sh result`（C4 接 report） | state · summary · pr |
| `progress` | `fleet-id.sh progress`；开关 on 时 `fleet_task_control.py progress`（C12：EPIC 驱动的 tick） | state · summary · event（同一 event 不再写）。只留最新一条，不是结果、不改状态；hub 镜像存在 `fleet_ids.progress*`，`fleet-epic-tick.py status` 的 `last_tick` 读它 |
| `progress`（起没起来，T642） | 包装器 `fleet-session-wrap.sh` → `fleet-id.sh start-word`；SessionStart 钩子（`fleet_id.hook`） | state `not_started`「未起来：<原因>」/ `dropped`「已掉：…」，同一原因只在它还是最新一条时不再写；agent 起来后钩子答 `started`「起来了」。`fleet_id.start_word` 是唯一的读者（EPIC tick 的 `stalled`、`await --task` 的 NOT-STARTED / DROPPED、`fleet-children.sh T<n>`），另看本机窗口里有没有 agent（`FLEET_ID_NOAGENT`）、窗口没了 ID 没收尾、过了 `FLEET_START_GRACE` 还没有原生段 |
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
| 任意（压缩除外） | 窗口的 `@id_next_trigger reopen:<epoch>`（恢复页 ↵、`fleet-restore.sh`、`fleet-migrate.sh` 重开时打，10 分钟内有效，读即删）⇒ 新段 reopen，**同一个原生 id 也开**（T644 C2） |
| 任意 | 这个 ID 的 attempt 比上一段的大（任务的重做）⇒ 新段 redo |

钩子永不挡 Agent、永不输出：不在 tmux、headless 的 `claude -p`、坏 stdin 都直接退出 0；
写不进账本时把这一段记在窗口的 `@id_retry`，下一次钩子先补写。`FLEET_ID_HOOK=0` 关掉它。

## 命令

```
fleet-id.sh get <ID | code> [--json]   ID、短码、opened、各段（agent · 原生 id · 起止 · trigger · 压缩次数）、结果
fleet-id.sh resolve <ID | code>        → 完整 ID；rc 1 没有，rc 2 有歧义（候选在 stderr）
fleet-id.sh short <ID>
fleet_id.py take <ID>                   任务的窗口能不能用任务的编号：here · first（rc 0）· elsewhere（rc 1）（T644 C2）
fleet_id.py attempt <ID> [--window @w]  任务的重做：开下一次（`reopened {attempt}`），打印现在是第几次
fleet-id.sh open|native|result|close …   见脚本头
fleet-id.sh push [<ID>…]                 把账本推给 hub 镜像（C2）
fleet-id.sh pull [--full | <ID>…]        从 hub 把本人全部 ID 记录拉进本机缓存（EPIC T644 C7，下节）
fleet-id.sh status|route|children|await|history|continue|reopen …   结果、父子、接班（C4，下节）
```

## 结果、父子、通信（C4，§4.3–§4.5）

- **结果挂在 ID 上**：会话自己的 `report`（`fleet-report-parent.sh`，没有 `--win`）在 ID 账本上写一条
  `result`（state · summary · pr · agent），可以多次，**最新的算**（S2）；合并检查改判的状态（armed ⇒ waiting）
  照实写。任务窗口的 `--outcome` 成为结果状态；任务记录的终态由 hub 读这个 ID 的最新结果（C8 起不再写记录）。
- **关窗即结束**：fleet 有意关窗（回收 `dash-reap.sh`、合并后 `fleet-cleanup.sh`、`fleet-worker-stop.sh`、
  agent 退出 `session-end-hook.sh`、闲置回收）走 `fleet_win_retire <win> <sock> <why>`，第三个词让账本记 `closed`；
  move / migrate / park 不给 why，ID 在下一个窗口接着用。关了没报过结果 = **已退出**（S7）。
- **状态**（`fleet-id.sh status`）：冲突（等你）＞ 最新结果（已完成 / 失败 / 等你）＞ 活着 = 运行中 ＞ 已退出。
  **冲突**：两个活着的 ID 当前段是同一个原生会话；关掉一个，另一个恢复（S9）。
- **接班与转交**（`fleet-id.sh route`，`fleet_id_take`）：发给一个 ID 的回报 / 消息——它开着就给它；
  关了就顺「谁的 prev 是它」找最新的活 ID（接班）；没有就交给它的 `parent`（同样规则往上）；
  再没有 ⇒ 你的提醒（`global/orphan-reports.ndjson`）。本机账本不认识的 ID 走旧路（hub、键）。
  `fleet-report-parent.sh`、`fleet_task_control.py receive`（切换前排着的子回报）、`fleet-peer-send.sh K3F9`
  都按它走；回报**不核父任务代次与原生进程**——/clear、交接、换 Agent、重开都不换 ID（BREAK-IT `report-parent-cleared`）。
- **父子**：两个派单入口开账本时记 `--parent`（派它的会话的 ID，`fleet_spawn_parent_id`：交来的 worker_id 的后半；
  否则 `--origin` 本身就是 ID 时就是它——编排、驱动、no-repo 会话这类没有键的父会话，`task` 派单都走这条；
  否则那个键对上的唯一窗口的 ID。hub 派的没有父）；`fleet-id.sh children <ID>` /
  `fleet-children.sh --ids` 列出 parent 是它的 ID。C9 之前 `task` 派出的子 ID 没记上父：
  `fleet-id.sh parents [--apply]` 按它 `opened` 的 `task` 读 hub 记录的 parent_session（后半）补一条只填空的
  `opened {parent}` 并推给 hub 镜像（默认只列不写；没有 hub ⇒ 3）。
- **等待**：`fleet-await.sh K3F9 | fid:<ID> | <ID>`（MCP `await` 的 `id`） → `fleet-id.sh await`：有不是回合边界（waiting / idle）的
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
- **驱动 = 一条线**（C18）：父 ID 连同顺 `prev` 接上它的每个 ID（驱动被回收后 `fleet-id.sh continue` 出的接班窗口；
  hub 的 family 回答里是 `lineage`）。接班窗口带着原窗口的 `@task` 与 parent（`continue --exec` 传
  `--id-task` / `--id-parent`，不认领、不进准入）；线上任一 ID 派的子 ID 都是这批的成员——哪怕它的记录没挂
  `parent_task`（只带 parent_session）；进度词取线上最新的一条。父记录没人认领（ID 开关）时，父 ID 是本机为它开的、
  prev 链起点的那个 ID。外批依赖（`T542 C7`）没合并就在 `waits_on`；合了就放行，并在成员的 `outside` 里写明 `done`。
- **批次标记**：`epic-running.d/<slug>-K3F9`（tick 的 `mark`，父 ID 的短码；C11 之前打的 `<slug>-T-xxxxx` 下一个 tick 换掉）带一行 `task: T<n>`；
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
  的 ID 表，每 10 分钟最多拉一次写进 `ids/.known`，本机选短码、解析短码都把它算进去——4 位对上两个就拒绝并列候选。
  `GET /v1/node/ids/<ID|code>`（`K3F9`，或旧的 `T-…`）读一条，歧义回 409 `AMBIGUOUS`。
- **完整 ID 重复即拒**：hub 已有、来自另一台机器（或另一个 owner）的同一个完整 ID ⇒ 409 `DUPLICATE_ID`，
  什么都不存（整机克隆，S13）。节点记 `ids/.hub/<ID>.refused`、在那个窗口上盖 `@id_hub_error`、
  发一条 `id-duplicate` 提醒，这本账不再推；窗口照常跑，新开的窗口不受影响。只有以 `moved` 开头的推送能把 ID 改挂到别的机器。
- **issues**（§3.5）：opened 的 `issue` / `ticket_ref` / `issue-<N>` 键 + repo，result 的 `issues`
  （`fleet-id.sh result --issues o/r#N,…`，PR 正文的 Fixes/Closes）。

`bin/fleet-id-hub-selftest.sh` 钉节点这一半的 S10、S12、S13；hub 那一半是
`hub/store/fleet_ids_test.go`、`hub/api/fleet_node_ids_test.go`。

## 本机账本只是缓存：换了家，面板一模一样（EPIC T644 C7）

本机账本是**写入口**（先写本地、再推 hub）；hub 上本人全部 ID 的记录（parent、prev、task、
short、段、结果、progress）**缓存**在每台机器的 `ids/.cache/<ID>.json`（hub 原样的记录）：

- **同步**：`fleet-id.sh pull`（清理 tick 每轮在 push 之后）读 `GET /v1/node/ids?since=<游标>`，
  一页 500 条、按 `updated_at` 往后翻，游标在 `ids/.cache/.cursor`；每小时（或 `--full`）从头全量一遍，
  hub 不再列的从缓存删掉。没有 hub ⇒ 3，hub 不答 ⇒ 75，缓存原样不动；旧 hub（答里没有 `cursor`）什么都不改。
- **读**：面板（`fleet_view.py` 的 `id_record`）、`get` / `children` / `family` / `resolve` / `status`
  都读 `fleet_id.record`：本机有账本的，由缓存补（`opened` 缺的字段、更长的短码——**hub 为准**），
  本机自己写的结果 / 收尾照留；本机没有的，就是缓存那条（`src=hub`，状态按 hub 的结果读）。
  `route` / `history` / 本机的任务线仍只看本机账本（另一台机器的 ID 答 `unknown`，走 hub 的路）。
- **显示路径不请求 hub**：缓存缺某条，那一行先显示本机算出的短码（`id_pending`），帧末
  `pull_later` 在后台按 ID 补取（单飞，`ids/.cache/.pulling`），补到后下一帧就是完整的。
- **别机的行**按 `<fleet UUID>/<key>` 记；`fleet-hub-sessions.sh` 把 hub 的 worker identity 写成
  `wid_ids`（`<worker_id>\t<ID>`），面板据此对上 ID；别机的 EPIC 驱动由行的第 25 列（节点的 `epic=`，
  T 任务批次的 `#T<n>` 也带）认出，它的展开状态记在本看台 `remote-views/epic-open-<fleet>.json`。

`bin/fleet-view-home-selftest.sh`（BREAK-IT `home-moved-panel-differs`）：家在 A、会话在 B ⇒ 每行的短码、
名字、分组、EPIC 父子与 已完成/总数 与家在 B 逐行相同；缓存缺失先占位后补齐；hub 不答照旧缓存画。

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
- 只迁**旧**记录（C13）：开关打开之后写下的记录、以及从没认领却有 ID 带着它编号的记录，是 ID 那一边的——开关开着窗口不认领，
  「没有 worker」不能当没开起来的证据，所以 dry-run 不列它们（否则 `--apply` 会把活窗口的记录关成「没开起来」）。
- 规则在 `hub/store/fleet_id_migrate.go`（`ClassifyIDMigration`），节点只负责打印。

**切换开关**：hub 设置 `fleet.id_switch`（`on`，否则关）。`fleet-id.sh switch [status|on|off]` → `/v1/node/ids/switch`
（GET 谁都能读，设置只有运营方的机器；也可 `PUT /v1/fleet/settings`），两条都记审计 `id_switch`。

- **关（默认）**：旧行为，一个字节不差。
- **开**：门只看「窗口有 ID」。hub 拒收执行权命令——认领、转移、重试、stop/cancel 确认、带围栏的回报
  （`MutateFleetTask` / `RecordFleetTaskReport` → 409 `{code: ID_SWITCH}`），派单不再签启动合约（`launchContract`）；
  **唯一还收的一条**（C13）：人对「从没认领」记录的取消（`fleet_task_control.py cancel` 发的无 owner `transition → cancelled`）——
  记录 accepted、没有 execution_owner、没有终态，且没有**开着的** ID 带它的编号（窗口从没开出来，或 ID 已关）才收成已取消；
  ID 还开着 ⇒ ID_SWITCH（到那个窗口去收），ID 关了但留下结果 ⇒ 409 冲突（它已按 ID 的结果结束）；有 owner 的照旧拒。
  已排队的子回报照常送给父会话（不丢）；记录的终态改读它对应 ID 的最新结果（`IDTaskOutcome`：窗口 `opened` 记的 `task`，
  或迁移给活窗口加的别名；merged/succeeded ⇒ succeeded，failed ⇒ failed），所以 `await T<n>`、回收、⌘P 照常。
- 节点把 hub 的话记在 `ids/.switch`：清理 tick 每轮问一次。C8 起只用来显示——节点上的每条路都按「开」走（下节）。
- 打开开关（迁移 `--apply` + `switch on`，§5.1 第 5 步）由操作者 MacBook 上、不在任何 fleet 里的会话来做（C7），照 [ID-SWITCH.md](ID-SWITCH.md) 做。
  C8 之后关掉开关**不再是回退**：节点上已没有旧路。

## C8：执行权层删掉之后（设计页 §6 A / B）

- **门是「窗口有 ID」**：派单开窗不认领、不签启动合约、不做本机启动预留；`fleet_repo_authority.py --gate|--finish`
  只问这个人的任务权限（frozen 拒，读不到拒，从不回退），`--supervise` 直接起启动器、去掉退役层的环境
  （`FLEET_LAUNCH*` · `FLEET_AUTHORITY_*` · `FLEET_ID_DISPATCH`）。
- **回报**：任务窗口的回报是它的 ID 的结果（`fleet-report-parent.sh`）；`fleet_task_control.py` 只剩读
  （`closed` · `await` · `children`）、EPIC 驱动的进度词（写在 ID 上）、取消「没有窗口开过」的记录、
  和送达切换前排着的子回报（`receive`）。
- **删掉的**：启动证明（`fleet_launch.py` 的回执、扣首轮、rebind、transfer 的代次移交）、回执重放与 release
  （`fleet_task_recovery.py`）、Codex 执行权登记（`fleet_native_registration.py`）、存活会话补登记与一次续接
  （`fleet_native_observe.py` · `fleet_native_continue.py`）、回收影子与状态证据（`fleet_reap_shadow*.py` ·
  `fleet_status_evidence.py`，⌘P 的「状态证据」）、`fleet_runtime.py` 的观察与条件接受、`LaunchWitness`、
  `dash-raw-session.sh --native-worktree`（它的准入就是启动证明 / 本机预留）。进程与工作树的身份读法留在
  `fleet_native_proc.py`。
- **老会话兼容一个版本**（compat-1v）：`fleet_launch.py` 是转发——还跑着旧 `fleet-session-wrap.sh` 的会话调
  `fleet_launch.py supervise`，它拿掉窗口的 `@launch*` 选项、走普通路；新包装器见 `@launch` 也一样。切换前开的、
  旧启动监督进程还在的窗口在 C8 版本上重开（ver-stale、↵、恢复）是同一个窗口、同一个 ID（BREAK-IT
  `c8-old-supervisor-reopen`）。`fleet_runtime.py event` 安静收下（旧 mod），`fleet_task_control.py report` 答 5、
  `finalize` 答 0（旧监督进程退出时调）。

- **hub 这一半**：执行权状态机（认领 · 转移 · 重试 · 取消请求/确认 · 带围栏的回报）、它钉的任务 lease、
  `task_attempt` 历史、启动合约（`launchContract` · `claimLaunch` · `verifyLaunchResult`）与 blocker 契约都删了；
  `mutate` / `report` 一律 409 `ID_SWITCH`，只剩 C13 的「从没开过窗口」取消（`CancelUnopenedTask`）。
  节点再报一个版本 `launch_v1`、收下并忽略旧 hub 发来的 `params.launch`。记录上的 `execution_owner` /
  `generation` 列只当档案读（C8 之前绑的父、ID 迁移）。旧式记录的 settle（#4867）不属执行权层，留着。

`bin/fleet-id-migrate-selftest.sh` 钉节点这一半；hub 那一半是 `hub/store/fleet_id_migrate_test.go`（§5 样例表逐条、
反例、apply 一次、开关两轮）与 `hub/api/fleet_id_migrate_test.go`（机器只问一次、失联不动、开关两轮下旧路拒收、记录读 ID 的结果）。

## 任务的编号（EPIC T644 C1：任务一建好就有编号）

- **hub 写下任务记录的那一刻就给它一个 ID**（`hub/store/fleet_task_ids.go`）：和窗口同一种 UUID，记在
  `fleet_tasks.fid`；对人只叫它的码——「写下来的」那段（在这个人全部历史里不重复、至少 4 位，`fleet_ids.short`）。
  `T<n>` 降为只读别名：记录 JSON 的 `id` 仍是 `T<n>`、新增 `task`（同一个 `T<n>`）、`fid`、`short`
  （compat-1v：下一批删 `id` 的旧义）。`fleet-task-record.sh new` 第一行打码、第二行 `T<n>`；老 hub 只答 `T<n>`。
- **铸出来的 ID 是 fleet_ids 里一行「预留」**：属这个人、没有机器（`endpoint_id` 空）、seq 0、`task` 空、
  `task_id` 是它自己。预留让它的码和这个人别的 ID 分得开、节点的解析也找得到；`task` 留空，所以
  `idCarrying` / `IDTaskOutcome` 不会把它当成「有窗口带着 T<n>」——从没开过窗口的记录照样能取消。
  这个人的第一台机器推这个 ID 的事件时接手它（`ApplyFleetIDEvents`）——为任务开的窗口用任务的 ID，是 C2 的路。
- **`fleet_ids.task_id`** 指任务的 ID：推上来的 `opened` 带 `task=T<n>` 时 hub 查出那条记录的 `fid` 填进去；
  `task` 列再留一个版本。
- **解析只有一个**：`store.ResolveFleetTask`——码（至少 2 位，大小写、`#`、I/L→1、O→0 都收）、完整 ID（任务的，
  或属于它的窗口 ID）、`T<n>`（有这条记录时按别名，否则当码读）。码先在**未结束**（记录未收口：成功 / 失败 /
  取消 / 拒绝 / closed 以外）里找，唯一即命中，多个 ⇒ 409 `{code: AMBIGUOUS, candidates}`；未结束里没有 ⇒
  全部历史里同样规则。从不替人猜。`/v1/node/tasks/<ref>`（及其 `children` 等子路）与 `/v1/fleet/tasks/<ref>`
  都走它；建 v1 记录时的 `parent_task` 也收码 / ID。
- **C1 之前的记录**：`POST /v1/node/tasks/ids-backfill {apply?}`（`store.BackfillTaskIDs`，只动这台机器主人的记录），
  默认 dry-run 出数（total · already · linked · minted · items），apply 才写：先对上已带它号码的最早 ID
  （`task = T<n>` 或迁移的别名，按 opened_at），没有就补铸一行预留。重复跑是空操作；旧列一个不删。
- **能力位**：`/version` 的 `capabilities` 含 `task_ids`；本机按它决定走不走新路，不按版本号猜。

`hub/store/fleet_task_ids_test.go`（建即得 ID、三种引用同一条、两位码多义 / 未结束优先 / 全史多义、回填 dry / apply /
幂等）与 `hub/api/fleet_task_ids_test.go`（节点路一整圈、409 候选、回填路由、能力位）钉住它。

## 记录的状态就是它的列（EPIC T644 C6：记录的状态和实际一致）

- **结果落地即写实**（`hub/store/fleet_task_state.go`）：一条编号的结果写进 `fleet_id_results`（`ApplyFleetIDEvents`
  的 `result` 事件）时，同一事务改它带的任务记录——`fid` 是它、`fleet_ids.task_id` 指过去的、名字里的 `T<n>`、
  迁移别名——只限同一个人的：`merged` / `succeeded` / `done` → `succeeded`，`failed` → `failed`（别的结果词不收尾），
  `state` 与 `outcome` 同写，`pr` 空才填，`observation = id_result:<ID>#<seq>`。同一任务更新的结局结果覆盖这样写的
  旧结果（失败后重做成功）；取消、拒收、旧报告写的结局一律不碰。收尾的记录迟到的 node 写不再改开
  （`UpdateFleetTask`），blocker / settle 查询也认这些收尾状态。
- **读时投影删掉**：`taskViews` 不再把 `IDTaskOutcome` 投到记录上，列表、children、单条、计数读的是同一列；
  `IDTaskOutcome` 只留给取消检查和迁移。
- **旧账一次收**：`fleet-task-record.sh reconcile [--before T<n>] [--apply] | --undo`（`POST /v1/node/tasks/reconcile`，
  `store.ReconcileTaskStates`，只动这台机器主人的记录），默认 dry（unfinished · ended · cancelled · kept · left · items）：
  未收口、编号已有结局结果的照写实；`--before` 以下仍未收口、没有活会话（没有开着的编号带它，worker 没有租约 /
  没收口的 local start / 不在 inventory）的收为 `cancelled`，`observation = reconcile_cancel:<旧状态>`；`--undo` 放回。
  重跑是空操作。
- **能力位**：`/version` 的 `capabilities` 含 `task_state`。

`hub/store/fleet_task_state_test.go`（结果后单条 / 列表 / children 一致、新结果覆盖、取消不覆盖、别人的编号不碰、
回填 dry = apply、幂等、可退回）与 BREAK-IT `task-state-behind-result` 钉住它。

## 派活、查、等、报结果都用这个编号（EPIC T644 C3）

本机每个和任务打交道的工具，收的、出的都是任务的码；`T<n>` 再收一个版本（compat-1v：下一批删）。

- **一个读者**：`fleet-task-record.sh resolve <码|ID|T<n>>` ——第一行码、第二行 `T<n>`（老 hub 只答 `T<n>`）；
  码对多个任务 ⇒ 退出 2、stderr 每个候选一行（`K5H0 · 标题 · 状态`），从不替人挑；没有 ⇒ 1。解析是 hub 的
  `store.ResolveFleetTask`（C1），本机不另算。`get` 遇多义同样退 2。
- **码的账本**：`ids/task-codes.tsv`（`T<n>\t码\tID`）——每个带 `short` 的 hub 回答顺手记下；码一辈子是这个任务的，
  所以报告头、等待的结论、`brief` 不必再问 hub。`fleet-task-record.sh code <T<n>|码>` 先读账本、再问 hub；
  `fleet_id.py task_code` 是 Python 侧的同一读法。
- **首行是码**：`new` / `dispatch` 先打码、再打 `T<n>`；`set` / `attach` 打码（老 hub：`T<n>`）；`get` / `children` /
  `mutate` 仍是 hub 的 JSON（记录里带 `short`）。`children` / `mutate` / `set` / `attach` 都收码。
- **等**：`fleet-await.sh --task <ref>`（MCP `await` 的 `task`；`id` 是本机窗口 ID 都不认的码时也走这条），结论写
  `task: <码>`；`fleet_task_control.py` 的 await / closed / children / cancel 都按码称呼任务。
- **派**：MCP `task` 的回答 `id` / `short` = 任务的码，`task` / `alias` = `T<n>`（一个版本）；老 hub：`id` 仍是开出的会话的码。
- **报**：child-report 头行 `#<码> · …`——任务的码（账本），没有就窗口 ID 的码；不再带「(别名 T<n>)」。
- **发消息**：`fleet-peer-send.sh <码>`——本机窗口 ID 都不认的码（或 `T<n>`、`#K5`）按任务读：送到带这个 `@task`
  的活窗口，没有就送它记录上的 worker（`wid:`）；多义拒收并列候选。
- **brief / status**：`task=<码>`、「dispatched by: <父任务的码>」、PR 正文写码。
- 窗口的 `@task` 仍是 `T<n>`（会话与记录在本机的连接，C2 之后由 ID 承接）。

`fleet-task-record-selftest.sh` F、`fleet-await-selftest.sh`（ONE CODE）、`fleet-mcp-selftest.sh` R2、`fleet-id-selftest.sh`
TASKCODE、`fleet-id-results-selftest.sh` NAMES、`fleet-brief-selftest.sh` CODE、`fleet_task_control_test.py`
（`test_one_code_names_the_task`）、`fleet-quick-dispatch-selftest.sh` H 钉住它。

## 一个任务的所有会话都挂在它的编号下（EPIC T644 C2）

- **开窗就用任务的编号**：两个派单入口带 `--task T<n>` 时问 `fleet_task_take`（`fleet-lib.sh`）——编号先取
  `$FLEET_TASK_FID`（`fleet-task-record.sh dispatch` 刚写下记录时交来的，写成 `T<n>=<ID>`，只对它自己那条记录有效），
  否则读 hub 的记录（`fleet-task-record.sh get`，记录 JSON 的 `fid`）；再由 `fleet_id.py take` 定能不能用：
  本机有它的账本 ⇒ `here`（同机重做 / 重新派）；hub 那一行还是 C1 的预留（seq 0）或 hub 没有这一行 ⇒ `first`（第一个窗口）；
  别的机器推过它、或 hub 不答 ⇒ `elsewhere`：退回旧路——新铸一个 ID、`prev` 是任务的（从不在别的机器的 ID 底下写账本）。
  记录没有编号（hub 不带 `task_ids`、记录没回填）⇒ 跟以前一样。`dash-raw-session.sh` 在 agent 起来**之前**就把它写进
  `@fleet_id`（窗口命令前缀的 stamp），钩子不会再另铸一个；自己的重做不记指向自己的 `prev`。
- **重做 = 同一编号的下一次**：`here` 时开窗前先 `fleet_id.py attempt`——账本跑过段就写一条 `reopened {attempt: n+1}`
  （hub 照 `reopened` 清掉关闭；没开起来过的不加次数）。之后的第一段 trigger 是 `redo`；每一段、每条结果都按账本里的
  先后记上它属于第几次（`fold` 算出，缺省 1）。**状态只看这一次**：`last_result` 只取当前这一次的结果，所以上一次的失败
  不再算——`status` 读「运行中」、`await` 接着等，这一次报 merged 就是任务的结果。`get` / 面板写「第 n 次」（n > 1：
  行标题 `修 bug · 第 2 次`，`view_id_attempt_fmt`）。
- **重起 / 重开 = 同一编号的新一段**：恢复页 ↵（`fleet-session-wrap.sh`）、`fleet-restore.sh`、`fleet-migrate.sh`
  （配额迁移、cfg-stale / ver-stale 重开）在新进程起来前打 `@id_next_trigger reopen:<epoch>`，钩子读到就开一段 `reopen`，
  哪怕原生 id 没变。交接（handoff）、`/clear`、换 Codex 本来就是同一 ID 的新一段（上表）。
- **两个活窗口带同一编号** ⇒ `status` 是冲突（`conflict` 里写它自己），面板两行都红「等你」（`fleet_view.id_conflicts`，
  沿用 S9）；关掉一个另一个就恢复。
- 还没做的：hub 镜像不存 attempt（`fleet_id_results` 没有这一列；C6 起记录随最新的结局结果改写，重做成功覆盖上一次的失败）；批次按编号排先后是 C5。

`bin/fleet-task-id-selftest.sh` 钉住 take / 开窗 / ↵ 新段 / 重做 / 冲突；BREAK-IT `task-many-ids`。
