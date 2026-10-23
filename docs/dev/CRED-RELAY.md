# 新加坡转发（cred relay）

> EPIC #1967 C7，issue #1974。三条路里的 `relay`：**可信、但探测为不能直连上游**的机器，
> 本机代理（`bin/fleet-cred-proxy.py`，C3）持订阅凭据，经新加坡一台只转发的机器出去。
> 集群里的中心代理（C6）替不可信机器出去时也走它。

## 一句话

转发机**不存、不解析、不记录**任何订阅凭据。每个请求它都先问入口
`GET /v1/relay/check`（Caddy `forward_auth` → 本机核验进程 → 入口）：请求头 `X-Fleet-Relay`
里的通行证对，才放行；订阅的 `Authorization` 原样透传给上游，通行证和所有 `X-Forwarded-*`
在出门前剥掉。入口重启那几十秒里，入口最近核过的通行证照常放行（见「入口重启时」）。

```
会话 ──fcp1.──▶ 本机代理 ──Authorization: <订阅>──────────────▶ 转发机 ──▶ api.anthropic.com
                    │       X-Fleet-Relay: frl1.…                │        chatgpt.com/backend-api
                    │                                            │        auth.openai.com
                    └── 入口 POST /v1/node/relay-credential      └── forward_auth ─▶ 127.0.0.1:2091 ─▶ 入口 GET /v1/relay/check
                        （节点令牌换本登录的通行证）                     （核验进程；只带 X-Fleet-Relay + 路径，不带 Authorization）
```

## 出口探测按会话真走的路判（issue #3364）

本机出口在 Claude / OpenAI 不支持的地区（如 ACK 深圳 `loc=CN`），而这登录的会话经 relay 出去时，
`bin/fleet-node-probe.sh` 不再按本机出口把它关掉：本机判断不合适时，它问本机凭据代理
`fleet-cred-proxy.sh relay-probe`——代理（只有它持通行证）经 relay 对 `/anthropic/v1/messages`、
`/chatgpt/wham/usage` 各发一个**不带凭据**的请求，答各家的状态和 relay 的对端地址；探测再用
`ipinfo.io/<对端>/country` 取 relay 出口。`node-probe.json` 记 `route: relay`、本机 `loc_local`、
`relay_anthropic` / `relay_openai`，`loc` 和 `verdict` 是 relay 那条路的；`anthropic` / `openai`
仍是本机直连的结果（代理路由读它们），代理见 `route: relay` 就先走 relay。relay 出口在不支持地区、
经 relay 被地区拒照样关；relay 拒通行证 / 连不上算 `unreachable`（天气，不关）。没有 relay 的登录
（代理不在、没配 relay、没通行证、机器不可信）记 `route: direct`，规则和以前一样。入口的
compute off / compute_region 文案写成「HK via relay (local CN)」。BREAK-IT `probe-ignores-relay`。

## 入口自己刷新 OpenAI 凭据（R1，issue #1976）

入口设 `CCQUOTA_FLEET_OAUTH_REFRESH_VIA=relay` + `CCQUOTA_FLEET_CRED_RELAY_URL=https://relay.example.com`
后，Codex 的刷新由入口直接 POST 到转发机 `/openai-auth/oauth/token`，不再交给某台管理节点——
长期 refresh token 不进任何机器的内存，管理节点不在线也能刷新。入口给自己签一张通行证
`frh1.<到期>.<HMAC>`（密钥由 `CCQUOTA_FLEET_SESSION_CRED_KEY` 派生，五分钟，每次刷新现签，不落库），
**只开 `/openai-auth/`**。审计里刷新记录写 `refresh_via=relay`；转发机不可达、网关错、拒绝通行证时
回落到 node 路（审计写明 `relay unavailable: <原因>`）。Claude 的刷新仍走 node 路。

prod 入口已开（#2137：`deploy/k8s/overlays/prod/deployment-env.yaml`，base 仍是 `node`）；回滚删掉 overlay 那一条即可。

## 入口的 GitHub 登录换令牌（issue #3392）

深圳集群连 `github.com` 时通时断（`api.github.com` 是通的），网页「用 GitHub 登录」最后一步——
入口 POST `https://github.com/login/oauth/access_token` 换令牌——会 15 秒超时。入口设
`CCQUOTA_GITHUB_OAUTH_VIA=relay`（同样要 `CCQUOTA_FLEET_CRED_RELAY_URL` 和
`CCQUOTA_FLEET_SESSION_CRED_KEY`）后，这一个请求改发到转发机
`/github-oauth/login/oauth/access_token`，带入口自己的 `frh1.` 通行证：

- **只这一条路径**：转发机的 Caddyfile 只给 `/github-oauth/login/oauth/access_token` 建了路由，
  `/github-oauth/` 下别的路径一律 404；入口核验时也只让 `frh1.` 开这一条，`frl1.` / `fcp-h1.` /
  `frq1.` 一律拒。**不是 GitHub 代理**——浏览器跳转的 authorize 页和 `api.github.com` 都不经过它。
- **回落**：转发机 5 秒内没给出 GitHub 自己的回答（连不上、超时、403/404/5xx），入口直连
  `github.com` 再试一次（8 秒）；两条都不通，用户看到原来那句「连不上 GitHub」，总共不超过 13 秒。
  GitHub 自己答了错（如 `bad_verification_code`）就到此为止，不重试。
- **日志**：成功是 `github sign-in: token exchanged through the relay https://relay.example.com`；
  回落是 `github sign-in: relay …: <原因> — trying github.com directly`。
- 不设（或 `direct`）：入口自己直连，和以前一模一样；GitHub 登录没开时这个开关被忽略。

prod 入口已开（`deploy/k8s/overlays/prod/deployment-env.yaml`）；回滚删掉那一条即可。
**转发机要先换上带 `/github-oauth/` 的 Caddyfile 和核验进程**（`fleet-relay-check.py` 的前缀表也加了
这一条），否则请求被 404 / 403，入口每次登录都要多等一次回落。

## 入口自己读订阅额度（issue #2169）

入口设 `CCQUOTA_FLEET_HUB_QUOTA=relay`（同样要 `CCQUOTA_FLEET_CRED_RELAY_URL` 和
`CCQUOTA_FLEET_SESSION_CRED_KEY`）后，每 `CCQUOTA_FLEET_HUB_QUOTA_INTERVAL`（默认 5m，至少 1m）
把保险箱里每个 pool 凭据（github、已暂停、待重新登录的除外）的额度自己读一遍，读数不再依赖节点：

- **Claude**：setup token 经 `/anthropic/v1/messages` 发和节点 `probeToken` 一样的一 token 请求，
  从响应头读 5 小时 / 7 天（`shared/limits`）。每读一次消耗极少量订阅额度，频率可配。
- **Codex**：保险箱的 access token（入口自己刷新）经 `/chatgpt/wham/usage` 读用量
  （`codex.ParseUsage`，和 app-server 读数同一套池 / 窗口命名）。
- **归属**：按凭据自己的 `account_uuid`（Codex 由 id_token 算出；Claude 用导入时记下的，或操作者
  `POST /v1/fleet/credentials {"action":"bind","principal_id":"pool","provider":"claude","account":"icloud","account_uuid":"…"}`
  补上的——不需要密钥，写审计 `bind`）。没有时按 #2104 的名字规则配唯一账号，配不上就不写，**不新建 `win_`**。
- **订阅页**：入口读数在新鲜期内（两轮，至少 10 分钟）就以它为准；转发机不可达 / 通行证被拒时
  回退到节点读数，`/v1/limits` 的 `read_via`（`hub` / `node`）和 `read_note`（入口为什么没读到）写明来源，
  卡片上显示「最后读取 · 入口/节点」。
- **通行证**：另一张 `frq1.<到期>.<HMAC>`（与 `frh1.` 分开派生，五分钟，每次现签，不落库），
  **只开 `/anthropic/v1/messages` 和 `/chatgpt/wham/usage` 两条**，且只在这个开关打开时入口才认。
- 不设（或 `off`）：入口什么都不读、不签也不认 `frq1.`，订阅页和现在完全一样
  （`TestHubQuotaOffChangesNothing`、`TestFleetHubQuota` 固定）。
- **转发机不用改**：`/anthropic/`、`/chatgpt/` 两条路由和 forward_auth 本来就在，核验在入口。
  运维只需在入口加上面的环境变量并重新部署入口镜像。

顺带：Codex「查额度」租约不再续给一直失败的采集端——节点报连续失败 ≥3 次（新 agent 会带
`failures`），或持有租约 15 分钟（或两个租期，取大）没交回一次完整读数（老 agent 也管用），入口就收回租约、
让它歇 30 分钟，换另一个在线采集端。

## 两道闸（取代来源 IP 白名单）

1. **通行证** —— 由入口逐请求核验，不在转发机上：
   - `frl1.…`：**每台机器、每个登录一张**，可信机器的节点用自己的节点令牌领
     （`fleet-relay-cred.sh fetch`）。入口只存它的 SHA-256，放在 fleet 设置
     `fleet.node_relay.<machine>`（与 C1 的 `fleet.node_trust.<machine>` 同表、同一套机器名匹配），
     值是 `<login>:<hash>` 若干个；同一登录重领只替换自己那一张。
   - `frh1.…`：入口自己的通行证，只给它自己经 `/openai-auth/` 刷新 OpenAI 凭据用（R1），和经
     `/github-oauth/login/oauth/access_token` 换 GitHub 登录令牌用（#3392）——`/github-oauth/` 只认它。
   - `frq1.…`：入口自己读额度的通行证，只开 `/anthropic/v1/messages`、`/chatgpt/wham/usage`，
     只在 `CCQUOTA_FLEET_HUB_QUOTA=relay` 时认（#2169，见上一节）。
   - `fcp-h1.…`：入口签给不可信机器会话的通行证（C2）。中心代理（C6）出门时带它。`fcp-h2.…` 是它可本地验签的一版（见下「会话通行证 fcp-h2」）。
     由 C2 的 `verifySessionCred` 核验，并且只放它覆盖的那家：`/anthropic/` 要 claude，
     `/chatgpt/`、`/openai-auth/` 要 codex；经 C2 的路由撤销即刻生效（不走下面的缓存）。
   - 不认：伪造的、被替换的、机器被标为不可信的、机器凭据被撤销的、放在 `Authorization` 里的。
2. **前缀白名单** —— 只有 `/anthropic/` `/chatgpt/` `/openai-auth/` 三条，加 `/github-oauth/` 下的
   `login/oauth/access_token` 一条路径（#3392）（入口核验时也按
   `X-Forwarded-Uri` 再查一遍）；其余一律 404。`/healthz` 不要通行证。**这不是开放代理。**

入口对同一张 `frl1.` 的判断缓存 30 秒（按哈希，不按原文）；领新证、撤销、改可信、撤销机器凭据都会
清空本副本的缓存，其它副本最多 30 秒后跟上。

## 入口重启时（issue #2048）

入口发布、Pod 重建的那几十秒，入口对 `/v1/relay/check` 回 503 或连不上（2026-10-07 05:24Z 实测整站
503）。Caddy 若直接问入口，这段时间经转发的请求全被拒：可信但不能直连的 relay 路、集群中心代理（C6）
的出口一起断。所以 Caddy 不直接问入口，问转发机上一个只听 `127.0.0.1:2091` 的小进程
[`extras/cred-relay/fleet-relay-check.py`](../../extras/cred-relay/fleet-relay-check.py)
（python3 标准库，systemd 单元 [`fleet-relay-check.service`](../../extras/cred-relay/fleet-relay-check.service)），
它再问入口。按（通行证的 SHA-256, 路由前缀）记一张表，只在内存里：

| 入口怎么答 | 核验进程怎么做 |
|---|---|
| 2xx，且距上次 2xx 不到 `RELAY_CHECK_CACHE_S`（30 秒） | 不问入口，直接放行 |
| 2xx | 放行，记下这一刻 |
| 4xx（不认、吊销、不可信、路径不对） | 原样拒，并**删掉**这条——吊销最多 `RELAY_CHECK_CACHE_S` 秒生效 |
| 5xx / 连不上 / 超过 `RELAY_CHECK_TIMEOUT_S`（5 秒） | 入口 `RELAY_CHECK_GRACE_S`（600 秒）内对这张证、这个前缀说过 2xx → 放行，日志记 `grace`；否则 503，日志记 `refused-unavailable` |

- 宽限放行**不续期**：窗口从入口最后一次真说 2xx 算起，入口一直不回来，10 分钟后照样拒。
- 没核过的、入口最后一次说不的、只在别的前缀上核过的（`fcp-h1.` 只覆盖一家），入口不在时一律拒。
- **吊销的边界**：入口在线时吊销 ≤ 30 秒生效（与入口自己的 30 秒缓存同一口径）。只有一种情况更长：
  吊销后 30 秒内入口恰好也停了，核验进程还没机会听到「不」——这张证在入口停着的这段里最多按宽限放行到
  它上次 2xx 后 10 分钟。入口一回来，第一次缓存到期就拒。
- 核验进程只转给入口 `X-Fleet-Relay`、`X-Forwarded-Uri`、`X-Forwarded-Method`；表里只有哈希和时间，
  不落盘；日志只有事件、前缀、入口怎么了、年龄（`hub-down` / `hub-up` 记入口状态的变化），没有通行证。
- 核验进程自己重启会忘掉这张表（重启后第一次问入口时补上），所以别在入口发布时重启它。

上线证据（入口发布期间、之后在转发机上）：

```sh
journalctl -u fleet-relay-check --since '-15 min' | grep -c ' grace '                 # 放行的
journalctl -u fleet-relay-check --since '-15 min' | grep ' refused-unavailable ' | grep -c 'seen=expired'  # 核过却被拒（应为 0）
journalctl -u fleet-relay-check --since '-15 min' | grep -E ' hub-(down|up) '         # 入口停了多久
```

## 吊销名单（issue #3560，EPIC #3500 C18）

上一节的表只在入口说「不」之后才拒：吊销要等缓存到期，入口停着时还按宽限放行。打开吊销名单后，入口记下的
每一次吊销都同时写进一份带版本号的名单，核验进程**先查本地这份**，再走上一节的表：

- 入口：`CCQUOTA_FLEET_REVOCATIONS_TOKEN[_FILE]` 设了就开（不设 = 关，下面的路由一律 404，入口什么都不多写）。
  `GET /v1/relay/revocations?since=<v>&wait=25`（Bearer 这个令牌）——版本不是 `<v>` 就立刻回整份名单，
  是就挂着等，名单一动立刻回，到点 304。条目 `{jti, exp}`（`frl1:<sha256>` 中转通行证、`fcp:<id>` 会话通行证、
  `ssh:<serial>` 连接证书）或 `{machine|principal|login, before, exp}`（这一范围在 before 之前签的一律作废）。
  写名单的：删中转通行证（`fleet.node_relay.<m>` 置空）、吊销会话通行证、收回入场证、
  `POST /v1/fleet/credentials/revoke`（解除时只撤它写的那几条）、`POST /v1/fleet/revocations {serial}`（单张证书）。
  条目过了 exp 就从名单里删，名单不会越来越长。
- 核验进程：有令牌文件就开（`FLEET_RELAY_REVOCATIONS_TOKEN_FILE`，默认 systemd 的
  `$CREDENTIALS_DIRECTORY/revocations-token`），一个线程跟着名单，存进 `$STATE_DIRECTORY/revocations.json`
  （重启后先读它，再按版本续拉）。名单上的通行证**立刻** 403，日志 `revoked`——不管缓存、不管宽限；
  入口停着时照样按手上那份拒。名单超过 `RELAY_REVOCATIONS_STALE_S`（600 秒）没刷新只记 `list-stale`，不拒。
  会话通行证按它自己的 claims（不验签，只用来拒）对 `fcp:<id>` 与范围条目。
- 过渡期**双验**：名单只加拒绝，上一节「每个请求问入口」照旧（frl2 在本地验签，见下一节）。
- 门：托管机器的入口 sshd 按同一份名单（`/v1/node/revocations`，节点令牌）生成 OpenSSH KRL 装上
  `RevokedKeys`（docs/MANAGED-NODE.md §16）。

打开（转发机上）：

```sh
sudo install -d -m 0700 /etc/fleet-relay
sudo sh -c 'umask 077; cat > /etc/fleet-relay/revocations-token'      # 粘贴入口的 CCQUOTA_FLEET_REVOCATIONS_TOKEN，^D
sudo install -D -m 0755 fleet-relay-check.py /usr/local/lib/fleet-relay/fleet-relay-check.py
sudo systemctl edit fleet-relay-check     # [Service] LoadCredential=revocations-token:/etc/fleet-relay/revocations-token
sudo systemctl restart fleet-relay-check
journalctl -u fleet-relay-check -n 5 | grep -E ' start .*revocations=on| list v='
```

演练：docs/BREAK-IT.md `cred-revoked-still-works`、`relay-revocations-hub-down`。

## 只活四小时的中转通行证 frl2（issue #3561，EPIC #3500 C19）

frl1 是一串随机数，入口只存它的哈希，**不过期**：会话里抄走一张，能一直经新加坡出公网，直到被发现、吊销。
入口有中转签名钥匙（`CCQUOTA_FLEET_RELAY_SIGN_KEY[_FILE]`，32 字节 Ed25519 种子，base64；Secret `ccquota`
的 `relay-sign-key`）后，`POST /v1/node/relay-credential {"kind":"frl2"}` 发的是

    frl2.<base64url claims>.<base64url Ed25519 签名>     claims = {v:2, jti, machine, login, principal, iat, exp = iat + 4h}

- 入口只在 `fleet.node_relay.<m>` 里记 `<login>:frl2@<jti>`（不是通行证本身）；重新领一张就顶掉这个登录的上一张，
  置空就是吊销（名单写 `frl2:<jti>`）。不问 kind 的老节点照旧拿 frl1（# compat-1v）。
- 核验进程从名单拿公钥（`relay_pub`，或 `FLEET_RELAY_PUB`），**自己验签**、看 exp、查名单（`frl2:<jti>` 或
  按机器 / 登录 / 人的范围），不问入口：入口 `/v1/relay/check` 上不再有 frl2 的请求，入口停着照常。
  验签用 python3 的 `cryptography`，没有就用装在它旁边的 `fleet_ed25519.py`（仓库 `bin/`）。没有公钥 ⇒ 照旧问入口。
- 换钥（#4138）：入口设了 `CCQUOTA_FLEET_RELAY_SIGN_KEY_PREV[_FILE]` 时名单另带 `relay_pub_prev`，核验进程两把都认，
  名单 10 分钟内报过的钥匙也认（滚动发布新旧副本轮流答）；会话通行证的 HMAC 钥匙同样有 `…SESSION_CRED_KEY_PREV`。
  步骤见 deploy/k8s/RUNBOOK.md「换会话通行证 / 中转签名钥匙」。
- 续：没有定时任务。代理挂通行证时看剩余，**用到时剩不到 20%**、或**到了 80% 处**，在自己的运行目录写
  `relay-want[.<login>]`（一行：原因 · 时间 · jti）；登录自己的 launcher、或共享代理时节点守护（`cred-relay`，
  以该登录身份、按请求跑一次）答它：`fleet-relay-cred.sh fetch --force`，交回代理。没有通行证（`missing`，
  60 → 120 秒翻倍问）和中转拒了（`refused`）也走这条。代理日志里每次请求一行 `relay_want reason=…`、
  每张新通行证一行 `relay_pass_new reason=…`——这就是续签的账：

```sh
sudo grep -hE '"ev": "relay_(want|pass_new)"' /var/log/fleet-cred/*.log | tail   # 每次续签的原因：used / 80% / missing / refused
```

打开（入口先、转发机后都行——没公钥的核验进程照旧问入口）：

```sh
openssl rand -base64 32    # 存进 Secret ccquota 的 relay-sign-key，重启入口：日志 "relay passes are frl2 (4h0m0s each)"
sudo install -m 0644 bin/fleet_ed25519.py /usr/local/lib/fleet-relay/fleet_ed25519.py   # 转发机，核验进程旁
sudo install -m 0755 extras/cred-relay/fleet-relay-check.py /usr/local/lib/fleet-relay/fleet-relay-check.py
sudo systemctl restart fleet-relay-check
```

### 会话通行证 fcp-h2：中转和中心代理也自己验签（issue #3698）

fcp-h1 是 HMAC，钥匙只在入口，中转和中心代理只能每个请求回入口问。入口有中转签名钥匙时，节点问
`POST /v1/fleet/session-cred {"kind":"fcp-h2", …}` 拿到的是

    fcp-h2.<base64url claims>.<base64url Ed25519 签名>     claims 同 fcp-h1，v = 2

用的是**同一把**中转签名钥匙（前缀在签名里，frl2 / fcp-h1 / fcp-h2 互相冒充不了），所以公钥就是名单的
`relay_pub`，中心代理在 resolve 的回答里拿到同一把（`session_pub`，或开机给 `--session-pub` /
`CCQUOTA_CREDPROXY_SESSION_PUB`）。

- 中转核验进程：**名单开着**、有公钥时自己验签、看 exp、看这条路去的服务商在不在通行证的 providers 里
  （`/github-oauth/` 永远不是会话的）、查名单（`fcp:<id>` 或机器 / 人范围），不问入口。没名单或没公钥 ⇒ 照旧问入口。
- 中心代理：伪造、过期的当场 403，不问入口；好的照旧问 resolve 拿账号绑定和访问令牌（≤ 30 秒缓存）。
- 入口 `/renew`、`/verify`、`/v1/relay/check`、resolve 两种都认；续签保持原来的种类。节点（`fleet-session-cred.sh`）
  总是问 fcp-h2，没钥匙的入口、老入口照旧发 fcp-h1（# compat-1v）。没钥匙 ⇒ 一字不变。

做完 frl2 + fcp-h2 后，中转访问日志里 `/v1/relay/check` 的调用应归零（C18 的判据）：

```sh
sudo grep -c 'GET /v1/relay/check' /var/log/caddy/access.log   # 换版后应只剩不带名单的老核验进程
```

演练：docs/BREAK-IT.md `cred-leaked-from-session`。

## 凭据在哪

| 东西 | 在哪 | 谁能看到 |
|---|---|---|
| 订阅凭据 | 可信机器上（本机代理读），中心代理在集群里 | 转发机只转发 TLS 里的这个头，不解析、不记录 |
| `frl1.` 通行证 | 机器上 `$FLEET_CONF_DIR/cred-proxy/relay.token`（0600，目录 0700） | 本机代理；不进配置、argv、日志、会话环境 |
| 通行证哈希 | 入口 `fleet.node_relay.<machine>` | 设置接口只显示「哪些登录持有」，不显示哈希 |
| 转发机 | 只有 Caddy 配置（无任何密钥） | — |

`FLEET_CRED_RELAY_TOKEN`（secrets.env）仍可手工指定，优先于领来的那张；一般不用。

## 机器这一侧

`fleet.conf` 的 `[common]`：

```sh
FLEET_CRED_RELAY_URL=https://relay.example.com
```

代理要通行证时节点守护以那个登录跑的 `cred-relay`（`fleet-cred-proxy.sh relay-tick`；客户端电脑上 `ensure`；每登录的启动器 `run` 已随 #4674 删掉）发现配了转发、又没有
`FLEET_CRED_RELAY_TOKEN` 时，自己跑 `fleet-relay-cred.sh fetch`：入口还认就保留（`KEPT`），
不认了就重领；之后只在代理请求时再领（`relay-want`：没有、快用完、到 80%、被中转拒，#3561——不再定时复核）。代理每个请求现读这个文件，
重领不用重启。没有通行证时 relay 路不参与选路（`route` 的说明里写「no relay pass」）。

```sh
fleet-relay-cred.sh fetch [--force]    # 领 / 复核本登录的通行证
fleet-relay-cred.sh check              # 入口现在还认不认（exit 3 = 不认）
fleet-relay-cred.sh path               # 放在哪
```

## 撤销（运维）

```sh
export CCQUOTA_VIEWER_TOKEN=…          # 只从环境读
fleet-relay-cred.sh status             # 哪些机器、哪些登录持有
fleet-relay-cred.sh revoke m9          # 这台机器所有登录的通行证立即作废
fleet-node-trust.sh set m9 untrusted   # 标为不可信，同样立即拒绝（并且领不到新的）
```

接口层面：运维的 `PUT /v1/fleet/settings {"key":"fleet.node_relay.<machine>","value":""}`；
非空值一律 400（没有手写哈希这条路）。每次领、撤销都在 `fleet_audit` 记一行
（`action = relay_cred`，`ISSUE <login>` / `REVOKE <n>` / `DENY <原因>`）。

## 转发机的配置

整份 Caddy 配置就是 [`extras/cred-relay/Caddyfile`](../../extras/cred-relay/Caddyfile)，自检
`bin/fleet-relay-cred-selftest.sh` 跑的就是这份文件（PATH 上有 `caddy` 或设
`FLEET_RELAY_CADDY` 时；否则用同规则的假转发）。要点：

- `forward_auth @fleet {$FLEET_RELAY_CHECK:127.0.0.1:2091} { uri /v1/relay/check … header_up -Authorization … }` ——
  先到本机核验进程（上一节），它再问入口；核验子请求**不带**订阅、Cookie、`Chatgpt-Account-Id`、
  `X-Api-Key`；`forward_auth` 默认补 `X-Forwarded-Uri`（原始路径，入口按它查前缀）。
- `request_header @fleet -X-Fleet-Relay` —— 通行证不出门。
- 每条 `reverse_proxy` 都 `header_up -X-Forwarded-For/-Host/-Proto`：**机器自己的地址不能递给上游**
  ——它所在的地区正是要绕开的。
- `/chatgpt/*` 改写成 `/backend-api/*`（本机代理的 Codex 基址是 `<relay>/chatgpt/codex`）。
- 流式：`flush_interval -1`。
- 日志 `format filter`：删掉全部请求 / 响应头、地址、TLS 信息，`request>uri` 只留前缀
  （`/anthropic/` 等，未路由的留空）——只剩前缀、状态、字节数、耗时。

占位符都不是密钥（`FLEET_RELAY_SITE`、`FLEET_RELAY_CHECK`、`FLEET_RELAY_LOG`、`FLEET_RELAY_ADMIN`，
以及只给测试用的上游覆盖），可以放在 systemd 的 `Environment=` 里。入口地址 `FLEET_HUB_URL`
现在是核验进程的设置（它的 systemd 单元里），不再是 Caddy 的。

## 上线步骤（在 monorepo 建单，由有转发机钥匙的人执行）

按发起人拍板，**新起一台**，与生产的 `ai-relay-1g` 分开（同配置：Lightsail `micro_3_0`，
2 vCPU / 1 GB / 每月 2 TB，`ap-southeast-1`，Debian 12，每月 7 美元，静态 IP）。

1. 建实例 `fleet-relay-sg`，挂静态 IP；阿里云 DNS 加 A 记录 `relay.example.com`
   （`*.example.com` 有通配，理由同 `doc/review/2026-09-12-ai-gateway-overseas-relay.md`）。
2. 防火墙：22 ← 运维本机 /32；80、443 ← any（fleet 机器在各处、集群出口也要进，门禁靠通行证，不靠来源 IP；
   80 只为 ACME）。
3. **先**装核验进程（Debian 12 自带 python3；没有就 `apt install python3`）：

   ```sh
   sudo install -D -m 0755 fleet-relay-check.py /usr/local/lib/fleet-relay/fleet-relay-check.py
   sudo install -m 0644 fleet-relay-check.service /etc/systemd/system/
   sudo systemctl edit fleet-relay-check   # [Service] Environment=FLEET_HUB_URL=https://<你的入口>（单元里的是占位）
   sudo systemctl daemon-reload && sudo systemctl enable --now fleet-relay-check
   curl -s http://127.0.0.1:2091/healthz                                         # ok
   ```

   再装 Caddy ≥ 2.10（官方 apt 源），把 `extras/cred-relay/Caddyfile` 放到 `/etc/caddy/Caddyfile`；
   `sudo systemctl edit caddy` 写：

   ```ini
   [Service]
   Environment=FLEET_RELAY_SITE=relay.example.com
   ```

   **已经在跑的转发机升级到 #2048**：同样先装、启动核验进程，`curl` 它的 `/healthz` 得 `ok`，
   再换 Caddyfile、reload——顺序反了，Caddy 问一个不存在的 2091，所有请求被拒。
   旧的 `Environment=FLEET_HUB_URL=…` 留在 caddy 里无害，可删。

4. `sudo -u caddy caddy validate --config /etc/caddy/Caddyfile`（**用 caddy 用户**：root 跑会建出
   root 属主的日志文件，caddy 随后起不来——ai-relay 踩过），`sudo systemctl reload caddy`。
5. 验证（不需要任何凭据）：

   ```sh
   curl -s https://relay.example.com/healthz                                  # ok
   curl -s -o /dev/null -w '%{http_code}\n' -X POST https://relay.example.com/anthropic/v1/messages   # 403（没有通行证）
   curl -s -o /dev/null -w '%{http_code}\n' https://relay.example.com/v1/models                       # 404（不是开放代理）
   curl -s -o /dev/null -w '%{http_code}\n' -X POST https://relay.example.com/github-oauth/login/oauth/access_token   # 403（没有通行证；#3392 的路由在）
   ```

6. 一台可信、不能直连的登录：`fleet.conf` 加 `FLEET_CRED_RELAY_URL`，`fleet-relay-cred.sh fetch`，
   `fleet-cred-proxy.sh route` 应读 `relay …`，然后 Claude、Codex 各 PONG 一次（见下）。

## 完成判据 / 上线证据

```sh
# 不能直连的可信登录上（或 node-probe.json 记为 unreachable 来模拟）
P=$(fleet-cred-proxy.sh port); T=$(fleet-cred-proxy.sh mint --account <账号>)
ANTHROPIC_BASE_URL=http://127.0.0.1:$P CLAUDE_CODE_OAUTH_TOKEN=$T \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 claude -p 'Reply with exactly: PONG'

# 转发机上：日志一行（只有前缀 / 状态 / 字节）……
sudo tail -n 1 /var/log/caddy/fleet-relay.log
# ……以及查不到任何订阅凭据片段（日志、配置、整机）
sudo grep -rEc 'sk-ant-|eyJhbGci|Bearer ' /var/log/caddy/ /etc/caddy/ ; sudo grep -rlE 'sk-ant-oat|refresh_token' / --exclude-dir={proc,sys,dev} 2>/dev/null | head
```

## 自检

- Go：`tokenledger/hub/api/fleet_relay_cred_test.go` —— 领证只给可信、有账号、未撤销的机器；
  伪造 / 篡改 / 节点令牌 / 放在 `Authorization` / 被替换 / 撤销 / 不可信一律 403；`fcp-h1.` 只放它覆盖的那家、
  改过声明的和撤销的拒绝；
  路径不在白名单 403；设置接口不露哈希；同机多登录各一张；没领过证时什么都不多（退化）。
- Shell：`bin/fleet-relay-cred-selftest.sh` —— 假入口 + 假上游 + 真 Caddy（或假转发）：领 / 复核 /
  重领；经转发 Claude、Codex、`/openai-auth/` 跑通且上游拿到原样的 `Authorization`、没有
  `X-Fleet-Relay` 和 `X-Forwarded-*`；入口核验从没见过 `Authorization`；拒绝的请求到不了上游；
  转发日志里没有订阅、通行证、路径细节、地址；本机代理（C3）在 relay 路上经转发跑通两家。

## Codex 中心网关的额度选择（T947）

`hub/api/fleet_credproxy_selection.go` 在已有授权候选内选择。来源是按凭据身份保存的
`QuotaSnapshot`（`/wham/usage` 的完整 `account_api` 读取，或收集器的
`account/rateLimits/read` / 局部更新），并读取独立保存的最近读取失败与 429 cooldown。
局部更新保留各窗口原来的观察时间，不能用新快照的时间替旧窗口续命。

**未登记容量时不可精确比较。** 上游协议只有 `used_percent`、窗口时长、reset、套餐名与
credits 标志，没有可跨订阅比较的绝对 token / 请求容量，也没有可信的换算系数。
套餐名相同不证明容量相同；不同套餐也不套倍率。credits 的余额 / unlimited 不被当作
5h 或 7d 订阅容量。因此不按「剩余百分比最大」排序，不声称最大化真实吞吐；诊断明确写
`comparability=no_absolute_capacity`。下节的套餐容量目录可登记经过确认的可比工作单位；
未登记时仍按本节保守规则运行，不从套餐名、价格或旧倍率推导容量。

未启用容量目录时的保守规则如下（常数是策略阈值，不是套餐容量）：

- 授权、暂停、reauth 和凭据去重仍由 `sessionBindChoices` 过滤。自有优先于共享，
  同一所属内 refresh 健康优先；已满账号才按原行为让给其他获授权的未满账号。
- `codex` 主池的 5h（300 分钟）与 7d（10080 分钟）必须都存在，百分比在 0–100，
  无重复窗口、缺 reset、未来观察时间、超出窗口的 reset；两窗各自观察时间均不超过
  10 分钟，最近读取也没有失败。过 reset 后要等新的读数，不能自行补成 100% 可用。
- 两窗各剩至少 20% 为 `usable`，任一窗不足为 `tight`；无可靠读数为 `unknown`。
  同一所属/健康层中依次选择 usable、tight、unknown、limited；全部未知或全部受限
  则保持原有确定顺序，不制造容量。unknown 不是「空闲」。已有未过 reset 的 100%
  读数保守保留 limited；新鲜 blocked 与 429 cooldown 也覆盖正面读数。
- **只有 usable 才有重置利用机会**：5h 距 reset ≤30 分钟，或 7d ≤12 小时。
  同一层内有机会者优先；不比较两个账号的精确余量，也不因一窗快重置就花掉另一窗
  的最后储备。缺容量时这是保守机会利用，不是绝对容量最优或精确容量优化。
- 已绑定的人类 Codex 会话至少保持 10 分钟。只有另一候选已知 usable，且当前
  tight/limited，或当前也是 usable 而另一候选独有重置机会，才主动换绑。
  读数未知本身不证明切换有收益；显式人工绑定不被主动策略覆盖。服务会话保留既有
  yield 逻辑，不使用新的主动换绑。429/授权失效仍走原有故障处理，不受机会型保持阻挡。

阈值依据是保守策略取舍，未经真实订阅压测，也不是上游缓存 TTL 或容量承诺：
10 分钟最短保持限制正常主动切换最多每 10 分钟一次，减少缓存反复失效；同为
10 分钟的读数有效期限制旧观察带来的机会，两个时钟独立，保持期结束不会刷新读数。
20% 是每个窗口自己的保护带，不代表相同 token 储备或保证下一请求一定放得下。
30 分钟 / 12 小时分别约为 5h / 7d 的最后 10% / 7%，把机会限定在窗口末段，
不对两个窗口或不同套餐的价值做精确加权。收益门槛是离散状态变化：恢复双窗保护带，
或两者都有保护带但仅候选临近 reset；百分比多一点、双方都有机会、未知变已知均不足以
单独触发主动换绑。假时钟测试固定保持期前一秒、恰好到期、后一秒，另测新鲜度、
20% 保护带与两个机会窗口的阈值内外。后续调参需要正常业务的脱敏证据另行评估。

### 套餐容量目录与安全预览（T972）

管理员在「订阅池 → Codex 容量路由 / Capacity」登记套餐与档位容量，在订阅详情的
「Register tier / 登记档位」关联该订阅的确认档位。没有账号优先级。provider 检测到的
plan 与管理员登记的 tier 分开显示；登记 plan 或最新配额 plan 与检测 plan 不符时，
诊断为 `plan_mismatch`，不套用容量。明确确认某 plan 不分档时才可登记空 tier；
`prolite` / `promax` 只是 provider 值，没有内置历史倍率。订阅价格与 API 标价均不参与容量。

目录在共享数据库的 `subscription_capacity_head` / `subscription_capacity_revisions`
保存，是 `subscription_plans` 价格目录旁独立的容量证据。保存用 expected revision CAS，
冲突返回 409；同一事务保留完整目录、actor 和时间，跨副本读取同一 revision。
清除某 profile 即移除它后保存；恢复是载入某历史目录，再以当前 revision 保存，
不会抹去审计记录。旧二进制忽略新增表，无需破坏性数据库回滚。

`GET /v1/fleet/plans/capacity` 返回 `{current, history}`，current 与 history 每项为
`{revision, catalog, actor, at}`。`PUT` body 为：

```json
{
  "expected_revision": 0,
  "catalog": {
    "mode": "shadow",
    "profiles": [{
      "plan": "example-plan",
      "tier": "confirmed-tier",
      "pool": "codex",
      "unit": "reference-work",
      "basis": "same confirmed workload and allowance basis v1",
      "source": "https://example.com/verified-capacity-evidence",
      "version": "v1",
      "confidence": "provisional",
      "effective_from": "2026-10-01T00:00:00Z",
      "effective_to": "2027-01-01T00:00:00Z",
      "windows": [{"minutes": 10080, "units": 1}]
    }]
  }
}
```

这是格式示例，**不是任何真实套餐的容量声明**。确认套餐档位或月费并不确认数字容量比；不从价格换算容量，也不自动填入官方倍率。运营者可明确登记低置信度相对工作量估计：`confidence: "provisional"`，`source` 写实际运营确认来源（不是未经确认的官方容量声明），`basis` 写明共同工作基准与估计性质，并登记版本、生效时间；预览保留这些字段。`verified` 只用于容量依据本身已确认的情况。

可作为人工登记初始估计的官方来源（不是内置配置）：

- [OpenAI 社区 Pro 100 USD 公告](https://community.openai.com/t/introducing-new-100-month-pro-tier/1378752)：2026-04-09 的首帖说明相对 Plus 的 Codex allowance 为 5 倍；临时 10 倍活动已于 2026-05-31 结束，不能继续作为基准。
- [OpenAI DevDay 2026 recap](https://openai.com/index/devday-2026-recap/) 的「A new Pro tier」说明 Pro 500 的 allowance 为 Plus 的 25 倍。
- [当前 Pro / Codex 使用窗口说明](https://help.openai.com/en/articles/20001516-managing-usage-with-gpt-6-astra-in-work-and-codex) 说明 Pro 100 / 200 / 500 不设五小时窗口。具体订阅仍须以完整、最新的 `account_api` 快照确认实际窗口。

这些来源可支持「基于官方档位 allowance 的初始估计」，不能证明每周可用 token 或任务数精确为某个值，也不保证不同工作负载下的实测比例。把官方相对 allowance 用作实际周窗口的共同工作单位，仍是管理员明确登记的 **provisional 估计**：保留官方 URL、共同 unit / basis、版本与生效时间，并通过 shadow / 小范围 canary 验证。软件不从价格计算这个比例，不把这些资料自动映射到 provider plan，不预置账号或容量配置。`verified` 也只表示有证据支持登记依据，不表示精确 token 容量；校准仍为 1，等待匹配证据。

安全预览读取当前已保存的真实 quota 快照，不请求推理或重新抓取凭据。`read_via=hub` 是读取路径，不单独证明窗口完整；仅周窗口须同时有完整 `account_api` 证据与明确的 10080 分钟 profile。没有容量 profile 时，旧 `missing_dual_window` 仍诚实显示 unknown；不因档位或月费已确认就臆造基准或缺失的五小时窗口。

字段约束：

| 字段 | 约束 / 含义 |
| --- | --- |
| mode | `off`（默认、原保守选择）、`shadow`（实际请求同 off，仅预览新策略）、`active` |
| profiles | 最多 100 项；精确 `(plan, tier)` 唯一，名称大小写敏感 |
| plan / tier / unit / version | plan、unit、version 必填；1–96 个 ASCII 字母数字及 `._:-`，首字母数字；tier 可空 |
| pool | 仅支持已识别的主池 `codex`；不支持凭空登记模型专属池 |
| basis / source | 必填，分别 ≤256 / ≤512 字节；无首尾空白和换行，说明可比工作负载与确认来源 |
| confidence | `verified` 或 `provisional`；两者在有效期内均可参与估算，provisional 是低置信度运营估计，不代表官方倍率或实际 token/tasks |
| effective_from / effective_to | RFC3339；from 必填，to 可省略，若存在须晚于 from；区间前闭后开 |
| windows | 列出全部预期实际窗口，1–2 项，分钟数只能为 300 / 10080，不能重复 |
| units | 每个窗口的可比工作容量，有限正数，范围 0.000001–1000000000；不是实际 tokens |

一个 profile 可明确只期待 10080 分钟窗口，但必须有完整 `account_api` 读取支持；
transcript / response header 的局部读取不能证明 5h 不存在。缺预期窗口、重复、额外主池窗口、非法值、过期、reset 尚未重新观察，
仍为 unknown；已知满窗继续 limited。局部更新不替旧窗续期。其他模型池不会给主池
增加容量。每个窗口各自保留实际观察年龄与 reset。

`active` 的同一所属、refresh 健康层及 eligible（usable + tight）层内，**只有整个候选组都具有
相同 pool / unit / basis 的已登记估算（保留 provisional/verified）**才按容量比较；混合或未知基准回退到保守的
状态与 reset 机会规则。每个窗口估计剩余为 `units × remaining_percent / 100 × calibration`，
原始估计取全部窗口的最小值。容量 score 逐窗口乘
`1 + 0.25 × (1 − clamp(reset 剩余分钟 / 窗口分钟, 0.05, 1))` 后再取最小值，
再除以 `1 + live_pass_bindings`。reset 加成最多 23.75%，不使用会趋向无穷的倒数。
负载是其他 worker 中持有未过期、未撤销 Codex pass 且仍有该账号绑定的去重人数；
当前 worker 排除，不将其称为正在推理的请求数或实际吞吐。负载查询失败禁用容量排序。

score 距该组最大值 1% 内的候选用 SHA256(worker_id, owner, credential identity)
的稳定 rendezvous 选择，消除微小时间差和字母序偏置；相同输入不会随机翻转。
更大容量自然取得更多新会话，已有活跃 pass 的绑定数则降低它的分配 score。
这里不承诺套餐倍率等于最终会话比例，也不修改授权、自有/共享、健康、暂停与去重边界。
全部已满仍显示 limited，不伪造额度。

自动绑定仍至少保持 10 分钟，仅独立请求边界可主动改变；可比组内还需候选 score
严格大于当前 1.25 倍；limited 可恢复到已知可用账号，缺少可比估算时保留 tight → usable 的保守恢复。未知当前读数不足以证明收益。
不批量搬迁；显式绑定保留，Codex 配额 429 也不覆盖显式绑定。来源引用及已开始的流
仍遵守下文亲和协议，429 仍只影响将来请求，本次推理不重放。

**校准状态诚实保留。** 当前没有证明配额下降与同账号、同池、同窗口计量相匹配的样本，
所以 factor 固定为 1、confidence 为 none、samples 为 0，状态
`pending_matched_observations`。没有自动学习、人工校准系数或跨账号计量推断。
后续若引入学习，须先实现可信窗口前后观察与全部消耗匹配、重置/并发隔离、最小样本及
有界置信度；本次不声称具备该能力。

`POST /v1/fleet/credproxy/preview` body：

```json
{"worker_id":"<fleet UUID>/<session UUID>","new_session":false}
```

只允许管理员，使用真实在线 worker 的 principal、endpoint 和 Codex pass 权限；
不存在/过期 worker 返回 404，矛盾身份 409。不能通过 body 指定别人的 principal 或
endpoint。`new_session:true` 仅在计算中忽略现有 sticky，模拟首次分配。
返回目录 revision、模式、proposed、current_policy、窗口与容量 inputs、所用负载依据，
以及 `mutates_bindings:false`。两种结果都使用 resolve 的同一 chooser；proposed 使用
已保存的 profiles，current_policy 遵守 mode。此接口不 lease、不刷新、不推理、不写
绑定或 affinity，也不会使 profile 生效。显式绑定、保持期与不足收益会显示对应原因。

建议先保存 shadow（或 off）目录，安全预览真实元数据，确认真实套餐和档位的来源、版本、
窗口与单位，再保存 active 做限定会话 canary。回滚保存 mode off，或用最新 revision
清空 profiles；已有绑定不被批量改动，后续独立请求回到保守判断。**T947 未完成的生产
验收仍须由发布负责人在生产完成**，本任务 fixture 和预览不替代旧会话、跨副本、流、
续接与真实发布路径的验收，也不自动标记验收通过。

**可信本地代理的容量路由。** direct/relay 仍走原来的传输判定，不强制走中心代理。
`GET /v1/node/codex-capacity` 只接受本节点认证，按租约同样的 principal、trust、
credsep、compute、撤销及机器/人员 allowlist 限定元数据，去重后返回本节点可用账号的
`{policy, catalog_revision, mode, observed_at, expires_at, accounts, load_basis, mutates_bindings:false}`。
每个 account 包含上述 quota/capacity input、稳定 credential_id、paused 和 conservative
input；不包含凭据，不 lease 或 refresh。消费者再与本 login 实际 held 账号相交，
不会因元数据新增订阅权限。有效缓存最多 30 秒，且不延长正向配额读取或 profile 有效期。
每 tenant 后台线程在到期前刷新（健康时最多 20 秒，5 秒 tick；失败退避 5/10/20/30 秒），
请求和本地 preview 不访问 Hub。冷启动、off/shadow 或不可用时保留原本地 selector 的
百分比、85% ceiling、sticky 和负载回退；未知不是无限。

只有在新会话 mint 时收到 fresh active 策略的 Codex pass 才带签名 enrollment。
已有 pass、已有 sid 的 remint 不因发布而变成新会话。升级交接在旧代理仍在线时，
通过 uid/root 限定 control socket 快照现有 picks，再恢复原绑定。共享代理由 root launcher
在降权到 service role **之前**快照；旧 launchd/systemd 的 `machine refresh` 则复用保护 LIB
中同一 launcher helper，在停止旧服务**之前**快照，避免 bootout 后丢失内存绑定。
快照写入各 tenant 的 role-owned 0600 文件，确认空 picks 会清除旧快照；在线旧代理拒绝、
返回不完整或失败时中止接替/重启，保留旧 listener。冷启动没有旧 listener 时保留已存快照。
不扩大 service role 的 control 权限，不推断历史引用来源，不批量重绑。没有旧进程或快照时，
不能恢复其从未持久化的内存来源记录，旧 pass
继续原兼容路径，发布负责人须验证旧会话。新 enrolled 会话则持久保存带用途的引用 hash
→ 原标签 + **实际 upstream account identity hash**；发送时校验实际载入的凭据身份。
同账号 token refresh 保持亲和，删后复用标签不能继承旧上下文。其已知引用在 off/shadow/
stale 回退期间也不能跟随保守 picker 换账号，来源不明、冲突、身份变更或满额时明确拒绝。
新独立请求才使用容量/保持期/收益规则；来源续接不改当前 sticky。所有本地 Codex 429
只记录将来的 cooldown，原响应原样交付，本次不换订阅或重放；Claude 重试行为不变。

本地 score 使用 Hub 同一 quota 计算与 profile 解析的结果，除以 `1 + local_recent_reservations`。
后者是本机各 tenant 最近 10 分钟的去重 session 预留，实际成功续接会更新活动；
已知死亡 wrapper、撤销或陈旧记录不计入。它不是全局实时并发，也与 Hub live-pass 绑定负载不同。
本地引用与预留只在此 tenant 的保护状态目录持久化，不声称跨机器共享引用。

安全本地预览（从目标 login 执行；root 使用已有 `FLEET_CRED_AS=<login>` scope）：

```sh
bash bin/fleet-cred-proxy.sh capacity-preview --sid t972-shadow-preview
```

返回候选输入、估计单位、source/version/confidence、所选原因与本地负载依据；
`mutates_bindings:false`，不 mint pass、不刷新 Hub、不改变 picks、seen、绑定或引用。
它模拟该 sid 的独立选择和保持期；使用未占用 sid 可模拟新会话。

**请求边界与账号亲和。** 新 HTTP 请求不等于独立上下文。只有可识别的自包含请求
（例如不带引用的完整文字历史）才允许按上述滞后策略重选。`previous_response_id`、
conversation、item/call ID、加密 reasoning/compaction 和 `x-codex-turn-state` /
`x-codex-routing-hint` 必须回到其来源凭据。来源由中心代理观察上游输出后写入
hub 的 `fleet_codex_affinity`，以 worker + 带用途的 SHA256 引用为键，保存所属人与
稳定凭据身份和实际 ChatGPT account ID 的用途隔离摘要；不保存原文、加密正文、header 或 token。代理冷启动、两副本和 pass
续期共享同一记录。引用有效期为最近观察后 30 天；到期、未知、跨来源混合、同一引用发生身份冲突
均明确返回 `409 codex_continuation_unavailable`，保持现有绑定及 revision 不变，不能猜当前绑定就是来源。
这里“维持绑定”不表示将未知续接转发给当前账号。WebSocket 的 GET responses/Upgrade
不在路径授权范围，返回 403，不解析其状态、不选账号、不连接上游。过期身份与
冲突记录保留为墓碑，不能删掉后让重复引用转属另一个账号；此表随已观察引用数增长，
发布容量验收须计入这部分数据库存储。

每次 Codex 请求都向 hub 询问来源，不走仅按 pass 缓存的旧 resolve 或 stale fallback；
hub 不可用时返回 503。新代理要求 hub 明确回传 `codex_affinity_v1` 能力；旧 hub
忽略未知 wire 字段而返回普通 lease，也不能被误当成已经登记来源。来源账号仍须通过 allowlist、暂停、reauth、refresh 健康与
cooldown 检查，替换同名凭据或改变同一 OAuth 身份的 workspace/account ID 都不继承旧引用；
缺少实际 account ID 的 lease 不能提供续接保证，拒绝发送推理。续接只取得该来源的 lease，不覆盖较新的
sticky 或人工绑定。旧 `request_boundary` boolean 不再触发主动重选；旧消费者仍可
resolve，但没有证明上下文独立的能力。

每个请求拿自己的凭据快照，流开始后不替换 token、不取消流、不重启 Agent。两个
副本可跨版本并发：A 的旧流继续到结束，B 上的独立请求正常进行；A 的后续续接仍回
A。绑定更新使用 revision CAS，较旧决定不能覆盖另一个请求或人工操作。来源记录必须先于引用交付：SSE 按事件登记再原字节转发；普通 JSON 最多缓冲 8 MiB。
上游请求协商 identity 编码，非预期的压缩响应拒绝。登记失败或超出事件/响应边界时
终止该响应，不交付未登记状态、不重放推理；已交付的流内容仍不可撤回。这增加 hub
依赖和事件延迟，必须纳入发布验收。

**兼容限制与发布前提。** 这是保守协议，不保证未知请求结构可自动移植。当前识别
文字/内嵌图片、function/custom tool、reasoning/compaction 与上述显式引用；未知
输入项、未知顶层字段、压缩请求体、外部 file/vector-store 依赖明确拒绝。引用上限
每请求 4096 个，数据库批量读写；不截断后猜测。超出解析上限的上游响应停止交付；未观察到的输出，其后续引用拒绝。
上线前生成的 opaque 历史没有来源记录，不可默认为当前账号；因此现存会话是否可继续
必须在正式发布验收中评估。不得以删除历史、剥离 opaque 内容、重放或重启 Agent 来
伪造可移植性。生产 rollout 必须先确认所有中心代理支持本协议，再开放会改变绑定的
流量；混用旧代理的缓存不能保证亲和。

依据：OpenAI 官方 [conversation state](https://developers.openai.com/api/docs/guides/conversation-state)
和 [compaction](https://developers.openai.com/api/docs/guides/compaction) 文档说明这些
对象携带续接状态，未承诺跨订阅账号可移植。本机 Codex 0.162.1 对应源码
`codex-rs/core/src/client.rs` 的 `ModelClientSession` 也明确约定 turn-state 只在同一
turn 内复用，auth ownership 变化时清除。网关不能替 Agent 清除或重建其状态。

Codex 的配额 429 仍记 cooldown、选择其他候选，但本次原样返回 429，**不跨账号重放**。
下一次独立请求才使用新绑定。401 access 刷新仍记录拒绝并更新健康状态，但刷新结果也
仅供下一次独立请求使用，本次返回原始 401；即便是同账号也不重放。Codex 的 HTTP
客户端不跟随重定向，向 Agent 返回不带 Location 的 400，且移除请求 body 的自动 rewind 能力。普通请求率 429 不换绑。

这改变了 Codex 已知配额拒绝后的重试契约，与请求开始时的主动机会策略分开验收：

| 场景 | T947 前 | T947 后 |
| --- | --- | --- |
| Codex 明确额度 429，有替代账号 | cooldown、换绑并同请求重发一次，caller 可能收到成功 | cooldown、换绑；caller 收到原始 429 正文及 Retry-After；下一独立请求使用新绑定 |
| Codex 普通请求率 429 | 原样返回，不换绑 | 保持该行为，不制造额度 cooldown |
| Codex 401 access 拒绝 | 刷新后可能同请求重试 | 仍报告拒绝/刷新健康，本次原 401 返回，不重放；新凭据供下一请求 |
| Claude 明确额度 429 | 可换绑并重发一次 | 保留既有契约 |
| Codex 主动机会选择 | 已有 sticky 保持 | 仅独立请求且满足最短保持/收益门槛时 CAS 换绑；未发生推理重试 |

`TestCodexSelection429Contract` 用真实 hub 和隔离假上游分别验证额度/普通 429：
原响应状态、正文与 Retry-After、单次上游调用、凭据身份 cooldown 及其 reset 边界、
绑定 revision、下一独立请求的账号与原始正文。Claude 的旧重发契约另由
`TestCredProxyRebindsOnQuota429` 固定，不能作为 Codex 不重放的证据。
`TestCodexQuotaCASTwoReplicas` 使用同库两个独立 Store 连接，显式安排获胜提交后
旧 revision 的反向决定到达，重复 CAS loser 均重读已提交账号/revision/保持时间，
不能倒退，也不能覆盖人工绑定；API 的并发与保持期测试另验证不抖动。

日志 `credproxy selection` 带策略版本、窗口观察年龄、窗口有效性、剩余百分比、reset、
健康层、可比性与选择/维持原因；不记录 access/refresh token、原始读取报错、请求正文或
请求头。`minimum_hold`、`no_known_safe_alternative`、`explicit_binding` 等原因可以解释
为什么没有切换。此策略不触发额外额度探测。

验收使用 `TestCodexQuota*`、`TestCodexSelection*`、`TestCodexContinuation*` 和现有 `TestCredProxy*` / `TestCredPolicy*`，
假时钟、临时数据库和 loopback 假上游；`codex-quota-sticky` 和 `codex-continuation-account` 是 BREAK-IT 入口。不得以真实
订阅请求做压力测试。**合并不是生产启用**：需正常发布 hub 与中心代理；仅 hub 更新时
旧代理不会触发已有 sticky 的机会型重选。发布后通过正常业务请求的脱敏选择日志核对
版本、双窗口状态、保持原因和绑定变化，不为验收额外花订阅额度；发布结果独立记录。
