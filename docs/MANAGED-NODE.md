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
- 托管码的 `command` 是 `curl -fsSL <入口>/install/bin/fleet-node-install.sh | sudo bash -s -- --hub <入口> --join <码>`（§8，入口自己的客户端包里那份，不连 GitHub）；不带角色的旧码仍是 `fleet-node-join.sh` 那一行。

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
| `/var/db/fleet-node/logins/<账号>.env` | 这个账号原来那份 agent 的设置（`CCQUOTA_*`、`FLEET_CONF_DIR`），`CCQUOTA_TOKEN` = **这个账号**的节点令牌 | `account adopt <账号>` 写（#2387）：键取自旧 `com.ccquota.agent.<账号>` plist 的 `CCQUOTA_*` / `FLEET_CONF_DIR` + 这个账号 node.env 的 `CCQUOTA_*`（凭据隔离的从 credsep 存储读，带 `CCQUOTA_FLEET_CRED_STORE`），旧 agent 一起进 attic；`account release` 删它、放回旧 agent。root 600；别人能读写就拒；`logins/` 一变，守护重启节点程序 |
| `/var/db/fleet-node/agent/<账号>/` | 每个账号的游标、待发队列 | 节点程序自己 |

`machine.env` 在、`logins/` 里至少有一个 `<账号>.env` 之前，守护显示 `node-agent waiting — … missing`，不启动（空的 `logins/` 不算，#2421）；最后一个账号 release 掉，它停下回到 waiting。

**连接**：节点程序用机器令牌连一条线（hello 能力位 `machine`），每个账号在这条线上
各说一次 hello，带自己的令牌（`login_token`）；之后这个账号的每条消息都带 `login`。
入口把每个账号仍当一个 endpoint（名册行、租约、中继、开号都不变），只是线共用。

**错账号一律拒**（BREAK-IT `machine-agent-wrong-login`）：入口只认令牌所属的登录名
（`os_user`；从没上报过的照 hello 记）、同一台机器、不是机器自己的令牌
（`internal/api/node_machine.go` `loginEndpoint`，唯一一处），否则答 `WRONG_LOGIN`、
那个账号不上线、审计记 `machine_login REFUSED`；发给这条线上没有的账号的消息两端都答
`WRONG_LOGIN`，不交给任何账号。

**账号重登记不切断机器的线**（#2501，BREAK-IT `machine-lane-reissued`）：令牌在机器守护手里的账号，
在入口上就只有这一份。这个账号正由机器连接服务时，设备重登记（旧版 `fleet host on` /
`fleet login` 的 node-pass）**不换发**，答 409 `machine_managed`；别处换发了的，旧令牌再认
10 分钟（`ReissueTokenGrace`）。过了宽限还拿旧令牌来的 hello，`WRONG_LOGIN` 写明「这个登录在
… 重登记过」和修法。被拒的账号：节点写 `<state>/agent/<账号>/lane.json`、机器心跳带
`logins_refused`（Machines 卡片红字「令牌失效 · 需要 relogin」），守护 `status` 一行
`lane <账号> 令牌失效`、`status --check` 退 3、doctor `node` 行 WARN。修：
`sudo fleet-node-supervisor.py account adopt <账号> --rejoin`——以这个账号的设备密钥
（`fleet-login.py node-pass`，降权到它）向入口要新通行证，写进凭据库与 `logins/<账号>.env`，
节点程序重读后上线；不要管理员的浏览器会话（设备没登记过就先以这个账号 `fleet login` 一次）。

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
    "claude":     {"version": "2.1.295", "artifact": "claude-{version}-{os}-{arch}"},
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
| 共享凭据代理 | 发布版提交的 `bin/fleet-cred-proxy.py` / `fleet-credsep-launch.py` | root 代码副本 `<root>/credsep/`：更新器每次切换、回退、验证前和每一轮跑 `<current>/bin/fleet-credsep.py machine refresh`，字节变了代理就重启——launchd 管的（旧 `com.claude-fleet.cred-proxy-shared` 还在）由 refresh bootout / bootstrap，守护管的子进程由守护按 `reload`（`credsep/` 一变）重启，refresh 不另写 plist（#2435） |
| 守护自身 | 发布版提交 | 它就在 `current` 里：切换后最后一步写 `<state>/update-restart.json`，守护停掉子进程退出，launchd 用新版拉起 |

- `os` / `arch` 只是 artifact 名字的展开；校验和永远是**入口签名清单**里的那个，`release.json` 不写校验和。
- 升一个部件 = 改这里的版本 + 把同名 artifact 放进入口的 `CCQUOTA_FLEET_RELEASE_ARTIFACTS`，再移 stable。
  发布包里缺 artifact → 这一版**不换**（`failed`，1 小时后重试），不会只换一半。
  两道拦截（#2631）：`fleet-stable.sh move` 先问入口 `GET /v1/fleet/release/artifacts`，目标 `release.json`
  钉的制品（`fleet-node-update.py pinned-artifacts`，按入口说的平台展开，默认 `darwin-arm64`）缺一个就拒挪
  （`artifacts:`，点名缺哪个；`--force` 记一行）；入口自己也不打包缺钉住制品的发布版（构建报错、不落盘），
  制品放进去后下一次请求就建出完整的一版。
- **Claude Code 不用人传**（#2631）：升 `components.claude.version` 即可。入口建包时缺 `claude-<ver>-<os>-<arch>`
  就自己取 Anthropic 发到 npm 的 `@anthropic-ai/claude-code-<os>-<arch>@<ver>`（与 downloads.claude.ai 同一份字节；
  入口所在集群连不上那边的 Google 存储），按 registry 的 `dist.integrity`（sha512）校验，取出 `package/claude`
  放进制品目录，再和别的制品一起签进清单。registry 依次试 `CCQUOTA_FLEET_RELEASE_NPM`（默认 npm → npmmirror）。
  门里这种名字算「入口自取」（`/v1/fleet/release/artifacts?want=` 的 `fetchable`）。Codex / tmux 仍要人放。
  已经建好、却缺钉住制品的发布包（入口当时取不到 / 旧入口建的）不是死的：下一次有机器取它的清单，入口发现
  `release.json` 钉的缺了、而且现在补得上，就补取并重建、重签（每版至多 10 分钟试一次；重建失败照旧发老的），
  所以不必为它再移一次 stable。清单因此不再标 immutable。
- `fleet-stable.sh move` 拒绝一个带 `bin/fleet-node-update.py` 却没有合法 `release.json` 的目标（`release:`，`--force` 记一行）；
  校验只有一处：`fleet-node-update.py check-release`。

### 一轮怎么走

`<state>/update.json` 记阶段，被杀后下一轮照记录做完（BREAK-IT `node-update-half`）：

1. **目标**：`expected.json` 的 `release`（§3 期望状态），否则入口 `/version` 的 `stable`。
2. **推迟**：任何托管账号有「有活」的 EPIC 批次在跑（#2247 的 `fleet_epic_holding`）→ `deferred`，最长 2 小时（`FLEET_EPIC_HOLD_CAP_SECS`）。
3. **取包**：`ccquota release fetch --artifacts`（C7，只问入口、验钉住的公钥 `<state>/release.pub`）→ 装 ccquota 和各工具 → 写 `.release/staged.json`。没有这个标记的目录 = 没装完，删掉重取。取包可续传（#2701）：只取 `release.json` 为本机平台钉住的制品（`--pinned`），每个落 `<root>/.fetch/<sha256>.part`、断了用 Range 接着取，只有 30 秒没有一个字节才算断、没有整包 deadline；取之前把工具缓存和当前 / 上一版的制品按 sha256 硬链进去，同字节的不再下；有进展的失败不退避，下一轮接着取。进度写 `<state>/fetch.progress`（`status` 打最后一行，`fleet node install` 边取边打印）。不认这些参数的旧 ccquota 照旧整包取。
4. **切换**：每个托管账号（降权、它自己的 HOME / TMPDIR）先跑新版的 `fleet-sessions-snapshot.sh save`，把没做完的会话钉进它的 `global/sessions.snapshot`（#2484）→ 记下当前（旧版）的机器体检 FAIL 作基线 → `.prev` = 旧版、`current` = 新版（各一次 rename）→ 开号缓存、账号链接、共享凭据代理的代码副本（`machine refresh`）→ 请守护重启。
5. **验证**（下一轮，新代码，`FLEET_NODE_UPDATE_SETTLE` 30 秒后）：机器体检（`fleet doctor --machine`）比基线多出 FAIL
   （判之前先 `machine refresh` 一次：由不认识 credsep 的旧更新器换上来的版本，副本还是旧的）
   → `current` 切回 `.prev`，缓存、链接、代理副本一起回，这一版记 `skip`（stable 再动之前不重试），再请守护重启；否则 `committed`。提交或回退之后每个托管账号跑那一版的 `fleet-sessions-snapshot.sh restore`：钉住的会话按原名、原目录、原对话经 `fleet-restore.sh` 开回（已关单 / 已删目录 / fleet-down 的不开），回来几个、缺哪个记进 `update.log`（BREAK-IT `node-update-sessions`；`FLEET_NODE_UPDATE_SESSIONS=0` 关）。
6. 退下来的版本留 7 天（`FLEET_NODE_UPDATE_KEEP_SECS`），`current` / `.prev` 永不删；没有发布版再引用的工具缓存一起清。

### 机器体检

`fleet doctor --machine`（= `fleet-node-update.py doctor`）一行一个部件：`runtime` `ccquota` `claude` `codex` `tmux`
（各自 `--version` 必须含 `release.json` 的版本，否则 FAIL）、`daemon`（守护在跑且跑的是 `current` 那一版，否则 FAIL）、
每个子进程、`cache`、`credsep`（机器有共享凭据代理时：副本 ≠ 发布版 FAIL；代理的 `version` ≠ 副本、等 `FLEET_NODE_CREDSEP_WAIT` 15 秒后仍是 FAIL；读不到 WARN）、每个托管账号的链接（WARN）与它的 `~/.claude/fleet` 版本（`install`，落后 WARN — #2688），最后一行 `version … — 各部件 = 发布版声明`。
退出码 = FAIL 数。普通 `fleet doctor` 多一行 `update`（最后一轮的结果；失败 / 回退 / 跳过时 WARN）。

### 新旧并存

- 没有 `update.json` 的机器：体检没有 `update` 行，`--machine` 只说「不是托管机器」。
- 旧守护没有 `update` 任务、不认 `update-restart.json`：新守护第一次由 C1 / C8 装上后才开始自己更新。
- 开号缓存的 git 镜像一半（`claude-fleet.git`）仍由开号时的 `refresh --from` 填。
- 托管账号自己的 `~/.claude/fleet`（守护替它跑的每个账号任务都是 `__HOME__/.claude/fleet/bin/…`）**不是**更新器搬的：它的 install-sync 跟的是**本机的发布版**——`<root>/current` 指向的那个 sha——而不是 `stable` 标签，同一次链接切换（#2688；以前这一拍答 `off · managed`，登录就停在开号时那一份上）。`<root>/current` 还没有时才是 `off`。`fleet doctor --machine` 每个托管账号一行 `install`：在发布版 PASS，落后或读不出 WARN（不算 FAIL，不触发整机回退），并给出当场跟上的命令 `sudo -u <login> bash <root>/current/bin/fleet-install-sync.sh --root ~<login>/.claude/fleet`。

## 8. 一条命令装成托管机器（C1，#2330）

```
sudo fleet node install --join <码> [--hub <入口>]
curl -fsSL <入口>/install/bin/fleet-node-install.sh | sudo bash -s -- --hub <入口> --join <码>   # 干净的 Mac
```

入口「机器」页点「添加机器」给出第二行，复制到新机器运行——这就是加一台机器要人做的全部（浏览器里点一次 + 这一条）。
`bin/fleet-node-install.sh` 按顺序收敛下面每一步：**先查后做**，已满足就「跳过」，缺的才做；
一步失败就停在那一步，打印原因和重跑命令（加入码不打印），这一步替换过的东西放回、不留半成品。
同一条命令再跑一遍 = 把缺的补上、坏的修好；退出码 0 = 已收敛。

| 步 | 做什么 | 已满足 = |
|---|---|---|
| 检查 | root、macOS、`/usr/bin/python3`（Xcode 命令行工具）、curl | — |
| 加入 | 加入码换**机器自己**的节点令牌（§1；`os_user` 报 `root`）→ `<state>/machine.env`（root 600：`CCQUOTA_HUB_URL`、`CCQUOTA_TOKEN`，其余行保留） | 令牌入口仍认（`/v1/node/self` 200）——不再花码 |
| 发布公钥 | `GET /v1/fleet/release/key` → `<state>/release.pub`，钉一次（`--release-key <文件>` 钉指定的） | 已钉住 |
| 期望状态 | `GET /v1/node/desired` → `<state>/expected.json`（§3 的首份）；`accounts` 为空就不写（写了会让守护暂停每个账号） | 与入口一字不差 |
| ccquota | 入口 `/v1/node/dist/darwin-<arch>`，SHA-256 核对 → `<state>/bin/ccquota`，只用来取第一个发布版 | `current/bin/ccquota` 或它已在 |
| 运行时 | 更新器（§7）跑一轮：`<root>/<sha>` + `current` + 各钉住的工具；目标 = `--target`、`expected.json` 的 `release`、入口 stable；用 curl 管道跑时更新器取自签名发布版本身 | `current` 是装齐的发布版（`staged.json`） |
| 角色用户 | `_fleetcred`（`fleet-credsep.py role`，与凭据隔离同一份代码） | 账号已在 |
| ssh CA | `GET /v1/fleet/ssh-ca.pub` → `/etc/ssh/fleet_user_ca.pub` + `sshd_config.d/100-fleet-user-ca.conf`，与 admin agent 写的一字不差；`sshd -t` 不过或 `sshd -T` 不认就放回原样 | 两个文件已是这样；入口不签证书则跳过 |
| 守护 | `<state>/logins`（700），`fleet-node-supervisor.py install`（从 `current` 跑，§C3） | `install --check`：服务定义一致且 launchd 已载入 |

装完之后机器由守护管：更新器跟发布版走，节点程序等 `logins/<账号>.env`（`account adopt <账号>` 逐个账号写，#2387），
账号用 `sudo <root>/current/bin/fleet-node-supervisor.py account adopt <账号>` 交给守护。
托管机器上 `fleet host on` / `fleet node join` 先提示改用这条命令（一个版本内照旧可用）。
沙箱自测 `bin/fleet-node-install-selftest.sh`；BREAK-IT `node-install-half`。

## 9. 真机演练（C8，#2336）

```
sudo bin/fleet-node-drill.sh run --to <升级到的 sha> --fail <故意失败的 sha> [--join-file <f>] [--logins a,b]
bin/fleet-node-drill.sh count        # 五个指标此刻的读数（不用 root）
sudo bin/fleet-node-drill.sh unblock # 演练被杀后留在 /etc/hosts 的 GitHub 挡板
```

在**被演练的那台**上跑（先 m4，共同约定 6）。每一步动真机前先问（y 做 · n 跳过记 SKIP · q 停）：
基线 → 加入码（人）→ 安装（人，§8 那一条）→ 逐个账号 `account adopt`（发起人自己的账号最后迁；失败即停并打印 `account release`）
→ 升级（人移 stable 到 `--to`，等更新器 `committed`）→ 回退（人移到 `--fail`：master 上一个只加 `conf/drill-fail` 的提交——带这个标记的发布版 doctor 多一行 FAIL（`fleet-node-update.py` `DRILL_FAIL`）——等 `rolled-back` 回到 `--to`；看完 stable **往前**移到删掉标记的下一提交。不用演练分支：install-sync 从不往回移，停在主干外的提交上的非托管账号就再也跟不上 stable）
→ 复查（`doctor --machine` + 五个指标）→ 断 GitHub（这一步内 `/etc/hosts` 挡住 github.com 等，重装应全部跳过、只从入口取到当前发布版；挡板总会撤掉，下次启动也先撤）
→ 回话（人确认会话能回话、入口能往这台派会话）。

每步计时、标「人 / 自动」，最后两张表——步骤表和五个指标的演练前 / 后 / 目标——打印并存到
`<state>/drill/<UTC>/report.md`，报告页直接用。加入码只从 `--join-file`（读后删除）或不回显的提示读，不打印、不落盘。
指标口径（`count`）：服务 = `/Library/LaunchDaemons` + 每个账号 `~/Library/LaunchAgents` 里有效的 `com.claude-fleet.*` / `com.ccquota.*`
（`.bak` / `.retired` 等残留不算）；种类 = 各账号服务组合去重（托管账号算「守护代跑」一种）；GitHub = 未托管且有 install-sync 的账号数；
部件 = `doctor --machine` 里 runtime / ccquota / claude / codex / tmux / cache 不是 PASS 的个数。沙箱自测 `bin/fleet-node-drill-selftest.sh`。

演练记录与五个指标的读数：#2336（m4，2026-10-08）。
演练里的「升级」用一个只改这份文档的提交；「回退」用一个只加 `conf/drill-fail` 的提交，再用一个删掉它的提交往前走。
演练前先在被演练的机器上 `count` 一次；中途新开的登录不在 `--logins` 里就不会被迁。

## 10. 后台服务登记表（EPIC #2524 C1，#2525）

以某个登录身份在托管机器上常驻的程序（短信通知这类），不再手写 LaunchDaemon / LaunchAgent，而是登记给整机守护：

    fleet service add sms-watch --cred BARK_KEY -- ~/bin/sms-watch.py   # 登记（或替换）
    fleet service cred set BARK_KEY                                     # 值从标准输入读，永不进参数
    fleet service ls / logs sms-watch [-f] / stop / start / restart / rm sms-watch

- **一个条目一个 JSON**：`/var/db/fleet-node/logins/<登录>/services/<名>.json`（root 0600）——
  `{name, login, kind: "service", exec, schedule, retries, env, env_keys, creds, paths, state}`（共同约定 2；
  `schedule` / `retries` 是 `kind: task` 的，见 §11）。条目里只有凭据的**名字**；值在
  `/var/db/fleet-node/logins/<登录>/creds/<名>`（root 0600），守护起进程时注入成同名环境变量。
- **写表是 root 的**：`fleet-service.sh` 经 `sudo -n` 跑 root 运行时里的 `fleet-node-supervisor.py service …`；
  没有免密 sudo 时打印一条给管理员跑的命令（exit 3）。`ls` / `logs` 不用 root。
- **守护代跑**：每个 `state: enabled` 的条目是守护的一个子进程，降权成那个登录（initgroups/setgid/setuid，
  它的 HOME / USER / TMPDIR，和账号半边同一条路），退出即按子进程退避重起（1 秒起翻倍，封顶 60 秒）。
  stdout + stderr 由降权后的进程自己续写 `/var/log/fleet-node/logins/<登录>/<名>.log`（目录归该登录，1 MB 轮转一次）。
  改条目（stop / start / restart 都是改写它）= 重起；删条目 = 停。条目不是 root 所有、或登录名与目录不符，
  守护只报 `INVALID`，不跑。
- **看得到**：`fleet-node-supervisor.py status` 每项一行；`status --json` 顶层 `services[]`
  （状态、pid、重启次数、上次退出码、日志末行 ≤ 200 字节；`state.json` 0644 里的同一份不带日志末行）。
- 一个登录的 `services/` 不是节点程序的租户：节点程序只在 `logins/*.env` 变时重起。
- BREAK-IT 行 `service-killed`；`fleet-node-supervisor-selftest.py` I。
- **跟人走**（C4，#2528）：`fleet service move <名> --to <登录>`（root：`fleet-node-supervisor.py service move
  --login <旧> --name <名> --to <新>`）整项搬到另一个登录——守护先停掉旧的（两份永不同时跑），条目的 `paths[]`
  （`--path`：工作目录、技能目录）从旧家目录搬到新家目录的同一位置并改归属（家目录外的路径是共用的，原地不动、
  输出里说明），日志和凭据跟到新登录下（旧登录没有别的条目再用的凭据一并删掉），exec / env 里指向旧家目录的
  字符串改指新家目录，按原状态（enabled / stopped）登记到新登录，最后才删旧条目。所有检查（新登录已有同名条目、
  目标路径已存在、同名凭据值不同）先于第一处改动；中途失败把已搬的原样放回。
- **退役前必须搬完**：`fleet-login-remove.sh <登录>` 在第 1 步之前（dry run 也一样）、`account release <登录>`
  在动手之前查该登录的登记表，还有条目就拒绝、**退 6**，逐项打印 `service move` 命令；`account release --force`
  照样释放（条目仍由守护以该登录身份跑）。BREAK-IT 行 `service-login-moved`；`fleet-node-supervisor-selftest.py` J。
- **命令行、体检、入口都看得到**（C2，#2526）：机器链路（`ccquota agent --machine`）每拍读守护的 `state.json`，
  心跳带 `services[]`（`name, kind, login, state, started_at, last_run, next_run, last_log_line`，日志末行只读该登录
  自己的、非链接的文件，≤ 200 字节）；入口把它挂在 `/v1/nodes` 的机器行上（`services` / `services_at`），**按
  (机器, 登录) 裁给本人**；`state` 为 `down · failed · invalid · no_login` 的记 `service_failed` 告警（主题
  `<机器>/<登录>/<名>`，恢复或删掉即清），`/v1/fleet/summary` 带 `alerts`。登录自己的心跳带的 `services` 入口不收。
  客户端的刷新循环把它存成 `global/hub_services`，读它的只有一个 `bin/fleet-services.py`：
  `fleet ls --services [--json]`（机器 · 登录 · 名称 · 类型 · 状态 · 上次 · 下次 · 最近日志，失败的标红）、
  体检 `services` 行（失败 FAIL，全在跑 PASS，无登记 INFO）、告警栏一条 ✖ `service · failed`（`FLEET_ALERTS_SERVICES=0` 关）。
  入口没提到的本机，直接读本机守护的 `state.json`（只列自己的登录）。BREAK-IT 行 `service-failed-unseen`；
  `fleet-services-selftest.sh`。

## 11. 定时 agent 任务（EPIC #2524 C5，#2529）

「每天几点、以谁的身份、开一个会话跑哪条提示」是同一张登记表的第二种条目（`kind: "task"`），不再各写一个 run.sh：

    fleet task add daily-report --at 07:00 --tz Asia/Shanghai --prompt '/daily-report' \
        --window 'daily-{date}' --done-file '~/daily-report/out/{date}.md' [--retries 2] [--bark BARK_KEY]
    fleet task ls                       # 状态 · 计划 · 上次 · 下次
    fleet task run daily-report --now   # 现在跑一次（不占计划）
    fleet task logs daily-report [-f] / stop / start / rm daily-report

- **条目**：`/var/db/fleet-node/logins/<登录>/services/<名>.json`（root 0600），没有 `exec`，多了
  `prompt` · `schedule`（`{at: "HH:MM", tz}` 或 `{cron: "分 时 日 月 周", tz}`；无 tz = 本机时区）·
  `retries`（默认 2 次重试）· `retry_delay`（300 秒）· `window`（会话名，`{date}` = 这一档的日子；默认 `<名>-{date}`）·
  `done_when.file`（可选）· `timeout`（3600 秒）· `idle`（600 秒）· `fleet`（默认该登录唯一的 fleet）· `notify.bark`（可选，凭据名）。
- **到点**：守护每轮算出最近一档（`at` / `cron` 按时区）；比条目登记得晚、比上一档新、且没晚过 6 小时
  （`FLEET_NODE_TASK_CATCHUP`，重启后补跑）就开跑。一次尝试 = 降权成该登录跑 `bin/fleet-task-run.sh`：
  该登录的 `~/.claude/fleet/bin/dash-raw-session.sh --no-repo --origin hub --print --name <窗口> --prompt <提示> <fleet>`；
  同名窗口已开（守护重启丢了这次）就认领它，不开第二个。有 `done_when.file` 时等会话结束且文件在：
  会话不在干活超过 `idle`、或窗口没了而文件不在 = 失败（13）；超过 `timeout` = 失败（12）；会话没开出来 = 失败（11）。
- **失败**：隔 `retry_delay` 重试（窗口名加 `-<次数>`），重试用完 → `failed`、写
  `logins/<登录>/alerts/<名>.json`（入口告警读它，C2）、条目带 `--bark` 时再推一条 Bark（密钥从凭据库注入，经 stdin 交给 curl）；
  下一次成功删掉告警。每次尝试记在 `logins/<登录>/runs/<名>.json`（留最近 60 次），输出在 `/var/log/fleet-node/logins/<登录>/<名>.log`。
- **看得到**：`status` 每个任务一行 `task <登录>/<名> <状态> · <计划> · last … · next …`；`status --json` 的 `services[]`
  对任务带 `status`（scheduled · running · retrying · ok · failed · stopped）、`last_run` · `next_run` · `last_result` ·
  `last_error` · `attempt` · `alert`。`state.json` 的 `agent_tasks` 是守护自己的记账。非 root 的 `ls` 读 `state.json` 里守护写好的那份。
- BREAK-IT 行 `task-fail-silent`；`fleet-node-supervisor-selftest.py` K。

## 12. 起停、现在跑一次、改计划 —— 从任何一台（EPIC #2524 C3，#2527）

客户端、入口页和机器上的命令行做的是同一件事；客户端那条不用 root、不用登上那台机器：

    fleet task run daily-report --now                         # 现在跑一次
    fleet task schedule daily-report --at 07:30 [--tz Asia/Shanghai]   # 改计划（或 --cron '0 7 * * 1-5'）
    fleet task stop|start|restart daily-report
    fleet service stop|start|restart sms-watch                # 同名在两台/两个登录上时加 --machine / --login

- **一条路**：`bin/fleet` 把这几个动词交给 `fleet-session-cli.py`：它从 `fleet-services.py` 的那张表找出条目在哪台
  机器、哪个登录，经 `fleet-hub-write.sh`（证书签名或 viewer 令牌两条门都行）发入口写操作
  `service_control {machine, login, name, action: start|stop|restart|run_now|set_schedule, at?, cron?, tz?}`；
  入口页「我的机器」里点一行，抽屉底部的按钮（停 · 起 · 重启 · 现在跑一次 · 改计划）发的是同一个。没有入口、
  请求根本没发出去时，在那台机器上自己跑就退回本机的 `fleet-<service|task>.sh`（sudo）。
- **入口裁权**：作用域 `service:control`（个人默认就有）；调用者看不到 (机器, 登录) → **403**；那台机器链路最近一拍
  的登记表里没有这一项 → 404；对常驻服务 `run_now` / `set_schedule` → 400。走的是那个登录自己的通道（不是哪个
  fleet），记一条操作日志、审计一行（`service:<机器>/<登录>/<名> <动作>`）。
- **节点执行**：机器的 `ccquota agent --machine` 不把它交给登录的 `fleet-control.py`（登记表是 root 的），而是自己以
  root 跑 root 运行时里、和 ccquota 同目录的 `fleet-node-supervisor.py`（root 所有、组和其他人不可写，否则拒绝），
  argv 固定为 `service <stop|start|restart|run|schedule> --login <这条通道自己的登录> --name <名>`——入口说的登录
  和通道不一致就 `WRONG_LOGIN`。答复即终态（succeeded / failed + 守护的原因），不用再对账。不是机器链路的普通
  agent 答 `UNAVAILABLE`。
- **改计划**：`service schedule` 只动 `schedule`（不给 tz 就留原来的），并记 `rescheduled`：改之前已经过去的那一档
  不补跑；下一档按新计划。`fleet task restart` 是 `start` 的同义（重新启用）。
- BREAK-IT 行 `task-rerun-root-only`；Go `TestServiceControl`（入口）、`TestServiceControlWrite`（节点）；
  `fleet-node-supervisor-selftest.py` K（`schedule`）；`fleet-session-cli-selftest.sh` K；`web/test/services.test.mjs`。

## 13. 登录级服务：把手写的启动项收编进登记表（EPIC #2524 C6，#2530）

以某个登录身份跑的后台程序一律登记给整机守护（§10–§12），不再手写 plist。已经手写的，按这一节收编。

**先找出来**：整机守护的清扫（每小时一次，`sudo fleet-node-supervisor.py sweep` 立即）把这类 plist 点名——
`/Library/LaunchDaemons` 里 `UserName` 是某个人的登录（不是 root、不是 `_` 开头的系统账号），以及各登录
`~/Library/LaunchAgents` 里程序在该登录家目录、又不在 `~/Library` 下的（应用自带的 agent 不算）。
它们记在 `state.json` 的 `sweep.handwritten`，`status` 每个一行 `handwritten <label> runs as <登录> …`，
体检 `services` 行对本登录的 WARN「N 个手写启动项」。只报不动：撤哪个、什么时候撤是人的事。
BREAK-IT 行 `service-handwritten`。

**收编顺序**（「先让新的跑通一次，再撤旧的」，漏一天比多一份更糟）：

1. 程序和它的状态放进目标登录的家目录（旧登录要退役的，先搬过来）；
2. 凭据进凭据库：`fleet service cred set <名>`（值从标准输入读），条目只写名字；
3. 登记：常驻的 `fleet service add`，定时的 `fleet task add`，工作目录和技能目录用 `--path` 记上
   （`fleet service move` 迁账号时靠它搬）；
4. 新的跑通一次：常驻的看 `fleet service ls` 在跑、日志有输出；定时的 `fleet task run <名> --now`，看它出了产物；
5. 撤旧的：`sudo launchctl bootout system/<label>`（LaunchAgent 是 `gui/<uid>/<label>`），plist 挪进
   `/var/db/fleet-node/attic/<时间>-handwritten/`，不删；清扫下一轮不再点名，体检转绿；
6. 旧的启动脚本留一版作手动补跑的后路（发起人拍板 4），下一批删。

**mini2 的两项（2026-10-09）**：

    # 短信通知：verkyyi → verky，常驻；Bark 推送密钥进凭据库
    fleet service cred set BARK_KEY                    # 值从标准输入读
    fleet service add sms-watch --cred BARK_KEY --path <它的状态目录> -- ~/bin/sms-watch
    # 每日推送：run.sh 的「07:00 后开会话、做完看 runs/<日>.done.json、试两次」由定时任务接手
    fleet task add daily-report --at 07:00 --tz Asia/Shanghai --retries 2 \
        --prompt '/daily-brief {date}' --window 'daily-{date}' \
        --done-file '~/daily-report/runs/{date}.done.json' \
        --path ~/daily-report --path ~/.claude/skills/daily-brief
    fleet task run daily-report --now                  # 跑通一次再撤旧的
    sudo launchctl bootout system/com.verkyyi.sms-watch
    sudo launchctl bootout system/com.verky.daily-report

验收：`ls /Library/LaunchDaemons | grep -c -E 'sms-watch|daily-report'` 为 0；`fleet ls --services` 两行都在跑；
次日 07:00 的 `daily-<日期>` 会话由守护开出；手机收到一条测试短信推送。`~/daily-report/run.sh --now`
仍可手动补跑一版。
