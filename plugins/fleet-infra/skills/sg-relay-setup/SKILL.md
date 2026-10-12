---
name: sg-relay-setup
description: 起一台海外中转机，让不能直连的机器和入口经它到达订阅服务与 GitHub——先装核验进程再装 Caddy、GitHub 的 CONNECT 代理只对集群出口开放、入口和机器各打开开关、按无凭据的探测验收、按开关撤回。用于「新建 / 迁移中转机」「中转返回 403/502」「GitHub 登录在国内走不通」「撤销一台机器的中转通行」。只给管理入口和中转的人用。
---

# sg-relay-setup — 海外中转

占位：`<RELAY_HOST>` 中转的域名 · `<HUB_URL>` 入口 · `<HUB_NAMESPACE>` 入口所在的 k8s 命名空间 ·
`<CLUSTER_EGRESS>` 集群出口的 /32 · `<NODE>` 机器名。都从私有部署仓库或人那里拿，**不写进本仓库**。
权威出处：`docs/dev/CRED-RELAY.md`「转发机的配置」「上线步骤」「入口重启时」「入口的 GitHub 登录换令牌」「机器这一侧」「撤销（运维）」「完成判据 / 上线证据」；
`deploy/k8s/RUNBOOK.md`「GitHub 登录换令牌走新加坡中转」；`extras/gh-relay/README.md`；
文件：`extras/cred-relay/{Caddyfile,fleet-relay-check.py,fleet-relay-check.service}`、`extras/gh-relay/{gh-relay.py,gh-relay.service}`。

## 什么时候用

- 机器或入口所在地区不能直连订阅服务 / GitHub，需要一台海外机器转发。
- 中转迁移、重装，或升级到新版核验进程。
- 中转返回异常（全部 403、502），或要撤销一台机器经中转的资格。

## 先查什么

- 你有中转机的 ssh 钥匙和 sudo；中转机是 Debian / Ubuntu，有 `python3`、`systemd`，Caddy ≥ 2.10（官方 apt 源）。
- DNS：`<RELAY_HOST>` 已指向中转的静态 IP（`dig +short <RELAY_HOST>`）。
- 防火墙：22 只对运维本机；80、443 对任何来源（门禁靠通行证，不靠来源 IP；80 只为 ACME）；3128 只对 `<CLUSTER_EGRESS>`。
- 已在跑的中转：`curl -s https://<RELAY_HOST>/healthz` 与 `systemctl status fleet-relay-check caddy gh-relay` 现状先记下来。

## 步骤

1. **先**装核验进程（顺序反了 Caddy 去问一个不存在的 2091，所有请求被拒）：
   ```sh
   sudo install -D -m 0755 fleet-relay-check.py /usr/local/lib/fleet-relay/fleet-relay-check.py
   sudo install -m 0644 fleet-relay-check.service /etc/systemd/system/
   sudo systemctl daemon-reload && sudo systemctl enable --now fleet-relay-check
   curl -s http://127.0.0.1:2091/healthz          # ok
   ```
   入口地址 `FLEET_HUB_URL=<HUB_URL>` 写在这个单元里（`systemctl edit fleet-relay-check`）。
2. 再装 Caddy：`extras/cred-relay/Caddyfile` → `/etc/caddy/Caddyfile`；`sudo systemctl edit caddy` 写
   `Environment=FLEET_RELAY_SITE=<RELAY_HOST>`；然后
   `sudo -u caddy caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy`
   （**用 caddy 用户**校验：root 校验会建出 root 属主的日志，caddy 随后起不来）。
3. GitHub 的 CONNECT 代理（集群里的入口和节点用）：照 `extras/gh-relay/README.md`「Install / update」——
   先 `python3 -I gh-relay.py --selftest`，装进 `/opt/gh-relay`，`sudo systemctl enable --now gh-relay`；
   来源限制同时写在云防火墙和 `GH_RELAY_SOURCES` 里。
4. 入口侧开关（私有部署覆盖层的环境变量，经发布列车上线，见 `hub-deploy`）：
   `CCQUOTA_FLEET_CRED_RELAY_URL=https://<RELAY_HOST>`，再按需 `CCQUOTA_GITHUB_OAUTH_VIA=relay`、
   `CCQUOTA_FLEET_OAUTH_REFRESH_VIA=relay`、`CCQUOTA_FLEET_HUB_QUOTA=relay`。**中转先升级，入口后部署。**
5. 机器侧（一台可信、不能直连的登录）：`fleet.conf` 的 `[common]` 加 `FLEET_CRED_RELAY_URL=https://<RELAY_HOST>`；
   `~/.claude/fleet/bin/fleet-relay-cred.sh fetch`；`~/.claude/fleet/bin/fleet-cred-proxy.sh route` 应读 `relay …`。

## 怎么验收

不需要任何凭据：
```sh
curl -s https://<RELAY_HOST>/healthz                                                             # ok
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://<RELAY_HOST>/anthropic/v1/messages      # 403（没有通行证）
curl -s -o /dev/null -w '%{http_code}\n' https://<RELAY_HOST>/v1/models                          # 404（不是开放代理）
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://<RELAY_HOST>/github-oauth/login/oauth/access_token  # 403
curl -sS -o /dev/null -w '%{http_code}\n' -x http://<RELAY_HOST>:3128 https://github.com/        # 从集群出口：200
```
- 机器上 Claude、Codex 各回一次 PONG（`docs/dev/CRED-RELAY.md`「完成判据」那段命令）。
- 中转机上查不到凭据片段：`sudo grep -rEc 'sk-ant-|eyJhbGci|Bearer ' /var/log/caddy/ /etc/caddy/` 全 0；日志一行只有前缀 / 状态 / 字节。
- 入口重启后：`journalctl -u fleet-relay-check --since '-15 min' | grep -E ' hub-(down|up) '` 先 down 后 up；
  GitHub 登录：`kubectl -n <HUB_NAMESPACE> logs deploy/ccquota-hub --since=10m | grep 'github sign-in'`。

## 怎么回滚

- 入口不走中转：从部署覆盖层删掉对应的 `…_VIA=relay` 行，下一次入口发布即恢复直连。
- 机器不走中转：从 `fleet.conf` 删掉 `FLEET_CRED_RELAY_URL`，`fleet-cred-proxy.sh route` 读回直连。
- 撤销一台机器（运维，环境里有 `CCQUOTA_VIEWER_TOKEN`）：`fleet-relay-cred.sh revoke <NODE>`，必要时 `fleet-node-trust.sh set <NODE> untrusted`；`fleet-relay-cred.sh status` 核对。
- 中转机换新：新机器照「步骤」装好并验收、DNS 切过去，旧机器留到 DNS TTL 过后再关。
