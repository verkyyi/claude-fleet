# 弄坏 fleet 的方式（BREAK-IT）

已知能把 fleet 弄坏的每一种方式，一行一条：怎么弄坏、修之前会怎样、现在怎么自己恢复、
哪条演练在隔离环境里真做一遍（issue #1786，EPIC #1776 C10）。

**规则：新发现一种弄坏 fleet 的方式，先在这张表加一行、在
`bin/fleet-break-it-selftest.sh` 加一条演练（先红），再修（变绿）。** 一条演练 =
一个 `drill_<id>` 函数；`演练` 一列写它的 `id`。不在本仓库修的（别的仓库、别的单），
`演练` 一列写 `登记：<单号>`，只登记不演练。

跑：`bin/run-selftests.sh fleet-break-it` — 每条一行 `PASS <id> <恢复用时> ≤<上限>`。
演练全部跑在隔离的 tmux socket、临时 HOME、假的 claude / ssh / 入口上，不碰任何在跑的 fleet。
表和脚本互相校验：表里的 `id` 没有演练、或演练不在表里，测试直接红。

| 方式 | 后果（修之前） | 自愈方式 | 演练 |
|---|---|---|---|
| 会话里 `/exit`（或 Ctrl+D）退出 | 窗口跟着关，会话从列表消失 | 窗口留下画恢复页（#1784）：↵ 用同一对话 id 续上，r 新开，q 回收 | `session-exit` |
| 会话里连按 Ctrl+C 退出 | 同上 | 同上，恢复页写「按了 Ctrl+C」 | `session-ctrl-c` |
| 会话进程被杀（kill -9、OOM） | 同上 | 同上，恢复页写「被结束（信号 9）」 | `session-killed` |
| 最后一个窗口关闭（home 的 shell 退出、最后一个会话结束） | tmux 服务器随之退出，整台 fleet 停 | 服务器 `exit-empty off`，home 窗格死了立即重开 shell（#1784）；tmux ≤ 3.4 忙时会漏掉 shell 退出的信号、窗格停在死状态，diskguard 节拍的 `home_watch` 补救重开（#1801） | `last-window` |
| 节点 tmux 服务器被关（`kill-server`、崩溃） | 整台 fleet 停，没人拉起 | diskguard 节拍跑 `fleet-restore.sh --auto`，只拉起没做完的会话（#1784） | `kill-server` |
| 节点 tmux 服务器退出时被一个不回应的客户端（网络冻住的 ssh 里的 attach）拖住 | 服务器不死不活：每个新连接都被它接下就关，`tmux -L fleet` 的一切（含 `fleet-up.sh`）都报 `server exited unexpectedly`，只能手工 `rm` socket | `fleet_socket_heal` 认出这种 socket，清掉并记一行（restore.log、`socket-heal.log`），`fleet-restore.sh --auto` / `fleet-up.sh` 随即起新服务器；守护进程的「no fleet sessions found」带上 WEDGED，`fleet-doctor` 的 `socket` 行报出来（#1729） | `wedged-socket` |
| 磁盘满 | 拉起 → 写满 → 再崩的循环 | `--auto` 先问磁盘门：低于下限只记一行不拉起；腾出空间后下一拍拉起 | `disk-full` |
| 非交互 shell（ssh、守护进程）PATH 里没有 claude | 会话开出来停在 shell，`exec claude` 失败 | `fleet_find_tool` 依次找 `FLEET_CLAUDE_BIN` → PATH → `~/.local/bin` → `/opt/homebrew/bin` → `/usr/local/bin`（#1774/#1784） | `no-claude-on-path` |
| install-sync 跟随中途被 kill -9（`launchctl kickstart -k`、OOM、重启、注销） | trap 不跑，锁目录留下；之后每一拍都 `another tick holds … skip`，这台登录停在旧版本，最多白等一小时（锁 TTL） | 下一拍读锁里的 `pid`，进程不在了就立即接管并记一行 `took over … holder pid=<n> is dead`；TTL 仍兜底（#1691） | `install-sync-killed` |
| 个人 tmux 配置（`~/.tmux.conf`）写坏一行，或把 fleet 的 source 行注释掉 | fleet 层只经 `~/.tmux.conf` 的 source 行载入，文件一出语法错整份跳过：回收 hook、改名保护、窗口基线全悄悄失效；`reapply-tmux-attention.sh` 把注释掉的行当成「已引入」，补不回来 | fleet 服务器直接用 `-f conf/tmux-fleet-server.conf` 起：先载入 fleet 层（末尾打 `@fleet_conf_loaded`），再 `source-file -q` 你的个人配置——个人设置照常生效，出错只跳过它自己；`fleet doctor` 的 `tmuxconf` 行逐个 fleet 服务器核对标记和回收 hook；reapply 只认没注释的行（#1845） | `personal-tmux-conf` |
| 客户端里 prefix x / prefix & / 右键菜单 Kill | 侧栏或右侧面板、甚至整个窗口和服务器被删 | 这些键和菜单在客户端里都不存在了（#1785） | `client-kill-keys` |
| 客户端的侧栏 / 右侧进程被杀 | 一半屏幕空着，只能重开 | 侧栏 5 秒内重画，右侧窗格 5 秒内重开（#1785） | `client-pane-killed` |
| 侧栏上按 Ctrl+C / Ctrl+\\ / Ctrl+Z | 侧栏进程退出或被挂起 | 侧栏忽略这三个键，还是同一个进程（#1785） | `sidebar-ctrl-c` |
| 右侧嵌套连接断开（断网、合盖、对端重启） | 右侧窗口关掉，回不到那台机器 | 右侧停在「回车立即重连」，Ctrl+C 也不关窗口（#1785） | `nested-drop` |
| 客户端服务器被关（`:kill-server`、删光窗口） | 客户端没了 | 再敲一次 `fleet` 就原样回来；机器上的会话不受影响 | `client-kill-server` |
| `~/.ssh/config` 里给这台机器写了固定 `RemoteForward`（如 open-url.sh 的 2226） | 同一台机器的第二条连接再要这个端口被拒，骑共享连接的 attach 直接失败：右侧空白、有的行切不过去，`run` 循环几秒一次重连，最后对方 sshd 开始拒连 | 骑共享连接的会话一律 `ClearAllForwardings=yes`，自己开的 master 拿不到转发也照常连（`ExitOnForwardFailure=no`）；断线提示写人话（#1775） | `static-forward` |
| 代理窗口被关（关窗、`kill-server`），而里面的 attach 永不返回 | `run` 循环和它的 ssh 成了孤儿，TERM 杀不掉，远端 view session 越积越多、把别人在看的窗口挤到最小 | attach 放后台 `wait`，窗格/服务器关掉的 HUP 和 TERM 立即走 cleanup；首次连接先等 warm 连接，不再私开一条（#1704） | `proxy-orphan` |
| 客户端的文件在它运行中被换掉、没有重新载入（#1781 之前的 `start` 把整个目录挪开换新、或在跑的时候又跑了一遍安装行） | 旧代码的代理循环和它的连接还在，新代码再开一条要同一个 `RemoteForward 2226`：点 worker 卡死，而且毫无痕迹，只能比对文件时间才发现「刚换过版本」 | 运行中的服务器记着自己载入的版本（`@client_version`），和磁盘上的 `.client-version` 对不上时，keeper 空闲时（或下一次 `fleet`）`reload --all`：代理窗格全部重开、循环和 keeper 重启；状态栏「✓ 已更新到 …」、每个客户端一句「fleet 客户端已更新到 …（入口 …）」、`fleet doctor` 记着上次更新；还是普通目录的 home 补成版本目录（#1829）。home 里的手改下次切换就没了——长期的本地补丁放 `~/.ssh/config` | `client-files-swapped` |
| 入口不可达 | 客户端打不开、看不出原因 | 客户端照常打开（侧栏 + 右侧），状态栏左边橙色「入口连不上」（#1779） | `hub-unreachable` |
| 入口数据盘满 | 入口写不进，租约、会话表都停 | 在入口仓库修 | 登记：monorepo #11641 |
