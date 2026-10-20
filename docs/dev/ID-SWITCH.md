# 切到「一个窗口一个 ID」：MacBook 会话照做的说明书（EPIC T497 C7）

这份说明书给**操作者 MacBook 上、不在任何 fleet 里的 Claude 会话**照做（设计页 §5.1 第 4–7 步）。
切换改的是所有会话都要过的那道门（认领 / 启动合约 / 执行权 → 「窗口有 ID」）；在 fleet 里切，
动手的会话可能被自己刚改的门挡在外面、半途丢掉（10-19 版本更新重开就是这样丢的，#4974）。
所以动手的会话在 MacBook 上，fleet 里的会话只看、不动。

前提：C1–C6 已合并（`a2fd34bbb` C1 … `093cb2483` C5、`f756aaefa` C6）。规则本身见
[FLEET-ID.md](FLEET-ID.md)「迁移与切换开关」；这里只写怎么做、每步该看到什么、哪里不对就停。

## 规矩

- 只用 `fleet` 客户端、hub 接口和节点自带的 `fleet-id.sh`（经 ssh 跑，不在任何 tmux 窗口里）；
  **不手改节点上的任何文件**，不 kill 任何 tmux。
- 每一步先看输出再走下一步；输出和「期望」对不上就**停**，把输出原样记下来，不要「修一下再继续」。
- 整个过程记一份切换记录（MacBook 上 `~/fleet-id-switch-<日期>.md`）：每步的命令、原样输出、对上没有。
  做完拷一份到 `$OPS` 的 `~/fleet-drafts/epic-session-t/switch-record.md`，告诉 T497 的驱动会话「切换完成」或「停在第几步」。
- 迁移 `--apply` 是单向的（每条写了审计，迁前整条记录在 `fleet_operations` 里）；能来回的是**开关**。

下文用两个变量，值由驱动会话转交说明书时一并给出（不写进仓库）：
`$OPS` = 运营方机器上运营方的登录（迁移与开关只从这里或 MacBook 的 `fleet hub` 做），
`$OTHERS` = 其余每个承载会话的登录（hub 上的机器名以 `fleet hub machines` 为准）。
`ssh <登录>@<机器>` 用操作者平时进那台的路（端口 22，或 entry 端口 22022）。

```bash
OPS=alice@mac-a                  # 例：运营方的登录@机器
OTHERS='bob@mac-b carol@mac-b'   # 例：其余每个登录@机器
F='~/.claude/fleet/bin'          # 节点上 fleet 的 bin（托管登录是到 runtime 的链接）
```

## ④ 核对所有登录都到了含 C1–C6 的版本

```bash
fleet update && fleet status                                     # MacBook 自己的客户端先跟上
ssh $OPS "$F/fleet-installs.sh"                            # = fleet doctor --installs
for h in $OTHERS; do ssh $h "$F/fleet-installs.sh"; done
```

期望：每份最后一行 `verdict: N of N install(s) at stable`；`login install` 每个登录一行、`= stable`；
`online client` 那行的 MacBook 不再是 `? (an older client says no version)`。再确认 stable 含 C1–C6：

```bash
S=$(ssh $OPS "$F/fleet-installs.sh" | sed -n '1s/.*stable \([0-9a-f]*\)).*/\1/p')
gh api repos/verkyyi/claude-fleet/compare/093cb2483...$S --jq .status   # ahead 或 identical
```

不对：某个登录不是 stable ⇒ 等它自己的更新 tick（托管登录跟 runtime，`落后 Nm` 超过 30 分钟就到那个登录看
`fleet doctor` 的 `install` 行），**不齐不往下走**。`compare` 是 `behind`/`diverged` ⇒ stable 还没带上 C1–C6，停。

### 切换前的基线（C1–C4 的上线证据，开关关着取）

在 `$OPS` 上用 ⌘N 开一个会话（下称 A），在里面依次做，每做完一项在 MacBook 上读一次：

```bash
ssh $OPS "$F/fleet-id.sh get <A 的短码>"
```

| 做什么 | 期望（`get` 的输出） |
|---|---|
| A 里 `/clear` 两次（S1） | ID、短码不变；多两段 `trigger clear`；⌘P 那一行编号不变 |
| A 里 `/compact`（S5） | 不多段；当前段压缩次数 +1 |
| A 里 `/fleet-handoff --to codex`（S4） | ID 不变；Codex 第一轮后多一段 `agent codex · trigger transfer`；⌘P 的 Agent 列变 Codex |
| ⌘P 截一屏 | 每行编号是 `T-xxxxx`；搜 `#4539` 出对应会话（C3） |
| A 派一个子会话（让它 `report` 一个 waiting 结果），A 再 `/clear`；然后子会话报 | 子会话的回报出现在 A 里，`get <A>` 的子 ID 列着它（C4） |

把四张 `get` 输出和截屏记进切换记录。任何一项不对 ⇒ 停：那是 C1–C4 的缺陷，不是切换的事。

## ⑤ 迁移 `--apply` + 打开开关

### 5a 迁移前收掉 T510 的空窗口

T510（T-kanwg）是 10-19 00:08Z 启动失败留下的死记录（`launch: unknown: no matching process/native-session
receipt; task input withheld`，没有 transcript），它的窗口 `@1075` 还开着，所以 dry-run 会把它定成「活着」。
⌘P 搜 `T-kanwg`（或 `T510`），确认是 `$OPS` 上 `@1075` 那个空窗口，回收它（⌃x，或 `fleet close <名字> --yes`）。

### 5b dry-run，与样例表逐条对

```bash
ssh $OPS "$F/fleet-id.sh migrate --only T351,T354,T355,T364,T478,T480,T488,T489,T510"
```

期望第一行 `dry-run（只看，不改） · 9 条旧记录 · 开关 关`，然后每条：

| 记录 | 期望定成 | 依据里该有 |
|---|---|---|
| T351 / T354 / T355 / T364 | 已取消、已关闭 | 节点回答没有窗口带 `86a316d7` / `81c7af71` / `851422c7` / `881cc321`；记录有 cancel_request |
| T478、T489 | 已完成、已关闭 | 记录本身：已终态（succeeded） |
| T480 | 已取消、已关闭 | 记录本身：已终态（cancelled），没有 worker |
| T488 | 窗口还在 ⇒ `活着 → T-58yp1（别名 T488），结果：已完成`；窗口已关 ⇒ 已完成、已关闭 | 节点回答窗口在 / 不在 |
| T510 | 已退出、已关闭（回收前发过取消则已取消） | 节点回答没有窗口带它（5a 之后） |

最后一行 `合计：…`。参照：10-19 驱动会话在 fleet 里跑的 dry-run（T488 那时窗口已关、T510 未回收）是
`合计：live 1 · succeeded 3 · cancelled 5`，其中 `live` 是 T510 → T-kanwg。

再跑一次不带 `--only` 的全量 dry-run，看有没有样例表外的记录：

```bash
ssh $OPS "$F/fleet-id.sh migrate"
```

期望：没有一条是 `等节点回答（不迁）`。有 ⇒ 那台机器的节点没答（失联、tmux 没起、旧 agent），它的记录一条都不会动；
先让那台机器上线（`fleet hub machines` 看它）再从 5b 重来。表外的记录逐条看依据是否说得通，说不通就停。

### 5c apply

```bash
ssh $OPS "$F/fleet-id.sh migrate --apply"
```

期望第一行 `迁移（已写入） · N 条旧记录 · 开关 关`，每条末尾 `✓`（`活着` 的那条写进了别名）。立刻再跑一次 dry-run：

```bash
ssh $OPS "$F/fleet-id.sh migrate"      # 期望：0 条旧记录（迁过的不再列出）
```

### 5d 打开开关

```bash
fleet hub set fleet.id_switch on              # MacBook，运营方的令牌（CCQUOTA_VIEWER_TOKEN）
ssh $OPS "$F/fleet-id.sh switch status"   # 期望：on
```

（等价的另一条路：`ssh $OPS "$F/fleet-id.sh switch on"`。）每个节点在下一次清理 tick（60 秒）
问到开关、写进自己的 `ids/.switch`：

```bash
for h in $OTHERS; do ssh $h "$F/fleet-id.sh switch status"; done   # 都是 on
```

## ⑥ 每个登录各开一个会话，走 S1 / S4 / S10

每个登录各用 ⌘N 开一个新会话（不复用切换前的 A），记下短码，各做：

| # | 做什么 | 期望 |
|---|---|---|
| S1 | `/clear` 两次 | `fleet-id.sh get <短码>`：ID 不变、多两段 `trigger clear`；⌘P 编号不变；之前报的结果还在 |
| S4 | `/fleet-handoff --to codex` | ID 不变；Codex 第一轮后多一段 `agent codex · trigger transfer`；⌘P Agent 列 Codex |
| 回报 | 让会话用 `report` 报一个 `waiting` 结果 | `get` 的结果里有它；⌘P 那一行照它显示；hub 没有 409 `ID_SWITCH`（回报走 ID 了） |
| S10 | 见下 | hub 上这些 ID 与本机账本逐条一致 |

S10 的核对（每个登录）：本机账本与 hub 镜像对每个活着的 ID 一致——

```bash
ssh <登录>@<机器> "$F/fleet-id.sh get <短码> --json"                          # 本机账本
ssh <登录>@<机器> "$F/fleet-id.sh _post GET /v1/node/ids/<短码> </dev/null"   # hub 镜像：第一行 200
```

期望：两边的段（agent · native · trigger）与结果条数一样，没有重复的结果；⌘P Tab 操作页没有「未登记到 hub」。

断线补齐（S10 本身）在 `$OPS` 上做一次：hub 断着的时候开 3 个窗口各报一个结果，hub 回来后再按上面逐条核。
没有计划内的 hub 停机就不要为它停 hub——补推每 60 秒由清理 tick 做，断线补齐已由
`bin/fleet-id-hub-selftest.sh` 钉住；切换记录里写「S10 断线一项：用 selftest 代替 / 在 <时间> 的 hub 停机里实测」。

还要看一眼 fleet 里的派单：在任一登录的会话里用 `task` 工具派一个小任务，期望它开窗不认领、
做完 `report merged` 后记录收口、`await T<n>` 返回。

## ⑦ 出错：关开关回退

任何一步不对，或开关开着后有会话被门挡住（认领被拒、回报丢了）：

```bash
fleet hub unset fleet.id_switch                   # 或 ssh $OPS "$F/fleet-id.sh switch off"
ssh $OPS "$F/fleet-id.sh switch status"    # 期望：off
```

关回来就是旧行为：旧表没删、写侧双写还在，带 `@launch` 的窗口照走旧路；窗口、ID、账本都不动
（BREAK-IT `id-switch-flip-report`）。已 `--apply` 的记录保持迁好的终态——没有「反迁移」，迁前整条记录在
`fleet_operations`（`action=id_migrate`）里。把出错那步的原样输出记进切换记录，交给 T497 的驱动会话。

## 做完

切换记录里每个登录的 S1 / S4 / S10 都对上、样例表 apply 后吻合 ⇒ 拷到 `$OPS`、告诉驱动会话「切换完成」。
开关开着稳定一个版本后才轮到 C8（删执行权层）。
