---
name: hub-deploy
description: 发布与回退入口（ccquota hub）——正常走发布列车，紧急走 hub-deploy 的手动运行；暂停、指定旧镜像回退、跨库迁移时恢复快照、按 /version 与体检验收。用于「入口要发新版 / 急修」「入口升级后坏了要回退」「暂停入口发布」「演练回退」。只给管理入口的人用。
---

# hub-deploy — 入口发布与回退

占位：`<HUB_URL>` 入口地址（`grep FLEET_HUB_URL ~/.config/claude-fleet/fleet.conf`）· `<HUB_NAMESPACE>` 入口的 k8s 命名空间 ·
`<OLD_TAG>` 要回到的镜像标签 `prod-<sha7>`。仓库是 `verkyyi/claude-fleet`（或你的派生仓库）。
权威出处：`deploy/k8s/README.md`「Release = the release train」（发布 1–7 步、自动回退、Manual rollback、Rollback drill、Pause、Notify）
「Who may do what」；`deploy/k8s/RUNBOOK.md`「发布与回滚」「快照与恢复」「库迁移」；`.github/workflows/hub-deploy.yml` 头注释；
仓库根 `CLAUDE.md` 里「release train」那一条。

## 什么时候用

- 一个改动合进主干后要确认入口跟上了（正常不用动手：发布列车会部署）。
- 急修或回退，等不了下一班列车。
- 入口新版坏了；要暂停发布；要演练回退。

## 先查什么

```sh
curl -fsS <HUB_URL>/version         # 现在跑的 version（prod-<sha7>）、commit、stable
curl -fsS -o /dev/null -w '%{http_code}\n' <HUB_URL>/healthz
gh run list --repo verkyyi/claude-fleet --workflow release-train.yml --limit 5
gh run list --repo verkyyi/claude-fleet --workflow hub-deploy.yml --limit 5
gh variable list --repo verkyyi/claude-fleet | grep -E 'HUB_DEPLOY_PAUSED|HUB_DEPLOY_NOTIFY_ISSUE'
```

- 有一班列车或一次部署正在跑：等它，**不要取消**（sqlite 形态取消一半会让入口停着）。
- 要回退到的 `<OLD_TAG>`：上一次成功部署的运行摘要里写着「旧 → 新」标签和快照路径。
- 新旧之间有没有库迁移：摘要里「可能有」一栏，或 `git log <旧>..<新> -- tokenledger/internal/store`。

## 步骤

1. **正常发布**：合进 master → `release-train.yml` 上车 → `bin/fleet-train-hub.sh <TRAIN_SHA>` 判断入口要不要换（已是同一份 Go 源码和 `deploy/k8s/` 就跳过，从不往回）→ 调 `hub-deploy.yml`（`sha` = TRAIN_SHA）→ 同一提交发布、移 stable。什么都不用做，看运行结果。
2. **紧急发布**：Actions › hub-deploy › Run workflow（`workflow_dispatch`，永不被暂停），或
   `gh workflow run hub-deploy.yml --repo verkyyi/claude-fleet`。
3. **手动回退**：同一入口，`tag` 填 `<OLD_TAG>`：
   `gh workflow run hub-deploy.yml --repo verkyyi/claude-fleet -f tag=<OLD_TAG>`。用 master 的清单部署那份镜像。
   **跨过了库迁移**：还要恢复对应快照（`/data/backup-hubdeploy-<UTC>-<tag>.db`），照 `deploy/k8s/RUNBOOK.md`「快照与恢复」做，需要集群管理员的 kubeconfig。
4. **暂停 / 恢复**列车的部署：`gh variable set HUB_DEPLOY_PAUSED --repo verkyyi/claude-fleet --body 1`；恢复 `gh variable delete HUB_DEPLOY_PAUSED --repo verkyyi/claude-fleet`。
5. **演练回退**：Run workflow，勾 `simulate_unhealthy`，`tag` = 任一不是现役的旧标签；它部署、判失败、回到现役镜像并变红。
6. **从不**手动 `kubectl apply -k overlays/prod`：清单里的标签是占位，sqlite 形态下入口会停掉。要重部署就跑 workflow。

## 怎么验收

- `curl <HUB_URL>/version` 的 `commit` 是这次的提交（回退后是 `<OLD_TAG>` 的），`stable` 有值。
- `/healthz` 200；`/install` 200 且第一行是 `#!`；`POST <HUB_URL>/v1/fleet/login/start` 不是 404。
- 运行摘要里 `downtime_seconds=<n>`、旧 → 新标签、快照路径、是否回退。
- 任一台客户端：`fleet doctor` 的 `hub-image` 行 PASS（入口与 stable 同源；WARN「不同源」= 有人手动回退把两者分开了，补一次正常发布）。

## 怎么回滚

- 健康检查或滚动失败时任务**自动**把镜像设回之前那份、等它健康、然后变红——只回镜像，清单仍是 master 的，已跑的迁移不撤。
- 自动回退之后或要回到更早：照「步骤」3 手动回退；跨迁移恢复快照。
- 暂停误开了：删掉 `HUB_DEPLOY_PAUSED`，暂停期间合进来的随下一班列车走，或手动跑一次。
- 回退后入口与 stable 不同源：修好原因后让下一班列车把两者带回同一提交，不要再手动移 stable。
