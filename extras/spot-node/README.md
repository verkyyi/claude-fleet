# SPOT 执行节点（issue #1428，EPIC #1419 R1）

固定机器（m5、m4）都忙的时候，入口（tokenledger hub）在它自己所在的
Kubernetes 集群里、SPOT 机器上起一台临时执行节点并派活；空闲满 30 分钟
自动释放；SPOT 机器被云回收时，节点先把空闲会话经入口搬走，没来得及的
按「意外下线」处理——租约立即释放、不自动重派、记录在案。

本目录是这台节点的**镜像**：`Dockerfile`（fleet + agent + tmux + gh +
Claude Code + Codex CLI，一个无特权登录 `fleet`）和它的入口脚本
`entrypoint.sh`。入口在集群里创建 pod、发加入码、看它报到、空闲时删 pod，
全在 `tokenledger/internal/api/fleet_spot.go`；对 Kubernetes API 的四个动作在
`tokenledger/internal/spot/`。

## 一次完整的「起节点 → 派活 → 合并 → 释放」

1. **起节点**：派单（`worker_start(node=auto)` / `dash-issue-session.sh --node auto`）
   找不到任何可用机器（都超过 0.8 负载/核、内存不足或到了每人上限）时，
   拒绝里多一句 `a SPOT node has been requested`，入口下一个 tick（30s）
   铸一个 10 分钟有效的加入码（kind=ephemeral），在 `CCQUOTA_FLEET_SPOT_NAMESPACE`
   里创建 pod `ccquota-spot-<id>`（镜像 `CCQUOTA_FLEET_SPOT_IMAGE`，加入码在 env
   里），台账 `fleet_spot_nodes` 记一行 `provisioning`。`/nodes` 页的「SPOT 节点」
   块从这一刻就列出它。运营者也可以在页上点「起一台 SPOT 节点」。
2. **报到**：pod 里 `entrypoint.sh` 用加入码跑 `fleet-node-join.sh`（依赖已
   预装，几秒钟），入口把加入码的 kind 盖到这个 endpoint 上（节点自己说什么
   都不算数），agent 前台运行、报到；台账变 `online`，节点列表里它带 `SPOT` 标。
3. **派活**：之后的派单把它当候选，分数乘以 `CCQUOTA_FLEET_SPOT_WEIGHT`
   （默认 0.5；`fleet.spot_weight` 设置可改），所以固定机器有空就先用固定
   机器。它上面的会话照常开 PR、合并——与任何机器一样。
4. **释放**：心跳里会话数为 0 持续 `CCQUOTA_FLEET_SPOT_IDLE_MINUTES`（30）后，
   入口删 pod（带 grace）；pod 消失后台账 `released`，节点行、endpoint 和它的
   token 一起退掉，`/nodes` 列表里它消失，「最近释放」里留下时间线：起 →
   报到 → 释放、活了多久、会话峰值。
5. **被回收**：kubelet 的 SIGTERM 到 agent，agent 先 `POST /v1/node/reclaim`
   （从此派单避开它），再跑 `bin/fleet-spot-evacuate.sh`——对本机每个 fleet
   `fleet-move.sh --rebalance --max all`，把 `done` 的会话经入口搬到别的机器；
   工作中的会话不动。pod 没了之后，它还持有的 issue 租约**立即**释放（不等
   30 分钟失联 TTL——入口知道它不会回来），记录 `sessions_lost`。

## 入口怎么配

hub 已经跑在 ACK（`new-deploy` 命名空间，`deploy/ccquota-hub`）。要开 SPOT
节点，hub 的 Deployment 加：

```yaml
env:
  - name: CCQUOTA_FLEET_SPOT_IMAGE
    value: registry.cn-shenzhen.aliyuncs.com/24haowan/ccquota-node:<tag>
  - name: CCQUOTA_FLEET_SPOT_HUB_URL          # pod 从集群内怎么到 hub；缺省用 CCQUOTA_FLEET_PUBLIC_URL
    value: http://ccquota-hub.new-deploy.svc:8787
  - name: CCQUOTA_FLEET_SPOT_NODE_SELECTOR    # SPOT 节点池
    value: node.kubernetes.io/instance-type=spot    # 按你的池的标签改
  - name: CCQUOTA_FLEET_SPOT_TOLERATIONS
    value: spot=true:NoSchedule
  - name: CCQUOTA_FLEET_SPOT_CPU
    value: "4"
  - name: CCQUOTA_FLEET_SPOT_MEMORY
    value: 8Gi
  # 可选：CCQUOTA_FLEET_SPOT_MAX (1) · _IDLE_MINUTES (30) · _BOOT_MINUTES (10)
  #       _WEIGHT (0.5) · _GRACE_SECONDS (300) · _PULL_SECRET · _SERVICE_ACCOUNT
  #       _POD_JSON（一个合并到生成的 Pod 上的 JSON 文件：volume、affinity 等）
```

hub 的 ServiceAccount 需要在该命名空间里对 pods 的 create/get/list/delete
（见 `k8s.yaml`）。镜像里不放任何凭据：Claude / Codex / GitHub 的凭据由节点
agent 按 #1415 向入口短期租用（`CCQUOTA_FLEET_CREDS=1` 走 node.env；本镜像
的 join 默认不开，需要时在 `_POD_JSON` 里加 env）。

## 构建镜像

从**仓库根目录**（镜像里带这个 checkout，节点从它装 fleet）：

```bash
docker build -f extras/spot-node/Dockerfile \
  --build-arg VERSION=$(git rev-parse --short HEAD) \
  --platform linux/amd64 \
  -t registry.cn-shenzhen.aliyuncs.com/24haowan/ccquota-node:$(git rev-parse --short HEAD) .
docker push registry.cn-shenzhen.aliyuncs.com/24haowan/ccquota-node:$(git rev-parse --short HEAD)
```

`--build-arg CLAUDE_INSTALL=0 CODEX_INSTALL=0` 跳过两个 CLI 的安装（CI 这么
冒烟）。`.github/workflows/spot-node.yml` 在 PR 上构建并冒烟：tini、tmux、gh、
ccquota 都在，入口脚本缺 `CCQUOTA_HUB_URL` 时拒绝启动。

## 本地试一遍（不需要集群）

`fleet-node-join.sh` 的 Linux 路径已由 `.github/workflows/node-join.yml` 在干净
容器里验证；SPOT 的整条生命周期由 Go 测试对着假的 Kubernetes API 跑
（`tokenledger/internal/api/fleet_spot_test.go`：起 → 报到 → 派活 → 空闲释放，
以及回收 → 租约立即释放），`go test ./internal/api/ -run Spot`。要看真 pod：
跑一个本地 hub（`CCQUOTA_FLEET=1 CCQUOTA_FLEET_SPOT_IMAGE=… CCQUOTA_FLEET_SPOT_KUBE_URL=…
CCQUOTA_FLEET_SPOT_KUBE_TOKEN=…`，`_KUBE_CA` 或 `_KUBE_INSECURE=1`）对着任何
集群（kind / minikube 也行），在 `/nodes` 点「起一台 SPOT 节点」。

## 已知边界

- 节点报的负载/内存是**宿主机**的（`/proc`），不是容器 cgroup 的；对独占一台
  SPOT 机器的节点来说这就是对的。
- 容器里没有 systemd，fleet 的后台 daemon（cleanup、dispatch、diskguard…）不
  跑；节点由入口驱动（开会话、发消息、搬家），30 分钟的机器不需要它们。
- 加入码在 pod 的 env 里，能读该命名空间 pod 的人能看到；它只能用一次、10 分钟
  内有效，换来的也只是这个节点自己的 token。
- 一个节点一个登录（`fleet`），所以 `fleet.node_cap.<机器名>` 对它的意义是
  这个登录在它上面的上限；机器名是 pod 名（`ccquota-spot-<id>`），每台不同。
