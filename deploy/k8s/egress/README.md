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
| 端口 | `FLEET_EGRESS_PORTS`，默认只 443 |
| 主机 | `FLEET_EGRESS_ALLOW`：`name` 精确、`.name` 含子域；默认 Anthropic / OpenAI / GitHub / npm / PyPI / Go 的域名 |
| 地址 | 直连时每个解析结果都得是公网地址（防 DNS 重绑到集群、元数据、VPC） |
| 上游 | `FLEET_EGRESS_VIA`：某些主机经上级代理——GitHub 经新加坡 `extras/gh-relay`（它只认集群出口 /32） |

每个请求一行 JSON（`src` 是 pod 地址：按 pod 记流量），不记内容。订阅流量**不走这里**：
会话的 API 请求到 `fleet-credproxy`，由它经新加坡中转出门。

`python3 -I deploy/k8s/egress/base/fleet-egress.py --selftest` 离线自检。

## 上线 · 升级

和中心代理一起：`kubectl kustomize deploy/k8s/fleet-workers`（`../credproxy/README.md`
«fleet-workers»，镜像占位 `fleet-python` 钉成托管节点镜像的 `@sha256:` 摘要）。改白名单 / 上游 =
改 `fleet-workers/deployment-env.yaml` 再 apply；改程序 = 改 `base/fleet-egress.py`，ConfigMap 名
带内容哈希，apply 即滚动（2 副本、`maxUnavailable: 0`，隧道在旧 pod 上跑完）。

验：

```sh
# 在用户 pod 里，以任何登录
curl -sS -o /dev/null -w '%{http_code}\n' https://github.com/                 # 200（经出口，再经 gh-relay）
curl -sS -o /dev/null -w '%{http_code}\n' https://example.com/                # 000（出口 403 host_not_allowed）
curl -sS --noproxy '*' -m3 https://registry.npmjs.org/                        # 拒绝（守卫，--egress-closed）
kubectl -n fleet-workers logs deploy/fleet-egress | tail                      # 每请求一行
```
