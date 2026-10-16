# 存活 Codex 的观察登记

`bin/fleet_native_observe.py` 补齐已经存在的 legacy 执行的 Hub 观察与本地身份。
它适用于原 SessionStart 的 authority 观察失败、但原私服与 TUI 仍在的情况。
预检和应用均不启动、恢复、重派、退出、打断或给原生会话输入文字，不重放 hook。
现有工作树、未提交文件、原 SID、worker/FID 和 reservation 保留。

## 支持入口

在目标登录运行**当前安装**的代码，使用维护者已经确认的原 PID/SID 和显式 pane。
PID、SID 是待核实的选择器，不是证明。不要从窗口标题或最新 transcript 推断它们。
原始 manifest 和回执包含私有身份、路径与账号元数据，保留在该登录的私有目录，
不放进 issue、PR、提交或公共日志。两种输出都不含凭据。

```sh
umask 077
python3 /path/to/current/bin/fleet_native_observe.py --preflight \
  --socket /path/to/original/tmux.sock --pane %123 \
  --pid 12345 --sid ORIGINAL-UUID > /private/path/preflight.json
# 检查 exit 0 和完整 manifest，再由现场 owner 审阅事实与现场授权。
python3 /path/to/current/bin/fleet_native_observe.py --apply /private/path/preflight.json \
  > /private/path/receipt.json
```

`--preflight` 只读：kernel PID/精确 birth/executable/UID/cwd、pane 后代链、
原 supervisor/launcher/runtime/guardian、唯一 TUI、私有 Unix socket 的 kernel peer、
唯一 loaded root thread/SID/cwd、原账号 scope、现存 reservation。
RPC 只读取元数据，不读取消息或工具正文。原生 phase 和最近 turn 元数据必须稳定；
活工具可以继续执行，但检查期间换 turn/phase 时保留并拒绝。

`--apply` 只接受本登录拥有的 0600 普通文件，按 socket/FID 串行化，再重新取得
完整事实与 manifest 比较。只有原 Hub 记录仍允许时才提交 `recover-observe`；
Hub 的精确确认后，用同一份已验证的原始本地身份快照作为 tmux CAS 条件登记
`@authority_receipt`、`@codex_identity`、`@codex_session_id`。已有 model/transcript
等身份附加字段保留。提交后再次核验原执行与 Hub。

所有 authority HTTP 请求复用 `fleet_ticket.creds` 的整对 URL/token 选择。
调用者只有 URL 时，当前 resolver 重新取得一整对合法来源；不要求现场手动 unset，
也不改变原 native 环境。旧 Hub/proxy 不支持新只读入口时，明确拒绝。

## 权威与账号边界

| 对象 | 支持与拒绝规则 |
|---|---|
| legacy reservation | 必须是原 owner/repo/endpoint/worker 的 `starting` 或同 native 的 `observed`；不 reserve/begin。取消、停止、不同 native 均拒绝。 |
| legacy 历史 | 没有 accepted generation；reserve 时间也不是 begin 顺序。同 worker 存在另一份执行记录，包括已停止记录时，历史多义，拒绝恢复。 |
| accepted task | 已有 `@launch`、`@launch_receipt` 或原 native accepted context 时拒绝。不会因任务登记而补造 generation。 |
| pinned subscription | 原 native subscription 的 profile/account/home，当前只读注册资料，以及已核实 peer 的 `account/read(refreshToken=false)`、原 thread 的 openai provider 一致。不会写 account.reauth 或刷新 token。 |
| local credential proxy | 原 native 的 credential 经已认证 ctl peer UID/tenant 核签名、撤销、原 sid/worker/wrapper、现有 selector/bind 与当前 lease；wrapper 的 kernel lifetime/祖先链另行核实。 |
| central proxy | 原 credential 验签；只使用代理**已经持有**的同 ID 有效续期证明。issuing-node 专用 `/v1/fleet/session-cred/inspect` fresh 检查 endpoint、当前 login→principal、worker、machine、provider、撤销和记录有效期，只读现有 binding。 |

代理证明的是原授权 scope 和已有 selector/bind；代理既有机制可切换物理上游账号，
此入口不能重建没有记录过的“出生时上游账号”。预检到应用之间 scope/bind 变化会拒绝，
不自动追认新账号。没有 mint、renew、选账号、attach、转发请求或修改原配置。
代理配置仅支持标准 launcher 发出的完整 inline provider 表；额外的 dotted、quoted
或上层 provider 覆盖无法证明其有效配置时拒绝，不沿用已被覆盖的旧 endpoint/凭据源。

## 结果与停留状态

| 输出 state | 含义与后续 |
|---|---|
| `retained`，非零退出 | 预检或应用前核验失败；原执行保留。原因区分本地验证、进程、RPC、Hub 认证/传输/响应。未知不能当作进程已死。 |
| `hub-unconfirmed/local-unchanged`，非零退出 | 请求可能已提交但没有精确 ACK；不登记本地身份。保留原 manifest，先核查原 Hub 记录，不开第二 execution。 |
| `hub-confirmed/local-pending`，非零退出 | Hub 已精确确认，但后续核验或本地登记没有完整完成；本地可能部分写入。保留原执行，现场 owner 决定是否在 fresh 检查后重试。 |
| `observed`、`local_registered=true`，退出 0 | 原 kernel→Hub 确认→本地身份已核对。相同请求重放不改变 Hub 事件/时间戳，完整相同本地登记不再次写 option。 |

重试同样进行完整 fresh 核验；phase/turn 已变时旧 manifest 不再适用。
不要建立自动重试循环，预检成功不替代现场授权或现场唯一 owner 的执行控制。

## 旧 hook 与消息各自验收

回执的 `hooks.state` 只报告原固定路径为 `missing`、`paths-present` 或 `unknown`，
`future_turns_verified` 始终是 false。即使路径存在，也没有执行旧 hook 来证明可用。
原旧安装移除后，本入口不重建路径、不改 hook pin、旧 packet、Meter 或退出 helper。
后续 Stop/UserPromptSubmit 等仍可能失败；登记成功不能宣称业务恢复。

`message_delivery` 始终为 unverified。正常发送入口的 `queued`、Hub relay receipt
只能证明对应层接受请求。消费要看**同一 SID** 的原生 userMessage/turn 和已有消息回执，
不能另发 turn/start 来制造证明。保留原 operation/idempotency key；通用 worker_message
有 operation/FID fence，没有 accepted-task generation 字段，不能冒称代际证明。
带 task generation 的既有消息道路继续使用其原有守卫。

## 隔离验证

`bin/run-selftests.sh fleet-native-observe-selftest.sh` 覆盖严格 ACK、fresh 比较、
丢 ACK/本地 pending、真实 socket peer 拒绝、真实隔离 tmux 的三项身份竞态和部分登记。
账号与正常启动回归在 `fleet-account-provider-selftest.sh`、`fleet-codex-session-selftest.sh`；
Hub store/API 测试覆盖原 reservation、认证范围、历史多义与只读 credential inspect。

有真实 Codex 可执行文件时，可单独运行下列无真实账号的原生演练。脚本使用隔离 HOME、
socket、标准 wrapper/launcher/runtime 和真实代理；authority HTTP 与 Responses 上游是
fixture，不能用其结果声称生产 Hub 或真实订阅服务已通过。

```sh
python3 bin/fleet_native_observe_native_test.py --codex /absolute/path/to/codex
python3 bin/fleet_native_observe_native_test.py --codex /absolute/path/to/codex --keep-install
```

第一种删除自己的临时旧安装，验证原活工具不被打断、原身份和 dirty 文件保留、
丢 ACK/部分登记重试，并单独报告消息消费是否取得原生证据；旧 hook 缺失不算已修复。
第二种保留旧安装作正常消息对照：同 SID 的唯一 userMessage/turn 和测试上游收到
预置测试消息才通过。演练只关闭自己创建的 socket 与进程。
