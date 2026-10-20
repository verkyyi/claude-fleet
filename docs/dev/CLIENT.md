# The client — keys for switching sessions

`fleet` on your own computer is the **client** (`bin/fleet-thin.py`):
one foreground Python loop and one connection to your home machine. The home
machine draws the panel, top bar and session. The old two-pane client was
removed in #3008; `--old` and `FLEET_CLIENT=shell` explain the retirement and
open the same current client. Configuration migration comments out old switches.
This page is the contract for moving between sessions from the keyboard
(issue #1903, EPIC #1906 C10) — from anywhere, without first putting the
keyboard on the list.

## One key + the panel (issue #3185, EPIC #3178 C7; issue #3328)

There is **one key**: **⌘P** on a Mac (iTerm2), and on a phone or any terminal
with no ⌘ **⌃空格** (two taps on Termius: Ctrl, space), **F12** (one, once you put
it on Termius' key row) or **⌃] p**. It opens the panel: every session, and every
action. On the ⚡ row, ↵ or Tab opens the editor: write a task, then choose
「开窗预填（不发送）」 to open a session with that draft and send it there, or
「开空白会话」 for a blank session. A session's Tab menu opens its shell;
「退出 fleet」 ends the connection. Open the panel again to return from the
shell or switch sessions. The current panel's steps and row actions are in
[日常使用](../public/zh/member/usage.md#一个键总面板).

**The keys that went (issue #3328, EPIC #3178 ⑤ — kept for good, #4790):** ⌘↓ ⌘↑ ⌘[
⌘] ⌘N ⌘K ⌘Q ⌃\ and the old popup's key still reach fleet: each opens the panel (a
new task / blank session lit on ⚡) and says 「… 已并进 ⌘P」 the first time.
`fleet doctor`'s `oldkeys` row counts how often they are still pressed
(`logs/view-switch.ndjson`, `how=old:<action>`). They stay fleet's: given back to
iTerm2, ⌘Q would quit it.

Want an old key back, or a different one? One line in `fleet.conf`
(`~/.config/claude-fleet/fleet.conf`; `bin/fleet_keys.py` reads it) — a key you
name there is yours, never a forward:

```
[client]                         # this computer's keys
FLEET_KEY_PANEL=cmd+p            # the panel's chord: cmd+' … · off = none
FLEET_KEYS_EXTRA="next=cmd+down prev=cmd+up back=cmd+[ fwd=cmd+] new=cmd+n quit=cmd+q shell=ctrl+\\"
[common]                         # the machine's keys for a phone
FLEET_KEY_PHONE="ctrl+space f12 ctrl+]p"
FLEET_KEYS_PHONE_EXTRA="ctrl+]n=next ctrl+]b=prev ctrl+]c=new ctrl+]q=quit"
```

An extra is `action=chord` (`chord=action` works too); actions are the switch
table's (next prev back fwd new quit) and `shell`, the session's shell.
A chord is `+`-joined `cmd` · `ctrl` · `alt` · `shift` and one key (a character,
`down` `up` `left` `right`, `space`, `tab`, `return`, `esc`, `f1`…`f20`);
`ctrl+]x` is ⌃] then x. A ⌘ chord becomes a row of iTerm2's `fleet` profile
(written by the client at every start); any other chord is bound on the machine
as it is. The client hands its `FLEET_KEYS_EXTRA` to the machine at each attach
(the remote command's environment — an older machine ignores it), and the
machine keeps the union (`@fleet_view_keys_extra`), so a phone attaching with no
extras takes nothing from the Mac's. ⌃] ⌃] always sends one ⌃] on.

- ⌃空格 in a session's shell is readline's set-mark — if you use it, drop
  `ctrl+space` from `FLEET_KEY_PHONE`.
- Not iTerm2 (Ghostty, Terminal.app): a ⌘ chord never reaches the fleet — use
  ⌃] p (or ⌃空格 / F12).

## 侧栏下线清单 — every sidebar job's new home (issue #3186, EPIC #3178 C8)

The old client was removed in #3008 after every row below was ✅. One row per row of the EPIC page's 「侧栏的每一件去哪」
(17 rows covering the sidebar's 24 jobs — the 11 menu items share row 7), no more,
no fewer; a job found later gets a row here and a member issue. Evidence lives
under `$FLEET_CONF_DIR/fleets/fleet/epic/3178/evidence/3186/` (the evidence store
of the time, retired with #4898; never committed) — `panel` · `menus` · `rows` are the mac-c 看台's own
`fleet-quickopen.py view-panel | view-menu | view-rows` output. 「点头」 = 发起人
@dave 2026-10-11 确认方案（「需要你定的事」全部按建议）.

状态：✅ 有证据（17/17，2026-10-11 全绿）

| # | 侧栏今天做的 | 在面板里怎么做 | 证据 | 状态 |
|---|---|---|---|---|
| 1 | 一直看得见谁在干活、谁卡住 | ⌘P：分组 置顶 · 等你 · 在干活 · 等合并/等发版 · 刚落地 · 其他 · ▸已结束（#4225 按「该做什么」细分），组标题带个数；顶上一行只说**这个**会话（#3194 改了页上的「顶上一行写 N 个在等你」，同样点头） | `panel` · 真机（发起人 2026-10-11 真机演练：MacBook + iPhone 全过） | ✅ |
| 2 | 「N 个在问你」，点一下跳过去 | 「等你」组排在最上；系统通知（`fleet_notify.py`）点开直达 | `fleet-view-selftest.sh`（组序） · 真机（发起人 2026-10-11 真机演练：MacBook + iPhone 全过） | ✅ |
| 3 | 问题原话 | 「等你」那一行下面一行（status_msg / `@claude_needs_detail`） | `fleet-view-selftest.sh`（原话行） · 真机（发起人 2026-10-11 真机演练：MacBook + iPhone 全过） | ✅ |
| 4 | 按仓库分组、父子缩进、已结束折起来 | 按「你该做什么」分组；仓库只在 2 个以上时做行尾标签；子会话缩进；已结束折在最下 | `panel` · `rows`（`claude-fleet` / `no repo` 标签） | ✅ |
| 5 | 置顶 | 「置顶」组；Tab →「置顶」（本机的行；别的机器的行侧栏也不能置顶） | `menus`（Pin） · 真机（发起人 2026-10-11 真机演练：MacBook + iPhone 全过） | ✅ |
| 6 | 别的机器的会话、失联变灰 | 同样列出，行尾标机器；失联 / 过期：顶上整条红字 + 那几行「? 失联 N 分钟」，↵ 说进不去 | `panel`（mac-d 的行）· `fleet-view-hub-fresh-selftest.sh` · 真机（发起人 2026-10-11 真机演练：MacBook + iPhone 全过） | ✅ |
| 7 | 点一行出菜单：回答 · 发消息 · 改名 · 停 · 继续 · 唤醒 · 改回收方式 · 回收 · 换账号 · 换 Claude/Codex · 打开它的改动 | 选中按 Tab，同一份菜单（`ACTIONS`；`SIDEBAR_ACTIONS` 一一对照）；别的机器的行有 回答 · 发消息 · 改名 · 改回收方式 · 停 · 回收 · 恢复 | `menus` · `fleet-view-actions-selftest.sh` · 真机（发起人 2026-10-11 真机演练：MacBook + iPhone 全过） | ✅ |
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

**真机演练**（MacBook iTerm2 一遍、iPhone Termius 一遍）：开面板（⌘P / ⌃空格 / F12）→ 派一件新任务 → 开 shell 并回来 → Tab 回收一个 → 回答一个 → 在别的机器上做一个 → 让列表过期看红字。每一步一张截图（当时进证据库，#4898 起附在 PR 里）。

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

924 (⌘J), 926 (⌘/) and 930 (⌘K, issue #3185) are retired (issue #2362) and never reused: a profile
written before the update still sends them, and the conf catches both and does
nothing with them until the next start rewrites the profile without them.

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
| ⌃V | 贴图 | 一样 | 客户端先把图送到会话那台机器（#2757，`fleet-thin-upload-selftest.sh`） | |
| ⌘V 多行 | 粘贴多行文字 | 一样 | 括号粘贴原样到会话 | `1b5b3230307e6f6e650d74776f1b5b3230317e` |
| 拖文件 | 得到文件路径 | 一样 | 客户端先把文件送过去（#2757） | |
| 选中 / ⌘C | 复制到本机 | 一样 | 见上一节「复制」（#2758，`clipboard-osc52-selftest.sh`） | |
| ⌃D | 空输入时退出 | 有意不同 | 原样给会话；离开客户端用面板的「退出 fleet」 | `04` |
| ⌃\ | （本地没有用途） | 有意不同 | 面板中打开会话 shell；可在 FLEET_KEYS_EXTRA 配置快捷键 | `1c` |
| ⌘K | iTerm2 清屏 | 一样 | #3185 起还给 iTerm2（默认只绑 ⌘P） | |

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

**Your address: no command = the 看台** (issue #3071, EPIC #3067 C5). On your
home machine's entry port (`ssh -p 22022 <login>@<name>.cf.example.com`, a key
added on the hub's key page) there is nothing to type: a connection with **no
command on a terminal** lands in your 看台 — the session you looked at last
from that key, else the orchestrator (#3060's first screen); open the panel
with ⌃] p, then use the session's Tab menu for its shell.
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
opens the panel on **⌃空格** (Ctrl, space — two taps), **F12** (one tap, once it
is on Termius' key row) and **⌃] p** — `FLEET_KEY_PHONE`, above. ⌃] ⌃] sends a
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
