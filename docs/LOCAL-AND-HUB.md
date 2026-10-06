# 本机模式与联机模式：哪个开关在哪一级

一台机器上的 fleet 有两种跑法，**按 fleet 选**（issue #1539，EPIC #1529 R1）：

- **本机（local）**——这台机器自己就是全部：会话开在这里，列表是这里的 tmux
  窗口，订阅是这个登录自己的账号，不问任何人。没装入口、或者 `CCQUOTA_FLEET`
  不是 `1`，就是这个模式，**逐字节**等于入口出现之前的 fleet。
- **联机（hub）**——这个 fleet 接到跨机器入口（`ccquota hub`，见
  [FLEET-HUB.md](FLEET-HUB.md)）：开会话先拿入口的租约、问入口开在哪台机器，
  侧边栏列出你在别的机器上的会话，回报和消息可以跨机器送达。

两种模式在同一个登录、同一台机器上**可以并存**：一个 fleet 联机，另一个只在本机，
互不影响。`fleet-doctor` 的 `mode` 行逐个 fleet 列出它现在是哪种：

```
INFO  mode     fleet hub (新会话 auto) · scratchpad local — 本机 / 联机各管什么: docs/LOCAL-AND-HUB.md
```

## 一台电脑是什么：fleet 和「承载」

人看到的只有两个词（issue #1806，EPIC #1813 C4）：**fleet**——每台电脑都有的那部分
（`fleet` 命令、它打开的客户端、Agent 配置包）；**承载**——可选能力：这台也跑会话。
配置里只有一个键，`fleet.conf` 的 **`FLEET_HOST=1`**；开关是一条命令：

```sh
fleet host on       # 先说清会发生什么、问 y/N，再打开（--yes 跳过问；没终端又没 --yes 就什么都不改）
fleet host off      # 关掉；是 on 让这台登记到入口的，就连入口程序一起停、通行证放到一边
fleet host status   # 能力: 基础 · 承载 已开 / 未开
```

接了入口时，`fleet host on` 就是入口那边的 node：这台还没登记就先跑 `fleet node join`
（装 tmux、git、`~/.claude/fleet`，已有就跳过），再跑 `fleet node compute on`（先测
这台合不合适，不合适就说原因、不打开；`--force` / `--personal` / `--shared` 原样传过去）；
没接入口时就是这台自己的 fleet 跑会话。入口协议里的名字照旧叫 node（`node.env`、
`/v1/node/*`），对照见 [TERMS.md](TERMS.md)「What a computer is」。

`fleet doctor` 用一行说这台是什么：

```
PASS  fleet    1.0.3 · 入口 在线 · tmux 3.5a · 证书 还有 9h
PASS  能力     基础 · 承载 未开（fleet host on）
```

承载的电脑多一行 `承载`（哪台机器、入口给不给它派会话、节点通行证的检查——#1491 那行）。
旧键 `FLEET_ROLE="client,node"` 由 `fleet-conf.sh migrate`（同步和客户端启动时自动跑）
原地改写成 `FLEET_HOST`：含 `node` 且这台有自己的 fleet、或入口可往这台派会话 ⇒ `1`；
只协调的笔记本（`CCQUOTA_FLEET_COMPUTE=0`、没有自己的 fleet）⇒ `0`。改写之前，读的地方
照旧认旧键，再认一个版本。守护：`bin/fleet-conf-selftest.sh` G 腿、
`bin/fleet-host-selftest.sh`。

## 一条安装命令（issue #1804）

每台电脑——同事的笔记本、m5、m4、只想要这套工具的单机——都是同一条：

```sh
curl -fsSL <入口>/install | sh
```

没有入口时，同一个文件从 GitHub 的 `stable` 取
（`curl -fsSL https://raw.githubusercontent.com/verkyyi/claude-fleet/stable/bin/fleet-install.sh | sh`），
只差入口预填的地址。装的时候从终端（`/dev/tty`，`curl | sh` 也能问）问两件事：

1. **这台电脑要做什么？** `1 只看、只派`（推荐，回车）· `2 也跑会话（承载）`——选 2
   再列出要多装的（git、tmux、后台程序）确认一次。
2. **接入口吗？** `1 接`（命令是从入口复制来的、或 `fleet.conf` 里已有地址时是默认）·
   `2 不接（单机）`。

- **一个目录**：都装在 `~/.claude/fleet`。只看只派 = 客户端清单
  （`tokenledger/internal/api/fleetclient/manifest`）那部分，不要 git；承载 = 同一个目录
  原地换成跟 `stable` 的 git 检出、跑新登录的设置（`bin/fleet-host-install.sh`，
  `fleet host on` 走的也是它）。已是完整安装的目录一个文件都不重下。
- **再跑一次 = 改答案**：回车默认是这台上次的答案，所以再跑零改动；改选 2 只多装承载那部分。
  安装从不拆东西——关承载用 `fleet host off`。也可以不跑安装：`fleet host on`。
- **没有终端可问**（自动化、CI）：按默认只装基础，打印一行
  「要承载：再跑一次本命令，或 fleet host on」。自动化用环境变量预填答案：
  `FLEET_INSTALL_HOST=0|1`、`FLEET_INSTALL_HUB=0|1`（地址 `FLEET_HUB_URL`）。
  旧的 `--host` / `--no-hub` 再认一个版本，作预填答案的别名。
- **两套并存的旧机器**：`~/.local/share/claude-fleet`（旧客户端目录）改成指向
  `~/.claude/fleet` 的符号链接（薄壳，一个版本后删），里面的旧文件在没有程序还从那里跑时删掉；
  正在跑的客户端不断。
- **不接入口时**：不写任何入口地址；承载时最后一行说账号——订阅账号全在本机，
  `claude setup-token` 打出的 token 存成 `~/.config/claude-fleet/accounts/<名字>`（0600）。
- 守护：`bin/fleet-install-selftest.sh` G 腿（不接入口、无终端）、H 腿（伪终端里三种答法、
  再跑零改动、只看 → 承载、预填与交互一致）、I 腿（两套迁移成一套、运行中的进程不断）。

### 不接入口时 `fleet` 打开什么

- **`fleet` 打开的还是同一个客户端**：没有入口地址时 `fleet connect --pick` 答「本机」
  （reason `local`，`fleet connect --print` 打印 `local <机器>`），右窗格直接嵌套接入
  这台机器的 fleet（不 ssh），左边列表是这台机器自己的会话——客户端的取数循环改问本机
  `fleet-remote-view.sh sessions`（`FLEET_HUB_SESSIONS_LOCAL=1`，`via=node`，不会因为
  「入口沉默」变灰），`FLEET_SIDEBAR_SOURCE=local`。开会话、切会话、跨 Agent 迁移
  都是这台机器上那套工具，和一机一 fleet 时一样。
- **什么时候是这个模式**：`FLEET_HUB_URL` / `CCQUOTA_HUB_URL`（环境、`fleet.conf`、
  `shell.conf`）和 `hub.json` 的 `url` 都没有。以后接入口，写上地址（入口的
  `curl -fsSL <入口>/install | sh` 会写）就回到入口来源，**有入口时客户端逐字节照旧**。
- 守护：`bin/fleet-shell-selftest.sh` K 腿（隔离 socket、无入口地址、`CCQUOTA_*` 全清：
  客户端起来、列表是本机 fleet 的全部会话、点一行右窗格切过去；写上地址就是入口环境）、
  `bin/fleet-install-selftest.sh` G 腿（不接入口在临时 HOME 装好、不写入口地址）、
  `bin/fleet-connect-selftest.sh` 第 7 段。

## 开关在哪一级

从低到高：后一级在它管得到的地方赢。

| 开关 | 机器 | 登录（`fleet.settings` / 安装的 `fleet.conf`） | fleet（`fleets/<sess>/conf`） | 仓库（`repos/<slug>.conf`） | 会话（命令行） |
|---|---|---|---|---|---|
| **`CCQUOTA_FLEET`** 联机总开关 | — | 默认值（`export CCQUOTA_FLEET=1`；ccquota 节点程序也读这一个） | **这个 fleet 的值，赢过登录的**（#1539） | — | — |
| **`FLEET_SPAWN_NODE`** 新会话开在哪台机器 | — | 默认值 | **这个 fleet 的值，赢过登录的**（#1539，以前只能全局设） | — | `--node <m>`（`dash-issue-session.sh` / `dash-raw-session.sh`，#1541：两种会话同义） |
| `FLEET_AUTOFILL_NODE` 自动补位开在哪台 | — | — | 有 | — | — |
| `FLEET_SIDEBAR_SOURCE` 列表从哪来 | — | — | `local` / `hub` | — | — |
| `FLEET_NODE_ALIASES` 机器标签 | 每台一份 | 有（全局） | — | — | — |
| `FLEET_ACCOUNTS` 订阅账号 | — | 有（全局） | — | — | — |
| **`FLEET_ACCOUNT_CLASS`** 用哪一类订阅 | — | 默认值 | **这个 fleet 的值，赢过登录的**（#1540） | — | `--account local\|pool\|any`（`dash-issue-session.sh`，赢过 fleet 的；盖在窗口 `@account_class` 上，远程派单一起带过去） |
| 入口地址 `CCQUOTA_HUB_URL` | — | 有（全局；没有就 `hub.json`） | — | — | — |
| **`FLEET_HOST`** 承载：这台跑不跑会话 | 每台一份（`fleet.conf` 的 `[common]`；`fleet host on\|off`） | — | — | — | — |
| 节点凭据 `node.env` | — | 每个登录一份，0600 | — | — | — |
| 维护中 `fleet.node_maintenance.<机器>` | 入口上，每台机器一份 | — | — | — | — |

为什么前两个落在 fleet 级：一个登录可能同时有「跟别的机器共用的仓库」和「只在这台
机器上的草稿 fleet」。以前 `CCQUOTA_FLEET` 名义上写在 fleet 里，实际被采集器、
状态条、派单从环境读——全局的；`FLEET_SPAWN_NODE` 在 global-only 名单里，写进
fleet conf 也被剥掉。现在两者都由 fleet 自己那一行决定，**fleet conf 不写这一行时
读登录的值，和以前一模一样**。

## 模式 × 领域

| 领域 | 本机（local） | 联机（hub） | 读哪里 |
|---|---|---|---|
| **派单**（开 issue 会话） | GitHub 认领就是锁；开在这台机器 | 先拿入口租约（一个 issue 只在一台机器上开），再按 `--node` ▸ `FLEET_SPAWN_NODE` ▸ `auto` 问入口开在哪；入口不通 → 开在这里 | `dash-issue-session.sh` → `fleet_hub_lease` / `fleet_hub_place`（`fleet_hub_on <sess>`） |
| **临时会话** | 开在这台机器 | 同派单：按 `--node` ▸ `FLEET_SPAWN_NODE` ▸ `auto` 问入口开在哪（#1541）——**不拿租约**（临时会话没有 issue），入口按 `<repo> scratch <fleet UUID>` 挑机器，`scratch-N` 的号由开出来的那台机器分配；入口不通 → 开在这里。带 `--prompt` 的和无仓库的临时会话只开在本机（点名别的机器会被拒绝）。侧边栏「新建到 m4…」弹窗里按 ⌃s 就是在 m4 开一个临时会话 | `dash-raw-session.sh` → `fleet_hub_place … scratch`；对端 `fleet-control-read.sh start … scratch` |
| **订阅** | 这个登录 `accounts/` 里的账号（`local` 类） | 同左，另加入口池里的 `hub:<label>` 账号（`pool` 类，入口发短期凭据）。按会话选「只用本地 / 只用池 / 都行」：`dash-issue-session.sh --account local\|pool\|any`（#1540）——盖在窗口 `@account_class` 上，`fleet-claude.sh` 据此只在那一类里挑；派到别的机器时 `ccquota place --account` 带过去，那台机器照样只在那一类里挑；`pool` 但本登录没有池账号 → 拒绝启动，不会悄悄落到本地订阅 | `fleet-account.sh`（`FLEET_ACCOUNT_CLASS` 过滤 `acct_labels`） |
| **列表来源** | 这台机器的 tmux 窗口 | `FLEET_SIDEBAR_SOURCE=local`：本机窗口 + 入口缓存里你在别的机器上的会话；`=hub`：整张表来自入口的 `fleet_sessions`（本机置顶的和无仓库的窗口照留——入口不认识它们，#1643），状态条换成机器 / 额度 / 入口的版式 | `tmux-dashboard-rows.sh`、`tmux-status.sh`（读 `$FLEET_C` 缓存，渲染路径不联网） |
| **取数** | 无 | 采集器在**至少一个** fleet 联机时跑 `hubsess` 阶段；`fleet-hub-sessions.sh` 只给联机的 fleet 写 `remote_<sess>` | `tmux-dash-collect.sh`（`fleet_hub_any`） |
| **回报 / 消息** | 只到本机窗口 | 本机找不到的 worker_id 走入口 outbox（`fleet_hub_put`）送到它所在的机器 | `fleet-report-parent.sh`、`fleet-peer-send.sh` |
| **凭据** | `gh auth`、账号 token（0600）；不碰入口 | 另加：节点 token 在 `node.env`，只在跑 `ccquota lease/place/move` 的子 shell 里读，从不进窗格环境（#1491）；看列表用你的连接证书 `~/.ssh/fleet-cert`，没有就用查看 token | `_fleet_hub_env`、`fleet-hub-sessions.sh` |

节点程序（`ccquota agent`，每个登录一个 launchd 服务）读的是**它自己环境里**的
`CCQUOTA_FLEET`——它为整个登录上报心跳，所以它的开关仍是登录级的。fleet conf 里
写 `CCQUOTA_FLEET=0` 只让这个 fleet 的派单、列表、状态条回到本机模式；节点程序照常
在线，别的机器照常看得见这台。

## 怎么切

- 一个 fleet 联机、其余本机：登录不设，fleet conf 写 `CCQUOTA_FLEET=1`。
- 整个登录联机、某个 fleet 留在本机：登录 `export CCQUOTA_FLEET=1`，那个 fleet 的
  conf 写 `CCQUOTA_FLEET=0`。
- prefix+c 的配置面板里两键都是 fleet 级（`@scope=fleet`），写进当前 fleet 的 conf。

## 守护

- 退化腿：`bin/hub-place-selftest.sh` `PERFLEET`——两个 fleet 一开一关，登录值
  指向哪边都互不影响；fleet 的 `FLEET_SPAWN_NODE` 赢过登录的，不写就跟登录。
  其余 `OFF` 腿保证没开入口时逐字节不变。
- 订阅类别（#1540）：`bin/fleet-account-selftest.sh` 末段——`local` 时永远选不到
  `hub:` 账号、`pool` 时只选它们、`any`/不写/乱写逐字节不变，按类挑的结果从不改写
  `account.active`；`bin/hub-place-selftest.sh` `ACCOUNT`——旗标上了 place 命令、
  盖在了窗口上，fleet conf 的默认值与 `--account any` 的关法；
  `bin/fleet-hub-selftest.py` `test_start_carries_the_account_class`——入口派来
  的 `worker_start` 把 `account_class` 回放成 `--account`。
- 临时会话腿：同一文件的 `SCRATCH` 腿（#1541）——没开入口时 `dash-raw-session.sh`
  逐字节不变、`--node m4` 被拒绝；开了入口时 REMOTE / LOCAL / 被拒 / 未知 / 入口不通
  与派单同一套分支，全程不调租约；入口派来的 start 不再二次问入口。入口侧
  `TestNodePlaceScratch*`（`fleet_place_test.go`）、节点侧
  `test_start_scratch_opens_a_raw_session`（`fleet-hub-selftest.py`）。
- `bin/tmux-config-selftest.sh` 核对 global-only 名单与 `fleet.conf.example` 的
  `@scope=global` 标签同步。
