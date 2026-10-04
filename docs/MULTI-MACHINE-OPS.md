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
| **失联** lost | 连续 3 次没报到（≈15 秒） | 心跳 | 只标记。会话行变灰归到 `─ m5 失联 N 分钟 ─`；它持有的 issue 认领（租约）**30 分钟后释放，不自动重派**（EPIC #1419 发起人拍板 2）。再响起心跳就回到在线/维护中。 |

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
- 确认 m4 接得住：`/nodes` 页「各登录」表里，**每个要迁的登录在 m4 上都有一行、在线**（登录不在 m4 上的人，他们的会话搬不过去——先按 `docs/SHARED-MACHINE.md` 加登录）。看 m4 的负载/内存/每人会话上限（`fleet.node_cap.m4`，默认 6）够不够。

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

## 3. 意外下线（断电、死机、网断）

**现象**（15 秒内）：`/nodes` 上 m5「失联」；每个人的侧边栏顶行 `○ m5 N · N 分钟没联系`，m5 上的行变灰归到 `─ m5 失联 ─` 组；m4 上 `fleet-children.sh` 把在 m5 上的子任务标 lost；`fleet connect` 自动落到 m4（m5 不在线就不会选它）。

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

## 6. 速查

| 要做的事 | 命令 / 接口 |
|---|---|
| 标 / 撤 / 看本机维护中 | `fleet-node-maintenance.sh enter [--reason …]` · `leave` · `status`（本机 node 令牌，`POST/GET /v1/node/maintenance`） |
| 运营者标任意机器 | `/nodes` 页卡片按钮；或 `PUT /v1/fleet/settings {"key":"fleet.node_maintenance.m5","value":"原因"}`，`value:""` 撤 |
| 搬空闲会话到别台 | `fleet-spot-evacuate.sh [--dry-run]`（每个登录一次）= `fleet-move.sh --rebalance --max all` |
| 搬一个指定会话 | `fleet-move.sh <window> --via hub --to m4` |
| 进某台机器 | `fleet`（入口选）· `fleet m4`（指名）· `fleet connect --print` 看选了哪条线 |
| 认领释放 / 强取 | 自动：失联 30 分钟 · 手动：`ccquota lease acquire --force <repo> <N> <wid>` |
| 本机健康 | `fleet-doctor.sh` |
| 审计 | 入口 `fleet_audit` 表：`node_maintenance`（ENTER/LEAVE/ALREADY/NOT_FLAGGED）、`lease_*`、`place`、`move` |

相关：`docs/FLEET-HUB.md`（入口、失联、租约）· `docs/SHARED-MACHINE.md`（给一台机器加登录）· `docs/HOST.md`（无人值守 Mac）· `tokenledger/README.md`「Fleet nodes」。
