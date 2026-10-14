# 国内真实用户路径巡检

（issue #4150 探针 · #4180 扩成真实用户路径 + 挡发版）

阿文调通前后撞了 9 层独立 bug，每层单测都绿，但没人跑过真实用户路径。这一页说那条路径怎么被一台机器定时走一遍、红了怎么挡住 stable。

## 走什么

`bin/fleet-cn-probe.sh` 在国内客户端（深圳演练机 oss-drill，以测试身份登录）上，对测试 pod 逐层走：

| 层 | 做什么 |
|---|---|
| client · install · hub · cert · list | 跳到客户端、客户端装了 `fleet`、入口 `/version`、证书被接受、入口列出 pod |
| table · auto · `<线>` | `fleet connect` 测速表；自动选的线、每条线强制各在 pod 上跑一次 `hostname` |
| `view:<线>` | 钉住这条线，在伪终端里敲裸 `fleet`：客户端 `thin.log` 记一行 `drawn`，界面停留 30 秒不掉 |
| `codex:<线>` | 钉住这条线，`fleet codex --new '只回一个词：CNP…'`：pod 上新开的 Codex 会话回出这个词；会话事后关掉 |
| `task` | 经 `fleet connect` 在 pod 上 `fleet-task-record.sh dispatch --repo <托管仓库>`：入口任务记录 T<n> + 它的工单（file_issue 那条路，不 spawn）；工单随即关掉（not_planned） |

门（entry）、中转（relay）两条线都走；表里标明不是这台客户端能走的线（局域网、Tailscale）只记一笔。每层一行 `PASS|FAIL|INFO`，最后一行「通：…」或「不通：卡在 <层> — <原因>」。

## 谁走、多久一次

`bin/fleet-cn-probe-watch.sh` 挂在 diskguard 守护的每拍上（`cn_probe_watch`），只在有客户端钥匙（`FLEET_CN_PROBE_KEY`）的那台机器、那个登录上跑：绿了每 6 小时一次（`FLEET_CN_PROBE_SECS`），红了每小时一次（`FLEET_CN_PROBE_RED_SECS`）。`FLEET_CN_PROBE=0` 关掉。

每次先 `bin/fleet-cn-probe-env.sh ensure` 把测试路面扶正：

- **测试 pod 跟 stable 的节点镜像**：列车 `node image` 作业在它构建的提交上留一条提交状态 `node image`（描述 `<repo>@sha256:…`）；pod 的镜像不同就 `kubectl set image` 滚到它。pod 不在了，用 `FLEET_CN_PROBE_POD_MANIFEST`（当初 `render.py --user-pod` 渲出来的清单，只留在这台机器上）重建。
- **测试身份**：入口给演练身份的寿命最长 24 小时，到期连同 pod 上的登录一起删。证书不被接受或入口不再列出 pod，就用这台机器的管理员证书 `fleet drill invite --home <pod> --ttl 24h` 重开，客户端 `fleet login`，用一次性批准码确认（批准码只在变量里，不落盘、不打印）。
- 客户端上的登录或 `fleet` 不在了：`useradd` + 入口的安装行。

## 红了会怎样

- 在它测的 stable 提交上留提交状态 `cn path`（failure，指向 breakage 单）；绿了留 success。
- 按卡住的层开一张 breakage 单（`--breakage-key cn-path-<层>`，跨机器去重），发一条 `breakage` 提醒，不开修复会话（#3120）。
- **挡发版**：`bin/fleet-stable.sh` 第 9 道门 `cn:` 读**当前** stable 上最新的 `cn path`。红且它指的单还开着 ⇒ 拒绝前移（`--precheck` 也拦，列车在跑测试前就停）。关掉那张单（修复随这次前移发出）或下一次巡检转绿 ⇒ 放行；`--force` 越过并记 `logs/stable-move.log`；`FLEET_STABLE_CN_GATE=0` 关掉这道门。
- `fleet doctor` 的 `cnpath` 行（那台巡检机上）：通 PASS，不通 WARN 写卡在哪层和单号，超过 12 小时没走 WARN。

## 为什么不在列车里走

1. 国内客户端的安全组只放这台机器的出口进去；列车跑在 GitHub 和集群自己的 runner 上。
2. 一个候选版本的节点镜像要等它发布之后才构建（列车 `node image` 作业），stable 前移前 pod 不可能跑候选版本。

所以巡检走的是**已上线**的入口、客户端和 pod 镜像，它的结论挡**下一次**前移。

## 手动

```sh
bin/fleet-cn-probe.sh                                  # 走一遍，不记任何东西
bin/fleet-cn-probe.sh --layers 'view'                  # 只走连通 + 界面
bin/fleet-cn-probe-env.sh status --repo <owner/name> --stable <sha>   # 测试路面现状，不动
bin/fleet-cn-probe-watch.sh --repo <owner/name> --now  # 立刻巡检一次（记状态、开单）
bin/fleet-cn-probe-watch.sh --repo <owner/name> --dry-run
```
