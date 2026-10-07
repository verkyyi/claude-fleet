# ccquota-hub 运维手册

> 2026-10-06 从 24haowan-monorepo `doc/k8s-yamls/ccquota/RUNBOOK.md` 搬来（EPIC #1982 C1，issue #1983）。
> 发布见 [README.md](README.md)。

单副本 + 单块 RWO 云盘（`ccquota-data`，`alicloud-disk-topology-alltype`，20Gi）。
这是**刻意**的设计：hub 是一个 Go 二进制加一个 SQLite 文件，没有要预置的数据库。
代价是任何一次重启都要经历一次「解绑—挂载」，而那一步会出事。

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

- **不要**改 `strategy` —— 已经是 `Recreate`，不是滚动更新抢占 PVC 的问题。
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
