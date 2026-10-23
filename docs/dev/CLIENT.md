# The client — keys for switching sessions

`fleet` on your own computer is the **client** (`bin/fleet-thin.py`):
one foreground Python loop and one connection to your home machine. The home
machine draws the panel, top bar and session. The old two-pane client was
removed in #3008; `--old` and `FLEET_CLIENT=shell` explain the retirement and
open the same current client. Configuration migration comments out old switches.
This page is the contract for moving between sessions from the keyboard
(issue #1903, EPIC #1906 C10) — from anywhere, without first putting the
keyboard on the list.

## One key + the panel (issue #3185, EPIC #3178 C7; issue #3328; T685)

fleet takes **one key** (操作者 2026-10-20, T685): **⌘P** on a Mac (iTerm2), and
on a phone or any terminal with no ⌘ the same panel as **F12** (one tap once it is
on Termius's extra-key row — T705, 操作者 2026-10-20 「Termius还应保留F12」) or
**⌃] p** (⌃], then p; always bound). In iTerm2 F12 stays the session's: the
`fleet` profile sends it as code 933, which the 看台 hands on as F12
(`fleet_keys.ITERM_PASS`) — on a Mac fleet still takes ⌘P alone. It
opens the panel: every session, and every action — the panel's own rows, picked
with ↑↓ ↵ or reached by typing a few of their words:

| Row | Does | Type |
|---|---|---|
| + 新会话 | the 「新会话」 box (T652, EPIC T651 C1): 仓库 ‹›, Agent ‹›, 开 — already chosen, so ↵ opens it; nothing is typed there, the first message is said in the session (and renames its row and record) | words that hit no session |
| $ 命令行 | this machine's login shell in `$HOME`, no session and no hub (EPIC T651 C3); the panel again comes back | `回家` · `home` · `shell` |
| ⇄ 语言 / Language | the interface language | `语言` · `lang` |
| ✦ 消息 | the panel's FIRST row (T701): every message in the one book `$FLEET_CONF_DIR/logs/notices.ndjson` (7 days) — a top-line notice (T675), a session asking / stuck / done (`fleet_notify.py`), an alert appearing / healing (`fleet-alerts.sh`), a result nobody took (`fleet-orphan-reports.py`'s own book) — and the other machines' (the hub caches `notices_<fleet>` / `orphanrep_<fleet>`, union by id, the latest read mark of any machine); `bin/fleet_notice.py page`, grouped, ↵ the whole text, g its session, r mark read, f hand a result nobody took to the orchestrator; ` N` while some are unseen; the 看台's message row under its top line (`status-format[1]`, `fleet-topbar.py inbox`, a click opens the page) is there only while one is live; `fleet notices` prints the same on a device | `消息` · `message` · `notice` |
| ⏏ 退出 fleet | ends the connection, the sessions run on — after a y / n | `退出` · `quit` |

A session's Tab page offers enter, PR, rename, agent switch, open in web and
stop (resumable), with unavailable actions hidden or explained. The separate
shell entry remains. There is no zoom / fold row: a 看台 window has one pane.
The current panel's steps and row actions are in
[日常使用](../public/zh/member/usage.md#一个键总面板).

**The keys that went back to iTerm2 (T685; after issue #3328):** ⌘↓ ⌘↑ ⌘[ ⌘] ⌘N
⌘T ⌘K ⌘Q ⌘\ are no row of the `fleet` profile any more, so iTerm2 has its own
again — ⌘K clears, ⌘T opens a tab, ⌘N a window, ⌘Q quits iTerm2. ⌃\ goes to the
session (`send-keys`) and ⌃空格 to the terminal (F12 came back for the phone, T705). Their private codes stay
retired, never reused: a profile written before the update still sends one until
the next start rewrites it, and the 看台 catches it as a user key bound to
nothing — it does nothing (`fleet_keys.RETIRED`). After the update each login is
told once: 「fleet 只用 ⌘P（手机 F12 或 ⌃] p），其余都在面板里」 (`keys-notice-T685`).

Want an old key back, or a different one? One line in `fleet.conf`
(`~/.config/claude-fleet/fleet.conf`; `bin/fleet_keys.py` reads it) — a key you
name there is yours:

```
[client]                         # this computer's keys
FLEET_KEY_PANEL=cmd+p            # the panel's chord: cmd+' … · off = none
FLEET_KEYS_EXTRA="next=cmd+down prev=cmd+up back=cmd+[ fwd=cmd+] new=cmd+n quit=cmd+q home=cmd+\\"
[common]                         # the machine's keys for a phone
FLEET_KEY_PHONE="f12"            # beside ⌃] p (always): off = ⌃] p alone · ctrl+space f12
FLEET_KEYS_PHONE_EXTRA="ctrl+]n=next ctrl+]b=prev ctrl+]c=new ctrl+]q=quit"
```

An extra is `action=chord` (`chord=action` works too); actions are the switch
table's (next prev back fwd new dispatch quit home) and `shell`, the session's shell.
A chord is `+`-joined `cmd` · `ctrl` · `alt` · `shift` and one key (a character,
`down` `up` `left` `right`, `space`, `tab`, `return`, `esc`, `f1`…`f20`);
`ctrl+]x` is ⌃] then x. A ⌘ chord becomes a row of iTerm2's `fleet` profile
(written by the client at every start); any other chord is bound on the machine
as it is. The client hands its `FLEET_KEYS_EXTRA` to the machine at each attach
(the remote command's environment — an older machine ignores it), and the
machine keeps the union (`@fleet_view_keys_extra`), so a phone attaching with no
extras takes nothing from the Mac's. ⌃] ⌃] always sends one ⌃] on.

- Not iTerm2 (Ghostty, Terminal.app): a ⌘ chord never reaches the fleet — use
  F12 or ⌃] p.

Terminal 是 iTerm2 中的 tmux 面板，Web 是网页。两者均按 PIN、无标题普通任务、
折叠的「更早的会话」排列；旧父子关系和 EPIC 成员平铺，不显示树或成员计数。
每行只有一个固定状态位，优先级为 `!` 需要回答/批准、`◷` 待启动、`↻` 运行、
`⟳` Loop；普通静止行留空。详情保留原生观测和错误原因，失联行淡化，不能把空白
解释为已经停止。面板本次浏览中的顺序不随状态刷新跳动。

Hub 看板的 `pending_start`、`running` 与可选 `loop` 是事实字段，显式 false
优先于旧状态推断。仅建立记录不算待启动；Loop 来自有效的重复计划，单次唤醒不算。
本地旧节点回退只把 working，或带有 bg/tool 原生等待事实的 looping，视为运行；
没有新字段时不凭 looping 名称猜 Loop。任务结果不盖过原生会话的新一轮运行。

「停下（可恢复）」直接调用现有 `worker_stop`，不再经过回收确认；保留文件和历史。
明确标为待启动且从未开过会话的任务，在操作页提供「取消启动」；Web 提供同名按钮，
`fleet close <任务短码>` 也可撤销该启动请求。操作前重新检查任务，若会话已经打开，
提示刷新后停止该会话，不自动改为强停。取消不依赖目标节点在线；
尚未覆盖全部未来唤醒，也不等于确认运行中的进程退出。
请求受理不表示远端已退出，失败须显示原因。Web 任务页只提供对话，旧任务
`?view=term` 打开同一任务的对话并提示；独立 Shell `/app/s/shell?view=term` 保留。

## 历史会话：查看、接回与撤销隐藏

网页的「更早的会话」从会话 FID 取历史入口，不依赖另一份已结束列表的条数，也不按
循环使用的 scratch 名称猜会话。打开对话是只读；不会启动助手，已删除工作树也
不妨碍读取保留的原生记录。状态区分 `readable`（可读）、`resumable`（可尝试接回）、
`offline_unknown`（目前无法核实）、`missing_confirmed`（人工核验全部副本缺失）和
`never_started`（没有记录到原生段）。Hub 缓存仅供本人读取；管理员的 view-as 不能读对话。

「详情 → 接回」按同一 FID 恢复原生 SID。Codex 的迁移收据须同时匹配 FID、SID
和原生记录中的落点，恢复时携带原 CODEX_HOME。缺少原目录且没有可核验的精确版本，
明确拒绝自动恢复；不会偷偷开新对话。可读与可接回是两个不同条件。

一次性清理由操作者使用 `bin/fleet-history-hide.py <manifest.json>`，默认仅 dry-run；
`--apply` 才隐藏，`--undo --apply` 撤销。凭据只从 `FLEET_HUB_URL`、
`FLEET_HISTORY_ADMIN_TOKEN` 环境变量读取。清单是一个 owner+FID 对象，必须包含
`owner,id,seq,machine,login,checked_at`、`online:true,complete:true`，按段顺序列出全部
`natives`，并声明 `native_evidence:"absent_verified"`、`backups:"absent_verified"`、
`inputs:"empty_verified"`；`evidence` 指向操作者核验过所有落点、迁移/收尾备份和输入队列的
证据。核验须在五分钟内完成；离线、不完整、版本变化、活跃窗口或未完成任务均拒绝。
这份清单是人工核验声明，不是工具自动扫描出的证明。Hub 会另行查缓存和待办：解密该 owner 的 view 缓存，用其中的原生
`Session` 与 owner 范围内记录的原生 SID 精确归属 FID，旧 key 缓存也这样读取；不按
scratch 名称或更新时间猜归属。无关且可归属的缓存不阻挡，相关缓存、解密失败、缺失或
歧义映射均拒绝隐藏。dry-run 的结果不复用到 apply：事务内重新检查，缓存写入与隐藏
共用 owner 锁；之后到达的相关或无法归属的缓存使隐藏行重新显示。缓存不会因隐藏而清除。
隐藏与撤销都留审计，仅改变 Web 与 Terminal 共用看板的可见性，不删除任务、原生段、
对话、账号或端点。后续 FID 事件会使旧隐藏自动失效。

## 侧栏下线清单 — every sidebar job's new home (issue #3186, EPIC #3178 C8)

**Historical acceptance record, 2026-10-11.** The table and device drills below
describe the client at that time. Their status groups, parent/child rows, EPIC
counts and reap menu have since been replaced by the current rules above;
these historical screenshots are not acceptance evidence for the current UI.

The old client was removed in #3008 after every row below was ✅. One row per row of the EPIC page's 「侧栏的每一件去哪」
(17 rows covering the sidebar's 24 jobs — the 11 menu items share row 7), no more,
no fewer; a job found later gets a row here and a member issue. Evidence lives
under `$FLEET_CONF_DIR/fleets/fleet/epic/3178/evidence/3186/` (the evidence store
of the time, retired with #4898; never committed) — `panel` · `menus` · `rows` are the mac-c 看台's own
`fleet-quickopen.py view-panel | view-menu | view-rows` output. 「点头」 = 发起人
@dave 2026-10-11 确认方案（「需要你定的事」全部按建议）.

状态：✅ 有证据（17/17，2026-10-11 全绿）

| # | 当时侧栏做的 | 当时在面板里怎么做 | 历史证据 | 当时状态 |
|---|---|---|---|---|
| 1 | 一直看得见谁在干活、谁卡住 | ⌘P：分组 置顶 · 等你 · 在干活 · 等合并/等发版 · 刚落地 · 其他 · ▸已结束（#4225 按「该做什么」细分），组标题带个数；顶上一行只说**这个**会话（#3194 改了页上的「顶上一行写 N 个在等你」，同样点头） | `panel` · 真机（发起人 2026-10-11 真机演练：MacBook + iPhone 全过） | ✅ |
| 2 | 「N 个在问你」，点一下跳过去 | 「等你」组排在最上；系统通知（`fleet_notify.py`）点开直达 | `fleet-view-selftest.sh`（组序） · 真机（发起人 2026-10-11 真机演练：MacBook + iPhone 全过） | ✅ |
| 3 | 问题原话 | 「等你」那一行下面一行（status_msg / `@claude_needs_detail`） | `fleet-view-selftest.sh`（原话行） · 真机（发起人 2026-10-11 真机演练：MacBook + iPhone 全过） | ✅ |
| 4 | 按仓库分组、父子缩进、已结束折起来 | 按「你该做什么」分组；仓库只在 2 个以上时做行尾标签；子会话缩进；已结束折在最下 | `panel` · `rows`（`claude-fleet` / `no repo` 标签） | ✅ |
| 5 | 置顶 | 「置顶」组；Tab →「置顶」（本机的行；别的机器的行侧栏也不能置顶） | `menus`（Pin） · 真机（发起人 2026-10-11 真机演练：MacBook + iPhone 全过） | ✅ |
| 6 | 别的机器的会话、失联变灰 | 同样列出，行尾标机器；失联 / 过期：顶上整条红字 + 那几行「? 失联 N 分钟」，↵ 说进不去 | `panel`（mac-d 的行）· `fleet-view-hub-fresh-selftest.sh` · 真机（发起人 2026-10-11 真机演练：MacBook + iPhone 全过） | ✅ |
| 7 | 点一行出菜单：回答 · 发消息 · 改名 · 停 · 继续 · 唤醒 · 改回收方式 · 回收 · 换 Claude/Codex · 打开它的改动（「换账号」随 T550 退休：订阅由池子挑） | 选中按 Tab，同一份菜单（`ACTIONS`；`SIDEBAR_ACTIONS` 一一对照）；别的机器的行有 回答 · 发消息 · 改名 · 改回收方式 · 停 · 回收 · 恢复 | `menus` · `fleet-view-actions-selftest.sh` · 真机（发起人 2026-10-11 真机演练：MacBook + iPhone 全过） | ✅ |
| 8 | 改名、发消息、回答时在那一行下面问一句 | 面板底部问一句（↵ 交 · Esc 退），答完回到列表 | `fleet-view-actions-selftest.sh` · 真机（发起人 2026-10-11 真机演练：MacBook + iPhone 全过） | ✅ |
| 9 | 配置坏了「会坏·需重开」 | 那一行的 `✗ 会坏·需重开` 标签 | `fleet-view-selftest.sh`（cfg broken） | ✅ |
| 10 | 已落地的列表、点一下恢复 | 「已结束」组：还开着的之后列出窗口已回收的会话（同 `/fleet-history` 那份账，标「window reaped · ↵ restore」），↵ 或 Tab →「恢复」（#3286） | `rows-after` · `menu-reaped`（Restore） | ✅ |
| 11 | 新会话时问「开在哪台」「什么时候回收」 | 默认不问（家里那台、合并后回收）；事后 Tab →「改回收方式」；每次都问 = R4 有空再做 | 点头 · `menus`（Reap policy） | ✅ |
| 12 | 批次视图、「#N 没人在跑」重开 | EPIC 那一行行尾 k/N；重开 = R3 有空再做；没人在跑照样来通知 | 点头 · `rows`（21/22 · 9/12 …） | ✅ |
| 13 | 铃声、系统通知 | 照旧（`fleet_notify.py`，不靠侧栏） | 不随侧栏删 | ✅ |
| 14 | 上下文、模型、额度 | 照旧在顶上一行（`fleet-topbar.py`） | 不随侧栏删 | ✅ |
| 15 | 顶上一条消息提示、等账号开好 | 照旧（新客户端已有） | 不随侧栏删 | ✅ |
| 16 | 窄屏布局切换、放大、折叠、隐藏侧栏、⌂ | 不要了：新客户端全屏，面板 100 列以下自动全屏 | 点头 | ✅ |
| 17 | 「新任务」红行、管家的待答清单、管家行 | 已随「编排和管家改成插件」（#3111）拿掉，不归这批 | #3119 | ✅ |

**手机上要实测的**（EPIC 页「出处与未核实」，iPhone Termius）：

| 实测 | 结果 |
|---|---|
| Termius 附加键默认那排有哪些键 | 演练够用，具体是哪些键没记（发起人 2026-10-11 真机演练：MacBook + iPhone 全过） |
| ⌃空格（点 Ctrl 再点空格）能不能开面板 — 开不了就把 `FLEET_KEY_PHONE` 默认改成 `f12 ctrl+]p` | 可以（发起人 2026-10-11 真机演练：MacBook + iPhone 全过） |
| 按上面「设置一次」把 F12 放到第一排后，点一下能开 | 可以（发起人 2026-10-11 真机演练：MacBook + iPhone 全过） |
| 音量键能不能设成 F12 | 可以（发起人 2026-10-11 真机演练：MacBook + iPhone 全过） |
| ⌃\ 在面板里能按出（开 shell） | 可以（发起人 2026-10-11 真机演练：MacBook + iPhone 全过） |

**当时的真机演练**（MacBook iTerm2 一遍、iPhone Termius 一遍）：开面板（⌘P / ⌃空格 / F12）→ 派一件新任务 → 开 shell 并回来 → Tab 回收一个 → 回答一个 → 在别的机器上做一个 → 让列表过期看红字。每一步一张截图（当时进证据库，#4898 起附在 PR 里）。

全部 ✅ 后在 #3008 留「侧栏下线清单已全绿，可删」。

## How a ⌘ chord reaches the client

A terminal sends nothing for ⌘ — macOS keeps it. So the client installs an
**iTerm2 Dynamic Profile** named `fleet`
(`~/Library/Application Support/iTerm2/DynamicProfiles/fleet.json`,
`bin/fleet-iterm-profile.py`) whose Keyboard Map turns each chord into a
**private code**:

    ESC [ <code> ~        code 920 next · 921 prev · 922 back · 923 fwd ·
                               925 zoom · 927 quickopen · 928 new · 929 fold ·
                               931 quit · 932 dispatch
                      ⌘\ (home, EPIC T651 C3 — only when named, T685) sends
                      ⌃\'s own byte 0x1c instead: tmux drops a private code
                      while a popup is up

924 (⌘J), 926 (⌘/) and 930 (⌘K, issue #3185) are retired (issue #2362) and never reused: a profile
written before the update still sends them, and the conf catches both and does
nothing with them until the next start rewrites the profile without them. Since
T685 the profile writes only ⌘P (+ what FLEET_KEYS_EXTRA names): every other code
above is caught the same way and does nothing when an older profile sends it.

No terminal sends `ESC [ 92x ~` for a real key. `conf/tmux-view.conf` catches
each as `user-keys[<code>]` → `User<code>`, bound to the same body as the prefix
key. The one table is `bin/dash-keymap.sh --panel switch list` (action · ⌘ glyph
· iTerm2 key · code · prefix key); the conf, the full sheet and the profile are
all held to it by `bin/dash-keymap-selftest.sh` leg 10.

The profile **adds** a profile and changes none: every other setting comes from
its parent — the profile the window was in when it was written, else iTerm2's
default — and its Keyboard Map is the parent's own with the table's rows on top.
`fleet` wears it only while attached (`ESC ] 1337 ; SetProfile=fleet` before the
attach, the profile it came from after the detach), so outside the client
iTerm2 behaves as it always did.

- **Written** at every start of the client (`fleet-thin.py`: the panel + your
  extras) —
  so the install line and every update leave it current. Nothing is written off
  a Mac, or on a Mac with no iTerm2.
- **Removed** with `python3 ~/.claude/fleet/bin/fleet-iterm-profile.py remove`;
  `FLEET_ITERM_KEYS=0` in the environment removes it at the next start and keeps
  it away (the window then never switches profile).
- **Not iTerm2** (Terminal.app, Termius, ssh from elsewhere — no `ITERM_PROFILE`
  in the environment): the attach is the bare `exec tmux … attach` it always
  was, byte for byte; the prefix keys above do the same jobs.

## Popups draw opaque

The home machine draws the panel with its own background and a complete frame
(`fleet_view.py`, `fleet-quickopen.py`'s `Heal`). The client runs no local tmux.

## 复制 — a copy made in a session lands on your device (issues #1766, #2758)

Text you select in a session, and text the session copies for you (Claude Code's
own copy), goes into the clipboard of the device you are typing on — not the
machine the session runs on.

- **How it travels.** The node's tmux (`conf/tmux-attention.conf`) writes
  OSC 52. The home machine's view and the thin loop pass it to your terminal;
  the node enables `set-clipboard on` and passthrough.
- **Drag to select.** Press, drag, release: the release copies (tmux's
  `MouseDragEnd1Pane` → `copy-pipe-and-cancel`). Double-click copies a word. In
  copy-mode (prefix `[`), `y` and `↵` copy and close it. A session that takes the
  mouse itself (Claude Code's own selection) copies with its own OSC 52.
- **iTerm2** drops every OSC 52 unless *Settings → General → Selection →
  「Applications in terminal may access clipboard」* is on, which it is not by
  default. That setting is iTerm2-wide (there is no per-profile one), so the
  client turns it on ONCE at its start (`fleet-iterm-profile.py write`) and
  leaves a mark (`~/.config/claude-fleet/iterm-clipboard`); turn it off
  afterwards and it stays off — `fleet doctor`'s `clipboard` row then WARNs and
  says where it is.
- **A terminal that may not take it** — Termius, macOS Terminal, or one the
  client cannot name (`通用终端`) — gets one line on its own bar when it attaches:
  copy with the terminal itself (⌥-drag on a Mac, long-press on an iPad or a
  phone).

| Terminal | Select in a session → clipboard | Claude's copy |
|---|---|---|
| iTerm2 (Mac) | yes, once the permission is on (the client turns it on) | yes |
| Blink (iPad) | yes | yes |
| Termius (phone) | no OSC 52 — long-press to select with Termius itself | no |
| macOS Terminal | no OSC 52 — ⌥-drag to select with Terminal itself | no |

`bin/fleet-thin-notify-selftest.sh` checks the current connection; historical
clipboard coverage also verified: a
copy-mode copy, a real mouse drag typed into the outer terminal, a program's own
OSC 52 (raw and passthrough) and an outer terminal with no `Ms` of its own all
arrive as OSC 52; the iTerm2 permission's once-only rule; the doctor row.

## 和本地 Claude 的键 — the keys of a local Claude, the same here (issue #2760)

A key you press in a session does what it does in Claude Code run straight in
your terminal (EPIC #2756's yardstick: the same Claude Code version in iTerm2 on
your Mac). The few that do something else on purpose say so below.

- **Extended keys.** The node enables `extended-keys on` and CSI u encoding;
  Shift+Enter reaches a pane that requests extended keys. The thin loop forwards
  these bytes through its pty. `shift-enter-sends` exercises the node on an
  isolated socket.
- **⌥← ⌥→.** The iTerm2 profile makes left Option send Esc+, so word movement
  works like a local Claude session. `FLEET_KEYS_PARITY=0` keeps the parent
  profile's Option behavior.
- **Portable keys.** The view's keys are in `conf/tmux-view.conf`; a direct
  attach keeps the node's normal tmux keys.

| 键 | 本地 Claude | fleet | 说明 | 终端送的字节 |
|---|---|---|---|---|
| ⌃C | 打断 / 清空输入 | 一样 | | `03` |
| Esc | 打断正在做的 | 一样 | | `1b` |
| Esc Esc | 回到之前的一句 | 一样 | | `1b+1b` |
| ⇧↵ | 换行不发送 | 一样 | 扩展键（#2760 之前变成「发送」） | `1b5b31333b3275` · `1b5b32373b323b31337e` · `0a` |
| ⌥↵ / ⌃J | 换行不发送 | 一样 | | `1b0d` · `0a` |
| ⇧⇥ | 切换自动接受 / 计划模式 | 一样 | | `1b5b5a` · `1b5b393b3275` |
| ⌃R | 翻历史 | 一样 | | `12` |
| ⌃L | 清屏重画 | 一样 | | `0c` |
| ↑ ↓ | 上一句 / 下一句 | 一样 | | `1b5b41` · `1b5b42` |
| ⌥← ⌥→ | 按词移动光标 | 一样 | 左 ⌥ 当 Esc+（fleet 的 iTerm2 配置） | `1b1b5b44` · `1b1b5b43` · `1b62` · `1b66` · `1b5b313b3344` · `1b5b313b3343` |
| ⇥ | 补全路径 / 命令 | 一样 | | `09` |
| ⌃B | 把正在跑的命令放到后台 | 一样 | 看台的前缀是 ⌃]，⌃B 原样给会话 | `02` |
| ⌃V | 贴图 | 一样 | 客户端先把图送到会话那台机器（#2757，`fleet-thin-upload-selftest.py`） | |
| ⌘V 多行 | 粘贴多行文字 | 一样 | 括号粘贴原样到会话 | `1b5b3230307e6f6e650d74776f1b5b3230317e` |
| 拖文件 | 得到文件路径 | 一样 | 客户端先把文件送过去（#2757） | |
| 选中 / ⌘C | 复制到本机 | 一样 | 见上一节「复制」（#2758，`clipboard-osc52-selftest.sh`） | |
| ⌃D | 空输入时退出 | 有意不同 | 原样给会话；离开客户端用面板的「退出 fleet」 | `04` |
| ⌃\ | （本地没有用途） | 一样 | T685 起原样给会话；会话 shell 在 Tab 页、本机 shell 是面板的「$ 命令行」，要键在 FLEET_KEYS_EXTRA 配 | `1c` |
| ⌘K | iTerm2 清屏 | 一样 | #3185 起还给 iTerm2（默认只绑 ⌘P） | |
| ⌘T ⌘N ⌘Q | iTerm2 新标签 / 新窗口 / 退出 | 一样 | T685 起还给 iTerm2；新会话、退出 fleet 在面板里 | |

## 停放后继续说话

空闲会话停放后保留最后一屏，底部显示灰字「· 已停放 · 直接打字，回车即接回（约 2 秒）」；英文显示「· parked · just type — Enter resumes it (~2 s)」。窄终端按宽度换行。

切换到这个窗口只查看记录。直接输入，按回车后恢复同一对话，并把整句作为第一轮；输入未提交前不会接回。恢复启动失败时原句仍留在窗口，回车或 r 重试，n 开新对话并带上这句话。只有助手启动确认后才清除暂存的输入。

## Where the state lives

The home keeps each view's registration under `$FLEET_CONF_DIR/remote-views/`.
`fleet_view.py` owns its history and panel state. Every switch uses
`fleet-view-go.sh`, preserving the view's current session identity across reconnects.
The local client keeps reconnect/version logs and its saved home connection;
there is no sidebar state, local stage server or warm connection pool.

## On a phone — the same road as the Mac (issues #3006, #1904)

A phone or an iPad has no client of its own. You **ssh** into something that has
`fleet` — your MacBook, or any of your machines — and type `fleet`. Over ssh
(`SSH_CONNECTION` set) plain `fleet` is the **thin loop** (`fleet --thin`,
bin/fleet-thin.py), the very one the Mac runs: one connection to your home
machine, and everything you see — the top line, the switcher, the other
machines' sessions — drawn there, in your own 看台. So the phone has none of the
old client's parts, and none of their faults.

- **ssh into the MacBook** (or any computer with the client): the loop there
  asks the hub for home and connects to it, as on the Mac itself.
- **ssh into a machine** (a managed one, `/var/db/fleet-node/machine.env`):
  that machine is home — `fleet-thin.py --local`, no hub asked, no ssh back to
  itself; the 看台 attaches right there, a child of the loop.
- **The machine the hub picks IS the one you ssh-ed into, as the same login**:
  `fleet-connect.py --argv` answers `local` too — no ssh to itself
  (`FLEET_CONNECT_SELF=ssh` keeps it, for a test of the route).
- `fleet <machine>` names the machine to connect to. `FLEET_CLIENT=shell fleet`
  explains that the old client was retired and starts the same thin loop.
- `fleet shell [<machine>] [--print]` (EPIC T651 C5, `bin/fleet-shell.py`) is
  the emergency way in: the home machine's login shell in `$HOME` with no 看台
  (`FLEET_NO_VIEW=1`), on the same `fleet-connect.py --argv` answer the loop
  uses. With the hub down it takes `--argv --offline` — the machine entered
  last (or named) and its remembered routes, never the relay; without a valid
  certificate only that machine's entry port (the device key, the keys file kept
  on the machine), else it says it cannot get in. `--print` prints the one ssh
  line for a phone's ssh app. It opens no client, takes no lease, writes no
  record (BREAK-IT `shell-hub-down`).

**Your address: no command = the 看台** (issue #3071, EPIC #3067 C5). On your
home machine's entry port (`ssh -p 22022 <login>@<name>.cf.example.com`, a key
added on the hub's key page) there is nothing to type: a connection with **no
command on a terminal** lands in your 看台 — the session you looked at last
from that key; ⌃] p opens the panel. A 看台 that ends with a code that is not
a leave (0 · 129) keeps the connection and drops you at the login shell with
`FLEET_NO_VIEW=1` and one line on how back (EPIC T651 C4).
**A command runs exactly as on port 22** — `ssh … ls`, sftp /
scp / rsync, and the thin client's own attach (it sends the same command it
always has); **no command and no terminal** (`ssh -T`) is your login shell. It
is the entry sshd's `ForceCommand`, `bin/fleet-entry.sh` — a dispatch run as
your login, never a limit; each arrival is one line in `logs/entry.ndjson`.

**手机：Termius 四样** (EPIC #3067). One app, no Tailscale, no computer:

1. Open the hub's key page on the phone — `<hub>/fleet/keys` (sign in once).
   The first time it asks for your address's name: lowercase letters, digits
   and `-`, 3–20 (the GitHub name is filled in); your address becomes
   `<name>.cf.example.com`.
2. In Termius: Keychain → **Generate key** (ED25519) → open it → **Copy public
   key**; paste that one line on the key page, give it a name (`iPhone`), **加上**.
   A private key pasted by mistake is refused and never kept.
3. In Termius: **New host** with the four things the page lists, each with a
   copy button — **地址** `<name>.cf.example.com` · **端口** your home's entry
   port as the page says (today 22122 for mac-c, 22123 for mac-d — the
   router's outside port, not always 22022) · **用户名** your login on the home
   machine · **钥匙** the one you just added. Connect: the first time Termius
   asks you to trust the host key — that is the home's entry port's own key.
4. You are in your 看台. Lost the phone? Open the key page anywhere and tap
   **撤掉** on its key: the home refuses it within seconds and cuts the
   connection it holds.

The key is an ordinary key of your login, the same as a computer's. Changing
home on the page changes the port when the new home sits behind the same router
(Termius: edit the port once) and Termius says the host key changed once —
`docs/MULTI-MACHINE-OPS.md` «从外面连进来».

**The keys: one, to open the panel** (issue #3185). A phone has no ⌘; the 看台
opens the panel on **F12** or **⌃] p** — `FLEET_KEY_PHONE`, above (F12 by default,
T705; ⌃] p always; T685 dropped ⌃空格 — write it there to have it back). Put `F12`
on Termius's extra-key row (Settings → Keyboard → extra keys) and one tap opens it. ⌃] ⌃] sends a
literal ⌃] to the session. Want a key per action? `FLEET_KEYS_PHONE_EXTRA` binds
the letters below (`bin/dash-keymap.sh --panel switch view` spells them):

| ⌃] then | Does |
|---|---|
| `p` | the panel: every session — all machines, every login of yours — and every action (default; ⌘P on the Mac) |
| `n` / `b` | the next / the previous session in that list (other machines' too) |
| `h` / `l` | back / forward in where you have been |
| `c` | a new session |
| `q` | 退出 fleet |
| `⌃]` | a literal ⌃] to the session (always) |

Narrower than 100 columns the list opens on **the whole screen**, and the top
line drops 剩余 · 模型 · effort (the session's key, its title and its machine
stay). In the list: type to filter, ↑↓ (⌃P / ⌃N) to move, ↵ to go, Esc to close.

**Termius (iPhone)**: ⌃ is the **Ctrl** key on the extra-key row above the
keyboard — tap it, then `]` (on the symbols page), then the letter. Copy works
by long-press (Termius takes no OSC 52 — see 复制 above); a session asking you
reaches the phone by the hub's push, not the terminal.
**Blink (iPad)**: with a hardware keyboard ⌃] is the chord itself (Caps Lock can
be Ctrl in Blink's keyboard settings); on screen, Blink's Ctrl key then `]`.
Blink takes OSC 52, so a copy in a session lands on the iPad.
*Which taps your own phone needs is confirmed in the C10 drill; the letters
above are what the 看台 binds.*

The old client's phone layout (`‹ i/n ›` taps and F1–F4, issue #1904) has
retired. Use the panel keys above on the current client.

## A new session in one command — `fleet claude` / `fleet codex` (issue #2264)

`fleet claude [--node mac-a] [a first sentence…]` (or `fleet codex …`)
opens a HOME session on a fleet machine, then attaches the current client to it.
`fleet-home-session.sh` asks through `fleet-client-place.sh`; failures print the
hub's reason. The session runs in your home directory with no repo. `--here`
runs the agent on this computer through its credential proxy.

## 放到后台 and 退出 fleet — two different things (issue #2349)

Closing the terminal or choosing 「退出 fleet」 in the panel ends the local
connection; sessions keep running on their machines. The next `fleet` can
return to them. There is no resident client process to keep in the background.
`fleet quit` cleans up an old resident client left by an earlier version;
`fleet status` reports any such leftovers and the current identity.

## A session on this computer — `fleet run` (issue #2136)

`fleet claude|codex --here [args…]` is the same thing (issue #2264); `fleet run`
is its older spelling.

A computer with only the client runs no fleet, so a host's launchers never
apply here. `fleet run claude|codex [args…]` is the one way to open a Claude
Code or Codex session on it without a subscription credential in the session:

1. `FLEET_CRED_PROXY=1` in `fleet.conf` `[common]` (off ⇒ `fleet run` refuses,
   exit 3; nothing else changes);
2. `fleet run` starts the local proxy (`fleet-cred-proxy.sh ensure`), signs a
   worker assertion with this computer's node token (`node.env`, from the
   install's `fleet node join`) for its **client fleet** —
   `uuid5(NAMESPACE_URL, "fleet-client:" + sha256(token))`, which the hub
   derives the same way (`fleetid.ClientFleetID`) since no fleet row exists —
   and borrows an `fcp-h1.` pass (`fleet-session-cred.sh mint`);
3. the agent talks to `127.0.0.1:<port>` with that pass; an untrusted computer
   (the default — `fleet-node-trust.sh status`) is routed **central**, so the
   real credential never leaves the cluster. At exit the pass is revoked.

`fleet cred-scan scan [--hashes FILE]`, run inside such a session, tries the
four routes to a credential (accounts files · `~/.codex/auth.json` · the
environment of the session and its ancestors · `node.env` → `POST
/v1/node/credentials`) plus the session's own directories and prints **counts
only**. `fleet-cred-scan.py hashes` on a host that holds the pool's credentials
prints their sha256 digests for `--hashes`, so a person's own login is told
apart from a pool credential. ⚠️ On a trusted host `④` is a real lease call —
pass `--no-hub` there.

## 常见问题 — 连不上 · 中文乱码 · 列表停住 · 会话结束了 · 额度在哪看 (issue #3216)

The `fleet-help` skill (`skills/fleet-help/SKILL.md`) answers from here; each
answer is a person's steps, the reasons live in the sections it points to.
`<入口>` is the hub's address — `FLEET_HUB_URL` in `fleet.conf`.

**连不上**
- 手机（Termius）：
  1. 打开钥匙页 `<入口>/fleet/keys`：那把钥匙还在（没被「撤掉」）、页上写的**端口**和
     Termius 里那台主机的端口一样——换过家端口会变（`docs/MULTI-MACHINE-OPS.md`
     «手动换家»）。
  2. 页上写「从外面连不上」：家机器的入口端口从外面够不着。在家机器上跑 `fleet doctor`，
     `public` 行说卡在哪（超时 · 被拒 · 钥匙不符 · 这台没有公网地址），或在同一页换一台当家。
  3. Termius 说**主机钥匙变了**：刚换过家就接受一次；没换过家先别接受，问运维。
  4. 家里宽带刚换了公网地址：地址最多 15 分钟跟上，等一会儿再连。
- Mac：`fleet` 说证书过期就 `fleet login`；`fleet doctor` 的 `fleet` 行写着版本、入口和证书。
- 还不行：把 `fleet doctor` 的输出交给运维。

**中文乱码**（中文画成 `_` 或方块）——连入口端口时手机没带 `LANG`。家机器的入口自 #3196
起自己补 UTF-8（BREAK-IT `entry-no-lang`），断开、重连一次即可。还乱：打开面板，选中会话，
Tab →「在它的目录开 shell」，打
`locale`，`LC_CTYPE` 不是 `…UTF-8` 就是家机器还没更新到那一版——`fleet doctor` 的
`install` 行看版本。

**列表停住**（⌘P 里别的机器的行不动、点进去进不去）——⌘P 第二行写「远端列表 N 没更新 ·
标「失联」的行可能已不在」时，是家机器取列表的身份断了（#3164）。在家机器上 `fleet doctor`
看哪一行红；在 Mac 上 `fleet login` 续证书、`fleet update` 跟上 stable。

**会话结束了**（`/exit`、⌃C、进程被杀）——窗口留在恢复页：↵ 用同一段对话续上 · r 新开 ·
q 回收（`docs/BREAK-IT.md` `session-exit`）。客户端说「会话已结束（mac-b）。fleet 可以恢复。」
时，下一次 `fleet` 就回到那个恢复页。关终端或面板里选「退出 fleet」只断开连接，会话照跑；
⌃D 原样交给会话，空输入时可能退出里面的程序（见「和本地 Claude 的键」）。

**额度和用量在哪看**——入口网页：`<入口>/quota`「我的额度」：每个订阅的 5 小时 / 7 天窗、
什么时候重置、是否用尽；`<入口>/usage`「我的用量」：每天用了多少、个人预算。看台顶行的
「剩余 N%」是**这个会话的上下文**还剩多少，不是额度（手机窄屏不显示它）。
