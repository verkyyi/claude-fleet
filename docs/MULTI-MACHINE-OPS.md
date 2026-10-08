# 多机运维手册：m5 下线，m4 接得住

> issue #1427（EPIC #1419 C8）。给运营者和 5 位同事（6 个登录）看的。
> 目标只有一个：**m5 计划下线时，10 分钟内大家从入口连到 m4 继续工作；m5 回来后自动回到正常状态。**
> 第一次按这份手册真的演练之后，把时间线贴回 #1427，并据实修订这里。

## 0. 一页纸

| 场景 | 谁 | 做什么 |
|---|---|---|
| **计划下线** m5 | 运营者，在 m5 的任意一个 fleet 窗格 | ① `fleet-node-maintenance.sh enter --reason '升级'` ② 每个登录 `fleet-spot-evacuate.sh` ③ 看 `/nodes`：m5 会话数降到 0 或只剩「工作中」 ④ 关机 |
| 期间 | 每位同事，在自己电脑 | `fleet` ——入口自动选 m4；`fleet m4` 指名也行 |
| **恢复** | 运营者，在 m5 | 开机 → agent 自己回连，`/nodes` 上 m5 从「失联」回到「维护中」→ 确认 `fleet-doctor` 全绿 → `fleet-node-maintenance.sh leave` |
| **意外下线** m5 | 每位同事 | 什么都不用做：`fleet` 会落到 m4；m5 上的会话入口标「失联」，30 分钟后它们的认领释放，**不自动重派**——你在 m4 上 `fleet-history`/重新 `/fleet-claim` 把要紧的接着做 |
| 意外下线后 m5 回来 | 运营者 | 先 `fleet-node-maintenance.sh enter`（别让入口立刻往上派活）→ 检查 → `leave` |

三条命令都在 `~/.claude/fleet/bin/`，都要在 fleet 窗格（或 `CCQUOTA_FLEET=1` 的 shell）里跑；入口模块没开（单机 fleet）时它们什么都不做，退出码 10。

## 1. 名词：入口怎么看一台机器

- **入口**（hub）在云上，不在 m5 上。m5 下线不影响入口本身，影响的是 m5 上的算力、会话，以及 `fleet connect` 默认把人送到哪台机器。
- 每台机器的每个登录都有一个 ccquota agent 向入口报到（几秒一次）。入口据此给机器三种状态：

| 状态 | 是什么 | 谁决定 | 入口怎么对待它 |
|---|---|---|---|
| **在线** online | 报到正常 | 心跳 | 一切照常 |
| **维护中** maintenance | 报到正常，但运营者标了「要下线」 | 运营者（`fleet-node-maintenance.sh enter`，或 `/nodes` 页卡片上的按钮） | **不再往它派新会话**——`--node auto` 不选它，指名 `--node m5` 也拒；`fleet-move.sh --rebalance` 问「这个会话该在哪」时，答案总是别的机器；`fleet connect` 优先去别台。它上面已有的会话照跑，侧边栏行不变灰、不进「失联」组。标记写在入口的设置表里，机器重启、入口重启都不丢，直到 `leave`。 |
| **失联** lost | 连续 3 次没报到（≈15 秒） | 心跳 | 只标记。会话行原地变灰、行尾 `@m5!`（不挪位置、不另起一组，#1882）；它持有的 issue 认领（租约）**30 分钟后释放，不自动重派**（EPIC #1419 发起人拍板 2）。再响起心跳就回到在线/维护中。 |

「失联」永远压过「维护中」：一台标了维护中又停了心跳的机器就是失联，租约照 30 分钟释放。维护中只改变入口**往它发什么**，不改变入口**对它的判断**。

在哪里看：
- `/nodes` 页（入口网页 → 机器节点）：机器卡片的徽章 在线 / **维护中**（带原因、从何时、谁标的）/ 失联；运营者看到「进入维护 / 结束维护」按钮。
- 侧边栏顶行：`● m5 22 · ◐ m4 3 维护中 · ○ m9 0 · 5 分钟没联系`——`●` 在线、`◐` 维护中、`○` 失联。
- 手机版「我的会话」：机器标题旁的「维护中」/「失联」胶囊。
- 命令行：`fleet-node-maintenance.sh status` → `maintenance: m5 maintenance · 升级 · since … · by node:verkyyi@m5`。

## 2. 计划下线（升级、搬机、换硬件）

前提：**和运营者约好时间**（周末晚上低峰，提前一天在群里说），m5 上没有谁的会话正在跑要紧的事。下面每一步都是手动执行，没有任何一步会自动触发下线。

### T-24h：通知

- 群里发：时间、预计多久、这期间请用 `fleet`（会自动落到 m4）；手头在 m5 上「工作中」的会话请在下线前让它收尾（合 PR，或 `/fleet-handoff`）。
- 确认 m4 接得住：`/nodes` 页「各登录」表里，**每个要迁的登录在 m4 上都有一行、在线**（登录不在 m4 上的人，他们的会话搬不过去——先按 `docs/SHARED-MACHINE.md` 加登录）。看 m4 的负载/内存/每人会话上限（`fleet.node_cap.m4`，默认不设，只按负载判定）够不够。

### T-0：标维护中

在 m5 的任意一个 fleet 窗格（哪个登录都行，入口标的是整台机器）：

```sh
~/.claude/fleet/bin/fleet-node-maintenance.sh enter --reason '升级 macOS，预计 40 分钟'
# maintenance: ENTERED m5 · 升级 macOS，预计 40 分钟 · since 2026-10-05T12:00:00Z · by node:verkyyi@m5
```

从这一刻起入口不往 m5 派新会话。核对：`/nodes` 上 m5 的徽章变「维护中」；m4 的侧边栏顶行出现 `◐ m5 N 维护中`；`fleet-node-maintenance.sh status` 说 maintenance。

> 入口是旧版本（没有 `/v1/node/maintenance`）时命令退出 4 并说明「predates issue #1427」——先重新部署入口（合并 ≠ 上线，见 `tokenledger/` 的部署说明），再做下线。

### T+1min：把空闲会话搬到 m4

**每个登录各自跑一次**（它只搬本登录的 fleet；运营者可以 `sudo -u <login>` 逐个代跑，或各人自己在自己的 fleet 窗格里跑）：

```sh
~/.claude/fleet/bin/fleet-spot-evacuate.sh --dry-run    # 先看计划：哪些会动、去哪
~/.claude/fleet/bin/fleet-spot-evacuate.sh              # 真搬：每个 fleet `fleet-move.sh --rebalance --max all`
# evacuate: moved 7, left 2
```

规则（都是 `fleet-move.sh` 的，不是这里新定的）：只搬 `done`/空闲的会话，**正在工作的一个都不碰**；工作树不干净的不搬（它会说 dirty）；搬过去的会话在 m4 以同一个 session id 续上，窗口名、`@issue`、父子关系都在。
`left N` 就是还留在 m5 上的：看侧边栏/`/nodes` 它们是谁，等它们完成或让它们的主人 `/fleet-handoff`，再跑一次 evacuate。

2026-10-04 演练学到的三件事（修掉之前照这里绕）：
- ~~**`--rebalance` 遇到第一个无处可去的会话就整体停**~~（#1513，已修）：现在无处可去的会话（`REFUSED NO_ELIGIBLE_NODE` 等）各打一行 `↷ <窗口名> (<wid>): <原因>` 跳过，接着搬下一个；只有「本机就是最佳」(`LOCAL`) 和入口问不通才停。汇总行是 `fleet-move: rebalance moved N · skipped M · left K`——`K` 是还留在本机的空闲会话（跳过 + 失败 + 没轮到的），evacuate 的 `left` 就从它来。
- **入口只认 fleet 的主仓库**（#1512）：一台机器只能接它的 fleet 以 `FLEET_REPO` 登记的那个仓库的会话，叠层仓库（`repos/*.conf`）对入口不可见。m5 主仓库是 monorepo、m4 主仓库是 claude-fleet 的今天，monorepo 的会话搬不到 m4，claude-fleet 的会话在 m5 本来就不是候选。**下线前先看 `/nodes` 各登录表里两台机器的 fleet 仓库**，心里有数哪些会话搬得走。
- **live install 落后的机器看不懂「维护中」**：没有 #1505 的侧边栏把 maintenance 当失联画（`○ m5 … 没联系`、行变灰进失联组），没有 #1491 的 `dash-issue-session.sh` 连入口的租约/派单都打不通（`hub unreachable (ccquota exit 1)`，#1507）。演练或下线前把两台机器都同步到 ≥ df4daf9。

### T+5~10min：确认，然后下线

- `/nodes`：m5 会话数为 0（或只剩你们决定「让它随机器一起断」的那几个）。
- 这些会话随 m5 断掉后的后果只有：入口标失联、30 分钟后它们的认领释放、**不会有人替它们重开**。要紧的别留。
- 关机 / 升级 / 断电。**这一步永远是人做的。**

### 恢复

1. 开机。各登录的 ccquota agent 是 LaunchAgent，自己回连；`/nodes` 上 m5 从「失联」回到**「维护中」**（标记还在，入口仍不派活），侧边栏顶行回到 `◐ m5`。
2. 在 m5 任一 fleet 窗格检查：`~/.claude/fleet/bin/fleet-doctor.sh` 全绿（`node` 行有 node.env、`machine` 行负载正常、`listen` 行没有 LAN 监听）；fleet 的 tmux 服务器由 `fleet-restore` 拉回来（`docs/HOST.md`「An unattended Mac」）。
3. 想把搬走的会话搬回来：在 m4 上对应登录跑 `fleet-move.sh <window> --via hub --to m5`（一个个搬），或者不搬——m4 继续跑也没问题。
4. 结束维护：

```sh
~/.claude/fleet/bin/fleet-node-maintenance.sh leave
# maintenance: LEFT m5
```

入口随即恢复往 m5 派会话；`fleet connect` 的默认机器照旧按「上次用的 / 有你的会话 / 负载最低」选。

### 温和版：只让入口当它下线（演练 / 验证入口用）

机器一点不动——不关机、不重启 agent、不杀 fleet、不碰 working 会话——只走「标维护中 → 验证入口拒派 → 搬一个空闲会话 → 解除」。2026-10-04 第一次演练就是这个版本（记录在 #1427）：

1. `fleet-node-maintenance.sh enter --reason '演练'`（T0）→ `status` 读回 maintenance。
2. 验证入口拒派：对 m5 上任一 **主仓库** 的空闲会话 `fleet-move.sh --rebalance --max 1 --dry-run`，输出里该会话一行 `↷ <窗口名> (<wid>): NO_ELIGIBLE_NODE — … macmini: maintenance: …`（这是「维护中排除了 m5」的直接证据；解除后同一条命令应变成 `this machine is the best place`——A/B 对照）。
3. 新会话落别台：在能搬的仓库上开一张占位小单，`dash-issue-session.sh <N> --repo <repo>`（`FLEET_SPAWN_NODE=auto`），看另一台 20 秒内开出窗口。
4. 搬一个空闲会话：`fleet-move.sh <窗口> --via hub --to m4 --dry-run`，再去掉 `--dry-run`；到 m4 上 `tmux -L fleet capture-pane -t fleet:<idx>` 看到 Claude 提示符即「能继续」。
5. `fleet-node-maintenance.sh leave` → `status` 回 online → 第 2 步的对照。
6. 收尾：占位会话 `fleet-worker-stop.sh fleet <repo>:issue-<N>` 优雅停、占位单关掉；临时改过的 conf 从备份恢复。

读数口径同全量演练：T0 → 最后一项在 m4 上恢复操作的时刻。2026-10-04：**8 分 09 秒**（22:24:19 → 22:32:28），期间无人受影响。

## 3. 意外下线（断电、死机、网断）

**现象**（15 秒内）：`/nodes` 上 m5「失联」；每个人的侧边栏顶行 `○ m5 N · N 分钟没联系`，m5 上的行原地变灰（行尾 `@m5!`，#1882）；m4 上 `fleet-children.sh` 把在 m5 上的子任务标 lost；`fleet connect` 自动落到 m4（m5 不在线就不会选它）。

**每位同事**：

1. `fleet`（或 `fleet m4`）进 m4。你在 m4 上原有的会话都在。
2. 你在 m5 上的会话：现在动不了。看侧边栏的失联组知道它们是谁、最后状态是什么（那是最后一次报到时的，不是实时）。
3. 要紧的事：在 m4 上重新开——`/fleet-history` 能看到它们的最后一条记录；issue 的认领 **30 分钟后自动释放**，之后 m4 上 `dash-issue-session.sh <N>`（或侧边栏回车）就能接着领；等不及 30 分钟可以 `ccquota lease acquire --force`（会记审计，写明挤掉了谁）。工作树和分支在 m5 的磁盘上，PR 已推的部分在 GitHub 上——从分支继续，别从头做。
4. **没有任何东西会替你重派**：这是 EPIC #1419 的约定（只释放、等你决定），防的是 m5 一回来两台机器各跑一份。

**运营者**：

1. 判断是真下线还是只是网断（能 ping / 能 ssh 进 LAN 口吗）。网断：会话其实还在跑，别动，等网回来，一切自动复原（租约在 30 分钟内续上就不释放）。
2. 真下线：群里一句话。不用做别的——该释放的 30 分钟后自己释放，该搬的本来也搬不了（机器不在）。
3. m5 回来后：**先** `fleet-node-maintenance.sh enter --reason '意外下线后检查'`——它一报到入口就会往它派活，先拦住；按第 2 节「恢复」检查；注意 m5 上那些会话会以「我还活着」的状态回来，而同一个 issue 可能已经有人在 m4 上重开了——`/nodes`「我的会话」里同一个编号出现两处就是这种情况，留 m4 的，关 m5 的（`fleet-worker-stop.sh`），然后 `leave`。

## 4. 恢复后检查清单

- [ ] `/nodes`：m5 在线（不是维护中、不是失联），各登录全部有行
- [ ] 侧边栏顶行：`● m5 … · ● m4 …`，没有 `○`、没有失联组
- [ ] `fleet-doctor.sh`：`node`、`machine`、`listen`、`hub` 行无 WARN
- [ ] `fleet-node-maintenance.sh status` → `m5 online`
- [ ] 入口审计（`fleet_audit`，`node_maintenance` 行）：ENTER 和 LEAVE 各一条、时间对得上——这就是演练记录的两个端点
- [ ] 同一 issue 没有两台机器各一个会话（`/nodes`「我的会话」按编号看）

## 5. 演练方案（批后、运营者确认时间后执行）

**红线（运营者 2026-10-04 决定）**：演练必须先与运营者确认时间；任何会让 m5 下线或重启 agent 的步骤都不得自动进行。本手册里没有自动化这些步骤的脚本，也不要写。

**时间**：周末晚上低峰，提前一天通知；m5 上无「工作中」的要紧会话。
**参与者**：运营者 + 至少 2 位同事（各自从自己电脑进来）。
**读数口径**（EPIC #1419）：`m5 下线时刻 → 最后一位参与者在 m4 上恢复操作的时刻`，目标 ≤ 10 分钟。

步骤 = 第 2 节逐条做；每做一步记时间。贴回 #1427 的表格：

| 时刻 (UTC+8) | 步骤 | 谁 | 结果 / 受影响的人 | 备注 |
|---|---|---|---|---|
| | T-24h 通知 | 运营者 | | |
| | `enter` 标维护中 | 运营者 | `/nodes` 变色用了 __ 秒 | |
| | `evacuate` 第 1 轮 | 各登录 | moved __, left __ | left 的是谁、为什么 |
| | `evacuate` 第 2 轮 | | | |
| | **m5 关机**（下线时刻 T0） | 运营者 | | |
| | 同事 A `fleet` 进 m4 | A | T0+__ | |
| | 同事 B `fleet` 进 m4 | B | T0+__ | |
| | 最后一位恢复操作 | | **T0+__ 分钟** ← 读数 | |
| | m5 开机、agent 回连 | 运营者 | `/nodes` 回到维护中 | |
| | 检查清单 | 运营者 | | |
| | `leave` | 运营者 | | |
| | 搬回（可选） | | | |

**演练后**：哪一步比预想慢、哪条命令的输出看不懂、谁被影响了——改到这份手册里，再提 PR；把 `fleet_audit` 的 ENTER/LEAVE 两行时间一起贴上。

**已做过的演练**
| 日期 | 版本 | 读数 | 记录 | 学到 |
|---|---|---|---|---|
| 2026-10-04 | 温和版（见 2 节末） | 8 分 09 秒 | #1427 | `--rebalance` 遇阻即停（#1513）；入口只认主仓库（#1512）；落后的安装把维护中画成失联、派不了单（#1507）；手册加了温和版一节 |

全量版（真关机）还没做过：按运营者定的低峰时段，先把两台机器同步到含 #1505 的版本，再按第 2 节走。

## 5½. 机器之间互访：一律经入口（#1626）

一台机器去另一台（打开别机会话 `fleet-remote-view.sh`、`fleet-node-upgrade.sh --host`、
`fleet-move.sh`），每次 ssh 前先用本登录的节点令牌向入口申请
`POST /v1/node/peer-cert {target, purpose: view|upgrade|move}`：入口核对目标机器上有
**同一主人**的登录，签一张 **5 分钟**、principal 只有那个登录、key id 写明
`peer:<来源>><目标>:<用途>` 的证书，先记审计再交出。目标的 sshd 用本来就信任的入口 CA
（`TrustedUserCAKeys`）放行；连接建立后不受证书过期影响。

- 入口不可达 / 拒绝：**暂停并说明**，不退回长期互信（`fleet-peer-cert.sh` exit 1）。入口不可达在
  **1 秒内**拒（连接只等 0.8 秒、只试一次），并给出绕法：「入口失联，机器间访问暂停；你可直接
  `fleet <机器>` 进去」——见第 5¾ 节。
- 没有入口（单机、无 node.env）或入口还没部署 #1626：照旧直接 ssh（exit 3）。
- 审计：`GET /v1/fleet/peer-certs`（运营者），每次跨机一行；目标 sshd 日志里也有 key id。
- 本机的 peer 钥匙：`~/.ssh/fleet-peer`（只用来被签，不放进任何 authorized_keys）。

**删除旧互信**（运营者 2026-10-04 已同意）：入口部署后，在 m5 上打开一个 m4 会话
（选路行出现「入口证书 5 分钟」）、`fleet-node-upgrade.sh --host m4 --status` 照常，
`/v1/fleet/peer-certs` 有两条；然后在每台机器上：

```sh
bash ~/.claude/fleet/bin/fleet-doctor.sh | grep sshtrust   # WARN 列出其它 fleet 机器的钥匙（行号）
# 删掉列出的那几行，再跑一次：PASS = 没有永久互信
```

删后再验一次跨机打开会话和升级。

## 5¾. 入口断开：照常干活，接上自动恢复（#1630）

入口（hub）重启、网络抖动、某台机器断网，都**不停任何会话**：入口只是看不见，不是指挥。

**断开期间**

| 谁 | 看到什么 | 能做什么 |
|---|---|---|
| m5 / m4 上的会话 | 什么都不变 | 照跑；认领在本机，入口回来再对账 |
| 你的本地壳（MacBook） | 列表保留最后一次的样子，60 秒后变灰（失联）；断开 5 分钟闪**一次**「入口失联」 | 右边直连照常——靠你那张 12 小时的客户端证书，不经入口 |
| 机器之间（打开别机会话、`fleet-node-upgrade.sh --host`、`fleet-move.sh`） | 1 秒内拒：「入口失联，机器间访问暂停；你可直接 `fleet <机器>` 进去」 | 自己 `fleet m4` 进去；**不**退回长期互信 |

**重连**（节点程序 `ccquota agent`，参数只在 `tokenledger/internal/agent/node.go` 一处）：

- 每次断开后按 **5 → 10 → 20 → 30 → 30 …** 秒重试（抖动只往短里抖，不超过 30 秒）——网络恢复到节点重新在线 ≤ 30 秒。
- 本机网络一变（换 Wi-Fi、睡醒、插回网线；macOS 路由套接字 / Linux netlink）**立刻**重试，退避清零。
- 接上后第一拍就是完整状态（所有会话、负载、版本），不等下一个周期。

**入口记的两类告警**（`fleet_alerts` 表，读：`GET /v1/fleet/fleet_alerts`）：

| kind | 什么时候出现 | 什么时候消除 | 入口做什么 |
|---|---|---|---|
| `node_lost` | 一台机器 **120 秒**没报到（`FLEET_NODE_LOST_ALERT_SECS`；从入口自己启动时起算，入口重启不会把所有机器都记失联；维护中的机器不记） | 它下一次报到 | 只记，`raised_at` / `cleared_at` 就是这次断开的起止 |
| `lease_conflict` | 一台机器**重连后第一拍**带着一个会话，而这张单的认领此刻在别的 worker 手里（它不在时被重开 / 强取了） | 两边重新一致：认领没了、回到它手里，或它不再报这个会话 | 只记两边是谁（`holder` / `reporter`：机器、worker_id、fleet），**谁也不杀、认领不动**——留哪个由你决定（第 3 节第 3 条） |

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$HUB/v1/fleet/fleet_alerts" | python3 -m json.tool
# {"open": 1, "alerts": [{"kind": "lease_conflict", "subject": "verkyyi/claude-fleet#7",
#   "detail": {"holder": {"node": "verkyyi@m5", …}, "reporter": {"node": "verkyyi@m4", …}}, …}]}
```

**演练：停入口 3 分钟**（运营者定时间；只停入口，不碰节点）

1. 记 T0，停入口（k8s：`kubectl scale deploy/<hub> --replicas=0`）。
2. 断开期间核对上表三行：m5 / m4 会话照跑；MacBook 列表变灰、右边可用；在 m5 上 `fleet-node-upgrade.sh --host m4 --status` 1 秒内被拒且有说明。
3. T0+3 分钟恢复入口，记 T1；`/nodes` 上 m5、m4 回到在线的时刻取较大者 − T1 = 读数（目标 ≤ 30 秒）。
4. `GET /v1/fleet/fleet_alerts`：断开超过 2 分钟的机器各一条 `node_lost`——注意入口停着的时候没人记，所以这次演练里**它们不会出现**（入口从自己启动时起算）；要看 `node_lost`，改为断某台机器的网 3 分钟，入口照常。贴出 `raised_at` / `cleared_at`。

## 5⅞. Codex 凭证只由入口一处刷新（#1666）

Codex 的刷新凭证（refresh token）**一次性**：谁刷新，服务端就换一张新的，旧的作废。
两方拿着同一张抢刷，后刷的那方被拒，登录状态变成 `reauth_required`——2026-10-04
就是这样：13:11Z 入口导入并（经 m4 转发）刷新了一次，23:46Z m5 本机 ccquota 的
自动刷新拿着旧的那张去刷，被拒；第二天切换撞上才发现，重登一次才恢复。

**所以一个账号只有一个刷新方**，`ccquota codex list --json` 里 `login.source` 就是它：

| `login.source` | 谁刷新 | `~/.codex/auth.json` 里 | 本机 `ccquota codex refresh` |
|---|---|---|---|
| `hub` 入口托管 | 入口（保险箱里的 refresh token；入口所在地被拒时经一台管理节点转发） | `refresh_token` 是占位符 `hub-managed`，节点程序 `ccquota agent`（`CCQUOTA_FLEET_CREDS=1`）到期前 2 小时续写 | **拒绝**，什么都不跑；登录状态只会是 `valid`，或续租没续上时的 `access_expired`（原因写明是节点程序，不是让你重登），或上游已拒绝这份租约时的 `access_rejected`（`upstream_error` 是上游的原话代码，如 `token_revoked`；得由入口重发一份，#1920） |
| `local` 本机自管 | 本机官方 Codex CLI（ccquota 到期前 24 小时催它） | 真的 refresh token | 照旧 |

**把一台机器切为入口托管**（批后、你点头后，**一台一台**；入口已部署含本单的版本）：

1. 入口保险箱里已有这个账号？`GET /v1/fleet/credentials` 看 `provider=codex` 的行
   （今天：`pool/codex/default`，就是 m5 的 `personal` 那个账号，m4 已在用它）。
   没有才导入：`bin/fleet-creds-import.sh --codex personal`——`personal` 住在 `~/.codex`，
   所以入口标签是 `default`（节点程序按标签把租约写回 `~/.codex`），命令会把映射打出来，
   并在导入后提醒**这台机器现在必须停止自己刷新**（第 2 步就是）。
2. 这台机器 `~/.config/claude-fleet/node.env` 加 `CCQUOTA_FLEET_CREDS=1`，重启
   `ccquota agent`（launchd：`launchctl kickstart -k gui/$(id -u)/com.ccquota.agent`）。
   节点程序先向入口续租，再把 `~/.codex/auth.json` 整个换成短期那半（`last_refresh`
   由它写）——切之前确认入口能续租：`~/.ccquota/agent.log`（凭据已隔离的登录：
   `sudo tail /var/log/fleet-cred/<登录>/agent.log`，#2296）里要有
   `credentials:` 成功行，没有就别切。
3. 验证：`ccquota codex list --json` 里 `login.source` 为 `hub`、`state` 为 `valid`；
   `ccquota codex refresh` 被拒；起一个 Codex 会话能用。然后才轮到下一台。
4. 之后 24 小时内 `auth.json` 的修改者应是节点程序（`last_refresh` 跟着
   `agent.log` 的续租时刻走），不是 Codex 自己。

**退回本机自管**：`codex logout` 再 `codex login`（新的一张，和入口那张互不相干），
并把 `CCQUOTA_FLEET_CREDS` 去掉重启节点程序；否则下一次租约又把 `auth.json` 换回去。

## 5⅞⅞. 一台机器上同一个人有两个 login（#2430）

迁移期间（#2210：管理员账号 verkyyi → 普通账号 verky）同一台机器上会有两个 login，
各有一个 fleet，都登记在同一个人名下。

- **放到哪就连到哪**：入口的放置答复带 `login`；客户端把每个 fleet 跑在哪个 login
  下记在 `$TMPDIR/.claude-dash/global/fleet_logins`（放置答复 + 每一轮会话清单），
  打开会话时 `ssh -l <那个 login>`，不骑别的 login 的暖连接。证书本来就签了这个人
  所有的 login，不用改 sshd。
- **侧栏**：会话清单里两个 login 的会话都在（证书路径下入口已按这个人全部
  (机器, login) 裁过）。
- **只让一个 login 接新会话**（运营者决定）：

  ```
  PUT /v1/fleet/settings {"key":"fleet.node_login.m5","value":"verky"}
  ```

  其他 login 在这台机器上不再接新会话（自动放置和点名都不行，指名它的 fleet 也拒），
  已开着的会话照常、恢复照常；值为 `""` 取消。不设就是以前的样子，按余量挑。

## 6. 速查

| 要做的事 | 命令 / 接口 |
|---|---|
| 标 / 撤 / 看本机维护中 | `fleet-node-maintenance.sh enter [--reason …]` · `leave` · `status`（本机 node 令牌，`POST/GET /v1/node/maintenance`） |
| 运营者标任意机器 | `/nodes` 页卡片按钮；或 `PUT /v1/fleet/settings {"key":"fleet.node_maintenance.m5","value":"原因"}`，`value:""` 撤 |
| 搬空闲会话到别台 | `fleet-spot-evacuate.sh [--dry-run]`（每个登录一次）= `fleet-move.sh --rebalance --max all` |
| 搬一个指定会话 | `fleet-move.sh <window> --via hub --to m4` |
| 进某台机器 | `fleet`（入口选）· `fleet m4`（指名）· `fleet connect --print` 看选了哪条线 |
| 认领释放 / 强取 | 自动：失联 30 分钟 · 手动：`ccquota lease acquire --force <repo> <N> <wid>` |
| 这台机器的 Codex 谁在刷新 | `ccquota codex list --json` → `login.source`：`hub` 入口托管（本机刷新被拒）· `local` 本机自管；切换见 5⅞ |
| 本机健康 | `fleet-doctor.sh` |
| 入口记的告警（失联 / 重复认领） | `GET /v1/fleet/fleet_alerts`（第 5¾ 节） |
| 审计 | 入口 `fleet_audit` 表：`node_maintenance`（ENTER/LEAVE/ALREADY/NOT_FLAGGED）、`lease_*`、`place`、`move` |

相关：`docs/FLEET-HUB.md`（入口、失联、租约）· `docs/SHARED-MACHINE.md`（给一台机器加登录）· `docs/HOST.md`（无人值守 Mac）· `tokenledger/README.md`「Fleet nodes」。
