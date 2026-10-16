# 回收前的只读影子核对

`bin/fleet_reap_shadow.py`（#4503）消费已有证据，逐维输出保留原因，并比较
同一身份上的旧 gate 与候选结果。它没有接入 cleanup、stop、retire 或守护循环，
不关闭窗口、不停止进程、不修改任务或清除 needs。旧 gate 仍独占实际回收路径。
所有结果，包括全维 clear，固定为 `actionable: false`、
`reason: not-actionable:no-atomic-boundary`。退出码 0 只表示成功输出一次观察。

## 分层与调用

`project(bundle, now=None)` 消费私有证据包；`read(pane, socket="", readers=None,
legacy_reader=None)` 做一次显式读取；`recheck(previous, fresh, now=None)` 核对先前证明。
命令行从 stdin 读取 JSON；`--previous /private/proof.json` 做重核，
`--pane %N --socket /private/tmux.sock` 做一次原生读取。没有 daemon、定时器或自动重试。
JSON 带原生身份，必须留在私有目录；对外只记录脱敏结论与验证层级。

证据包有三个字段：`runtime` 是原样的 `runtime.v1`；`layers` 是下表维度到
证据 envelope 的映射；`legacy` 是旧 gate **实际读到**的结果 envelope。
每个 envelope 为 `{version: 1, identity, source, observed_at, expires_at, value}`，
可另带 `evidence_at`（持久记录的原事件时间）、`unknown`、`stale`、`reason`。
`identity` 必须与 runtime 完全一致，包括 operation、task、owner、attempt、generation、
完整 worker/FID、provider、native SID/PID/birth/executable/endpoint 和 turn。
类型也必须一致；缺失身份不能按 pane 名、单号或时间临近补齐。

| 层 / 维度 | 证据和 clear 条件 |
| --- | --- |
| runtime | 直接调用 `fleet_runtime.read/project`；仅明确 idle 可继续，其 `reclaim.eligible` 仍为 false。active、ask、approval、interrupted、unknown 均保留。 |
| task | 当前 C1 GET，完整 owner/generation/worker/provider 匹配且 outcome 为显式终态；MERGED 字样不是 outcome。 |
| blockers | 从同一 task 调用 `fleet_task_control.blocker_projection`；仅 clear 可继续。缺字段、错 scope、revoked、active、stale 均保留。不会清 needs 或代替原生 attention。 |
| report | C6 持久 report 回执 disposition=committed，精确 task/owner/generation/worker/event、终态与 task 相符。progress、historical、未持久、未知均保留。 |
| pending_tool | 唯一 `fleet_pending_tool.observe` 的新观察，精确 native 身份相符且 code=1。code=0/4、旧 registry/无法读取/不支持均保留；no_pending 不单独授权。 |
| children | 现有 children GET 的完整 parent/task/session/generation 与空 children 集。当前版本保守保留所有非空 children，包括已 terminal 但未证明其 native 已安静的子任务。 |
| processes | 现有 owner 提供完整精确进程树观察：`complete=true, pending=[], unknown=[], fingerprint=<nonempty>`。fingerprint 覆盖 PID/birth/executable/祖先和 helper 精确分类。复用 #4318 分类与 #4474 采集，禁止按名字豁免或在聚合器里另建 process/provider probe。 |
| loop / delivery / transfer / migration / wake / outbox | 各 owner 的完整、当次空集合；缺文件、未挂载 reader、未知 lease 不等于空集合。controller 接受/投递仍由 #4431 所有。 |
| worktree | 原 gate 读到的 `clean=true, unpushed=false`；包括所有未持久工作。 |
| draft | 原输入快照明确空字符串；无法读输入保持 unknown。 |
| policy | 原 gate 的 `{value: <policy>, satisfied: true}`，使用唯一 `fleet_reap_policy.parse` 校验；keep 永远保留。 |
| grace | 原 gate 的 `{deadline: <epoch>}` 已到期，且该观察仍有效。 |

`read` 默认组合已有 runtime、pending-tool、task/children GET，以及
`fleet_reap_shadow_local.LocalSources` 的本地读取：通过现有 repo resolver 取得
配置，读注册工作树/HEAD/upstream，调用 `fleet-input.snapshot`、loop reader、
rotate lease reader、sleep phase/inbox、outbox、policy/grace 和 C6 只读回执。
没有 `@repo` 时不调用会回填 stamp 的兼容 resolver；缺 owner 存储目录时保留，
不会为观察创建 lifecycle 目录。旧 tmux 转义分隔符时使用有界逐字段回退，收集末仍比较全部字段。既有本地 helper 使用 named socket，因此本地
组合只接受与实际 session 同名的 socket；其它 transport 保持逐维 unknown。

进程树只通过 #4474 的 `Processes.collect/proof/ancestry` 读取；该次表传给
#4318 原有 `quiet_processes` 分类器的私有模块实例，不复制 helper 分类规则。
Claude 使用严格模式保留未知子进程；Codex 使用已有精确 helper 配置分类。
收集结束再通过同一个入口读一次树，任何变化使该维 unknown。
默认 pending-tool 另做自己的独立观察；因此完整 shadow 不宣称仅一次 ps，
也不属于 #4444 的整轮预算证明。所有读取仅按显式调用发生。

C6 report 适配器使用已有 `operations/action=task_receipt` 的 SQLite `mode=ro`，
其 authority hash 从既有 `fleet-task-record.sh authority` 取得。它不调用会
建表/expire/ack 的 Journal，不重放。新观察时间和原 `evidence_at` 分列；重复
report、错 hub、未知状态保留。journal 观察最多 1000 行，每行最多 64 KiB，SQL 扫描有 1 秒 progress deadline；outbox 最多 1000 个目录项，每文件最多 64 KiB，超限返回 unknown。controller 接受/投递回执仍未由 #4431 提供，
`delivery` 在记录本地 inbox 证据后保持 `controller_acceptance_unavailable`。

测试或外部 owner 可通过 `readers` 替换单维 reader；签名为
`reader(frozen_identity) -> envelope`。reader 必须核验真实 source 的身份、
完备性和时间，不能将传入 identity 盖到无关证据上；聚合器不认证任意 JSON。

`legacy_reader` 也必须返回 envelope，value 为 `{eligible: bool, reason: string}`；
必须是现有完整 gate 的当次结论，不能用某个子 gate 代替。没有它、身份不同或证据
过期时 `comparison=incomparable`。可比较时输出 `agree`、
`legacy-clear_candidate-retain` 或 `legacy-retain_candidate-clear`，连同全部 source、
时间、last_known 和 retained 原因。调用方把输出保存到既有私有证据位置；本模块不
新增影子 journal。本地默认调用既有 `Cleaner.candidate(dry_run=True)` 的完整对应路径，采用 daemon 的 cwd/环境；显式 `--pr N` 则调用既有 `fleet-cleanup.sh --auto --dry-run`。记录它真实返回的结论（含 no-PR 的 `would-clean:done-no-pr`）和 `pre-action-dry-run` 阶段，输出列出未观察的 history/resume/final-recheck/atomic-action gates，不把最后的 history/动作边界说成已经执行。当前没有生产 caller 接线，也不声称生产 gate 差异已采集。

## 失效与动作边界

每维观察最多 5 秒有效；不接受未来时间、非有限数或跨 TTL envelope。读取过期副本
不会刷新时间；远端断连、旧 mod、缺身份保留其 last_known 和原时间。证明有效期
取最早维度失效时间；任一来源的内容、修订、时间或身份变化都让旧 fingerprint 失效。
新 turn、子进程、lease、输入、工作树、report/outbox 和 policy/grace 都在比较范围内。
旧 gate 的观察也参与 fingerprint。即使只是一次更新了观察时间的合法读取，也必须
重新生成证明；这偏保守，不是缓存可持续续期的许可。

`read` 首尾通过既有 runtime reader 比较身份与原生状态；`recheck` 在旧有效期内
比较全部证据。**两次 read 不是 atomic permit**：最后读取之后仍可能出现新工作。
未来实际动作的 owner 必须在真实串行化动作边界重新读取同身份的全部 gate，并覆盖
原生 turn、子进程、lease 竞争。没有该边界，本接口一直 not-actionable。
启用回收动作必须另行审阅 shadow 证据并由现有 owner 落实，不在本 PR 自动交付。

## 验证层级

BREAK-IT `reap-shadow-race` 先登记并红于缺少聚合模块，再由
`fleet-reap-shadow-selftest.py` 覆盖长工具/CI、ask/approval、Stop、loop、children、
bg、未知进程、远端过期、脏树、未确认 report、blocker 关闭但 attention 未结束、
transfer/wake 与新 turn 竞争。fixture 没有 native 模型或真实 task authority。
隔离 socket + 临时 HOME 用真实内核进程观察验证树变化，结束后检查 server 和进程退出；
这仍是进程集成测试，不能写成真实 Claude/Codex 验收。

复用 [PR #4480](https://github.com/verkyyi/claude-fleet/pull/4480) 的 runtime 原生
证据及其中明确的层级：Claude 原生 mod→reader；Codex 受管 C3→read 的长工具/idle
单例；Codex 其它场景仅 collector。其模型和 C1 authority 为 fixture，真实 C1
operation/accepted-launch 投递前回执门禁仍缺证。没有把这些证据升级为本聚合器的
完整原生 gate 验收。部署、live activation、C8 退役门、#4431 接受/投递闭环保持独立。
