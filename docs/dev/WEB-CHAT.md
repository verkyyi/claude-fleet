# 浏览器里和会话对话 · 最小版（issue #3567）

一个人一条对话，在浏览器里（手机 Safari 也行）跟 Claude 说话。后端是 **Claude Agent SDK**，
跑在这个人自己的登录上，走 fleet 额度池的凭据代理 —— 和 fleet 会话里的 claude 同一条路。

## 用

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

- **按需**（D1）：人打开 `/chat` 时，节点用固定的命令跑整机守护的
  `fleet-node-supervisor.py service ensure --login <这个人的家登录> --name webchat --wait 3`（`service_control`
  的 `ensure`，只认 `webchat`，入口给的是名字、不是命令）：没登记就按家目录登记
  （`~/.claude/fleet/bin/fleet-webchat.sh serve`，`paths[]` 是 `~/.config/claude-fleet/webchat`），停着或空闲就起，
  然后等 socket 上的 `/healthz`，每次 15 秒（`FLEET_NODE_ENSURE_SECS`），最多 3 次，两次之间重起一次。
  页面在这期间先显示骨架屏（C4）。
- **空闲退出**：没有在跑的一轮、没有页面连着、最后一次动静过去 `FLEET_WEBCHAT_IDLE_SECS`（默认 7200，0 = 不退）
  之后，服务自己退出、**退出码 75**。守护认这个码：记 `idle`（`fleet ls --services` 里「空闲·打开再起」），
  不重起、不告警，登记保留，直到条目被改写（`service start` / `service ensure`）。
- **跟人走**：`service move` 先停掉旧的，再把 `paths[]`（状态目录）搬到新家目录。Claude Code 的记录在
  `~/.claude/projects/` 里、不在 `paths[]` 里，所以服务每轮结束、每次退出都把整条 chain 的记录抄进状态目录的
  `transcripts/`；在另一个家目录下起来时（`conversation.json` 记着上次的 `home`），把它们放回自己的
  projects 目录、cwd（记录里的也一起）改成新家，记一行 `home_moved`。新家上打开 `/chat` 还是同一条对话，
  旧登录下不留服务。BREAK-IT `chat-home-moved`。

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
- 回复流式显示；每个工具步骤折叠成一行，点开看结果；`AskUserQuestion` 和权限确认显示成按钮，
  等你回答的那一步自己展开。
- 模型下拉只有白名单：Sonnet 5.5（默认）· Opus 5.5 · Haiku 5.5。白名单是 `extras/web-chat/lib.mjs` 的 `MODELS`，
  由服务端校验，名单外的请求返回 400。
- 停止键停掉正在跑的这一轮。页面关掉或断线不会停掉这一轮，重新打开会接着显示，待答的按钮还在。

## 页面怎么做的（issue #3637）

样子和官网 v2 是一套：配色、字体（Bricolage Grotesque / IBM Plex Sans / IBM Plex Mono，中文落到苹方）、
圆角和 LOGO（一小一大两枚箭头）都取自官网 v2 页面自己的 `:root`，写在
`extras/web-chat/ui/src/theme.css` 一个地方，再映射成 shadcn/ui 的标准变量。官网只有深色；
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

## 一条对话怎么一直连着

- 「这个人 → 当前 session id」存在 `$FLEET_CONF_DIR/webchat/conversation.json`。每一轮都 resume 它，
  服务重启或断线后也是同一条。
- 每轮结束后记下上下文用量；到窗口的 `FLEET_WEBCHAT_COMPACT_AT`（默认 0.8）时，在两轮之间后台跑一次
  Claude Code 自带的 `/compact`。下一轮会等它跑完。
- `/compact` 失败，或者某一轮报「上下文太长」，就**接力**：新开一个 session，把旧 session 的结尾带进第一句里
  （包在 `<fleet-webchat-relay>` 里，页面上不显示），旧 id 记进 `chain`。页面把整条 chain 的记录连起来显示。
- 这些都是 Claude Code 自己的记录（`~/.claude/projects/<目录>/<id>.jsonl`）。在终端里用
  `cd <目录> && claude --resume <id>` 可以读到、接着用，页面底部写着这条命令。

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
走通一轮放开（BREAK-IT `chat-budget-bypass`）。`--only=socket|budget|local` 只跑其中几段（演练用）。

## 不在这一版

网页终端、文件和图片上传、语音、多人共享一条会话、给 tmux 里正在跑的会话插话、并进入口 `/app`、微信登录。
