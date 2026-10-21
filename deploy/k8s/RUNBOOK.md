# ccquota-hub 运维手册

> 2026-10-06 从 acme-monorepo `doc/k8s-yamls/ccquota/RUNBOOK.md` 搬来（EPIC #1982 C1，issue #1983）。
> 发布见 [README.md](README.md)。
> 下文的 `overlays/prod` · `updating/prod` · `credproxy/prod` · `*/fleet-workers` 是部署自己的覆盖层，
> 我们的在私有部署仓库里（#3630）：手工 `kubectl` 之前先把它的 `k8s/` 叠到本仓库的 `deploy/k8s/` 上
> （`cp -R <部署仓库>/k8s/. deploy/k8s/`，[README.md](README.md)）。它是哪个仓库：
> `gh variable get FLEET_DEPLOY_OVERLAY_REPO -R verkyyi/claude-fleet`（公开仓库里不写它的名字）；
> fleet 机器上 fleet 托管着它，检出在 `~/projects/<name>`（`fleet-repo.sh list`）。

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
   "value":"registry-region-a-vpc.ack.aliyuncs.com/acs/csi-plugin:v1.36.2"},
  {"op":"replace","path":"/spec/template/spec/initContainers/0/image",
   "value":"registry-region-a-vpc.ack.aliyuncs.com/acs/csi-plugin:v1.36.2-init"}
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
| 2 | `hub-users-principal`（#3603） | `hub_users` 改以账号（principal）为键，每人补一条 github 登录方式 | 同上 |
| 3 | `remove-spot-nodes`（#4797） | SPOT 执行节点下线：丢掉 `fleet_spot_nodes` 表；删掉只有它读的设置 `fleet.spot` / `fleet.spot_weight` / `hub.legacy_migrated.fleet.spot` / `spot.want`；`detail` 另记还标着 `node_kind=ephemeral` 的端点数（原样保留，已无人读） | 镜像换回迁移前的 tag：旧镜像启动时 `CREATE TABLE IF NOT EXISTS` 把空表建回来，设置读回默认（`fleet.spot` = off）；要原来的行就用这次发布前的快照恢复（上面「恢复」一节）。上线时表里是 0 行 |
| 4 | `remove-hub-tickets`（T477，#4898 续） | hub 自己的单据下线：丢掉 `fleet_tickets` / `fleet_ticket_comments` / `fleet_ticket_seq` / `fleet_ticket_index` 四张表，`detail` 记每张表丢掉的行数；任务记录 `fleet_tasks` 不动 | 镜像换回迁移前的 tag：旧镜像启动时 `CREATE TABLE IF NOT EXISTS` 把空表建回来；要原来的行就用这次发布前的快照恢复（上面「恢复」一节） |
| 5 | `remove-pool-move-when-full`（T543） | 设置「满了就挪会话」下线：删掉 `fleet_settings` 里的 `pool.move_when_full` 与 `hub.legacy_migrated.pool.move_when_full` 两行，`detail` 记删了几行 | 镜像换回迁移前的 tag：旧镜像读不到这行就按默认 off；要原值用这次发布前的快照恢复 |

**发布前演练**（#2050）：`hub-deploy` 拍完快照、apply 之前，把新镜像作为临时容器（ephemeral
container）塞进正在跑的 hub pod，挂 `/data`，对快照的一份拷贝跑 `ccquota hub --migrate-only`。
跑不过 ⇒ 不 apply，job 红，线上 pod 一直没停。本地复现同一件事：
`ccquota hub --migrate-only --db <快照的拷贝>`（不给拷贝、给不存在的文件都会拒绝）。
演练本身的演练：workflow_dispatch 勾 `simulate_migration_failure`。

迁移没有反向脚本：回滚只走「旧镜像 + 快照」。删掉的公司业务数据只在那份快照里还有。



**保留策略：盘里只留最近 2 份 `backup-*`，更早的挪到 `oss://haowan24-archive/ccquota-hub-backups/`**
（私有桶、IA 存储；`SHA256SUMS.txt` 第一列是解压后 `.db` 的 sha256）。一条命令，先校验再删：

```bash
tools/ccquota-archive-backups.sh --dry-run   # 在 acme-monorepo 里跑；看会挪哪些
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
2. 部署 Role 能管 PodDisruptionBudget（[README.md](README.md)「Who may do what」那段 yaml，acme-monorepo 里改）。
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

1. **停自动发布，合切换 PR**：`bin/fleet-hub-pause.sh on --why <原因>`（已在车道里排着的列车也拦得住；仓库变量只拦设了之后才排队的），再合并
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
   回到原样，revert 切换 PR，`bin/fleet-hub-pause.sh off`。
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
5. **恢复自动发布**：`bin/fleet-hub-pause.sh off`。之后第一次真发布的
   hub-deploy 摘要里 `downtime_seconds=<n>` 那一行就是这批的上线证据，应为 0。
6. **旧盘留 7 天**：PVC `ccquota-data` 不再在渲染里，但 apply 从不删东西，它和 `/data/ccquota.db` 原样留着。
   第 7 天：`kubectl -n new-deploy delete pvc ccquota-data`（管理员）。

### 3. 退回（7 天内）

1. `bin/fleet-hub-pause.sh on --why <原因>`（已在车道里排着的列车也拦得住；仓库变量只拦设了之后才排队的），revert 切换 PR（`components: [sqlite]` 回来）。
2. 管理员 kubeconfig，在 revert 后的 master 上，同第 4 步的 `LIVE` / `kubectl kustomize … | sed … | kubectl apply -f -`，
   再 `kubectl -n new-deploy delete pdb ccquota-hub`（apply 不删它；单份上留着它会挡住节点排空）。
   这一次是 `Recreate`：两份停掉、单份挂盘起来，30–60 秒不可用。
3. `kubectl -n new-deploy rollout status deploy/ccquota-hub`，`/healthz` 200 后`bin/fleet-hub-pause.sh off`。

hub 回到 `/data/ccquota.db`，也就是第 2 步只读那一刻的数据。⚠️ 切过去之后写进 Postgres 的东西不在旧库里，
没有反向搬家；所以退回要早——发现不对就在当晚退。

## fleet 的两把 Secret（#11200 起，多机统一入口）

hub 开了 `CCQUOTA_FLEET=1` 之后多挂两把密钥，**各自独立 Secret，不进库、不进仓库**，Deployment 对它们
刻意不写 `optional`（缺了起不来，而不是静默关着）：

| Secret（ns new-deploy） | key | 挂到 | 是什么 | 生成 |
|---|---|---|---|---|
| `ccquota-ssh-ca` | `ca` | `/secrets/ssh-ca/ca`（`CCQUOTA_FLEET_SSH_CA_KEY`） | SSH 用户 CA **私钥**（OpenSSH、无口令），hub 用它签 12 小时的用户证书 | `ssh-keygen -t ed25519 -N '' -C fleet-user-ca -f ca` |
| `ccquota-ssh-host-ca` | `ca` | `/secrets/ssh-host-ca/ca`（`CCQUOTA_FLEET_SSH_HOST_CA_KEY`） | SSH **主机** CA 私钥（T743）：独立生成、**不由用户 CA 推出**，hub 用它给每台家机器的入口钥匙签 30 天的主机证书。可选：没建这把 Secret ⇒ 不签主机证书，其余照旧；是用户 CA 那把 ⇒ hub 拒绝启动 | 见下「主机 CA」 |
| `ccquota-fleet-cred-key` | `key` | `/secrets/cred-key/key`（`CCQUOTA_FLEET_CRED_KEY_FILE`） | 凭据保险箱的 AES-256-GCM 密钥，32 字节 base64 | `openssl rand -base64 32 > key` |

**主机 CA（T743）**——在运维自己的机器上生成，私钥不进任何会话 / 日志 / 单子 / PR：

```bash
umask 077
ssh-keygen -t ed25519 -N '' -C fleet-host-ca -f host-ca          # 独立的一把，与用户 CA 无关
kubectl -n new-deploy create secret generic ccquota-ssh-host-ca --from-file=ca=./host-ca
kubectl -n new-deploy label secret ccquota-ssh-host-ca app=ccquota-hub
# 加密备份交运维保险箱（口令另存，不与备份放一起），然后删明文
openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -in host-ca -out host-ca.enc
shred -u host-ca 2>/dev/null || rm -P host-ca
kubectl -n new-deploy rollout restart deployment/ccquota-hub
```

`host-ca.pub` 不是秘密（hub 也经路线表的 `host_ca` 发给客户端）。**轮换**：生成新的一把、换 Secret、重启——
客户端下次 `fleet connect` 写入新的 `@cert-authority` 行，各家机器入口在下一次可达上报（≤5 分钟）拿到新证书；
新旧之间没签上的那几分钟，客户端仍按 hub 列出的逐把钥匙认。**吊销某台机器**：证书 30 天自然过期；要立即作废就轮换主机 CA。

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

## 换操作员令牌 viewer-token（#4122）

`ccquota` Secret 的 `viewer-token`（pod 里的 `CCQUOTA_VIEWER_TOKEN`）是入口的**管理员**令牌：看板、查询 API、
MCP、`/v1/fleet/*` 的管理员口都认它。泄露过（进过 argv、日志、聊天）就整把换，不留旧值。

用它的地方（只写位置）：

| 位置 | 怎么跟上 |
|---|---|
| Secret `new-deploy/ccquota` 的 `viewer-token` | 下面的命令换 |
| 仓库密钥 `FLEET_HUB_VIEWER_TOKEN`（`mac-follow.yml` 的 `fleet-train-macos.sh pick` 读 `/v1/fleet/ci-runners`） | 同一管道 `gh secret set` |
| 「从 hub pod 环境现读」的脚本 / 文档（`kubectl exec … printenv CCQUOTA_VIEWER_TOKEN` 一类） | 换完自然跟上 |
| 个人电脑上的 `~/.ccquota/viewer-token` / `CCQUOTA_VIEWER_TOKEN`（fleet-hub-sessions / fleet-release 等操作者脚本读它） | 谁有谁从 Secret 重取 |
| 浏览器里 `?token=` 换来的 cookie | 失效，用 GitHub 登录 |

官网里程表的发布器（monorepo `tools/ccquota-publish.sh`）自 monorepo #11768 起只读公开的 `/meter.json`，
**不要任何令牌**（`/odometer.svg` 随 #4904 去掉）。

全程不打印、不落盘、不进 argv（`--patch-file=/dev/stdin`、curl `-K -`、`gh secret set` 读 stdin）：

```bash
NS=new-deploy HUB=https://<入口域名>
code(){ printf 'header = "Authorization: Bearer %s"\n' "$1" | curl -s -o /dev/null -w '%{http_code}' -K - "$HUB$2"; }
OLD=$(kubectl -n $NS get secret ccquota -o jsonpath='{.data.viewer-token}' | base64 -d)
python3 -c 'import secrets,json,base64;print(json.dumps([{"op":"replace","path":"/data/viewer-token","value":base64.b64encode(secrets.token_hex(24).encode()).decode()}]))' \
  | kubectl -n $NS patch secret ccquota --type=json --patch-file=/dev/stdin
kubectl -n $NS annotate secret ccquota kubectl.kubernetes.io/last-applied-configuration-   # 旧注解里存着整份旧 data
kubectl -n $NS rollout restart deploy/ccquota-hub && kubectl -n $NS rollout status deploy/ccquota-hub
NEW=$(kubectl -n $NS get secret ccquota -o jsonpath='{.data.viewer-token}' | base64 -d)
echo "old=$(code "$OLD" /v1/live) new=$(code "$NEW" /v1/live)"          # 应为 old=401 new=200
printf %s "$NEW" | gh secret set FLEET_HUB_VIEWER_TOKEN --repo verkyyi/claude-fleet
unset OLD NEW
```

## 换会话通行证 / 中转签名钥匙（#4138）

Secret `ccquota` 的 `session-cred-key`（fcp-h1、frh1、frq1 的 HMAC）和 `relay-sign-key`（frl2、fcp-h2 的
Ed25519 种子）可以换，**不打断在跑的会话**：入口多读一把旧钥 `-prev`，签发只用新钥，验 / 续 / resolve /
中转核验新旧都认，续签用新钥重签同一张（同一个 id、kind 不变）。没有 `-prev` ⇒ 一把钥匙，和以前一样。

**先决条件（一次）**

- 转发机的 `fleet-relay-check.py` 是这一版（认名单的 `relay_pub_prev`）——装法同上一节「转发机先升级」。
- 中心代理（`deploy/k8s/credproxy`，hub-deploy 不碰它）跑的是这一版的 `ccquota`（跟着入口报的钥匙走）。
- 私有部署仓库的 `overlays/prod/deployment-env.yaml` 里有这两条（`optional: true`：没有这把 key 就是没设）：

```yaml
            - name: CCQUOTA_FLEET_SESSION_CRED_KEY_PREV
              valueFrom: {secretKeyRef: {name: ccquota, key: session-cred-key-prev, optional: true}}
            - name: CCQUOTA_FLEET_RELAY_SIGN_KEY_PREV
              valueFrom: {secretKeyRef: {name: ccquota, key: relay-sign-key-prev, optional: true}}
```

**换（K = `session-cred-key` 或 `relay-sign-key`，两把可以一起换）**——值不打印、不进 argv：

```bash
NS=new-deploy K=session-cred-key HUB=https://<入口域名>
kubectl -n $NS get secret ccquota -o json | python3 -c '
import base64, json, os, sys
k = sys.argv[1]; d = json.load(sys.stdin)["data"]
new = base64.b64encode(base64.b64encode(os.urandom(32))).decode()
print(json.dumps([{"op": "add", "path": "/data/" + k + "-prev", "value": d[k]},
                  {"op": "replace", "path": "/data/" + k, "value": new}]))' "$K" \
  | kubectl -n $NS patch secret ccquota --type=json --patch-file=/dev/stdin
kubectl -n $NS annotate secret ccquota kubectl.kubernetes.io/last-applied-configuration-
kubectl -n $NS rollout restart deploy/ccquota-hub && kubectl -n $NS rollout status deploy/ccquota-hub
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)      # 发布完成的时刻：此后的签名都是新钥的
kubectl -n $NS logs deploy/ccquota-hub | grep 'rotating — the previous key still verifies'
```

**等**：通行证用到 80% 就续（≤ 4 小时），续的就是新钥签的。数还没续到新钥的（没吊销、还在 7 天续签宽限里、
最近一次签名早于 T0 的）：

```bash
printf 'header = "Authorization: Bearer %s"\n' "$(kubectl -n $NS get secret ccquota -o jsonpath='{.data.viewer-token}' | base64 -d)" \
  | curl -s -K - "$HUB/v1/fleet/session-cred?signed_before=$T0"      # {"count": N, …}
```

`relay-sign-key` 另有 frl2：4 小时一张、到 80% 重领，T0 后 4 小时全是新钥的。`count` 4 小时后还剩的，是睡着
的笔记本上过期了的会话（7 天宽限内醒来还能续）——等它到 0，或接受它们醒来要重开会话，再往下。

**删 `-prev`**：

```bash
printf '[{"op":"remove","path":"/data/%s-prev"}]' "$K" | kubectl -n $NS patch secret ccquota --type=json --patch-file=/dev/stdin
kubectl -n $NS annotate secret ccquota kubectl.kubernetes.io/last-applied-configuration-
kubectl -n $NS rollout restart deploy/ccquota-hub && kubectl -n $NS rollout status deploy/ccquota-hub
```

滚动发布那一两分钟里，还没换的老副本不认新钥签的：转发机和中心代理会把 10 分钟内入口报过的钥匙都记着，
其余是一次 verify 碰上老副本、这一个请求失败、下一次就好；续签要到通行证 80% 处（约 3 小时后）才轮到，碰不上老副本。BREAK-IT
`key-rotation-breaks-sessions`。

## 发布包（#2335 代码，#2366 接上）

入口按 stable 打包、签名每个发布版（`/v1/fleet/release/*`），存在 OSS 桶
`haowan24-fleet-releases`（region-a，private，VPC 内网地址）里，两个副本同时挂在 `/releases`。

| 东西 | 谁建 | 内容 |
|---|---|---|
| OSS 桶 + RAM 用户 `svc-fleet-release-oss`（策略 `fleet-release-oss-rw`，只此一桶） | 人，控制台 | — |
| Secret `ccquota-release-oss` | 人 | 键 `akId` / `akSecret`（OSS CSI 的 nodePublishSecretRef 格式） |
| （无签名私钥） | — | 自 #3559 起入口不持签名私钥：发布列车（`release-sign` 环境的 `RELEASE_SIGN_KEY`）签名，入口只带离线根的公钥 `CCQUOTA_FLEET_RELEASE_ROOT`（docs/dev/FLEET-HUB.md「发布签名」）；旧的 Secret `ccquota-release-key` 已删 |
| PV `ccquota-releases-oss` + PVC `ccquota-releases` | 人，一次 | `overlays/prod/release-volume.yaml`——部署 Role 建不了 PV / PVC，所以它不在 kustomization 里 |
| 环境变量 + 一个挂载 | hub-deploy | `overlays/prod/deployment-release.yaml` |

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
- 公钥：`curl -fsS https://hub.example.com/v1/fleet/release/key`。换钥匙 = 新 keygen、
  `kubectl create secret … --dry-run=client -o yaml | kubectl replace -f -`、滚一次；已装机器钉的旧公钥要跟着换。

## 入口读 GitHub 用的 App（#4881）

远端调试（#2891）和反馈建单（#3356）随 #4904 去掉；`CCQUOTA_FLEET_DEBUG_*` 不再读，诊断包的 PV
（Retain）留着无害，`deployment-debug.yaml` 可以从 overlay 里删掉。

反馈建单留下的 GitHub App 还在用：入口读 issue 状态（旧式 T 记录收口）和「我的用量」的标题时带它的
installation token（`issueMetaViaApp`）——匿名读共用集群出口，一小时 60 次很快用完。

| 东西 | 谁建 | 内容 |
|---|---|---|
| Secret `ccquota-feedback-github`（`new-deploy`，名字沿用） | 管理员，从集群里已有的那份 App 私钥建 | 键 `app-id`（`5271651`）、`installation-id`（`170195053`）、`private-key`（App 的 PEM）；只读挂到 `/etc/ccquota-feedback-github`（0440） |
| 环境变量 + 挂载 | hub-deploy | `overlays/prod/deployment-feedback.yaml`（`CCQUOTA_FLEET_FEEDBACK_GH_DIR`；`CCQUOTA_FLEET_FEEDBACK_REPO` 不再读；卷 `optional: true`） |

- 没有这个 Secret（或少一个键）：入口照常起，GitHub 读走匿名；有了以后日志是
  `fleet: GitHub issue reads carry the App's installation token (GitHub App 5271651)`。Secret 是挂成文件的，
  建好后要等下一次发布（或滚一次 pod）才读到。
- 私钥、令牌不进日志、单子、配置、仓库。

## GitHub 登录换令牌走新加坡中转（#3392）

集群连 `github.com` 时通时断（`api.github.com` 通），网页「用 GitHub 登录」最后一步换令牌会 15 秒超时，
用户看到「连不上 GitHub，没能完成登录」。开关：

| 东西 | 在哪 | 内容 |
|---|---|---|
| `CCQUOTA_GITHUB_OAUTH_VIA=relay` | `overlays/prod/deployment-env.yaml`（随发布列车上线） | 换令牌改 POST `$CCQUOTA_FLEET_CRED_RELAY_URL/github-oauth/login/oauth/access_token`，带入口自己的 `frh1.` 通行证；要 `CCQUOTA_FLEET_CRED_RELAY_URL` 和 `CCQUOTA_FLEET_SESSION_CRED_KEY`，缺一个入口起不来 |
| 中转白名单 | 转发机 `/etc/caddy/Caddyfile` + `/usr/local/lib/fleet-relay/fleet-relay-check.py`（仓库 `extras/cred-relay/`） | 只放行 `/github-oauth/login/oauth/access_token` 一条路径到 `https://github.com`，`/github-oauth/` 下其余 404；只认入口的 `frh1.` |

中转 5 秒没给出 GitHub 的回答（连不上 / 超时 / 403 / 404 / 5xx）就直连 `github.com` 再试一次（8 秒），
两条都不通给原来那句提示，最多 13 秒。回滚：删掉 overlay 里那一条，下一次发布即恢复直连。

**转发机先升级，再发布入口**（管理员在 Lightsail `fleet-relay-sg` 上跑；顺序：核验进程先，Caddy 后）：

```sh
# 运维本机，仓库 master 上
scp extras/cred-relay/fleet-relay-check.py extras/cred-relay/Caddyfile admin@relay.example.com:/tmp/
# 转发机上
sudo install -m 0755 /tmp/fleet-relay-check.py /usr/local/lib/fleet-relay/fleet-relay-check.py
sudo systemctl restart fleet-relay-check && curl -s http://127.0.0.1:2091/healthz          # ok
sudo install -m 0644 /tmp/Caddyfile /etc/caddy/Caddyfile
sudo -u caddy caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://relay.example.com/github-oauth/login/oauth/access_token   # 403（没通行证）
curl -s -o /dev/null -w '%{http_code}\n' https://relay.example.com/anthropic/v1/messages                           # 403（老路由照旧）
```

发布后验证：

```sh
kubectl -n new-deploy logs deploy/ccquota-hub | grep 'github sign-in: the token exchange goes through the relay'   # 开关生效
# 有人在网页上用 GitHub 登录一次，然后：
kubectl -n new-deploy logs deploy/ccquota-hub --since=10m | grep 'github sign-in'
#   github sign-in: token exchanged through the relay https://relay.example.com   ← 经中转成功
#   github sign-in: relay …: … — trying github.com directly                         ← 中转没答，回落了：查转发机
```

