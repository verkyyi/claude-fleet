# deploy/k8s/egress — 统一出口（claude-fleet#3547，EPIC #3500 C2）

集群里一份去外面的路，Service `fleet-egress:3128`（`fleet-workers`）。用户 pod 自己的守卫
（`extras/managed-node/render.py --egress-closed`）把公网整个 REJECT，每个登录的
`HTTPS_PROXY` / git 的 `http.proxy` 指向这里（`--egress-proxy`，`fleet-node-linux.py` 每次启动写
`/etc/fleet-devnet.env` 与 `/etc/gitconfig`）。程序是 `base/fleet-egress.py`（ConfigMap 挂进去，
镜像只需要 python3——用托管节点镜像，节点上本来就有）：

| 墙 | 什么 |
|---|---|
| 来源 | `FLEET_EGRESS_SOURCES`——集群的 pod 网段；别人连上即断、不答一个字。flannel 不执行 NetworkPolicy，这一道才是真墙 |
| 方法 | 只 `CONNECT`（不做明文转发，不解密） |
| 端口 | `FLEET_EGRESS_PORTS`，默认 `*` 任何端口（#4311：集群 API 6443 也得出得去）；运行出口设 443 |
| 主机 | `FLEET_EGRESS_ALLOW`：默认 `*` 任何主机（#4311）；`name` 精确、`.name` 含子域，一份 overlay 想收窄时用 |
| 地址 | 直连时**每个**解析结果都得是公网地址——VPC、元数据 `100.100.100.200`、回环、私网段、pod / Service 网段一律 403 `blocked_address`（也防 DNS 重绑）。主机、端口都放开以后，这一道就是墙 |
| 上游 | `FLEET_EGRESS_VIA`：某些主机经上级代理——LLM 端点、GitHub 经美国出口 |
| 必经上游 | `FLEET_EGRESS_REQUIRE_VIA`：这些主机（LLM 端点）**只**走上级，上级不通就 502，绝不国内直连；没给它配上级的策略启动即拒 |

每个请求一行 JSON（`src` 是 pod 地址：按 pod 记流量），不记内容。订阅流量**不走这里**：
会话的 API 请求到 `fleet-credproxy`，由它经新加坡中转出门。

`python3 -I deploy/k8s/egress/base/fleet-egress.py --selftest` 离线自检；`--selftest private` / `--selftest require-via`
是 BREAK-IT `egress-private-via-proxy` / `egress-required-via-direct` 两条。

## 上线 · 升级

和中心代理一起：`kubectl kustomize deploy/k8s/fleet-workers`（`../credproxy/README.md`
«fleet-workers»，镜像占位 `fleet-python` 钉成托管节点镜像的 `@sha256:` 摘要）。改白名单 / 上游 =
改 `fleet-workers/deployment-env.yaml` 再 apply；改程序 = 改 `base/fleet-egress.py`，ConfigMap 名
带内容哈希，apply 即滚动（2 副本、`maxUnavailable: 0`，隧道在旧 pod 上跑完）。

我们的 `fleet-workers/` 在私有部署仓库里（[../README.md](../README.md) «overlays live in a private
repo»）：先 `gh variable get FLEET_DEPLOY_OVERLAY_REPO -R verkyyi/claude-fleet` 查到它（fleet 机器上
它被托管在 `~/projects/<name>`，`fleet-repo.sh list`），把它的 `k8s/` 叠到本仓库的 `deploy/k8s/`
上再 apply；别另做一份临时 overlay。上游里的美国出口是 [`../us-egress`](../us-egress/README.md)。

验：

```sh
# 在用户 pod 里，以任何登录
curl -sS -o /dev/null -w '%{http_code}\n' https://github.com/                 # 200（经出口，再经 gh-relay）
curl -sS -o /dev/null -w '%{http_code}\n' https://example.com/                # 200（任何公网主机）
curl -sS -m5 -k https://<集群 API 公网地址>:6443/version                        # 401/403 来自集群 API（6443 也放）
curl -sS -m5 http://100.100.100.200/ -x "$HTTPS_PROXY" -p                       # 失败（出口 403 blocked_address）
curl -sS --noproxy '*' -m3 https://registry.npmjs.org/                        # 拒绝（守卫，--egress-closed）
kubectl -n fleet-workers logs deploy/fleet-egress | tail                      # 每请求一行
```

## 运行出口（`run/`，#4005）

服务运行（活页的报告任务）的 Job 要读事先列不出来的网页，所以有第二份同样的程序：Service
`fleet-egress-run:3128`，`FLEET_EGRESS_ALLOW=*`——任何主机，但仍然只开 443、只 `CONNECT`、每个解析结果都得是**公网**地址（集群、元数据、VPC、回环一律拒）。
它只给运行用：运行 Job 的守卫（`render.py svc_run_resources`，封闭）只放它和凭据代理两个 ClusterIP；用户 pod 的守卫从来不放它。
随 `kubectl kustomize deploy/k8s/fleet-workers` 一起上（`run/` 是它的一份 overlay，名字加 `-run`，标签 `fleet/egress: run`）；
`FLEET_EGRESS_SOURCES` 与 `../fleet-workers` 的同一个 pod 网段。
