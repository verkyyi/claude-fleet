# 故障排查

出问题时先跑体检，再按症状找。体检报的每一行，在本页「体检的每一行」里都有一节（小标题就是行名）：它查的是什么、报 WARN / FAIL 时怎么办。

## 先跑 `fleet doctor`

```sh
fleet doctor                              # 这台电脑、这个登录：一行一项
fleet doctor | grep -E '^ *(WARN|FAIL) '  # 只看要动的
sudo fleet doctor --machine               # 托管机器（装了整机守护的 Mac）的整机那一半
```

每行是 `<级别>  <行名>  <说明>`：

| 级别 | 意思 | 要不要管 |
|---|---|---|
| **FAIL** | 坏了：有会话或整台机器的某件事不工作 | 要修 |
| **WARN** | 会出事，或者没跟上新版本 | 要看；说明里写着下一轮会自己补的，等一轮再看 |
| **INFO** | 提示，只是告诉你现状 | 不用管 |
| **PASS** | 好的 | 不用管 |

退出码就是 FAIL 的个数。几乎每一行的说明里都写着修法（`fix: …` 或一条命令）——**先照说明做**，它比本页更具体。

先修哪个：**先修 FAIL，再看 WARN**；同时有好几行时，先修最底层的——机器上的程序（`tools` `python3` `tmux`）→ 守护与运行时（`daemon` `node` `runtime`）→ 和入口的身份（`cert` `hubauth` `hub`）→ 其余。底层坏了，上面的行多半是跟着红的。

只装了客户端的电脑（只看会话、不跑会话）上，`fleet doctor` 只打 `fleet`（客户端是否跟上稳定版）和 `notify`（系统通知能不能弹）等几行，各行说明即修法。

## 按症状找

### 装不上：找不到 `fleet`、下载不动

- 装完说找不到 `fleet`：命令在 `~/.local/bin/fleet`。开一个新终端窗口；还不行就把 `~/.local/bin` 加进 `PATH`。
- 下载卡住或报证书错误：确认这台电脑能打开入口的地址（自托管只用一台电脑时是 GitHub）。公司网络有代理时，先让 `curl -I <地址>` 通。
- 装在托管机器上：用 `sudo fleet node install --join <加入码>`；同一条命令也是修复，中途失败重跑即可，已经做完的步骤会跳过。

### 登录不上：二维码过期、证书没签下来

- 二维码或登录链接有时效，过期了重新 `fleet login` 拿一个新的。
- 浏览器里点了 **确认签发**，终端还在等：看终端是否连得上入口（`fleet doctor` 的 `cert` `hubauth` 两行）。
- 连接证书 12 小时有效、到期自动续；续不上时 `cert` 行会报出来，`fleet login` 重签一次。

### 连不上机器、看不到别的机器的会话

- 看 `hub-sessions` `hubauth` `peerlink` 几行：入口在不在、令牌认不认、机器间链路通不通。
- 机器在入口的「机器」页显示「维护中」或「失联」：维护中是管理员手动设的，不会往那台派会话；失联要先让那台机器重新上线。

### 看台起不来、一起来就退出

- 电脑上的 `fleet`：家机器连得上、看台却连续 3 次没起来（或起来不到一分钟就退出），就不再重连，直接把你放到家机器的命令行，并说一行为什么；在那里输入 `exit` 回看台。
- 手机 / ssh App 走入口端口：看台意外退出（不是你自己离开）时留在家机器的命令行，不断开；输入 `fleet` 回看台。
- 排查看那台机器的 `~/.config/claude-fleet/logs/`。
- 三条退路（⌃\、自动落到命令行、`fleet shell`）合在一页：[看台出问题时](view-trouble.md)。

### 会话停了、没反应

- 先看它是不是在等你：⌘P 面板「在等你的」一栏。
- 窗口显示恢复页（会话退出了）：按 ↵ 接着原来的对话，`r` 开一个新的。
- 新会话开不出来、一直排队：看 `admit` `memory` `machine` 三行——多半是这台电脑内存或负载到线了，已有会话不受影响，空出来就会开。
- 会话说额度用完：订阅满了由池子换到下一个订阅（有的话），会话不用挪；会话自己的剩余 % 在看台顶上一行。

### 「这台是客户端，任务在托管节点上跑」

- fleet 里的电脑分三类：**客户端**（你用的终端：连接、看、开窗）、**入口**（hub）、**托管节点**（托管机上的登录、集群里的执行 pod）。只有托管节点跑任务。
- 入口把这台记成了客户端，所以 `fleet-repo.sh add`、`fleet host on`、在这台开会话都会被拒。任务照常开：入口会把它派到托管节点上，你在这台看、在这台接着聊。
- 这台确实该跑任务（比如它就是一台托管机）：请管理员在入口改它的类型。

### GitHub 连不上的时候

GitHub 在 fleet 里只做一件事：放代码和 PR。任务、会话、订阅和看台都走入口（hub），所以 GitHub 不通时大部分照常，只有和代码交付有关的几步在等。

**照常：**

- **任务**：⚡ 行派任务、任务页、T 号记录都在入口上，不受影响。
- **会话**：已经在跑的会话照常干活；新会话照常开——先花最多 20 秒去 GitHub 拿最新的主分支，拿不到就从这台机器上次拿到的那一版开出来。
- **订阅与凭据**：会话用的订阅凭据由入口发，额度读数也来自入口。
- **看台**：⌘P 面板、切换会话、回答问题、手机上接着看，都走入口和机器之间的连接。

**在等：**

- **推送代码、开 PR、看 CI、合并**：这几步要 GitHub。会话会说它在等 GitHub；门禁的读数是「还不确定」，不算失败，不会被当成红。
- **主分支跟进**：机器上的主分支暂时停在上次拿到的那一版。
- **任务页上的「等待 GitHub」**：PR 还没确认合并时，工作结果旁显示这一句。这不需要你处理。

**通了以后自动接上：**

- 后台每分钟把主分支快进到 GitHub 上的最新版。
- 在等门禁的会话再读一次就拿到结果，绿了照常合并；合并后的清理（关窗口、收 worktree）由后台照常做完。
- 「等待 GitHub」在 PR 确认合并后自己消失。

体检的 `gh` 行只说这台机器的 `gh` 装没装、登没登录，不说 GitHub 此刻通不通。

### 把诊断信息发给管理员

```sh
fleet doctor --json
```

把输出发给管理员即可——每一行的级别、名字和说明都在里面。

## 体检的每一行

按「先修哪一层」排。每节开头写着它来自 `fleet doctor` 还是 `fleet doctor --machine`。体检新加了一行而本页还没有，仓库的自测会提醒；`bin/docs-build.sh --troubleshooting-skeleton` 打出缺的那几节的骨架。

### 机器上的程序

#### `tools`

来自 `fleet doctor`。

- **是什么**：后台服务只有最基本的 `PATH`（`/usr/bin:/bin`），这一行查它们找不找得到 `tmux` `claude` `python3` 等程序。
- **WARN / FAIL 怎么办**：FAIL 点名找不到的那几个：装上它，或照说明在配置里写明它的路径。

#### `python3`

来自 `fleet doctor`。

- **是什么**：fleet 的很多脚本要 Python 3。
- **WARN / FAIL 怎么办**：FAIL = 没装。macOS 装 Xcode 命令行工具（`xcode-select --install`）或 `brew install python`；Linux 用系统的包管理器装。

#### `tmux`

来自 `fleet doctor` 和 `fleet doctor --machine`。

- **是什么**：每个会话是一个 tmux 窗口，要 tmux 3.2 以上。
- **WARN / FAIL 怎么办**：FAIL = 没装或太旧：`brew install tmux`（Linux 用包管理器）。托管机器上的 tmux 由更新器按发布版装，等它下一轮（约 5 分钟）。

#### `fzf`

来自 `fleet doctor`。

- **是什么**：节点上还会打开的选择框（添加仓库）要 fzf 0.59 以上。
- **WARN / FAIL 怎么办**：`brew install fzf`（或包管理器）。只用新客户端（⌘P）的话不影响会话本身。

#### `perl`

来自 `fleet doctor`。

- **是什么**：转圈动画用到 Perl 的 Time::HiRes。
- **WARN / FAIL 怎么办**：WARN 只是动画按整秒转，可以不管；要修就装上 Time::HiRes。

#### `gh`

来自 `fleet doctor`。

- **是什么**：会话推代码、开 PR、看 CI、合并都用 GitHub 命令行 `gh`。
- **WARN / FAIL 怎么办**：FAIL = 没装：`brew install gh`；WARN = 没登录：`gh auth login`。不碰 GitHub 仓库的话可以不管。

#### `claude`

来自 `fleet doctor` 和 `fleet doctor --machine`。

- **是什么**：Claude Code 命令行在不在。
- **WARN / FAIL 怎么办**：装上 Claude Code 并用订阅登录一次。托管机器上它由发布版钉住、更新器装，等下一轮。

#### `codex`

来自 `fleet doctor` 和 `fleet doctor --machine`。

- **是什么**：Codex 命令行在不在、版本对不对。只用 Claude 的话它是可选的（INFO）。
- **WARN / FAIL 怎么办**：照说明升级或重装；托管机器上由更新器装。

#### `brew`

来自 `fleet doctor`。

- **是什么**：Homebrew 的目录归不归这个登录，装不装得了东西。
- **WARN / FAIL 怎么办**：照说明里的命令修目录权限。

#### `tls`

来自 `fleet doctor`。

- **是什么**：Python 能不能验证入口的 HTTPS 证书。
- **WARN / FAIL 怎么办**：装上 CA 证书（`pip3 install certifi`，或用系统自带的 python3）。公司网络做了 HTTPS 中间人时，把公司的根证书加进系统。

#### `testtmux`

来自 `fleet doctor`。

- **是什么**：自测留下、没清掉的 tmux 服务器和死掉的 socket 文件。
- **WARN / FAIL 怎么办**：照说明里的命令清掉；不影响正在跑的会话。

### 守护与运行时

#### `node`

来自 `fleet doctor`。

- **是什么**：托管机器上那个整机守护（`com.claude-fleet.node`）在不在跑、入口认不认它。
- **WARN / FAIL 怎么办**：没在跑：系统几秒内会把它拉起来，不起就重跑 `sudo fleet node install`。入口拒绝某个登录：照说明重新加入。说没有「完全磁盘访问」：在 系统设置 → 隐私与安全性 → 完全磁盘访问 里给它打勾。

#### `daemon`

来自 `fleet doctor --machine`。

- **是什么**：整机守护装了没有、在不在跑、换版后有没有重启到当前版本。
- **WARN / FAIL 怎么办**：重跑 `sudo fleet node install`（同一条命令也是修复）。

#### `child`

来自 `fleet doctor --machine`。

- **是什么**：整机守护拉起的子服务（凭据代理、节点程序等）有没有挂。
- **WARN / FAIL 怎么办**：守护会自己退避重启；一直起不来就看 `sudo fleet-node-supervisor.py status` 和它的日志，再重跑 `sudo fleet node install`。

#### `runtime`

来自 `fleet doctor --machine`。

- **是什么**：托管机器的运行时（所有登录共用的那份程序）是不是一个完整的发布版。
- **WARN / FAIL 怎么办**：WARN「没有运行时」= 这台不是托管机器，不用管。FAIL：重跑 `sudo fleet node install`，或等更新器回滚到上一版。

#### `update`

来自 `fleet doctor`。

- **是什么**：整机更新器最近一轮的结果。
- **WARN / FAIL 怎么办**：看 `/var/log/fleet-node/update.log` 和 `sudo fleet doctor --machine`。换版后多出 FAIL 时，更新器会自己退回上一版，不用手动回退。结果是 `refused`：入口给的目标比正在跑的版本旧（入口的 stable 被回退了），机器只往前走、留在当前版本——等下一版，或确要回退时在那台机器上设 `FLEET_NODE_UPDATE_BACKWARD=1`。

#### `install`

来自 `fleet doctor` 和 `fleet doctor --machine`。

- **是什么**：这个登录的 fleet 是不是稳定版、有没有本地改动；托管机器上还查它是否链到当前发布版。
- **WARN / FAIL 怎么办**：落后：等自动同步，或 `fleet update`。有本地提交或分叉：说明里写着哪些提交，挪走后同步才会继续。不要在会话里手动同步安装。

#### `login-tree`

来自 `fleet doctor --machine`。

- **是什么**：每个登录的 `~/.claude/fleet` 指向的发布版还在不在。
- **WARN / FAIL 怎么办**：更新器下一轮重建链接；急的话重跑 `sudo fleet node install`。

#### `account`

来自 `fleet doctor` 和 `fleet doctor --machine`。

- **是什么**：本机：订阅令牌文件是否齐全、权限是否只有自己可读。整机：每个账号的 claude · codex · tmux 是否链到发布版。
- **WARN / FAIL 怎么办**：令牌文件权限：`chmod 600 <文件>`；令牌空了：`claude setup-token` 重领。整机那半：更新器下一轮重链。

#### `account-pool`

来自 `fleet doctor`。

- **是什么**：这个登录的账号目录里有池子的账号（`hub:` 开头），但这个登录还没做凭据隔离（没有 `credsep.json`）。开会话不再在本机账号里挑（T550）：没有代理替它挑，会话用的是这个登录自己登着的账号。
- **WARN / FAIL 怎么办**：把这个登录交给池子：`fleet-credsep.sh` 做凭据隔离（托管机器上运维的 credsep-enforce 会自己收进来）。

#### `cache`

来自 `fleet doctor --machine`。

- **是什么**：给新账号用的那份 Claude Code 是不是发布版钉的版本。
- **WARN / FAIL 怎么办**：更新器下一轮补上。

#### `helper`

来自 `fleet doctor --machine`。

- **是什么**：某个部件缺它的帮手程序。
- **WARN / FAIL 怎么办**：更新器下一轮补上。

#### `ccquota`

来自 `fleet doctor --machine`。

- **是什么**：发布版里的 ccquota（节点程序）是不是那次提交构建的。
- **WARN / FAIL 怎么办**：FAIL = 发布版带错了 ccquota：按稳定版重新部署入口，再发下一版。WARN 是老发布版核对不了，下一版就好。

#### `key`

来自 `fleet doctor --machine`。

- **是什么**：机器钉住的发布签名公钥，和当前发布版的签名对不对得上。
- **WARN / FAIL 怎么办**：WARN 没钉：`sudo fleet node install` 钉上。FAIL 对不上：不要强行用这一版——确认签名钥匙是否换过，换过就 `sudo fleet node install --release-key <公钥文件>`。

#### `codesign`

来自 `fleet doctor --machine`。

- **是什么**：节点程序有没有固定的签名身份；有了它，macOS 的隐私授权换版后还有效。
- **WARN / FAIL 怎么办**：更新器下一轮补签；之后在 系统设置 → 隐私与安全性 里给它授权一次。

#### `admin-agent`

来自 `fleet doctor --machine`。

- **是什么**：管理员登录里那个负责开号的节点程序是不是发布版、换版后重启过没有。
- **WARN / FAIL 怎么办**：更新器下一轮把它指向发布版并重启；不重启就照说明手动重启它。

#### `shell`

来自 `fleet doctor --machine`。

- **是什么**：被接管的登录里有没有残留的客户端外壳或登录钩子。
- **WARN / FAIL 怎么办**：照说明清掉；客户端外壳只该装在人用的电脑上。

#### `drill`

来自 `fleet doctor --machine`。

- **是什么**：当前发布版带着「故意失败」的演练标记。
- **WARN / FAIL 怎么办**：这是演练，更新器会自己回滚，不用动。

#### `versions`

来自 `fleet doctor --machine`。

- **是什么**：机器上留着几个发布版、占多少磁盘。
- **WARN / FAIL 怎么办**：WARN = 比平常多：更新器会清掉用不到的，看 `update.log` 里为什么没清。

#### `image`

来自 `fleet doctor --machine`。

- **是什么**：只在个人 pod 这类「运行时归镜像」的机器上有：它没有更新任务，只有 pod 被滚到新镜像才会跟上 stable；这一行拿入口的 stable 比本机运行时。
- **WARN / FAIL 怎么办**：WARN = 落后 stable、本机不会自己追上：集群有开号执行器时入口会自动滚（`roll-user-pod`）；没有的话照提示用 `render.py --image-patch` 换成 stable 那一版的节点镜像，再 `kubectl patch deploy <pod>`。

#### `credpool`

来自 `fleet doctor --machine`。

- **是什么**：整机共享的订阅凭据池是否正常。
- **WARN / FAIL 怎么办**：照说明修。

#### `seats`

来自 `fleet doctor`。

- **是什么**：整机服务、管理服务是不是跑在 root 或专门的角色账号里，而不是哪个人的登录里。
- **WARN / FAIL 怎么办**：FAIL：重跑 `sudo fleet node install` 把它收回；`sudo fleet-node-supervisor.py seats --json` 看是哪一个。

#### `tenants`

来自 `fleet doctor`。

- **是什么**：被接管的登录有没有管理员权限或 sudo。它们不该有。
- **WARN / FAIL 怎么办**：FAIL：把这个登录移出 admin 组和 sudoers。

#### `rootlog`

来自 `fleet doctor`。

- **是什么**：root 服务的日志是不是写进了某个人的家目录。
- **WARN / FAIL 怎么办**：重跑 `sudo fleet node install` 把日志挪到系统日志目录。

#### `services`

来自 `fleet doctor`。

- **是什么**：登记过的常驻服务有没有挂，有没有手写的启动项。
- **WARN / FAIL 怎么办**：`fleet ls --services` 看是哪一个；手写的启动项删掉，改用 fleet 登记。

#### `daemons`

来自 `fleet doctor`。

- **是什么**：这个登录的定时服务是不是都按时在跑。
- **WARN / FAIL 怎么办**：说明里点名没跑的那个：重跑安装，或看它的日志。

#### `basesync`

来自 `fleet doctor`。

- **是什么**：把仓库主目录保持在最新的那个服务装了没有。
- **WARN / FAIL 怎么办**：重跑安装（托管机器：`sudo fleet node install`）。

#### `cleanup`

来自 `fleet doctor`。

- **是什么**：合并后收尾（收窗口、收工作副本）的服务装了没有、能不能读 PR 状态。
- **WARN / FAIL 怎么办**：重跑安装；说缺 `gh` 就装 `gh` 并 `gh auth login`。

#### `ledger`

来自 `fleet doctor`。

- **是什么**：记下每个关掉的会话、以便以后接着做的服务装了没有。
- **WARN / FAIL 怎么办**：重跑安装。

#### `collect`

来自 `fleet doctor`。

- **是什么**：采集服务（给列表和面板供数据）最近一轮有没有按时跑完。
- **WARN / FAIL 怎么办**：卡住或超时：说明里写着最慢的一步；它下一轮会自己顶掉卡住的那轮。一直卡就看它的日志。

#### `state`

来自 `fleet doctor`。

- **是什么**：会话状态对账（谁在干活、谁空闲）有没有在跑、判得准不准。
- **WARN / FAIL 怎么办**：看状态对账服务（`com.claude-fleet.reconcile`，Linux 上 `claude-fleet-reconcile.timer`）在不在跑和它的日志（`logs/reconcile.launchd.log`）。

#### `metrics`

来自 `fleet doctor`。

- **是什么**：每分钟记一行机器指标（出事后用来复盘）。
- **WARN / FAIL 怎么办**：5 分钟没有新行 = 磁盘守护服务没在跑：重跑安装。

#### `ci-runner`

来自 `fleet doctor`。

- **是什么**：这台机器上的自托管 CI 跑机（只有配了才有这一行）。
- **WARN / FAIL 怎么办**：看 `sudo fleet-node-supervisor.py status` 的 ci-runner 一行和它的日志。

### 和入口的身份与连接

#### `cert`

来自 `fleet doctor`。

- **是什么**：你的连接证书有没有、过没过期、入口认不认。
- **WARN / FAIL 怎么办**：`fleet login` 重签；机器上则重跑 `fleet node install --join <加入码>`。

#### `background`

来自只当客户端用的电脑上的 `fleet doctor`。

- **是什么**：没人在看时 fleet 还在后台跑的进程（旧客户端留下的、断掉的客户端留下的 ssh 主连接）有几个，以及升级后留在安装目录旁边的多余文件（超过「当前 + 上一版」的版本目录、没收尾的临时目录）有几个。三个都是 0 才 PASS。
- **WARN 怎么办**：`fleet quit` 收掉后台进程；多余文件下次打开 `fleet` 时自动清。你自己放进安装目录、或改过的文件不算多余，升级也不会删。

#### `hubauth`

来自 `fleet doctor`。

- **是什么**：入口认不认这台机器的令牌。
- **WARN / FAIL 怎么办**：查 `node.env` 里的令牌是否被换掉；`fleet login`，或在入口的「机器」页重新拿加入码加入。

#### `hub`

来自 `fleet doctor`。

- **是什么**：这台对入口的几处设置是否一致，侧栏用什么身份问入口。
- **WARN / FAIL 怎么办**：说两处不一致：`fleet-conf.sh migrate` 合成一份（同步时也会自动跑）。说问不了入口：`fleet login`。

#### `hub-sessions`

来自 `fleet doctor`。

- **是什么**：别的机器上的会话列表有没有在刷新。
- **WARN / FAIL 怎么办**：照说明修：入口在不在、令牌对不对。

#### `hub-image`

来自 `fleet doctor`。

- **是什么**：入口跑的版本和稳定版是不是同一次提交。
- **WARN / FAIL 怎么办**：落后或分叉：按稳定版重新部署入口，或等下一次发版。

#### `personcert`

来自 `fleet doctor`。

- **是什么**：机器上的服务是不是在用某个人的登录证书。机器只该用自己的令牌。
- **WARN / FAIL 怎么办**：查 `node.env` 与凭据代理，让机器用自己的令牌。

#### `compute`

来自 `fleet doctor`。

- **是什么**：入口能不能往这台派会话。只报状态。
- **WARN / FAIL 怎么办**：不想让入口往这台派，在 `node.env` 里写 `CCQUOTA_FLEET_COMPUTE=0`。

#### `承载`

来自 `fleet doctor`。

- **是什么**：这台电脑自己跑不跑会话，令牌在不在。
- **WARN / FAIL 怎么办**：照说明修令牌；要它跑会话：`fleet host on`（入口记为客户端的电脑会被拒——只有托管节点跑会话）。

#### `可信`

来自 `fleet doctor`。

- **是什么**：入口把这台当不当可信机器。不可信的机器拿不到订阅凭据，会话走中心代理。
- **WARN / FAIL 怎么办**：WARN = 会话用不上订阅：入口管理员把这台标成可信。

#### `能力`

来自 `fleet doctor`。

- **是什么**：这台是什么角色（只看 / 也跑会话），配置是不是只有一份。
- **WARN / FAIL 怎么办**：还在读旧配置文件：`fleet-conf.sh migrate` 合成一份。

#### `mode`

来自 `fleet doctor`。

- **是什么**：本机模式（不连入口）还是联机模式。只报状态。
- **WARN / FAIL 怎么办**：不用管。

#### `dist`

来自 `fleet doctor`。

- **是什么**：这个登录的新版本从哪里拿。连着入口时应该从入口拿。
- **WARN / FAIL 怎么办**：照说明改回从入口拿。

#### `agent`

来自 `fleet doctor`。

- **是什么**：这台机器上各个登录的节点程序是不是稳定版。
- **WARN / FAIL 怎么办**：照说明里的命令先 `--dry-run` 看一遍，再逐个重启。

#### `agentdup`

来自 `fleet doctor`。

- **是什么**：同一个登录跑了不止一个节点程序，它们会互相顶掉和入口的连接。
- **WARN / FAIL 怎么办**：照说明里的命令经启动项重启，只留一个。

#### `peerlink`

来自 `fleet doctor`。

- **是什么**：机器之间的链路（看别的机器上的会话用）通不通。
- **WARN / FAIL 怎么办**：`fleet-peerlink.py status` 看最近几次重建和原因。

#### `releasekey`

来自 `fleet doctor`。

- **是什么**：这台电脑上有没有发布签名私钥（环境变量、配置目录、`~/.ssh`、`~/.config` 里）。私钥只该在发布列车里，机器只认离线根钥匙和它背书的钥匙。
- **WARN / FAIL 怎么办**：删掉说明里点名的那份私钥；怀疑已经泄露，就请管理员用根钥匙签一张作废单（运维文档「发布签名」）。

要查看认的公钥，运行 `~/.claude/fleet/bin/fleet-release-key.sh status`。指纹不同但担保链认可时，会显示「下次取版本自动重钉到根」并成功退出，无需手工重认；未知或已作废的担保链仍报错。托管或跟随机器运行时的登录以机器级 `/var/db/fleet-node/release.pub` 为准，登录级 pin 不起作用。此命令只查看，不改钥匙。

#### `entry`

来自 `fleet doctor`。

- **是什么**：这台机器的入口端口（成员直接 ssh 进来用的那个）名单是否最新、配置是否被系统接受。
- **WARN / FAIL 怎么办**：照说明重新拉一次名单；看 `sudo fleet-node-supervisor.py status` 的 entry 一行。

#### `public`

来自 `fleet doctor`。

- **是什么**：从外面能不能连到这台的入口端口。
- **WARN / FAIL 怎么办**：查路由器的端口转发、公网地址，以及主机钥匙是否对得上；`sudo fleet-node-supervisor.py entry reach` 再测一次。

#### `onboard`

来自 `fleet doctor`。

- **是什么**：新装好的这台能不能开出第一个会话（就绪检查）。
- **WARN / FAIL 怎么办**：照说明修。

#### `firstrun`

来自 `fleet doctor`。

- **是什么**：首次运行要的几样东西是否齐全。
- **WARN / FAIL 怎么办**：照说明修。

#### `fleet`

来自 `fleet doctor`。

- **是什么**：客户端是不是稳定版；常驻服务有没有还跑着换版前的程序。
- **WARN / FAIL 怎么办**：客户端落后：`fleet update`。服务没重启：照说明里的命令重启它们。

#### `team`

来自 `fleet doctor`。

- **是什么**：入口下发的团队设置（共享的 MCP、技能、设置）同步到这台了没有。
- **WARN / FAIL 怎么办**：`fleet-agent-team.py sync`；节点程序每一拍也会重试。

#### `roles`

来自 `fleet doctor`。

- **是什么**：角色定义能不能从入口取到。
- **WARN / FAIL 怎么办**：`fleet-agent-team.py sync`；取不到时会话照用本机那份，不影响开会话。

### 订阅与额度

#### `modelcap`

来自 `fleet doctor`。

- **是什么**：状态对账每分钟探一次各 fleet 有没有会话撞了单个模型的上限（撞了就原地换到备用模型）；这一探连续超时，撞墙的会话就没人发现。
- **WARN / FAIL 怎么办**：照行内的步骤名查是哪一步慢；必要时调高 `FLEET_MODELCAP_PROBE_BUDGET`。

#### `cred`

来自 `fleet doctor`。

- **是什么**：会话的订阅凭据走哪条路（中心代理还是本机），通不通。
- **WARN / FAIL 怎么办**：照说明修中转或凭据代理。

#### `credsep`

来自 `fleet doctor` 和 `fleet doctor --machine`。

- **是什么**：凭据隔离：会话读不到订阅的密钥，全靠一个代理替它带上。
- **WARN / FAIL 怎么办**：代理没起：照说明启动或重跑安装。整机代理跑的不是这一版：`sudo fleet-credsep.py machine refresh`（更新器每轮也做）。

#### `credsep-all`

来自 `fleet doctor`。

- **是什么**：这台机器上所有托管登录是不是都做了凭据隔离。
- **WARN / FAIL 怎么办**：FAIL 点名没隔离的登录：管理员执行说明里的 `fleet-credsep.sh machine install --logins managed`。

#### `credsep-logins`

来自 `fleet doctor`。

- **是什么**：这台托管机器上每个 fleet 登录是不是都做了凭据隔离。机器守护每 5 分钟自己补一次（`credsep-enforce`），不用谁敲 sudo；没隔离的登录入口一份凭据都不发。
- **WARN / FAIL 怎么办**：FAIL 点名还没隔离的登录和守护最后一次的原因（比如它的会话还在直接读凭据文件）。等下一轮守护；急的话管理员执行说明里的 `fleet-credsep.sh machine install --logins <登录>`。

#### `credproxy`

来自 `fleet doctor`。

- **是什么**：这台机器上是不是只有一个凭据代理（共享代理），所有登录都是它的租户。
- **WARN / FAIL 怎么办**：FAIL 点名共享代理之外还在跑的代理（登录 · pid）：它们各留一份订阅副本，入口删掉的订阅会留在那里、会话收到 401。管理员执行说明里的 `fleet-credsep.sh machine install --logins managed`，把它们并进共享代理。

### 会话

#### `admit`

来自 `fleet doctor`。

- **是什么**：新会话的「放不放行」：看这台还剩多少内存、负载多高，装不下就让新会话排队。
- **WARN / FAIL 怎么办**：WARN 正在拦：等内存空出来，或关掉几个不用的会话；已有会话不受影响。说「一道门都没有」：至少开一种上限（默认的内存放行就够）。

#### `machine`

来自 `fleet doctor`。

- **是什么**：整台机器的负载、有没有失控的孤儿进程、会话总数。
- **WARN / FAIL 怎么办**：负载过高：`fleet-diskguard.sh --orphans` 点名失控的进程，停掉它们。

#### `memory`

来自 `fleet doctor`。

- **是什么**：内存压力。压力高时系统在回收内存，再久一点机器可能卡死。
- **WARN / FAIL 怎么办**：`fleet-memguard.sh --once --dry-run` 看内存守护会停掉谁；关掉不用的会话。

#### `cpu`

来自 `fleet doctor`。

- **是什么**：Linux 容器里的 CPU 是否顶到上限（被限流）。
- **WARN / FAIL 怎么办**：调大这台 Linux 节点的 CPU 限额，或少开几个会话。

#### `files`

来自 `fleet doctor`。

- **是什么**：整机打开的文件数占系统上限多少。满了谁都打不开文件。
- **WARN / FAIL 怎么办**：找出开文件最多的进程（`lsof | awk '{print $1}' | sort | uniq -c | sort -n | tail`），必要时调高系统上限。

#### `pty`

来自 `fleet doctor`。

- **是什么**：整机在用的终端数占系统上限多少。满了开不出新窗口。
- **WARN / FAIL 怎么办**：关掉用不到的终端和会话；必要时调高系统上限。

#### `nofile`

来自 `fleet doctor`。

- **是什么**：系统默认的单进程打开文件上限。只报状态。
- **WARN / FAIL 怎么办**：不用管：fleet 的服务会自己调高。

#### `reap`

来自 `fleet doctor`。

- **是什么**：有没有该收没收的会话（PR 合了、早就空闲了）。
- **WARN / FAIL 怎么办**：照说明里的命令看每个为什么还留着；在干活、有后台任务的会话不会被收。

#### `context`

来自 `fleet doctor`。

- **是什么**：会话上下文满了自动压缩后，有没有接着做。
- **WARN / FAIL 怎么办**：说压缩后没续跑：到那个会话里说一句「继续」；反复出现就把说明里的记录发给管理员。

#### `handoff`

来自 `fleet doctor`。

- **是什么**：上下文快满时提醒会话交接的那套机制在不在工作。
- **WARN / FAIL 怎么办**：照说明修；多数是安装不完整，同步一次就好。

#### `statusln`

来自 `fleet doctor`。

- **是什么**：会话的状态读数（剩余上下文、模型）有没有送上来。
- **WARN / FAIL 怎么办**：缺 `jq`：`brew install jq`。有窗口没读数：重开那几个窗口。

#### `mod`

来自 `fleet doctor`。

- **是什么**：Claude Code 的 fleet 扩展装了没有。
- **WARN / FAIL 怎么办**：扩展目录不在：下一次同步补上。

#### `hooks`

来自 `fleet doctor`。

- **是什么**：Claude Code 的 `settings.json` 里 fleet 的钩子是否齐全。
- **WARN / FAIL 怎么办**：照说明里的命令合并一次（同步时也会做）。

#### `settings`

来自 `fleet doctor`。

- **是什么**：Claude Code 的默认设置是否缺键。
- **WARN / FAIL 怎么办**：下一次同步补上；只补缺的，不改你已有的。

#### `agents`

来自 `fleet doctor`。

- **是什么**：默认的 MCP 服务和技能是否齐全。
- **WARN / FAIL 怎么办**：下一次同步补上；只补缺的，不改你已有的。

#### `agentcfg`

来自 `fleet doctor`。

- **是什么**：换版后，老会话启动时读到的钩子和工具还在不在。不在的老会话会坏。
- **WARN / FAIL 怎么办**：照说明里的命令点名这些会话，逐个重开（↵ 会接着原来的对话）。

#### `agentdef`

来自 `fleet doctor`。

- **是什么**：这个版本的 Claude Code 支不支持按「代理文件」启动会话。
- **WARN / FAIL 怎么办**：`claude update`；托管机器等更新器跟上发布版。

#### `commands`

来自 `fleet doctor`。

- **是什么**：fleet 的斜杠命令装了没有。
- **WARN / FAIL 怎么办**：下一次同步补上，或在 Claude Code 里 `/plugin install fleet@claude-fleet`。

#### `skills`

来自 `fleet doctor`。

- **是什么**：几个技能依赖的东西在不在（交接的基础技能、文档预览要的 tailscale）。
- **WARN / FAIL 怎么办**：同步一次；用文档预览就装上 tailscale。

#### `plugins`

来自 `fleet doctor`。

- **是什么**：fleet 的 Claude Code 插件是不是最新。
- **WARN / FAIL 怎么办**：`claude plugin update <插件>`，或等下一次同步。

#### `mcp`

来自 `fleet doctor`。

- **是什么**：会话启动时带哪些 MCP 服务。没写白名单时每个会话都带上你装的全部，吃内存。
- **WARN / FAIL 怎么办**：给这个 fleet 写一份 MCP 白名单（说明里写着键名）。

#### `信任框`

来自 `fleet doctor`。

- **是什么**：新会话会不会停在 Claude Code 的「是否信任此文件夹」。只报状态。
- **WARN / FAIL 怎么办**：不用管；新会话停在那里时点一下「信任」即可。

#### `trust`

来自 `fleet doctor`。

- **是什么**：仓库目录有没有被 Claude Code 预先信任。没有的话，新会话会停在信任对话框上。
- **WARN / FAIL 怎么办**：照说明里的命令授信。

#### `seed`

来自 `fleet doctor`。

- **是什么**：新会话的第一句话怎么来。只报状态。
- **WARN / FAIL 怎么办**：不用管。

#### `timing`

来自 `fleet doctor`。

- **是什么**：最近 10 次按 ⌘P 到面板弹出、开新会话到能打字，各要多久（中位数）。面板该在 0.5 秒内，新会话该在 8 秒内。
- **WARN / FAIL 怎么办**：`fleet_timing.py table` 看慢在哪一段，发给管理员。

#### `alerts`

来自 `fleet doctor`。

- **是什么**：fleet 自己发出的提醒（报警、警告、在等你的）。
- **WARN / FAIL 怎么办**：逐条看提醒里写的事。

#### `epic`

来自 `fleet doctor`。

- **是什么**：一批任务（EPIC）是不是还有人在推。
- **WARN / FAIL 怎么办**：心跳停了而批次的父任务（`T<n>`）还没收口：从 `/fleet-history` 续上它的驱动会话，或在一个会话里跑 `/fleet-epic-run --task T<n>`。批次在 hub 的任务页里，父任务旁边就是驱动最后一拍写的进度。

#### `socket`

来自 `fleet doctor`。

- **是什么**：fleet 的 tmux 服务器是不是卡在「快死」的状态（所有窗口都打不开）。
- **WARN / FAIL 怎么办**：FAIL：照说明执行 `fleet-up.sh`，它清掉坏的 socket 并把会话拉回来。

#### `tmuxconf`

来自 `fleet doctor`。

- **是什么**：tmux 服务器载入的 fleet 配置是不是当前这一版。
- **WARN / FAIL 怎么办**：照说明里的 `fleet-ui-refresh.sh` 命令重载；同步后也会自动重载。

#### `rview`

来自 `fleet doctor`。

- **是什么**：远程连进来的客户端是不是各用自己的视图。
- **WARN / FAIL 怎么办**：照说明让它们断开重连；不影响会话本身。

#### `open`

来自 `fleet doctor`。

- **是什么**：「在你电脑上打开网页」用的密钥文件权限对不对。
- **WARN / FAIL 怎么办**：`chmod 600` 那个文件（说明里写着路径）。

#### `laptop`

来自 `fleet doctor`。

- **是什么**：你那台笔记本上 iTerm2 那一侧的小插件装了没有、是不是最新。
- **WARN / FAIL 怎么办**：照说明在那台笔记本上重装一次。

#### `listen`

来自 `fleet doctor`。

- **是什么**：有没有 fleet 的进程在局域网上开着端口（等于把目录分享给同网段的所有人）。
- **WARN / FAIL 怎么办**：把它改成只听 `127.0.0.1`，或停掉它。

### 仓库

#### `repos`

来自 `fleet doctor`。

- **是什么**：这个 fleet 托管了哪些仓库。只报状态。
- **WARN / FAIL 怎么办**：不用管；加仓库用 ⌘P 的 **添加仓库…**。

#### `repo`

来自 `fleet doctor`。

- **是什么**：每个仓库的配置是否写明了它是哪个仓库。
- **WARN / FAIL 怎么办**：照说明补上；或把那个仓库删掉重新添加。

#### `main`

来自 `fleet doctor`。

- **是什么**：仓库的主目录在不在、是不是 git 仓库、远端对不对。
- **WARN / FAIL 怎么办**：照说明修；最省事是删掉这个仓库，再用 **添加仓库…** 加一次。

#### `base`

来自 `fleet doctor`。

- **是什么**：会话从哪个分支开、往哪个分支合。它应该是仓库的默认分支。
- **WARN / FAIL 怎么办**：在仓库的配置里把 `FLEET_BASE_BRANCH` 写成默认分支。

#### `checkout`

来自 `fleet doctor`。

- **是什么**：仓库主目录是不是停在基础分支上。
- **WARN / FAIL 怎么办**：照说明移走占着基础分支的那个工作副本。

#### `deploy`

来自 `fleet doctor`。

- **是什么**：「合并后算不算上线」的配置写对没有。
- **WARN / FAIL 怎么办**：照说明改 `FLEET_DEPLOY_REF` / `FLEET_DEPLOY_CHECK`，或删掉它们（合并即完成）。

#### `deps`

来自 `fleet doctor`。

- **是什么**：主目录的依赖（如 `node_modules`）装好没有；新工作副本从这里链过去，不用从零装。
- **WARN / FAIL 怎么办**：网络问题会自己重试；仓库自己的问题修好后照说明的命令重装。

#### `overrides`

来自 `fleet doctor`。

- **是什么**：这个仓库自己改过的设置——它那份仓库设置（`repos/<slug>.conf`）里除仓库名、检出位置、主干分支之外写下的每个键和值；覆盖了 fleet 级的值时，括号里写出原来的 `fleet:` 值。像凭据的键或值只显示 `<hidden>`。只写了身份时写「no setting of its own」。
- **WARN / FAIL 怎么办**：只报状态，不会 WARN / FAIL。要改哪个设置，就改行尾点名的那个文件。

#### `emit`

来自 `fleet doctor`。

- **是什么**：会话事件外发（配了接收地址才有）是否送得出去。
- **WARN / FAIL 怎么办**：装 `curl`；事件积压就查接收端。

#### `wtroot`

来自 `fleet doctor`。

- **是什么**：工作副本放在哪个目录。
- **WARN / FAIL 怎么办**：目录名不以 `.noindex` 结尾时 Spotlight 会去索引它们：照说明改名。

### 这台 Mac 的设置

#### `sleep`

来自 `fleet doctor`。

- **是什么**：跑会话的机器会不会睡眠。睡了会话就停。
- **WARN / FAIL 怎么办**：`sudo pmset -a sleep 0 autorestart 1 womp 1`（撤回：说明里写着）。

#### `spotlight`

来自 `fleet doctor`。

- **是什么**：Spotlight 还在不在索引磁盘。它会和会话抢 CPU 和磁盘。
- **WARN / FAIL 怎么办**：`sudo mdutil -a -i off`（撤回：`sudo mdutil -a -i on`）。

#### `wallpaper`

来自 `fleet doctor`（只在托管 Mac 上出现）。

- **是什么**：不接显示器的承载机还在不在跑动态（Aerial）桌面。没人看得见，却一直占着一部分 CPU。整机守护每小时检查一次，没有显示器时把每个登录换成系统自带的纯色图并关掉屏幕保护——每个登录只换一次；接了显示器的机器不碰。
- **WARN / FAIL 怎么办**：`sudo ~/.claude/fleet/bin/fleet-wallpaper.sh off` 立即换。行里点名「手动换回」的登录是有人特意换回去的，fleet 不再改；要保留动态桌面：`sudo touch /var/db/fleet-node/wallpaper.keep`。

#### `siri`

来自 `fleet doctor`。

- **是什么**：Siri 开着时，它的几个后台进程常驻占内存。只报状态。
- **WARN / FAIL 怎么办**：没人对这台说话的话，在系统设置里关掉 Siri。

#### `icloud`

来自 `fleet doctor`。

- **是什么**：iCloud 同步进程常驻。只报状态。
- **WARN / FAIL 怎么办**：用不到就退出 iCloud，或关掉 iCloud 云盘和通讯录同步。

#### `network`

来自 `fleet doctor`。

- **是什么**：有没有两块网卡接在同一个子网上。回包会从另一块出去，连接时断时续。
- **WARN / FAIL 怎么办**：拔掉一条（比如有线和无线二选一），或改路由。

#### `launchd`

来自 `fleet doctor`。

- **是什么**：macOS 给这个登录的后台服务管理（launchd）是否正常。这是系统的状态，不是 fleet 的。
- **WARN / FAIL 怎么办**：注销再登录这个账号，或重启电脑。

### 只报状态

#### `gate`

来自 `fleet doctor`。

- **是什么**：公开发布前必须先完成的七项安全门槛各自做到没有（给维护者看的）。
- **WARN / FAIL 怎么办**：只报状态，不用管。
