# 显式任务阻塞契约

`task-blockers.v1`（#4502）在现有 T 任务、operation journal、mutation/report
和有界重放通道中记录依赖。它不改变任务 outcome、原生 ask/approval、runtime、
controller、投递或回收许可。页面消费属于后续单；旧客户端省略新字段时行为不变。

## 身份与字段

权威任务的 GET、列表、children 和新的 mutation/report 回执包含
`task_blockers: {version: 1, generation, items: [...]}`。旧记录没有该字段。
一次请求的幂等回执是当时的快照；需要当前状态时重新 GET。

每条 blocker 的身份是本 hub 内 `(owner, task, generation, blocker_id)`：

| 字段 | 含义 |
| --- | --- |
| `version` | 固定 1；未知版本拒绝写入 |
| `blocker_id` | 调用方稳定 ID，1–200 位字母/数字及 `_.:-`，首位字母/数字 |
| `scope` | 创建任务的 `task`、账户 `owner`、`repo`、带 backend 的 `ticket_ref`、`generation`、`worker_id` |
| `created_endpoint` | hub 认证的创建节点，不能由请求伪造 |
| `dependency` | 本 hub 的依赖任务，使用与 `scope` 相同的完整字段；不是 GitHub 单号或 URL |
| `dependency_policy` | 默认 `success-required`；只有创建者显式选 `terminal-any` 才授权非成功终态自动撤销 |
| `state` | `active`、`resolved` 或 `revoked`；不是 task outcome |
| `created_at` / `resolved_at` / `revoked_at` | hub 事务时间；后两项仅在对应状态存在 |
| `creation_evidence` / `creation_reason` | 不变的创建证据与原因 |
| `evidence` / `reason` / `event_id` | 最近一次变更的证据、审计原因及 journal 事件 ID |

每代最多保留 64 个 blocker，包括已关闭项；不删除审计或复用同代 ID。
generation 改变后，新投影只包含新代 blocker；旧代仍留在 journal。
跨仓库依赖可以显式声明，且必须完整匹配；两个 repo 的同号单不互相替代。
账户和 hub 边界不能跨越。

## 写入入口与授权

现有 `POST /v1/node/tasks/T<n>` 的 `authority_version: 1` mutation 增加
`kind: "blocker"`。外层保留 `idempotency_key`、`generation`、`expected_worker`，
内层 `blocker` 为：

```json
{
  "version": 1,
  "action": "create",
  "dependency_policy": "success-required",
  "blocker_id": "prerequisite-one",
  "repo": "org/repo",
  "ticket_ref": "gh:org/repo#7",
  "dependency": {
    "task": "T12",
    "owner": "account-principal",
    "repo": "org/dependency",
    "ticket_ref": "gh:org/dependency#7",
    "generation": 2,
    "worker_id": "fleet-uuid/session-uuid"
  },
  "reason": "等待已接受的依赖任务",
  "evidence": "明确声明依赖的证据"
}
```

`action` 另有 `resolve`、`revoke`；每次都携带原依赖完整身份、原策略及新的非空证据和原因。省略策略等于 `success-required`；创建后不能更换。
字段须从权威任务读取，示例不是真实身份。证据最多 8000 字节，原因最多 2000 字节；
不要传凭据、transcript、私有 preview URL 或原始会话 provenance。

同一 `blocker` 对象也可放入现有 `POST /v1/node/tasks/T<n>/reports`。
report 保留原 event ID、owner/worker/generation、ticket 和 parent fencing，
必须是有 `status` 的 progress report，不允许同时声明 outcome、停止或取消确认。
节点上的消费入口（`fleet_task_control.py blocker` / `blockers`，以 `@launch` 绑定构造 report）
随启动证明一起退役（EPIC T497 C8）：节点不再写 blocker；hub 一侧的 blocker 按拍板 6
先改按 ID 解除、跑一个版本再定删。

创建、主动解决和撤销必须来自当前任务 execution owner 所属的已认证节点，
同时比较账户、task、repo、ticket、generation、worker、endpoint。
依赖必须是同账户、已绑定执行 owner 的权威任务，不能依赖自身。
任务已 terminal 或有 cancel intent 时拒绝新 blocker 修改。
事件 key 在同一任务的整个生命周期内不能复用（换代也要使用新 key）。
同事件同 payload 返回原回执；变 payload 冲突；已关闭 blocker 不能换事件再次修改。
旧代 report 保留为 historical，不能修改当前代。

## 外部依赖事件

创建时的 `dependency` 是对该精确代次终态事件的显式授权。
hub 在已有 task mutation/report 提交事务内，按依赖 T 的索引查询 active blocker：

- 已提交 `succeeded` → `resolved`。
- 已提交 `failed`、`cancelled` 或 `refused`：默认保留 `active`，记录失败证据和审计原因；
  只有创建者明确选择 `terminal-any` 才转为 `revoked`。`revoked` 也不能解释为依赖满足。
- 没有匹配的当前 scope、可信证据或明确终态 → 保留 active。

取消请求本身不是取消结果；执行中的取消仍需 C4 的停止确认。历史 report、
另一任务/仓库/账户/代次的结果、inventory 缺席、Stop、runtime TTL 到期和 unknown
都不能触发解除。依赖在注册前完成时，可使用同事务读到的已提交 attempt result，
因此没有事件到达顺序造成的漏解，也没有后台扫描或新轮询。

任务生命周期与 blocker 变更在 PostgreSQL 使用同一账户事务锁，再锁任务行；
SQLite 使用既有单 writer 锁。依赖结果、匹配 blocker 变更和审计事件一起提交。
每次快照更新要求 active CAS 恰好影响一行，否则整个事务回滚。
一个结果可以命中多个明确依赖它的 blocker，但绝不清除其它项。
被阻塞任务若已取消请求、终态或换代，外部事件不再改它。

`fleet_operations` 增加 additive scope 索引列；`task_blocker` 是有界快照，
原 `task_event`/`task_report` 保存 owner 操作，`task_blocker_event` 保存依赖触发审计。
generic operation update 不得改这些行。没有第三套任务存储。

## 只读消费与验证

节点上的只读投影（`fleet_task_control.blocker_projection`）随 EPIC T497 C8 删掉。

CI 的 SQLite/PostgreSQL 共用 `TestTaskBlocker*`、`TestNodeTaskBlockerContract`：
幂等/冲突、精确依赖、跨 scope、旧代 report、取消/终态竞争、独立 writer 与审计保护。
节点一侧的用例（`fleet_task_blockers_test.py`、BREAK-IT `task-blocker-fence`）随 C8 删掉。
夹具证据不等于原生或现场验收。

原生验收须分别用隔离 Claude/Codex 的内核 executable 与 native SID 核验身份，
在实际 ask/approval 期间提交 blocker，再完成依赖；要求 attention 保持，
且 blocker 单独关闭。需保留私有原始记录，公开仅写验证层级及结论。
源码合并、fixture、native、deployed、live 的状态分列记录在 PR/任务验收中；
不因这些测试通过推断已部署，也不替代 C8 的四道退役门。
