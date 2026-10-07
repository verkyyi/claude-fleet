# deploy/k8s/credproxy — 中心代理（集群凭据代理）

claude-fleet#1973（EPIC #1967 C6）。不可信机器上的会话手里只有入口签的会话通行证
（`fcp-h1.`，C2），本机代理（C3）把请求连同通行证发到这里；中心代理问入口「这张通行证
还算不算、是谁的会话、绑的哪个账号」，拿到该账号的短期 access token（入口保险箱的租约读），
换掉通行证，**一律经新加坡转发**（C7）发往上游，流式原样回传。凭据不出集群：不到机器，
也不到转发机（转发机只看到 `X-Fleet-Relay` 里的通行证，自己去入口核）。

```
base/   与环境无关：Deployment（2 副本、RollingUpdate）、Service、Ingress（只占 /v1/proxy/）、PDB
prod/   new-deploy 命名空间、ACR 镜像、两个入口域名、新加坡转发地址
```

## 它依赖什么、不依赖什么

- **无状态**：不挂盘、不持保险箱密钥、不读数据库。入口是单副本 SQLite（`Recreate`），
  中心代理不能也不需要碰它的盘——每张通行证只问入口一句
  `POST /v1/fleet/credproxy/resolve`（Service `ccquota-hub`，集群内，带自己的令牌），
  答案缓存 ≤ 30 s（吊销、换绑、token 刷新在 30 s 内生效）。
- **入口重启时照常服务**：入口答不了（重启、发布）时，已经在跑的会话用手里的答案继续
  （`--stale`，默认 15 分钟，且不超过 access token 自己的到期）；没见过的通行证回 503
  （客户端会重试），永不回 403。
- ⚠️ 转发机的 `forward_auth` 也问入口（`/v1/relay/check`，C7）。入口重启的那几十秒里，
  经转发的请求会被转发机拒——这是转发机一侧的事，另单跟进。

## 首次上线（人做，一次）

部署 job（`hub-deploy`）**不碰这里**：它的 Role 只管入口自己的对象，也不能写 Secret。

1. **入口先打开会话通行证（C2）**——`overlays/prod` 已经引用 Secret `ccquota` 的
   `session-cred-key`（#2092，`optional: true`）；键在 Secret 里、入口发布过一次，
   入口日志就不再有「session passes are off」。没有通行证就没有中心路。
2. **中心代理的令牌**，写进 Secret `ccquota` 的 `credproxy-token`（值不进仓库、不进 argv）：

   ```sh
   kubectl -n new-deploy patch secret ccquota --type merge \
     -p "{\"stringData\":{\"credproxy-token\":\"$(openssl rand -base64 32)\"}}"
   ```

   入口的 `overlays/prod` 已经引用它（`optional: true`）——入口下次重启（下一次发布，
   或 `kubectl -n new-deploy rollout restart deploy/ccquota-hub`）后 resolve 才开。
3. **应用**，镜像钉成入口当前的 tag（同一镜像）：

   ```sh
   tag=$(kubectl -n new-deploy get deploy ccquota-hub -o jsonpath='{.spec.template.spec.containers[?(@.name=="ccquota")].image}'); tag=${tag##*:}
   kubectl kustomize deploy/k8s/credproxy/prod | sed "s#:set-by-hub-deploy\$#:$tag#" | kubectl apply -f -
   kubectl -n new-deploy rollout status deploy/ccquota-credproxy
   ```

4. **验**：
   - `curl -s https://claudefleet.24haowan.com/v1/proxy/anthropic/v1/messages -d '{}'`
     → `403 {"type":"error","error":{"type":"permission_error",…"fcp-h1."…}}`（来自中心代理，
     不是入口的 404）。
   - 在一台标为不可信的登录上（`fleet-node-trust.sh set <m> untrusted`，`FLEET_CRED_PROXY=1`）：
     `claude -p 'reply PONG'`、`codex exec 'reply PONG'` 各回一次 PONG；
     `kubectl -n new-deploy logs deploy/ccquota-credproxy | tail` 每请求一行
     （`principal`、`worker_id`、`account`、`status`、`bytes_*`、`ms`，没有任何认证头）。

## 之后

- **升级**：镜像跟入口走——`hub-deploy` 入口发布成功后自己
  `kubectl -n new-deploy set image deploy/ccquota-credproxy credproxy=<入口新镜像>`
  （#2092；滚动、`maxUnavailable: 0`，流在旧 pod 上跑完再走，宽限 120 s）。这个
  Deployment 还没部署就跳过；部署 Role 还没加 `ccquota-credproxy`（`../README.md`
  «Who may do what» 那一行）也跳过并在发布摘要里写明——两种都不变红。只改镜像，
  这里的清单改了仍由人 apply。
- **换令牌**：改 Secret 的 `credproxy-token`，重启入口和中心代理。
- **换绑账号**：`PUT /v1/fleet/session-cred/bind {worker_id, provider, account}`
  （签发通行证的那台机器的节点令牌，或运营者），下一次 resolve（≤ 30 s）生效。
- **下线**：`kubectl -n new-deploy delete -k deploy/k8s/credproxy/prod`；本机代理的中心路
  随之 404，不可信机器上的会话停在「没有可用的路」——可信机器不受影响。
