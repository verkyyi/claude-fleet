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
节点 ──以该登录（prepCmd）──▶ ccquota term-pty ──▶ 伪终端 ──▶ bin/fleet-term-attach.sh ──▶ tmux 分组视图
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
- **视图**：`<fleet>@view-web-<转发 id 前 8 位>`，分组会话（同 看台），接上后才设 `destroy-unattached on`，
  退出 / 挂断时按 session id 只 kill 它自己。不起会话、不起 agent、不起编排。

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
