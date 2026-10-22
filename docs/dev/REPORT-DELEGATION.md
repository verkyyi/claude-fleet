# 报告监督委托

监督委托只改变自动报告的 delivery，不改变 worker 的历史 parent、`@origin`、
`@origin_fid`、`@origin_wid`、generation、任务归属或原生会话。默认没有委托。
`fleet-report-parent.sh` 的完成、blocked、failed、Stop/reap 后备入口共用它。
`report` 仍只表示报告已送达或入队，不表示监督者已接受任务。

## 授权与存量作用域

正式入口是 **报告产生机器、同一 fleet 登录**下的
`python3 ~/.claude/fleet/bin/fleet_report_delegation.py`。
这是登录级管理权限（与管理 fleet 配置相同），不是给任意远程 worker 的管理 API。
只能在操作者明确授权后运行；`--authorization` 填可查的授权记录引用，不填凭据。
审计自动记录实际 OS uid/login、时间、授权引用、完整作用域和 grant UUID，不能用参数冒充 actor。
私有目录必须属于此登录、权限 0700，审计文件 0600。

必须先发布并安装本 PR 的 **producer、receiver 和 hub** 三部分，再启用。
旧版本没有委托语义；仅合并 PR 不代表路由上线。没有改任何 release-hold、stable 或 timer。

按当前 inventory 逐个核对完整身份：worker 和 parent、target 都是
`<fleet UUID>/<session UUID>`；不接受短码、窗口号、scratch 名或通配符。
存量清单是显式快照，不自动纳入未来新 worker。未来任务应直接由新监督者派发。
在每个报告产生机器上分别授权其存量 worker；迁移改变 fleet UUID 或 producer 时，
由迁移负责者在新机器读回身份并重新授权后再放行工作，本入口不控制迁移冻结或 quota。

```sh
# 所有值由当前 inventory 和授权记录取得；以下是占位变量。
python3 ~/.claude/fleet/bin/fleet_report_delegation.py grant \
  --parent "$original_parent_worker_id" --target "$supervisor_worker_id" \
  --worker "$existing_worker_id_1" --worker "$existing_worker_id_2" \
  --authorization "$operator_authorization_reference"

# 读回完整有效作用域和审计；resolve 是实际报告路径使用的同一个 reader。
python3 ~/.claude/fleet/bin/fleet_report_delegation.py show
python3 ~/.claude/fleet/bin/fleet_report_delegation.py audit
python3 ~/.claude/fleet/bin/fleet_report_delegation.py resolve \
  --worker "$existing_worker_id_1" --parent "$original_parent_worker_id"
```

没有匹配作用域时 `resolve` 返回 4。损坏的授权记录返回 1，报告拒绝路由，
不会悄悄退回旧 parent。同一 worker、同一 parent 不能重叠授权。
同一 producer 可显式授权下一跳，最多 8 跳；自环、环和投递给报告者自身都拒绝。
完整链在 producer 解析一次，receiver 不再查询或追加委托，所以跨机器不会重复转发成环。
授权引用只随该 worker 的链投递，不携带整个存量 worker 清单。

## 投递、证据与升级

报告 envelope 保留原报告者、原 parent、原 origin 和 grant 链，目标固定为精确身份。
新委托报告在 producer 的 children ledger 以原 parent UUID 归档，保留原来源和
原 origin，避免碰撞已被另一 generation 复用的 key。它不是 supervisor 的子任务。
历史 ledger 不重写；新行带 `report_delegation`，旧 parent 的 batch digest 不再发送它。
已经产生或入队的旧报告不被本授权追溯重定向，也不清队列。

委托报告使用既有 `peer-queue`，cleanup 的既有 drain 重试；跨机继续使用 hub outbox / relay。
暂不可达、没有活窗口、目标已换身份都保持 queued；不会按窗口名找替身，不转给旧 parent、
祖先或人的 reminder，不因 TTL 或 stale 告警唤醒人。目标以同一身份恢复后自动补送。
队列和 hub 都保存报告 ID；同一最新报告重放使用同一个 ID，状态变化后再次回到 blocked
属于新事件。hub 重放和重复 drain 不生成新 ID；receiver 的
持久 receipt 记录成功投递后去重。adapter 成功返回与 receipt 落盘之间的进程崩溃仍是
既有 transport 的不确定窗口，不能声称对任意崩溃实现端到端 exactly-once。

状态读回与证据位置：

```sh
~/.claude/fleet/bin/fleet-peer-queue.sh status -L "$fleet_session"
```

- `$FLEET_CONF_DIR/report-delegation/audit.ndjson`：授权与撤销的追加审计。
- `$FLEET_CONF_DIR/fleets/<session>/delivery.ndjson`：QUEUED / DELIVERED；完整未投递报告在其 `peer-queue/`。
- receiver 的 `$FLEET_CONF_DIR/report-delegation/receipts/`：成功投递的原报告、链和时间；原 children ledger 保持历史归属。
- hub 的 `fleet_relays` 和既有 relay audit：跨机持久队列、路由及回执。

**升级策略：** blocked、failed 和重要完成先交指定监督者处理，不因 tier=loud 就退回旧 parent。
真正需要人决定的事项仍走现有 `ask`；监督者依操作者授权把紧急风险、重要完成主动升级给指定入口。
本委托不改 `ask`，不把普通完成批量变成人工告警。监督者永久失效时必须由授权管理者处理
pending 和后续授权；队列不会自行宣布 accepted、丢弃报告或选择另一个接收者。

## 撤销与回滚

```sh
python3 ~/.claude/fleet/bin/fleet_report_delegation.py revoke \
  --id "$grant_uuid" --authorization "$rollback_authorization_reference"
python3 ~/.claude/fleet/bin/fleet_report_delegation.py show
python3 ~/.claude/fleet/bin/fleet_report_delegation.py resolve \
  --worker "$existing_worker_id_1" --parent "$original_parent_worker_id"
```

撤销后新报告按剩余链或原 parent 投递。已入队报告保留当时授权快照和精确接收者，
撤销不会偷偷改写或删除它；如需换 supervisor，应先处理旧目标的 pending，再撤销并重新 grant。
回滚代码之前须先撤销所有授权并确认 pending 已送达，不能让旧版 queue/receiver 处理新版委托。
不删除审计、队列或 reported stamp。

## 验证

`python3 bin/fleet-report-delegation-selftest.py` 覆盖正式 grant/revoke/resolve、环与
作用域拒绝、真实 report-parent/peer-queue/hub-node 入口、本地/跨机离线恢复、身份更换、
原 provenance、自动完成/失败/blocked/Stop 状态及重放去重。
BREAK-IT `report-delegation-offline` 按名守住同一隔离演练，CI 单独运行专项自测；Go 的
`TestDelegatedReportSurvivesRelayTTL` 验证 hub 保留委托报告、普通报告仍正常过期。
