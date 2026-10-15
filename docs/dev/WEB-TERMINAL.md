# 网页终端（EPIC #3836）

浏览器里打开**自己的**终端：自己拥有的会话（worker），或个人终端。C1（#3838）是中继这一层：
入口认人、找家、认目标，节点以那个登录开伪终端、接一个分组 tmux 视图。直连（C5）、个人终端常驻（C4）、
页面（C2）、回来不丢位置（C3）都建在它上面。

## 路

```
浏览器 ──wss /v1/term/connect?worker=<worker id> | ?target=personal（同源、已登录）──▶ 入口
入口：人（本人；管理员也只是他自己；以他视角 / 运营门一律 403）· 家（EntryHomeOf）· 目标是他的
入口 ──term_open {relay_id, secret, login}──▶ 家登录的节点（只发给报了 CapTerm 的）
节点 ──wss /v1/node/term?id=…──▶ 入口
入口 ──第一帧 {"grant": "ftg1.…"}──▶ 节点：验过才开终端
节点 ──以该登录（prepCmd）──▶ ccquota term-pty ──▶ 伪终端 ──▶ bin/fleet-term-attach.sh ──▶ fleet-webterm.py connect ──▶ 原生 Fleet 看台
```

- **选择器只有两种**：`target=personal` 或 `worker=<fleet UUID>/<fleet_id>`，二选一。worker 必须出现在家登录上
  那个 fleet 的上报里（`fleet_fleets.workers`）；别人的和不存在的都答 `404 not_yours`。机器、登录、路径、命令
  一个都不从浏览器来。
- **授权**（`control.SignTermGrant`）：入口用家登录节点令牌的哈希签（同对话的 `X-Fleet-Person`），绑定
  人 · 登录 · 这条转发 · 目标，两分钟，`aud=term`。前缀 `ftg1` ≠ 对话的 `fpp1`，`verifyStatement` 先认前缀：
  一张对话声明打不开终端，反之亦然。节点每个转发 id 只认一次（`spentGrants`）。
- **目标**只能是 `personal` 或 `worker:<fleet_id>`（`control.ValidTermTarget`）。`term-pty` 只跑一个固定命令：
  `~/.claude/fleet/bin/fleet-term-attach.sh --view web-<id> --target <目标>`。
- **伪终端是登录自己的**：`term-pty` 以登录身份（`prepCmd`，托管机经 root core 的 exec-as）自己开 PTY，
  stdio 上和节点讲一个小帧协议（`'d'` 字节、`'r'` 尺寸），输出原样回来。stdin 一断就挂断进程组（SIGHUP，3 秒后
  SIGKILL）。环境里给 `TERM=xterm-256color` 和 UTF-8 locale（中文输入、宽字符）。
- **视图**：`<fleet>@view-wt-web-<连接 id>`，经现有 `attach --thin --browser` 加载原生菜单与键表，
  连接前先取得控制权；接上后设 `destroy-unattached on`，退出按捕获的 session id 清自己的 view/registry。
  personal 首次使用可创建无 repo 的 fleet/home，但不启动 agent 或编排；之后复用同一个 home pane。
  `Ctrl+\` 和菜单的切壳动作去这个持久 shell，再按返回原会话；worker 消失拒绝，不回落到别的窗口。
- **locale**：节点读取 `locale -a`，按 `LC_ALL` / `LC_CTYPE` / `LANG` 顺序选已安装的 UTF-8 locale，
  再回退到实际存在的 `C.UTF-8` / `en_US.UTF-8` 或其他 UTF-8 locale。三项统一设置，避免 `LC_ALL=C`
  盖过 UTF-8 LANG；没有可用 UTF-8 时拒绝开 PTY，不假定 macOS 有 `C.UTF-8`。

### C3 接线边界（#4407）

`fleet-webterm.py connect --conn C --target T [--generation N]` 是节点固定脚本的唯一入口。
T 沿用授权的 `personal` 或 `worker:<fleet_id>`；C 是本条连接 id。helper 先 ensure（已有终端结束时
绝不隐式 renew）、检查可选 generation，再在 control 锁内 claim 和建立 view。存活连接续租；
`control take --target T --conn C` 先关闭旧 epoch 的真实 view，再允许新连接 attach；旧 cleanup
只能清自己的 session id，不能释放新 epoch。`status` 的 id/generation 是持久个人 pane 的身份，
不同于 hub hello 的节点链路代，也不同于 C5 的 direct/relay 路径 epoch。

C3 仍需把这些状态/控制映射到已授权的 wire hello、Use here 和恢复流程，传回期望 generation，
并协调原生菜单切换目标后的租约（personal 切到 worker 与直接 worker 入口目前是不同初始租约）。
逐帧输入/resize 与逻辑目标 epoch 的原子校验、页面重连和无重放由 C3 接续；本接线不声称完成这些验收。
原生交互由 `fleet-term-attach-selftest.sh` 的隔离真实 PTY 验证，真实 Chromium 页面和 Safari/OS IME
仍须在部署后另验。

## 帧

| 方向 | 二进制 | 文本（≤1 KiB） |
|---|---|---|
| 浏览器 → 入口 → 节点 | 键入的字节（≤32 KiB） | 只有 `{"t":"resize","cols":1..1000,"rows":1..500}` |
| 节点 → 入口 → 浏览器 | 终端输出 | `{"t":"ready"}`（伪终端起来了，可以开始输入）· `{"t":"exit","code":N}` |
| 入口 → 浏览器 | — | `{"t":"hello","v":1,"term":…,"gen":…,"conn":…,"mode":"relay"}` · `{"t":"error","error":…,"msg":…}` |

别的帧（未知控制、超大、非 JSON）立刻断这条流。`gen` 是节点链路的代（`<端点>.<hello 时刻>`）：节点重连、
pod 重建就变。

## 边界

- 每人同时 2 个（`CCQUOTA_FLEET_TERM_PER_PERSON`）、每分钟 20 个；每登录 8 条（`CCQUOTA_FLEET_TERM_RELAY_MAX`），
  1 MiB/s（`CCQUOTA_FLEET_TERM_RELAY_RATE_BPS`）；节点自己每登录 4 个兜底。
- 两条腿 10 秒一 ping、10 秒不回就断；每 15 秒重认人和家，不对先发 `revoked` 再断；控制链路断了 `closeNode`
  收走所有终端。
- 审计：`fleet_term_sessions` 一行一个终端（人 · 机器 · 登录 · 目标 · 方式 · 开 / 关 · 结局 · 两个方向的字节），
  从不记内容、授权或密钥；拒绝记 `fleet_audit` 的 `term_refused`。
- `GET /v1/term/home` 给页面：`ok` · `offline` · `maintenance` · `unsupported`（节点没报 `CapTerm`：
  「这台机器还不支持」）。`CCQUOTA_FLEET_TERM=0` 让节点不报。没报的节点，其余一个字节不变。
- 与对话共用的只是路（`loginRelayNode` 选链路、`openLoginRelay` 开转发、`dialRelayData` / `readRelayHello`
  回拨），表、名额、限速、授权各是各的：终端关、饱和、发垃圾不打断对话，反之亦然。
- 多副本：人的请求落在不持家登录链路的副本上，整个升级交给持链的那个（`termRelayPeer`）。

BREAK-IT：`term-other-person` · `term-relay-orphan` · `term-view-kills-session`。
测试：`tokenledger/internal/api/term_relay_test.go`、`internal/agent/term_pty_test.go`、
`internal/control/term_relay_test.go`、`bin/fleet-term-attach-selftest.sh`。

## 直连优先的共用传输（C5 #4374）

`extras/browser-transport/attachment.ts` 是两个 Vite 页面共用的连接助手；Go 的
`internal/attachment.Stream` 是终端与对话适配器共用的有序帧接口。C5 提供终端适配器，
C2 接页面；C6 接 Webchat 的请求准入及固定 `chat.sock` 适配器，仍使用原来的对话进程。
在 C6 接入前，`service=chat` 明确拒绝，不绕过 `/v1/chat/*` 的试用、预算及请求限额。

入口为同源 WebSocket `/v1/attachment/connect?service=term&worker=<worker id>`，也可用
`target=personal`。`generation=<上次的代>` 用于恢复；不匹配答 `interrupted`，不跟到重建的 pod。
旧 `/v1/term/connect` 和旧节点能力位保留；新入口要求 `attachment-v1`，不把旧节点说成能直连。

1. hub 认本人、家、目标及维护状态，返回 `config`（目标、节点代、显式 STUN 配置）。
2. 浏览器给 `offer`；完整 SDP ≤24 KiB、候选 ≤32、只准 UDP 的数据通道。无 WebRTC 时给 `relay`。
3. hub 经原 `openLoginRelay` / 节点控制链路发 `attachment_open`；节点回拨
   `/v1/node/attachment`。第一帧的 `fba1` 授权只到节点：人、家、登录、节点、服务、目标、连接、
   代、DTLS SHA-256 指纹、选择 epoch、过期时间缺一不可。验过才建 ICE，协商时不开 PTY。
4. 浏览器原生 WebRTC 与 Pion 交换 `answer`。可靠有序 `fleet.v1` DataChannel 通过 DTLS 校验
   offer 指纹；无 TURN，relay candidate 拒绝。协商超时最多 8 秒，选择原 hub WebSocket 路。
5. hub 在 `select` 时再认一次本人及同一个目标，签 epoch 2。节点先关闭 ICE 才允许 relay
   开目标；direct 必须 DataChannel 已打开。服务发 `ready` 后才接收输入。协商期的数据直接拒绝。
6. direct 的字节只走浏览器与节点；hub 每 5 秒重验授权并续一个 ≤15 秒的租约。维护、撤销、
   换家、目标消失、节点控制链路断开或租约不能续都结束附件。退出登录持久撤销该 cookie 的
   哈希，其他副本持有的连接也在重验时关闭；不保存 cookie 本身。

选择只生效一次；迟到的 direct 成功不能抢回 relay。已就绪的 direct 后来断开，助手只尝试一次
重新授权的 relay：同目标、同代、携带 `previous` 连接。节点先取消并等待旧附件清理，才启动
新适配器；同一个前任只能被替换一次。没有输入队列，不重放不确定是否送达的写入。之后的页面
恢复策略由 C3 负责。这个传输的 epoch 只裁定路径，C4 的逻辑终端控制权仍由页面/服务适配器接入。

帧 ≤32 KiB；单 peer 接收/发送缓冲 ≤256 KiB，读写背压超限关闭该附件。文本仍为终端控制，
二进制保持原始字节；页面显示可用 `utf8Stream()` 保留跨帧 UTF-8 状态。审计 `mode` 为
`direct` 或 `relay`；`bytes_up/down` 是 **hub 转发的数据字节**，direct 必须为 0，不代表终端没有流量。
选中的候选对类型经 `selected.pair` 返回；不记录候选地址、终端字节、授权或密钥。

### 网络与部署验证

hub 的 `CCQUOTA_ATTACHMENT_STUN` 是空白分隔的 `stun:host:port`，最多 4 个，默认空；
没有隐含公共 STUN。空配置仍可尝试本地可达 host 候选，跨 NAT 通常回退。需要 STUN 时由部署者
显式提供其端点，端点会交给浏览器和节点；不支持带凭据端点或 TURN。

Mac 节点保留 SSH 为唯一静态公网入口。ICE 是节点附件临时分配的 UDP socket，不增加 TCP
终端监听，不改防火墙或路由器。个人 ACK pod 使用现有 per-pod/per-login agent 边界及认证
分配的家，不创建每人 LoadBalancer、NodePort、公网 IP 或 SSH 入口。所需策略须由部署者审阅：
pod 到指定 STUN 的 UDP 出站及回包、pod 到浏览器候选地址临时 UDP 端口的 ICE 检查及回包、
SNAT 映射允许反向 ICE。严格/对称 NAT 或 UDP 禁止时保留现有 hub HTTPS/WSS 回退。
本实现不申请或修改任何基础设施规则，也不保证任意 NAT 都能直连。

CI `browser-attachment` 在隔离身份、真实节点适配器和抛弃式 shell 上运行 Chromium：直连、
跨帧中文、ready 前拒绝输入、直连中断后的无重放回退、浏览器策略禁 UDP 后回退、进程与转发表归零。
精确命令：在 `extras/browser-transport` 中 `npm ci && npm run check && npx playwright install chromium`；
在 `tokenledger` 中 `go test -tags browseracceptance -count=1 -v -run '^TestAttachmentChromium$' ./internal/api`。
普通 Go 门另跑 `TestAttachment*` 的授权、重放、租约、候选/帧上限与背压测试。

每次部署另外记录 Mac SSH-only 实际网络、ACK 个人 pod 各自的节点/hub 版本、STUN 配置、
候选对类型、direct/relay、目标/代、hub 字节计数、清理结果及 UDP 禁止时的回退。用可回滚的
浏览器 UDP 策略或专用测试身份验证，不能为测试改 live 防火墙/集群策略。pod 重建必须换代并拒绝
旧授权。CI Chromium 版本写在日志；Safari 版本、日期、真实 OS CJK IME 需人工记录。上述真实
拓扑与 Safari 验证在部署前仍为待验，不能用 CI host 候选对结果声称已覆盖 NAT 或已上线。
