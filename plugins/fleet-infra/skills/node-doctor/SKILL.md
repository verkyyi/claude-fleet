---
name: node-doctor
description: 读懂 `fleet doctor`（和机器那半 `fleet doctor --machine`）——每一行 PASS / WARN / FAIL / INFO 是什么意思、先修哪一行、每个 WARN / FAIL 该去哪个运维技能；本页末尾的「行 → 技能」对照覆盖体检能打出的每一行（由体检的行表生成，自测核对）。用于「体检有 WARN / FAIL 怎么办」「这一行什么意思」「托管机器体检不绿」「更新后体检多了 FAIL」。给机器管理员用；成员和管理员看的对外故障排查页是另一份。
---

# node-doctor — 读懂体检

占位：`<RT>` 运行时根目录（macOS `/Library/Application Support/claude-fleet`）· `<ROW>` 体检里的行名（第二列）。
权威出处：`bin/fleet-doctor.sh`（每一行的判据和行内修法都写在它旁边的注释里）· `bin/fleet-node-update.py doctor`（`--machine` 那半，
更新器的回滚判据）· `bin/fleet-doctor-rows.py`（行表：两半能打出的全部行名）· `docs/dev/MANAGED-NODE.md` §7「机器体检」。

**分工**：本页给**机器管理员**——一台机器体检不绿时从哪一行下手、去哪本手册。对外的故障排查页给**成员和管理员**——按症状
（「连不上」「会话没反应」）写，不按行名。两份都从同一张体检行表来，不各抄一份。

## 什么时候用

- `fleet doctor` 有 WARN / FAIL，想知道是什么、先修哪个。
- 托管机器 `fleet doctor --machine` 有 FAIL（更新器会因为「切换后多出的 FAIL」回滚整版）。
- 换版、换机器、改配置之后复查。

## 先查什么

```sh
fleet doctor                                   # 这台、这个登录：一行一项，行尾就是修法
fleet doctor --machine                         # 托管机器的整机半：运行时、各部件、守护、签名身份（root 跑的那份）
fleet doctor --installs                        # 这台上每份安装离 stable 多远
fleet doctor | grep -E '^ *(WARN|FAIL) '        # 只看要动的
```

- 每行是 `<级别>  <行名>  <说明>`。**FAIL** = 坏了、要修（会话或机器有东西不工作）；**WARN** = 会出事 / 没跟上，要看；
  **INFO** = 提示，从不计数；**PASS** = 好。退出码 = FAIL 的个数（`--machine` 同样）。
- 绝大多数行的说明里已经写着修法（`fix: …`、`` `命令` ``）——先照它做，它比任何手册都具体。
- 行名在末尾的对照表里查：「来自」说是 `fleet doctor`（node）还是 `--machine`（machine）打的，「去哪」是对应的技能。

## 步骤

1. **先修 FAIL，再看 WARN**；同一类先修最底下的：`tools` / `python3` / `tmux`（机器上的程序）→ `daemon` / `node` / `runtime`
   （守护与运行时）→ `cert` / `hubauth` / `hub`（和入口的身份）→ 其余。底下的坏了，上面的行多半是连带的。
2. 每个 WARN / FAIL：在对照表里找到它的行，**先做「先做什么」那一格**；要完整流程再打开「去哪」那个技能。去哪写着
   `[node-doctor]` 的行没有专门的运维手册——照行内的修法做，那一格是要点。
3. **换版后多出的 FAIL**（托管机器）：更新器拿「切换前体检没打、切换后打了」的 FAIL 做回滚判据，会自己退回上一版、跳过这个 sha；
   不用手动回退。看 `update` 行和 `/var/log/fleet-node/update.log`，原因修好后发下一版（[release-rules]）。
4. **说明里有「下一轮补」「下一次同步补」的 WARN**：更新器 / install-sync 会自己补；超过一轮（5 分钟）或一小时还在，再按「去哪」查。
5. **一行不在对照表里**：体检新加了行而本页没跟上——自测会红；先照行内修法做，并在仓库里跑
   `python3 bin/fleet-doctor-rows.py skeleton --from plugins/fleet-infra/skills/node-doctor/SKILL.md` 补上那一行。

## 怎么验收

- `fleet doctor` 退 0（没有 FAIL），WARN 只剩你知道为什么、接受它的（例如「这台没有公网地址」）。
- 托管机器：`fleet doctor --machine` 退 0；`fleet doctor --installs` 都在 stable。
- 修的那一行变 PASS，且它的说明是你预期的读数（不是「没查」「读不到」）。

## 怎么回滚

- 体检只读、不改任何东西，没有回滚。
- 照某一行的修法动过机器：回滚那一步写在「去哪」那个技能的「怎么回滚」里；行内修法通常是幂等的补齐（同步、重链、重启），撤回就是
  不再做，下一轮体检照实报。

## 行 → 技能对照

`来自`：node = `fleet doctor`，machine = `fleet doctor --machine`。`去哪`：本插件的技能。这张表由
`python3 bin/fleet-doctor-rows.py skeleton --from <本文件>` 生成骨架（已有的行原样保留，新行是 `?`），
`fleet-plugins-selftest.sh` K 核对：体检的行名集合 ⊆ 本表、没有 `?`、每个技能都存在。

| 行 | 来自 | 去哪 | 先做什么 |
|---|---|---|---|
| `account` | node · machine | [login-lifecycle] | 本机：`chmod 600` 令牌文件或 `claude setup-token` 重领；`--machine`：账号的 claude · codex · tmux 下一轮重链 |
| `account-pick` | node | [node-doctor] | 额度读不到——先看 `qwatch` / `quota` 行 |
| `admin-agent` | machine | [mac-node-enroll] [runbook-tcc-stuck] | 更新器下一轮重指；没重启就 `sudo launchctl kickstart -k system/com.ccquota.agent.<admin>` |
| `admit` | node | [node-doctor] | 容量门全关了：`FLEET_GLOBAL_MAX_SESSIONS` / `FLEET_MACHINE_MAX_SESSIONS` / `FLEET_ADMIT` 至少开一个 |
| `agent` | node | [release-rules] | 登录的 ccquota agent 落后 stable：照行内命令先 `--dry-run` 再逐个重启 |
| `agentcfg` | node | [release-rules] | 新版后老会话会坏：`fleet-oldcfg-check.sh --sweep --list` 点名，逐个重开 |
| `agentdef` | node | [release-rules] | `claude update`；托管机器等更新器跟上 release.json 钉的版本 |
| `agentdup` | node | [mac-node-enroll] | 同一登录多个 ccquota agent：照行内命令经启动项重启，只留一个 |
| `agents` | node | [release-rules] | 默认 MCP / 技能缺：下一次同步补齐（只补不改） |
| `alerts` | node | [node-doctor] | 状态栏 prefix ! 列出每条提醒，逐条看 |
| `base` | node | [node-doctor] | 仓库配置：写 `FLEET_BASE_BRANCH`，且它要是仓库的默认分支 |
| `basesync` | node | [mac-node-enroll] | 守护没装上：重跑 `sudo fleet node install`（同一条命令也是修复） |
| `brew` | node | [mac-node-prep] | Homebrew 目录权限：照行内修 |
| `cache` | machine | [release-rules] | 装机缓存的 claude 不是 release.json 的：更新器下一轮补 |
| `ccquota` | machine | [hub-deploy] [release-rules] | 发布版带错了 ccquota：按 stable 重新部署入口镜像，再让列车发下一版 |
| `cert` | node | [mac-node-enroll] | 连接证书入口不认：`fleet login` 重签，或重跑 `fleet node install --join` |
| `checkout` | node | [node-doctor] | 基础 checkout 不在 base 分支：照行内命令移走占着它的 worktree |
| `child` | machine | [mac-node-enroll] | 守护的子进程挂了：看 `fleet-node-supervisor.py status` 与它的日志，重跑 `fleet node install` |
| `ci-runner` | node | [runbook-train-stuck] | 自家测试机：`fleet-node-supervisor.py status` 的 ci-runner 行与 ci-runner.log |
| `claude` | node · machine | [mac-node-prep] [release-rules] | 装 Claude Code；托管机器上由 release.json 钉、更新器装 |
| `cleanup` | node | [mac-node-enroll] | 收尾守护没装上：重跑 `sudo fleet node install`；或它缺 gh：装 gh 并 `gh auth login` |
| `codesign` | machine | [runbook-tcc-stuck] | 没有固定签名身份 / 没签上：下一轮补签；之后给它授权一次 |
| `codex` | node · machine | [mac-node-prep] [release-rules] | Codex CLI 版本 / 安装：照行内修；托管机器由更新器装 |
| `collect` | node | [node-doctor] | 采集守护卡住或超时：看 collect 日志里最慢的阶段 |
| `commands` | node | [release-rules] | fleet 的 /命令 没装：下一次同步补，或装 fleet 插件 |
| `compose` | node | [node-doctor] | ⌘P 慢：`fleet-compose-latency.sh --last 20` 看哪一段 |
| `compute` | node | [node-doctor] | 这台能不能接入口派的会话：node.env 的 `CCQUOTA_FLEET_COMPUTE` |
| `config` | node | [release-rules] | 安装不完整（缺 fleet.conf.example）：下一次同步补 |
| `context` | node | [node-doctor] | 压缩后没续跑：看 context-ladder.log 的 resumed 行 |
| `cpu` | node | [ack-linux-node] | 容器到了 CPU 上限：调大这台 Linux 节点的 limits |
| `cred` | node | [sg-relay-setup] [login-lifecycle] | 会话凭据走哪条路：照行内的 trust × probe 结论修中转或代理 |
| `credpool` | machine | [login-lifecycle] | 共享凭据池：照行内修 |
| `credsep` | node · machine | [mac-node-enroll] | 凭据隔离：照行内（代理没起 / 该并入整机共享代理）；整机的代码不是这一版 ⇒ `fleet-credsep.py machine refresh`（更新器每轮也做） |
| `credsep-all` | node | [mac-node-enroll] | 托管登录都做了凭据隔离：FAIL 点名没隔离的、WARN 点名还跑自己代理的；管理员一条 `sudo bash ~/.claude/fleet/bin/fleet-credsep.sh machine install --logins managed` |
| `daemon` | machine | [mac-node-enroll] [release-rules] | 整机守护没装 / 没在跑 / 没重启到 current：重跑 `sudo fleet node install` |
| `daemons` | node | [mac-node-enroll] | 某个守护没加载：重跑安装，或看它的 launchd 日志 |
| `deploy` | node | [node-doctor] | 仓库配置：`FLEET_DEPLOY_REF` / `FLEET_DEPLOY_CHECK` 写错了 |
| `deps` | node | [node-doctor] | 基础 checkout 的依赖：照行内 `fleet-deps-link.sh --prime-base` |
| `dist` | node | [release-rules] | 这个登录的新版本不是从入口来的：照行内改回入口 |
| `docprev` | node | [node-doctor] | doc-preview 旧进程 / 残留路由 / 过期公开链接：照行内的 share.sh 命令 |
| `drill` | machine | [release-rules] | 演练标记（故意失败）：更新器会回滚，不用动 |
| `emit` | node | [node-doctor] | 事件外发：装 curl，或修 `FLEET_EMIT_URL` 的接收端 |
| `entry` | node | [runbook-door-down] | 入口端口：名单落后 / 配置被拒 / 有人却没在听 |
| `epic` | node | [node-doctor] | 批次没人在跑：在一个不绑单的会话里重新 `/fleet-epic-run <N>` |
| `failover` | node | [login-lifecycle] | 账号切换状态：`fleet-account.sh failover-status` |
| `failover-stuck` | node | [login-lifecycle] | 迁移卡住：照行内 `fleet-account.sh migrate --stuck` |
| `feedback` | node | [node-doctor] | 只报状态，从不 WARN |
| `files` | node | [mac-node-prep] | 打开文件数快满：找出谁开的，必要时调高系统上限 |
| `firstrun` | node | [mac-node-prep] | 首次运行检查没过：照行内修 |
| `fleet` | node | [release-rules] | 常驻服务还跑切换前的版本：照行内重启；客户端落后：`fleet update` |
| `fzf` | node | [mac-node-prep] | 装 fzf ≥ 0.45 |
| `gate` | node | [node-doctor] | 只报状态：公开前的七项安全门槛 |
| `gh` | node | [mac-node-prep] | 装 gh 并 `gh auth login` |
| `github` | node | [node-doctor] | GitHub GraphQL 额度用完：等重置，期间走 REST，不是权限问题 |
| `handoff` | node | [release-rules] | 自动交接的阈值读不到：同步安装补上 bin/fleet-hook-conf.sh |
| `helper` | machine | [release-rules] | 部件缺它的帮手程序：更新器下一轮补 |
| `hooks` | node | [release-rules] | settings.json 的 hook 表不对：`python3 fleet-hooks-merge.py merge`（同步时也做） |
| `hub` | node | [mac-node-enroll] | node.env 与 fleet.conf 对入口说法不一：`fleet-conf.sh migrate` |
| `hub-image` | node | [hub-deploy] [release-rules] | 入口镜像落后 / 分叉 / 与 stable 不同源：按 stable 重新部署入口，或等下一趟列车 |
| `hub-sessions` | node | [node-doctor] | 别的机器的会话不刷新：照行内修（入口在不在、令牌） |
| `hubauth` | node | [mac-node-enroll] [login-lifecycle] | 入口不认这台的令牌：查 node.env，或 `fleet login` |
| `icloud` | node | [mac-node-prep] | 退出 iCloud 或关同步 |
| `ingress` | node | [runbook-door-down] | 系统 sshd 的公网转发探不通：查路由器转发与远程登录 |
| `install` | node · machine | [release-rules] | 安装落后 / 有本地提交 / 分叉 stable：让 install-sync 跟上，不在会话里手同步 |
| `key` | machine | [release-rules] [mac-node-enroll] | 发布签名钥匙没钉 / 对不上：`sudo fleet node install --release-key <file>` |
| `keys` | node | [node-doctor] | 面板键与 tmux prefix 撞了：改 prefix2 或那个键 |
| `labels` | node | [node-doctor] | 仓库缺 fleet 标签：`fleet-labels-seed.sh --repo <repo>` |
| `laptop` | node | [node-doctor] | 笔记本上的 iTerm2 插件缺 / 旧：在那台重跑 extras/iterm2/install.sh |
| `last-crash` | node | [mac-node-prep] | 机器一天内崩过：看崩溃摘要，查内存 / 温度 |
| `launchd` | node | [mac-node-prep] | launchd 的 gui 域坏了：机器层面——注销重登或重启 |
| `ledger` | node | [mac-node-enroll] | 守护没装上：重跑 `sudo fleet node install` |
| `listen` | node | [node-doctor] | 有 fleet 进程监听在局域网：改成 127.0.0.1，或停掉它 |
| `login-tree` | machine | [login-lifecycle] [release-rules] | 登录的 ~/.claude/fleet 指向已不在的版本：更新器下一轮重建链接树 |
| `machine` | node | [mac-node-prep] | 负载过高 / 有失控孤儿进程：`fleet-diskguard.sh --orphans` 点名 |
| `main` | node | [node-doctor] | 仓库配置：`FLEET_MAIN` 不在 / 不是 git / origin 不对 |
| `mcp` | node | [node-doctor] | 没有 MCP 白名单：给这个 fleet 写一份 |
| `memory` | node | [mac-node-prep] | 内存吃紧：`fleet-memguard.sh --once --dry-run` 看会停谁 |
| `metrics` | node | [node-doctor] | 5 分钟没有机器指标：diskguard 守护在不在跑 |
| `mod` | node | [release-rules] | 扩展目录不在：下一次同步补 |
| `mode` | node | [node-doctor] | 只报状态：本机 / 联机 |
| `modelcap` | node | [node-doctor] | 只报状态：按模型的额度窗 |
| `network` | node | [mac-node-prep] | 两块网卡在同一个子网：拔掉一条或改路由 |
| `node` | node | [mac-node-enroll] [runbook-tcc-stuck] | 整机守护：令牌被拒 ⇒ `account adopt <login> --rejoin`；没有完全磁盘访问 / TCC 卡住 ⇒ 卡死手册 |
| `nofile` | node | [mac-node-prep] | 只报状态：系统默认文件数上限 |
| `oldkeys` | node | [node-doctor] | 只报状态：还在按退役的快捷键 |
| `onboard` | node | [node-doctor] | 就绪探针没过：照行内修 |
| `open` | node | [node-doctor] | open.secret 权限不是 0600：`chmod 600` |
| `peerlink` | node | [node-doctor] | 机器间链路：`fleet-peerlink.py status` |
| `perl` | node | [mac-node-prep] | 装 Time::HiRes（不装也只是转圈按整秒） |
| `personcert` | node | [mac-node-enroll] | 节点在用个人的 fleet login：查 node.env / 凭据代理，节点只用自己的令牌 |
| `plugins` | node | [release-rules] | 插件落后：`claude plugin update`，或等同步 |
| `pty` | node | [mac-node-prep] | 终端数快满：找出谁占的，必要时调高系统上限 |
| `public` | node | [runbook-door-down] | 外面连不上入口端口：路由器转发、公网地址、钥匙不符 |
| `python3` | node | [mac-node-prep] | 装 python3 |
| `quota` | node | [login-lifecycle] | 额度读数缺 / 形状不认识：查入口与账号，`fleet-account.sh quota --refresh` |
| `qwatch` | node | [login-lifecycle] [mac-node-enroll] | 额度缓存不刷新：先修凭据（cert / node 行、`fleet login`），再 `fleet-account.sh quota --refresh` |
| `reap` | node | [node-doctor] | 有会话该收没收：照行内读原因 |
| `repo` | node | [node-doctor] | fleet 覆盖层没写 FLEET_REPO |
| `repos` | node | [node-doctor] | 只报状态：托管的仓库 |
| `roles` | node | [release-rules] | 角色定义取不到：`fleet-agent-team.py sync` |
| `rootlog` | node | [mac-node-enroll] | root 服务的日志写在家目录里：重跑安装把日志挪出去 |
| `runtime` | machine | [release-rules] [mac-node-enroll] | 没有 root 运行时（未托管）或 current 不是一个发布版：`sudo fleet node install` |
| `rview` | node | [node-doctor] | 远端客户端挂在 fleet 会话上：让它们各用自己的视图会话 |
| `seats` | node | [mac-node-enroll] | 个人账号在跑整机或管理服务：`sudo fleet node install` 收回到 root / 角色账号；`fleet-node-supervisor.py seats --json` 看是哪个 |
| `seed` | node | [node-doctor] | 只报状态：新会话的第一句 |
| `services` | node | [mac-node-enroll] | 登记的服务挂了 / 有手写的 launchd 启动项：`fleet ls --services` |
| `settings` | node | [release-rules] | Claude 设置缺键：下一次同步补（只补不改） |
| `shell` | machine | [release-rules] | 客户端 shell 落后：`fleet update` |
| `siri` | node | [mac-node-prep] | 关 Siri |
| `skills` | node | [release-rules] [mac-node-prep] | 技能缺依赖（handoff 基础技能、tailscale）：同步安装 / 装 tailscale |
| `sleep` | node | [mac-node-prep] | 机器会睡：`sudo pmset -a sleep 0 autorestart 1 womp 1` |
| `socket` | node | [node-doctor] | tmux socket 被一个快死的服务器占着：`fleet-up.sh` 清掉并拉起 |
| `spotlight` | node | [mac-node-prep] | Spotlight 还在索引：`sudo mdutil -a -i off` |
| `sshtrust` | node | [node-doctor] | authorized_keys 里有别的 fleet 机器的永久钥匙：删掉，机器间走五分钟证书 |
| `state` | node | [node-doctor] | 状态对账没跑：查 com.claude-fleet.sleep 与它的日志 |
| `statusln` | node | [node-doctor] | 状态行缺 jq / 窗口没心跳：`brew install jq`，或重开那些窗口 |
| `team` | node | [release-rules] | 团队层没同步：`fleet-agent-team.py sync` |
| `tenants` | node | [login-lifecycle] | 接管的登录有管理员 / sudo：移出 admin 组与 sudoers |
| `testtmux` | node | [node-doctor] | 自测没清掉的 tmux 服务器：照行内清 |
| `tls` | node | [mac-node-prep] | python 验不了入口证书：装 CA（certifi），或换系统 python |
| `tmux` | node · machine | [mac-node-prep] [release-rules] | 装 tmux ≥ 3.2；托管机器由更新器装 |
| `tmuxconf` | node | [release-rules] | tmux 服务器载入的是旧 fleet 配置：照行内 `fleet-ui-refresh.sh` |
| `tools` | node | [mac-node-prep] | 裸 PATH 找不到工具：装上，或照行内设路径 |
| `trust` | node | [node-doctor] | 仓库目录没被 Claude Code 信任：照行内 grant |
| `update` | node | [release-rules] | 整机更新器报错：/var/log/fleet-node/update.log，`fleet doctor --machine` |
| `versions` | machine | [release-rules] | 只报状态：本机留着几个发布版、占多少盘 |
| `webhook` | node | [node-doctor] | webhook 缺 gh / gh-webhook 扩展 / python3：照行内装 |
| `wtroot` | node | [node-doctor] | worktree 根目录：照行内修 |
| `信任框` | node | [node-doctor] | 只报状态：没预信任时新会话会停在信任框 |
| `可信` | node | [login-lifecycle] | 这台不可信，入口不发订阅凭据：操作者 `fleet-node-trust.sh set <machine> trusted` |
| `承载` | node | [mac-node-enroll] | 这台能不能跑会话：照行内修令牌 / 开关 |
| `能力` | node | [release-rules] | 还在读旧配置文件：`fleet-conf.sh migrate` |
