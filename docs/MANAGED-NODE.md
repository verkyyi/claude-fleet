# 托管机器：身份、信任与期望状态

EPIC #2329 共同约定 1：**机器的期望状态在入口。** 入口为每台托管机器存一份
「应有的样子」；机器上的守护每个周期把实际状态收敛到它，`fleet doctor` 的机器部分
就是两者的差。这份文档是那份「应有的样子」的约定——C2（#2214）建了它，C3–C6 读它。
加一个字段，先改这里。

## 1. 机器的身份 = 入口发的令牌，不是机器名

一台机器在入口的身份是它加入时换到的**节点令牌**（一个 endpoint，`ep_…`）。
机器名（hostname）是 agent 自己报的，谁都能报成别的——所以**信任记在身份上**。

| 从哪来 | `trust_source` | 说明 |
|---|---|---|
| 托管加入码 | `join_code` | 操作者在入口「机器」页点「添加机器」生成；码里写明可信 + 角色 `managed`，一次性、1 小时 |
| 操作者 | `operator` | `PUT /v1/fleet/nodes/<ep>/desired` 带 `trust` |
| 机器名（旧规则） | `machine_name` | `fleet.node_trust.<机器>`，只对**用这个名字加入**的 endpoint 生效；`# compat-1v`，一个发布版后删 |
| 冒用的机器名 | `name_borrowed` | 报的名字是可信机器，但它不是用这个名字加入的 → 不可信、审计一行 |

判定顺序（`internal/api/fleet_trust.go` `nodeTrust`，唯一一处）：

1. 操作者把它报的机器名标了 `untrusted` → 不可信（操作者的话只会收回信任）；
2. endpoint 自己的信任（加入码 / 操作者）→ 照它，不管报什么名字；
3. 旧规则：名字可信 **且** 与 `endpoints.enrolled_host`（加入时的名字，没给就是第一次上报的名字；加入时没报名字记 `?`）同一台 → 可信；
4. 其余不可信。

## 2. 加入码

```
POST /v1/fleet/nodes/join-codes      （操作者）
  {"label": "m4"?, "trusted": true?, "role": "managed"?, "kind": "fixed"?}
→ {"code": "fj_…", "expires_at": …, "command": "…", "trust": "trusted", "role": "managed"}
```

- 缺省：`trusted: true`、`role: managed`、1 小时；`trusted: false` 发不带信任的码。
- 旧路由 `POST /v1/fleet/join-codes` 照旧：不带信任、10 分钟。
- 码只存哈希；兑换（`POST /v1/node/join`）与登记 endpoint 在一个事务里，一次、过期即拒。
- 加入码不进任何 issue、评论、提交、日志（共同约定 8）。
- `command` 目前是 `fleet-node-join.sh` 那一行；C1（#2330）的 `sudo fleet node install --join <码>` 上线后换成它。

## 3. 期望状态

```
GET /v1/fleet/nodes/<ep>/desired     （操作者）
PUT /v1/fleet/nodes/<ep>/desired     （操作者；只有操作者能写）
GET /v1/node/desired                 （机器自己，节点令牌）
```

GET 的回答：

```json
{
  "endpoint_id": "ep_…",
  "version": 3,
  "release": "4ffae0a5…",
  "components": {"ccquota": "prod-02e8161b", "claude": "2.1.3", "codex": "0.10.0", "runtime": "4ffae0a5"},
  "accounts": ["verkyyi", "24haowan"],
  "spare_accounts": 2,
  "trust": "trusted",
  "trust_source": "join_code",
  "role": "managed",
  "updated_at": "2026-10-08T03:00:00Z",
  "updated_by": "…"
}
```

| 字段 | 含义 | 约束 |
|---|---|---|
| `version` | 入口每写一次 +1；0 = 从没写过 | 入口给，不可写 |
| `release` | 这台跑的发布版（stable 标签所在提交） | 标签或提交，≤ 80 |
| `components` | 各部件钉住的版本：`ccquota` `claude` `codex` `runtime` … | ≤ 32 项，名字小写，版本 `[A-Za-z0-9.+_-]` |
| `accounts` | 这台应有的系统账号 | ≤ 64，系统登录名 |
| `spare_accounts` | 备好的空账号数 | 0–32 |
| `trust` / `trust_source` / `role` | 身份上的信任与角色（§1） | PUT 里可带 `trust`：`trusted` / `untrusted` / `""`（回到机器名规则） |

PUT 的请求体就是上面可写的字段，外加可选的 `if_version`（读到的版本；对不上 `409 version_conflict`，什么都不写）。
未知字段 `400`——凭据不会有地方落脚。每次写审计一行（`node_desired`），改信任另记一行（`node_trust`，`endpoint:<ep>`）。

## 4. 机器报「收敛到哪了」

心跳（`control.Heartbeat`）带：

```json
"desired": {"version": 3, "release": "4ffae0a5…", "diff": "codex 0.9.0 → 0.10.0"}
```

- `version`：上次收敛完成时读到的期望版本；
- `release`：实际在跑的发布版；
- `diff`：还差什么，一行；空 = 已一致。

不管理任何东西的旧 agent 不带这个字段，入口的名册也就不显示期望 / 实际两栏——一字不差。
名册每个节点多出 `trust_source`、`role`、`desired {want, reached, want_release, release, diff}`；
入口「机器」页的卡片显示「可信 · 来自加入码」和期望 / 实际两栏。

## 5. 一个版本内新旧并存

- 旧节点没有身份信任：照旧按机器名，但只认它加入时的名字（`machine_name`）。
- 迁移时 `enrolled_host` 用每个 endpoint 当时报的名字补齐，所以 m4 / m5 现有的登录一个都不掉。
- 下一批删旧规则（`# compat-1v: 下一批删`）：那时每台机器都已凭托管加入码重新加入（C1 / C8）。

## 6. 一个节点程序服务整台机器（C5，#2333）

托管机器只跑**一个** `ccquota agent --machine`：root 运行，由守护（C3）的 `node-agent`
子进程拉起，取代每个账号一份的 `com.ccquota.agent.<login>`。

| 文件 | 内容 | 谁写 |
|---|---|---|
| `/var/db/fleet-node/machine.env` | `CCQUOTA_HUB_URL`、`CCQUOTA_TOKEN`（**机器自己**的节点令牌，§1） | 安装 / 迁移（C1 / C4），root 600 |
| `/var/db/fleet-node/logins/<账号>.env` | 这个账号原来那份 agent 的设置（`CCQUOTA_*`、`FLEET_CONF_DIR`），`CCQUOTA_TOKEN` = **这个账号**的节点令牌 | 迁移，逐个账号，root 600；别人能读写就拒 |
| `/var/db/fleet-node/agent/<账号>/` | 每个账号的游标、待发队列 | 节点程序自己 |

两个文件都在之前，守护显示 `node-agent waiting — … missing`，不启动。

**连接**：节点程序用机器令牌连一条线（hello 能力位 `machine`），每个账号在这条线上
各说一次 hello，带自己的令牌（`login_token`）；之后这个账号的每条消息都带 `login`。
入口把每个账号仍当一个 endpoint（名册行、租约、中继、开号都不变），只是线共用。

**错账号一律拒**（BREAK-IT `machine-agent-wrong-login`）：入口只认令牌所属的登录名
（`os_user`；从没上报过的照 hello 记）、同一台机器、不是机器自己的令牌
（`internal/api/node_machine.go` `loginEndpoint`，唯一一处），否则答 `WRONG_LOGIN`、
那个账号不上线、审计记 `machine_login REFUSED`；发给这条线上没有的账号的消息两端都答
`WRONG_LOGIN`，不交给任何账号。

**以账号身份跑**：每个账号是进程里一个租户；它启动的每条命令（`fleet-control.py`、
开号脚本、中继、git、tailscale）降权到这个账号——uid / gid / 附属组、`HOME` / `USER` /
`LOGNAME`、工作目录是它的家（`internal/agent/runas.go` `prepCmd`）；root 的机器程序遇到
没带账号的命令**拒跑**，不以 root 跑。写进账号家目录的文件（中继、迁入的会话包、凭据
标记）交还这个账号；订阅凭据只交给共享凭据代理（以 `as=<账号>` 说明是谁的），没有代理
就不领——root 不往账号目录写凭据。

**名册**：机器自己那条线标 `machine_link`（永不放会话），它带着的账号标 `via`；
`machines[].links` 是这台机器开着的连接数。入口「机器」页每台卡片一行「1 条连接 · 账号：…」，
`fleet hub machines` 多一列「连接」。

**旧节点**：没迁的账号照旧自己连（`links` 多算一条）；某个账号已经由整机连接带着时，
它残留的旧 agent 被拒（`REFUSED`），不来回抢。旧入口不认识能力位：把机器 hello 当一个
普通节点、账号 hello 当未知消息——整机节点程序退不回去，迁移前先升级入口。

## 7. 整机一个更新器（C6，#2334）

你移一次 stable，每台托管机器上的**所有部件**换到这一版；新版体检不过就整体退回上一版。
更新器是 `bin/fleet-node-update.py`，守护（C3）的 `update` 任务（每 5 分钟一次，`FLEET_NODE_UPDATE_EVERY`），
root 运行；它取代托管账号各自的 `fleet-install-sync.sh`（那个账号的 install-sync 记 `off · managed`）。
非托管机器照旧走 install-sync，一字不差。

### `release.json`（仓库根，随发布包一起签名）

```json
{
  "schema": 1,
  "components": {
    "ccquota":    {"artifact": "ccquota-{os}-{arch}"},
    "claude":     {"version": "2.1.293", "artifact": "claude-{version}-{os}-{arch}"},
    "codex":      {"version": "0.154.0", "artifact": "codex-{version}-{os}-{arch}"},
    "tmux":       {"version": "3.7c",    "artifact": "tmux-{version}-{os}-{arch}", "lock": "conf/vendor-tmux.lock"},
    "supervisor": {"script": "bin/fleet-node-supervisor.py"}
  }
}
```

| 部件 | 版本从哪来 | 装到哪 |
|---|---|---|
| 脚本（运行时） | 发布版提交本身（签名清单的 `sha`） | `<root>/<sha>/`（`<root>` = `/Library/Application Support/claude-fleet`） |
| `ccquota` | 发布包里的 `ccquota-<os>-<arch>`（入口 dist 构建，sha256 在签名清单里） | `<root>/<sha>/bin/ccquota`——节点程序（C5）从 `current` 跑它 |
| Claude Code / Codex / tmux | `version` 钉住；可执行文件本身是发布包的 artifact（`{version}` `{os}` `{arch}` 展开，`{arch}` 是 `arm64` / `amd64`） | root 缓存 `<root>/tools/<名>/<sha256>/<名>`，发布目录里 `tools/bin/<名>` 链过去 |
| 开号缓存 | 同 `claude.version` | `<root>/cache/claude/<ver>/claude` + `current`（`fleet-bootstrap-cache.sh claude` 从这里装新账号） |
| 账号 | — | 每个托管账号的 `~/.local/bin/{claude,codex}`、`~/.local/share/claude-fleet-vendor/bin/tmux` 链到 `<root>/current/tools/bin/<名>`；由降权到该账号的进程建，每轮重建（Claude Code 自己更新换掉了链接就换回来），**从不覆盖账号自己的普通文件** |
| 守护自身 | 发布版提交 | 它就在 `current` 里：切换后最后一步写 `<state>/update-restart.json`，守护停掉子进程退出，launchd 用新版拉起 |

- `os` / `arch` 只是 artifact 名字的展开；校验和永远是**入口签名清单**里的那个，`release.json` 不写校验和。
- 升一个部件 = 改这里的版本 + 把同名 artifact 放进入口的 `CCQUOTA_FLEET_RELEASE_ARTIFACTS`，再移 stable。
  发布包里缺 artifact → 这一版**不换**（`failed`，1 小时后重试），不会只换一半。
- `fleet-stable.sh move` 拒绝一个带 `bin/fleet-node-update.py` 却没有合法 `release.json` 的目标（`release:`，`--force` 记一行）；
  校验只有一处：`fleet-node-update.py check-release`。

### 一轮怎么走

`<state>/update.json` 记阶段，被杀后下一轮照记录做完（BREAK-IT `node-update-half`）：

1. **目标**：`expected.json` 的 `release`（§3 期望状态），否则入口 `/version` 的 `stable`。
2. **推迟**：任何托管账号有「有活」的 EPIC 批次在跑（#2247 的 `fleet_epic_holding`）→ `deferred`，最长 2 小时（`FLEET_EPIC_HOLD_CAP_SECS`）。
3. **取包**：`ccquota release fetch --artifacts`（C7，只问入口、验钉住的公钥 `<state>/release.pub`）→ 装 ccquota 和各工具 → 写 `.release/staged.json`。没有这个标记的目录 = 没装完，删掉重取。
4. **切换**：记下当前（旧版）的机器体检 FAIL 作基线 → `.prev` = 旧版、`current` = 新版（各一次 rename）→ 开号缓存、账号链接 → 请守护重启。
5. **验证**（下一轮，新代码，`FLEET_NODE_UPDATE_SETTLE` 30 秒后）：机器体检（`fleet doctor --machine`）比基线多出 FAIL
   → `current` 切回 `.prev`，缓存、链接一起回，这一版记 `skip`（stable 再动之前不重试），再请守护重启；否则 `committed`。
6. 退下来的版本留 7 天（`FLEET_NODE_UPDATE_KEEP_SECS`），`current` / `.prev` 永不删；没有发布版再引用的工具缓存一起清。

### 机器体检

`fleet doctor --machine`（= `fleet-node-update.py doctor`）一行一个部件：`runtime` `ccquota` `claude` `codex` `tmux`
（各自 `--version` 必须含 `release.json` 的版本，否则 FAIL）、`daemon`（守护在跑且跑的是 `current` 那一版，否则 FAIL）、
每个子进程、`cache`、每个托管账号的链接（WARN），最后一行 `version … — 各部件 = 发布版声明`。
退出码 = FAIL 数。普通 `fleet doctor` 多一行 `update`（最后一轮的结果；失败 / 回退 / 跳过时 WARN）。

### 新旧并存

- 没有 `update.json` 的机器：体检没有 `update` 行，`--machine` 只说「不是托管机器」。
- 旧守护没有 `update` 任务、不认 `update-restart.json`：新守护第一次由 C1 / C8 装上后才开始自己更新。
- 开号缓存的 git 镜像一半（`claude-fleet.git`）仍由开号时的 `refresh --from` 填；托管账号的 `~/.claude/fleet` 指向 root 运行时，不靠它。
