# 研究：订阅凭据不落到会话里——本机凭据代理（issue #1872）

实测日期 2026-10-06 · 本机 macOS 27.0 · Claude Code 2.1.292 · codex-cli 0.160.1 ·
原型 [`extras/cred-proxy/`](../extras/cred-proxy/)（不进安装包、不接任何启动路径）。
§10 Codex 由 issue #1912 补完（同日，假 ChatGPT 后端 [`extras/cred-proxy/sim/`](../extras/cred-proxy/sim/)）。

## 结论

**Claude Code：有条件可行。** 会话只拿一个代理签发的会话凭据（`fcp1.…`），代理在本机把它换成真
订阅凭据——一问一答、交互多轮、工具调用、Opus、`/model`、流式、服务端工具（web search）、限额、
三会话并发全部照常，延迟无可测差别，**还能不重启换号**。条件有三：

1. 会话凭据要放在 **`CLAUDE_CODE_OAUTH_TOKEN`**（不是 `ANTHROPIC_AUTH_TOKEN`），Claude Code 才留在
   订阅模式、给状态线 `rate_limits`；同时设 **`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`**，否则它会把
   会话凭据直接发给 `api.anthropic.com` 的 bootstrap / 特性开关 / 遥测（绕过 base URL，401）。
2. **只有代理跑在另一个系统用户下才真的藏住凭据。** 同 uid 时会话照样能读
   `~/.config/claude-fleet/accounts/*.hub/.credentials.json`；代理只挪走了「环境变量 / 会话配置目录」里的那份。
   本机有免密 sudo，能建用户，但本单未建（见 §11）。
3. 代理成为每个会话推理的单点：它挂 = 本机所有会话停。

**Codex：模拟通过，真机待确认 4 点**（issue #1912，§10）。本登录仍没有有效的 Codex 凭据（入口租约写进
`~/.codex/auth.json` 的 token 上游回 `token_revoked`），所以在代理上游位置放了一个假 ChatGPT 后端，用真
`codex` CLI 0.160.1 跑「Codex → 代理 → 假上游」：`exec` 回 PONG、交互 TUI 多轮 + shell + apply_patch、
流式、限额、rebind、刷新、并发、坏凭据、旁路审计全部通过（`simtest.py` 16/16）。代理只需换
`Authorization` + 补 `chatgpt-account-id`，请求体不改；Codex 配 `plugins=false apps=false
analytics.enabled=false` 后不再有任何流量绕开 base URL。剩下只有上游才能回答的：它收不收自定义 provider
形状的请求（无 `instructions`、无 routing 头）、限额头的真名真值、真实延迟、刷新是否作废旧 token——
`sim/real-check.sh` 一条命令复核。

### 结论表

| # | 问题 | 结论 | 一句话 |
|---|---|---|---|
| 1 | `claude -p` / 交互多轮 + 工具 | ✅ | `-p` 回 `PONG`；交互会话跑了 Bash、Web Search、多轮 |
| 2 | 最小改写头集合 | ✅ | 换 `Authorization: Bearer <真>` + 删 `x-api-key`；`oauth` beta 不需要 |
| 3 | Opus / `/model` | ✅ | opus/sonnet/haiku 都通；`/model sonnet` 后下一问答 `claude-sonnet-5-5` |
| 4 | 流式 + 延迟 | ✅ | 6×6 次：TTFB 中位 直连 472 ms / 代理 453 ms，SSE 事件与结尾完整 |
| 5 | 限额头 → `@rl*` | ⚠️ | 头全部透传；模式 B（`CLAUDE_CODE_OAUTH_TOKEN`）状态线有 `rate_limits`，模式 A 没有 |
| 6 | 绕过代理的流量 | ⚠️ | bootstrap / eval / event_logging / mcp-registry / 更新检查直连；关非必要流量后只剩推理 |
| 7 | 不重启换凭据 | ✅ | `rebind` 后下一请求换账号，状态线 7d 从 6% 变 69%（另一个账号的） |
| 8 | ≥3 会话不串号 / 坏凭据报错 | ✅ | 3 会话 3 账号并发无串号；坏凭据 → `API Error: 401 cred-proxy: <原因>` |
| 9 | 会话里找不到真凭据 | ✅（同 uid 下 ⚠️） | env / `ps -E` / 会话文件 / 新文件 0 命中；但同 uid 能读账号目录 |
| 10 | Codex | ✅ 模拟通过 · 真机待确认 4 点 | 假上游上 `codex exec` 回 PONG、TUI 多轮 + 工具、限额、rebind、刷新、并发全通；只改 `Authorization` + `chatgpt-account-id`；本登录无有效 Codex 凭据（#1912） |
| 11 | 单独系统用户 | 未实测 | 有免密 sudo，可建；未建，步骤见下 |
| 12 | 会话凭据怎么发 | 建议 | 不直接复用 `FLEET_WORKER_CRED`；由代理签、wrapper 领、与会话同生同灭 |

---

## 怎么测的

- 代理 `extras/cred-proxy/cred_proxy.py serve --port 18787`（只绑 127.0.0.1，测完已停）。
- 每个被测会话都用 `env -i` 起：全新 `CLAUDE_CONFIG_DIR` / `CLAUDE_SECURESTORAGE_CONFIG_DIR`（空目录，
  无 keychain 项、无 `.credentials.json`），`ANTHROPIC_BASE_URL=http://127.0.0.1:18787`，会话凭据放
  `ANTHROPIC_AUTH_TOKEN`（模式 A）或 `CLAUDE_CODE_OAUTH_TOKEN`（模式 B）。
- 交互会话跑在隔离 tmux 套接字（`tmux -L cpscratch`）上。
- 「绕过 base URL 的流量」：代理同时充当 `HTTPS_PROXY`，CONNECT 一律记录；再用一张只活 2 天、只在
  scratchpad 的自签 CA（`NODE_EXTRA_CA_CERTS` 只给被测进程）终结 TLS，只记方法 / 路径 / 状态 /
  认证头**长度**。
- 真 token 只在代理 / 测试脚本的内存里，从现有账号文件读，不复制；所有输出都打码。账号：icloud、gmail、
  ly297（只读，未改任何账号）。

## 1. 一问一答 + 交互多轮 ✅

```
$ env -i … ANTHROPIC_BASE_URL=http://127.0.0.1:18787 ANTHROPIC_AUTH_TOKEN=fcp1.eyJ… claude -p 'Reply with exactly: PONG'
PONG
proxy: {"ev":"fwd","sid":"t1","acct":"icloud","m":"POST","path":"/v1/messages","status":200,
        "ttfb_ms":1954,"hdrs_in":[…,"authorization=<redacted:136>",…],"sent":[…,"authorization",…]}
```

交互会话（隔离 tmux）：Bash 工具调用、Web Search（服务端工具，走 `/v1/messages`）、`/model` 切换、多轮，
共 9 次 `/v1/messages` 全 200。会话里跑 `env | grep -i token` 看到的是：

```
ANTHROPIC_BASE_URL=http://1...
ANTHROPIC_AUTH_TOKEN=fcp1.eyJ...
```

## 2. 最小改写头集合 ✅

直接打 `api.anthropic.com/v1/messages`（haiku，`max_tokens 5`）：

| 发送 | 结果 |
|---|---|
| 只 `x-api-key: <订阅 token>` | 401 `API key is invalid.`（即 #495 的 apiKeyHelper 死路） |
| 只 `Authorization: Bearer <订阅 token>` | **200** |
| Bearer + `anthropic-beta: oauth-2025-04-20` | 200 |
| Bearer + oauth beta + 任意 `x-api-key` | 401 `invalid x-api-key` —— **`x-api-key` 必须删** |
| Bearer + `claude-code-20250219`（无 oauth beta） | 200 |

另一条上游规矩（与代理无关，但决定了代理**不能改请求体**）：Opus / Sonnet 用订阅 token 时，请求体里没有
Claude Code 的 system prompt 就回 `429 rate_limit_error "Error"`，有就 200。Claude Code 自己会带，所以代理
原样转发即可。Claude Code 启动时那次 279 字节的探测请求本来就会 429（它不带 system prompt），无影响。

用 `--no-beta` 的代理跑真 Claude Code（opus）也 200。**最小集合 = 设 `Authorization: Bearer <真 token>` + 删
`x-api-key`，其余头和请求体原样。** 原型默认仍补 `oauth-2025-04-20`（无害，防上游哪天又要它）。

## 3. Max 档模型 / `/model` ✅

```
claude -p --model opus   → claude-opus-5-5
claude -p --model sonnet → claude-sonnet-5-5
claude -p --model haiku  → claude-haiku-4-5-20251001
交互: /model sonnet → "Set model to Sonnet 5.5"；下一问 → claude-sonnet-5-5
```

## 4. 流式 + 延迟 ✅

同一个流式请求（haiku，数 1 到 60），直连 / 代理交替各 6 次（`latency.py`，每次新连接，公平）：

| | TTFB 中位（最小–最大） | 总时长中位 | SSE 事件数 | `message_stop` | 文本完整 |
|---|---|---|---|---|---|
| 直连 | 472 ms（444–496） | 978 ms | 26–27 | 6/6 | 6/6 |
| 代理 | 453 ms（438–484） | 955 ms | 26–27 | 6/6 | 6/6 |

差别在噪声内。代理按 `read1` 逐块转发、逐块 flush，交互会话里长输出（Web Search 那次 26 KB、6.7 s）也是边到边显示。

## 5. 限额头 → 状态线 `@rl*` ⚠️（模式 B ✅）

代理把 `anthropic-ratelimit-unified-{5h,7d}-{utilization,reset,status}`、`…-representative-claim`、
`…-overage-*`、`…-fallback-percentage` 全部原样透传（日志 `rl` 字段可见）。但 Claude Code 是否把它们交给
状态线，取决于它**认为自己是什么认证**：

| 模式 | 横幅 | statusLine JSON `rate_limits` | `/status` |
|---|---|---|---|
| A：`ANTHROPIC_AUTH_TOKEN=<会话凭据>` | `API Usage Billing` | **null** → fleet `@rl*` 空 | `Auth token: ANTHROPIC_AUTH_TOKEN`；Usage 页按 API 计价显示美元 |
| B：`CLAUDE_CODE_OAUTH_TOKEN=<会话凭据>` | `Claude API` | `{"five_hour":{"used_percentage":2,…},"seven_day":{"used_percentage":6,…}}` | — |

**用模式 B。** `/status` 另显示 `Managed settings (remote): not fetched — not available with a custom
ANTHROPIC_BASE_URL`、`Organization policy: not fetched`——有自定义 base URL 时远程托管设置不拉取，这对 fleet
无影响（fleet 不用它）。备选：代理本身就看得到每个会话、每个账号的限额头，可以直接当 `@rl*` 的第二个喂入方
（`conf/statusline.sh --from …`），比各会话自报更准——EPIC 拆分里列为可选项。

## 6. 推理之外的地址 ⚠️

代理兼当 `HTTPS_PROXY` 审计到的（交互会话，打开 TLS 嗅探）：

| 目的地 | 走 base URL？ | 模式 A 带什么认证 | 模式 B 带什么认证 → 结果 |
|---|---|---|---|
| `POST /v1/messages`（含 web search 等服务端工具） | ✅ 走代理 | 会话凭据 → 代理换真 | 同左 |
| `GET /api/hello`（连通探测） | ✅ 走代理 | 无 | 无（原型放行，不加凭据） |
| `GET api.anthropic.com/api/claude_cli/bootstrap` | ❌ 直连 | — | **会话凭据** + oauth beta → 401 |
| `POST api.anthropic.com/api/eval/sdk-…`（特性开关） | ❌ 直连 | — | **会话凭据** → 401 |
| `POST api.anthropic.com/api/event_logging/v2/batch`（遥测） | ❌ 直连 | 无 → 200 | 有一批带**会话凭据** → 401，其余无凭据 200 |
| `GET api.anthropic.com/mcp-registry/v0/servers` | ❌ 直连 | 无 → 200 | 无 → 200 |
| `GET downloads.claude.ai/claude-code-releases/latest`（更新检查） | ❌ 直连 | 无 → 200 | 无 → 200 |

`count_tokens`、OAuth profile、`/api/oauth/usage` 本次没出现（setup token 只有 `user:inference`
作用域，今天的 fleet 会话本来就拿不到 profile）。影响：bootstrap / 特性开关失败 = Claude Code 用内置默认
（会话本身正常，上面全部测试都在这种状态下通过）；遥测部分丢失。**问题在于会话凭据被直接发给了
Anthropic**——它在那边没用，但这是凭据外流。

**解法已验证**：加 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`，模式 B 的 `claude -p --model opus` 全程只剩
一次 `POST /v1/messages`（经代理，200），没有任何直连。

## 7. 不重启换凭据 ✅ ——比 `migrate` 关窗重开更好

模式 B 交互会话运行中：

```
$ cred_proxy.py rebind --state … --sid t2 --account gmail
rebound t2 -> gmail
（会话里再问一句）
proxy: t2 icloud 200 / t2 icloud 200 / t2 gmail 200 / t2 gmail 200
statusLine rate_limits: 之前 seven_day 6%（icloud）→ 之后 seven_day 69%（gmail）
```

会话无感继续，状态线立刻反映新账号。这意味着今天的「`fleet-account.sh migrate` 关窗 + `--resume` + 提示
重新定向」可以变成「代理改一行绑定」：不丢回合、不打断正在跑的工具、`/loop` 窗口也能换。代价：换号后第一
次请求的提示缓存在新组织里不命中（整段上下文重新写缓存，一次性成本）。同理，凭据刷新（setup token 到期、
入口换发）只要代理读到新文件，会话下一次请求就用新的——代理本来就是每请求读一次文件。

## 8. 并发不串号 + 坏凭据 ✅

三个会话同时 `claude -p`，各自凭据绑不同账号：

```
c1 -> SESSION-1    proxy: c1 icloud 200
c2 -> SESSION-2    proxy: c2 gmail 200
c3 -> SESSION-3    proxy: c3 ly297 200
```

坏凭据时会话看到的（代理的错误体原样显示，Claude Code 先按 401 重试若干次，约一两分钟后放弃）：

```
[过期]   Failed to authenticate. API Error: 401 cred-proxy: session credential expired
[伪造]   Failed to authenticate. API Error: 401 cred-proxy: bad signature
[撤销]   Failed to authenticate. API Error: 401 cred-proxy: session credential revoked
[账号无凭据] API Error: 503 cred-proxy: no upstream credential for account nosuch. This is a server-side
         issue, usually temporary — try again in a moment. If it persists, check your inference gateway (127.0.0.1:18787).
[非会话凭据] Failed to authenticate. API Error: 401 cred-proxy: malformed session credential
```

（伪造签名那次代理收到 8 次请求、跨 73 s——这是 Claude Code 的 401 重试节奏。EPIC 里应让 wrapper 在凭据
将到期前续签，别让会话撞上这段重试。）

## 9. 会话里找不到真凭据 ✅（但同 uid 有上限）

模式 B 交互会话运行中（`scan` 拿所有账号的真 token 在内存里比对，只输出计数）：

```
ps -E of session: chars=611  has fcp1 session cred=True  real-token hits=0  'sk-ant-oat' hits=0
session files scanned=11 real-token hits=0                         # CLAUDE_CONFIG_DIR + cwd
files under ~ newer than test start=11 real-token hits=0           # find ~ -newer
```

会话的 `~/.claude*`、配置目录、keychain（全新 `CLAUDE_CONFIG_DIR` → 没有对应 keychain 项）里都没有。

**但**：代理和会话同一个 uid 时，会话照样 `cat ~/.config/claude-fleet/accounts/*.hub/.credentials.json`、
`~/.codex/auth.json`——本次测试里模型的 Bash 就能列出 `~/.claude*`。代理只把凭据从「每个会话的环境 / 配置」
挪成「一处文件」；要让会话**读不到**，必须 §11。

## 10. Codex ✅ 模拟通过 · 真机待确认 4 点

issue #1872 时这一节停在「改写后的请求到达上游认证层，但本登录 token 已作废」。issue #1912 先找有效凭据，
找不到，于是用假上游把代理侧该验证的全部验证掉。

### 有效凭据：没有（只读检查，未登录、未刷新、未触发入口）

| 来源 | 结果 |
|---|---|
| `~/.codex/auth.json` | 入口租约写的（`auth_mode=chatgpt`，`refresh_token` = 11 字节 `hub-managed` 占位，今天 14:33 写入，JWT `exp` 还剩 183 h）。一次空体 `POST …/codex/responses`（认证在请求体校验之前，不消耗推理）→ `401 token_revoked` |
| `ccquota codex list --json` | 只有 `default`（= `~/.codex`），`login.state: "valid"`、`source: "hub"`——它只看到期时间，**上游已作废的 token 它仍报 valid** |
| `fleet-codex-account.sh list` / `~/.codex-accounts` | `[]` / 不存在 |

### 模拟怎么搭（`extras/cred-proxy/sim/`）

```
codex 0.160.1 ──Bearer fcp1…──▶ cred_proxy.py /codex ──Bearer <access> + chatgpt-account-id──▶ fake_chatgpt.py
 全新 CODEX_HOME，无 auth.json        127.0.0.1                                               127.0.0.1
 env_key = FLEET_PROXY_CRED                │ 每请求读 <homes>/<acct>/auth.json                 /backend-api/codex/responses (SSE)
                                           │（节点 agent 租约写的同一处、同一形状）            /oauth/token（刷新：两枚都轮换，旧 access → token_revoked）
```

- 请求形状不是编的：发请求的就是真 `codex`，假上游只记录（头名 + `<redacted:len>`、请求体字段）并按
  Responses API 回 SSE；工具调用按 Codex 真实提供的工具（见下）回放。
- 一条命令：`python3 -I extras/cred-proxy/sim/simtest.py --codex <codex>`，全部只绑 127.0.0.1，两个服务
  各带 `--max-seconds` 自毁，脚本退出前全停。README 在 `sim/`。
- 代理为此加了 `--codex-upstream`（http 只许 loopback）、`--codex-homes`（账号 → home 与节点 agent
  `codexHomeFor` 同一映射）、`--max-seconds`、`--sinkhole`（离线审计）。

### 结果（`simtest.py` 16/16 PASS，另加一次交互 TUI）

```
$ codex exec --skip-git-repo-check 'Reply with exactly: PONG'   # CODEX_HOME 全新，FLEET_PROXY_CRED=<fcp1 会话凭据>
PONG
rc=0  0.2s
session -> proxy:  authorization=<redacted:135>（fcp1 会话凭据）
proxy -> upstream: authorization=<redacted:375>, chatgpt-account-id=<redacted:16>（acctA 的）
only in upstream: ['accept-encoding', 'chatgpt-account-id']    only in session: []
```

| 问题 | 结论 | 证据 |
|---|---|---|
| `codex exec` PONG | ✅ | 上面；`exec resume --last` 第二轮 `SIM turn 2` |
| 交互多轮 + 工具 | ✅ | 隔离 tmux 里跑 TUI（`--sandbox workspace-write -a never`）：`• Ran echo SIM-SHELL-OK $((6*7)) └ SIM-SHELL-OK 42` → `• Added sim-patched.txt (+1 -0)` → 第二、三轮续上；`exec` 下同样 3 个请求（call、call、final），文件落盘 |
| 最少改写哪些头 | ✅ 两个 | 换 `Authorization`、补 `chatgpt-account-id`（**一律覆写**为绑定账号的——会话自己带 acctB 的 id 也照样走 acctA，`spoof` 检查）。`originator: codex_exec`、`user-agent`、`session-id`、`thread-id`、`x-client-request-id`、`x-codex-beta-features`、`x-codex-turn-metadata`、`x-codex-window-id`、`x-openai-internal-codex-responses-lite: true` 都是 Codex 自带，原样透传；不需要代理补 `OpenAI-Beta` / `originator` |
| 请求体要不要改 | ✅ 不改 | Codex 自带 `store:false`、`stream:true`、`include:["reasoning.encrypted_content"]`；**没有 `instructions`**——responses-lite 把系统指令放成 4 条 `developer` 消息、工具放成一个 `additional_tools` 输入项（`namespace` 分组）。代理按字节转发 |
| 流式 | ✅ | `STREAM 5000`：5005 个 SSE 事件，Codex 输出 5001 词、以 `END-5000` 结尾 |
| 延迟（各 ≥5 次） | ✅ 代理开销 <1 ms | 同一假上游：`codex exec` 墙钟中位 直连 0.17 s / 代理 0.17 s（n=5）；HTTP 首字节中位 0.3 ms / 0.8 ms（n=20）。对真上游的差别要真机测 |
| 限额 → 会话 / fleet 读数 | ✅（`/status` 明细 ⚠️） | `x-codex-primary/secondary-{used-percent,window-minutes,reset-at}` 全透传 → rollout 的 `token_count.rate_limits.primary.used_percent = 11.0`（即 fleet 读的 `tokenledger/internal/scan/codex_telemetry.go`）、`info.total_token_usage` 照常；TUI 底栏 `⚠ 5h limit: 23% left`、`less than 25% of your 5h limit left` 提示。但 `/status` 的 `Limits:` 行是 `data not available yet`——自定义 provider 下 Codex 不去拉 ChatGPT 的 usage 接口，只剩响应头这一路 |
| 不重启换号（rebind） | ✅ | `exec`：同一 thread `resume` 后 `acct=acctB`，限额 11% → 77%；TUI 运行中 `rebind tui -> acctB`，下一轮 `SIM turn 3 acct=acctB`，底栏随即变成 acctB 的 23% |
| 并发不串号 | ✅ | 3 会话同时（各 `SLOW 1500`）绑 A/B/A：`c1 acctA / c2 acctB / c3 acctA`，代理日志一致 |
| 坏凭据时 Codex 看到什么 | ✅（重试节奏 ⚠️） | `ERROR: unexpected status 401 Unauthorized: cred-proxy: session credential expired`（伪造 → `bad signature`，撤销 → `session credential revoked`，非会话凭据 → `malformed session credential`）：每种 6 次请求、约 6 s 后放弃。账号无凭据回 503 → Codex 当暂时故障重试 **30 次、24 s**；正式版应给这种永久失败一个不重试的状态码 |
| 刷新链路 | ✅ | 假「入口保险箱」用自己保管的 refresh token 打 `/oauth/token`（Codex 的公开 client id），改写 `auth.json`；运行中的会话下一请求无感用上新 token，旧 access token 上游已 `401 token_revoked`。会话里从头到尾没有 refresh token（只有 `env_key`，`CODEX_HOME` 无 `auth.json`） |
| 绕过 base URL 的流量 | ⚠️ → ✅（关 3 个开关） | 离线 sinkhole 审计（`HTTPS_PROXY` = 代理 `--sinkhole`，临时 CA 经 `CODEX_CA_CERTIFICATE` 只给被测进程，CONNECT 一律本地答 503，什么都不出本机）。默认配置：`ab.chatgpt.com POST /otlp/v1/metrics`、`chatgpt.com GET /backend-api/plugins/featured`、`…/plugins/export/curated`、`api.github.com GET /repos/openai/plugins`、`github.com` CONNECT——**全部不带凭据**，会话凭据外流 0。加 `[features] plugins = false`、`apps = false`、`[analytics] enabled = false` 后：一个也没有 |
| 会话里找不到真凭据 | ✅（同 uid 上限同 §9） | 运行中会话每个进程的 `ps -E`：会话凭据 2 处、access token 0；`CODEX_HOME` 67 个文件 access token 0 |

顺带修了原型一个 bug：代理在拒绝（401 / 503）时没读走请求体，keep-alive 连接上那段请求体被当成下一个请求
解析，Codex 看到的是 HTML「Bad request syntax」而不是拒绝原因。现在先读体再判断。

### 另外三个发现

1. **TUI 的后台守护进程带着会话凭据活下来。** 交互 `codex` 会起 `codex app-server --managed-daemon`（二进制
   拷在 `CODEX_HOME/packages/…`），TUI 退出后它以 `PPID=1` 留着，环境里有 `FLEET_PROXY_CRED=fcp1…`。
   `codex exec` 不留。所以 §12 的「wrapper 退出时撤销会话凭据」对 Codex 是必须的，不是加固；接入时还要让
   这个守护进程随窗口收掉（`fleet-window-reap.sh` 按锚点认孤儿树，它的 cwd / `CODEX_HOME` 要在锚点里）。
2. **自定义 provider 比原生 ChatGPT 模式安静得多。** 对照：用同一个假上游给原生模式（内置 provider + 假
   `auth.json`，`chatgpt_base_url` 指向假上游）跑同一句，它在推理之前就带着凭据发了 9 类请求——`codex/models`、
   `wham/accounts/check`、`wham/settings/user`、`plugins/featured`、`ps/plugins/{list,installed,suggested}`、
   `ps/mcp`、`codex/analytics-events/events`——并且推理前必须完成 workspace routing discovery
   （`/wham/accounts/check` 返回 `workspace_backend_origin` + `account_routing_override`，之后请求带
   `x-openai-account-routing-override`）；假上游没摸清这个内部格式，原生模式没跑到推理。自定义 provider 下这些
   一个都不发，代理只要一条路由。代价：没有 apps / plugins（`codex_apps` MCP）、没有远程模型列表、`/status`
   没有限额明细（见上）。
3. **默认模型是 code mode。** `gpt-6.1-sol` 只给一个 freeform `exec`（跑 JS），shell 和 apply_patch 是它里面的
   `tools.exec_command(...)` / `tools.apply_patch(...)`；假上游据此回放。对代理没影响（工具全在本机执行），
   但写假上游 / 解析转录时要知道。

### 只有真机才能确认的 4 点

1. **上游收不收自定义 provider 形状的请求**：`x-openai-internal-codex-responses-lite: true` + 无 `instructions` +
   `store:false`，并且**没有** `x-openai-account-routing-override`。原生模式先做 routing discovery 再带这个头；
   个人 Plus/Pro 很可能不需要，Team / Enterprise workspace 若需要，代理就得自己做 discovery 并补头。#1872
   只证明了认证层认 token，没走到这一步。
2. **限额头的真名和真值**：代理全透传、Codex 解析的就是 `x-codex-primary-*` / `x-codex-secondary-*`，但真上游
   今天发不发、发什么，只有真机看得到（顺带看 fleet 的 Codex 读数是否照常）。
3. **真实延迟**：代理本身 <1 ms；对 `chatgpt.com` 的 TTFB 直连 / 代理各 ≥5 次比对。
4. **刷新是否作废旧 access token**：模拟按「作废」处理（更严，代理每请求读文件照样过）。真实环境里刷新由入口
   保险箱做——`tokenledger/internal/credvault/refresh.go`（`refreshForm` 的 Codex 分支，`HTTPRefresher` /
   经 admin 节点的 `ProxyRefresher`），节点 agent `tokenledger/internal/agent/node_creds.go` `writeCodexAuth`
   把新的 access token 写进 `codexHomeFor(<acct>)/auth.json`，代理下一请求读到。本登录今天这份租约 token 已被
   上游作废、`ccquota` 却报 valid，说明入口侧的「谁在刷、旧的何时失效」本身要在真机上查清。

**一条命令复核**（在有有效 ChatGPT 登录的机器 / 登录上；不登录、不刷新，`auth.json` 只在代理内存里读）：

```sh
extras/cred-proxy/sim/real-check.sh default "$(command -v codex)"
```

它起代理（127.0.0.1、600 s 自毁）、签会话凭据、用全新 `CODEX_HOME` + 上面 3 个开关跑 PONG 和一次 shell
工具调用，打印打码后的代理日志（状态、发上去的头、回来的 `x-codex-*` 头）和 rollout 里的 `rate_limits`，
然后停掉。延迟各 5 次就把它跑 5 遍、再用同一 `codex` 不经代理跑 5 遍。

## 11. 代理以单独系统用户运行 —— 未实测

- 能否：`sudo -n true` → 成功（本登录**有免密 sudo**），现有用户 `daemon / minilinux / nobody / root / verkyyi`。
- 为什么没做：建系统账户是持久的整机改动，超出「只研究 + 原型」的范围；也不能把凭据复制给一个测试用户
  （约束：不复制）。
- 步骤（macOS）：

  ```sh
  sudo sysadminctl -addUser _fleetcred -shell /usr/bin/false -home /var/empty -roleAccount   # 隐藏的 role 账户
  sudo install -d -o _fleetcred -m 0700 /var/db/fleet-cred                                   # 凭据目录，仅它可读
  # 入口（ccquota lease）把各账号凭据写到 /var/db/fleet-cred/<acct>.json，而不是 ~/.config/…/accounts/
  # 代理 LaunchDaemon（UserName=_fleetcred）listen 127.0.0.1:<port>，并开一个 0660 的 unix socket
  #   （组 = 会话用户的组）给 wrapper 领会话凭据
  sudo -u verkyyi cat /var/db/fleet-cred/icloud.json      # 预期：Permission denied —— 验收这一条
  ```

  Linux 节点同理（`useradd --system`、systemd `User=`）。需要的权限：建用户、装 LaunchDaemon（root 一次）；
  之后入口下发凭据要写到代理用户的目录，即 `ccquota` 的 lease 由代理用户发起（node token 也随之搬过去）。
- 怎么测：上面最后一行，以及在会话里重跑 §9 的扫描时把 `/var/db/fleet-cred` 加进去，预期全部 `Permission denied`。

## 12. 会话凭据怎么发

**不直接复用 `FLEET_WORKER_CRED`**，理由：

- 它是 HMAC，校验需要密钥，而密钥 `$FLEET_CONF_DIR/worker-cred/key` 是会话用户可读的——同 uid 的会话可以
  自己签出任意 `fwc1`。对 MCP 身份这没关系（同 uid 信任），对凭据代理就意味着能冒用任何会话的账号绑定。
- 它 24 h 到期、靠 MCP server 进程内存续签；而 Claude Code 只在启动时读一次 `CLAUDE_CODE_OAUTH_TOKEN`，
  会话活过 24 h 就会撞上 §8 的 401 重试。

**建议**：

| 项 | 做法 |
|---|---|
| 谁签 | 代理（系统用户）用它自己的密钥签 `fcp1`；会话用户读不到这把钥匙 |
| 谁领 | `fleet-session-wrap.sh` 每次 launch 经 unix socket 向代理领一个，`fid` 即 `FLEET_WORKER_CRED` 里那个 `@fleet_id`（两者对得上），放进 `CLAUDE_CODE_OAUTH_TOKEN` / Codex 的 `env_key` |
| 绑定 | 机器（代理只在本机 loopback）× 会话（`fid` + 签发时的 pane pid）× 账号（代理侧 `bind`，由放置决定，不在凭据里写死） |
| 有效期 | 不设短 `exp`；有效 = 会话活着：wrapper 退出时撤销（同 `--cred revoke`），代理定期对照活着的 `fid` 清理。上限可设 7 天兜底 |
| 风险上限 | 同 uid 的会话仍可向 socket 再领一个——但它最多拿到「本机某个会话的推理权」，拿不到能带出本机、一年有效的 setup token |

---

## 推荐方案

模式 B + 关非必要流量 + 代理系统用户：

```
fleet-session-wrap.sh ──(unix socket)──▶ cred-proxy (_fleetcred) ── 读 /var/db/fleet-cred/<acct>
      │  领 fcp1                               ▲ 换号 = 改 bind，不重启会话
      ▼                                        │
claude  CLAUDE_CODE_OAUTH_TOKEN=fcp1…  ANTHROPIC_BASE_URL=http://127.0.0.1:<port>
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
```

## 剩余风险

- **上游行为可变**：订阅 token 接受哪些头、`/v1/messages` 以外哪些端点要认证，都是未公开约定。今天最小集合不
  需要 oauth beta，明天可能需要——代理补上无害，原型默认补。
- **单点**：代理挂 → 本机所有会话的推理失败（Claude Code 会重试再报 `API Error`）。需要 launchd KeepAlive +
  doctor 行 + break-it 演练（`docs/BREAK-IT.md` 先登记）。
- **base URL 的副作用**：远程托管设置 / 组织策略不拉取；bootstrap、特性开关、遥测关掉后 Claude Code 跑在
  内置默认上（本次所有测试就在这状态下通过）。新版本若把某个必需端点放到 base URL 之外，会出现在 §6 的审计里——
  原型的 `--audit --mitm-cert` 就是回归检查工具。
- **同 uid 未隔离时收益有限**：只防「凭据随环境变量进子进程 / 被转录 / 被 `env` 打印」，不防有意读文件。
- **Codex 只在模拟里验证**（§10）：上游是否接受自定义 provider 形状的请求、Team/Enterprise 是否要 routing 头，
  要真机；TUI 的后台守护进程会带着会话凭据活过会话。
- 提示缓存：换号后首个请求缓存不命中，一次性成本。

## 若做：EPIC 拆分建议

1. **cred-proxy 正式化**（Go，进 `ccquota` 或单独二进制）：每请求读凭据、改写头、流式透传、打码日志、
   `bind` / `revoke` 控制面只走 unix socket；selftest 用假上游。
2. **系统用户 + 凭据目录**：安装器建 `_fleetcred`（macOS）/ 系统用户（Linux），`ccquota lease` 写到它的目录；
   doctor 加 `cred` 行（会话用户读凭据目录必须失败）。break-it 先登记「代理挂了」。
3. **wrapper 领会话凭据**：`fleet-session-wrap.sh` 领 / 撤 `fcp1`，设 `CLAUDE_CODE_OAUTH_TOKEN` +
   `ANTHROPIC_BASE_URL` + `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`，去掉 `CLAUDE_SECURESTORAGE_CONFIG_DIR`；
   开关控制，关 = 今天的样子字节不变。
4. **换号走 bind**：`fleet-account.sh migrate` / 限额轮换在代理开着时改 bind，不关窗；关着时保留今天的路。
5. **代理喂 `@rl*`**（可选）：代理按会话把限额头交给 `conf/statusline.sh --from proxy`，与 ccquota 对账。
6. **Codex 接入**：先在有有效 ChatGPT 登录的机器跑 `sim/real-check.sh` 确认 §10 的 4 点；接入时 wrapper 给
   Codex 写自定义 provider（`env_key` = 会话凭据）+ `plugins/apps/analytics` 三个开关，退出时撤销会话凭据并
   收掉 `app-server --managed-daemon`；selftest 直接用 `sim/fake_chatgpt.py`。
