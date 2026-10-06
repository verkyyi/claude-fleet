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
| 最后一个窗口关闭（home 的 shell 退出、最后一个会话结束） | tmux 服务器随之退出，整台 fleet 停 | 服务器 `exit-empty off`，home 窗格死了立即重开 shell（#1784） | `last-window` |
| 节点 tmux 服务器被关（`kill-server`、崩溃） | 整台 fleet 停，没人拉起 | diskguard 节拍跑 `fleet-restore.sh --auto`，只拉起没做完的会话（#1784） | `kill-server` |
| 节点 tmux 服务器退出时被一个不回应的客户端（网络冻住的 ssh 里的 attach）拖住 | 服务器不死不活：每个新连接都被它接下就关，`tmux -L fleet` 的一切（含 `fleet-up.sh`）都报 `server exited unexpectedly`，只能手工 `rm` socket | `fleet_socket_heal` 认出这种 socket，清掉并记一行（restore.log、`socket-heal.log`），`fleet-restore.sh --auto` / `fleet-up.sh` 随即起新服务器；守护进程的「no fleet sessions found」带上 WEDGED，`fleet-doctor` 的 `socket` 行报出来（#1729） | `wedged-socket` |
| 磁盘满 | 拉起 → 写满 → 再崩的循环 | `--auto` 先问磁盘门：低于下限只记一行不拉起；腾出空间后下一拍拉起 | `disk-full` |
| 非交互 shell（ssh、守护进程）PATH 里没有 claude | 会话开出来停在 shell，`exec claude` 失败 | `fleet_find_tool` 依次找 `FLEET_CLAUDE_BIN` → PATH → `~/.local/bin` → `/opt/homebrew/bin` → `/usr/local/bin`（#1774/#1784） | `no-claude-on-path` |
| 客户端里 prefix x / prefix & / 右键菜单 Kill | 侧栏或右侧面板、甚至整个窗口和服务器被删 | 这些键和菜单在客户端里都不存在了（#1785） | `client-kill-keys` |
| 客户端的侧栏 / 右侧进程被杀 | 一半屏幕空着，只能重开 | 侧栏 5 秒内重画，右侧窗格 5 秒内重开（#1785） | `client-pane-killed` |
| 侧栏上按 Ctrl+C / Ctrl+\\ / Ctrl+Z | 侧栏进程退出或被挂起 | 侧栏忽略这三个键，还是同一个进程（#1785） | `sidebar-ctrl-c` |
| 右侧嵌套连接断开（断网、合盖、对端重启） | 右侧窗口关掉，回不到那台机器 | 右侧停在「回车立即重连」，Ctrl+C 也不关窗口（#1785） | `nested-drop` |
| 客户端服务器被关（`:kill-server`、删光窗口） | 客户端没了 | 再敲一次 `fleet` 就原样回来；机器上的会话不受影响 | `client-kill-server` |
| 入口不可达 | 客户端打不开、看不出原因 | 客户端照常打开（侧栏 + 右侧），状态栏左边橙色「入口连不上」（#1779） | `hub-unreachable` |
| 入口数据盘满 | 入口写不进，租约、会话表都停 | 在入口仓库修 | 登记：monorepo #11641 |
