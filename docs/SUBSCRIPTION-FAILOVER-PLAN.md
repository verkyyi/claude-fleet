# 订阅额度耗尽后的会话续接：基于现有机制的方案审查

状态：#599 实现与验收中。已整合 #753 的 Codex home 入口和 #754 的原生状态
读取；启用统一策略时，账号及额度后端使用 ccquota，旧的独立 Codex pool 模式
保持兼容。发布/机器启用结果以 PR 和逐机器验证记录为准。

目标：一个任务会话触及订阅限额时，优先换同类 Coding Agent 的可用订阅；
没有合格同类目标时再跨 Agent 交接；都不可用则保留任务等待。继续携带原始
Agent、原始会话路径、交接链、未发送草稿和循环。适用于 Claude ⇄ Codex 两个方向。

## 1. 审查结论：扩展现有链路

沿用 [#599 跨 provider 溢出](https://github.com/verkyyi/claude-fleet/issues/599)
和 [#602 Codex 多 home](https://github.com/verkyyi/claude-fleet/issues/602)。#599
原先以新建 worker 为主，本需求增加**运行中会话及双向切换**，需要同步更新其
验收范围。#600 团队归因、#601 优先级/个人预算、#607 状态命名重构各自保持独立。

| 职责 | 已有机制及证据 | 本次扩展 |
|---|---|---|
| 账号、登录、额度采集 | ccquota 已有 Codex profile 注册、官方登录/续期、独立 home、quota hub | Fleet 消费现有接口，补本机可启动 profile 与额度账号的对应关系 |
| 排名、冷却、额度缓存 | [fleet-account.sh](../bin/fleet-account.sh)：`quota_parse`、`pick_best`、`pick_active`、bench、phase、hysteresis | 同一策略入口增加 Codex adapter、账号命名空间及严格迁移目标选择 |
| 定时额度治理 | [fleet-quotawatch.sh](../bin/fleet-quotawatch.sh)：有时限的机器级 tick、锁、心跳、按 fleet socket 扇出 | 加 Codex 读数及待迁移会话重试，沿用现有 daemon |
| 已发生的额度错误 | [tmux-dash-collect.sh](../bin/tmux-dash-collect.sh) 的 `ph_banner`；已有 model-cap 分流 | Claude banner 与 Codex 原生错误进入同一决策入口 |
| Claude 同类换订阅 | [fleet-migrate.sh](../bin/fleet-migrate.sh)：真实账号校验、退出后 `--resume` | 保留执行器，增加明确目标账号和共享互斥 |
| 会话交接 | [fleet-transfer.sh](../bin/fleet-transfer.sh)、[.fleet-transfer.py](../bin/.fleet-transfer.py)、[waiter](../bin/.fleet-transfer-wait.py) | 补 `--to claude`、目标 profile、额度受阻时的安全交接条件 |
| Codex 身份与恢复 | [fleet-codex-session.py](../bin/fleet-codex-session.py)、[launcher](../bin/fleet-codex.sh)，PR #747 | 在已有 UUID/home/rollout 身份上绑定实际订阅，核验目标启动完成 |
| 循环 | [fleet-loop.py](../bin/fleet-loop.py)：schedule、绑定会话、投递状态及去重保护 | 保留同一循环，补 Claude 投递 adapter、换账号及等待额度恢复 |
| 人工交接入口 | [/fleet-handoff](../commands/fleet-handoff.md) + 基础 [handoff skill](../skills/handoff/SKILL.md) | 同一入口描述两个目标；自动限额路径直接调用控制器，无需源模型再写一轮总结 |

不增加第二份凭证池、额度采集服务、切换 daemon、交接协议、会话历史库或循环定时器。
若需要抽取共享决策函数，它仍属于 `fleet-account` 的策略层，由现有调用方复用。

## 2. ccquota 已提供的接口

已核对本机 CLI 及 TokenLedger 源码（本地 checkout `237abde`；已安装 ccquota
自报版本 `7db2bda-codex-auth.b6e94b594709`）。二者不是同一构建标识；应在实现时做
接口能力探测。当前已有命令：

```sh
ccquota codex list --json
ccquota budget --source claude --account all --json
ccquota budget --source codex --account all --json
```

依据：TokenLedger 的 `cmd/ccquota/codex.go`、`cmd/ccquota/budget.go`、
`internal/codex/profiles.go`、`internal/codex/refresh.go` 和 `internal/agent/codex.go`。

- `list` 提供 profile 名称、home、规范账号 ID、登录健康信息；`budget` 提供 source、
  account UUID、available、blocked、headroom 和通用 `windows[]`。接入这两个结果，
  不另读或复制 `auth.json`。这里的账号 profile 不等于 Codex 的配置 profile。
- `--account all` 返回 hub 可见账号；候选必须与**当前机器实际可启动的 profile**
  取交集。MINI 与本机分别解析本地 home，不能把另一台机器的路径作为启动目标。
- 同一个账号的多个 home 共享订阅额度。以 `(source, account_uuid)` 合并限额状态，
  home 只是本地启动入口。Claude 继续兼容现有 label 与 `.conf` 中的 UUID 映射；
  未确认账号映射时，不宣称能跨别名准确去重。
- 启动时把已验证账号绑定到准确会话身份；之后某 home 重新登录，不能把仍运行的
  旧会话改标为新账号。新目标核验失败时刷新观测，不能覆盖已有来源记录。
- Codex 窗口携带 ID 和时长，`primary` 不保证是五小时；读取 `windows[]` 与
  `blocked`，不能把缺失的 Claude `five_hour/seven_day` 字段补成零。
- ccquota 已区分陈旧/不可读与可用额度，并负责采集去重及官方续期。Fleet 保留这些
  区别。hub 的 quota lease 是**采集权**，不是运行会话的额度预留。
- `ccquota codex run` 持有共享运行锁，login/refresh 用互斥维护锁；多个运行锁可以
  并存。Fleet 目前直接启动 Codex，必须接入这套锁协议并对齐 file credential store。
  TUI、私有 app-server、loop bridge 要使用同一目标 home，锁覆盖完整运行生命周期；
  不通过修改全局 `ccquota codex use` 来迁移某个窗口。

账号状态与策略状态仍由各自既有组件管理：ccquota 管登录和观测；Fleet 管选择、
bench 和切换尝试。新增 Fleet 字段只保存身份、决策依据和恢复信息，不保存凭证。

## 3. 决策顺序

```text
确认是订阅额度阻塞 / 已配置的预防性阈值
  → 当前 Agent 的其他合格订阅
  → 允许切换的另一 Agent 的合格订阅
  → 持久化 waiting-quota，由现有 quotawatch 后续 tick 重查
```

“合格”同时要求：本机可启动、身份可验证、读数有效且低于已有 ceiling、未 bench、
目标模型可用、任务所需能力满足。复用已有排名、滞回与 phase 策略；同类优先是
候选分组顺序，不能让跨类账号仅因分数更高就抢先。源 Agent 恢复额度后不主动切回，
避免任务在两边来回搬迁。

同类账号没有可验证的可用目标时，可以选已验证的跨类目标，但记录原因是
`unreadable`、`auth-unavailable` 还是 `exhausted`，不能统称“全部用完”。自动迁移
不选未知目标；保留现有新建会话在全部读数未知时的兼容行为，不顺手改变全局契约。

保留现有 per-model cap 与 `/model` 降级分流；单模型受限不能默认宣布整个订阅耗尽。
短时节流、网络错误、登录失败、人为预算暂停、等待人工批准分别处理，不据此跨
Agent 绕过限制。候选范围沿用已授权订阅，不自动转用付费 API key/credits。

新建会话也复用同一目标选择：先确定实际 Agent/账号，再判断对应额度。
`fleet-dispatch.sh` 已跳过 Codex 的 Claude quota gate；这不代表已经有 Codex gate。
补上 Codex 判断时保留原先修复，不能让 Claude 池空阻止可用的 Codex 启动。

## 4. 必须修正的具体接点

### 4.1 目标选择不能依赖 `active` 非空

`fleet-account.sh:pick_active` 在所有账号都 limited 时仍可能返回当前账号，服务于
旧的启动兼容路径。现有 `quota_move_target` 和 `migrate_noop` 已识别这类问题，
应抽取/复用严格的迁移候选判断。

决策结果要固定 source 会话身份、target Agent/account/profile/home 及观测依据，
传给执行器。现有 quotawatch 的 `qto` 主要用于“是否有目标”，migrate 启动时再读
全局 active；自动切换需消除这个竞态。源退出前再核验目标；失效就重新等待，
不能退出后才发现选到了另一个已满账号。

### 4.2 同时接入主动阈值与实际报错

`ph_banner` 当前仅在 `mark-limited` 返回 10（active 发生变化）时发起迁移。
同类池耗尽正好可能没有这个返回值，因此只在 quotawatch 加分支会漏掉实际报错。
两条入口都应提交同一种“该会话需要续接”的请求，Codex 已确认的额度错误也如此。

Codex 事件识别复用现有 [RPC helper](../bin/fleet-codex-rpc.py) 与准确线程身份；
额度库存仍读 ccquota，不再轮询建立另一套账号额度缓存。实现时验证错误来自本次
会话/当前订阅，避免把屏幕历史或 rollout 中上一轮的报错重复当成新事件。

### 4.3 告警去重与切换重试分开

quotawatch 会先写 `quota.ceiling.<label>`，再 bench/派发；没有目标也会写标记。
以后相同 reset episode 会跳过。它适合一次性告警，不能代表该账号所有会话已迁移。

在既有 Fleet 状态目录保存每个待续接会话的请求及结果，关联 transfer manifest。
请求绑定机器/fleet socket/窗口/原始会话 UUID、来源账号和限额 episode；同一会话
同时只能有一个有效请求，即使不同入口提供了不同 reset 信息也要合并。状态至少区分
waiting、preparing、source-exited、starting、bound、failed/ambiguous。
后续 tick 有界退避重试 waiting，读数更新、新账号加入和 reset 都可重新评估。
关闭、已完成、被人工换线程的会话撤销请求；永久能力缺失明确报告，不无限重启。

### 4.4 复用迁移执行器，补真实互斥

Claude → Claude 继续用 `fleet-migrate` 的原生 resume；Codex 换 home 首版使用
已有 packet 续接到新会话，直到跨 home 原生 resume 有明确验证。仅给旧 UUID 换
`CODEX_HOME` 不能保证新 home 找得到历史。跨 Agent 都由 `fleet-transfer` 执行。

`fleet_rotate_lease_take` 是写文件的清理保护，不是原子互斥锁；transfer 的
`.transfer-lock` 才通过原子 mkdir 排他。让 migrate、transfer、context cycle、
model switch 共同遵守同一转换锁及已有状态标记，避免并发控制同一窗口。
保留 TTL lease 对退出 hook/清理器的保护，两者不能互相替代。

### 4.5 额度已满时也能生成交接包

已有 packet 可从准确 transcript、工作区和 git 状态生成，不依赖源模型继续回答。
但 transfer 当前要求 `done` 或 `--after-turn` 的新 Stop；额度阻塞可能停在
working/needs，不能直接放宽为“所有 needs 均可退出”。

增加明确的 quota 原因及证据校验：限额对应当前会话、当前回合确已停止发起工作、
工具/子代理已静止、没有人工确认对话或正在输入。仍在执行则等待；不能伪造 done、
强杀工具或因调用超时假定它失败。保留原始工具调用/结果及未完成动作，目标先核对
实际结果再继续，避免重复写入。Codex `history.md` 当前只摘取 message，完整工具
证据在 `source.jsonl`；pickup 应明确指向它，或扩展现有 renderer。

未发送草稿单独存文件并标记 `unsent`，交接包引用它，不拼接进自动执行的任务提示。
现有退出路径会清空输入框且截图不能证明长草稿完整；无法可靠保存时，等待用户
结束输入/处理草稿，不能静默清除。这沿用此前 GrowthAgent 的草稿保留约定。

### 4.6 明确目标绑定成功与恢复边界

在现有 manifest 中增加目标账号/profile/home 和切换原因，保留 `source.agent`、
`source.session_id`、`source.transcript_path`、冻结副本、`previous_handoff`。
接收者既能看到直接前任，也能沿链追到最初会话。旧 manifest 继续可读。

目前 transfer 的 started 仅表示出现 Codex 进程。自动限额迁移应核验：目标 launcher
仍拥有窗口、准确原生会话已绑定、工作目录正确、实际认证账号符合目标、必要的
hooks/任务能力可用，然后才解除交接状态并恢复循环。排除私有 app-server 或子代理
PID 被误当成目标成功。模型配置和权限按目标 adapter 明确映射，不扩大授权。
目标认证应在自动投递 pickup 任务前确认，不能让身份尚不明确的新进程先开始续做。

源退出前失败则保留原会话；源退出后保留 packet、窗口及恢复状态。超时/进程归属
不明不自动启动第二个写作者。确认没有目标进程写工作区后才能恢复源或改选目标。
在同一额度 episode 内记录已失败目标及退避，避免 Claude ⇄ Codex 无限往返。

现有 transfer 的范围是准确登记、独占 pane、拥有 linked worktree 的 worker/raw
scratch；hub、panel、未登记原生线程等不能靠去掉守卫来实现“任意 Session”。
不支持的会话明确保持 waiting/unsupported；进一步扩大范围需单独补身份与隔离能力。

## 5. Loop 随任务续接

PR #747 已支持 Codex context cycle 携带 active loop；Claude → Codex 的显式循环
导入也已存在。继续扩展 `fleet-loop.py` 的持久状态与投递 adapter，不创建替代 timer。

1. 进入转换锁后暂停旧 owner，保存 prompt、interval、next_run_at、最后一次投递及
   所属会话；在已有状态中延续稳定循环标识和 ownership generation。
2. 转移中或 waiting-quota 时不发新一轮；新会话及订阅核验后再绑定。跨多个交接包
   只能有一个有效 owner，旧进程晚到的结果不得解锁新 owner。
3. Codex 使用既有私有 app-server 投递；Claude 优先复用
   [fleet-peer-send.sh](../bin/fleet-peer-send.sh) 的原生 inbox，补准确 session 校验与
   接收确认。其当前成功仅表示 frame 写出，不能当成已经执行一轮；验证后才可宣称
   Codex → Claude 自动循环可用，不退回模拟键盘输入 prompt。
4. 保留“错过多次只唤醒一次”及 delivering/paused 不盲目重放的语义；额度失败若已
   确认没有执行，可以进入等待，否则保留不确定状态供检查。未发送草稿不触发唤醒。
5. 目前 loop bridge 绑定 TUI 生命周期；全池等待及机器重启后的重新绑定需接入
   现有恢复/tick 路径。仅复制 loop spec 不能满足持续自动唤醒的验收。

## 6. 实施拆分与验收

| 顺序 | 对应已有 issue | 可独立审查的改动 |
|---|---|---|
| 1 | #602 | ccquota 接口能力探测、Codex profile/额度 adapter、账号绑定与严格候选；先支持 dry-run 决策 |
| 2 | #602 / #599 | 固定目标参数、共用转换锁、Codex 同类换账号、transfer 双向 adapter 与 quota 受阻入口 |
| 3 | #599 | quotawatch/banner/Codex 错误汇合、每会话待处理状态与有界重试；复用 loop 状态补双向连续性 |
| 4 | #599 | `/fleet-handoff`、能力矩阵、dashboard/doctor 的等待原因与目标显示；完整 gate 后同步本机及 MINI |

配置入口为 `FLEET_FAILOVER=1` 和 `FLEET_FAILOVER_AGENTS=claude,codex`，默认关闭。
`fleet-account.sh inventory/choose/reconcile/failover-status` 提供观测、预演与状态。
启用前完成对应组合的能力验证。发布沿用现有同步流程，逐机器确认
版本、ccquota 接口、本地账号/home 与 fleet 配置；全机共用 daemon 按命名 socket
工作，不为每个 fleet 再安装一套额度监控。回滚关闭新决策入口并保留恢复 packet。

扩展现有 `fleet-account`、`fleet-quotawatch`、`fleet-quota-blind`、`fleet-migrate`、
`fleet-transfer`、`fleet-loop`、`fleet-codex-recovery` selftests，验收必须覆盖：

- Claude A → B 保持原生 resume；Codex A → B 优先于跨 Agent；两方向跨类续接。
- `active` 非空但全满、部分不可读、读数陈旧、不同额度窗口、blocked、重复账号 home，
  以及 hub 有额度但本机没有登录入口。
- 告警已去重后目标恢复仍会重试；同时触发 banner/watch 只执行一次；准备期间目标
  换账号/耗尽、source UUID 变化、手动关闭会话都不会误退出。
- 源额度耗尽不能再调用模型、工具尚未结束、人工确认、未发送草稿、多次交接原始
  路径可追溯，以及目标认证失败/进程存活但线程未绑定。
- 原 loop 停发、新 owner 只唤醒一次；Claude inbox 接收证据、投递超时不重复、全池
  等待/reset、bridge/daemon 重启后恢复，以及 completed/stopped 不被重新唤醒。
- 同机多个 fleet socket 和 MINI 的本地 profile 隔离；两个 home/机器登录同一账号
  不被当成两份容量；新建会话使用实际目标 provider 的 gate。

tmux 测试只用隔离 socket；通过 `run-selftests.sh` 的 shadow root 运行。代码修改的
发布 gate 保留 Bash 3.2、BSD portability 与 macOS/Linux 检查，运行期间不编辑 bin。
实施后运行账号、交接、循环及恢复的行为测试，再运行完整发布 gate。
