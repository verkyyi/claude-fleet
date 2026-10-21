# 门简化方案：少一层登录（设计；A2 已按第 3 节做完，T647）

issue #4181。只出方案，不改代码、不动线上门和任何 pod；发起人确认后再拆单动手。

## 一句话

推荐 **A2：门只放行跳转**——门不再给每个人开账号、不再拿自己的钥匙替人登录 pod；
它只认「这把钥匙是谁的」，然后只许这条连接打开一条通往**这个人自己 pod 22 端口**的隧道。
真正的登录只在 pod 的 sshd 一处，认的是入口发的同一套东西（这个人的钥匙 / 入口证书）。
门手里不再有能进任何 pod 的钥匙。

## 1. 现在的链路

```
客户端 fleet connect
  │ ① 入口（hub）：POST /v1/fleet/home 挑机器、给路线表 + 主机钥匙；fleet login 发 12 小时证书，
  │    并把本机钥匙登记成「门钥匙」
  ▼
② 门 fleet-door（LoadBalancer 22022，2 副本，FLEET_NODE_PROFILE=door）
  │ sshd：每个人一个门账号（useradd），AllowUsers = 名单，keys/<login> = 入口给的钥匙
  │ 认证：这个人自己的钥匙（不认证书）
  │ ForceCommand bin/fleet-door.sh：读门的书（GET /v1/node/entry-routes：login → u-<nonce>）
  ▼
③ 门再 ssh 一次：ssh <login>@u-<nonce>.fleet-workers.svc:22，用门自己的钥匙（Secret fleet-door）
  │ 带 FLEET_DOOR_FP / SRC / NAME 过去
  ▼
④ pod 的 sshd（容器里 2222，Service 22 → 2222）
  │ 认证：AuthorizedKeysCommand cat /run/fleet-door/door.pub（Secret fleet-door-pub），只认门的钥匙；
  │ 回环地址上（中转）另认入口用户 CA 证书（Match LocalAddress，#4149）
  ▼
⑤ ForceCommand bin/fleet-entry.sh → 看台（tmux）/ 命令 / sftp / shell
```

中转（relay）是另一条：客户端 → 入口 wss → pod 里的 agent → 127.0.0.1:2222 → 同一个 pod sshd，
认入口证书。它本来就只有一层 ssh 登录。

| 层 | 认证 | 配置从哪来 | 谁维护 | 出过的事 |
|---|---|---|---|---|
| ① 入口 | 设备钥匙 / 扫码；签 12h 证书 | 入口数据库 | 入口 | — |
| ② 门 sshd | 这个人的钥匙（keys/<login>） | 入口的门名单（`entryRouteList` ← `EntryHomes`）+ 门自己 useradd | 门的 supervisor（door 模式） | #4157 名单只放「家在 pod 上」的人，先登录后开 pod 的新人永远进不去；#4161 Debian useradd 写 `!`，`UsePAM no` 下锁定账号连公钥也拒，543 次全拒；同单 state 目录 0777 被 StrictModes 拒 |
| ② 门可达 | — | 门自己报 `entry reach`，入口替它续（`doorReachKeep`） | 门 + 入口 | #4112 / #4149 门的可达登记 15 分钟过期，路线表里没有门 |
| ③ 门→pod | 门的钥匙 | Secret `fleet-door`（私钥）与 `fleet-door-pub`（公钥）两份要对上 | 手工（MANAGED-LINUX「The door」） | 换钥匙要两份 Secret + rollout |
| ④ pod sshd | door.pub；回环上加入口 CA | pod-etc 渲染（`pod_sshd_text`） | render.py / fleet-node-linux.py | #4167 缺 AUDIT_WRITE，要终端的登录一律断 |
| ⑤ fleet-entry | — | 运行时 | — | — |

一个人进得来，要 ②③④ 三处各自的账号、钥匙、名单同时对齐；三张单里两张（#4157、#4161）出在只为「门替人再登录一次」而存在的部件上。

另一个问题是**安全**：门的钥匙是所有 pod 都认的万能钥匙。门是唯一对公网开口的部件，攻下它就等于以每个人的身份进每个 pod。

## 2. 三个方案（A 分两种做法）

SSH 协议在加密之前不带「要去哪」，所以「门只做纯转发、认证只在 pod」要么靠 SSH 以外的东西挑目标（A1），要么让门看一眼身份只为挑目标（A2）。两种都列。

### A1 门只做 TLS/SNI 纯转发

客户端把 ssh 包进 TLS（ProxyCommand，SNI = `u-<nonce>`），门是一个不认人的 TCP 转发器，按 SNI 接到对应 pod:22；登录只在 pod sshd，认入口证书。

- 安全边界：门不认人，**任何人都能碰到任何 pod 的 sshd 握手**（认证前的攻击面从 1 个门扩到 N 个 pod）；门手里没有任何凭据。审计只剩 pod 的记录 + 门的「SNI → 源地址」连接日志。
- 改动量：中。门换成一个转发器（新部件）+ TLS 证书；客户端加 TLS 包装；pod sshd 在所有地址认 CA。
- 迁移：新旧门并存（换端口或换 Service），客户端随 stable 换。
- 中转：几乎就是现在中转做的事（中转经入口 wss），两条路认证完全相同。
- **手机 / 裸 ssh 用不了**（Termius、`ssh -p 22022` 不会包 TLS）——入口端口 #3071 的本意之一就是手机能直接进。
- 失败面：最少（转发器 + 证书 + 路由表）。

### A2 门只放行跳转（ProxyJump）——推荐

门 sshd 只有**一个**固定账号 `fleet-jump`（打进镜像，不在运行时 useradd），没有 shell、没有会话：

```
Match User fleet-jump
  AuthorizedKeysCommand <runtime>/bin/fleet-door-keys.py %f    # 读门的书：指纹 → 这个人 → 他的 pod
  AuthorizedKeysCommandUser nobody
  TrustedUserCAKeys <入口用户 CA>                               # 证书也行，主体名 → 这个人
  AuthorizedPrincipalsCommand <runtime>/bin/fleet-door-keys.py --cert %k   # 证书的主体名 → 这个人 → 同样的 permitopen
  PermitTTY no
  ForceCommand /usr/sbin/nologin
  AllowTcpForwarding local
  PermitListen none
  AllowStreamLocalForwarding no
  X11Forwarding no
```

`fleet-door-keys.py` 给每把认得的钥匙输出
`restrict,port-forwarding,permitopen="u-<nonce>.fleet-workers.svc.cluster.local:22" <key>`——
这把钥匙只能开一条通往**它主人自己 pod** 的隧道（一人两 pod 时两条 permitopen，#3562）。
客户端 `ssh -J fleet-jump@<门>:22022 <login>@u-<nonce>.fleet-workers.svc.cluster.local`，
里面那次握手是客户端直接对 pod 做的（端到端加密，门看不见内容）。pod sshd 认这个人的钥匙和入口证书，
**所有地址同一条规则**（中转的回环例外 `Match LocalAddress` 可以删）。

- 安全边界：门只决定「这条连接能通到哪个 pod」，不登录任何地方；**门手里不再有进 pod 的钥匙**
  （删掉 Secret `fleet-door` / `fleet-door-pub`）。pod sshd 只放 `AllowUsers <login>`、只认这个人的钥匙 / 证书。
  门被攻下：能看见谁在连、能拒绝服务，但进不了任何 pod。比现在强一档。
- 审计：门记「指纹 · 来源地址 · 去哪个 pod」（AuthorizedKeysCommand 自己写一行，不依赖 sshd 日志级别）；
  pod 自己从 `ExposeAuthInfo` 看到真实的钥匙指纹（不再靠门转述 `FLEET_DOOR_FP`），来源地址在门的记录里，按时间对。
- 改动量：中。门：一个账号 + 一个查书脚本 + 一段静态配置，删掉 per-login 账号 / keys 目录 / fleet-door.sh。
  pod：sshd 认钥匙表 + CA（钥匙表照「家的入口端口」从入口拉，同一条接口）。入口：pod 家的 entry 路线带上
  `jump` 和 pod 自己的主机钥匙（#4149 已经随心跳上报）。客户端：entry 路线遇到 `jump` 就加 `-J`。
- 迁移：全部可以「先加、后删」，见第 3 节；旧客户端走旧路到删之前一直能用。
- 中转：不受影响；pod 侧规则统一后，中转和门落到同一个认证上。
- 手机 / 裸 ssh：能用，但要写跳板（`ssh -J …`，Termius 有 Jump host）。入口的钥匙页给出可复制的一行。
- 失败面：门上「每人一个账号」这一整类（#4161 锁定、StrictModes、名单漏人里的账号部分）消失；
  门钥匙两份 Secret 对不上消失；`FLEET_DOOR_*` 环境转述消失。剩：一张书（谁的钥匙 → 哪个 pod）、门可达、pod sshd。
  #4157 的名单来源问题仍在，但书只需要「谁有 pod」，不再绑「家在哪」（同时做 C 的那一条）。
  #4167 这类 pod sshd 自身的问题任何保留 sshd 的方案都还在。
- 代价：里面那次握手跨公网，建连多 2–3 个往返（国内到深圳集群几十毫秒级，可接受）；pod 每次启动换主机钥匙，
  客户端必须拿入口给的那份（已有：入口的路线表带主机钥匙，`fleet-connect` 不 TOFU）。

### B 去掉 pod 的 sshd，门直接 exec 进 pod

门用 kubectl exec（或等价的 pods/exec）把连接接到 pod 的容器里跑 fleet-entry.sh。

- 安全边界：门要有 `fleet-workers` 命名空间的 `pods/exec` 权限——**对公网开口的部件拿到进每个 pod（包括共享服务、
  以 root 跑的 sshd 容器）的权限**，比现在的万能钥匙更糟。要以这个人的身份跑，还得在容器里 su，容器要能提权。
- 改动量：大。sftp / scp、pty 尺寸、环境、`ExposeAuthInfo`、信号——sshd 做的会话语义都要重写；kube-apiserver 进入每条连接的路径（可用性、限流）。
- 迁移：pod 去掉 sshd 要重渲染每个 pod；中转（接 127.0.0.1:2222）也要跟着重做。
- 失败面：去掉 pod sshd 一处，换来 apiserver 依赖 + 一套自写会话。
- **不推荐**。

### C 保持两层，配置收敛到入口一处

门名单、门账号、钥匙、pod 的信任都由入口一张表下发：名单从「谁有活的 pod 登录」算（不看家，修 #4157 这一类），
门的 pod 钥匙也由入口签成短期证书（pod 认入口 CA 下的「门」主体），去掉两份 Secret。

- 安全边界：和现在一样（门仍能以任何人进任何 pod，只是钥匙变成短期证书）。
- 改动量：小。
- 迁移：几乎无感。
- 中转：不变。
- 失败面：只少「来源不一致」这一类；每人一个门账号（#4161 类）、两次登录、环境转述都还在。

## 比较

| | 门能进 pod 吗 | 登录次数 | 门上每人账号 | 手机/裸 ssh | 改动 | 去掉的过往故障类 |
|---|---|---|---|---|---|---|
| 现状 | 能（万能钥匙） | 2（门、门替人登 pod） | 有 | 能 | — | — |
| A1 | 不能 | 1 | 无 | **不能** | 中 | #4161 全部、#4157 账号部分、钥匙对齐；但 pod 握手暴露给公网 |
| **A2** | **不能** | 1 次登录 + 门一次只读的身份查验 | **无** | 能（`-J`） | 中 | #4161 全部、#4157（配 C 的名单来源）、钥匙对齐、环境转述 |
| B | 门有 pods/exec | 1 | 无 | 能 | 大 | pod sshd；但新增 apiserver 依赖 |
| C | 能（短期证书） | 2 | 有 | 能 | 小 | #4157 |

## 3. 推荐 A2，分步迁移

原则：每一步只**加**东西，旧路照常；删旧路放最后，按门的记录确认没人再走。每一步之前先写 BREAK-IT 行和演练（CLAUDE.md「新坏法先登记」）。

1. **基线**：国内路径探针（#4150，随 #4904 去掉）当时在 oss-drill 上以演练登录跑一遍，所有路线「通」，存为改动前证据。
2. **pod 侧加信任**（新镜像 + 逐个 pod 重渲染）：pod sshd 在所有地址认「这个人的钥匙表 + 入口 CA」，`door.pub` 照旧也认。
   pod 重渲染会断这个人的会话——和本人约时间，一次一个（先演练登录，再真实用户）。
   BREAK-IT：`pod-foreign-key`（别人的钥匙 / 别人的证书主体进不来）。
3. **门侧加 `fleet-jump`**（门 rollout，2 副本滚动，不碰 pod）：镜像里的账号 + `fleet-door-keys.py` + `Match User fleet-jump`。
   per-login 账号和 fleet-door.sh 不动。BREAK-IT：`door-jump-other-pod`（A 的钥匙要求 permitopen B 的 pod 被拒）、
   `door-jump-shell`（要会话 / 要终端被拒）、`door-jump-unlisted`（书里没有的钥匙 0 次放行）。
4. **入口 + 客户端**：pod 家的 entry 路线加 `jump`（门地址、`fleet-jump`、门主机钥匙）和 pod 自己的主机钥匙；
   `fleet-connect` 见到 `jump` 用 `-J`，没有就走旧路。客户端随 stable；旧客户端不认 `jump`，照旧走门的 per-login 路。
   不带新字段时一字不差（`…OffAddsNothing` 一类的测试）。
5. **验收**（配 #4150 的探针，给它加一层 `jump`）：
   - 国内客户端 `fleet connect` 自动选中 entry 且是跳转路，`hostname` 在 pod 上跑通；`--route entry` / `--route relay` 各通；
     间隔 ≥15 分钟连 3 次；
   - 旧客户端（上一版 stable）仍通；
   - 手机：Termius 配 Jump host 照入口给的一行连上（人工一次）；
   - 门的记录有「指纹 · 来源 · pod」，pod 的 entry.ndjson 指纹对得上；
   - 第 2、3 步的 BREAK-IT 演练全 PASS。
6. **删旧路**（compat-1v，下一批）：门的记录里 per-login 账号的到达连续 N 天为 0（或已逐个通知手机用户换成新一行）后，
   删门的 per-login 账号 / keys 目录 / `fleet-door.sh` / `AcceptEnv FLEET_DOOR_*`、Secret `fleet-door` 和 `fleet-door-pub`、
   pod 的 `door.pub` 挂载和中转的 `Match LocalAddress` 例外；MANAGED-LINUX「The door」改写。
   **已做**。hub 一半（T643，2026-10-20）：pod 的 `entry` 路线只在跳转就绪时发、且必带 `jump`，入口页不再给 pod 家
   `ssh://<login>@<门>` 的码；门上一半（T647，2026-10-20）：per-login 账号、keys 目录、`fleet-door.sh`、
   `AcceptEnv FLEET_DOOR_*`、门进 pod 的钥匙（Secret `fleet-door` 的 `id_ed25519`、`fleet-door-pub`）、pod 的 `door.pub`
   挂载都删了（`Match LocalAddress` 例外 #4193 时已去）；门上只剩 `fleet-jump`，表空时照样监听。Secret 的删法见
   MANAGED-LINUX「The door」：先换门镜像，再删。BREAK-IT `door-account-locked` · `door-strictmodes` · `door-empty-table`
   三行退休（后者的意思并进 `door-wrong-pod`）。

## 4. 待发起人定的

- 是否接受 A2 的代价：手机 / 裸 ssh 要写跳板（`-J`），建连多 2–3 个往返。
- A1 要不要作为以后的一步（只给 fleet 客户端，手机仍走 A2）——本方案不做。
- 第 2 步重渲染真实用户 pod 的时间。

确认后按第 3 节拆单（pod 侧、门侧、入口+客户端、探针、删旧路各一张）。

## 5. 统一地址：门按用户名接到各自的家（A5SQ，设计第 2 版）

所有人在 Termius 里填同一个地址（`ssh.<入口的域名>:22022`）+ 自己的登录名 + 自己的钥匙。SSH 的用户名在
加密建立之后才发，所以按用户名分路 = 门终结这条 SSH；门看得见经它的会话，但**门不持进家的钥匙**：

1. 门用书（`GET /v1/node/entry-routes?home=1` 的 `homes`：家在机器上的人 · 登录名 · 钥匙）认人；
2. 门把手机这次 publickey 登录的签名交给入口（`POST /v1/node/door-session`）。入口按 RFC 4252 §7
   自己重建被签内容（会话标识 · 用户名 · 钥匙），用登记的公钥验，钥匙必须属于「家登录 = 这个用户名」的那一个人，
   会话标识落库去重（`fleet_door_sessions`），才给门这次的临时钥匙签一张门会话证书：一个主体名（家的登录）、
   两分钟、`source-address` 只许回环；门会话 CA 由入口的 SSH CA 派生（`sshca.Derive("door-session")`，
   不另加 Secret），公钥随家的名单下发（`EntryNodeList.door_ca`）；
3. 门开 `GET /v1/node/door-home?principal=` 的流，入口让家里报了 `CapEntryRelay` 的 agent 接本机入口端口
   （`SSHRelayOpen.Target = entry`，端口是 agent 自己的 `FLEET_ENTRY_PORT`），门用那张证书登进去。

门被攻下：只能动那段时间里正经它登录的人；没在登录的人的家进不去（没有他们的签名就没有证书）。
门自己的 SSH 服务器是 `ccquota door`（`tokenledger/agent/door`）：按书核对「钥匙是这个用户名的主人的」才要签名；
签名来自门带的一份 `golang.org/x/crypto/ssh`（`tokenledger/agent/internal/xssh`：上游原样 + `fleet.patch`
加一个 `SignedPublicKeyCallback`；`bin/xssh-sync.sh` 跟上游版本同步，`--check` 核对，维护说明在该目录 README）；
到家那一跳只认入口给的家主机钥匙。每次登录一行审计（来源 · 用户名 · 人 · 指纹 · 家）。

门上的监听由 `FLEET_DOOR_SERVER=ccquota`（`render.py --door-server ccquota`）换成 `ccquota door`，它在同一个端口
照旧承担 pod 的跳转（`fleet-jump`，规则同 `fleet-door-keys.py`）；不设就照旧是 OpenSSH。

分批：①入口 + agent 这一半（本节的三个接口，BREAK-IT `door-session-no-sig` · `door-session-replay` ·
`door-home-not-door`）；②家的本机入口认门会话 CA；③门自己的 SSH 服务器（`ccquota door`）；④网页「手机」页
一行地址；⑤美国侧的门（同名按地区解析）；打洞 / STUN 留作高级。
