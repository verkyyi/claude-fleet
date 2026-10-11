# 托管机器：身份、信任与期望状态

Linux / Aliyun ACK 的单登录安装与容器生命周期见 [MANAGED-LINUX.md](MANAGED-LINUX.md)（#3022）；下面的 launchd / macOS 操作仍用于 Mac。

EPIC #2329 共同约定 1：**机器的期望状态在入口。** 入口为每台托管机器存一份
「应有的样子」；机器上的守护每个周期把实际状态收敛到它，`fleet doctor` 的机器部分
就是两者的差。这份文档是那份「应有的样子」的约定——C2（#2214）建了它，C3–C6 读它。
加一个字段，先改这里。

## 1. 信任在机器上；机器 = 加入时的那台，不是自报的机器名

一台机器在入口的身份是它加入时换到的**节点令牌**（一个 endpoint，`ep_…`），
加入时记下它是哪台机器（`endpoints.enrolled_host`）。**信任只在机器上**（#3300，人定：
「trust shall be set on machines, not login」）：`fleet.node_trust.<机器>`，一台机器上
每个登录 / endpoint 都随它。机器名（hostname）是 agent 自己报的，谁都能报成别的——
所以按的是**加入时**的机器，不是现在报的名字（#2214）。

| `trust_source` | 说明 |
|---|---|
| `machine` | 加入时那台机器的设置 `fleet.node_trust.<机器>` |
| `name_borrowed` | 报的名字是可信机器，但它不是用这个名字加入的 → 不可信、hello 审计一行 |

谁写机器的信任：

- 操作者：`fleet-node-trust.sh set <机器> trusted|untrusted`（`PUT /v1/fleet/settings`），或
  `PUT /v1/fleet/nodes/<ep>/desired` 带 `trust`——写的是这个 endpoint 加入时那台机器；
- 可信加入码（托管路由默认）：兑换时把 `trusted` 写到它加入的机器上；操作者明说过
  `untrusted` 的机器不被它翻掉；
- 入口开号（`loginJoinCode`）：码里记着开在哪台机器，新登录就按那台入册、随那台的信任，
  不管它报什么名字。

加入时记下的机器（`enrolled_host`）：码里写了机器就用码的；否则用加入时报的名字；
没报名字记 `?`（谁也不随）。旧的按 endpoint 的信任（`endpoints.trust`，加入码 / 旧的期望状态写）
入口启动后一次性迁到机器（`fleet.node_trust_machines_migrated`；同一台既有可信又有操作者
标的不可信 ⇒ 不可信），之后不再读。判定只在一处：`internal/api/fleet_trust.go` `nodeTrust`。

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
  "trust_source": "machine",
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
| `trust` / `trust_source` / `role` | 所在机器的信任与身份上的角色（§1） | PUT 里可带 `trust`：`trusted` / `untrusted` / `""`（去掉，读不可信）——写到这台 endpoint 加入时的机器上 |

PUT 的请求体就是上面可写的字段，外加可选的 `if_version`（读到的版本；对不上 `409 version_conflict`，什么都不写）。
未知字段 `400`——凭据不会有地方落脚。每次写审计一行（`node_desired`），改信任另记一行（`node_trust`，`machine:<机器>`）。

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

- 旧节点：按它加入时的机器（`enrolled_host`，老数据回填为当时报的名字）。
- 迁移时 `enrolled_host` 用每个 endpoint 当时报的名字补齐，所以 m4 / m5 现有的登录一个都不掉。
- 下一批删旧规则（`# compat-1v: 下一批删`）：那时每台机器都已凭托管加入码重新加入（C1 / C8）。

## 6. 一个节点程序服务整台机器（C5，#2333）

托管机器只跑**一个** `ccquota agent --machine`：root 运行，由守护（C3）的 `node-agent`
子进程拉起，取代每个账号一份的 `com.ccquota.agent.<login>`。

| 文件 | 内容 | 谁写 |
|---|---|---|
| `/var/db/fleet-node/machine.env` | `CCQUOTA_HUB_URL`、`CCQUOTA_TOKEN`（**机器自己**的节点令牌，§1） | 安装 / 迁移（C1 / C4），root 600 |
| `/var/db/fleet-node/logins/<账号>.env` | 这个账号原来那份 agent 的设置（`CCQUOTA_*`、`FLEET_CONF_DIR`），`CCQUOTA_TOKEN` = **这个账号**的节点令牌 | `account adopt <账号>` 写（#2387）：键取自旧 `com.ccquota.agent.<账号>` plist 的 `CCQUOTA_*` / `FLEET_CONF_DIR` + 这个账号 node.env 的 `CCQUOTA_*`（凭据隔离的从 credsep 存储读，带 `CCQUOTA_FLEET_CRED_STORE`），旧 agent 一起进 attic；`account release` 删它、放回旧 agent。root 600；别人能读写就拒；`logins/` 一变，守护重启节点程序——账本里有正在跑的账号操作时先等它结束（最多 `FLEET_NODE_RELOAD_HOLD` 960 秒，#2918） |
| `/var/db/fleet-node/agent/<账号>/account-ops.json` | 节点程序的账号操作账本：见过的 op_id、正在跑的操作（pid、哪个登录，不含加入码）、入口还没确认的结果 | 节点程序写（root 600、一次 rename，#2918）：重启后照账本补发结果，被截断的操作答成失败（写明登录在不在）；入口按同一 op_id 再问时不重跑。守护读它的 `inflight` 决定要不要先等再重启 |
| `~<管理员>/<登录>-onboard/op` | 开号脚本记下的「这个登录是哪次 op 建的」：`op=` `pid=` `started=`（第 1 步之前），跑完追加 `done=` 和结果行（credsep 最后） | fleet-login-new.sh 写（管理员 600，op_id 来自节点程序给的 `FLEET_LOGIN_OP_ID`，#2928）。不靠账本也认得出同一 op：登录已在、记号是同一 op ⇒ 跑完了按结果答成功、还在跑就等、半路停了就收回（fleet-login-remove，家目录保留）再报失败；开号失败而登录是这次 op 建的也当场收回 |
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
一个账号的被拒 lane 只是这个账号的事：Linux 托管机器的就绪探针不看它（#3333——曾让负载均衡摘掉
pod、22022 的门对每个登录都死了）；账号已不在（OS 登录、`accounts.json`、`logins/<账号>.env` 都没有）
的 lane 不算；`account forget` 把 `agent/<账号>/` 挪进 `attic/agent-<账号>-<UTC>`（BREAK-IT `linux-stale-lane-door-down`）。

**删号要完全磁盘访问**（#2973，BREAK-IT `login-remove-dscl-denied`）：macOS 不让没有「完全磁盘访问」
的进程删用户记录，root 也不行（`dscl . -delete` 答 `eDSPermissionError`）。入口下发的删号由节点程序跑，
它的进程链归守护的解释器（launchd 起的 `python3`）。守护每 5 分钟以 root 读一次 TCC 库，读不到就记
`state.json` 的 `fda`，`status --check` 退 4、doctor `node` 行 WARN，点名要加的程序。修（一个人点一次，
程序拿不到）：系统设置 › 隐私与安全性 › 完全磁盘访问 加上那个程序，再
`sudo launchctl kickstart -k system/com.claude-fleet.node`。没授权前，卡住的删号由 admin 经 ssh 手跑
`sudo fleet-login-remove.sh <账号> --delete-home --apply`（删号脚本被拒时最后一行就是这条）。

**删号不再等这个授权：走本机 ssh**（#2994）。sshd 的会话在「系统设置 › 通用 › 共享 › 远程登录 › ⓘ ›
允许远程用户完全磁盘访问」开着时自带完全磁盘访问，所以删号脚本读出自己没有时，先把删的那一步交给
`bin/fleet-login-remove-ssh.sh`：root 的钥匙 `/var/db/fleet-node/remove-ssh/id_ed25519`（known_hosts 取本机
主机公钥，不首次信任）授给跑删号的 admin，`authorized_keys` 里一行
`from="127.0.0.1,::1",restrict,command="/bin/bash '<current>/bin/fleet-login-remove-ssh.sh' forced"`——强制命令
只认 `probe` 与 `delete <登录名>`（普通登录名、uid ≥ 501、不是 admin 组、不是自己），删记录、清
`com.apple.access_*` 组。钥匙由 `fleet node install` 的「删号通道」一步、以及每次删号自己设（幂等）。走不通时
（远程登录关着 · 钥匙没被收 · 那个开关没开 = exit 7）各说一句，然后照原路直删；节点程序有完全磁盘访问时只走原路。
要做一次：在机器上打开「远程登录」和它的「允许远程用户完全磁盘访问」，跑删号的 admin 在远程登录的允许名单里。

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

**谁移 stable：只有发布列车**（#3141 · #3142 · #3143，EPIC #3139）。`release-train.yml` 测完同一个 `TRAIN_SHA` 后
出入口镜像（调 `hub-deploy.yml` 的部署任务）、发布（`fleet-release-publish.sh`）、挪 stable（`fleet-stable.sh move --train`），
一趟红了当场取消（「红灯即停」）、下一趟照常发。旧的三条路（合并触发的入口上线、`stable-auto.yml` 的自动挪动、
挪完自动派发的发布）已退休：`hub-deploy.yml` 只剩列车调用和手动 `workflow_dispatch`（`tag` = 回退），`stable-publish.yml`
只剩 dispatch 作修补；它们留在某个提交上的红 run 不再挡后面的挪动（`fleet-stable.sh` 第 3 道门不算发布类 workflow 自己的 run，
`FLEET_STABLE_DERIVED_RE`；`--ignore-check` 可重复）。BREAK-IT `train-red-holds-lane` · `train-derived-red`。

**发布版里的 ccquota 是该提交的 Go**（#2930）。发布版的 `ccquota-<os>-<arch>` 取自入口镜像自带的那份，所以入口镜像
构建时给每个 ccquota 盖上它编译的 Go 源摘要（`cmd/ccquota-srcdigest` → `-X main.SrcDigest`；`ccquota version` 第二行
`src <摘要>`）。摘要只算 `tokenledger/` 的构建输入（`go.mod` · `go.sum` · `cmd/` `internal/` 下的文件，去掉测试、
`testdata/`、`.md`、客户端清单和 pack；`release.SourceDigest`，git 一侧是 `bin/fleet-src-digest.py`）。入口建发布版时按该提交
算同一摘要：不等就不建（发布 422 `ccquota:`，等入口镜像重新部署），等了就签进清单的 `ccquota_src`；补建沿用原包的 ccquota。
所以 **Go 改了的提交要先重新部署入口镜像，stable 才挪得过去**：`fleet-stable.sh move` 第 8 道门先比入口
`/v1/fleet/release/artifacts` 的 `ccquota_src` 与目标提交的摘要（`ccquota:`；入口不报 `ccquota_src` 时退回 #2927 按 `/version` 查提交的那条）。机器上 `fleet doctor --machine` 的 `ccquota`
行：清单记了源、二进制的 `src` 不是它 → FAIL（整机退回）；旧发布版没记源、构建提交又不是 runtime → WARN。
更新器是 `bin/fleet-node-update.py`，守护（C3）的 `update` 任务（每 5 分钟一次，`FLEET_NODE_UPDATE_EVERY`），
root 运行。**新 stable 推过来就当拍跑**（#3146，EPIC #3139 C7）：入口的稳定指针一动、以及每条连接第一拍，给报了
`CapRelease` 的连接发 `release {sha, seq}`；整机节点程序（§6）对已在 / 已过的 seq 不理，否则写 `<state>/update-now`
（内容 = sha，root 0644，一次 rename），守护每秒看一眼，有就立刻起 `update`（照旧持锁、照旧医生验收、照旧回退），起跑时消掉；
目标仍是更新器自己读的入口 stable，推送只是叫醒，只前进。没托管的登录由它自己的 agent 跑一次
`fleet-install-sync.sh --now`。定时不动：推送丢了，下一次定时照样切到（BREAK-IT `release-push-lost`）。**托管登录的 `~/.claude/fleet` 就是机器运行时那一份**（#2774，EPIC #2770 C4）：
`~/.claude/fleet.versions/<sha>/` 仍是登录自己的**真目录**，但里面每个文件都是指向 `<root>/<sha>/<同一路径>` 的链接
（与 `bin/selftest-shadow-root.sh` 同一做法：目录是真的、文件是链接，所以 `$BIN/..` 落在登录自己的目录里——
`logs/`、`epic-pages/`、`fleet.conf*` 照旧由 `fleet.versions/.shared/` 链入）。字节只在 `<root>/<sha>/` 存一份，
登录目录只是链接（< 1 MB），毫秒级建好——唯一的例外是 `mod/`：整棵真拷贝（几百 KB），因为 Claude Code 解析插件文件的真实路径、
拒绝落在 `--plugin-dir` 之外的（「Path escapes plugin directory」），之前建的树由在发布版的下一拍原地补成拷贝（#2964）；最后写的 `.fleet-linked`（`{sha, root}`）是「这棵树完整、属于哪一版」的记号。
建它的是更新器的 `link-tree <sha>`，**降权到该登录**（它的 HOME / TMPDIR / `FLEET_CONF_DIR`）运行：建树 → 一次 rename 切
`~/.claude/fleet`（普通目录先收成版本布局）→ 跑新版的 `fleet-install-apply.sh --tree-from <旧版本目录> --tree-to <新>`
（两目录比较模式：链接树里没有 git，改了什么逐文件比两棵树得出；守护重载、hook 合并、技能安装照旧）。
**机器换版时所有登录同时换**：切换那一拍（`current` 换完、请守护重启之前）每个托管登录 `link-tree` 到新版；
体检 FAIL 整机退回时每个登录一起退回；提交后、以及每拍处于发布版时，没链接到 `current` 的登录（被手动指回一份
独立旧副本、开号时那份自己的拷贝）重新链接（BREAK-IT `managed-login-own-copy`；只有打开了 EPIC 挡（`FLEET_EPIC_HOLD_CAP_SECS`）时，有活的批次在跑才先等）。跟不上的记进 `update.json` 的 `follow`，`install` 行写明最后一次结果，同一版
`FLEET_NODE_UPDATE_RETRY` 后再试（`FLEET_NODE_UPDATE_FOLLOW=0` 关）。登录自己的 `fleet-install-sync.sh` 在托管登录上答
`off · managed · 跟随 <root>/current (<sha>)`（这次是对的：更新器负责），不再自己去取——以前（#2688 / #2714）它按提交
从 GitHub 取对象、每个登录各存一份。`account adopt` 接管那一刻**当场同步**做一次 `fleet-node-update.py follow <login>`
（`FLEET_NODE_ADOPT_FOLLOW=0` 关）；`account release` 先把链接目录换回一份**独立副本**（拷贝而非链接，一个
`fleet-release: <sha> seq=<n>` 提交的 checkout，放手后它的 install-sync 走入口那条路自己活），再放回它自己的服务。
被某个登录版本树链接着的 `<root>/<sha>` 过了保留期也不删（`.prev` 与 7 天保留都按「有人还在用」算）；登录自己退下来的
链接树留 `FLEET_INSTALL_VERSIONS_KEEP_SECS`（7 天，给还在跑旧文件的会话），下次 `link-tree` 时清。
旧的 fleet-shell.sh 钉在某个版本目录的客户端壳镜像（`~/.cache/claude-fleet/shell/{bin,conf}` → `fleet.versions/<key>/…`）
每拍改走登录链接（`~/.claude/fleet/…`），随安装一起动。
`fleet doctor --installs`（#2692）一张表列本机的运行时、每个登录安装、每份客户端壳，各自是否等于 stable。
非托管机器照旧走 install-sync，一字不差。

### `release.json`（仓库根，随发布包一起签名）

```json
{
  "schema": 1,
  "components": {
    "ccquota":    {"artifact": "ccquota-{os}-{arch}"},
    "claude":     {"version": "2.1.295", "artifact": "claude-{version}-{os}-{arch}"},
    "codex":      {"version": "0.162.1", "artifact": "codex-{version}-{os}-{arch}"},
    "tmux":       {"version": "3.7c",    "artifact": "tmux-{version}-{os}-{arch}", "lock": "conf/vendor-tmux.lock"},
    "supervisor": {"script": "bin/fleet-node-supervisor.py"}
  }
}
```

| 部件 | 版本从哪来 | 装到哪 |
|---|---|---|
| 脚本（运行时） | 发布版提交本身（签名清单的 `sha`） | `<root>/<sha>/`（`<root>` = `/Library/Application Support/claude-fleet`） |
| `ccquota` | 发布包里的 `ccquota-<os>-<arch>`（入口 dist 构建，sha256 在签名清单里） | `<root>/<sha>/bin/ccquota`——节点程序（C5）从 `current` 跑它 |
| Claude Code / Codex / tmux | `version` 钉住；可执行文件本身是发布包的 artifact（`{version}` `{os}` `{arch}` 展开，`{arch}` 是 `arm64` / `amd64`） | root 缓存 `<root>/tools/<名>/<sha256>/<名>`，发布目录里 `tools/bin/<名>` 链过去。部件可带 `helpers`（文件名 → artifact 模板，同样展开、同样算钉住制品）：工具在**启动路径旁**找的辅助程序（codex 的 `codex-code-mode-host`，#3017）装进同一个缓存目录、`tools/bin/<辅助名>` 链过去；旧更新器装的发布版缺它，下一轮补上（`ensure_helpers`） |
| 开号缓存 | 同 `claude.version` | `<root>/cache/claude/<ver>/claude` + `current`（`fleet-bootstrap-cache.sh claude` 从这里装新账号） |
| 账号 | — | 每个托管账号的 `~/.local/bin/{claude,codex}`、`~/.local/share/claude-fleet-vendor/bin/tmux` 链到 `<root>/current/tools/bin/<名>`，工具的辅助程序链在同一目录（工具是发布版的时，那里手放的副本换成链接）；由降权到该账号的进程建，每轮重建（Claude Code 自己更新换掉了链接就换回来），**从不覆盖账号自己的普通文件** |
| 管理员的节点 agent | 同 `ccquota` | 不被接管的登录（管理员，#2842）的 `com.ccquota.agent.<login>` 经 credsep 启动器跑 credsep `meta.json` 的 `agent_argv`：更新器每轮把它的 `agent_argv[0]` 指向 `<root>/current/bin/ccquota`（root 的文件，不写登录家目录），发布版一变（切换、回退、首次指回）就 `launchctl kickstart -k system/com.ccquota.agent.<login>`（Linux `systemctl restart`），同一版只一次（`update.json` 的 `admin_agents`）——它是开号的那个管理员节点，跑旧二进制就说不出 `login_join`（#3034）。机器体检 `admin-agent` 行：跑自己的旧二进制或没在当前版重启 → WARN，不作回退依据；`fleet-node-upgrade.sh` 跳过跑发布版 ccquota 的 agent |
| 共享凭据代理 | 发布版提交的 `bin/fleet-cred-proxy.py` / `fleet-credsep-launch.py` | root 代码副本 `<root>/credsep/`：更新器每次切换、回退、验证前和每一轮跑 `<current>/bin/fleet-credsep.py machine refresh`，字节变了代理就重启——launchd 管的（旧 `com.claude-fleet.cred-proxy-shared` 还在）由 refresh bootout / bootstrap，守护管的子进程由守护按 `reload`（`credsep/` 一变）重启，refresh 不另写 plist（#2435）。旧 plist 由守护的清扫在子进程能起时 bootout 进 attic，此后 credsep 的 install / join / leave / purge 要重启代理时只在 `credsep/` 写一个 `.restart` 戳、不再写 plist（#2981） |
| 守护自身 | 发布版提交 | 它就在 `current` 里：切换后最后一步写 `<state>/update-restart.json`，守护停掉子进程退出，launchd 用新版拉起 |

- 可选的 `"client_reload": "hot" | "restart"`（#2737，缺省 `hot`）：版本切换后正在跑的客户端壳怎么换新。`hot` = install-sync
  切换成功后 `fleet-client-update.sh follow` 原地重载（同一对 tmux 服务器、窗口、正在看的会话不动）；`restart` = 这一版载入不了
  正在跑的客户端（tmux.conf 要更新的 tmux、协议变了），不热换，底栏「新版已就绪 · 下次打开生效」，没人连着的客户端在下一次
  `fleet` 时关掉重开。只在需要的那一版写，下一版去掉。
- `os` / `arch` 只是 artifact 名字的展开；校验和永远是**入口签名清单**里的那个，`release.json` 不写校验和。
- 升一个部件 = 改这里的版本 + 把同名 artifact 放进入口的 `CCQUOTA_FLEET_RELEASE_ARTIFACTS`，再移 stable。
  发布包里缺 artifact → 这一版**不换**（`failed`，1 小时后重试），不会只换一半。
  两道拦截（#2631）：`fleet-stable.sh move` 先问入口 `GET /v1/fleet/release/artifacts`，目标 `release.json`
  钉的制品（`fleet-node-update.py pinned-artifacts`，按入口说的平台展开，默认 `darwin-arm64`）缺一个就拒挪
  （`artifacts:`，点名缺哪个；`--force` 记一行）；入口自己也不打包缺钉住制品的发布版（构建报错、不落盘），
  制品放进去后下一次请求就建出完整的一版。
- **ccquota 是入口自己编的那份**（`ccquota-<os>-<arch>` 来自入口镜像的 dist 目录，版本 = 入口 `/version` 的
  `prod-<sha>`），不是从 stable 那个提交编的。所以 `fleet-stable.sh move` 第 8 道门（#2927）：目标在
  `tokenledger/` 下（测试、*.md 除外）有入口那个 sha 没有的提交就拒挪（`ccquota:`，列出缺的提交）——先部署入口，
  再移 stable；`--force` 记一行。否则机器会跑上树的一半、节点程序的旧一半（stable 003e89bb 带着 prod-343c92b：
  #2922 的 hold 上了机、账本没上，开号被重启截断后重跑，撞「登录已存在」）。
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
2. **不为批次推迟**（#2934）：切换只换 `current/` 和守护，在跑的会话不受影响（各在 `fleet.versions/<sha>`），所以默认有 EPIC 批次在跑也照常切换——批次跨版本由 `/fleet-epic-run` 自己记（`fleet-epic-floor.sh`，报告写「本批跨了几个版本」），`status` 写 `hold    off`。`FLEET_EPIC_HOLD_CAP_SECS=<秒>` 是可选开关：设了之后任何托管账号有「有活」的 EPIC 批次在跑（#2247 的 `fleet_epic_holding`）→ `deferred`，最长这么久——整机一个钟，从第一次 deferred 起算，换批次、换 stable 都不重开，到达目标版本才清（#2843）；超封顶照常切换，更新器以各登录身份在每个在挡批次的 EPIC 上留一条记录型说明。托管登录的 install-sync 不再自己挡第二次。每拍记下第一次看到目标版本的时间（`update.json` 的 `target_seen`），`fleet doctor --installs` 据此写「落后 stable 多久」，超过 30 分钟 WARN。签名：`status` 打出钉住的 key 指纹与当前发布版的签名 key 指纹；取包验签失败是 doctor 的 `key` FAIL（附入口现在的 key：同一把 = 读到两次构建的半对，ccquota 已自动重读一次；不同 = 入口换了钥匙，需重钉）。
3. **取包**：`ccquota release fetch --artifacts`（C7，只问入口、验钉住的公钥 `<state>/release.pub`）→ 装 ccquota 和各工具 → 写 `.release/staged.json`。没有这个标记的目录 = 没装完，删掉重取。取包可续传（#2701）：只取 `release.json` 为本机平台钉住的制品（`--pinned`），每个落 `<root>/.fetch/<sha256>.part`、断了用 Range 接着取，只有 30 秒没有一个字节才算断、没有整包 deadline；取之前把工具缓存和当前 / 上一版的制品按 sha256 硬链进去，同字节的不再下；有进展的失败不退避，下一轮接着取。进度写 `<state>/fetch.progress`（`status` 打最后一行，`fleet node install` 边取边打印）。不认这些参数的旧 ccquota 照旧整包取。
4. **切换**：每个托管账号（降权、它自己的 HOME / TMPDIR）先跑新版的 `fleet-sessions-snapshot.sh save`，把没做完的会话钉进它的 `global/sessions.snapshot`（#2484）→ 记下当前（旧版）的机器体检 FAIL 作基线 → `.prev` = 旧版、`current` = 新版（各一次 rename）→ 开号缓存、账号链接、共享凭据代理的代码副本（`machine refresh`）、每个托管登录的 `~/.claude/fleet`（`link-tree` + 两目录 apply，#2774）→ 请守护重启。
5. **验证**（下一轮，新代码，`FLEET_NODE_UPDATE_SETTLE` 30 秒后）：机器体检（`fleet doctor --machine`）比基线多出 FAIL
   （判之前先 `machine refresh` 一次：由不认识 credsep 的旧更新器换上来的版本，副本还是旧的）
   → `current` 切回 `.prev`，缓存、链接、代理副本、每个托管登录的 `~/.claude/fleet` 一起回，这一版记 `skip`（回退的原因只是一条已成过去时的签名失败就当拍重试，否则 `FLEET_NODE_UPDATE_SKIP_RETRY` 6 小时后再试、同一版每回退一次翻倍、最多一周；`0` = stable 再动之前不重试——#2906）。机器体检的 `key` 行只认比最近一次验过章的取包更新的签名失败；入口的 torn read（入口给的钥匙 = 钉住的）只 WARN，不作回退依据，再请守护重启；否则 `committed`。提交或回退之后每个托管账号跑那一版的 `fleet-sessions-snapshot.sh restore`：钉住的会话按原名、原目录、原对话经 `fleet-restore.sh` 开回（已关单 / 已删目录 / fleet-down 的不开），回来几个、缺哪个记进 `update.log`（BREAK-IT `node-update-sessions`；`FLEET_NODE_UPDATE_SESSIONS=0` 关）。
6. 退下来的版本留 7 天（`FLEET_NODE_UPDATE_KEEP_SECS`），`current` / `.prev` 永不删，还有托管登录的版本树链接着的也不删（#2774）；没有发布版再引用的工具缓存一起清。

### 机器体检

`fleet doctor --machine`（= `fleet-node-update.py doctor`）一行一个部件：`runtime` `ccquota` `claude` `codex` `tmux`
（各自 `--version` 必须含 `release.json` 的版本，否则 FAIL）、`daemon`（守护在跑且跑的是 `current` 那一版，否则 FAIL）、
每个子进程、`cache`、`credsep`（机器有共享凭据代理时：副本 ≠ 发布版 FAIL；代理的 `version` ≠ 副本、等 `FLEET_NODE_CREDSEP_WAIT` 15 秒后仍是 FAIL；读不到 WARN）、每个托管账号的链接（WARN）与它的 `~/.claude/fleet`（`install`：链接到 `current` 的同一 sha 才 PASS；独立副本——哪怕同一 sha——、落后、读不出 WARN — #2688 / #2774），最后一行 `version … — 各部件 = 发布版声明`。
退出码 = FAIL 数。普通 `fleet doctor` 多一行 `update`（最后一轮的结果；失败 / 回退 / 跳过时 WARN）。

### 新旧并存

- 没有 `update.json` 的机器：体检没有 `update` 行，`--machine` 只说「不是托管机器」。
- 旧守护没有 `update` 任务、不认 `update-restart.json`：新守护第一次由 C1 / C8 装上后才开始自己更新。
- 开号缓存的 git 镜像一半（`claude-fleet.git`）退役（#2775）：新登录第一次装走 `fleet-login-install.sh`——托管机器上直接 `link-tree` 到 `<root>/current`（不取任何东西），`fleet-login-new.sh` 第 8 步改为 `account adopt`（不再给托管机器上的新登录渲染逐登录的 LaunchDaemon）；没有运行时才找入口的签名 stable，都没有（开发者机器）才 `git clone`。`refresh --from` 照收不用（一版），旧镜像留在盘上没人读；Claude Code 那一半照旧。
- 托管账号自己的 `~/.claude/fleet`（守护替它跑的每个账号任务都是 `__HOME__/.claude/fleet/bin/…`）**是**更新器搬的（#2774）：一棵链接到 `<root>/<sha>/` 的目录树，随机器一起换、一起退。第一次换到带 #2774 的版本时，切换由旧更新器做（它还不链接登录），新代码在下一拍验证提交后把每个登录链接过去；在那之前登录仍是 #2688 / #2714 留下的那份自己的 worktree，`install` 行 WARN「its own copy, not linked to the runtime」。登录自己的 install-sync 在托管登录上答 `off · managed · 跟随 <root>/current`；`<root>/current` 还没有时答 `off · managed — … names none yet`。当场跟上：`sudo python3 <root>/current/bin/fleet-node-update.py follow <login>`。旧会话手上的绝对路径（`fleet.versions/<old>/…`）在 7 天保留期内仍在；链接树里文件的 `realpath` 落在 `<root>/<sha>/`（只读、共用），所以写东西的脚本一律经 `$BIN/..`（真目录）走。

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
基线 → 加入码（人）→ 安装（人，§8 那一条）→ 逐个账号 `account adopt`（发起人自己的账号最后迁；管理员登录 adopt 退 5、记 SKIP——它不交给守护，§15；其余失败即停并打印 `account release`）
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
- **删号先让守护放手**（#2924）：`fleet-login-remove.sh` 第 1c 步（服务下线、杀进程之前）跑
  `account forget <登录>`——条目从 `accounts.json` 删掉、`logins/<登录>.env` 删掉、等守护停掉它的任务和子进程，
  attic 里的旧服务**不装回**（只取消保留，7 天后清掉）；不然守护会把杀掉的任务再拉起，删号三轮后退 1。
  `account release` 遇到机器上已没有的登录也只做这一件，不装回任何 plist。BREAK-IT 行 `login-remove-managed`、
  `account-release-gone-login`。
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
BREAK-IT 行 `service-handwritten`。只点名接管过的登录（`logins/<登录>.env`，#2702，见 §14）。

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

**mini2 的手机 MCP（#3247）**：`phone-mcp` 同样登记给守护，以管理员登录 verkyyi 常驻、带鉴权代理听 tailnet，
人的每个登录经 http 连它——装法、配法、换令牌见 [PHONE-MCP.md](PHONE-MCP.md)。

## 14. 托管机器不是谁的常驻客户端（#2702 · #2720 · #2904）

人在自己的设备上跑 `fleet`（客户端壳）；托管机器只跑会话和后台服务。所以在托管机器上
（有 `/var/db/fleet-node/machine.env`）：

- **SSH 登录不自动开客户端**；但人**显式**敲 `fleet`（或 `fleet <机器>`）时，进入「节点上的客户端」（#2720）：
  先一行「客户端在 <机器> 上运行；平时请在自己设备上用 fleet」，然后照常起客户端——给手边只有手机 Termius、
  别人的电脑、只能 SSH 的场合用。它和设备上的客户端是**同一份代码**：从机器运行时 `current/bin` 跑（不往
  `~/.cache/claude-fleet/shell` 复制镜像、不装壳的 LaunchAgent、不自己检查更新、不写 iTerm2 配置），版本随机器
  运行时走；缓存是 `$TMPDIR/fleet-node-client-<uid>` 临时目录。进程只在这次 SSH 期间存在：`fleet quit`、分离
  （prefix d）、断开 SSH（SIGHUP）都把它全部退掉，连临时缓存一起删；SSH 无声断掉时 keeper 发现
  `FLEET_NODE_HOSTED_IDLE`（30 秒）没有终端挂着就自己退。身份是这个登录的证书 / `fleet login`；`where` 报告
  `via=node-hosted`、能力只有「给链接」，`show` / `open` 在底行打印路径 / 链接。会话列表与设备上一致：本机会话
  是本机行，别机行走入口缓存；没有入口地址就说「先 fleet login」，没有 #1712「读本机」的特例。
  `fleet claude|codex`（`--here` 除外）答一行、退出码 3（单会话视图跟着设备上的客户端走）。会话里的测试身份
  （`FLEET_CLIENT_IDENTITY=test`）和 `FLEET_NODE_CLIENT=1`（#2702 之前留下的常驻客户端）照旧走设备客户端的路；
  还留着 `~/.cache/claude-fleet/shell`（或旧常驻壳的 `-L fleet-shell` 还在跑）时再提示怎么清掉。
  它的 tmux 服务器是自己的 `-L fleet-node-client[-stage]`（`FLEET_NODE_HOSTED_SESSION`，#2904），从不复用旧常驻壳的
  `fleet-shell`——同名复用时看到的是旧壳的旧画面。托管机器已是受信任节点：`fleet login` / `fleet login status`
  末尾的「登录即登记」（`fleet node ensure`）在这里什么也不做，不再向入口要节点通行证（入口对它答 409）。
  首连某台机器时 ssh 的主机密钥确认（`continue connecting (yes/no)?`）出现在右侧，敲 `yes` 继续——#2757 的贴图
  过滤器曾把它吞掉，首连永远停在「正在连接」（#2904，设备上的客户端同样受影响）。
- **SSH 登录是一个普通 shell**：`shell/fleet-login.zsh` 在这里不出横幅、不开客户端；`fleet-login-new.sh` 开号时
  `~/.zshrc` 只写 `~/.local/bin` 的 PATH 行（没有首登块、没有 cw.zsh），fleet 由它当场以新登录的身份拉起（8b）。
- **一次性清理**：`sudo fleet-node-shell-retire.sh --login <登录> [--dry-run]`——先 `fleet quit`（把入口租约还回去），
  再停掉还从 `~/.cache/claude-fleet/shell` 跑的进程（TERM，3 秒后 KILL），删掉这个目录，把 `~/.zshrc` 里的首登块和
  source `fleet-login.zsh` / `cw.zsh` 的行拿掉（旧文件留作 `~/.zshrc.pre-shell-retire`）；每步先看、没事可做就 `skip`，
  文件操作都以那个登录的身份做。会话、`~/.claude/fleet`、它的服务都不碰。
- **清扫自己清**（#2981）：托管机器（有 `expected.json`）上，整机守护的清扫对「家目录里还有壳 / `~/.zshrc` 还有钩子」
  的托管登录直接跑上面那条命令（加 `--if-idle`：客户端还在跑就什么都不动、退出 3，下一轮再来）；清不掉的才记进
  `sweep.clientshell`，`status` 每个一行 `clientshell <登录> …`（带命令和这一轮的结果）；`fleet doctor --machine`
  一行 `shell`：都没有 PASS，有就 WARN（不算 FAIL，不触发整机回退）。root 当场看每个家目录，别的登录读上一轮清扫的记录。
  节点上的客户端（#2720）只在 `$TMPDIR` 里、只在一次 SSH 期间存在，不在点名之列。
- **只看托管清单**：清扫的手写启动项、`clientshell` 和 doctor 的 `shell` 行只看整机守护接管过的登录
  （`/var/db/fleet-node/logins/<登录>.env` 里登记的）。管理员（例：verkyyi）、不用 fleet 的本地用户一律不扫、不点名、
  不判断——机器上有其他管理员或非托管账号是正常状态。`shell` 行写明「托管登录 N 个，其余账号不在清单内不扫」。
- **fleet 自己的启动项例外**（#2981）：托管机器上，清扫把「期望集合」之外的 fleet 启动项（`com.claude-fleet.*` /
  `com.ccquota.*`）先 bootout 再挪进 attic（7 天，`attic restore <id>` 放回）——整机守护不跑的机器级单元、
  托管登录残留的、已不存在的登录的，以及子进程的旧 LaunchDaemon（守护能自己起它时：
  `cred-proxy-shared`）。期望集合 = 守护自己、`expected.json` 的 `labels`、root 的 `/var/db/fleet-node/keep-labels`
  （一行一个，本机想留的）、每个现存登录自己的凭据代理 `com.claude-fleet.credsep.<登录>`（`machine join` 是它的路），
  以及**管理员登录**的每个单元（管理员永不被接管，#2842；它的 `com.ccquota.agent.<管理员>` 就是这台机器的 admin node，
  入口靠它开新人的登录——#2997：清扫曾把它收进 attic，两台机器都没了 admin node，新人一个号也开不出来）。
  **只点名不动**的：没被接管的非管理员登录的（`account adopt` 是它的路）、卸不下来的、子进程还起不来的旧 daemon；
  有 `fleet-onboard-drill.sh` 在跑时这一轮一个都不动（`held:`）。`status` 每个留下的一行 `extra <label> left in place — <为什么>`，
  末行 `removed N · extra M (left in place)`。

## 15. 破坏能力 = 登录的能力，不是提示词（#2842）

一个会话能毁掉什么，由它跑在哪个登录下决定，不由它的提示词决定。

- **接管的登录是租户**：守护 `account adopt` 的登录没有 admin、没有 sudo——物理上建不了账号、删不了账号、
  改不了 root 的守护进程。worker 就跑在这样的登录下，所以「worker 不许建临时账号」不需要写成一句提示词，
  也不该写：一句提示词拦不住一个不听话（或被注入）的会话，却会让有能力的会话也不敢动手（#2139 的演练被连推 5 轮给人）。
- **管理员的能力是管理员的**：verkyyi 这类有 sudo 的登录可以做，任何以它身份跑的会话也可以做——包括编排经
  `m4-admin` / `m5-admin` 的管理员 SSH。限制的对象是普通租户，不是角色。
- **要 root 的脚本只看能力**：`fleet-onboard-drill.sh`、`fleet-login-smoke.sh` 的预检只问 `sudo -n`，
  不通就拒并说「需要管理员登录（有 sudo）」，从不问「调用的是不是 worker」。新写的同类脚本照此办。
- **能力面是检查出来的**：`account adopt` 先查这个登录——admin 组、`sudo -l -U` 的规则、sudoers 里的名字——
  有一条就退 5、什么也不挪（管理员登录不交给守护）；守护每 `FLEET_NODE_TENANT_EVERY`（300 s）以 root 重读每个接管的
  登录写进 `state.json`；`fleet doctor` 的 **`tenants`** 行（`fleet-node-supervisor.py tenants --check`：组当场读，
  sudo 读守护的那份）任何一条成立就 **FAIL**，写明是谁、哪条。BREAK-IT `tenant-admin-adopted`；登录自己往外看的一半是
  `fleet-tenant-scan.sh` 的 `sudo` 项（`tenant-sudo`）。
- **派活跟着能力走**：worker 被「需要管理员登录」拒了的活，编排经管理员 SSH 自己跑（规则 20），管家不把它当「只能人做」（规则 21）。
- **不做的**：不改 sudoers，不给任何接管的登录任何 sudo。一个管理员登录已经被接管了（`tenants` FAIL 指着它）：
  `sudo fleet-node-supervisor.py account release <登录>` 把它的服务放回去，它照旧以自己的 LaunchAgents 跑。

## 16. 入口端口：只认入口登记的钥匙（EPIC #3067 C3，#3070）

每人一个地址（`<名字>.cf.24haowan.com`），指向他的家机器上**第二个 sshd**——fleet 里唯一一个有意监听公网的服务。
机器原有的远程登录（22 端口、tailnet 上的）一字不动、不上公网。

- **开关**：`FLEET_ENTRY=1`（端口 `FLEET_ENTRY_PORT`，默认 22022），写在 `<state>/machine.env`——launchd 不给守护环境变量，
  所以 `FLEET_ENTRY=1 sudo fleet node install` 的「入口」一步把它写进去（`FLEET_ENTRY=0` 去掉），再跑一遍 `entry ensure`。
  没开 ⇒ 不建任何东西、不监听，`status` 逐字节如前。
- **进程**：守护的子进程 `sshd -D -e -f <state>/entry/sshd_config`，自己的主机钥匙（`<state>/entry/ssh_host_ed25519_key`，
  和系统 sshd 的不同），配置一变发 SIGHUP（sshd 原 pid 重读，已有连接不断）。配置先过 `sshd -t`，再看 `sshd -T` 里
  密码 / 键盘交互 / root 都是 no、`PerSourcePenalties` 在（OpenSSH 9.8+）——不过就留原样；没有每来源惩罚的老 sshd 根本不起，
  体检说缺什么。日志在守护的子进程日志 `<log>/entry.log`（`LogLevel VERBOSE`：每次进门的登录、来源、钥匙指纹）。
- **钥匙文件**：每个登录一份 `<state>/entry/keys/<login>`（root 0644，目录 root 0755），每行一把普通钥匙
  `<type> <b64> fleet:<fp>`（不加 `restrict` / `command=`，手机与电脑同权）。入口 sshd 只读它
  （`AuthorizedKeysFile …/keys/%u`），不读 `~/.ssh/authorized_keys`、不信用户 CA、不跑 `AuthorizedKeysCommand`。
  只由这里写：入口推 `entry_keys {version}`（`CapEntryKeys`，整机链路），整机节点程序跑
  `fleet-node-supervisor.py entry pull --version N`——用机器 token `GET /v1/node/entry-keys`，形状
  `{version, logins:{<login>:{person, keys:[{fp,type,b64,name}]}}}`；version 只进不退。最后一份好名单存在
  `<state>/entry/list.json`（root 0600），守护每 `FLEET_ENTRY_EVERY`（60 秒）比对一次，有人改过就放回。
  入口不在时最后一份一直有效。
- **谁能进**：`AllowUsers` = 名单里**守护接管了、没有管理员能力**（与 §15 同一个判断）的登录；管理员登录、root
  名单点名也不写。一个人都没有 ⇒ 删配置、入口 sshd 停。macOS「仅这些用户可远程登录」开着时，把这些登录加进
  `com.apple.access_ssh`（只加、记在 `state.json` 的 `access_ssh`，离开入口时只撤自己加的）。
- **撤钥匙**：重写后被撤的钥匙下一次就被拒；它正连着的入口连接被断开——Linux 按 `ExposeAuthInfo` 的
  `$SSH_USER_AUTH`，macOS（看不到别的进程的环境）按入口日志里该指纹的来源端口对上连接（`lsof`）。tmux 会话不受影响。
- **体检**：`fleet doctor` 的 `entry` 行（`entry status --check`）：入口 vN · 本机 vM · 拉到 …；落后一小时、配置被拒、
  名单有人却没在监听 ⇒ WARN。`fleet-node-supervisor.py status` 多一行 `entry`。
- **进门去哪**（#3071，C5）：`ForceCommand /bin/bash <runtime>/bin/fleet-entry.sh`（运行时带它之后才写；之前是普通登录），
  只分发、以那人的登录运行：无命令有终端 ⇒ `fleet-remote-view.sh attach --thin --resume`（视图 id = 钥匙名 + 指纹 6 位，
  同一把钥匙回到上次的会话——那一份记在 `$FLEET_CONF_DIR/entry/<view>.cur`；没有就是编排会话；设备名按
  `ExposeAuthInfo` 的指纹从 `state.json` 的 `names` 查，名单里钥匙带 `name`）；有命令 ⇒ `exec "$SHELL" -c`，与 22 端口一样
  （`Subsystem sftp` 是本机真的 sftp-server，ForceCommand 下 internal-sftp 跑不了）；无命令无终端 ⇒ 登录 shell。
  不设 `DisableForwarding`，但转发只到本机（#3075，C9）：`AllowTcpForwarding local` + `PermitOpen localhost:* 127.0.0.1:* [::1]:*`
  （`fleet open` 的 `-L`、瘦客户端照常），`-R`、unix socket、agent、X11、隧道都关。
- **电脑也走它**（#3075，C9）：`fleet login` 登记的设备钥匙（`~/.ssh/fleet-cert` 那把）在入口开着时同时登记成这个人的
  一把普通钥匙（钥匙页上「<设备名> · fleet」；开入口前登记的设备在下一次续期时补上；人在钥匙页撤掉的，续期不补、
  重新扫码才回来），设备被吊销时一起撤。节点路线 `entry=<host>:<port>`（`CCQUOTA_FLEET_NODE_ROUTES`，公网端口在路由器上）
  就是 `fleet connect` 的 `entry` 路线（没写 `entry=` 的机器，用 C6 的 reachable(machine)——入口真敲开过的地址 + 端口，
  `entry`、`entry-2` …；没敲开过就没有）：排在 Tailscale 和旧的 `public`（系统 sshd）前、中转前，ssh 只出示设备钥匙
  （`IdentitiesOnly`，不出示证书）；主机钥匙是入口自己的那把，随心跳的 host keys 下发（`fleet route <机器> entry` 钉住）。
- **审计**（共同约定 11）：每次进门登录处一行 `$FLEET_CONF_DIR/logs/entry.ndjson`（去了哪：view · exec · sftp · shell）；
  守护每拍读入口 sshd 的 `entry.log`（接受 · 钥匙被拒 · 没这个登录 · 不在入口上），一行一条写 `<log>/entry.ndjson`
  （时间 · 人 · 登录 · 指纹 · 机器 · 来源 IP · 结果，不含钥匙正文），并排进 `<state>/entry/audit-pending.ndjson`
  送 `POST /v1/node/entry-audit`（每条自己的 id，重发无害；入口不在就攒着，最多 5000 条）。
- **Linux 托管节点**同一份规则：容器的环境里给 `FLEET_ENTRY=1`，守护照样起它（`fleet-node-linux.py` 已建 `/run/sshd`）。
- BREAK-IT：`entry-password` · `entry-other-login` · `entry-revoked-key` · `entry-self-added-key` · `entry-admin-login` ·
  `entry-keys-tampered` · `entry-hub-down` · `entry-no-command-lands` · `entry-forward-out`（`bin/fleet-break-it-entry-selftest.sh`，真 sshd、
  沙箱端口、沙箱状态目录）。

### 外面能不能连上它（EPIC #3067 C6，#3072）

- **每 5 分钟报一次**：整机节点程序（`ccquota agent --machine`）在心跳之外、自己的 goroutine 里跑
  `fleet-node-supervisor.py entry reach`——一次报不上、路由器不回答，都不耽误一拍心跳。它读入口有没有在听、入口端口的
  主机公钥、本机的全局 IPv6（不报隧道 / 网桥上的、临时的、废弃的）和私网 IPv4（只用来写「转发到哪个内网地址」——默认路由那块网卡的排第一，有线 en0 与 Wi-Fi en1 都在时写的是 en0 的），
  `FLEET_ENTRY_PORTMAP=auto`（默认，machine.env 或环境）时先用 NAT-PMP、不行再用 UPnP 请路由器把入口端口转出去
  （租期 2 小时，每次报时续上；UPnP 只取应答路由器自己私网地址上的描述）；`off` 不碰路由器。没人以这台为家（没在听）就不请路由器。
- **路由器给入口的公网端口**：机器有运维写的 `CCQUOTA_FLEET_NODE_ROUTES` `entry=host:port`（环境、machine.env，或接管登录的
  `<state>/logins/<login>.env`——节点程序读的那份）时，报告带上 `entry_host` / `entry_port`，入口在**那个端口**上敲来源地址和
  这个 host 解析出的公网地址（macmini `entry=ssh.minihaowan.com:22122`，mini2 `:22123`，路由器转到各自的 :22022）；体检写
  「在路由器上把公网 TCP <那个端口> 转发到 <有线网卡地址>:22022」。`public=` 是系统 sshd 的，这里不读；没有 `entry=` 就是 22022。
- **入口从外面敲门**：机器 token `POST /v1/node/entry-reach`。公网 IPv4 不由机器说——是入口看到这次报告从哪来
  （入口前面的 ingress 写进 `X-Forwarded-For` 的那个）；路由器给了映射就用映射的外侧端口。入口对每个地址拨 TCP、
  读到 `SSH-` 横幅、完成密钥交换看到的主机钥匙**就是**入口端口那把才算可达（不登录、不试钥匙，入口 sshd 不记失败）；
  只拨公网单播地址（私网、回环、链路本地、100.64/10、文档段一律不拨——报告不能让入口去扫它自己的网络）；同一台一分钟内只敲一次。
  结果记 `fleet_entry_reach`（地址 · 族 · 端口 · 可达 · 上次成功 · 原因 `timeout` / `refused` / `hostkey` / `not_ssh` / `unreachable`）。
- **`reachable(machine)`**（hub 的 `EntryReachable`）：可达且 15 分钟内查过的地址，IPv4 在前——C7 的地址记录、C9 的选路只读它；
  地址只解析、没人应门或应门的是别的机器，一律不在里面。
- **疑似运营商级 NAT**：路由器外侧地址在 100.64/10 或私网、或与入口看到的出口地址不一致、或经 ingress 看到的来源就在 100.64/10
  ⇒ 回答里 `no_public: cgnat`，体检直说「这台没有公网地址」。
- **体检**：`public` 行（`entry reach --check`，读 `<state>/entry/reach.json`，0644，只有地址与原因）：
  PASS「外面连得上：<地址:端口>（IPv4 / IPv6）」；WARN「外面连不上：<地址> 超时 / 被拒 / 钥匙不符 · 在路由器上把 TCP 22022
  转发到 <内网地址>:22022」，运营商级 NAT 说「这台没有公网地址」，路由器没肯自动开写原因，超过 20 分钟没新结果写「结果过期」。
  入口没开、或没人以这台为家 ⇒ 无此行。现在就查：`sudo fleet-node-supervisor.py entry reach`。
- BREAK-IT：`entry-public-unreachable`（入口那半由 Go 测试对演练里真的入口 sshd 拨号）。

### 你的地址指向你的家（EPIC #3067 C7，#3073）

- **只有入口写记录**：`tokenledger/internal/dns`（provider 接口 List · Upsert · Delete、DNSPod 实现、测试用假实现）。
  记录建在 DNSPod 上已有的 24haowan.com 里（`<名字>.cf`，A / AAAA，TTL 600），不委托、不另开 zone。
  DNSPod 用旧版 token API（`https://dnsapi.cn/`：`Record.List` / `Record.Create` + `Record.Remark` / `Record.Modify` /
  `Record.Remove`）；建时在备注里打 `fleet`，List 只认带它、且在 `cf` 下的——别的记录一条不碰；打不上备注的新记录当场删掉。
- **一个循环**：入口上 `RunEntryDNS`（`internal/leader` 选主 `entry-dns`，只一个副本写）每分钟：每个在用的地址名
  （改名后的旧名留 7 天）的目标 = 它的人的家机器的 `reachable(machine)`（上一节）；与记录现状比对，只写差异
  （每拍至多 40 次写），每写一条记一行入口审计（kind `dns`，「A verky.cf 旧 → 新」）。家从外面连不上（或 15 分钟没新结果）
  ⇒ 一条不改，记录留着最后的地址，钥匙页写「从外面连不上」；手动换家 ⇒ 下一拍改指新家；有人在控制台手改 ⇒ 下一拍改回，
  审计写「有人手改」。DNSPod 报错只记日志（不带凭据），不删记录，下一拍再试。
- **端口不进 DNS**（改约定 3）：两台家机器在同一个路由器后面时地址相同、端口不同（路由器转发到入口的外侧端口，即机器节点路线里的
  `entry=<host>:<port>`——macmini 22122、mini2 22123，没有就是 22022；C6 敲门用的就是它，`public=` 是系统 sshd 的，不读）。钥匙页给 Termius 的「端口」= 家机器的这个端口（`entryPublicPort`：可达的那一行，IPv4 在前），不是常数 22022；
  换家确认时端口变了就写「端口改成 N」。IPv6 在别的端口上应门（不经路由器转发）就不写 AAAA——一个名字只给 Termius 一个端口。
- **凭据**：入口环境 `CCQUOTA_DNS_DP_ID` / `CCQUOTA_DNS_DP_KEY`（`deploy/k8s/overlays/prod/deployment-env.yaml` 从 `new-deploy/acme-dnspod`
  的 `DP_Id` / `DP_Key` 只读引用，`optional: true`）+ `CCQUOTA_DNS_DOMAIN=24haowan.com`、`CCQUOTA_DNS_SUBDOMAIN=cf`。
  缺一样 ⇒ 循环不起、0 次调用。⚠️ 这把 token 与 ACME DNS-01 共用、管整个 DNSPod 账号（不只这一个域名）：轮换它要同时顾到 ACME。
- 查：`dig +short @223.5.5.5 <名字>.cf.24haowan.com`；入口审计里 kind `dns` 的行。BREAK-IT：`entry-dns-follows`。

## 17. 测试机：只跑合并后的列车，机器忙时让路（EPIC #3139 C5，#3144）

每台托管 Mac 最多挂一台 GitHub Actions 测试机，给列车（`release-train.yml`）的 macOS 测试用，
PR 永远不上自家机器。没有 `/var/db/fleet-node/ci.env` = 什么都不做：没有子进程、`state.json`
没有 `ci_runner`、`status` 没有那一行，字节不变。

- **开**：在 root 名下写 `/var/db/fleet-node/ci.env`（root:wheel 0600），首选 GitHub App
  （只装在这个仓库、只有仓库权限 Administration: read and write）：

  ```sh
  sudo install -m 600 -o root -g wheel /dev/stdin /var/db/fleet-node/ci.env <<'X'
  FLEET_CI_REPO=verkyyi/claude-fleet
  FLEET_CI_APP_ID=<App ID>
  FLEET_CI_APP_INSTALLATION_ID=<安装 ID>
  FLEET_CI_APP_KEY_FILE=/var/db/fleet-node/ci-app.pem
  X
  ```

  私钥文件同样 root:wheel 0600。兜底：`FLEET_CI_TOKEN=<只能管这个仓库测试机的细粒度令牌>` 代替三行 App。
  守护（`fleet-node-supervisor.py`）看到它就起 `ci-runner` 子进程（`bin/fleet-ci-runner.py loop`），
  ci.env 一改就重起；删掉它，子进程停、测试机撤下。
- **凭据只在 root 进程内存里**：每趟铸之前用私钥签 JWT（`openssl dgst -sha256 -sign`，RS256，
  exp ≤ 10 分钟）→ 换 1 小时的安装令牌 → `generate-jitconfig`。私钥、JWT、安装令牌、细粒度令牌
  都不进 argv、文件、日志、`fleet-ci` 的环境或任何会话。
- **测试账号 `fleet-ci`**（`FLEET_CI_LOGIN`）：首次由 `sysadminctl -addUser … -shell /usr/bin/false`
  建，非管理员、家目录 0700、隐藏；自己的 uid = 自己的 tmux socket 目录，碰不到任何 fleet 的 socket。
  它在 `tenants` 行里照查（#2842）：一旦能 sudo / 进了 admin 组，测试机拒绝再起（`error`）。
- **测试机本身**：`conf/ci-runner.lock` 钉版本 + 每个平台的 SHA-256（不进 release.json：已装的更新器
  不认识新组件会拒整个发布，制品门也会挡住每次挪 stable）；从 GitHub 下、核对哈希后才解包到
  `<root>/tools/actions-runner/<sha>/`（root 0755）。每趟一份新的拷贝在 `~fleet-ci/runner`，跑完删掉，
  `fleet-ci` 名下剩的进程全杀。
- **一趟**：JIT 配置（标签 `self-hosted` · `macOS` · `ARM64` · `fleet-ci`）只能接一个任务；
  `run.sh` 降权到 `fleet-ci`、`nice 10`、环境从零搭（没有 FLEET_* / CCQUOTA_* / gh 令牌，JIT 配置走
  `ACTIONS_RUNNER_INPUT_JITCONFIG` 不进 argv）。
- **只接列车**：`ACTIONS_RUNNER_HOOK_JOB_STARTED` = root 名下的 `bin/fleet-ci-job-gate.sh`，在任务任何一步
  之前核对 仓库 · 事件（push / workflow_dispatch / schedule）· `refs/heads/master` · 没有 `GITHUB_HEAD_REF` ·
  workflow 在 `FLEET_CI_WORKFLOWS`（默认 `release-train.yml`）里，缺一项就拒。仓库设置仍保持
  「外部贡献者的 workflow 需批准」。
- **让路**：铸下一趟前看 内存压力（≥ warn）· 空闲内存够不够「底线（10% RAM，至少 2 GB）+ 一个会话 1.5 GB
  + 一趟 4 GB」· 每核负载 > 0.75 · 重活槽全满或有人排队——任一项就 `paused:<为什么>`，不铸；等活的空闲
  测试机在机器变紧时撤下、注销；跑着的那趟跑完（上限 `FLEET_CI_MAX_SECS` 3 小时）。
  阈值都可在 ci.env 里改（见 `fleet-ci-runner.py --help`）。
- **看**：`sudo fleet-node-supervisor.py status` 的 `ci-runner` 行；`fleet doctor` 的 `ci-runner` 行
  （idle / busy / paused PASS，error / 循环没在跑 WARN）；入口 `GET /v1/fleet/ci-runners`（管理员）列每台
  机器的状态、是否在线、空闲几台（C6 据此决定上自家机器还是回 GitHub 的机器）。
- **列车怎么挑**（C6，#3145）：每趟车的 `board` 用 `bin/fleet-train-macos.sh pick` 问入口
  `GET /v1/fleet/ci-runners`（仓库密钥 `FLEET_HUB_VIEWER_TOKEN` = 入口的 viewer 令牌；不用 GitHub 管理员令牌）：
  在线且 idle / busy 的有 n 台 ⇒ macOS 段排 `[self-hosted, macOS, fleet-ci]`，min(n, 2) 片、每片 25 分钟上限，
  分片按 `bin/selftest-durations-fleet-ci.txt`（自家机器自己的耗时）；一台没有、入口不通、没设密钥 ⇒
  `macos-latest` 2 片，车照开。`macos-wait`（`… watch`）把每片的机器名和排队时间写进这趟的摘要；
  排给自家机器 20 分钟没开的，写「自家测试机没接」、这趟红并取消。设密钥：
  `gh secret set FLEET_HUB_VIEWER_TOKEN --repo verkyyi/claude-fleet`（粘贴，不进命令行）。
  BREAK-IT：`train-own-runners-gone` · `train-own-runner-silent`。
- BREAK-IT：`ci-runner-hogs` · `ci-runner-pr-code`（`bin/fleet-break-it-ci-selftest.sh`，沙箱里的假 GitHub、
  假测试机包、假测试账号）。
