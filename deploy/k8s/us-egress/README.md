# deploy/k8s/us-egress — 美国出口（claude-fleet#4313，上线于 #4311）

[`fleet-egress`](../egress/README.md) 的上级代理：LLM 端点、它们的遥测与下载、GitHub 经这里出门
（`egress/fleet-workers/deployment-env.yaml` 的 `FLEET_EGRESS_VIA` → Service `fleet-us-egress:3128`）。
集群里只有网关一半；另一半是一台美国的 macOS 主机，它**主动**用 WSS 连进来（经入口现有的 TLS，
只占精确路径 `/_fleet/us-egress`，不开新的 LoadBalancer、家里路由器不开端口），每条 CONNECT 隧道借它
一条线路，由它解析、连上公网目标。隧道里是原样的 TLS 字节——不解密、证书与 SNI 不变。

| 端口 | 谁来 |
|---|---|
| `connect` 3128 | `fleet-egress`（`FLEET_US_EGRESS_SOURCES` = 集群 pod 网段，overlay 必须给、程序没有默认；只放 `FLEET_US_EGRESS_DOMAINS` 里的主机、只 443） |
| `reverse` 8090 | 美国主机的连接器，经入口；凭 Secret `fleet-us-egress` 的 `token` 认证 |

没有连接器时 CONNECT 回 502——没有直连、也没有新加坡兜底。`/livez` 只说进程活着（入口在中断期间
也得收得下重连的连接器）；`/healthz` 没有已认证的连接器时回 503，监控看它和一次真实 CONNECT。
每个请求一行 JSON（目标主机、状态、耗时、来源），不记头和内容。

```
base/            程序 us-egress.py（以 gateway 跑）+ PyPI 的 websockets-12.0-py3-none-any.whl
                 （sha256 dc284bbc…500e9e，init 容器离线解包）、Deployment · Service · Ingress
fleet-workers/   示例 overlay：namespace、镜像（托管节点镜像，按 @sha256: 钉）、入口主机名
```

它**不**并进 `deploy/k8s/fleet-workers`：那一层只在集群里（没有 Ingress）、每份两副本（#4175 钉着），
而网关要一条入口路径、只能一副本（连接器的线路在哪个 pod 上，隧道就只能在那个）、还先要人建的 Secret。
单独 apply；网络规则在 `../fleet-workers/networkpolicy.yaml` 的 `us-egress-in`（3128 只收 `fleet-egress`，
8090 只收入口控制器）。

## 上线 · 升级

1. 我们的 `fleet-workers/` 在私有部署仓库里：`gh variable get FLEET_DEPLOY_OVERLAY_REPO -R verkyyi/claude-fleet`
   查到它（fleet 机器上它被托管在 `~/projects/<name>`，`fleet-repo.sh list`），把它的 `k8s/` 叠到本仓库的
   `deploy/k8s/` 上（`cp -R <部署仓库>/k8s/. deploy/k8s/`，[../README.md](../README.md)）。
2. Secret `fleet-workers/fleet-us-egress`（key `token`）由人从加密的 stdin 建，从不写进清单、参数或日志；
   连接器那头从 macOS 系统钥匙串读同一枚（账户与服务都是 `fleet-us-egress`）。
3. `kubectl apply --dry-run=server -k deploy/k8s/us-egress/fleet-workers`，再去掉 `--dry-run` apply。
   改程序 = 改 `base/us-egress.py`，ConfigMap 名带内容哈希，apply 即滚动。

连接器（`client-run.sh` · `install-macos.py`，launchd `com.claude-fleet.us-egress`）和凭据代理那一侧的
`FLEET_CRED_ANTHROPIC_PROXY` 还在分支 `scratch-20261012-us-egress` 的 `extras/us-egress/`（提交 157e3276），
它的 `render.py` 是这份清单的前身——网关这一半以本目录为准。那一版程序默认来源网段，
本目录的不给默认：从那份清单换到 `base/` 时，overlay 要补上 `FLEET_US_EGRESS_SOURCES`。

验：

```sh
curl -sS -o /dev/null -w '%{http_code}\n' https://api.anthropic.com/   # 在用户 pod 里：经 fleet-egress → 美国出口
kubectl -n fleet-workers exec deploy/fleet-us-egress -- \
  python3 -c "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8090/healthz').status)"   # 200 = 有连接器
```
