---
name: runbook-train-stuck
description: 发布列车卡住或一直红时的故障手册——看它卡在哪一段（plan · board · 测试分片 · macos-wait · precheck · hub · release），分清「慢不是挂」「来晚了不是红」「入口被别人先部署了」「两趟连红的测试被隔离」，各自怎么处理；不取消正在跑的列车、不手动挪 stable 了事。用于「列车一直在跑」「stable 挪不动」「macOS 分片排队不动」「列车红了但测试都过了」「release 段 409」。只给发版的人和值班管理员用。
---

# runbook-train-stuck — 发布列车卡住

占位：`<RUN>` 列车的 run id · `<TRAIN_SHA>` 这趟上车的提交 · `<HUB_URL>` 入口地址。仓库是 `verkyyi/claude-fleet`
（或你的派生仓库）。
权威出处：`.github/workflows/release-train.yml` 头注释；`docs/dev/BREAK-IT.md` 行 `train-push-cancels` ·
`train-red-holds-lane` · `train-shard-timeout` · `train-macos-slow-not-hung` · `train-own-runner-silent` ·
`train-own-runners-gone` · `train-superseded-red` · `train-hub-backwards` · `train-hub-stable-split` ·
`train-derived-red` · `train-quarantine` · `macos-red-to-stable`；脚本 `bin/fleet-train-{board,plan,macos,failfast,hub,superseded,quarantine}.sh`。
规矩本身见 [release-rules]。

## 什么时候用

- 一趟列车跑了很久、看着像挂住了；stable 好几个小时没动。
- 列车红了，但没有一个测试是 FAIL；或 `release` 段 409「not forward」。
- macOS 分片一直排队；摘要写「自家测试机没接」。
- 有测试被「隔离」了，想知道它会不会挡发版。

## 先查什么

```sh
gh run list --repo verkyyi/claude-fleet --workflow release-train.yml --limit 8
gh run view <RUN> --repo verkyyi/claude-fleet                 # 每个任务的状态，卡在哪一段
gh run view <RUN> --repo verkyyi/claude-fleet --log-failed | tail -60
sh ~/.claude/fleet/bin/fleet-stable.sh show
curl -fsS <HUB_URL>/version
```

- 列车一次只跑一趟、只排一趟（`concurrency: release-train`，不取消正在跑的）：**排着的那趟显示「cancelled」是被更新的
  合并顶掉的，不是坏了**。
- run 摘要页写着每段的结论：`board` 上了哪个提交、macOS 去了哪（`fleet-ci` / GitHub）、`plan` 的预测、「红灯即停：<任务>」、
  「隔离了 N 个：…」、`superseded` / `hub superseded`。先读摘要，再看日志。

## 步骤

按卡住的那一段：

1. **测试分片在跑、很慢**（`Linux / shard *`、`macOS / shard *`）：stable 落后很多时 `--changed <stable>` 接近全量，
   GitHub 的 Mac 一片可能跑 40 分钟以上，日志一直在前进就是在跑（`train-macos-slow-not-hung`）。**不要取消**——取消后
   下一趟从头再来。真挂住的单条测试会被 600 秒上限打成 `TIMEOUT <名字>` 继续往下。
2. **分片被步骤上限截断**（「timed out after N minutes」、日志里没有 FAIL / TIMEOUT 行）：`fleet-shard-run.sh` 会原样
   重跑一次；两次都截断才红。红了：重开一趟（`gh run rerun <RUN> --failed`），并检查 `bin/selftest-durations*.txt`
   是不是太旧（`bin/selftest-durations.sh --run <一次全绿的 run>` 刷新，走 PR）。
3. **macOS 分片排队不动**：排给自家测试机（`[self-hosted, macOS, fleet-ci]`）的 20 分钟没开，`macos-wait` 会把这趟打红
   并取消，下一趟 `board` 读到心跳就改用 GitHub 的 Mac。想立刻换：在那台测试机上把它撤下
   （`sudo mv /var/db/fleet-node/ci.env /var/db/fleet-node/ci.env.off`，守护停掉 ci-runner；体检 `ci-runner` 行），然后 `gh workflow run release-train.yml --repo verkyyi/claude-fleet`。两台都不在时列车本来就用 GitHub 的。
4. **一片红了**：`fail-fast` 当场取消整趟、把车道让出来（`train-red-holds-lane`）。看 `--log-failed` 里的 `FAIL <测试>`：
   - 你的改动弄坏的：修、合进 master，下一趟自然带上。
   - master 本身就红（同一测试在上一趟也红、和改动无关）：两趟连红、改动没碰它的测试会被**隔离** 48 小时
     （`QUARANTINE` 而不是 `FAIL`，列车照常发版），并自动开一张 breakage 单——修那张单，不要手动挪 stable 绕过。
5. **precheck 红**（`fleet-stable.sh move --precheck`）：理由前缀说是哪道门——`oldcfg:` 老会话会坏（删了 hook / 工具要留
   转发一版）、`release:` release.json 不合法、`artifacts:` 入口缺制品（放进入口的制品清单）。修原因，走 PR。
6. **hub 段**：`hub plan` 判断入口已是同一份 Go 源和 `deploy/k8s/` 就跳过；入口已在更新的（或分叉的）提交上 ⇒
   「hub superseded」、这段绿（`train-hub-backwards`）；读不到 `/version` ⇒ 红，不盲部署——先让入口能答 `/version`
   （见 [hub-deploy]）。部署本身红：入口已自动回到原镜像，按 [hub-deploy] 查。
7. **release 段 409「not forward」/ 挪动「does not descend」**：stable 已被手动或后一趟挪过了这趟——`fleet-train-superseded.sh`
   会让它绿着收场（`train-superseded-red`）；仍是红的话看是不是有人把 stable 挪到了分叉的提交，按 [release-rules] 往前修。
   `ccquota:` 拒绝 = 入口镜像不是这一版的，先让入口跟上。
8. **很久没有列车**：每次合并、以及每小时 41 分各开一趟；`gh run list` 里都没有 ⇒ Actions 被禁用或 workflow 文件坏了，
   在仓库的 Actions 页看。手动开：`gh workflow run release-train.yml --repo verkyyi/claude-fleet`。

**从不**：取消一趟正在跑测试的列车（下一趟只会更慢）；为了「先发出去」手动 `fleet-stable.sh move --force`；在 PR 上
加 `--ignore-check` 绕过一个真红。

## 怎么验收

- 最近一趟列车绿，摘要里 `release` 写了挪到的提交（或 `superseded`）。
- `fleet-stable.sh show` 的 `stable:` 前进了；`curl <HUB_URL>/version` 的 `commit` 与 `stable` 同源。
- 任一台机器 `fleet doctor`：`hub-image` PASS；`fleet doctor --installs` 一小时内都到了 stable。

## 怎么回滚

- 列车不需要回滚：红就什么都没发出去（已部署的入口留着，它也服务旧机器；发布是幂等的），下一趟从头来。
- 列车已发出一个坏版本：不往回挪 stable——修好合进 master 发下一版；入口照 [hub-deploy] 手动回退旧镜像；托管机器的
  更新器在体检多出 FAIL 时自己退回上一版。
- 撤下的自家测试机：把 `ci.env.off` 改回 `ci.env`，守护重起 ci-runner，下一趟 `board` 读到心跳就会再用它。
