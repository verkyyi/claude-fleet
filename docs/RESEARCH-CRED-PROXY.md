# 研究：订阅凭据不落到会话里——本机凭据代理（issue #1872）

实测日期 2026-10-06 · 本机 macOS 27.0 · Claude Code 2.1.292 · codex-cli 0.160.1 ·
原型 [`extras/cred-proxy/`](../extras/cred-proxy/)（不进安装包、不接任何启动路径）。

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

**Codex：未能端到端实测。** 代理把请求送到了 `chatgpt.com/backend-api/codex/responses`，上游认出注入的是
一个真实用户的 token，但本登录 `~/.codex/auth.json` 的 token 已被上游作废（`token_revoked`），本登录也没有
注册任何 fleet Codex 账号；按约束不触发登录 / 刷新。

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
| 10 | Codex | ⚠️ 未实测通 | 路由 + 改写打到上游认证层；本登录 Codex token 已作废 |
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

## 10. Codex ⚠️ 未能端到端

配置（`CODEX_HOME` 全新、无 `auth.json`）：

```toml
model_provider = "fleetproxy"
[model_providers.fleetproxy]
name = "fleet cred proxy"
base_url = "http://127.0.0.1:18787/codex"
wire_api = "responses"
env_key = "FLEET_PROXY_CRED"          # 值 = 会话凭据
```

`codex exec` 发 `POST /codex/responses`，带 `Authorization: Bearer <会话凭据>`、`originator`、`session-id`、
`x-codex-turn-metadata` 等；代理换成 `Authorization: Bearer <auth.json access_token>` 并补
`chatgpt-account-id`，转给 `chatgpt.com/backend-api/codex/responses`。上游回：

```
401 Encountered invalidated oauth token for user … auth error code: token_revoked
```

对照：同一端点用乱写的 token 回 `401 Could not parse your authentication token`。即**改写后的请求已经到达
上游认证层、被认作某个真实用户的 token**，只是这个 token 已被作废（JWT 的 `exp` 还有 185 h，但 refresh
已在别处发生；`refresh_token` 只是 11 字节占位）。本登录 `fleet-codex-account.sh list` 为空。按约束没有
触发登录 / 刷新。

**怎么测完**：在一个有有效 ChatGPT 登录的机器 / 登录上，用同一份 `config.toml` 跑 `codex exec 'Reply: PONG'`。
待验证点：Codex 用自定义 provider 时请求体是否与 ChatGPT 后端要求一致（`store:false`、`instructions`）、
是否还需要 `OpenAI-Beta` / `originator: codex_cli_rs` 一类头；Codex 的 access token 约 10 天、要
refresh，refresh 必须是代理（或入口）的事，会话里没有 refresh token。

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
- **Codex 未验证**（§10）。
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
6. **Codex 实测 + 接入**：先在有有效 ChatGPT 登录的机器补完 §10，再决定 Codex 走不走代理。
