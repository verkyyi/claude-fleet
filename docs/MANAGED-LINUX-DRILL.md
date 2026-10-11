# fleet-linux-0 真人演练单（EPIC #3208 C7 · issue #3214）

arvin 在 fleet-linux-0 上拿到自己的登录、从电脑和手机连进来、开会话、Claude 答话；
再开一个演练登录、删掉它，确认删干净。**C2（#3210）、C6（#3213）与 C8（#3281，出口护栏）合并、上线、
贴出上线证据后才开练**；在那之前不碰线上这台。

约定：

- 「节点上」= `kubectl -n fleet-workers exec -it fleet-linux-0 -- …`（只动 `fleet-workers`；
  kubeconfig 只在本机私有处）。节点上运行时在 `R=/var/db/fleet-node/runtime/current/bin`。
- 「入口上」= 运维那台电脑上的 `fleet hub …`。
- arvin 的私钥只在他手上：钥匙由他自己在钥匙页加，执行会话不经手。
- 每一步过了，把「记什么」那一栏贴进 issue #3214（`docs/MANAGED-LINUX.md`
  「Acceptance evidence」末尾汇总）。

## 0. 开练前（运维，5 分钟）

| 看 | 命令 | 算过 |
|---|---|---|
| 新运行时在这台 | 节点上 `readlink /var/db/fleet-node/runtime/current` | 等于 `refs/tags/stable` 的提交，且含 C2、C6 |
| 开号开关开着 | 节点上 `grep ACCOUNT_OPS /var/db/fleet-node/machine.env` | `FLEET_NODE_ACCOUNT_OPS=1` |
| 机器健康 | 节点上 `$R/fleet-node-supervisor.py status --check` | 退出 0；pod `Ready` |
| 门开着 | 入口上 `fleet route fleet-linux-0` | 有 `entry` 一行（负载均衡地址:22022）和 `relay` 一行 |

出事看：`kubectl -n fleet-workers describe pod fleet-linux-0`、节点上
`/var/db/fleet-node/logs/`、入口的 `/nodes` 页这台的卡片。

## ① 入口给 arvin 开登录（运维）

```sh
fleet hub accounts assign gh:2987262 --host fleet-linux-0 --login 24haowan
fleet hub accounts            # 隔几十秒看一次
```

- **算过**：arvin 那一行的机器格从 `fleet-linux-0:pending` → `creating` →
  `fleet-linux-0:active:separated`（几分钟内）。节点上
  `$R/fleet-node-linux.py login list` 有 `24haowan <uid≥10002> /home/24haowan ok`。
- **出事看**：一直 `pending` ⇒ 节点程序没报 `CapLoginJoin`（第 0 步的开关、节点程序重载）；
  `--login` 报「login is X, not Y」⇒ 他在入口上的登录名不是 `24haowan`，照提示用
  `relogin`；`:not separated` / `:pending — …` ⇒ 节点上
  `/var/log/fleet-cred/24haowan.log` 与 `/var/db/fleet-node/agent/_machine/account-ops.json`。
- **记**：`fleet hub accounts` 里 arvin 那一行。

## ② arvin 加钥匙、选家（arvin，浏览器）

1. 用**自己的 GitHub** 打开入口的 `/fleet/keys`。
2. 第 3 步把电脑的公钥（`ssh-ed25519 AAAA…`）贴进去，点「加上」→ 看到
   「已加上。家机器正在为你打开入口，约 1 分钟。」
3. （可选，决定走门还是走中转）`/fleet/connection#home`：在 fleet-linux-0 上点「设为家」→
   「换过去」→ 看到「已换家。你的地址几分钟内指向它…」。

- **算过**：钥匙页显示「入口开着，外面连得上。」；换了家的话地址卡写着
  `<名字>.cf.24haowan.com` · 端口 22022 · 用户名 `24haowan`。
- **出事看**：「直连入口还没开」⇒ 入口的 `fleet.entry` 没开；「从外面连不上」⇒ 门不通
  （第 0 步的 `entry` 行），这时电脑仍可走中转，手机不行。
- **记**：家是不是这台（决定下面走门还是走中转——两条都要记一次）。

## ③ arvin 的电脑连进来（arvin，终端）

```sh
fleet connect --pick fleet-linux-0        # 列表里有这台
fleet connect fleet-linux-0 --verbose     # 看选了哪条线
fleet fleet-linux-0                       # 真的连上
```

- **算过**：`--pick` 的 `machines[]` 里有 `fleet-linux-0`；`--verbose` 的表最后一行
  `→ 选中 entry`（以这台为家）或 `→ 选中 relay`（地址写「经入口 …」）；连上后进到看台，
  底栏走中转时写「· 中转」。
- **两条都走一次**：`fleet route fleet-linux-0 entry` 连一次、`fleet route fleet-linux-0 relay`
  连一次，最后 `fleet route fleet-linux-0 auto` 还原。
- **出事看**：arvin 电脑上 `~/.cache/claude-fleet/shell/logs/connect.log`（`pick` /
  `ssh-start` / `relay-open` 几行）；`→ 没有一条线能连通` ⇒ 先看第 0 步的路线。
  门上 *Permission denied* ⇒ 钥匙没加对（回 ②）。
- **记**：两次 `--verbose` 的表各一份（这是指标「从外面进这台机器的路」的读数 2/2）。

## ④ 开会话，Claude 答话（arvin + 运维）

arvin 在看台里开一个新会话（⌘N），问一句「你好，回一句话」。

- **算过**：Claude 答了话。
- **运维核**（节点上，以他的身份）：

  ```sh
  su - 24haowan -c "$R/fleet-cred-proxy.sh route --provider claude"   # relay	trusted + unreachable
  grep '"path":"/v1/messages"' /var/log/fleet-cred/24haowan.log | tail -1
  ```

  最后那行是 `"route":"relay"` · `"status":200`。
- **出事看**：没答话 ⇒ `su - 24haowan -c "$R/fleet-control-read.sh ready"` 里 `creds`
  要是 `true`（不是 ⇒ 账号池没给到这个登录，C3）；代理日志里 4xx/5xx 的那行。
- **记（上线证据）**：arvin 电脑上那个会话的 `tmux capture-pane -p`（问话与回答），
  加代理日志里 `route=relay · 200` 那一行。

## ⑤ 他看不到别人的东西（运维，节点上）

```sh
su - 24haowan -c "bash $R/fleet-tenant-scan.sh"     # 退出 0 = 每项都是 0
$R/fleet-node-supervisor.py tenants --check          # … none admin or sudo-capable
stat -c '%a %U %n' /home/*                           # 每个家都是 700、属主是它自己
su - 24haowan -c 'ls /home/fleet; sudo -n true'      # 两个都被拒
```

- **算过**：扫描退出 0；`tenants` 那行说没有管理员；读 `fleet` 的家与
  `/var/db/fleet-cred/*` 都 Permission denied；`sudo -n` 失败。
- **出事看**：扫描退出 1 时它会打印哪条路还通——这是 BREAK-IT `linux-tenant-cross-read`
  的一条，停下报。
- **记**：扫描的输出。

## ⑤′ 出口护栏（运维，节点上；C8 #3281）

这台碰不到云元数据和集群内网——以 `24haowan` **和** `fleet` 容器里的 root 各跑一遍：

```sh
curl -m3 http://100.100.100.200/                 # 失败（云元数据）
curl -m3 -k https://kubernetes.default.svc       # 失败（集群服务网段）
curl -m3 http://<space 命名空间里一个 pod 的 IP>/   # 失败（pod 网段；IP 由运维在本机 kubectl 查）
iptables -F                                      # root 下也被拒（容器没有 NET_ADMIN）
```

这些照通：

```sh
curl -fsS https://claudefleet.24haowan.com/version
git ls-remote https://github.com/verkyyi/claude-fleet HEAD
getent hosts registry.npmjs.org                  # DNS
```

- **算过**：前四条全失败、后三条全成功；④ 的 Claude 答话本身就证明经凭据代理出去的路还在，
  ③ 的门照进得去。
- **出事看**：`kubectl -n fleet-workers get pod fleet-linux-0 -o jsonpath='{.spec.initContainers[*].name}'`
  有 `egress-guard`、它的日志；元数据通了就是 BREAK-IT `linux-egress-metadata`，**停下报，不往下练**。
- **记**：两种身份下四条失败、三条成功的输出。

## ⑥ 派来的活照跑（运维 / 编排会话）

编排会话派一个小活到这台（落在 `fleet` 上，不在 `24haowan`）：

```sh
FLEET_SPAWN_NODE=fleet-linux-0 dash-issue-session.sh <N>   # 或 --node fleet-linux-0
```

- **算过**：打印 `#N → fleet-linux-0 已开窗 …`，活在 `fleet` 登录上跑完、PR 合并。
- **出事看**：入口派活的排除原因（`not ready: …`）；节点上 `su - fleet -c "$R/fleet-control-read.sh ready"`。
- **记**：那个 PR 的号。

## ⑦ 再开一个演练登录、删掉它（运维）

用一个演练身份（**开练前定好**：一个不是真人的 `gh:` 身份，登录名如 `drill7`）。

```sh
fleet hub accounts assign gh:<演练id> --host fleet-linux-0
fleet hub accounts                                   # 走到 fleet-linux-0:active:separated
# （可选）在它的钥匙页加一把钥匙，让门的钥匙文件先出现
fleet hub accounts remove gh:<演练id> --host fleet-linux-0
fleet hub accounts                                   # remove_pending → removing → 这一格没了
```

节点上逐项核（每项都应「没了」）：

| 什么 | 怎么看 | 算过 |
|---|---|---|
| OS 用户 | `getent passwd drill7` | 空 |
| 家 | `ls -d /home/drill7` · `ls /home/.attic/` | 家没了；attic 里有 `drill7-<UTC>.tar.gz`（root 600） |
| 声明 | `ls /var/db/fleet-node/linux-tenants/` · `cat …/.retired` | 没有 `drill7.json`；它的 UID 在 `.retired` |
| 凭据租户 | `ls /var/db/fleet-cred/drill7 /var/db/fleet-node/logins/drill7.env` | 都不存在 |
| 门的钥匙 | `ls /var/db/fleet-node/entry/keys/drill7` | 不存在（⚠️ 删号程序本身不删它，靠 `node leave` 后下一次拉名单——**要专门看**；还在就是 BREAK-IT `linux-removed-login-lingers`，停下报） |
| 进程 | `pgrep -u <它的 UID>` | 无 |
| 入口上那一行 | `fleet hub accounts` | 演练身份在 fleet-linux-0 上没有格 |

- **出事看**：节点上 `account-ops.json` 里这条 op 的结果；删号最后一行应是 `credsep: purged`。
- **记**：上表逐行的实际输出。

## ⑧ 手机（视 arvin 的家）

只在 arvin 以这台为家时做：照 `/fleet/keys` 的六步——Termius 生成 ED25519 钥匙（Label
`iPhone`）、公钥贴回钥匙页、新建主机（Hostname `<名字>.cf.24haowan.com`，Port 22022，
Username `24haowan`，Key `iPhone`）、连接时信任新主机钥匙、进看台按 `ctrl` `]` `p` 看会话列表。

- **出事看**：*Permission denied* ⇒ 选错钥匙；*timed out* ⇒ 家从外面连不上。
- **记**：手机上看到会话列表（截图由 arvin 发）。

## 收尾：指标逐行读出

| 指标 | 读数从哪来 |
|---|---|
| 这台上真人的登录 | ① 的 `active:separated` + ④ 的回答 → 1 |
| 派活时这台被排除在外 | ⑥ + 入口 24 小时的排除原因计数 |
| 正式版更新后跟上要多久 | 第 0 步的 `current` 对 stable |
| 更新一次被打断的会话 | C4 的读数（本演练不量） |
| 从外面进来的路 | ③ 的两张表 → 2/2 |
| 已知的出事方式 | BREAK-IT 七行（`linux-egress-metadata` · `linux-uid-reuse` · `linux-removed-login-lingers` · `linux-tenant-cross-read` · `linux-entry-weak-door` · `linux-hub-other-root-op` · `linux-image-pins-old`）全绿 → 0（第七行是 C8 新加的） |
