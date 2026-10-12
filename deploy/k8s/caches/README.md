# deploy/k8s/caches — 包缓存（claude-fleet#3548，EPIC #3500 C3）

集群里一份装包的地方：用户 pod 装 npm / pip / Go 包、新会话起 MCP，都先问这里，不现场去公网拉。
三个读穿缓存，各一个 StatefulSet（2 副本、每副本自己一块盘、PDB），都在 `fleet-workers`：

| Service | 程序 | 上游（`fleet-workers/` 里改） | 挂了 |
|---|---|---|---|
| `fleet-npm:4873` | Verdaccio（`base/verdaccio.yaml`：只读，不许发布、不许注册） | registry.npmmirror.com | 另一个副本接着答；两个都挂 = npm 装包失败（npm 没有备用源） |
| `fleet-pypi:3141` | devpi-server（`base/devpi-start.sh`：每次启动把 root/pypi 指向上游） | 清华 pypi.tuna.tsinghua.edu.cn | 另一个副本接着答 |
| `fleet-goproxy:3000` | Athens（磁盘存储） | goproxy.cn | 用户 pod 的 `GOPROXY` 用 `\|` 接着 goproxy.cn，变慢不失败 |

缓存自己出门（`fleet/role=ops`，不经 `fleet-egress`），上游都在国内。Service 带
`sessionAffinity: ClientIP`：一个用户 pod 一直问同一个副本，第二次装就命中。

用户 pod 用它们：`render.py --cluster-caches`（替代 `--cn-mirrors`），`fleet-node-linux.py`
每次启动把下面这些写进 `/etc/fleet-devnet.env`（登录自己的值优先）：

```
npm_config_registry / YARN_REGISTRY / COREPACK_NPM_REGISTRY = http://fleet-npm.fleet-workers.svc.cluster.local:4873
PIP_INDEX_URL / UV_DEFAULT_INDEX = http://fleet-pypi.fleet-workers.svc.cluster.local:3141/root/pypi/+simple/
GOPROXY = http://fleet-goproxy.fleet-workers.svc.cluster.local:3000|https://goproxy.cn|direct
```

MCP 包：托管节点镜像里全局预装 context7 / playwright / github 三个 npm 包和 `mcp-server-fetch`
（`extras/managed-node/Dockerfile`），`npx -y <包>` 直接用本地那份、不问源；写着 `@latest` 的
（playwright）问一次 `fleet-npm`，在集群内。

Git：拉代码走 CI 的镜像（`git-mirror.arc-runners`，`render.py --git-mirror`，推仍去 GitHub），
NetworkPolicy 给用户 pod 开了到 `arc-runners` 9418 的口。

## 上线 · 升级

镜像：Verdaccio、Athens 从 docker.io 同步进集群的镜像仓库（`verdaccio/verdaccio:6`、
`gomods/athens:v0.19.2`）；devpi 用 `pypi-image/Dockerfile` 在境外构建再推。三个都在
`fleet-workers/kustomization.yaml` 的 `images:` 里按 `@sha256:` 钉住。盘用集群默认的
StorageClass；要别的类，给 `volumeClaimTemplates` 加一个 JSON6902 补丁再 apply
（StatefulSet 的 `volumeClaimTemplates` 建好就改不了，换类 = 删 StatefulSet 留盘、改、再 apply）。

```sh
kubectl kustomize deploy/k8s/fleet-workers > /tmp/fleet-workers.yaml     # 凭据代理 + 出口 + 包缓存 + 网络规则
kubectl apply --dry-run=server -f /tmp/fleet-workers.yaml
kubectl apply -f /tmp/fleet-workers.yaml
kubectl -n fleet-workers rollout status sts/fleet-npm sts/fleet-pypi sts/fleet-goproxy
kubectl -n fleet-workers get svc fleet-npm fleet-pypi fleet-goproxy \
  -o jsonpath='{range .items[*]}{.spec.clusterIP}:{.spec.ports[0].port}{"\n"}{end}'   # --egress-closed 时每个都 --egress-allow
```

改上游 = 改 `fleet-workers/upstreams.yaml`（npm 的在 `base/verdaccio.yaml`）再 apply，滚动重启。

验（在用户 pod 里，以任何登录，`--cluster-caches` 之后）：

```sh
npm config get registry                                   # http://fleet-npm.fleet-workers.svc.cluster.local:4873
cd "$(mktemp -d)" && echo '{}' > package.json && time npm i express@4    # 第一次：从上游
cd "$(mktemp -d)" && echo '{}' > package.json && npm cache clean --force && time npm i express@4   # 第二次 ≤ 2 秒
pip download -q --no-deps -d "$(mktemp -d)" requests && echo pip ok
go env GOPROXY
```
