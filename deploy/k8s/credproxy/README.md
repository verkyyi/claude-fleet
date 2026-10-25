# deploy/k8s/credproxy — 中心代理（集群凭据代理）

> 下文的 `overlays/prod` · `updating/prod` · `credproxy/prod` · `*/fleet-workers` 是部署自己的覆盖层，
> 我们的在私有部署仓库里（#3630）：手工 `kubectl` 之前先把它的 `k8s/` 叠到本仓库的 `deploy/k8s/` 上
> （`cp -R <部署仓库>/k8s/. deploy/k8s/`，[../README.md](../README.md)）。

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
- 转发机的 `forward_auth` 也问入口（`/v1/relay/check`，C7），经转发机上的本机核验进程：入口重启的
  那几十秒里，10 分钟内核过的通行证照常放行（claude-fleet#2048，docs/dev/CRED-RELAY.md「入口重启时」）。

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
   - `curl -s https://hub.example.com/v1/proxy/anthropic/v1/messages -d '{}'`
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

## Bedrock 兜底（任务 PNWW，默认关）

订阅池接不住一个 Claude Messages 请求时——hub 说 `claude_pool_unavailable`
（没有可用订阅），或绑定的订阅换绑一次后仍回 429——中心代理问 hub 一次
`POST /v1/fleet/credproxy/fallback`，hub 准了才把**同一个请求体**改投 Amazon
Bedrock（InvokeModel / InvokeModelWithResponseStream，SigV4），把 Bedrock 的
event-stream 译回 Anthropic SSE。没准、模型没映射、Bedrock 拒了：原来的错误原样给客户端。

- **开关**：hub 设置 `fleet.fallback.bedrock`（`on` | `off`，默认 `off`；关着 hub 什么
  都不读，代理把这个「关」记一个缓存周期，不每个 429 都问）。
  `fleet hub set fleet.fallback.bedrock on`。
- **谁不行**：试用身份（`trialIdentity`）、超了个人额度的人——一律原错误。
- **月上限**：`fleet.fallback.bedrock.cap_usd`（默认 `200`，UTC 自然月）。花费 =
  本月 `pool_usage` 里 `source=bedrock` 的行按 API 价算（和成员美元上限同一张价表、
  同一个 `priceUsage`）；到线就不再兜底。
- **钥匙**：存在 vault 里，`POST /v1/fleet/credentials`
  `{"action":"put","principal_id":"pool","provider":"claude","account":"bedrock1",
  "secret":{"aws_access_key_id":"…","aws_secret_access_key":"…","aws_region":"us-west-2"}}`
  （region 可省，默认 `us-west-2`）。它是 kind `bedrock`、source_class `api` 的一行，
  **不是订阅**：不出现在订阅列表、不租给机器、不绑会话（`GET` 的答案里单列在 `bedrock`）。
- **模型**：`claude-opus-5-5` → `us.anthropic.claude-opus-5-5`——表只有一张，
  `tokenledger/shared/credproxy/bedrock.go` 的 `BedrockModels`；跨区推理前缀按钥匙
  的 region 加（us. / eu. / apac.）。上线前对照账号的 Bedrock 控制台核一遍 ID。
- **计量**：Bedrock 服务的请求照样记一行 `pool_usage`，`source=bedrock`、account
  `pool/<钥匙名>`、人是通行证的人（也算进个人额度）；其余行 `source=subscription`。
  `GET /v1/admin/usage` 多了 `sources`（本周按来源的 token / 请求数）和 `bedrock`
  （开没开、本月花了多少、上限）。审计行带 `fallback`（兜了，或为什么没兜）。
- **出口**：中心代理直连 `bedrock-runtime.<region>.amazonaws.com`，不经新加坡中转；
  `--bedrock` / `CCQUOTA_CREDPROXY_BEDROCK_URL` 可换一个端点。只有中心代理有兜底，
  本机代理（`bin/fleet-cred-proxy.py`）没有。

## fleet-workers — 用户 pod 旁边再一份（#3547，EPIC #3500 C2）

`fleet-workers/` 把同一个中心代理在 `fleet-workers` 命名空间里再起一份，名字按批次约定改成
`fleet-credproxy`（Service `fleet-credproxy:80`，2 副本、PDB、滚动 `maxUnavailable: 0`），
**只在集群里**：没有 Ingress，不挂集群令牌，pod 带 `fleet/role: ops`。用户 pod
（`extras/managed-node/render.py --cred-central http://fleet-credproxy.fleet-workers.svc.cluster.local`）
的每个会话只拿入口签的通行证，经 pod 里的本机代理交给它；订阅凭据只在它和入口之间。
它和 new-deploy 那份互不相干，各自滚动。一起起的还有统一出口、包缓存和命名空间的网络规则：
`../fleet-workers/`（一个 `kubectl apply -k` 全上，见 `../egress/README.md`、`../caches/README.md`——
包缓存三个镜像的 `:set-by-person` 同样在第 2 步换成 `@sha256:` 摘要）。

首次上线（人做，一次）：

```sh
# 1. 令牌：入口只认一个 credproxy 令牌——把 new-deploy 那份原样抄过来（值不进仓库、不进 argv）
kubectl -n new-deploy get secret ccquota -o jsonpath='{.data.credproxy-token}' \
  | python3 -c 'import base64,json,sys; print(json.dumps({"apiVersion":"v1","kind":"Secret","metadata":{"name":"fleet-credproxy","namespace":"fleet-workers"},"type":"Opaque","data":{"credproxy-token":sys.stdin.read().strip()}}))' \
  | kubectl apply -f -
# 2. 应用，镜像钉成入口当前的 tag；统一出口的镜像钉成托管节点镜像的摘要（../egress/README.md）
tag=$(kubectl -n new-deploy get deploy ccquota-hub -o jsonpath='{.spec.template.spec.containers[?(@.name=="ccquota")].image}'); tag=${tag##*:}
node=$(kubectl -n fleet-workers get sts fleet-linux -o jsonpath='{.spec.template.spec.containers[0].image}')
kubectl kustomize deploy/k8s/fleet-workers \
  | sed -e "s#ccquota:set-by-hub-deploy\$#ccquota:$tag#" -e "s#fleet-managed-node:set-by-person\$#${node##*/}#" \
  | kubectl apply -f -
kubectl -n fleet-workers rollout status deploy/fleet-credproxy
```

升级：`kubectl -n fleet-workers set image deploy/fleet-credproxy credproxy=<入口新镜像>`，或
`kubectl -n fleet-workers rollout restart deploy/fleet-credproxy`——新 pod 就绪才摘旧 pod，
旧 pod 上的流跑完再走（宽限 120 s），会话不断（本机代理遇 5xx / 断连自动重试）。
`hub-deploy` 现在只跟 new-deploy 那份（`ccquota-credproxy`）。
