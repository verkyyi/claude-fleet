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

## 入口自己刷新 OpenAI 凭据（R1，issue #1976）

入口设 `CCQUOTA_FLEET_OAUTH_REFRESH_VIA=relay` + `CCQUOTA_FLEET_CRED_RELAY_URL=https://fleet-relay.24hw.cn`
后，Codex 的刷新由入口直接 POST 到转发机 `/openai-auth/oauth/token`，不再交给某台管理节点——
长期 refresh token 不进任何机器的内存，管理节点不在线也能刷新。入口给自己签一张通行证
`frh1.<到期>.<HMAC>`（密钥由 `CCQUOTA_FLEET_SESSION_CRED_KEY` 派生，五分钟，每次刷新现签，不落库），
**只开 `/openai-auth/`**。审计里刷新记录写 `refresh_via=relay`；转发机不可达、网关错、拒绝通行证时
回落到 node 路（审计写明 `relay unavailable: <原因>`）。Claude 的刷新仍走 node 路。

prod 入口已开（#2137：`deploy/k8s/overlays/prod/deployment-env.yaml`，base 仍是 `node`）；回滚删掉 overlay 那一条即可。

## 入口自己读订阅额度（issue #2169）

入口设 `CCQUOTA_FLEET_HUB_QUOTA=relay`（同样要 `CCQUOTA_FLEET_CRED_RELAY_URL` 和
`CCQUOTA_FLEET_SESSION_CRED_KEY`）后，每 `CCQUOTA_FLEET_HUB_QUOTA_INTERVAL`（默认 5m，至少 1m）
把保险箱里每个 pool 凭据（github、已暂停、待重新登录的除外）的额度自己读一遍，读数不再依赖节点：

- **Claude**：setup token 经 `/anthropic/v1/messages` 发和节点 `probeToken` 一样的一 token 请求，
  从响应头读 5 小时 / 7 天（`internal/limits`）。每读一次消耗极少量订阅额度，频率可配。
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
   - `frh1.…`：入口自己的通行证，只给它自己经 `/openai-auth/` 刷新 OpenAI 凭据用（R1，见上一节）。
   - `frq1.…`：入口自己读额度的通行证，只开 `/anthropic/v1/messages`、`/chatgpt/wham/usage`，
     只在 `CCQUOTA_FLEET_HUB_QUOTA=relay` 时认（#2169，见上一节）。
   - `fcp-h1.…`：入口签给不可信机器会话的通行证（C2）。中心代理（C6）出门时带它。
     由 C2 的 `verifySessionCred` 核验，并且只放它覆盖的那家：`/anthropic/` 要 claude，
     `/chatgpt/`、`/openai-auth/` 要 codex；经 C2 的路由撤销即刻生效（不走下面的缓存）。
   - 不认：伪造的、被替换的、机器被标为不可信的、机器凭据被撤销的、放在 `Authorization` 里的。
2. **前缀白名单** —— 只有 `/anthropic/` `/chatgpt/` `/openai-auth/` 三条（入口核验时也按
   `X-Forwarded-Uri` 再查一遍）；其余一律 404。`/healthz` 不要通行证。**这不是开放代理。**

入口对同一张 `frl1.` 的判断缓存 30 秒（按哈希，不按原文）；领新证、撤销、改可信、撤销机器凭据都会
清空本副本的缓存，其它副本最多 30 秒后跟上。

## 入口重启时（issue #2048）

入口发布、Pod 重建的那几十秒，入口对 `/v1/relay/check` 回 503 或连不上（2026-10-07 05:24Z 实测整站
503）。Caddy 若直接问入口，这段时间经转发的请求全被拒：可信但不能直连的 relay 路、集群中心代理（C6）
的出口一起断。所以 Caddy 不直接问入口，问转发机上一个只听 `127.0.0.1:2091` 的小进程
[`extras/cred-relay/fleet-relay-check.py`](../extras/cred-relay/fleet-relay-check.py)
（python3 标准库，systemd 单元 [`fleet-relay-check.service`](../extras/cred-relay/fleet-relay-check.service)），
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
FLEET_CRED_RELAY_URL=https://fleet-relay.24hw.cn
```

本机代理的启动器（`fleet-cred-proxy.sh run` / `ensure`）发现配了转发、又没有
`FLEET_CRED_RELAY_TOKEN` 时，自己跑 `fleet-relay-cred.sh fetch`：入口还认就保留（`KEPT`），
不认了就重领；之后每 `FLEET_CRED_RELAY_RECHECK_SECS`（1800）复核一次。代理每个请求现读这个文件，
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

整份 Caddy 配置就是 [`extras/cred-relay/Caddyfile`](../extras/cred-relay/Caddyfile)，自检
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

1. 建实例 `fleet-relay-sg`，挂静态 IP；阿里云 DNS 加 A 记录 `fleet-relay.24hw.cn`
   （`*.24haowan.com` 有通配，理由同 `doc/review/2026-09-12-ai-gateway-overseas-relay.md`）。
2. 防火墙：22 ← 运维本机 /32；80、443 ← any（fleet 机器在各处、集群出口也要进，门禁靠通行证，不靠来源 IP；
   80 只为 ACME）。
3. **先**装核验进程（Debian 12 自带 python3；没有就 `apt install python3`）：

   ```sh
   sudo install -D -m 0755 fleet-relay-check.py /usr/local/lib/fleet-relay/fleet-relay-check.py
   sudo install -m 0644 fleet-relay-check.service /etc/systemd/system/
   sudo systemctl daemon-reload && sudo systemctl enable --now fleet-relay-check
   curl -s http://127.0.0.1:2091/healthz                                         # ok
   ```

   再装 Caddy ≥ 2.10（官方 apt 源），把 `extras/cred-relay/Caddyfile` 放到 `/etc/caddy/Caddyfile`；
   `sudo systemctl edit caddy` 写：

   ```ini
   [Service]
   Environment=FLEET_RELAY_SITE=fleet-relay.24hw.cn
   ```

   **已经在跑的转发机升级到 #2048**：同样先装、启动核验进程，`curl` 它的 `/healthz` 得 `ok`，
   再换 Caddyfile、reload——顺序反了，Caddy 问一个不存在的 2091，所有请求被拒。
   旧的 `Environment=FLEET_HUB_URL=…` 留在 caddy 里无害，可删。

4. `sudo -u caddy caddy validate --config /etc/caddy/Caddyfile`（**用 caddy 用户**：root 跑会建出
   root 属主的日志文件，caddy 随后起不来——ai-relay 踩过），`sudo systemctl reload caddy`。
5. 验证（不需要任何凭据）：

   ```sh
   curl -s https://fleet-relay.24hw.cn/healthz                                  # ok
   curl -s -o /dev/null -w '%{http_code}\n' -X POST https://fleet-relay.24hw.cn/anthropic/v1/messages   # 403（没有通行证）
   curl -s -o /dev/null -w '%{http_code}\n' https://fleet-relay.24hw.cn/v1/models                       # 404（不是开放代理）
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

- Go：`tokenledger/internal/api/fleet_relay_cred_test.go` —— 领证只给可信、有账号、未撤销的机器；
  伪造 / 篡改 / 节点令牌 / 放在 `Authorization` / 被替换 / 撤销 / 不可信一律 403；`fcp-h1.` 只放它覆盖的那家、
  改过声明的和撤销的拒绝；
  路径不在白名单 403；设置接口不露哈希；同机多登录各一张；没领过证时什么都不多（退化）。
- Shell：`bin/fleet-relay-cred-selftest.sh` —— 假入口 + 假上游 + 真 Caddy（或假转发）：领 / 复核 /
  重领；经转发 Claude、Codex、`/openai-auth/` 跑通且上游拿到原样的 `Authorization`、没有
  `X-Fleet-Relay` 和 `X-Forwarded-*`；入口核验从没见过 `Authorization`；拒绝的请求到不了上游；
  转发日志里没有订阅、通行证、路径细节、地址；本机代理（C3）在 relay 路上经转发跑通两家。
