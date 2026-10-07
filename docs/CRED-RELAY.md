# 新加坡转发（cred relay）

> EPIC #1967 C7，issue #1974。三条路里的 `relay`：**可信、但探测为不能直连上游**的机器，
> 本机代理（`bin/fleet-cred-proxy.py`，C3）持订阅凭据，经新加坡一台只转发的机器出去。
> 集群里的中心代理（C6）替不可信机器出去时也走它。

## 一句话

转发机**不存、不解析、不记录**任何订阅凭据。每个请求它都先问入口
`GET /v1/relay/check`（Caddy `forward_auth`）：请求头 `X-Fleet-Relay` 里的通行证对，才放行；
订阅的 `Authorization` 原样透传给上游，通行证和所有 `X-Forwarded-*` 在出门前剥掉。

```
会话 ──fcp1.──▶ 本机代理 ──Authorization: <订阅>──────────────▶ 转发机 ──▶ api.anthropic.com
                    │       X-Fleet-Relay: frl1.…                │        chatgpt.com/backend-api
                    │                                            │        auth.openai.com
                    └── 入口 POST /v1/node/relay-credential      └── forward_auth ─▶ 入口 GET /v1/relay/check
                        （节点令牌换本登录的通行证）                     （只带 X-Fleet-Relay + 路径，不带 Authorization）
```

## 两道闸（取代来源 IP 白名单）

1. **通行证** —— 由入口逐请求核验，不在转发机上：
   - `frl1.…`：**每台机器、每个登录一张**，可信机器的节点用自己的节点令牌领
     （`fleet-relay-cred.sh fetch`）。入口只存它的 SHA-256，放在 fleet 设置
     `fleet.node_relay.<machine>`（与 C1 的 `fleet.node_trust.<machine>` 同表、同一套机器名匹配），
     值是 `<login>:<hash>` 若干个；同一登录重领只替换自己那一张。
   - `fcp-h1.…`：入口签给不可信机器会话的通行证（C2）。中心代理（C6）出门时带它。
     由 C2 的 `verifySessionCred` 核验，并且只放它覆盖的那家：`/anthropic/` 要 claude，
     `/chatgpt/`、`/openai-auth/` 要 codex；经 C2 的路由撤销即刻生效（不走下面的缓存）。
   - 不认：伪造的、被替换的、机器被标为不可信的、机器凭据被撤销的、放在 `Authorization` 里的。
2. **前缀白名单** —— 只有 `/anthropic/` `/chatgpt/` `/openai-auth/` 三条（入口核验时也按
   `X-Forwarded-Uri` 再查一遍）；其余一律 404。`/healthz` 不要通行证。**这不是开放代理。**

入口对同一张 `frl1.` 的判断缓存 30 秒（按哈希，不按原文）；领新证、撤销、改可信、撤销机器凭据都会
清空本副本的缓存，其它副本最多 30 秒后跟上。

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

- `forward_auth @fleet {$FLEET_HUB_URL} { uri /v1/relay/check … header_up -Authorization … }` ——
  核验子请求**不带**订阅、Cookie、`Chatgpt-Account-Id`、`X-Api-Key`；`forward_auth` 默认补
  `X-Forwarded-Uri`（原始路径，入口按它查前缀）。
- `request_header @fleet -X-Fleet-Relay` —— 通行证不出门。
- 每条 `reverse_proxy` 都 `header_up -X-Forwarded-For/-Host/-Proto`：**机器自己的地址不能递给上游**
  ——它所在的地区正是要绕开的。
- `/chatgpt/*` 改写成 `/backend-api/*`（本机代理的 Codex 基址是 `<relay>/chatgpt/codex`）。
- 流式：`flush_interval -1`。
- 日志 `format filter`：删掉全部请求 / 响应头、地址、TLS 信息，`request>uri` 只留前缀
  （`/anthropic/` 等，未路由的留空）——只剩前缀、状态、字节数、耗时。

占位符都不是密钥（`FLEET_RELAY_SITE`、`FLEET_HUB_URL`、`FLEET_RELAY_LOG`、`FLEET_RELAY_ADMIN`，
以及只给测试用的上游覆盖），可以放在 systemd 的 `Environment=` 里。

## 上线步骤（在 monorepo 建单，由有转发机钥匙的人执行）

按发起人拍板，**新起一台**，与生产的 `ai-relay-1g` 分开（同配置：Lightsail `micro_3_0`，
2 vCPU / 1 GB / 每月 2 TB，`ap-southeast-1`，Debian 12，每月 7 美元，静态 IP）。

1. 建实例 `fleet-relay-sg`，挂静态 IP；阿里云 DNS 加 A 记录 `fleet-relay.24hw.cn`
   （`*.24haowan.com` 有通配，理由同 `doc/review/2026-09-12-ai-gateway-overseas-relay.md`）。
2. 防火墙：22 ← 运维本机 /32；80、443 ← any（fleet 机器在各处、集群出口也要进，门禁靠通行证，不靠来源 IP；
   80 只为 ACME）。
3. 装 Caddy ≥ 2.10（官方 apt 源），把 `extras/cred-relay/Caddyfile` 放到 `/etc/caddy/Caddyfile`；
   `sudo systemctl edit caddy` 写：

   ```ini
   [Service]
   Environment=FLEET_HUB_URL=https://ccquota.24haowan.com
   Environment=FLEET_RELAY_SITE=fleet-relay.24hw.cn
   ```

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
