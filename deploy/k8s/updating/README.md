# deploy/k8s/updating — 「正在更新」页

claude-fleet#2052（EPIC #1982）。入口是单副本 SQLite（`Recreate`），每次发布有几十秒没有
就绪的 pod。以前这几十秒里 ingress-nginx 自己回一个光秃秃的 503；现在入口的 Ingress
带 `nginx.ingress.kubernetes.io/default-backend: ccquota-hub-updating`
（`../base/ingress.yaml`），没有就绪 endpoint 时请求原样转到这里：

| 请求 | 回答 |
|---|---|
| 浏览器要页面（`Accept` 含 `text/html`，且不是下面的路径） | `503` + 中英双语「ClaudeFleet 正在更新，一分钟内回来 / ClaudeFleet is updating — back in a minute」，`Retry-After: 30`，每 15 秒自动刷新 |
| `/v1/*`、`/mcp`、`/install`、`/healthz`、`/version`，以及不要 HTML 的一切 | `503` + `Retry-After: 30` + 一行 JSON（`{"error":"updating",…}`）——机器和客户端照旧重试 |

```
base/   与环境无关：nginx Deployment（2 副本）、Service、ConfigMap（nginx.conf + 页面 + JSON）
prod/   new-deploy 命名空间、ACR 里的 nginx 镜像（按 digest 钉住）
```

**为什么不是 `custom-http-errors`**：入口自己会有意回 502 / 503（功能没开、保险箱锁着、
上游不通），那些回答带着说明，必须原样到客户端。`default-backend` 只在入口**没有就绪
pod** 时接手，正好是发布那几十秒。**为什么不是 server-snippet**：集群的 ingress-nginx
（v1.11）没开 `allow-snippet-annotations`。

## 安装（人做，一次）

部署 job（`hub-deploy`）**不碰这里**：它的 Role（24haowan-monorepo#11751）只管入口自己的
对象，不能创建新的 Deployment / Service / ConfigMap；prod 的配置也受 `lock-prod-config`
准入策略（prod-config-lockdown #955）约束——走 monorepo 的配置发布（config-deploy）或
break-glass：

```sh
kubectl kustomize deploy/k8s/updating/prod | kubectl apply -f -
kubectl -n new-deploy rollout status deploy/ccquota-hub-updating
```

装好之后的**下一次入口发布**才会把 annotation 带上：hub-deploy 渲染时看
`app=ccquota-hub-updating` 有没有在跑的 pod，没有就从渲染里删掉那一行并在运行里留一条
warning——Ingress 永远不会指向一个不存在的后端。

## 验

发布期间（从「Apply」到健康检查通过的那几十秒）：

```sh
curl -s -H 'Accept: text/html' https://claudefleet.24haowan.com/ | grep 正在更新
curl -s -o /dev/null -w '%{http_code}\n' -D - https://claudefleet.24haowan.com/v1/me | grep -i -E '^503|retry-after'
```

改文案 / 规则：改 `base/` 里的文件再 apply 一次——ConfigMap 名字带内容哈希，pod 会滚动换新。
