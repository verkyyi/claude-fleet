# CI：开 PR、列车、每晚各跑什么

一个 PR 能不能合，只看一项检查：**「CI 结论」**（issue #4815，EPIC #4810 C5）。它也是 `master` 上唯一必过的一项。

## 三层分工

| 什么时候 | 跑什么 | 谁决定跑哪些 | 跳过算什么 |
|---|---|---|---|
| 开 PR（`.github/workflows/ci.yml`） | 这次改动碰得到的检查：相关的 shell 自测、改到的那几块 Go（块内只测受影响的包）、相关的端到端 | `bin/ci-plan.sh all`，结果在 run 的 `ci-plan` 产物里 | 通过——由「CI 结论」统一判 |
| 合并后的列车（`release-train.yml`） | PR 上没证明过的自测（`bin/fleet-train-reuse.sh` 复用 PR 的绿），再发布 | `run-selftests.sh --changed <stable> --proven` | 复用的算过，没复用的照跑 |
| 发布后 15 分钟（`release-watch.yml`，列车 `next` 挪了 stable 就派，自己一条道） | `bin/fleet-release-watch.py`：读入口 `/v1/fleet/release/health`（金丝雀 `fleet.release_canary` 拦住、机器回滚这一版、入口 5xx）并探 `/healthz`；出问题 ⇒ `fleet-release-rollback.sh <stable> --since <上一版>` 整版回退 + 通知（#4915，BREAK-IT `release-bad-spreads`） | 不挑 | — |
| 每晚（北京 06:17） | 全部：Linux 全量自测（`selftests-nightly.yml`，stable）、Mac 全量（`selftests-macos.yml`）；`ci-nightly.yml`（master）把 `ci.yml` 能调的每一项都整项跑一遍——Go 四块 `-race -count=1`（不读测试缓存）+ Postgres 全部分片、task-acceptance / client-e2e（Linux + macOS）/ fleet-hub-mcp / browser-attachment / hub-rolling / shellcheck 全树 …（不含 oss-scan：它只看 PR 的 diff） | 不挑，全跑 | 没有跳过；漏选的第二天自动开单（`fleet-nightly-miss.sh`，见下节） |

拿不准就跑：base 解析不了、git 或 `go list` 出错、`tokenledger/` 下认不出的路径、改了 `bin/ci-plan.sh` 或 `ci.yml` 本身——一律全跑（EPIC #4810 共同约定 7）。

## 每晚：跳过的有没有漏

`ci-nightly.yml`（#4816）跑完，`选漏分析` 一步把每一项的结果记成 `nightly-checks` 产物（第二晚的「前一晚」），再跑 `bin/fleet-nightly-miss.sh --go <Go 日志> --checks <各项结果>`，窗口是上一次定时运行测的提交 .. 今晚（没有就前一天）：

| 红的是什么 | 怎么查 | 没选中 ⇒ |
|---|---|---|
| 一个 Go 测试（`go-log-*` / `pg-log-*` 里的 `--- FAIL`） | 在今晚复跑（绿 ⇒ 时好时坏）、窗口起点复跑（红 ⇒ 早就红了），再在窗口的合并上 `go test -race -count=1 -run '^T$'` 二分到最早红的合并 M（Postgres 腿连本 job 自己的 Postgres）；问 `bin/ci-plan.sh go M^` 有没有选中它的块和包 | 一张 `selection-miss` 单，`--breakage-key nightly-go-<包>.<测试>` / `nightly-pg-…`，写明 M、改的文件和计划原话 |
| 一整项检查（端到端，不逐次重跑） | 前一晚也红 ⇒ 早就红了；否则问窗口里每次合并 `bin/ci-plan.sh <检查> M^` | `run=false` 的那几次就是嫌疑（只有一次 ⇒ 点名），`nightly-check-<检查>`；一次都没跳过 ⇒ 普通红单 |

一个故障一张单（键不带 sha），第二晚还红只加「同一故障」评论。Linux 自测的漏选仍由 `selftests-nightly.yml` 查（`nightly-<测试>`）。BREAK-IT 行 `selection-miss-silent` / `selection-miss-go-silent`。

## 「CI 结论」怎么判

`ci.yml` 先跑 `plan`，再按计划调用各检查（每个检查是自己的工作流，`workflow_call`），最后 `CI 结论` 这一项 `needs` 全部、`if: always()`：

- `plan` 必须成功；
- 计划选中的检查必须 `success`；
- 没选中的必须是 `skipped`（被跳过 = 通过）；
- 任何 `failure` / `cancelled` 都是红。

它自己不跑测试，只读 `needs`，所以它坏的概率很小；万一坏了挡住所有 PR，管理员可以在 ruleset 里临时去掉这项必过。

`bin/fleet-pr-verdict.sh`（执行会话合并前读的门）优先读「CI 结论」：有它就以它为准——它绿了，别处还在跑的检查不再拖住；它还没出结果就是 PENDING；别的检查红了照样 FAILING（逐项判断保留一个版本，`# compat-1v`）。没有它（`ci.yml` 之前开的分支）就照旧逐项判。

## 每个检查的触发规则

规则只在 `bin/ci-plan.sh` 的 `check_rules` 里一处（各工作流不再写 `paths:`）：

| 检查（键） | 工作流 | 什么改动会跑 |
|---|---|---|
| `selftests` | `selftests.yml` | `bin/ hooks/ conf/ launchd/ systemd/ .claude-plugin/ commands/ skills/ shell/ extras/ mod/`、`fleet.conf.example`、它和 `selftests-shards.yml`；跑哪些测试再由 `run-selftests.sh --changed` 选 |
| `shellcheck` | `shellcheck.yml` | `bin/ hooks/ shell/ extras/`、`.shellcheckrc`、`.shellcheck-version` |
| `tokenledger` | `tokenledger.yml` | 碰到任一 Go 块（见下节） |
| `task_acceptance` | `task-acceptance.yml` | `tokenledger/`、`extras/web-console/`；`bin/` 里的改动要被它的入口文件点名才跑 |
| `client_e2e` | `client-e2e.yml` | `tokenledger/`；`bin/ shell/ conf/` 里的改动要被入口文件点名 |
| `fleet_hub_mcp` | `fleet-hub.yml` | `requirements-mcp.txt`；`bin/fleet*` 要被入口文件点名 |
| `browser_attachment` | `browser-attachment.yml` | Go 里只认它守的那几条路（#4919）：附件 / 终端 / 聊天的 hub、节点文件（`*attach* *chat* *term*`、`pty*`、`relay.go` 等）、`shared/control` 里的 `control.go` 与附件 / 终端 / 聊天消息、`shared/attachment hubwire`、联调 harness 与 `*browser*` 测试、各模块的 `go.mod/go.sum`、`go.work`；外加 web 终端那几个脚本、`extras/browser-transport/ web-console/ web-chat/ui/`。认不出的 `tokenledger/` 路径照跑 |
| `hub_rolling` | `hub-rolling.yml` | 发布物与 hub 启动（#4919）：`deploy/k8s/`、`.github/actions/hub-release/`、`tokenledger/Dockerfile`、客户端打包（`fleet-client-pack.sh`、`hub/api/fleetclient/`）、`hub/cmd/ hub/leader/`、就绪 / 关停（`server.go deploy_probe.go`）、迁移（`store/migrations.go schema.sql pg*.go store.go`）、`go.mod/go.sum`、`go.work`。认不出的 `tokenledger/` 路径照跑 |
| `hub_deploy_check` | `hub-deploy-check.yml` | `deploy/k8s/`、`.github/actions/hub-*`、`hub-deploy.yml` |
| `cluster_perms` | `cluster-perms.yml` | 集群那几处 `deploy/k8s/*` 与相关脚本 |
| `native_claude_worktree` / `native_managed_hooks` | 同名 | 各自列出的脚本与 hooks |
| `node_join` | `node-join.yml` | `fleet-node-join.sh` 与 hub 的 join 代码 |
| `oss_scan` | `oss-scan.yml` | 任何改动 |
| `web_chat_ui` / `web_console` | 同名 | 各自的前端目录与主题 |

每个检查自己的工作流文件改了，它也跑；`ci-plan.sh` / `ci.yml` 改了，全部跑。

### Go：四块

`tokenledger/` 是四个模块（EPIC #4810）。`bin/ci-plan.sh go <base>` 先按目录选块，再在块内用 `go list -test` 只留「测试二进制依赖到改动包」的包：

| 改到 | 选中的块 |
|---|---|
| `shared/**` | shared · agent · hub · e2e |
| `agent/**` | agent · e2e |
| `hub/**` | hub · e2e |
| `e2e/**` | e2e |
| `go.work`、`Dockerfile`、`Makefile`、`test-quarantine.txt`、`tokenledger.yml`、`tokenledger-quarantine.sh`、`tokenledger-modules-selftest.sh`、`go-test-shard.sh` | 四块全选（不再收窄） |
| `bin/fleet-client-pack.sh`（hub 内嵌的客户端） | hub · e2e |
| 被 Go 测试执行的 `bin/` 脚本（`*_test.go` 里 `filepath.Join(…, "bin/<名>")` / `"bin", "<名>"`，或 `// drives: bin/<名>` 一行点名；issue #4944） | 那个测试所在的块，只收窄到它的包 |
| `README.md`、`docs/`、`notify/`、`test-durations*.txt`（只改发牌） | 不选 |
| `tokenledger/` 下别的路径 | 四块全选（拿不准） |

一块里没有一个包依赖到改动 ⇒ 这块也跳过。`hub/api` 被选中才跑它的 `api-K` 片（片数按耗时表定，见下节；含 Postgres 腿）；`hub/store` 被选中才跑 -race 的 `store` 片（它单独一片，#4817）；`hub/store`、`hub/leader` 被选中才跑 Postgres 的 `store` 片；e2e 被选中才跑 Postgres 的 e2e 片；交叉编译 hub 块选中编 hub、agent 块选中编节点。gofmt / vet（只在选中的模块）/ 模块方向自测在 `lint` 一项里。

打印形如：

```
select: agent ← tokenledger/agent/cli/budget.go changed
skip: hub ← no changed file reaches it
skip: e2e ← tokenledger/agent/cli/budget.go changed (agent ⇒ e2e) — but none of its packages depends on a changed one
pkgs agent: github.com/verkyyi/claude-fleet/tokenledger/agent/cli
```

### Go：按耗时分片、用上次的结果（#4817，EPIC #4810 C7）

- **耗时表**：`tokenledger/test-durations.txt`（-race 腿）和 `tokenledger/test-durations-pg.txt`（Postgres 腿），一行 `<秒>\t<包>.<测试>`，<包> 是 `tokenledger/` 下的导入路径（`hub/api.TestX`）。刷新：`bin/go-test-durations.sh [--pg] --run <ci.yml 的 run>`——读那次各片上传的 `go-log-*` / `pg-log-*`（`go test -v`），见到的测试取中位、没见到的留着、函数已删的去掉。
- **片数**：`bin/ci-plan.sh` 用 `bin/go-test-shard.sh count` 按表里 `hub/api` 的总秒数 ÷ 240（每片 4 分钟）定 `api-K` 的个数，1..8；表里没有这个包就是 3。两条腿各算各的（`go_api_shards` / `go_pg_api_shards`），记在 `ci-plan` 产物里。
- **发牌**：每个 `api-K` 先 `go test -list`，再 `bin/go-test-shard.sh deal`——最长的先发、发进当前最轻的那片（和 `run-selftests.sh --shard` 同一算法），没有行的测试按这个包的中位数算。每片拿同一份列表算同一副牌，只留自己那份，所以 N 片的并集就是整个包（`bin/go-test-shard-selftest.sh` A，BREAK-IT `go-shard-drops-test`）。
- **每片的 summary**：测试数、预测（表）、实际（各测试秒数之和）、偏差、`go test` 墙钟，以及缓存读数。
- **缓存**：每个 job 自己的 `actions/cache`（键：腿 + 片 + go.sum + OS + run），只在 PR 上恢复（同一 PR 上一次推送的，退到同一片最新的）——没改的包 `go test` 直接拿缓存里的结果（`ok … (cached)`），`-race` 的编译产物复用。PR 之外（手动、每晚）不恢复、`-count=1`，一律重新测。保存前 `bin/go-ci-cache.py prune` 删掉这次没用到的条目（仓库缓存上限 10 GB，早就满了），`report` 打印编译条目复用率和测试结果命中率。
- **Postgres 模板库**：`storetest.Open` / `OpenFleet`（hub/api、e2e）和 store 包的 `newStore` / `taskStore` 在 Postgres 腿上先 `store.PGTemplate`：每个测试二进制建一个迁移好的模板库，每个测试 `CREATE DATABASE … TEMPLATE` 一份，不再每个测试从空 schema 建表（原来每个 ~1.3 秒）。日志里 `pg leg: N test database(s) copied from a template, X s per test` 就是固定开销。
- **store 包自己的测试**：`newStore` / `taskStore` 同样从模板起——SQLite 是一份迁移好的文件按字节复制（store 包不能引 storetest），Postgres 是模板库。
- **交叉编译**：一个 job 编四个平台（两个一组并行），不再四个 job 各排一次队。

### 本仓库自己的 PR 上深圳集群（#4821，EPIC #4810 C18）

- **跑哪些**：tokenledger 的 lint、`-race` 测试各片、交叉编译，和自测分片。Postgres 腿留在 GitHub（服务容器要 Docker，runner pod 里没有）。
- **谁上**：只有 head 是本仓库分支的 PR（不是 fork）；fork 的、机器人的永远在 `ubuntu-latest`。`ci.yml` 的 plan 里 `bin/fleet-train-runner.sh pr-pick` 决定，输出 `runs_on` 传给两个被调用的工作流；摘要写为什么。
- **集群在不在**：PR 读不到 runner 列表（runner 应用的密钥只给 master 的环境 `fleet-ack-probe`），所以 `fleet-ack-status.yml` 每 10 分钟在 master 上跑列车同一个 `pick`，把答案（`ts=` + pick 的几行）存进 Actions 缓存 `fleet-ack-status-<run>`；plan 恢复最新那份，30 分钟内说「在」才上 fleet-ack，否则 `ubuntu-latest`（BREAK-IT `pr-ack-down`）。
- **机器那头**：任务开始钩子 `bin/fleet-ci-job-gate.sh` 设了 `CI_GATE_PR_WORKFLOWS=ci.yml` 才收 PR，且从事件文件核对 head 是本仓库、非 fork、base master、作者非 `[bot]`（BREAK-IT `ci-ack-pr-fork`）。镜像就是常驻的 Go 缓存：Go、模块和 `-race` 的编译产物都烤在 `fleet-ci-runner` 里，fleet-ack 上不跑 `setup-go`、不读写 Actions 缓存。
- **开关**：仓库变量 `FLEET_PR_RUNNER=fleet-ack`；空 ⇒ 什么都不读、全在 `ubuntu-latest`，和以前一字不差。打开前先把伸缩组换到带新钩子的镜像、加上 `CI_GATE_PR_WORKFLOWS`（`deploy/k8s/runners/README.md`），否则 PR 的 job 会被旧钩子拒掉。

## 怎么加一个新检查

1. 工作流的 `on:` 写 `workflow_call:`（要定时 / 手动跑再加 `schedule` / `workflow_dispatch`），**不要**写 `pull_request:`；它的 `concurrency` 组名写死自己的名字，不能用 `${{ github.workflow }}`（被调用时那是 `CI`）。它要的权限不能超过 `ci.yml` 顶上给的（`contents: read`、`actions: read`）。
2. `bin/ci-plan.sh`：键加进 `CHECKS`，`check_rules` 里写它的 `globs`（必要时 `paths` + `among`）。
3. `ci.yml`：`plan` 的 `outputs` 加一行；加一个调用它的 job（`if: needs.plan.outputs.<键> == 'true'`）；名字加进 `CI 结论` 的 `needs`。
4. `bin/ci-plan-selftest.sh` A 腿会核对这三处是否对齐、是否还有工作流自己挂在 `pull_request` 上。

## 守住它的东西

- `bin/ci-plan-selftest.sh`：三处对齐；四块映射与包级收窄（沙箱仓库）；拿不准就跑；「CI 结论」的判法。
- `docs/dev/BREAK-IT.md` 行 `module-skip-wrong`：映射漏一块时上面的自测当场红。
- `bin/fleet-pr-verdict-selftest.sh`：合并门优先读「CI 结论」。
