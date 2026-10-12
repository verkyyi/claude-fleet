---
name: release-rules
description: 发版的规矩——stable 只由发布列车推进；入口、发布包、stable 同一个提交；真急时只能把 stable 挪到「≥ 正在跑的那趟列车的版本」并告诉列车负责人；绝不往回挪、绝不 --force 了事。用于「要不要手动挪 stable」「急修怎么发」「入口和 stable 不同源」「各机器为什么没跟上」「发版前该看什么」。只给发版的人和值班管理员用。
---

# release-rules — 发版的规矩

占位：`<HUB_URL>` 入口地址（`grep FLEET_HUB_URL ~/.config/claude-fleet/fleet.conf`）· `<SHA>` 要发的提交 ·
`<RUN>` 列车的 run id。仓库是 `verkyyi/claude-fleet`（或你的派生仓库）。
权威出处：仓库根 `CLAUDE.md`「CI runs only the RELATED tests」那一条（发布列车、唯一自动发版的路）；
`.github/workflows/release-train.yml` 头注释；`bin/fleet-stable.sh` 头注释（8 道门）；`docs/BREAK-IT.md` 的
`train-*`、`macos-red-to-stable`、`release-artifact-missing`、`release-ccquota-stale` 行；`docs/MANAGED-NODE.md` §7。
出了事照 [runbook-train-stuck]；入口本身的发布与回退照 [hub-deploy]。

**五条规矩**（每条都是一次事故换来的）：

1. **stable 只由发布列车推进**。合进 master ⇒ 上下一趟车；列车测 `--changed <stable>`（Linux + macOS）、过
   `fleet-stable.sh move --precheck`、同一个 `TRAIN_SHA` 先出入口、再发布、再 `fleet-stable.sh move <SHA> --train <RUN>`。
   没有第二条自动发版的路：`hub-deploy.yml` 没有 push 触发，`stable-publish.yml` 只作修补。
2. **入口、发布包、stable 是同一个提交**。手动只挪 stable、或只部署入口，会让两者不同源（`hub-image` 行 WARN
   「不同源」；发布接口 422 `ccquota:`；托管机器停在旧版）。
3. **真急只能往前、只能挪到 ≥ 正在跑的那趟列车的版本，并告诉列车负责人**。挪到列车之前的提交没有意义（列车跑完
   就会把它带过去），还会让 stable 落在已被列车部署到 `TRAIN_SHA` 的入口后面——两者不同源；挪到与列车分叉的提交，
   列车的挪动被只前进门拒绝。挪到列车本身或它之后，列车跑完以「superseded: stable is at …, already ahead」绿着收场。
   手动挪了就在那趟列车的 run 或发版频道说一句「stable 已手动挪到 `<SHA>`，原因 …」。
4. **从不往回挪、从不 `--force` 了事**。`fleet-stable.sh` 只前进（门 2）；回退一个坏版本 = 修好再发一个新的。
   `--force` 只越过门 4–8，并在 `logs/stable-move.log` 记一行——它是「我知道这一道门错了」的签字，不是「赶时间」。
5. **跟上 stable 是机器自己的事**。托管机器由整机更新器每轮跟、登录由 install-sync 跟；发版的人不登上去手动同步，
   不在会话里跑 `/fleet-sync-install`（会把脚本和守护换到别人脚下）。

## 什么时候用

- 想手动挪 stable、想「先发了再说」、或有人问「为什么不能直接挪」。
- 急修：等不及下一趟列车。
- `fleet doctor` 报 `hub-image` 不同源 / 落后、`ccquota` 不是这一版的、`agent` / `install` 落后 stable。
- 发版前想确认这一版能发。

## 先查什么

```sh
sh ~/.claude/fleet/bin/fleet-stable.sh show                 # stable 在哪、落后 master 几个
gh run list --repo verkyyi/claude-fleet --workflow release-train.yml --limit 5   # 有没有列车在跑、跑到哪
curl -fsS <HUB_URL>/version                                  # 入口跑的 commit 与它知道的 stable
fleet doctor --installs                                      # 每份安装离 stable 多远（「落后 Nm」）
```

- 有列车在跑：**它就是这一版的发布**。等它；看它卡在哪一段，卡住照 [runbook-train-stuck]。
- 没有列车在跑、master 比 stable 新：每小时 41 分有一趟兜底；等不及就手动开一趟：
  `gh workflow run release-train.yml --repo verkyyi/claude-fleet`。

## 步骤

1. **正常发版**：合进 master，什么都不做。看列车 run 的摘要：上车的 `TRAIN_SHA`、测试、`hub plan`、`release`。
2. **急修**：修复走普通 PR 合进 master，然后手动开一趟列车（上一节最后一条）——列车上车时现读 master 的头，
   正在跑的那趟不会被取消，新的一趟排在它后面。
3. **真等不了列车**（入口或机器在坏、列车本身坏了）：
   - 先 `--dry-run`：`sh ~/.claude/fleet/bin/fleet-stable.sh move <SHA> --dry-run`，8 道门逐条说结果。
   - `<SHA>` 必须 ≥ 正在跑的列车的 `TRAIN_SHA`（是它本身或它的后代）：`git merge-base --is-ancestor <TRAIN_SHA> <SHA>`。
   - 入口先跟上同一个提交：`gh workflow run hub-deploy.yml --repo verkyyi/claude-fleet`（见 [hub-deploy]），门 8
     （`ccquota:`）才会过。
   - 再 `sh ~/.claude/fleet/bin/fleet-stable.sh move <SHA>`（它推完标签会触发一次 `stable-publish.yml`）。
   - 告诉列车负责人（列车 run 的发起人 / 值班）：挪到了哪、为什么。那趟列车之后会以「superseded」绿着收场。
4. **门拒了**：读理由前缀——`macos:` macOS 半边红或没跑完；`oldcfg:` 老会话会坏；`release:` release.json 不合法；
   `artifacts:` 入口缺制品（把它放进入口的制品清单再挪）；`ccquota:` 入口镜像不是这一版的（先部署入口）。
   修原因，不 `--force`。

## 怎么验收

- `fleet-stable.sh show` 的 `stable:` 是 `<SHA>`、`verdict:` CURRENT 或只落后列车之后的合并。
- `curl <HUB_URL>/version`：`commit` 与 `stable` 同源。
- 任一台机器 `fleet doctor`：`hub-image` PASS；托管机器 `fleet doctor --machine` 的 `runtime` 是这一版（更新器一轮内）。
- `fleet doctor --installs` 一小时内全部「在 stable」。

## 怎么回滚

- stable 不往回挪。坏版本的回滚 = 修好合进 master 发下一版；等的这段时间，托管机器的更新器在体检多出 FAIL 时
  会自己退回上一版并跳过这个 sha（`docs/MANAGED-NODE.md` §7）。
- 入口坏了：照 [hub-deploy] 的手动回退（`tag` = 旧镜像），之后让下一趟列车把入口和 stable 带回同一个提交。
- 误挪了 stable（挪到了列车之前、或没部署入口）：不要再挪回去；部署入口到同一个提交，或让下一趟列车往前带。
