# ccquota-hub 运维手册

> 2026-10-06 从 24haowan-monorepo `doc/k8s-yamls/ccquota/RUNBOOK.md` 搬来（EPIC #1982 C1，issue #1983）。
> 发布见 [README.md](README.md)。

入口有两种形态（#2125，EPIC #2119）：

| | 单份 SQLite（生产，切换前） | 两份滚动（base，切换后） |
|---|---|---|
| 清单 | `overlays/prod` 带 `components: [sqlite]`（`components/sqlite-single`） | `base` 原样 |
| 副本 · 发布 | 1 份，`Recreate`：每次发布 30–60 秒整站不可用 | 2 份，`RollingUpdate` maxUnavailable 0 / maxSurge 1：0 秒 |
| 数据 | 一块 RWO 云盘（`ccquota-data`）上的 SQLite 文件 | 托管 Postgres（RDS），Secret `ccquota-db` |
| 会卡住的 | 盘的「解绑—挂载」（下一节） | 没有盘 |

一份 pod 怎么走（滚动形态）：新 pod 只有 `/readyz` 说库连得上、迁移版本够了才接流量；
旧 pod 先 `preStop` 睡 5 秒（等 ingress 把它摘掉），再收 SIGTERM，手上的请求最多再给
`CCQUOTA_SHUTDOWN_GRACE`（25 秒）做完。发布、删 pod、节点排空都是这一条路；PDB 保证排空时
至少留一份。每次发布 hub-deploy 每秒探一次 `/healthz` + 一次写，摘要里 `downtime_seconds=<n>`
就是不可用秒数；CI 的 `hub-rolling` 在 kind 里把三次发布 + 删 pod + 回退各做一遍，必须是 0。

下面「卡在 ContainerCreating」「快照与恢复」「数据盘水位」只适用于**单份 SQLite 形态**。

## 症状：pod 卡在 ContainerCreating，服务 503

```
MountVolume.MountDevice failed for volume "d-xxxx" : rpc error: code = Internal
desc = NodeStageVolume: ADController Enabled, but disk d-xxxx can't be found:
disk attached but not found by serial xxxx
```

控制面认为盘已经 attach 到这个节点，节点内核里却没有对应的块设备
（`/dev/disk/by-id/virtio-<serial>` 不存在）。重试循环因为「已 attach」不再重新下发
attach，于是自锁——**在同一个节点上等多久都不会好**。

### 先做这一步

```bash
kubectl -n new-deploy delete pod -l app=ccquota-hub
```

多半会调度到另一个节点，然后 20~30 秒起来。**只有再次落到同一节点**才需要：

```bash
kubectl cordon <node>
kubectl -n new-deploy delete pod -l app=ccquota-hub
kubectl uncordon <node>          # ★ 起来之后立刻解除，别把节点长期扣着
```

### 不要做的事

- **不要**急着断定「节点坏了」。先看那个节点上有没有**同存储类**的其它 pod 正常跑：

  ```bash
  kubectl get pods -A -o wide | awk '$8=="<node>"'
  ```

  2026-09-13 那次，故障节点上另有 2 个 `alicloud-disk-topology-alltype` 的 pod 正常运行
  —— 所以问题在这一块盘的 attach 状态，不在节点。
- **不要**手工删 VolumeAttachment。pod 删掉之后它会自己清理；确认用：

  ```bash
  kubectl get volumeattachments | grep <disk-id>
  ```

## 根因与已做的修复（2026-09-13）

同一个 CSI 驱动的两半版本对不上：

| 组件 | 角色 | 当时版本 |
|---|---|---|
| `deploy/csi-provisioner` | 控制器，跑 ADController 的 attach 逻辑 | `csi-plugin:v1.36.2` |
| `ds/csi-plugin` | 节点插件，跑 NodeStageVolume | `csi-plugin:v1.35.1` ← 落后一个小版本 |

控制器标记已 attach，老一版的节点插件按 serial 找不到设备，正好是上面那句报错。
节点 kubelet 升到 1.36 之后（`.154`/`.185`）撞上的概率变高。

已把节点插件升到与控制器一致：

```bash
kubectl -n kube-system patch ds csi-plugin --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/3/image",
   "value":"registry-cn-shenzhen-vpc.ack.aliyuncs.com/acs/csi-plugin:v1.36.2"},
  {"op":"replace","path":"/spec/template/spec/initContainers/0/image",
   "value":"registry-cn-shenzhen-vpc.ack.aliyuncs.com/acs/csi-plugin:v1.36.2-init"}
]'
kubectl -n kube-system rollout status ds/csi-plugin
# 回滚：kubectl -n kube-system rollout undo ds/csi-plugin
```

滚动策略 `maxUnavailable: 20%`，一次一个节点；已有挂载由 kubelet 持有，不受影响。

**集群升级后请复查这两个版本是否还一致** —— 它们分开升级，偏斜会再次发生：

```bash
kubectl -n kube-system get deploy csi-provisioner -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n kube-system get ds csi-plugin -o jsonpath='{.spec.template.spec.containers[3].image}{"\n"}'
```

## 停机的实际代价：零数据

不要因为 hub 短暂 503 就慌。这条链路是按「宁可不搬也不搬错」设计的：

- **agent** 推不上去就在本地排队（`~/.ccquota/agent/`），恢复后补送。
- 库本身没有写入风险：故障发生在挂载阶段，进程根本没起来。

## 发布与回滚

发布 = 合并到 master，由 `hub-deploy` 工作流打包、推送、快照、apply、核对 `/version`，见同目录
[README.md](README.md)。**不再手工 `docker build` / `kubectl set image`**，也不要手工 `kubectl apply -k`
（manifest 里的镜像 tag 是占位符）。

### 快照与恢复

`hub-deploy` 每次 apply 前自动拍一份 `/data/backup-hubdeploy-<UTC>-<发布前的 tag>.db`，只留最新 3 份
（人手拍的 `backup-*` 它不碰）。手工拍一份：

```bash
POD=$(kubectl -n new-deploy get pod -l app=ccquota-hub -o name | head -1)
# pod 里没有 sqlite3，用 VACUUM INTO 取事务一致快照（对活库安全，只读原库）
kubectl -n new-deploy exec $POD -c ccquota -- /data/snapshot-tool /data/ccquota.db \
  /data/backup-$(date -u +%Y%m%dT%H%M%SZ).db
```

`/data/snapshot-tool` 是一个只做 `VACUUM INTO` 的静态 Go 小工具，2026-09-13 放进
PVC 备用。394MB 的库约 15 秒。**不要**用 `kubectl cp` 直接拷 `ccquota.db`：
库在 WAL 模式下持续写入，拷出来是撕裂的。

> 往 pod 里传文件很慢（实测约 9 KB/s，5MB 要十分钟）。要在 pod 内跑新二进制做演练，
> 先 `gzip -9` 再 `kubectl cp`，并核对字节数——传输被打断不会报错，只会给你一个截断的文件。

**恢复**（回滚跨了库迁移时）：先用 workflow_dispatch 把镜像换回旧 tag，再在 pod 里把对应快照换回库
（停写：`kubectl -n new-deploy scale deploy/ccquota-hub --replicas=0` 后用一个挂同一 PVC 的临时 pod
`mv` 文件，再 scale 回 1）。这一步要管理员 kubeconfig，发布角色做不了。

### 库迁移

编号迁移在 hub 启动时各跑一次，记在库里的 `hub_migrations` 表（`id`、`name`、`applied_at`、
`detail` = 每张表删了 / 丢了多少行）。跑的那次启动会在日志里留一行：

```bash
kubectl -n new-deploy logs deploy/ccquota-hub -c ccquota | grep 'store: migration'
```

| 编号 | 名字 | 做什么 | 回滚 |
|---|---|---|---|
| 1 | `remove-company-business`（#1987） | 删 `usage_events` / `usage_hourly` / `accounts` / `subscription_plans` 等带 `source` 列的表里 **source = gateway / vendor_bill / voice** 的行（Claude、Codex 的行一行不动）；丢掉 `growth_facts`、`repo_*`、`share_links`、`finding_notices` 这些表；把 repo / growth 的上报令牌标成已退役 | 镜像换回迁移前的 tag + 用 `hub-deploy` 在这次发布前拍的快照恢复（上面「恢复」一节） |

**发布前演练**（#2050）：`hub-deploy` 拍完快照、apply 之前，把新镜像作为临时容器（ephemeral
container）塞进正在跑的 hub pod，挂 `/data`，对快照的一份拷贝跑 `ccquota hub --migrate-only`。
跑不过 ⇒ 不 apply，job 红，线上 pod 一直没停。本地复现同一件事：
`ccquota hub --migrate-only --db <快照的拷贝>`（不给拷贝、给不存在的文件都会拒绝）。
演练本身的演练：workflow_dispatch 勾 `simulate_migration_failure`。

迁移没有反向脚本：回滚只走「旧镜像 + 快照」。删掉的公司业务数据只在那份快照里还有。



**保留策略：盘里只留最近 2 份 `backup-*`，更早的挪到 `oss://haowan24-archive/ccquota-hub-backups/`**
（私有桶、IA 存储；`SHA256SUMS.txt` 第一列是解压后 `.db` 的 sha256）。一条命令，先校验再删：

```bash
tools/ccquota-archive-backups.sh --dry-run   # 在 24haowan-monorepo 里跑；看会挪哪些
tools/ccquota-archive-backups.sh             # 挪；任一份校验不过，那一份就留在盘里、退出码 1
```

为什么要有这条：2026-10-06 盘用到 89%（19.5G 里只剩 2.1G），库本身才 2.2G —— 占地方的是 15 份
升级前快照（约 15G），一份都没在回滚里用上过。脚本头注释写了怎么搬、为什么不能 `kubectl exec … cat`。

**库为什么会长**（2026-10-06 量的，`dbstat`）：`usage_events` + 4 个索引占 1.66G / 2.2G，10 月起每天约 8 万行
（网关那一档的 `details_json` 占大头），盘上约 100MB/天。hub 按 `--retention-days`（deploy/k8s/base/deployment.yaml，
2026-10-06 起 60 天）每天删到期的原始行；按小时汇总的 `usage_hourly` 永远不删，所以花费总数不受影响。
`account_usage_observations`（约 140MB）和 `limit_snapshots`（约 80MB）hub 从不剪，一天约 6MB ——
要剪得改 claude-fleet 仓 tokenledger 的 `pruneLoop`。SQLite 删行不缩文件，只复用空页。

**告警**：hub pod 里的 `disk-watch` 边车每 5 分钟 `df /data`，≥ 80% 记一条 kf-notify（`alerts.prod`，
source `ccquota:disk-watch`，dedupKey `ccquota:data-disk-high`，6 小时内同级别不重复；≥ 90% 升 error），
回落到 75% 以下记一条恢复。在 ops 收件箱里看（kf-notify 只记录、不推企微）。演练一次：

```bash
kubectl -n new-deploy exec deploy/ccquota-hub -c disk-watch -- \
  env THRESHOLD_PCT=1 DRILL=1 sh /tmp/disk-watch.sh once     # 标题带「[演练]」，dedupKey 带 drill: 前缀
kubectl -n new-deploy logs deploy/ccquota-hub -c disk-watch --tail=5   # 平时的水位读数也在这里
```

**收到告警时**，按顺序：

1. `kubectl -n new-deploy exec deploy/ccquota-hub -c ccquota -- ls -la /data` —— 先看是不是快照又堆起来了，
   是就跑上面的脚本。
2. 是库本身长大：看 `--retention-days` 是不是被改大了、是不是哪一档写入暴涨（`/v1/summary` 按 source 看）。
3. 都不是，就扩盘：改 `deploy/k8s/base/pvc.yaml` 的 `storage` 再 `kubectl apply -f` 它。
   云盘**在线扩容**，pod 不重启；判据是 `kubectl get pvc ccquota-data` 的 CAPACITY 变了、pod 里 `df -h /data`
   变大。尺寸按「至少是库的 2.5 倍」（库 + 一份 VACUUM INTO 快照 + 余量）。只能扩、不能缩。

## 换库：SQLite → 托管 Postgres（#2122，EPIC #2119）

一条命令搬：`ccquota db migrate`。整份拷贝是**一个 Postgres 事务**：中途被杀（进程、pod、网络）目标库原样不动，
重跑就是干净重来；`--dry-run` 是同一个事务最后回滚，演练拷的、核对的和正式搬一模一样，目标库什么都不留
（只留 hub 本来就会建的空表结构）。`--verify` 在同一事务里逐表比 **行数 + 按主键排序的内容 SHA-256**；
`ccquota db verify` 可单独跑，只读两边。输出只有表名、行数、摘要和 `host/库名`——**不打印任何行的值，
也不打印连接串**。

| 拒绝 | 为什么 | 怎么办 |
|---|---|---|
| `the source predates hub migration N` | 源库是旧版 hub 留下的，表结构和目标对不上 | 对**拷贝**跑 `ccquota hub --migrate-only --db <拷贝>`，再搬 |
| `the target already holds a finished move` | 目标库里已有一次完成的搬家（`db_move_log`），之后 hub 可能已写过 | 确认要覆盖才加 `--overwrite` |
| `the target is not empty` | 目标库里有 hub 写过的数据 | 同上；换一个空库更稳 |
| `the target has no table for …` / `no column …` | 二进制比写源库的 hub 旧 | 用同一版本的镜像跑 |

前提（批后，你来做）：

1. RDS Postgres 就绪。Secret `ccquota-db` 两个 key：`db-url`（连接串）和 `replica-token`（两份入口互相转交
   机器连接用的共享令牌，#2124）——在你自己的终端敲，别进任何文件或单子：
   ```bash
   kubectl -n new-deploy create secret generic ccquota-db \
     --from-literal=db-url='postgres://…?sslmode=require' \
     --from-literal=replica-token="$(openssl rand -hex 32)"
   ```
2. 部署 Role 能管 PodDisruptionBudget（[README.md](README.md)「Who may do what」那段 yaml，24haowan-monorepo 里改）。
3. #2190 已合并（`fleet login`、客户端租约、实时会话在两份入口之间不丢）。
4. 准备好**切换 PR**：只删 `overlays/prod/kustomization.yaml` 里 `components:` / `  - sqlite` 两行。
   它的 hub-deploy `check` 会证明删完的渲染是完整的滚动形态（`mode=postgres`）。

### 1. 演练（不停写，任何时候都可以）

```bash
POD=$(kubectl -n new-deploy get pod -l app=ccquota-hub -o name | head -1)
SNAP=/data/backup-move-rehearsal-$(date -u +%Y%m%dT%H%M%SZ).db
kubectl -n new-deploy exec $POD -c ccquota -- /data/snapshot-tool /data/ccquota.db $SNAP
# 连接串只给这一条命令，经环境变量，不上命令行：
kubectl -n new-deploy get secret ccquota-db -o jsonpath='{.data.db-url}' | base64 -d \
  | kubectl -n new-deploy exec -i $POD -c ccquota -- sh -c \
      'read -r U; CCQUOTA_DB_URL="$U" ccquota db migrate --from '$SNAP' --dry-run --verify'
kubectl -n new-deploy exec $POD -c ccquota -- rm $SNAP
```

判据：最后一行 `verify: N table(s), N match, 0 differ`、退出码 0。末行的耗时 ≈ 正式搬时停写的长度——
超过 1 分钟就先别切，回单子上说。

### 2. 正式切换（你定时间）

停写从第 2 步算到第 4 步两份新 pod 就绪；读一直不停（旧 pod 只读服务到新 pod 接手）。

1. **停自动发布，合切换 PR**：`gh variable set HUB_DEPLOY_PAUSED --body 1 --repo verkyyi/claude-fleet`，再合并
   上面第 4 条的切换 PR（暂停中，什么都不发）。
2. **只读**：`kubectl -n new-deploy set env deploy/ccquota-hub CCQUOTA_READONLY=1`（滚一次）。
   起来后 `curl -s https://<hub>/healthz` 带 `"mode":"read-only"`；写接口一律 `503` + `Retry-After: 15`，
   读接口照常；store 自己也只读，后台的写（心跳、清理）报错而不是写进旧库后丢掉。
3. **搬 + 核对**：
   ```bash
   POD=$(kubectl -n new-deploy get pod -l app=ccquota-hub -o name | head -1)
   kubectl -n new-deploy get secret ccquota-db -o jsonpath='{.data.db-url}' | base64 -d \
     | kubectl -n new-deploy exec -i $POD -c ccquota -- sh -c \
         'read -r U; CCQUOTA_DB_URL="$U" ccquota db migrate --from /data/ccquota.db --verify'
   ```
   有任何 `DIFF` 它自己回滚、退出码 1 —— 不往下走：`kubectl -n new-deploy set env deploy/ccquota-hub CCQUOTA_READONLY-`
   回到原样，revert 切换 PR，删掉 `HUB_DEPLOY_PAUSED`。
4. **换成两份**（管理员 kubeconfig，在切换 PR 合并后的 master 干净 checkout 里；这是唯一一次手工 apply——
   用线上正在跑的镜像，不发新版本）：
   ```bash
   LIVE=$(kubectl -n new-deploy get deploy ccquota-hub -o jsonpath='{.spec.template.spec.containers[?(@.name=="ccquota")].image}')
   kubectl kustomize deploy/k8s/overlays/prod | sed "s#image: .*:set-by-hub-deploy\$#image: $LIVE#" > /tmp/hub-switch.yaml
   grep -c 'set-by-hub-deploy' /tmp/hub-switch.yaml   # 必须是 0
   kubectl apply -f /tmp/hub-switch.yaml && kubectl -n new-deploy set env deploy/ccquota-hub CCQUOTA_READONLY-
   kubectl -n new-deploy rollout status deploy/ccquota-hub --timeout=8m
   ```
   `apply` 不会去掉第 2 步 `set env` 加的只读（那一项不在上次 apply 的记录里），所以紧跟一条 `set env … CCQUOTA_READONLY-`；
   两次改动之间控制器直接滚到最后那版。策略在同一次 apply 里换成 RollingUpdate：旧的单份 pod 只读服务到两份新 pod
   就绪才走。判据：`kubectl -n new-deploy get pod -l app=ccquota-hub` 两份 Ready；`/healthz` 不再有 `mode`；
   `kubectl -n new-deploy logs deploy/ccquota-hub -c ccquota | grep 'database: Postgres'`；
   `curl -s -X POST https://<hub>/v1/deploy-probe` 回 200。
5. **恢复自动发布**：`gh variable delete HUB_DEPLOY_PAUSED --repo verkyyi/claude-fleet`。之后第一次真发布的
   hub-deploy 摘要里 `downtime_seconds=<n>` 那一行就是这批的上线证据，应为 0。
6. **旧盘留 7 天**：PVC `ccquota-data` 不再在渲染里，但 apply 从不删东西，它和 `/data/ccquota.db` 原样留着。
   第 7 天：`kubectl -n new-deploy delete pvc ccquota-data`（管理员）。

### 3. 退回（7 天内）

1. `gh variable set HUB_DEPLOY_PAUSED --body 1 --repo verkyyi/claude-fleet`，revert 切换 PR（`components: [sqlite]` 回来）。
2. 管理员 kubeconfig，在 revert 后的 master 上，同第 4 步的 `LIVE` / `kubectl kustomize … | sed … | kubectl apply -f -`，
   再 `kubectl -n new-deploy delete pdb ccquota-hub`（apply 不删它；单份上留着它会挡住节点排空）。
   这一次是 `Recreate`：两份停掉、单份挂盘起来，30–60 秒不可用。
3. `kubectl -n new-deploy rollout status deploy/ccquota-hub`，`/healthz` 200 后删掉 `HUB_DEPLOY_PAUSED`。

hub 回到 `/data/ccquota.db`，也就是第 2 步只读那一刻的数据。⚠️ 切过去之后写进 Postgres 的东西不在旧库里，
没有反向搬家；所以退回要早——发现不对就在当晚退。

## fleet 的两把 Secret（#11200 起，多机统一入口）

hub 开了 `CCQUOTA_FLEET=1` 之后多挂两把密钥，**各自独立 Secret，不进库、不进仓库**，Deployment 对它们
刻意不写 `optional`（缺了起不来，而不是静默关着）：

| Secret（ns new-deploy） | key | 挂到 | 是什么 | 生成 |
|---|---|---|---|---|
| `ccquota-ssh-ca` | `ca` | `/secrets/ssh-ca/ca`（`CCQUOTA_FLEET_SSH_CA_KEY`） | SSH 用户 CA **私钥**（OpenSSH、无口令），hub 用它签 12 小时的用户证书 | `ssh-keygen -t ed25519 -N '' -C fleet-user-ca -f ca` |
| `ccquota-fleet-cred-key` | `key` | `/secrets/cred-key/key`（`CCQUOTA_FLEET_CRED_KEY_FILE`） | 凭据保险箱的 AES-256-GCM 密钥，32 字节 base64 | `openssl rand -base64 32 > key` |

```bash
kubectl -n new-deploy create secret generic ccquota-ssh-ca --from-file=ca=./ca
kubectl -n new-deploy create secret generic ccquota-fleet-cred-key --from-file=key=./key
kubectl -n new-deploy label secret ccquota-ssh-ca ccquota-fleet-cred-key app=ccquota-hub
```

- **CA 公钥**（`ca.pub`）不是秘密：贴在建它的那张单子的评论里（首发是 #11200），节点侧 sshd 的
  `TrustedUserCAKeys` 要用。私钥文件用完即删，别留在任何 checkout 里。
- **换 CA** = 新建密钥对、`kubectl create secret … --dry-run=client -o yaml | kubectl replace -f -`、滚一次
  hub；旧证书最多 12 小时自然过期，节点侧把新公钥追加进 `TrustedUserCAKeys` 即可平滑过渡（README 的
  `CCQUOTA_FLEET_SSH_CA_PUB` 就是给轮换期多信一把公钥用的）。
- **换保险箱密钥不能这么换**：库里每条凭据都是用旧密钥封的，换了密钥 = 全部读不出来。要换先把 KMS 那条路
  开起来（`CCQUOTA_FLEET_CRED_KMS_KEY_ID`，README「The vault key in Aliyun KMS」一节有迁移顺序），不要
  直接替换这个 Secret。
- 这两把都**不在** `tools/export-cluster-state.sh` 的导出集里（Secret 按设计不进仓库），所以漂不漂只能
  靠 Deployment 起不起得来说话。

## 发布包（#2335 代码，#2366 接上）

入口按 stable 打包、签名每个发布版（`/v1/fleet/release/*`），存在 OSS 桶
`haowan24-fleet-releases`（cn-shenzhen，private，VPC 内网地址）里，两个副本同时挂在 `/releases`。

| 东西 | 谁建 | 内容 |
|---|---|---|
| OSS 桶 + RAM 用户 `svc-fleet-release-oss`（策略 `fleet-release-oss-rw`，只此一桶） | 人，控制台 | — |
| Secret `ccquota-release-oss` | 人 | 键 `akId` / `akSecret`（OSS CSI 的 nodePublishSecretRef 格式） |
| Secret `ccquota-release-key` | 人 | 键 `release-key`：`ccquota release keygen` 产出的 ed25519 私钥文件；只读挂到 `/etc/ccquota-release`（0440，fsGroup 10001） |
| PV `ccquota-releases-oss` + PVC `ccquota-releases` | 人，一次 | `overlays/prod/release-volume.yaml`——部署 Role 建不了 PV / PVC，所以它不在 kustomization 里 |
| 环境变量 + 两个挂载 | hub-deploy | `overlays/prod/deployment-release.yaml` |

```sh
kubectl apply -n new-deploy -f deploy/k8s/overlays/prod/release-volume.yaml
kubectl -n new-deploy get pvc ccquota-releases     # Bound 之后才合并带挂载的那次发布
```

- PVC 没 Bound 就发布：新 pod 挂不上卷，滚动超时，hub-deploy 自动回滚——旧 pod 一直在服务。
- 发布前的 `--check` 用新 env、旧 pod 的卷跑：hub-deploy 把只有新渲染才挂的路径写进
  `CCQUOTA_CHECK_UNMOUNTED`，钥匙文件在其中时 `--check` 报告而不拒绝，真正的启动才读它。
- 桶里的布局：`<sha>/b<unix>-<hex>/` 一次构建（就地写，签名最后写，之后不改不改名），
  `<sha>/current` 指向在用的那次（单文件 rename）。ossfs 上目录 rename 是逐个对象复制再删，
  不原子，两个副本又会同时构建同一个 stable——所以不用目录 rename。
- 关掉：删 `deployment-release.yaml` 和 kustomization 里它那一行；桶和 PV 是 Retain，留着无害。
- 公钥：`curl -fsS https://claudefleet.24haowan.com/v1/fleet/release/key`。换钥匙 = 新 keygen、
  `kubectl create secret … --dry-run=client -o yaml | kubectl replace -f -`、滚一次；已装机器钉的旧公钥要跟着换。
