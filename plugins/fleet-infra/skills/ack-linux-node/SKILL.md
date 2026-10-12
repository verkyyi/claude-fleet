---
name: ack-linux-node
description: 在 Kubernetes（如阿里云 ACK）上起一台托管 Linux 节点——打镜像、渲染清单、用一次性加入码起 StatefulSet、开号、核对出口和凭据隔离、按 digest 升级与回退。用于「加一台云上 Linux 机器」「Linux 节点起不来 / 换镜像」「云节点回滚」。只给管理集群和机器的人用。
---

# ack-linux-node — 云上 Linux 节点

占位：`<HUB_URL>` 入口 · `<NODE>` 节点名（pod 名）· `<REGISTRY>` 镜像仓库 · `<STORAGE_CLASS>` 加密云盘的存储类 ·
`<PULL_SECRET>` 拉镜像的 Secret · `<LB_ADDRESS>` 入口端口的负载均衡地址。都从私有部署仓库或人那里拿，**不写进本仓库**。
权威出处：`docs/MANAGED-LINUX.md`「Build the ACK image」「ACK resources」（含 Egress guard、Dev network）「Hub, relay, and access」
「Shared services」「Package caches」「Upgrade and recovery」「Acceptance evidence」；演练顺序 `docs/MANAGED-LINUX-DRILL.md` §0–⑦；
共享层 `deploy/k8s/fleet-workers`、`deploy/k8s/egress`、`deploy/k8s/caches` 各自的 README。

## 什么时候用

- 要一台不归任何人桌面的 Linux 机器跑会话（托管客户、容量不够）。
- 节点 pod 起不来、要换镜像、要回到上一版镜像。
- 临时容量走 SPOT 节点是另一条路（入口自己起停，`extras/spot-node/README.md`），不用这张。

## 先查什么

```sh
kubectl config current-context                   # 是目标集群，不是别的
kubectl auth can-i create statefulset -n fleet-workers
kubectl get storageclass                         # <STORAGE_CLASS> 存在且加密
kubectl -n fleet-workers get pods,secrets        # 同名节点已在 = 这是升级 / 修复，不是新建
curl -fsS <HUB_URL>/healthz
```

- 入口「机器」页拿一个托管加入码（一次性、1 小时）。存成文件，不贴进任何地方。
- 发布版：用 stable 指向的提交（`RELEASE_COMMIT`）打镜像。

## 步骤

1. 打镜像（`docs/MANAGED-LINUX.md`「Build the ACK image」）：
   ```sh
   bash extras/managed-node/prepare-image.sh <HUB_URL> <release.pub> RELEASE_COMMIT /tmp/fleet-node-image linux-amd64
   docker build --platform linux/amd64 -t <REGISTRY>/fleet-managed-node:RELEASE_COMMIT /tmp/fleet-node-image
   docker push <REGISTRY>/fleet-managed-node:RELEASE_COMMIT      # 记下 digest，之后一律按 digest 部署
   ```
2. 渲染并先空跑：
   ```sh
   python3 extras/managed-node/render.py --image <REGISTRY>/fleet-managed-node@sha256:<DIGEST> \
     --hub <HUB_URL> --storage-class <STORAGE_CLASS> --pull-secret <PULL_SECRET> > /tmp/fleet-linux.json
   kubectl apply --dry-run=server -f /tmp/fleet-linux.json
   ```
   出口、镜像缓存、凭据集中等开关（`--egress-*`、`--cluster-caches`、`--cred-central` …）按文档那一节选。
3. 起节点：
   ```sh
   kubectl create namespace fleet-workers
   kubectl -n fleet-workers create secret generic fleet-linux-join --from-file=machine=<加入码文件>
   kubectl apply -f /tmp/fleet-linux.json
   kubectl -n fleet-workers rollout status statefulset/fleet-linux --timeout=15m
   kubectl -n fleet-workers delete secret fleet-linux-join      # 码用过就删
   ```
   要入口端口：先只渲染 Service 拿到 `<LB_ADDRESS>`，再带 `--entry-host <LB_ADDRESS>` 渲染一次（文档里两遍的顺序）。
4. 共享层（凭据代理、出口、缓存）：`kubectl kustomize deploy/k8s/fleet-workers`，按各 README 应用。
5. 新节点默认不受信任：`fleet-node-trust.sh set <NODE> untrusted` 确认一次。
6. 开号：`fleet hub accounts assign <PRINCIPAL> --host <NODE> --login <LOGIN>`（见 `login-lifecycle`）。

## 怎么验收

- 节点里：`fleet-node-supervisor.py status --check` 退出 0；`readlink /var/db/fleet-node/runtime/current` 是 stable 的提交。
- 出口：pod 里 `curl -m3` 云元数据地址被拒（地址和命令照 `docs/MANAGED-LINUX.md`「Egress guard」）；`iptables -F` 报 Permission denied。
- 凭据：会话里 `env | grep -i token` 为空；`fleet-cred-scan.py scan --no-hub` 干净。
- 入口：`fleet hub machines` 有 `<NODE>` 在线；`fleet route <NODE>` 能到；派一个会话能回话。
- `docs/MANAGED-LINUX.md`「Acceptance evidence」逐条打钩。

## 怎么回滚

- 节点自己跟 stable 升级（`fleet-node-update.py`），换版后体检出新的 FAIL 自动退回上一版。
- 镜像回退：StatefulSet 是 `OnDelete`——把镜像 digest 改回上一个，`kubectl apply`，再 `kubectl -n fleet-workers delete pod <NODE>`。**从不 `--force`**（会丢正在写的盘）。
- 不让节点自己升级、只认镜像：`FLEET_NODE_UPDATE_OWNER=image`。
- 整个撤掉：先在入口把人挪走（`login-lifecycle`），`fleet-node-revoke.sh <NODE>`，再删 StatefulSet；持久卷按数据保留策略单独决定，不顺手删。
