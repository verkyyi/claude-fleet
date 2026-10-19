# 巡检与自动报警：每种只留一处

issue #4271（发起人 2026-10-14 确认的「减法」第 3 条）。这一页是**全部**会自己报警、自己提醒、自己定时醒来的东西的清单。新加一个之前先来这里看：已经有的，不要再做第二个。

## 只报警，不开单（#4898）

自动开单的入口（`fleet-issue-file.sh --breakage`）随 issue 层一起去掉了（EPIC #4895 批 1）。下表的每个入口现在只**说**：把标题和正文写到那次运行的摘要页、发一条 `::warning::`（`bin/fleet-ci-say.sh`），macos-watch 发一条 `breakage` 提醒。key 仍不带 sha。要修就由人或编排会话派一件任务（`task` 工具）。

| 入口 | 通道（key 前缀） | 谁跑它 | 带的版本 |
|---|---|---|---|
| `bin/fleet-macos-watch.sh` | `macos-<红的测试>` | diskguard 每拍（10 分钟节流） | 红的 run 的提交 + run 链接 |
| `bin/fleet-nightly-miss.sh` | `nightly-<测试>` / `flaky-<测试>` | `selftests-nightly.yml` | 夜间全量测的 stable + run |
| `bin/fleet-train-quarantine.sh` | `selftest-quarantine.<测试>` / `flaky-<测试>` | `release-train.yml` 的「隔离」 | TRAIN_SHA + run |
| `bin/fleet-durations-drift.sh` | 耗时表漂移 | `selftests-nightly.yml` | 夜间全量 |

发布列车本身失败不开单：红的 Linux 测试由上面的隔离 / 重跑 / 夜间全量接住，红的 macOS 由 macos-watch 接住。

（desk 单随 #4898 去掉；管家的体检单和「待你动手」台账单随管家的巡查程序删了，#4339。）

## 提醒：每个红 run 一次

- macos-watch：每个红 run 一条 `breakage` 提醒，同一个 run 不重提（#4898 起不开单）。保留：红了超过 `FLEET_MACOS_STALE_SECS`（2 小时）「每台 Mac 停在上一版」一条，每段红一次。

## 定时巡检：一处

发起人定的是「巡检入口只留一个」。编排改成会话模板之后（EPIC #4333），这一个就是管家会话的 `/loop`；编排会话只谈、只派，不巡检（它的模板 `conf/agent-defaults/claude/agents/orchestrator.md` 写着）：

| 巡检 | 状态 | 说明 |
|---|---|---|
| 管家会话的 `/loop`（`spawn agent:steward`，只用通用工具） | **保留，唯一**，只挂一条 | 人起一个 steward 会话才有，从不自己起；关掉就没了。节奏由它自己的 `ScheduleWakeup` 定（模板 `steward.md`）。巡查程序（tick / 待答清单 / 面板 / 停放）已删（#4339）。代码里没有常驻的残留可删：#3118 / #3115 起常驻管家窗口、diskguard 拉起的 beat 都没有了，不要加回来 |
| 编排会话的自巡检 | 已收掉 | 编排模板不巡检；压缩后也没有角色状态叫它重建定时任务（#4340） |
| diskguard 的 macos-watch | 保留 | 是**探针**：只提醒（上一节），不开单、不替人巡检、不派人 |
| 各 watch 里每个红 run 一条的提醒 | 已收掉 | macos-watch 改成只在单子新开 / 重开时提醒 |
