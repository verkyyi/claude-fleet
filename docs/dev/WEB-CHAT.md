# 浏览器里和会话对话 · 最小版（issue #3567）

一个人一条对话，在浏览器里（手机 Safari 也行）跟 Claude 说话。后端是 **Claude Agent SDK**，
跑在这个人自己的登录上，走 fleet 额度池的凭据代理 —— 和 fleet 会话里的 claude 同一条路。

## 经官网（EPIC #3642）

人从官网 `/chat` 进来；**入口只认人、找家、转发，不跑对话**。对话跑在这个人的家登录上，入口和别的机器都碰不到内容。

### 链路

```
浏览器 /chat/（只带官网的 ccq_sess）
  → 入口 /v1/chat/*（viewerOnly：登录的人，只进自己的）
  → EntryHomeOf(人) = 家机器 · 登录
  → 控制消息 chat_relay_open {relay_id, secret, login}（只发给报了 CapChat 的那个登录）
  → 节点回拨 wss /v1/node/chat-relay，第一帧 X-Fleet-Person（入口用该登录节点令牌的哈希签）
  → 节点验过，以该登录连 $FLEET_CONF_DIR/webchat/chat.sock（目标写死）
  → 对话服务 server.mjs --socket（该登录的登记后台服务）
  → 每一轮 fleet-session-cred.sh mint → 凭据代理 → 池子 · /v1/node/usage
```

转发到节点时 socket 没人听，节点就以本登录跑 `service ensure --name webchat --wait 3` 再拨一次，服务没起就起（D1，#3648）。

### 发起人的四个要求怎么落

| 要求 | 落在哪 |
|---|---|
| 仅限已有账户的人 | `/chat/` 和 `/v1/chat/*` 都挂在 `viewerOnly` 后：没登录 302 / 401，不在名单 403，operator 口令 403；没有家 409 `no_home`，页面引去「我的连接」。没有注册入口（C3 · C4） |
| 受同一限额 | 每一轮走凭据代理，按人计到 `fleet.person_budget`；到顶时代理 403 `person_budget_exceeded`，服务变成一行 `code:"budget"` + `until`，页面置灰到点自己重读；顶栏的额度条读的就是本人 `/v1/me/usage` 的 `limit`，和「我的用量」同一个数（C1 · C4，BREAK-IT `chat-budget-bypass`） |
| 同一个 TOKEN | 浏览器只带官网的 `ccq_sess`，不另发 cookie、不要登录链接；对话里的 `claude` 拿的是这一轮 mint 的会话凭据（`fcp1.…`），池子里的号由代理挑，和 `fleet-claude.sh` 一样 |
| 后台跑在这个人的家登录下 | 入口按人找家（`EntryHomeOf`），只给那个登录开转发；节点只在 `X-Fleet-Person` 验过才以该登录连它自己 0700 目录里的 0600 socket；服务是该登录的登记后台服务，家换了登录跟着搬（C1 · C2 · C5，BREAK-IT `chat-relay-wrong-person` · `chat-socket-other-login` · `chat-home-moved`） |

### 已定（发起人确认）

- **D1** 按需起停：第一次打开 `/chat` 经 `service_control ensure` 登记并启动，空闲 2 小时退出 75（守护记 `idle`、不重起）。
- **D2** 家机器连不上（离线 / 维护中 / 转发拨不通）：答 503 `home_down`，页面说「你的机器现在连不上」+「再试一次」，**不**在别的机器开新对话。
- **D3** 本机直连（127.0.0.1 + 一次性链接）保留作开发 / 排障，**默认关**：`FLEET_WEBCHAT_LOCAL=1` 才开，不设时 `fleet-webchat.sh start|link|stop` 退 2，`server.mjs` 不带 `--socket` 不起。
- **D4** 页面地址 `/chat`，官网菜单「对话」，每个角色都有。
- **D5** 管理员也只能进自己的：入口只给登录的本人签 `X-Fleet-Person`，`?principal=` 点名别人答 403 `not_yours`，审计只记开 / 拒，不记内容。

各段细节见下面「按需起停」（C5）、「节点上的转发」（C2）、「入口的路由」（C3）、「官网上的 `/chat`」（C4）。

## 用

网页打开会话时，若会话门还在探测或暂时连不上，输入框显示「正在连接会话，可以先写下要说的话…」。可以先写草稿，确认会话可写后自动允许发送；不用重建会话。只有旧版会话或只读访问才显示只读，探测失败会继续重试。

托管安装的 Codex 会话使用发行树固定的 CLI（`tools/bin/codex`），私有 app-server 与终端客户端保持同一版本；不会被 PATH 前面的旧版 npm/Homebrew CLI 覆盖。旧版本已启动的会话仍按真实能力只读，正常停放后可沿原会话接回到新版，记录保留。

对话服务是这个登录的**登记后台服务**（docs/dev/MANAGED-NODE.md §10），只听一个 unix socket
`$FLEET_CONF_DIR/webchat/chat.sock`（socket 0600，目录 0700）——不开任何 TCP 端口，不发 cookie、
不要登录链接、不写 `admin.token`。能连上这个 socket 的只有本登录；到达它的是节点程序的转发
（EPIC #3642 C2：入口认人、找家、经控制链路转发，`X-Fleet-Person` 由节点验签，这里只记进日志）。

```sh
bin/fleet-webchat.sh enable           # fleet service add webchat --path <状态目录> -- fleet-webchat.sh serve
bin/fleet-webchat.sh serve            # 服务跑的就是它：前台、只听 socket（第一次装好锁定版本的 Agent SDK）
bin/fleet-webchat.sh status           # on · socket … · pid，或 off
bin/fleet-webchat.sh disable          # fleet service rm webchat
bin/fleet-webchat.sh ensure           # 按需：没登记就登记、停着 / 空闲就起，等 socket 的 /healthz（3 次）
bin/fleet-webchat.sh move --to <登录>  # 家换了登录：fleet service move webchat --to <登录>
```

### 按需起停，家搬了跟着走（#3647，EPIC #3642 C5）

- **按需**（D1）：人打开 `/chat`、转发到了节点却连不上 socket 时（服务没起过、停着或空闲退了），节点的转发（`chatSockOrEnsure`，#3648）用固定的命令跑整机守护的
  `fleet-node-supervisor.py service ensure --login <这个人的家登录> --name webchat --wait 3`（`service_control`
  的 `ensure`，只认 `webchat`，入口给的是名字、不是命令）：没登记就按家目录登记
  （`~/.claude/fleet/bin/fleet-webchat.sh serve`，`paths[]` 是 `~/.config/claude-fleet/webchat`），停着或空闲就起，
  然后等 socket 上的 `/healthz`，每次 15 秒（`FLEET_NODE_ENSURE_SECS`），最多 3 次，两次之间重起一次；成功了再拨一次 socket。
  只有整机节点程序能 ensure（登记表是 root 的），普通节点程序只拨一次。BREAK-IT `chat-first-open-cold`。
  页面在这期间先显示骨架屏（C4）。
- **空闲退出**：没有在跑的一轮、没有页面连着、最后一次动静过去 `FLEET_WEBCHAT_IDLE_SECS`（默认 7200，0 = 不退）
  之后，服务自己退出、**退出码 75**。守护认这个码：记 `idle`（`fleet ls --services` 里「空闲·打开再起」），
  不重起、不告警，登记保留，直到条目被改写（`service start` / `service ensure`）。
- **跟人走**：`service move` 先停掉旧的，再把 `paths[]`（状态目录）搬到新家目录。Claude Code 的记录在
  `~/.claude/projects/` 里、不在 `paths[]` 里，所以服务每轮结束、每次退出都把整条 chain 的记录抄进状态目录的
  `transcripts/`；在另一个家目录下起来时（`conversation.json` 记着上次的 `home`），把它们放回自己的
  projects 目录、cwd（记录里的也一起）改成新家，记一行 `home_moved`。新家上打开 `/chat` 还是同一条对话，
  旧登录下不留服务。BREAK-IT `chat-home-moved`。

### 节点上的转发（#3644，EPIC #3642 C2）

入口不跑对话，只把人的网页经节点已连着的控制链路转到他家登录的 socket，形状和 SSH 转发（#1413）一样：

1. 入口发控制消息 `chat_relay_open {relay_id, secret, login}`，只发给报了能力位 `CapChat` 的那个登录的
   节点程序（或它在整机连接上的车道）；没报就不发，入口答 `NO_CHAT`，连不上答 `NODE_OFFLINE`。
2. 节点回拨 `wss /v1/node/chat-relay?id=…`（带 `X-Relay-Secret`，同 SSH 转发的门 `attachRelayData`）。
3. 入口在这条流上发第一帧 `{"person": "fpp1.…"}` —— `X-Fleet-Person`：人 · 家登录 · 这条转发的 id ·
   两分钟过期，HMAC-SHA256，钥匙是该登录节点令牌的哈希（入口存着、节点自己算得出；同 worker assertion，#1810）。
4. 节点验过（签名、登录、转发 id、时间）才以该登录连 `$FLEET_CONF_DIR/webchat/chat.sock`：
   普通节点程序本身就是这个登录，直接连；整机节点程序以该登录跑 `ccquota chat-pipe`（`prepCmd`，座位上经核心的
   exec-as），连上先回一个就绪字节再双向拷贝。验不过就断开（policy violation），socket 一个字节都收不到；
   给别的登录的 open 根本不回拨。

目标写死：`chat_relay_open` 只有上面三个字段，`ccquota chat-pipe` 不收任何参数。每个登录同时最多 8 条
（`CCQUOTA_FLEET_CHAT_RELAY_MAX`），合计 1 MiB/s（`CCQUOTA_FLEET_CHAT_RELAY_RATE_BPS`，负数不限）；节点自己也最多接 8 条。
`CCQUOTA_FLEET_CHAT=0` 让节点不报 `CapChat`。入口那半边给 C3 用的是 `dialChatRelay(ctx, 人, 机器, 登录)`，
返回一条 `net.Conn`。BREAK-IT `chat-relay-wrong-person`（Go 测试：`tokenledger/hub/api/chat_relay_test.go`）。

入口跑多副本时（#3847，照 SSH 转发的 #2151）：人的 `/v1/chat/*`（含 `home`）落在不持该登录 CapChat 链的副本上，
整个请求连同副本令牌交给持链副本（`chatRelayPeer`），由它认人、开转发、审计，不再二跳；节点的回拨落在没开这条
转发的副本上，在**验签之前**按请求自称的身份（FleetSig keyid 或 bearer，`claimedEndpoint`）转给持链副本——签名的
nonce 只在真正处理它的副本上花一次。单入口逐字节不变。BREAK-IT `chat-relay-replica-hop`

**对话只有一份，记录在家里**（Y393）：入口数据库里那份按人加密的副本（`cached=1`）只在页面第一次读、家还没答时上屏，
家答过一次后再晚到的副本一律丢掉（`homeSeen`）；副本按「家回答的时刻」落库，`updated_at` 只进不退，两个副本上乱序
结束的两次读留下的是新的那份。同一人开几个浏览器看的是同一份：一边发的消息只流给发的那边，另一边聚焦即重读家、
在屏时每 30 s 自己重读一次。BREAK-IT `chat-copy-order`。
（`tokenledger/hub/api/chat_relay_replica_test.go`）。

### 入口的路由（#3645，EPIC #3642 C3）

页面只跟入口说话：`/v1/chat/conversation`（GET）· `/v1/chat/turn` · `/v1/chat/stop` · `/v1/chat/answer`（POST），
各自转到对话服务的 `/api/<同名>`（`tokenledger/hub/api/fleet_chat.go`）。

1. **认人**：挂在 `viewerOnly` 后，只认登录的人——普通用户或管理员，**各自只进自己的**（D5）；operator 口令
   答 403 `operator`，请求里点名别人（`?principal=`）答 403 `not_yours`；没登录 401，不在名单 403。
2. **找家**：`EntryHomeOf(人)` → 家机器 + 登录；没有家 409 `no_home`；家在维护中、或连不上（转发拨不通）
   503 `home_down` —— **不**改派别的机器（D2）。
3. **转发**：`httputil.ReverseProxy` 加一个只会拨 C2 `dialChatRelay(人, 机器, 登录)` 的 Transport，
   `FlushInterval: -1`，NDJSON 一行一行到页面。浏览器的头只放过 `Content-Type` · `Accept` ·
   `X-Fleet-Webchat`（cookie 一律不带过去），`X-Fleet-Person` 由入口按登录的人重写（只记日志；真凭据是 C2
   第一帧里的签名声明）。POST 不带 `X-Fleet-Webchat: 1` 就 403。
4. **上限**：每人同时最多 4 个请求（`CCQUOTA_FLEET_CHAT_PER_PERSON`），每分钟最多开 60 条转发
   （`CCQUOTA_FLEET_CHAT_PER_MINUTE`），超了 429；负数不限。
5. **审计**：每次开转发一行 `fleet_audit` `chat_relay`（`OPENED <路由> <机器>/<登录>`），每次拒绝一行
   `chat_refused`（`<code> <路由>`）——从不记内容。

### 本机直连（开发 / 排障用，默认关）

原来的 127.0.0.1 + 一次性链接模式还在，但**默认关**（#3642 D3）：`FLEET_WEBCHAT_LOCAL=1` 才能用下面几条，
不设时它们退 2，`server.mjs` 不带 `--socket` 也不起。

```sh
export FLEET_WEBCHAT_LOCAL=1
bin/fleet-webchat.sh start            # 第一次会把锁定版本的 Agent SDK 装进 $FLEET_CONF_DIR/webchat/deps
bin/fleet-webchat.sh link             # 一次性登录链接（10 分钟），经 fleet-open 开到你自己电脑的浏览器
bin/fleet-webchat.sh link --tailnet   # 给手机：https://<本机 tailnet 名>:18961/login?c=…（只在 tailnet 里能开）
bin/fleet-webchat.sh stop
```

`--tailnet` 需要 `tailscale serve`。这个登录不是 tailscale 的 operator 时，由管理员跑一次
`sudo tailscale serve --bg --https=18961 http://127.0.0.1:18961`，路由会一直留着，之后 `link --tailnet` 直接用它。

## 页面

- 打开就是那一条对话，往上翻是历史；没有会话列表，不能新开或切换。
- 回复流式显示；每个工具步骤折叠成一行，点开看结果；`AskUserQuestion` 显示成按钮，
  等你回答的那一步自己展开。
- **权限模式与 fleet 的 CLI 会话一样是 `bypassPermissions`**（issue #4031，`lib.mjs` 的 `PERMISSIONS`）：
  改文件、跑命令不再逐个等你点「允许」。护栏不变：SDK 读这个登录的设置（`settingSources`
  user · project · local），fleet 的 PreToolUse 守卫（bash-guard、base-readonly-guard 等）照样跑，
  守卫拒的命令在 bypass 下也被拒，拒绝理由作为工具结果回到对话里。`AskUserQuestion` 不是权限批准，
  Claude Code 在 bypass 下仍把它交给 `canUseTool`，所以照旧出选项卡；允许·拒绝卡那条路留着，
  SDK 再交来别的工具时仍走它。
- 模型下拉只有白名单：Sonnet 5.5（默认）· Opus 5.5 · Haiku 5.5。白名单是 `extras/web-chat/lib.mjs` 的 `MODELS`，
  由服务端校验，名单外的请求返回 400。
- 停止键停掉正在跑的这一轮。页面关掉或断线不会停掉这一轮，重新打开会接着显示，待答的按钮还在。

## 页面怎么做的（issue #3637）

样子和官网 v2 是一套：配色、字体（Bricolage Grotesque / IBM Plex Sans / IBM Plex Mono，中文落到苹方）、
圆角和 LOGO（一小一大两枚箭头）都取自全站共用的主题包 `extras/fleet-theme/`（issue #3924：官网、对话页、
控制台都从它取，`bin/fleet-theme-selftest.sh` 守着），`extras/web-chat/ui/src/theme.css` 只 `@import` 它，
颜色已在包里映射成 shadcn/ui 的标准变量。字体是包里 `fonts/` 的拉丁子集，打进 dist。官网只有深色；
浅色是同一族颜色铺在纸色上，跟随系统切换（`prefers-color-scheme`，不用脚本）。

界面全是现成组件：React + **shadcn/ui**（Radix + Tailwind）+ **assistant-ui**。

| 部分 | 组件 |
|---|---|
| 消息列表、流式文本、输入框、发送 / 停止键、回到底部 | assistant-ui `Thread`（`thread.aui.tsx`） |
| Markdown、代码块 | assistant-ui `MarkdownText` |
| 工具步骤折叠、结果 | assistant-ui `ToolFallback` + `ToolGroup` |
| 选项按钮（`AskUserQuestion`）、权限确认 | `ToolFallback` 的审批界面：`approval.display = "questions"` / 允许·拒绝 |
| 模型下拉 | assistant-ui `ModelSelector`（shadcn Popover + Command） |
| 按钮、提示、弹层 | shadcn/ui `Button` `Tooltip` `Popover` `Command` `Dialog` |

这些组件是用官方 CLI（`npx shadcn add …`、`npx assistant-ui add thread model-selector`）拷进
`src/components/` 的源码 —— shadcn 的用法就是这样。拷进来之后只改了：文案换成中文；`Thread` 多两个插槽
（输入框左边放模型下拉、下面放「终端里接着用」一行）；有待答的工具组自己展开；没有重试能力时不显示重试键；
`MarkdownText` 关掉逐字显现（`smooth={false}`：它和「等你确认」那一步展开时会赛跑，偶尔把正文停在半截；
文字本来就是一段段流进来的）。**没有自己写的新组件。**

`src/chat.ts` 是唯一的接线：把服务端原有的 NDJSON（`/api/conversation`、`/api/turn`、`/api/stop`、
`/api/answer`）换成 assistant-ui 的 external store。协议只多了一个字段：`ask` 带上它卡住的那一步的
`id`（SDK 给 `canUseTool` 的 `toolUseID`），页面把按钮挂在那一步上。

### 构建

产物 `extras/web-chat/ui/dist/` 提交在仓库里，`server.mjs` 直接提供它 —— 机器上不用构建，
页面运行时只从本服务取文件（`Content-Security-Policy` 只许同源；字体也打在包里，国内能打开）。
改了 `ui/` 里的东西就重新构建、把 `dist/` 一起提交：

```sh
cd extras/web-chat/ui
npm ci            # 依赖全部锁定版本（package.json 写死版本号 + package-lock.json）
npm run build     # tsc + vite → dist/
npm run dev       # 本地调：vite 在 127.0.0.1，/api 转给 127.0.0.1:18961
```

CI 的 `web-chat-ui` 用同一个锁文件重新构建，`dist/` 和提交的不一样就红；也检查 `dist/` 里没有 CDN。

### 官网上的 `/chat`（#3646，EPIC #3642 C4）

> **搬到了 `/app`（#3926，EPIC #3923 C3），官网版拆了（#3939，C16）**：对话是控制台 `extras/web-console` 的首页——同一套界面（`src/app/chat/chat.ts` · `src/app/pages/chat.tsx`），接口仍是 `/v1/chat/*`，服务与中继不动。`/chat/` 和 `/chat` 只剩一跳 301 到 `/app`（带 query，`consolePages`，永久保留）；`/chat/assets/*`、`npm run build:site` 和 `bin/web-chat-pack.sh` 随旧控制台一起删了。本机服务那份（`dist/`）照旧。

- **家**：`GET /v1/chat/home` 入口自己答，不转发：`{machine, login, state}`，state 是 `ok` · `offline`
  （那个登录没连着）· `maintenance` · `old_agent`（连着但没有对话转发）；没家 200 `state: no_home` + `why`
  （J091：页头每次打开都问，不算报错；挡页面的是对话自己的 409 `no_home`）。`?cached=1` 没副本也是 200
  `{items: [], mirror: null}`；`/v1/try/state` 试用关着答 200 `{state: "none"}`，页面只有试用身份才问。
- **额度**：小条读本人的 `fleet.person_budget`（`/v1/me/usage` 的 `limit`，剩得最少的那个窗口；没设限额
  就不画）—— `/v1/me/quota` 是订阅池的、只给管理员，不是这个人的额度。用完（这里说用完，或者服务
  回了 `{t:"error", code:"budget"}` / 对话里的 `budget.blocked`）：输入框上方一条「这周的额度用完了，
  <时间> 恢复」，输入框置灰（assistant-ui 的 `isDisabled`），到点自己重读。
- **页面态**：对话读不到时整页换成一句话 + 一个动作 —— 没家「去「我的连接」」、家连不上「再试一次」
  （不换机器，D2）、operator 口令「用自己的账号登录」；会话过期（401）回 `/app/signin`。

## 一条对话怎么一直连着

- 「这个人 → 当前 session id」存在 `$FLEET_CONF_DIR/webchat/conversation.json`。每一轮都 resume 它，
  服务重启或断线后也是同一条。
- 每轮结束后记下上下文用量；到窗口的 `FLEET_WEBCHAT_COMPACT_AT`（默认 0.8）时，在两轮之间后台跑一次
  Claude Code 自带的 `/compact`。下一轮会等它跑完。
- `/compact` 失败，或者某一轮报「上下文太长」，就**接力**：新开一个 session，把旧 session 的结尾带进第一句里
  （包在 `<fleet-webchat-relay>` 里，页面上不显示），旧 id 记进 `chain`。页面把整条 chain 的记录连起来显示。
- 这些都是 Claude Code 自己的记录（`~/.claude/projects/<目录>/<id>.jsonl`）。在终端里用
  `cd <目录> && claude --resume <id>` 可以读到、接着用：本机页面底部写着这条命令，官网 `/chat` 收在头像菜单里。

## 两个助手：Claude Code 与 Codex（R9A2，issue #4370 B）

页面顶部「Claude Code ｜ Codex」切换，每个助手各一段持续对话，同一个家、同一本额度账。家机器这一半是
`extras/web-chat/codex.mjs`（`server.mjs` 只多一个路由分支）：

- **怎么区分**：请求带 `?provider=codex` 就是 Codex 那一段；不带（或 `claude`）就是 Claude，和以前一字不差。
  别的值 400；这台机器没有 codex（`fleet-webchat.sh` 的 `codex_bin`，传进 `FLEET_WEBCHAT_CODEX_BIN`）时
  `?provider=codex` 一律 404，Claude 的 `/api/conversation` 也不带 `providers` / `others`——页面据此不显示切换排。
- **跑在哪**：`codex app-server`（stdio 上的 JSON-RPC）。第一轮（或页面第一次读 Codex 那一段、要模型列表）才起，
  最后一轮结束后 `FLEET_WEBCHAT_WARM_SECS`（600 s）空闲就关；服务的 2 小时空闲退出把它也算上。不新增常驻进程。
- **凭据**：每次起 app-server 时 `fleet-session-cred.sh mint --provider codex`，再 `codex-home` 一个不含凭据的
  `CODEX_HOME`，`model_provider="fleet"` 指向代理的 `/codex`（`env_key=FLEET_CODEX_SESSION_CRED`）——与
  `bin/fleet-codex.sh` 同一条路；凭据只在子进程环境里，app-server 关时 revoke。代理不在（rc 3/4）就用这个登录自己的 Codex。
- **批准与提问**：`sandbox=workspace-write` + `approval_policy=on-request`——家目录里放手做，要出去（联网、写家目录以外）
  才问（发起人在设计页定的）。`item/commandExecution/requestApproval` · `item/fileChange/requestApproval` ·
  `item/permissions/requestApproval` → `{t:"ask", kind:"permission", id:<item id>}`；`item/tool/requestUserInput` →
  `kind:"question"`，答案按问题的 id 回填。允许 = `accept`，拒绝 = `decline`（不给 decline 时 `cancel`）；
  `ASK_TIMEOUT` 没人点按拒绝。
- **流**：与 Claude 一样的词：`agentMessage` 增量 → `text`；`commandExecution` → `Shell · <命令>`，`fileChange` → `Edit · <路径>`，
  MCP / 网页搜索各一步；`imageView`（view_image）、`imageGeneration`、MCP 结果里的图 → `image`（存进 `media/`）；
  `page_target` / `show_page` 是 thread 开始时给的 dynamic tools（`initialize` 打开 `experimentalApi`），`show_page` → `page` 卡片；
  `turn/completed` → `done` / `stopped` / `error`。停止键 = `turn/interrupt`。
- **额度**：代理的 403 `person_budget_exceeded` 在 Codex 那里是 `error` 通知 / `turn/completed` 的 `error.message`，
  交给同一个 `budgetRefusal` → 一行 `{t:"error", code:"budget"}`，写同一个 `budget.json`：两边一起显示「额度用完」。
- **对话与历史**：`conversation-codex.json`（`thread` · `cwd` · `put_away` · `last` · `model`）；每一轮页面看到的步骤
  追加进 `codex/<thread>.ndjson`（0600，随 `service move` 一起搬），读回就读它。Codex 自己的记录照常在
  `~/.codex/sessions/**/rollout-*-<thread>.jsonl`：终端里 `cd <cwd> && codex resume <thread>` 接得上。
  重启服务后下一轮 `thread/resume` 同一个 thread。模型列表是 app-server 的 `model/list`（缓存在 `codex-models.json`），
  默认是它标的默认——跟家机器的 Codex 设置走。
- **新对话**：`POST /api/new[?provider=codex]` 只动那一边：Codex 的 thread、Claude 的 session（连同 chain）记进
  `put_away`（留档，不删），下一轮新开；另一边一字不动。正在回复时 409。
- **另一边的状态**：每一边的 `/api/conversation` 带 `last`（最后一轮的号）和 `others.<另一边>` `{busy, last}`，
  页面据此在另一边的标签上亮点（在跑：跳动；有没看过的回复：静止）。

- **入口与页面**（R9A2 ②）：入口只把 `provider=codex` 这一个参数带给家（别的值 400、不转），`POST /v1/chat/new` 是一条路由；
  入口旁的对话副本按助手各存一份（`hub_chat_mirrors` 的 `pid` / `pid#codex` 两行，#5171 以家为准的新旧规则按行算，
  关掉开关两份都删）。页面（`extras/web-console` 的对话页）在对话上方一排：两个标签、「在终端里继续」、「新对话」；
  家没说 `providers` 含 codex（旧家、或没装 codex）就不显示这一排。

### 接口约定（给「在终端里继续」与两边互斥）

- 会话号与目录：`GET /api/conversation[?provider=codex]` 的 `session`（Claude 的 session id / Codex 的 thread id）和 `cwd`。
  终端里接上：Claude `cd <cwd> && claude --resume <session>`，Codex `cd <cwd> && codex resume <session>`。
- 网页上的「在终端里继续」：`/app/s/shell?view=term&continue=claude|codex`——个人终端从家读这一边的 `session` / `cwd` / `busy`（不从地址里拿），
  在跑就不接；否则开 看台 的 shell（⌃\）敲 `cd '<cwd>' && fleet run claude --resume <session>`（Codex：`fleet run codex resume <session>`）。
- 正在跑：同一响应的 `busy`（及 `turn`）；`busy` 为真时不要在别处接着写这一段。这一版的锁只在服务进程里（`live`），
  终端那一侧的锁由另一个任务接上。

### 终端和网页接着聊（T810）

同一段对话在终端会话和网页之间来回接力，同一时刻只一边在答。

- **交给网页**：⌘P 选中会话 → Tab →「在 WebChat 里继续」（`fleet-webchat.sh continue fid:<会话>` 同一条路，
  `bin/fleet-webchat-handoff.sh to-web`）。两边都不在答才走：家机器服务的 `POST /api/adopt`（只走 socket，入口不转）
  接管这段会话——按会话号在 `~/.claude/projects/*/<id>.jsonl` 找到记录和它的目录，原来那段对话按「新对话」的规则
  收起留档（`conversation.json` 的 `put_away`）；记录写成 webchat 拿着；窗口里的 agent 用 fleet 自己的 `/exit` 停下，停在结束页
  「已在 WebChat 里继续 · ↵ 拿回终端」（`@handoff_web 1`，回收器不收它）；网页在操作者此刻的设备上打开。
- **谁拿着**：`$FLEET_CONF_DIR/convo-lock/<agent>-<sid>.json`（`{holder: terminal|webchat, window_fid, label, machine}`），
  只经 `bin/fleet-convo-lock.py` 写。「在答」不存，每次现看：终端 = 窗口的 `fleet_reap_state`，网页 = socket 的
  `GET /api/state`。没有这份记录 = 从没交接过，一切照旧。
- **终端拿着时**：`/api/conversation` 多一个 `owner {where: terminal, busy, label, machine}`，页面输入框灰、上方一条
  「正在终端里回答…」或「这段对话在终端里 · 在这里继续」，每 3 秒跟着读；`/api/turn` 409 `code: terminal`。
  「在这里继续」= `/v1/chat/take` → `/api/take` → `fleet-webchat-handoff.sh to-webchat-take`：终端在答就 409
  `terminal_busy`，空闲就停下它、记录改成 webchat。
- **拿回终端**：结束页 ↵ → `to-terminal`：网页在答就原地一行「WebChat 正在回答…，答完再按 ↵」，否则记录改成 terminal、
  服务关掉它的热进程（`/api/release`），再按原样续同一个会话号——网页上说的几轮都在。
- Codex（R9A2 接上）：`/api/adopt` 的 `agent:"codex"` 把 Codex 的 thread 接成网页 Codex 一侧的对话（旧的那段收起留档，
  目录取 rollout 的 `session_meta.cwd`，历史读 Codex 自己的 rollout，终端里说的几轮也在）；锁记录同一个
  `convo-lock/codex-<thread>.json`；`/api/state` · `/api/release` · `/api/take` 带 `?provider=codex` 就是 Codex 一侧的。
  handoff 一侧默认放行 Codex，`FLEET_WEBCHAT_CODEX=0` 关掉；这台机器没有 codex 时 adopt 回 409 `no_codex`。
- 测试：`bin/fleet-webchat-handoff-selftest.sh`（隔离 tmux socket + 桩 agent + 桩 WebChat）、`fleet-webchat-selftest.sh --only=handoff`。

### 终端里的会话，网页里只读看（F481，EPIC GR5E C5）

会话工作区（`/app/s/<编号>?view=chat`）的「对话」看法：一个跑在终端里的会话，网页只读实时看它的记录——
你说的、它答的、工具步骤，上方「正在终端里回答…」；发送框关着，要说话到终端里，或者接管（下一节）。

- **页面**：`GET /v1/chat/view?worker=<worker id>`（`extras/web-console/src/app/chat/view.ts`）。浏览器只报
  worker id，从不报机器、登录或会话号。打开时三层先后（YP39，与 KSQG 同一套 `chat/local.ts`）：本机 IndexedDB
  里这个会话上次的记录（一侧一个会话：`view:<worker id>`；只读票据、以他的视角看不读不写）→ 入口副本
  `?cached=1` → 那台机器的流，它的答案总是替换前两层；前两层在屏上时顶上一行「本机记录 / 上次的记录 · 同步中…」。
  首帧画出的时刻打点 `view:first:<layer>` / `window.__fleetViewFirst`（从进会话算）。
- **入口**（`tokenledger/hub/api/chat_view.go`）：谁 = `termPerson`（本人，管理员也只看自己的；共用口令、只读预览都拒；
  只读控制台票据可以只读看，见 FLEET-HUB.md）；会话是不是你的 = 终端的同一个 `termTarget`（家登录或你自己的另一个
  在线登录上报的 worker，否则一律 404 `not_yours`——别人的和不存在的同一个答案）。窗口身份取 worker 行的
  `fleet_id`，没有就取 `identity`（清单里一直是这一项——YP39 之前带编号的 scratch-N / issue-N 会话全被 404），再没有才取
  编号后半段。然后 `dialChatRelay` 到会话所在的那个登录，转成 `/api/view?fid=<窗口的 @fleet_id>`，带上页面的
  `at` / `s` / `before`。那台机器的 agent 没有 chat relay = 409 `old_agent`；维护中 / 连不上 = 503 `home_down`。每人同时
  最多 3 个这样的流。流的第一帧（新读的那一段）按对话副本的规则（只文字 + 每步一行，不存工具输出）按人密封存一份
  （`hub_chat_mirrors` 行 `<person>#view:<worker id>`，90 天无读即删，「我的」里关掉对话副本的开关一并删）。
- **会话所在机器的服务**（`server.mjs viewStream`）：`fleet-webchat-handoff.sh view-of fid:<id>` 说窗口跑的哪个 agent、
  哪段会话、在不在答（约 1 s）；上次的答案 10 分钟内直接用、后台立刻再问（`viewKnown`）。记录是 Claude Code 的
  transcript（`findTranscript`：所有项目目录同时 stat，cwd 只读文件头）或 Codex 的 rollout，路径记在 `viewFiles`。
  第一帧 `{t:"items", replace:true, items, at, older, session}`：从文件尾倒读到够最近 200 条（`FLEET_WEBCHAT_VIEW_FIRST`），
  整行为界；`at` = 读到的字节，`older` = 这一段开头的字节（0 = 没有更早的）。之后 `{t:"items", items, at}` 只发新增。
  工具输出在网页里只带前 1500 字（终端里全有）。页面掉线、切后台回来带 `?at=<字节>&s=<会话>`，一条不重；换了会话
  （/clear、resume）= `{t:"reset"}` 再从尾读；窗口关了 = `{t:"gone"}`。`?before=<字节>` 回 JSON 的再早一页（assistant-ui
  自带的「更早的消息」）。轮询：文件 0.5 s、窗口状态 2 s（`FLEET_WEBCHAT_VIEW_POLL_MS` / `FLEET_WEBCHAT_VIEW_STATE_MS`）。
- **图片和文件**：会话记录里的图片、文件链接的编号是会话所在那台机器的服务发的，页面取它们时带 `&worker=<id>`：
  `/v1/chat/file?ref=…&worker=…` 按同一个 `termTarget` 送到那台机器（不带 worker 的照旧去家）。
- 老服务没有 `/api/view`：页面收到 404 没有 code，说「这台机器的网页对话服务还旧」一句话。
- 测试：`fleet-webchat-selftest.mjs --only=view`、`fleet-webchat-handoff-selftest.sh` 1b、e2e `TestChatView*` /
  `TestChatFileOfSession`、`console_ticket_test.go`、`extras/web-console/test/session-view.mjs` / `chat-media.mjs`。

### 接管与交回：同一时刻只有一边在说（VV8F，EPIC GR5E C6）

会话工作区的「对话」看法里，只读跟着的终端会话可以**接管**到网页里说，说完**交回终端**。谁拿着只看 T810 的锁记录
（`convo-lock/<agent>-<sid>.json` 的 `holder`），它随只读流的 `{t:"state"}.holder` 推到页面：`webchat` = 网页在说、终端停在结束页只读；
别的 = 终端拿着、网页只读。

- **页面**（`extras/web-console/src/app/chat/handover.ts`、`pages/chat.tsx` 的 `TakeOver` / `HeldChat`）：只读条上「接管」→
  确认框（手机从底部升起，带安全区）→ 接管成功即显示「已接管 · 在这里说，终端只读」，对话就是网页那一边（Claude Code / Codex 按会话的 agent）
  的对话——WebChat 已把这段会话接成它的对话，`useFleetChat` 照常可写。条上「交回终端」。终端在答时按钮是「等它说完」、不可点；
  网页在答时「交回终端」同样等这一轮。自己刚接管 / 交回的结果先信（≤6 s），之后以流里的 holder 为准。只读预览（view-as）不显示接管。
- **入口**（`tokenledger/hub/api/chat_worker.go`，原 `chat_take.go`）：`POST /v1/chat/takeover?worker=<id>` · `POST /v1/chat/giveback?worker=<id>`，要
  `X-Fleet-Webchat: 1`；谁 = `termPerson`，会话是不是你的 = `termTarget`，还必须在**家登录**上（网页的对话只在家里，别的登录上的会话只能看，
  409 `not_home`）。转给家的 `/api/takeover|giveback`，body 由入口写 `{"fid": <窗口>}`——浏览器只报 worker id。旧服务没有这两条 = 409
  `old_service`；旧 agent = 409 `old_agent`。
- **家机器服务**（`server.mjs handover`）：先 `view-of` 看窗口；接管：已是 webchat = 200 `already`，终端在答 = 409 `terminal_busy`，
  网页那一边在答 = 409 `web_busy`，否则 `fleet-webchat-handoff.sh to-web fid:<id> --no-open`（⌘P「在 WebChat 里继续」同一条路，不在人的屏幕上开页）。
  交回：不是 webchat 拿着 = 200 `already`，网页在答 = 409 `web_busy`，否则 `give-back fid:<id>`。同一个窗口同时只办一件：
  第二个 409 `taking`。
- **两处同时接管只一个成功**：服务进程里按窗口一把（两个网页）；`fleet-webchat-handoff.sh` 里按窗口一个目录锁
  `convo-lock/.taking-<fid>`（网页和 ⌘P 一起按），第二个 rc 3「另一处正在接管这个会话」。
- **交回** = `give-back`：网页不在答，就给窗口结束页按它自己的 ↵——结束页跑 `to-terminal`（锁改回 terminal、WebChat 放掉热进程）并按原样续同一个会话号，
  终端马上能打字；窗口没停在结束页就只改锁。
- 测试：`fleet-webchat-handoff-selftest.sh` 7b、`fleet-webchat-selftest.mjs --only=handover`（X）、e2e `TestChatHandover`、
  `extras/web-console/test/session-handover.mjs`。

### 会话合一：网页上一张会话表、对任何会话直接说（Y01K，与 HHV0 · PQ41）

页面一侧（`extras/web-console`）。开关是入口的 `fleet.chat.unified`，页面从
`GET /v1/chat/home` 的 `unified: true` 读到（`chat/home.ts useUnified`）；没有这个字
段 = 旧路：`/app/chat` 的那一条对话、终端会话只读，下面这些都不出现。

- **一张会话表**：「我的对话」不再是专行（旧路才有）；终端开的会话标题后一个 `>_`
  （行的 `origin`，旧入口不说时有活窗口即算终端）；行尾只说要看的：回答中 · 新回复 ·
  在问你；停放的网页会话就是「空闲」（`work.ts boardRows`）。一个行从「回答中」变走而人
  不在它上面 ⇒ 橙点「新回复」+ 顶部一行「「X」答完了 · 去看」3 秒（`work-rows.tsx`）。
  机器名只给有好几台机器的人、只在详情里（`board.machines`，没有就按行数）。
- **新会话只一个入口**：左栏 ＋ / 手机右下「＋ 新会话」→ `/app/new`。对话：
  `POST /v1/chat/open {agent, text}`（家机 `/api/open`，开一个 origin web 的会话，第一句
  是它的第一轮）→ `{fid, worker}`，开好进 `/app/s/<ref>`；终端：页面不开会话，给
  `fleet claude` / `fleet codex` 与安装行，网页终端只在底部一行小字。电脑上的 `/app/`
  就是新会话页；`/app/chat` 打开迁出来的「我的对话」（origin web，标题「我的对话」）。
- **对会话直接说**（`chat/view.ts` + `chat/talk.ts`）：读仍是 `GET /v1/chat/view`，
  `{t:"state"}` 里 `can_talk` 为真才写；`POST /v1/chat/say?worker=` `{id, text, images?}`
  → `{delivery, state: sent|queued|refused, reason}`。发出的一句先照着落地的样子画，
  记录里有了就换成记录；`queue` 里 why 为 busy / typing / asking 的淡色排着、下面一行
  原因，waking 照常画（接回期间就是「回答中」）；门退回的（expired · session_changed ·
  wake_timeout · no_session · old_version · exited · dropped）文字放回输入框、输入框上一句
  「这一句没送到…」+ 重试 / 在新会话里接着说，并 `POST /v1/chat/ack?worker= {delivery}`。
  不知道送没送到（没有回答）的重试用同一个 id。提问卡片：`ask {fp, kind, questions}` →
  `POST /v1/chat/answer?worker= {fp, answers}` / `{fp, allow}`；停止：`POST /v1/chat/stop?worker=`。
  `can_talk:null`（首次探测）或 `talk_reason:unreachable`（暂时连不上）显示连接中，允许写草稿但不能发送；探测会自动重试，明确为真后启用发送。只读票据和以他视角看始终不能写。
  `can_talk` 为假（老版本）或旧服务没带这个字段时只读，只在输入框里一句「只读 · 终端会话。要接着说，在 iTerm2
  里输入 fleet open <编号>（详情里可复制）」。接管按钮、「对话 | 终端」切换都没了；旧路
  上已经被网页接过来的会话仍可「交回终端」。
- **同步只一种说法**：标题旁浅灰小字，平时什么都没有（不再有「已同步」）；没同步时
  「同步中…」，超过 10 秒或家机器连不上时「家机器暂时连不上」，输入框说「家机器连回来后
  才能发」。会话的「⋯ 更多」第一项一点即复制 `fleet open <编号>`；详情里是命令行接入。
- 原型：`npm run build:proto`，场景 `{"uni": "on"|"busy"|"typing"|"ask"|"old"|"fail"|"down"}`。

### 会话合一：网页只和会话说话（PQ41 ②；HHV0 ① 家机会话门、Y01K ③ 页面）

网页里的每段对话都是家机器上的一个会话，和终端开的会话进同一张表（A4G2 的 `board`）：网页表、⌘P、看板画同一批行。

- **说**：`POST /v1/chat/say?worker=<id>`（`{text, images: [≤4]}`，≤1 MB）→ 会话所在登录的 `/api/say`，body 加入口写的
  `fid`（浏览器带的 `fid` 被覆盖）→ `{delivery, state: sent | queued | refused, reason?}`。`answer?worker=`（问题指纹 + 选项原文）、
  `stop?worker=`、`ack?worker=`（`{delivery}`，页面收下队列退回的一句）同一条路（`/api/answer|stop|ack`）；不带 `worker` 的 `answer` / `stop` 仍是家里那段对话自己的。谁 = `termPerson`，
  会话是不是你的 = `termTarget`（家或你自己的另一个登录，否则 404 `not_yours`），个人终端 400 `bad_target`；空话 400 `empty`、
  五张图 400 `too_many_images`、不是 JSON 400 `bad_body`；旧服务 409 `old_service`、旧 agent 409 `old_agent`。试用者的一句照旧记一行，
  会话没收下（非 200 或 `state: refused`）就还回去。`open-terminal` 不做（「更多」只复制命令）。新开一段：`POST /v1/chat/open`
  （`{agent, text, images}`，转家的 `/api/open`，第一句随它记试用的一行；回答里入口补上 `worker` = 这个登录唯一那支 fleet 的 `<fleet>/<fid>`）。`GET /v1/chat/home` 带 `unified`（= 下面的开关）。
- **旧路由**：设置 `fleet.chat.unified`（默认 off）。on 时 `/v1/chat/turn|new|take|takeover|giveback` 回 410 `moved`、不到家；
  off 时照旧转发（新页面和家机会话门上线前网页不断）——三个任务里最后合入的一方把它打开，之后一个版本删旧路。
  接力锁（`fleet-convo-lock.py`）不再有新的写入方：⌘P「在 WebChat 里继续」改为「在网页里打开」（`fleet-web-open.sh`，
  开 `/app/s/<会话>`，不搬、不锁）；结束页对旧锁的读取留一个版本。
- **表**：`board.rows[]` 每行加 `origin`（`web` = 网页开的，节点 inventory 第 35 列 `origin=web`，来自窗口的 `@session_origin`；
  否则 `terminal`；没会话的记录行为空）和 `can_talk`（活着、没收起、机器没失联 / 维护 / 停用；终端会话默认也能说）。
  停放的会话（节点报 `state: parked`）在表里就是「空闲」。`board.machines` = 这个人有几台机器，1 台时页面不显示机器名。
- **停放**：`fleet.session.park_idle`（默认 `5m`，`1m`–`24h` 或 `off`）随 `/v1/fleet/client-settings` 的 `pool` 下发为
  `FLEET_SESSION_PARK_IDLE`（秒，0 = 不停放），只管网页开的会话。
- **旧书签**：`/chat`、`/chat/` → 301 `/app/chat`（「我的对话」——旧对话迁出的那个会话的地址，页面认它）。
- 测试：e2e `TestChatSayToSession`、`TestChatPage`；`TestBoardOriginAndCanTalk`；`session-title-selftest.sh`（第 35 列）；
  `fleet-view-board-selftest.py`（网页开的一行）；`fleet-view-actions-selftest.sh`（`webopen`）。

## 会话合一 ①：会话门、停放与接回（HHV0）

网页不再自己跑一段对话、也不再「接管 / 交回」：每个对话就是家机器上的一个**会话**（一个窗口、一个
`@fleet_id`，和终端开的同一张表），网页和终端都只是往里「说一句」的口子，先到先进。家机上的对话服务
是这些会话的**门**：收下网页的一句，交给那个会话作为它的下一轮。

| 路（家机 socket） | 做什么 |
|---|---|
| `POST /api/say` `{fid, text, images≤4, id?}` | 一句话（+ 图，存进 `media/`，路径写进这一轮）→ `{delivery, state: sent\|queued\|refused, reason}` |
| `POST /api/open` `{agent, text, images?}` | 网页新开一个会话：本机 no-repo 窗口，`@session_origin web`，这句是它的第一轮 → `{fid, agent, state}` |
| `POST /api/answer` `{fid, fp, answers\|picks}` · `{fid, fp, allow}` | 替它答 AskUserQuestion（`fleet-dialog-answer.sh`）/ 权限（`fleet-permission.sh --by 网页`） |
| `POST /api/stop` `{fid}` | 停掉正在答的一轮：Claude 确认在答时按 Esc（实测 0.24–0.34 s），Codex `turn/interrupt` |
| `POST /api/ack` `{fid, delivery}` | 页面把退回的一句放回输入框后，门里删掉它 |
| `GET /api/session?fid=` | `{can_talk, queue:[{delivery,text,why}], ask?}` |
| `GET /api/view?fid=` | 读记录的流（F481 那条）；`{t:"state"}` 不再有 holder，带 `can_talk`、`queue`、`ask` |
| `POST /api/migrate` · `GET /api/ended` | 旧「我的对话」变成一个会话（同一对话 resume，窗口名「我的对话」）；收起过的 ≤200 段进「已结束的会话」 |

没有 `fid` 的 `/api/turn|new|take|stop|answer` 还是旧的 SDK 对话，直到入口的 `fleet.chat.unified`
打开（PQ41）；迁移过的对话再走旧路回 410 `moved`（带 fid）。

**门** = `bin/fleet_session_gate.py`。每句一条记录先落盘（`$FLEET_CONF_DIR/session-gate/<fid>/`，每句
一个 delivery id），再交出去，所以服务重启丢不了、也不会发两遍（WD8F ①：一轮在它自己的窗口里跑，
重启对话服务掐不断它；排着的照样从盘上接着送）。

- **Claude**：fleet mod 的条件接收 `idle.v2`（mod ≥ 0.7.0，`mod/fleet/hooks/accept.ts`）：投进窗口的
  收件箱槽位，到引擎入口边界再查一次——没有在跑的一轮、输入框没有草稿、其间没有 /clear——过了就是
  它自己的一轮（回执：mod 的回执文件，或这一轮隐藏上下文里的 delivery id）；拒了就排着，服务每 1.5 秒
  tick 一次，空闲了再交；没答复就先查回执，绝不重投同一句。网页的一句被停止后，引擎会把它放回输入框，
  mod 认出是门自己的话就清掉（不然后面每句都会被当成「有人在打字」）。
- **Codex**：它自己的队列（`thread/queue/add` 带 clientUserMessageId，再 `thread/queue/start`）：空闲就
  开始，在答就排在 Codex 自己的队列里，答完它自己开始，门扫回执确认。
- 一个会话一次交一句，最老的先：在答时连说两句 = 两轮，按顺序。
- 退回网页（`why`）：排了 30 分钟（`FLEET_GATE_QUEUE_SECS`）还没进 `expired` · 换了对话（/clear、另一个
  id）`session_changed` · 窗口没了 `no_session` · 老版本 `old_version` · 停放的会话 20 秒没接回
  `wake_timeout`。排着时的 `why`：`busy` 在答 · `typing` 终端里有草稿 · `asking` 它在问你（先答问题）·
  `waking` 正在接回。
- `can_talk`：mod 说 `@mod_accept idle.v2` 的 Claude、停放中的会话（下次启动就是新 mod）、app-server
  ≥ 0.162 的 Codex；其余只读。清单第 36 列 `cantalk=`，第 5 列停放时写 `parked`（看板画成空闲）。

**停放**（`fleet_session_gate.py park`）：所有来源的空闲会话共用 HHV0 的停放器
（`fleet-cleanup-idle.py web_park`，保留旧入口名）。只停有 `@park_wrap_ver=1` 的新外壳：
在答、在问、输入框有草稿、有话排着、有后台任务、真人终端客户端正在看着，都不停。
看着时不断刷新离开时钟，离开后重新等待；分组 view 与 thin 客户端按窗口身份判断，控制模式不算真人。
有人交互的档位为 `fleet.session.park_idle`（5 分钟）；无人档位为
`fleet.session.park_idle_unattended`（本次缓存实测未完整复用前缀，默认保守退回 5 分钟，可设 1 分钟）。
`fleet.session.park_presence` 默认 15 分钟：键盘输入和网页在场更新时间，缺少证明时按有人处理。
内存紧张（`FLEET_PARK_MEM_PCT`，15%；试用账号到份额 80%）时，按空闲最久排序，跳过不适合的窗口，
每拍停一个，不必等普通档位。派发工作已报告完成仍按原回收规则结束。C6 的 `fleet_reap_policy.py ORIGINS` 同表维护停放和回收：person / decide 及等待回复的任务停放后 `fleet.session.reap_parked`（默认 3d）无动静才回收；先验证历史可接回，常驻与显式 keep 不回收。`fleet doctor --park` 的每窗口行读同一截止时间。

停放前按适配表 `park_probe` 取证明：Claude 用 mod 的 `park.v1`；Codex 检查原生 thread idle、
队列为空和终端输入框为空，后台任务 / 子会话 / goal 由已有的原生 inventory 检查。无法确认就不停。
两者通过同一个 7501 中继向 pty 送 `/exit`；`park_exit` 指定 Codex 的 bracketed paste，
不支持该退出方式的老中继拒停，等下次正常重开后启用。
证明以后有键盘输入就取消，绝不靠 Escape 清空草稿。窗口、ID、对话、工作区和凭据留在原处，窗口仍读作空闲。
有定时任务时必须先交出 C3 的唤醒约定，否则保守不停。
Codex 的 Fleet loop 轮间即使没有 Claude mod 状态，也由同一原生证明判断是否可停。
迁移循环停放后，外壳接回时移除首次桥接启动参数，保留原 manifest 与 ledger；不再创建控制器，定时投递继续归已交接的 gate owner。

唯一唤醒接口为 `fleet_park_wake <fid> --why <理由> [--seed-file <文件>]`，转到门的 `wake`；
包装器自己请求唤醒时使用 `--request-only` 避免等待自己。种子文件挂在 `@park_wake`，包装器 rename 成
`.taken` 后用同一会话号 `--resume`（Codex 为 `resume <thread id>`），句子随启动进入首轮；
Claude 的 7501 首次原生状态、Codex 私有 runtime 的 thread 绑定分别写 `.launched` 确认恢复。
超时收回未认领种子；已认领的种子属于当前启动，不会重投。
peer 消息和子会话回报也通过 `fleet_agent_deliver` 调这一个唤醒入口，原文成为接回后的首轮；
发送方只有在 7501 确认接回后才看到已送达（返回 0），否则仍排队（返回 3）。
`fleet-peer-queue.sh drain` 沿用投递编号（`--delivery`），认领后的慢启动只等原回执，
不会在新进程的收件箱再送一次。账本原因分别为「消息」「回报」。

**选择框暂不自动停放（C4）**：Claude Code 2.1.295 的原生 AskUserQuestion 演练中，
向打开的选择框发送 `/exit` 没有退出，反而提交了当前 Blue 选项。无法证明题干与选项可安全恢复，
因此即使等过 30 分钟仍保持运行；网页、⌘P、微信继续走现有代答入口。
权限确认也继续排除。统一 `park` 入口及原生证明后的复检都拦截 blocked、ask、权限标记和
会话记录中未回答的 AskUserQuestion；旧 done 状态、loop 标记和内存紧均不能绕过，题干及选项原文不改。
只有取得原生空输入框证明的空闲会话才可停放。

有人切到窗口或在里面按 ↵ 也走这一路。C8 计量沿用 HHV0 的 `@parked` + `@park_held`，两者同时存在才计停放。`@park_since` 为本次停放开始的 epoch，接回或停放失败时清除。停前由 C1 写 `@park_saved_mb` 和
`@park_why`；RSS 为进程树含外壳的总量，单位 MB，采样失败或根进程缺失时清除快照。C8 优先读这份快照，缺戳时才按同一 fid 取最后一次 park 动作的 rss_mb 后备，两者都缺失则隐藏节省项。只在动作发生时追加 `logs/park.ndjson`：`ts, fid, act, why, secs, result, next, started`；
`next` 与 `started` 为 epoch；成功 `park` 行可写 `rss_mb`（未采到为 null），用于动作记录，C8 日汇总按 act 计数和 wake secs 求分位。没有每拍的 skip 日志。

**停放期间的定时任务（C3）**：停前通过 `fleet_loop_mark.py export --fid <身份>`
读取 `@loop` 与这段会话的完整原生工具记录，保存到 `$FLEET_CONF_DIR/wake/<fid>.json`。
每个任务保留 `next / kind / expr / prompt / until`、任务 ID、时区及会话号。
原生进程退出且外壳确认停放后才启用；退出失败撤回准备状态，原生任务继续运行。
导出后末次复检若发现新问答、观看者或状态变化，也在返回拒停前撤回准备状态，
恢复先前约定与原 dispatcher 的投递权，不等下一次到期清扫；不发送退出或改写问题。
spinner 每 5 秒驱动 `fleet_park_wake.py tick`，到点经会话门接回同一会话，首轮是原提示。
唤醒仍由 `wake_request` 仲裁，7501 确认启动；`park.ndjson` 的 `why=定时`、`next`
和 `started` 记录约定与实际请求时刻。只有确认送达才推进 cron，错过多轮只执行一轮。
每轮使用落盘的 delivery ID，重复 tick 沿同一条门记录收据，不另发一轮。
restore 保留约定，停放外壳先回来等待到点；已有约定的 cron 不再重建 `/loop`。

durable 任务沿 `fleet_transfer_durable.py` 已验证的单一归属路径：先暂存，原生进程退出后，
在启动闸和项目隔离证明下撤出原生表，读回一致才激活 fleet 约定。另一个会话的记录不动。
未知原生版本、临近切换边界、不能证明归属或存在其它原生写者时拒停，返回 `wake_contract`
及原因；不能只复制文件便让两个调度器同时执行。会话内 `CronDelete` / 停止唤醒沿现有 hook
同步取消 fleet 约定；也可使用 `python3 bin/fleet_park_wake.py stop --fid <身份> --job <任务ID>`
停止指定约定（省略 `--job` 停止该会话全部约定）。已开始的轮次不会被强行中断。

已由 `fleet-loop.py` 管理的循环（含 Codex）继续以原账本为唯一节拍来源。
停前写 `park_fid` 交出投递权；旧 bridge 不再投递、也不因停放退出把循环写成 stopped。
外壳进入停放页时清掉 transfer 首次创建控制器所用的 `FLEET_LOOP_SPEC / FLEET_LOOP_AGENT`，
保留原 manifest / ledger；接回走原 thread 的普通恢复，不再进入 bridge 创建另一份控制器。
接回同一 thread 后原有 `fleet-loop.py defer / stop` 仍有效；正在投递且收据未定的循环拒停。
显式 stop、取消任务或改期后，定时 tick 与独立会话门清扫都会重新核对原计划，
撤销尚未被外壳或原生领取的旧提示。同一时刻的多个任务取消其中一个时，
旧的合并提示作废，其余任务以新的 delivery ID 投递一次，原账本与 owner 代次不变。
已被领取的当前轮次保留原收据，不强行中断；收据确认不会把 stopped 的账本重新激活。

隔离演练：`bin/fleet-park-wake-selftest.py` 驱动停放门、外壳、定时投递及 durable 撤出，
覆盖 3 秒后唤醒、三轮 cron、外壳恢复、退出失败保持原生任务，以及 Claude/Codex
原 ledger 的同会话投递、owner 不变和停止不复活。BREAK-IT `park-stopped-timer-revives`
还驱动显式停止、单任务取消及未取消任务的保留。

测试：`bin/fleet-session-gate-selftest.py`（假 tmux、假 mod、假 Codex，A–M）、
`bin/fleet-idle-accept-claude-selftest.sh`（真引擎：入口边界、排队重交、Esc、草稿、竞态；CI 上无 claude 跳过）、
`bin/fleet-webchat-selftest.mjs --only=gate`（Y：HTTP 路）、`bin/session-wrap-selftest.sh` PK（停放与接回）、
`bin/fleet-cleanup-idle-selftest.py WebPark`、`bin/fleet-park-selftest.py`（隔离 socket，实际进程退出与身份保留）。

## 浏览器上下文（#4034）

模型知道人此刻从哪儿、用什么在说话：

- **页面报自己**（`ui/src/browser.ts`）：UA、UA Client Hints（高熵的 platformVersion / model / architecture 每页问一次）、
  语言、时区与偏移、屏幕 / 视口、触点、`navigator.connection`、深色——随每个 `/api/turn` 的 `client` 一起发。
  服务端 `cleanBrowser()` 只留这些字段、截长度，别的丢掉。
- **入口报地址和城市**：入口转发时自己写一个 `X-Fleet-Client`（base64url JSON `{ip, country, province, city}`，
  `tokenledger/hub/api/chat_client.go`），浏览器带来的同名头丢掉——和 `X-Fleet-Person` 一样只有入口能写；
  它走在节点验过首帧签名之后才接到 socket 的那条流上，所以不改 `chat_relay_open`、首帧和节点。地址取最右一个
  公网的 `X-Forwarded-For`（ingress 加的；副本转交加的是私网段，跳过），否则连接对端。城市来自入口本地的
  ip2region IPv4 xdb（Apache-2.0，约 11 MB，中文地名）：`CCQUOTA_FLEET_CHAT_GEO_DB` 指向它，进程内只读一次；
  不设或读不了就只有地址（逐字节照旧，日志说一次）。不调任何外部服务。本机直连模式没有入口，只有页面那一半。
- **给模型一行**（`lib.mjs` `contextLine()`）：`手机 · iPhone · Safari · zh-CN · 窄屏 · 本地时间 2026-10-13 周二 14:05（Asia/Shanghai） · 大致位置 广东省深圳市`，
  包在 `<fleet-webchat-context>` 里放在这一轮人的话**前面**（不进系统提示——那会破提示缓存），页面上剥掉。
  只在一个 session 的第一轮、或这一行的键（设备 · 系统 · 浏览器 · 语言 · 屏宽档 · 时区 · 位置 · 本地日期——不含分钟）
  变了时加；键记在 `conversation.json` 的 `ctxKey`。不含 IP、不含原始 UA。
- **按需工具** `browser_context`：每一轮用 SDK 的 `createSdkMcpServer` 现做一个进程内 MCP 服务（`fleet_browser`），
  只装这一轮这个人的浏览器：完整 IP、位置、UA、Client Hints、语言、时区、屏幕、网络。答在对话记录里，
  `server.log` 不记 IP、UA 或任何一项。

### 城市库（#4039）

- **怎么到入口**：烤进 hub 镜像。`tokenledger/Dockerfile` 的 `geo` 阶段在构建时取
  `lionsoul2014/ip2region` 某个固定提交的 `data/ip2region_v4.xdb` 和 `LICENSE.md`，两者都要对上钉住的 sha256，
  对不上就构建失败；镜像里放在 `/usr/share/ccquota/ip2region/`（旁边一个 `SOURCE` 写着来源提交）。
  运行时从不下载。镜像来源先 jsDelivr（深圳的 buildkitd 够得着）、再 GitHub raw——哪个都行，哈希说了算；
  `GEO_DB_MIRRORS` 构建参数可以换。`deploy/k8s/base/deployment.yaml` 设
  `CCQUOTA_FLEET_CHAT_GEO_DB=/usr/share/ccquota/ip2region/ip2region_v4.xdb`。
- **更新**：上游大约每月合一次社区修正。每季度一次（或有人报某段地址城市错了时），谁想换谁开一个 PR：
  改 `geo` 阶段的 `GEO_DB_COMMIT` · `GEO_DB_SHA256` · `GEO_LICENSE_SHA256` 三个钉子，
  本机拿新文件跑 `CCQUOTA_TEST_GEO_DB=<文件> (cd tokenledger/hub && go test ./api -run TestChatGeoRealDB)`
  （格式变了这里先红），随下一班列车上线。
- **许可**：ip2region 是 Apache-2.0 / MIT 双许可；它的 `LICENSE.md` 原样随库进镜像（同一目录），这一节就是署名处。
- **验**：上线后在 `/chat` 问「我大概在哪」，模型那行上下文里有「大致位置 …」；`browser_context` 工具能给出完整的省市。

## 图片（T773）

对话里的图——工具结果里的（截图、读到的图片文件）、回复里的、人自己发的——对话记录里本来就是 base64 块；服务把它们
**按内容落一份**：`<state>/media/<sha256 前 32 位>.<png|jpg|gif|webp>`（目录 0700、文件 0600），给页面的是条目
`{t:"image", id?, ref, w, h}`（人发的挂在自己那一行的 `images` 上），**JSON 里从不带图的字节**。页面按 ref 取：
`GET /v1/chat/file?ref=<ref>` → 入口（只认这个 ref 的形状，别的查询一律不往家传，404 不出门）→ 本人的家 →
服务的 `/api/file`：只读 media 目录、原样的图片类型、`Content-Security-Policy: default-src 'none'; sandbox`、
`nosniff`、可缓存（名字就是内容）。取图在入口另排一队（每人 6 个同时、每分钟 300 个），不占一轮对话的位子。

上限：单张超过 `FLEET_WEBCHAT_IMAGE_MAX`（10 MB）的不落、条目是 `{t:"image", big:true}`；两句人话之间超过
`FLEET_WEBCHAT_IMAGES_PER_REPLY`（20）张的，多出来的计在一个 `{t:"image_more", n}` 上。最新 60 张图带一张
预览 `thumb`（≤ 24 KB 的 JPEG data URL，后台用 macOS `sips` 或 ImageMagick 做，都没有就不带）；国内那份副本
（`chat_mirror.go`）对图**只存预览**——不存 ref、不存原图，全部预览 ≤ 2 MB、新的优先——家连不上时页面先显示预览。

### 回复里指向家机器文件的链接（T773 ②）

回复里的 Markdown 链接 / 图片目标若是本机文件（绝对路径、`~/…`、`file://…`、相对会话目录），服务在那段文字后面给一条
`{t:"files", files:{<原样的目标>: <ref>}}`，页面把这些目标改成 `/v1/chat/file?ref=<ref>`。ref 是 `f` + 32 位十六进制
的随机号，记在 `<state>/refs.json`（0600，7 天，`FLEET_WEBCHAT_LINK_DAYS`；过期后 30 天内回 410「已过期」），入口
只见号、不见路径。给号与读取各认一次：只放 `$HOME` 或会话目录下的普通文件、≤ 20 MB（`FLEET_WEBCHAT_LINK_MAX`），
`lib.mjs` `fileDenied` 名单（`.ssh` `.config` `.claude` `.aws` `Library/Keychains` …，`.env*`、`*.pem`、`id_rsa`、
名字带 secret / token / credential / password 的）一律不给；读的时候若已变成链到外面的软链，拒。图片原样回，其余
（含 HTML、SVG）一律下载，`sandbox` CSP——Agent 写的东西不在入口的域名下运行。BREAK-IT `chat-file-escape`。

### 发图给 Agent（T773 ③）

输入框左下「＋」（`ComposerAddAttachment`，assistant-ui 的 `SimpleImageAttachmentAdapter`）选图、拍照或粘贴；发送前
浏览器用自己的 canvas 把每张缩到长边 ≤ 1568 px（Claude 看图的上限）、转 JPEG，逐级降质量 / 尺寸，直到全部图加字放得进
对话这条路**一次请求的 1 MB**（`control.ChatBodyMax`，节点的帧缓冲按它定，不放宽）。一条最多 4 张。`/turn` 的请求体多一个
`images:[{media_type, data}]`；服务只收 png / jpeg / gif / webp 且读得出尺寸的，超过 4 张或不是图回 400，整条超界 413；
给 Agent 的是内容块 `[image…, text]`（暖会话直接推，冷路径包成一条消息的输入流）。图随后按「图片」一节落 media、挂在人那
一行上。

### Agent 做的网页：发到活页，对话里一张卡片（T773 ④）

对话服务给 Agent 两个进程内工具（`fleet_chat` 服务）：`page_target({file})` 答这一页该放哪——活页文件夹「WebChat 产物」
（第一次由 Agent `create_folder`，之后记在 `<state>/pages.json`，0600）和这个文件上次发成的 `proposal_id`（再发就是同一链接的
新版本）；`show_page({title, url, status, proposal_id, version, file, folder_id?, preview?})` 让页面多一张卡片
（`{t:"page"}`，从对话记录里这次调用的输入重建，非 https 的链接丢掉，`preview` 是本机一张图、按「图片」一节落 media）。
发布本身用这个登录自己连好的 `space` MCP（凭据是 Claude Code 自己的，不经这个进程、不进对话记录），默认私密、工具不改可见
范围。每个会话第一句前有一段 `<fleet-webchat-note>`（页面不显示）告诉 Agent 这些规矩。卡片在控制台用 `makeAssistantDataUI`
画：可点（`ready`）时「打开」新开一页；`review` / `publishing` / `failed` / `unavailable`（这台机器没连活页）不可点；同一
`proposal` 的卡片都显示最新一次的状态与版本。「在这里预览」用活页的嵌入链接（QVTF：工作区白名单
`embed_origins` 里有入口的 origin 时，`preview_version(version_id, embed_origin)` 给一个 ≤ 60 分钟、只读、免登录的
`embed.url`，只有它回 `frame-ancestors <入口>`）：页面每轮把自己的 `location.origin` 交给服务，`page_target` 答
`embed_origin`，Agent 铸好后连同 `expires_at` 交给 `show_page`（`embed_url` / `embed_expires`），卡片在过期前多一个
「在这里预览」，点开是 `sandbox="allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox"` 的
iframe；过期就只剩「打开」。入口控制台只在部署给了 `CCQUOTA_FLEET_CHAT_FRAME_ORIGINS`（逗号分隔的 https origin，填活页的嵌入链接所在的源；
生产的值在私有部署覆盖层里）时加 `frame-src`，否则什么都不嵌。国内副本存卡片的标题、链接、状态，
不存预览。

### 试用者的网页：替他开活页、钥匙不进会话（task XA4R）

试用者的登录没有自己的 `space`。对话服务每轮问一次本机凭据代理 `GET /space/status`（带这一轮的会话凭据；代理用这个登录的节点令牌问入口
`GET /v1/node/livepage-token`，一分钟一问）：是试用者、入口开着 `fleet.trial.livepage` ⇒ 给 Agent 挂一个 `space` 服务器——
`bin/mcp-space.py`，stdio 小桥，参数只有代理地址和**会话凭据所在变量的名字**（Claude `CLAUDE_CODE_OAUTH_TOKEN`，Codex
`FLEET_CODEX_SESSION_CRED` 经 `env_vars`），凭据本身不进配置、不进 argv。小桥自己答 `initialize` / `tools/list`（发布用的那十个工具），
第一次真调工具才经代理的 `/space/mcp` 连活页——没发过网页的人不会多出一个空账号。代理在转发时问入口要这个人的活页钥匙
（`POST /v1/node/livepage-token`：第一次由入口调活页 `/internal/partner/provision` 开号，钥匙封存在 `hub_partner_creds`），只放内存、
到期前 5 分钟丢掉，换掉 Authorization 再转给活页的 `/mcp`（`FLEET_CRED_SPACE_URL`，默认活页的公网入口）；活页回 401 就再问一次。第一次开号那一调的结果多一行，
Agent 给 `show_page` 带 `account_new`，卡片上说一次「已用你的微信开好活页账号」；发好后 `push_to_wechat`（只给本人）再带 `pushed`，
卡片写「仅你可见 · 已发到你的微信」；开号没成是 `status: account`，卡片有「现在重试」。试用的网页不能设公开（小桥和活页两边都拒），
要给别人看先问、只给口令。试用结束（到期、用完、转正）入口一分钟内收回钥匙并告诉活页 `/internal/partner/revoke`，到期那次推一条微信、
对话页的额度条改说「网页保留 30 天」；删掉这个人时活页账号一起注销（`erase`）。`fleet.trial.livepage` 默认 `off`：什么都不挂、不开号，
和以前一样。测试：`fleet-cred-proxy-space-selftest.py`（代理 + 小桥）、`fleet_trial_livepage_test.go`（入口）、本页 S 段的试用一半。

## 认证和凭据

每一轮用 `bin/fleet-session-cred.sh mint --provider claude --sid web-<pid>-<n>` 取一张**会话凭据**，
这一轮结束就 revoke。SDK 起的 `claude` 子进程只在环境变量里拿到它：

| 变量 | 值 |
|---|---|
| `ANTHROPIC_BASE_URL` | `http://127.0.0.1:<代理端口>`（共享凭据代理） |
| `CLAUDE_CODE_OAUTH_TOKEN` | 这一轮的 `fcp1.…` 会话凭据，不是订阅令牌 |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | `1` |

`ANTHROPIC_API_KEY`、`ANTHROPIC_AUTH_TOKEN`、`FLEET_WORKER_CRED`、`TMUX*` 都会去掉。代理按请求从池子里选号、计量，
记到这个登录对应的人名下（`POST /v1/node/usage`），额度满了切号 —— 和 `bin/fleet-claude.sh` 一模一样。
代理关着（`fleet-session-cred.sh on` ≠ 0，或 mint 返回 3/4）时，按 CLI 的老路，用这个登录本身的身份。

**额度**：人的额度（`fleet.person_budget`）到顶时，凭据代理把这一轮拒成 403 `person_budget_exceeded`
（带入口给的 `reset_at`）。Claude Code 会把它当成一句「API Error: 403 …」交回来；服务认出它，流里只发一行
`{t:"error", code:"budget", msg, until?}`，原话不上页面；`GET /api/conversation` 带
`budget: {blocked, msg?, until?}`，记在 `budget.json`（重启也在），一轮真走通才放开。

凭据只在子进程的环境变量里：不进响应、不进 `server.log`、不进任何文件，也不出现在 argv 里。
另外，响应和日志写出去前都会过一遍 `redact()`，`fcp1.` / `sk-ant-` / `Bearer …` 形状的串会被替换掉。

## 只有本人能进

socket 模式（默认）：门就是 socket 本身——0600、在本登录 0700 的状态目录里，同机别的登录连不上；
旧 socket 先删再建（umask 0177 下诞生），已有活的服务在答就不起第二个（exit 3）。BREAK-IT `chat-socket-other-login`。

本机直连模式（`FLEET_WEBCHAT_LOCAL=1`）：

- 只绑 `127.0.0.1`，没有改它的选项。
- 进门要一次性链接，由 `fleet-webchat.sh link` 生成：它要出示 `admin.token`，这个文件是 0600，放在本登录 0700 的状态目录里，
  机器上的别的登录读不到，也就生成不了链接。
- 链接只能用一次，10 分钟内有效。用过之后种下 HttpOnly、SameSite=Strict 的 cookie，有效 30 天；cookie 只存 sha256。
- 没有 cookie 一律 403。不认识的 `Host` 返回 421（防 DNS rebinding）。POST 必须带页面自己加的头。

## 测试

`bin/fleet-webchat-selftest.sh` 用桩 SDK、桩 `fleet-session-cred.sh`、桩代理把服务真跑一遍，覆盖：
只绑 127.0.0.1、没有链接的人被拒、白名单由服务端执行、这一轮的请求带着发下来的会话凭据到了代理（池子在代理那里计量）、
sid 用完被 revoke、凭据和 admin token 不出现在任何响应、日志或文件里、重启后还是同一条对话、停止键；
以及页面本身（G）：没有 cookie 拿不到页面和资源、CSP 只许同源、gzip、`dist/` 以外的文件出不去、提问带着它卡住的那一步。
A–G 在 `FLEET_WEBCHAT_LOCAL=1` 下跑。H：socket 0600 / 目录 0700（放一个 0666 的旧 socket 也会被换掉），能免密
`sudo -u nobody` 的机器上另一个 uid 连不上（放开时它连得上，作对照），没有 TCP 监听、没有 `admin.token`，
不带 `--socket` 也没开本机模式就不起。I：代理的预算 403 → 一行 `code:"budget"` + `until`，`/api/conversation` 说被挡，
走通一轮放开（BREAK-IT `chat-budget-bypass`）。M：手机 UA 和电脑 UA 各一轮，各在人的话前面加一行上下文（带入口给的城市、不带 IP），
同一浏览器再问不加、换城市再加，页面上看不到这一行，`browser_context` 答得出完整 IP 和 UA，`server.log` 里都没有。
入口那一半（浏览器伪造的 `X-Fleet-Client` 被换掉、XFF 取哪一个、xdb 读法）是 Go 的 `chat_client_test.go`。
`--only=socket|budget|context|local` 只跑其中几段（演练用）。

Codex 那一边是 `bin/fleet-webchat-codex-selftest.sh`：假的 `codex app-server`（按 0.162 实录的 JSON-RPC 讲话）驱动
`server.mjs` + `codex.mjs`——两边各自的对话、凭据只在子进程环境里、workspace-write + on-request、流里的每一种步骤、
读回、批准（accept / decline / cancel）、提问按 id 回填、停止、额度、新对话只清一边、重启接着同一个 thread、凭据不出现在任何响应或文件里。

## 不在这一版

网页终端、文件和图片上传、语音、多人共享一条会话、给 tmux 里正在跑的会话插话、并进入口 `/app`、微信登录。

### 试用码的次日留存（TVCC / T938）

运营台「试用码」列表和详情的漏斗在「首句」后显示「次日回来」（英文
Back next day）：开通后的第二个北京自然日里发过消息的人数，每人只计一次。
例如周一 23:59 开通、周二 00:00 发言就计入；周三才回来不计。
用该人数除以开通人数可看次日留存，刚开通、还没走完次日的批次要等到窗口结束再比较。

hub 在对话服务接受 `open` / `turn`，或统一会话入口接受 `say`（已发送或已排队）时
记录 `fleet_trial_grants.next_day_at`；打开页面、拒绝发送不计数。只保存时间，
不保存聊天正文。统计从本次发布开始，没有历史消息回填，旧批次的零不能解释为无人回来。
`GET /v1/admin/trial-codes` 的每码漏斗、七天汇总和详情均返回 `next_day`。

官网开启试用后，未登录用户看到站点试用码；已登录用户在电脑上看到的
「换个微信登录」仍请求登录码，手机上保留「进入控制台」。

停放后的接回由本机全部登录共享 `fleet.session.wake_slots`（默认 3，1–32）个
启动名额。对应节点设置 `FLEET_SESSION_WAKE_SLOTS`；共享槽在 macOS 的
`/Users/Shared/claude-fleet/wake/slot-K`，Linux 的 `/var/tmp/claude-fleet/wake/slot-K`，
由现有 shared-dirs 维护 root 所有权。同优先级按原请求时间排队；亲手提交的话有
30 秒的排队优势，等待更久的定时请求不会被持续插队。每次排队最多等 60 秒；
名额持有到原生助手确认就绪。定时接回还要通过现有机器准入闸，闸关闭或名额
排队超时会记一次 `deferred`，30 秒后重试同一投递，原提示、约定时刻和原排队时间保留。

原生启动 20 秒仍未确认就绪，外壳结束这次启动并回到停放页，原话保留；
启动失败也走同一恢复页。投递只认本次启动的 native-ready 回执：旧会话号仍在、
`@parked` 清空或落入普通恢复页都不是成功；失败保留原话和投递 ID，记 `fail`，
不推进定时轮次。同一失败投递重试仍返回失败原因。接回前比对原记录最后一个版本与本机助手版本：主版本
不符时，自动在原窗口带原话新开对话，旧记录保留，原因记在 `fresh` 动作和
`fleet doctor --park` 的说明行；已有定时约定迁移到新会话号，不重建定时器。
读不到版本时仍尝试原会话；原生拒绝接回则显示原因，按 `n` 带原话新开。
连续两次失败后，该窗口不再自动停放（包括内存压力触发），doctor 给出 WARN；
手动重试仍可用。memguard 规则 C 对 ≥4 GB 的空闲会话调用同一停放门，
提问、草稿、观看、后台任务和旧外壳仍拒停，拒停时保留原内存告警。
`park.ndjson` 只记 `park`、`wake`、`fail`、`deferred`、`fresh` 等动作，不记轮询。


统一生命周期（T939 / C7）：运行容量与保留会话分开。只有新外壳已确认
`@parked` + `@park_held`、原生 relay 已退出且没有待接回请求时，才从运行计数
扣除；退出中、接回中和未知外壳仍占容量。窗口、身份、历史和 pin/人工 keep
保持原样，账户/产品会话配额不改。

内存准入的 `--make-room` 对新外壳先让已完成任务走正式回收流程复检；仍需
保留的安全空闲会话（含 pin/keep/管家、无仓库和等待会话）走同一个
`fleet_session_gate.py park --why memory`，不强制关闭窗口。运行、输入、问题、
真实后台及未知证据继续拒停；这条路径不使用 `--force`。报告停放前后进程树
RSS 差值，读不到就报 unknown，不凭保留窗口数推算释放量。旧外壳保留既有
兼容路径，需具备停放协议后才能走这条停放路。仅沿已批准的单机灰度观察，不因
功能合入全局切换无人档 1 分钟，也不将隔离测试当作生产指标。
