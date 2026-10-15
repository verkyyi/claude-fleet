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

每一次走路——diskguard 的拍子、手动 `--now`、恢复验证，绿的也算——都在 `$FLEET_CONF_DIR/global/cn-probe/history.ndjson` 记一行（`ev: run`：`mode` · `run_id` · stable · 结论 · 类别 · `reason_code` · 起止 · result 路径）；一拍没走，理由也记（`ev: skip`：节流到几点、锁被哪个 pid 占着、时钟落后于上次的 stamp），同一个理由只记一次；锁里写着持有者的 pid，持有者已经不在就当场接管（`ev: lock_reclaimed`），活着的照旧一小时为限。diskguard 的 `diskguard/cn-probe.log` 只是它那一拍的输出（#4304）。

## 修复上线后的恢复验证（#4304）

修复真正部署、就绪之后（不是合并的时候），由编排开一轮有界的恢复验证：

```sh
bin/fleet-cn-probe-watch.sh --repo <owner/name> --recover --expect stable=<sha> [--expect image=sha256:…] --why '<修的是什么>'
python3 bin/fleet-cn-probe-recover.py "$FLEET_CONF_DIR/global/cn-probe" status   # 这一轮到哪了
python3 bin/fleet-cn-probe-recover.py "$FLEET_CONF_DIR/global/cn-probe" stop --why '<为什么>'
```

`--recover` 开一轮（同一个期望重复开是同一轮，什么都不新起）并当场走一次；之后每一拍问这一轮该不该走——该走的那拍不管节流，仍在同一把锁下、一次一轮。账本 `bin/fleet-cn-probe-recover.py`（`global/cn-probe/recover.json`）：

- **间隔**：默认一次接一次连着跑（上一次结束后的下一拍就开始，不按整点），串行不重叠；`FLEET_CN_RECOVER_EVERY`（0 s，起点到起点）可拉开。
- **算一次通过**：#4303 的 `result.json` 说 pass、类别 none；每条路由的 connect / view / codex 都走过且过（`FLEET_CN_RECOVER_STAGES`，默认 `entry relay view:entry view:relay codex:entry codex:relay`）；诊断读全了部署向量——hub、hub 发的客户端、客户端、节点运行时、镜像 digest、pod UID，没有 `unknown`；每个 `--expect`（`stable=` `hub=` `client=` `runtime=` `image=` `pod=` 或完整键名）都在读数里；时间合理（结束不早于开始、在这一轮和这次登记之内、时钟没有倒退）；且这次是本轮登记过的。
- **归零**：红、env、probe、半截、版本读不到或不符、时钟倒退、超时、巡检死掉（`abandoned`）都清零；换了向量的通过从 1 重数。同一个 run_id 只判一次，巡检崩了重来不会重复计。
- **结束**：同一向量上连续 `FLEET_CN_RECOVER_NEED`（3）次 ⇒ `done`；跑满 `FLEET_CN_RECOVER_MAX_RUNS`（6）次或 `FLEET_CN_RECOVER_MAX_SECS`（5400 s）⇒ `exhausted`，写明差几次。两种都写证据 `global/cn-probe/recover/<round>.json`（0600：每一次的 run_id、结论、原因、向量、result 路径；done 时列出那 3 次独立完整的运行），巡检回到原来的节流。

探针每轮自己开的 Codex 会话一律收掉：客户端的 `fleet close` 收不掉，就当轮经 `fleet connect` 在 pod 上按会话的 fleet id 优雅停掉（`fleet-worker-stop.sh fid:`）；还收不掉的记在 `runs/.left-sessions`，下一轮开自己的会话之前先收（#4304：一晚积了 8 个，pod 的 CPU 门于是拒了下一轮）。

它只给编排核对稳定窗口用：不动 stable、不合 PR、不改发布门、不开单；每次只关自己开的测试会话（探针本来如此）。

每次先 `bin/fleet-cn-probe-env.sh ensure` 把测试路面扶正：

- **测试 pod 跟 stable 的节点镜像**：列车 `node image` 作业在它构建的提交上留一条提交状态 `node image`（描述 `<repo>@sha256:…`）；pod 的镜像不同就 `kubectl set image` 滚到它。pod 不在了，用 `FLEET_CN_PROBE_POD_MANIFEST`（当初 `render.py --user-pod` 渲出来的清单，只留在这台机器上）重建。
- **测试身份**：入口给演练身份的寿命最长 24 小时，到期连同 pod 上的登录一起删。证书不被接受或入口不再列出 pod，就用这台机器的管理员证书 `fleet drill invite --home <pod> --ttl 24h` 重开，客户端 `fleet login`，用一次性批准码确认（批准码只在变量里，不落盘、不打印）。
- 客户端上的登录或 `fleet` 不在了：`useradd` + 入口的安装行。

## 一轮的结果与诊断（#4303）

每轮一个 `run_id`，目录 `$FLEET_CONF_DIR/global/cn-probe/runs/<run_id>/`（0700，文件 0600），巡检的 `last.json` 记着 `run_id` 和 `result`：

- `stages.tsv` → **`result.json`**：每阶段的起止、耗时、可机读 `reason_code`、证据（`ev/<阶段>.txt`，脱敏）和类别——`product` 产品失败、`env` 测试路面无效（客户端机器、它的登录、演练身份过期、pod 不在名单、`ensure` 失败）、`probe` 探针自己出错。只有一个失败阶段都没有才算通；`env` 和 `probe` 都不算通过。探针打印的 `RESULT` / `CLASS` / `通：` / `不通：` 行和退出码都由 `bin/fleet-cn-probe-result.py render` 从这个文件生成，一份结论。
- **`diag.json`**：`bin/fleet-cn-probe-diag.sh` 每轮一次的只读、脱敏诊断——hub / 客户端 / 节点运行时 / ccquota 版本，pod 名、UID、镜像和实际运行的 digest，证书主体与有效期、入口名单，准入闸门的判定、真正的拒绝者和 CPU / 内存 / 磁盘读数（闸门对着状态文件的副本跑，不写任何东西），凭据代理的信任、各家走哪条路、最近一次启动和最近一次 `nocred`，开号器在跑还是被关、为什么、运行时目录权限。读不到的项写 `unknown`，`sources` 说每个来源怎么样；凭据文件一概不读，token / cookie / 码一律删去。有 kubectl 的这台机器从集群直接读 pod（`kubectl exec`，只读命令），否则经客户端 `fleet connect`。
- Codex 步只读本轮 `--new` 会话自己那块屏：已经出现明确终止错误（`unexpected status 4xx`，不含 408 / 429 和正在重试的行；钥匙被拒；证书过期 / 吊销）就当场失败，reason 按原话分（`upstream_no_credential` · `upstream_http_<码>` · `cert_refused`）；没有明确错误照常等到 `FLEET_CN_PROBE_ANSWER`。
- `ensure` 失败就是本轮结论（`env` · `ensure:<部分>`），不跑探针、不开会话；单的标题写「国内探针环境无效」，提交状态写「环境无效」。

后续有界复测沿用这个格式。

## 红了会怎样

排查 `codex` 超时要同时看 pod 上的回答和客户端自己的 `*.ssherr`。`Session open refused by peer` 后跟 `Could not resolve hostname u-…` 表示 SSH 复用会话被拒后退回了裸主机名，不能仅凭界面的「找不到这台机器的地址」判断入口丢了在线状态。客户端应在复用连接返回 255 后为当前窗口重新选路，不关闭其他窗口共用的连接。双副本下还需分别验证机器身份鉴权和门 / pod 的跳转就绪状态；连接落在哪个副本都应得到一致结果。

个人 POD 的 CPU 准入策略还必须经真实 SSH 登录验证：容器环境里的 `FLEET_USER_POD=1` 不会自动传入 sshd 创建的会话。pod 的服务端 sshd 配置用 `SetEnv FLEET_USER_POD=1` 保留这个身份；不能只看 `kubectl exec` 或 tmux 服务端环境就认定客户端开会话也走个人 POD 策略。内存保护和显式 `FLEET_ADMIT_POD_CPU=hold` 仍然生效。

- 在它测的 stable 提交上留提交状态 `cn path`（failure，指向 breakage 单）；绿了留 success。
- 按卡住的层开一张 breakage 单（`--breakage-key cn-path-<层>`，跨机器去重），发一条 `breakage` 提醒，不开修复会话（#3120）。
- **挡发版**：`bin/fleet-stable.sh` 第 9 道门 `cn:` 读**当前** stable 上最新的 `cn path`。红且它指的单还开着 ⇒ 拒绝前移（`--precheck` 也拦，列车在跑测试前就停）。关掉那张单（修复随这次前移发出）或下一次巡检转绿 ⇒ 放行；`--force` 越过并记 `logs/stable-move.log`；`FLEET_STABLE_CN_GATE=0` 关掉这道门。
- `fleet doctor` 的 `cnpath` 行（那台巡检机上）：通 PASS，不通 WARN 写卡在哪层和单号，超过 12 小时没走 WARN。

## 为什么不在列车里走

1. 国内客户端的安全组只放这台机器的出口进去；列车跑在 GitHub 和集群自己的 runner 上。
2. 一个候选版本的节点镜像要等它发布之后才构建（列车 `node image` 作业），stable 前移前 pod 不可能跑候选版本。

所以巡检走的是**已上线**的入口、客户端和 pod 镜像，它的结论挡**下一次**前移。

POD 重建验收还要保留客户端已有的自动 / 固定线路缓存，先直接重连，不能先 `--retest` 或删 known_hosts 掩盖旧密钥问题。连接器对 POD 从已鉴权的 hub 路由刷新主机身份；已有 home 响应直接复用，不再请求一次。身份变化后不走旧缓存捷径。hub 不可用时只保留原有信任，未知密钥仍由 SSH 拒绝，不能关闭主机校验。

控制器的异步启动链路也要保留 `FLEET_USER_POD`：`fleet_control.Control.environment()` 同时用于 detached executor 和 adapter，只修 SSH 环境还不够。回归要在模拟高 CPU 下走真实控制器的异步 scratch 启动，确认个人 POD 放行、共享机器拒绝、显式 CPU hold 与严重内存压力仍拒绝；不能靠恰好低负载的一次实测认定已修复。其他准入覆盖参数和凭据仍不从调用者环境透传。

无仓库会话的回收也属于验收：必须由客户端 `fleet close <wid> --yes` 正常完成，不能把 `fleet-worker-stop.sh fid:` 兜底成功当作客户端回收已通过。控制器应保留会话的唯一身份，不能把它改成空的工作树 key 后匹配所有无仓库会话；相同身份确实出现在两个窗口时仍应拒绝操作。

## 手动

```sh
bin/fleet-cn-probe.sh                                  # 走一遍（只写 runs/<run_id>/，不记巡检状态、不开单）
bin/fleet-cn-probe-diag.sh                             # 只读诊断一次，写 runs/<id>/diag.json
bin/fleet-cn-probe.sh --layers 'view'                  # 只走连通 + 界面
bin/fleet-cn-probe-env.sh status --repo <owner/name> --stable <sha>   # 测试路面现状，不动
bin/fleet-cn-probe-watch.sh --repo <owner/name> --now  # 立刻巡检一次（记状态、开单）
bin/fleet-cn-probe-watch.sh --repo <owner/name> --dry-run
```
