# 巡检与自动开单：每种只留一处

issue #4271（发起人 2026-10-14 确认的「减法」第 3 条）。这一页是**全部**会自己开单、自己提醒、自己定时醒来的东西的清单。新加一个之前先来这里看：已经有的，不要再做第二个。

## 一个开单入口、一种指纹

所有自动开单都走 `bin/fleet-issue-file.sh --breakage-key <通道>-<失败的测试或探测步骤>`（master 探针是 `--breakage`，它自己算 key）。

- **指纹里不带 sha。** 同一指纹有开着的单 ⇒ 每个新 sha 只追加一条评论（带 sha 和链接，`<!-- fleet:fault sha=… -->`；同一 sha 再来什么都不加），退出码 5。
- **关掉的单不另开新单。** 这次红的版本含关单的那个修复提交（compare API；人手关的单看提交时间是否晚于关单）⇒ 重开那张旧单；不含（还在测旧版本）⇒ 只在旧单上记一笔。退出码都是 5。
- **只有显式的 flag 才算故障单。** 普通建单的正文里有「红」也是普通单——#2175 的自动判定拿掉了（它把 #4268 认成了 macOS 的故障单，又吞掉了下一张单）。

| 入口 | 通道（key 前缀） | 谁跑它 | 带的版本 |
|---|---|---|---|
| master 红（执行会话、编排报红主干） | `ci-<失败的 job · 报错首行>` | 人 / 会话显式 `--breakage` | 红的那段起点的提交 + 那次运行 |
| `bin/fleet-macos-watch.sh` | `macos-<红的测试>` | diskguard 每拍（10 分钟节流） | 红的 run 的提交 + run 链接 |
| `bin/fleet-cn-probe-watch.sh` | `cn-path-<卡住的那层>` | diskguard 每拍（绿 6 小时、红 1 小时） | 它测的 stable |
| `bin/fleet-nightly-miss.sh` | `nightly-<测试>` / `flaky-<测试>` | `selftests-nightly.yml` | 夜间全量测的 stable + run |
| `bin/fleet-train-quarantine.sh` | `selftest-quarantine.<测试>` / `flaky-<测试>` | `release-train.yml` 的「隔离」 | TRAIN_SHA + run |

发布列车本身失败不开单：红的 Linux 测试由上面的隔离 / 重跑 / 夜间全量接住，红的 macOS 由 macos-watch 接住。

**有自己去重、不算故障单的两处**（保留，不并进来）：

- 不绑仓库会话的 desk 单（`bin/dash-raw-session.sh`）：是台账，不是故障。

（管家的体检单和「待你动手」台账单随管家的巡查程序删了，#4339。）

## 提醒：只在单子新开或重开时

- macos-watch：新开或重开的单一条 `breakage` 提醒；同一张开着的单再红只留评论，不再提醒（以前每个红 run 一条）。保留：红了超过 `FLEET_MACOS_STALE_SECS`（2 小时）「每台 Mac 停在上一版」一条，每段红一次。
- cn-probe：每张单一条提醒（`global/cn-probe/filed` 记着），绿了忘掉。

## 定时巡检：一处

发起人定的是「巡检入口只留一个：编排的自巡检」。落到代码上：

| 巡检 | 状态 | 说明 |
|---|---|---|
| 编排会话的自巡检 | **保留，唯一**，只挂一条 | 编排会话自己的循环。压缩后 `[fleet orchestrator state]` 叫它先 `CronList`：同一 prompt 的定时任务还在就不再建、多的删到只剩一条（以前每压缩一次多一条，同时挂过 3 条一样的自巡检）。重开的会话里定时任务已经没了，照 `/loop` 形式重建一条 |
| 管家会话的 `/loop`（`spawn agent:steward`，只用通用工具） | 和自巡检重复，**不同时跑** | 人起一个 steward 会话才有，从不自己起；编排已在自巡检时不要再起管家。巡查程序（tick / 决定单 / 面板 / 停放）已删（#4339）。代码里没有常驻的残留可删：#3118 / #3115 起常驻管家窗口、diskguard 拉起的 beat 都没有了，不要加回来 |
| diskguard 的 macos-watch / cn-probe | 保留 | 是**探针**：开单（上面的指纹）和提醒（上一节），不替人巡检、不派人 |
| 各 watch 里每个红 run 一条的提醒 | 已收掉 | macos-watch 改成只在单子新开 / 重开时提醒 |
