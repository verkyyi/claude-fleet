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

## 开关在哪一级

从低到高：后一级在它管得到的地方赢。

| 开关 | 机器 | 登录（`fleet.settings` / 安装的 `fleet.conf`） | fleet（`fleets/<sess>/conf`） | 仓库（`repos/<slug>.conf`） | 会话（命令行） |
|---|---|---|---|---|---|
| **`CCQUOTA_FLEET`** 联机总开关 | — | 默认值（`export CCQUOTA_FLEET=1`；ccquota 节点程序也读这一个） | **这个 fleet 的值，赢过登录的**（#1539） | — | — |
| **`FLEET_SPAWN_NODE`** 新会话开在哪台机器 | — | 默认值 | **这个 fleet 的值，赢过登录的**（#1539，以前只能全局设） | — | `--node <m>`（`dash-issue-session.sh`） |
| `FLEET_AUTOFILL_NODE` 自动补位开在哪台 | — | — | 有 | — | — |
| `FLEET_SIDEBAR_SOURCE` 列表从哪来 | — | — | `local` / `hub` | — | — |
| `FLEET_NODE_ALIASES` 机器标签 | 每台一份 | 有（全局） | — | — | — |
| `FLEET_ACCOUNTS` 订阅账号 | — | 有（全局） | — | — | 下一刀：`--account local\|pool\|any`（#1540） |
| 入口地址 `CCQUOTA_HUB_URL` | — | 有（全局；没有就 `hub.json`） | — | — | — |
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
| **临时会话** | 开在这台机器 | 今天仍只开在这台（下一刀 #1541：`dash-raw-session.sh --node`） | `dash-raw-session.sh` |
| **订阅** | 这个登录 `accounts/` 里的账号 | 同左，另加入口池里的 `hub:<label>` 账号（入口发短期凭据）；按会话选「只用本地 / 只用池 / 都行」是下一刀 #1540 | `fleet-account.sh` |
| **列表来源** | 这台机器的 tmux 窗口 | `FLEET_SIDEBAR_SOURCE=local`：本机窗口 + 入口缓存里你在别的机器上的会话；`=hub`：整张表来自入口的 `fleet_sessions`，状态条换成机器 / 额度 / 入口的版式 | `tmux-dashboard-rows.sh`、`tmux-status.sh`（读 `$FLEET_C` 缓存，渲染路径不联网） |
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
- `bin/tmux-config-selftest.sh` 核对 global-only 名单与 `fleet.conf.example` 的
  `@scope=global` 标签同步。
