# CI：开 PR、列车、每晚各跑什么

一个 PR 能不能合，只看一项检查：**「CI 结论」**（issue #4815，EPIC #4810 C5）。它也是 `master` 上唯一必过的一项。

## 三层分工

| 什么时候 | 跑什么 | 谁决定跑哪些 | 跳过算什么 |
|---|---|---|---|
| 开 PR（`.github/workflows/ci.yml`） | 这次改动碰得到的检查：相关的 shell 自测、改到的那几块 Go（块内只测受影响的包）、相关的端到端 | `bin/ci-plan.sh all`，结果在 run 的 `ci-plan` 产物里 | 通过——由「CI 结论」统一判 |
| 合并后的列车（`release-train.yml`） | PR 上没证明过的自测（`bin/fleet-train-reuse.sh` 复用 PR 的绿），再发布 | `run-selftests.sh --changed <stable> --proven` | 复用的算过，没复用的照跑 |
| 发布后 15 分钟（`release-watch.yml`，列车 `next` 挪了 stable 就派，自己一条道） | `bin/fleet-release-watch.py`：读入口 `/v1/fleet/release/health`（金丝雀 `fleet.release_canary` 拦住、机器回滚这一版、入口 5xx）并探 `/healthz`；出问题 ⇒ `fleet-release-rollback.sh <stable> --since <上一版>` 整版回退 + 通知（#4915，BREAK-IT `release-bad-spreads`） | 不挑 | — |
| 每晚 | 全部：Linux 全量自测（`selftests-nightly.yml`）、Mac 全量（`selftests-macos.yml`）、task-acceptance / client-e2e / fleet-hub-mcp / shellcheck 的定时全跑；Go 全量 + Postgres 由 C6（#4816）加 | 不挑，全跑 | 没有跳过；漏选的第二天自动开单（`fleet-nightly-miss.sh`） |

拿不准就跑：base 解析不了、git 或 `go list` 出错、`tokenledger/` 下认不出的路径、改了 `bin/ci-plan.sh` 或 `ci.yml` 本身——一律全跑（EPIC #4810 共同约定 7）。

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
| `browser_attachment` | `browser-attachment.yml` | `tokenledger/`、web 终端那几个脚本、`extras/browser-transport/ web-console/ web-chat/ui/` |
| `hub_rolling` | `hub-rolling.yml` | `deploy/k8s/`、`.github/actions/hub-release/`、`tokenledger/` |
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
| `go.work`、`Dockerfile`、`Makefile`、`test-quarantine.txt`、`tokenledger.yml`、`tokenledger-quarantine.sh`、`tokenledger-modules-selftest.sh` | 四块全选（不再收窄） |
| `bin/fleet-client-pack.sh`（hub 内嵌的客户端） | hub · e2e |
| `README.md`、`docs/`、`notify/` | 不选 |
| `tokenledger/` 下别的路径 | 四块全选（拿不准） |

一块里没有一个包依赖到改动 ⇒ 这块也跳过。`hub/api` 被选中才跑它的三片（`api-1..3`，含 Postgres 腿）；`hub/store`、`hub/leader` 被选中才跑 Postgres 的 `store` 片；e2e 被选中才跑 Postgres 的 e2e 片；交叉编译 hub 块选中编 hub、agent 块选中编节点。gofmt / vet（只在选中的模块）/ 模块方向自测在 `lint` 一项里。

打印形如：

```
select: agent ← tokenledger/agent/cli/budget.go changed
skip: hub ← no changed file reaches it
skip: e2e ← tokenledger/agent/cli/budget.go changed (agent ⇒ e2e) — but none of its packages depends on a changed one
pkgs agent: github.com/verkyyi/claude-fleet/tokenledger/agent/cli
```

## 怎么加一个新检查

1. 工作流的 `on:` 写 `workflow_call:`（要定时 / 手动跑再加 `schedule` / `workflow_dispatch`），**不要**写 `pull_request:`；它的 `concurrency` 组名写死自己的名字，不能用 `${{ github.workflow }}`（被调用时那是 `CI`）。它要的权限不能超过 `ci.yml` 顶上给的（`contents: read`、`actions: read`）。
2. `bin/ci-plan.sh`：键加进 `CHECKS`，`check_rules` 里写它的 `globs`（必要时 `paths` + `among`）。
3. `ci.yml`：`plan` 的 `outputs` 加一行；加一个调用它的 job（`if: needs.plan.outputs.<键> == 'true'`）；名字加进 `CI 结论` 的 `needs`。
4. `bin/ci-plan-selftest.sh` A 腿会核对这三处是否对齐、是否还有工作流自己挂在 `pull_request` 上。

## 守住它的东西

- `bin/ci-plan-selftest.sh`：三处对齐；四块映射与包级收窄（沙箱仓库）；拿不准就跑；「CI 结论」的判法。
- `docs/dev/BREAK-IT.md` 行 `module-skip-wrong`：映射漏一块时上面的自测当场红。
- `bin/fleet-pr-verdict-selftest.sh`：合并门优先读「CI 结论」。
