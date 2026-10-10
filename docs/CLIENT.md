# The client — keys for switching sessions

`fleet` on your own computer is the **client**: a task list on the left, the
session you picked on the right (`bin/fleet-shell.sh`, `conf/tmux-shell.conf`).
This page is the contract for moving between sessions from the keyboard
(issue #1903, EPIC #1906 C10) — from anywhere, without first putting the
keyboard on the list.

## The keys

| Action | iTerm2 on a Mac | Any other terminal | |
|---|---|---|---|
| next / previous session, the right pane follows at once | ⌘↓ ⌘↑ | prefix n / p | no wrap at either end |
| back / forward through the sessions you were on | ⌘[ ⌘] | prefix h / l | a closed session is stepped over |
| zoom the right pane | ⌘↩ | F9 | again to restore |
| sessions and actions (also ⌘K / prefix s, issue #2365) | ⌘P | prefix / | type a few letters, ↵ — below |
| 派一件事: one line + a repo, ↵ files it and starts its worker, from any window (issue #2753) | ⌘T | prefix t | below |
| a new task: the writing area on the right | ⌘N | prefix c | below |
| the orchestrating session ⇄ the writing area (issue #2146) | ⌘N again | prefix c again | only with an orchestrator; also the 「新任务」 row's right-click menu |
| open / shut the sub-tasks of the session in view (issue #2167) | ⌘. | prefix . | on a sub-task: shuts its parent |
| the switcher: every session, a new one, the layout (issue #2266) | ⌘K | prefix s | |
| quit fleet: the client's processes here go, the sessions run on (issue #2349) | ⌘Q | prefix Q | below |

This table is the one list of the client's keys: the client opens no key page
and has no key for one (issue #2362 took ⌘/ and prefix ? away, and with them ⌘J
and prefix k). **The session waiting on you** is a tap on the bar's red
「! N 等你」 — it unzooms, puts the list on that row and the right pane on it.

**⌘P — sessions and actions** (issue #2365: 「一切优化为 CLI」 — the way in is the
keyboard, not the right-click menu, which stays but is advertised nowhere) lists
every session — one folded under its parent too — each with `#单号 · 机器 · 状态 ·
PR · 回收方式`. On the lit row: **⌃R** 改名 · **⌃X** 回收 · **⌃A** 回答 (on a row
that is not asking: onto the first one that is) · **⌃E** 改回收方式 · **⌃O** 打开
PR (a row on another machine: its PR's page, else its issue's). Each key runs
THAT row's own menu item, never a second copy. A query starting `>` lists the
panel's commands first — 退出 fleet · 新会话 claude / codex · 切到多 / 单会话视图 ·
改名当前会话 — then the row menu's. The panel's last line says its keys. An empty
query lists the sessions waiting on you first, then the most recent and the one
in view last, so ⌘P ↵ is «the one I was just on». A query keeps the rows it matches: a substring of the name first
(earlier is better, a word start best), then a substring of the machine, state
or repo (`m4`, `needs`), then the letters in order (`crr` → 「Codex: reap
rules」); ties go to the more recent. ⌘P + two letters + ↵ reaches any session
in four keys.

From a zoomed session, ⌘↓ ⌘↑ ⌘[ ⌘] unzoom first (⌘P keeps the zoom while you
pick). With no task list on screen they do nothing — prefix h is then still
«the machine before», as prefix q.

**派一件事** (issue #2753): ⌘T — or prefix t, or ⌘P's first line 「⚡ 派一件事…」 —
from any window (a worker's, the orchestrator's, Claude or Codex, a bare shell, a
session on another machine) opens a small popup (`bin/fleet-quick-dispatch.py`): a
title, the repo (the one your last task went to; ←→ when there are several) and
「交给 Codex」 (⌃X). ↵ writes the writing area's own payload and hands the list
`compose`, exactly as the writing area's ↵ does — no model and no orchestrator
queue on the way — so the list draws 「开工中…」, switches to the new session's
row when it shows, and says 「已建 #N 并开工」. `/qd` in the orchestrator's window
is the same thing from inside it (fleet-issue-file.sh either way). ⌘P's top group
— 派一件事 · + 新会话 · the layout flip · 退出 fleet — needs no `>`; an empty ⌘P
still lights the session before, so ↵ there is «the one before» as it was.

**A new task** (issue #1953): ⌘N — or prefix c, or a tap on the list's first row
「+ 新任务」 — turns the right pane into the writing area (`bin/fleet-compose.py`,
the stage's `@fleet_role portal` window, made once). Write as many lines as you
like (⇧↵ — the `fleet` profile sends it as 0x0a — ⌃j or ⌥↵ start a new one);
drop a file on the window and its path is an attachment. Under the box sit three
options, already picked, so ↵ needs none of them (issue #2231; Tab walks to them,
↵ or space opens one): **仓库** — the repo of the session you were on, else the
one your last task went to; or 「无仓库 · HOME」, a session in your home directory
with no issue — **节点** — the machine the hub would pick (fewest running);
维护中 / 失联 machines are greyed — and **Agent** — this fleet's default
(`FLEET_AGENT`). A change is for this send only: the next ⌘N shows the defaults
again. ↵ sends: the first line is the issue's title, the whole text its body (a
HOME session starts on the whole text). The list draws 「开工中…」 under 「新任务」
at once. When that machine has a session already open and idle for this repo
(or HOME) and agent — the warm pool, `scratch-pool.sh` — it takes that one and
submits your text into it as its first turn (plus one line: the issue and branch
follow), and answers in about a second (issue #2234); the issue is then filed and
the session bound to it in the background (`fleet-start-backfill.sh`, issue
#2235): the same window becomes `issue-N` in place, and the agent hears its issue
and branch on its next turn, never in the middle of one. A filing that fails
three times leaves the session working and its row marked 「单子没建上」 (a red
`∅`). With none
ready it files the issue (`fleet-issue-file.sh`) and opens its worker as before.
The right pane switches to it when its row appears — no token spent on the way. esc goes back to the session before; the draft is kept on disk
(`~/.local/state/claude-fleet/compose-draft`) until it is sent. The orchestrating
session is reached from its own row, not from the writing area.

## How a ⌘ chord reaches the client

A terminal sends nothing for ⌘ — macOS keeps it. So the client installs an
**iTerm2 Dynamic Profile** named `fleet`
(`~/Library/Application Support/iTerm2/DynamicProfiles/fleet.json`,
`bin/fleet-iterm-profile.py`) whose Keyboard Map turns each chord into a
**private code**:

    ESC [ <code> ~        code 920 next · 921 prev · 922 back · 923 fwd ·
                               925 zoom · 927 quickopen · 928 new · 929 fold ·
                               930 switcher · 931 quit

924 (⌘J) and 926 (⌘/) are retired (issue #2362) and never reused: a profile
written before the update still sends them, and the conf catches both and does
nothing with them until the next start rewrites the profile without them.

No terminal sends `ESC [ 92x ~` for a real key. `conf/tmux-shell.conf` catches
each as `user-keys[<code>]` → `User<code>`, bound to the same body as the prefix
key. The one table is `bin/dash-keymap.sh --panel switch list` (action · ⌘ glyph
· iTerm2 key · code · prefix key); the conf, the full sheet and the profile are
all held to it by `bin/fleet-keys-selftest.sh` leg 10.

The profile **adds** a profile and changes none: every other setting comes from
its parent — the profile the window was in when it was written, else iTerm2's
default — and its Keyboard Map is the parent's own with the table's rows on top.
`fleet` wears it only while attached (`ESC ] 1337 ; SetProfile=fleet` before the
attach, the profile it came from after the detach), so outside the client
iTerm2 behaves as it always did.

- **Written** at every client start and reload (`fleet-shell.sh iterm_keys`) —
  so the install line and every update leave it current. Nothing is written off
  a Mac, or on a Mac with no iTerm2.
- **Removed** with `python3 ~/.claude/fleet/bin/fleet-iterm-profile.py remove`;
  `FLEET_ITERM_KEYS=0` in the environment removes it at the next start and keeps
  it away (the window then never switches profile).
- **Not iTerm2** (Terminal.app, Termius, ssh from elsewhere — no `ITERM_PROFILE`
  in the environment): the attach is the bare `exec tmux … attach` it always
  was, byte for byte; the prefix keys above do the same jobs.

## Popups draw opaque

The client's tmux server keeps the terminal's left/right margins (DECSLRM) off
(`terminal-overrides[90] "*:Cmg@:Clmg@"`, issue #2362). tmux turns them on for
iTerm2 by itself and then scrolls or clears every rectangle narrower than the
screen — the session pane beside the list, the inside of ⌘P's popup — with a
margin scroll; the popup's content travelled that way too, and any slip in the
terminal's margin handling left the session's text inside the list and the
popup's borders gone. With the margins off tmux redraws those rows cell by cell
around the popup. The popups' own frame has a background of its own (the
palette's `PAL_BG`, `fleet_popup_draw`), so no cell inside is the terminal's
default.

## 复制 — a copy made in a session lands on your device (issues #1766, #2758)

Text you select in a session, and text the session copies for you (Claude Code's
own copy), goes into the clipboard of the device you are typing on — not the
machine the session runs on.

- **How it travels.** The copy is made by the tmux nearest the text (the
  machine's fleet session, `conf/tmux-attention.conf`; or the client's own when
  you are in its copy-mode), which writes it as OSC 52 to its terminal. Each tmux
  further out — the stage (`conf/tmux-shell-stage.conf`), the client
  (`conf/tmux-shell.conf`) — says `set-clipboard on`, so it passes it on, and
  gives every terminal `Ms` (`terminal-overrides[92]`), so it sends one even to a
  terminal tmux has no clipboard row for. A program's own OSC 52, raw or wrapped
  as tmux passthrough, takes the same road.
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

`bin/clipboard-osc52-selftest.sh` runs the three servers on isolated sockets: a
copy-mode copy, a real mouse drag typed into the outer terminal, a program's own
OSC 52 (raw and passthrough) and an outer terminal with no `Ms` of its own all
arrive as OSC 52; the iTerm2 permission's once-only rule; the doctor row.

## 和本地 Claude 的键 — the keys of a local Claude, the same here (issue #2760)

A key you press in a session does what it does in Claude Code run straight in
your terminal (EPIC #2756's yardstick: the same Claude Code version in iTerm2 on
your Mac). The few that do something else on purpose say so below.

- **Extended keys.** Each tmux on the way — the client (`conf/tmux-shell.conf`),
  the stage (`conf/tmux-shell-stage.conf`), the machine's fleet session
  (`conf/tmux-attention.conf`) — says `extended-keys on`,
  `extended-keys-format csi-u` and `terminal-features … extkeys`: it asks the
  terminal for keys WITH their modifiers and hands them on, in the CSI u form a
  local Claude reads, to the pane that asks (Claude Code does; a shell and the
  list do not, and get the old bytes). Before, ⇧↵ arrived as a bare ↵ and sent
  half a sentence.
- **⌃B and the prefix.** The client's prefix is **⌃]**. ⌃B — a local Claude's
  「放到后台」 — goes on to the session when you type it in **iTerm2** (tmux's
  `client_termtype`: there every switch has its ⌘ chord); from any other terminal
  (an iPad's Blink, a phone) ⌃B is still the prefix, as it always was, and ⌃]
  works there too. `prefix ⌃B` / `prefix ⌃]` send that key itself. Wherever this
  page says `prefix`, that is ⌃] in iTerm2.
- **⌥← ⌥→.** The client's iTerm2 profile (`fleet-iterm-profile.py`) makes the
  LEFT ⌥ send Esc+, so ⌥← ⌥→ (and ⌥b ⌥f) move by word as in a local Claude; the
  right ⌥ is the profile's own (typing special characters).
- **Off.** `FLEET_KEYS_PARITY=0` (fleet.conf `[client]`) is everything as before
  #2760: no extended keys on the client's servers, the prefix ⌃B, the left ⌥ the
  parent profile's. A `FLEET_SHELL_PREFIX` of your own wins either way (and then
  ⌃B is plain tmux again). A server already running takes the change at
  `fleet quit` + `fleet`; extended keys are asked of a terminal when it attaches.

The table is the contract: `bin/fleet-keys-selftest.sh` leg 12 reads it — every
row whose bytes column has a value is typed into an outer terminal (a pty) in
front of three tmux servers on isolated sockets with the three real confs, and
the session's pane must receive the SAME key (its modifiers decoded, whichever
encoding tmux chose); 「有意不同」 rows are checked for what this table says they
do. A `+` in the bytes is a second press a moment later; `·` separates encodings
of one key (a terminal's legacy bytes, CSI u, xterm's modifyOtherKeys).

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
| ⌃B | 把正在跑的命令放到后台 | 一样 | iTerm2 里前缀是 ⌃]，⌃B 原样给会话；别的终端 ⌃B 仍是前缀 | `02` |
| ⌃V | 贴图 | 一样 | 客户端先把图送到会话那台机器（#2757，`fleet-client-upload-selftest.sh`） | |
| ⌘V 多行 | 粘贴多行文字 | 一样 | 括号粘贴原样到会话 | `1b5b3230307e6f6e650d74776f1b5b3230317e` |
| 拖文件 | 得到文件路径 | 一样 | 客户端先把文件送过去（#2757） | |
| 选中 / ⌘C | 复制到本机 | 一样 | 见上一节「复制」（#2758，`clipboard-osc52-selftest.sh`） | |
| ⌃D | 空输入时退出 | 有意不同 | 单会话视图（`fleet claude`）里是「放到后台」，会话照跑；别的布局原样给会话 | `04` |
| ⌃\ | （本地没有用途） | 有意不同 | 单会话视图里切到会话所在机器的 shell（#2744）；别的布局原样给会话 | `1c` |
| ⌘K | iTerm2 清屏 | 有意不同 | fleet 里是「切换」（⌘K / prefix s） | |

## Where the state lives

Per client computer, under `$XDG_STATE_HOME/claude-fleet`
(`~/.local/state/claude-fleet`; `FLEET_SWITCH_STATE` overrides):

- `switch-history.json` — the history ⌘[ ⌘] walk (`stack` + `at`, as a
  browser's back/forward) and the recency ⌘P sorts by (`mru`). Written by the
  task list on every change of the session in view, however it changed.
- `switch-rows.tsv` — the rows the list last painted, so ⌘P draws at once; it
  reads every session (the list's producer with `FLEET_ROWS_UNFOLD=1`) a moment
  later.

The keys never switch anything themselves: next / prev / back / fwd and ⌘P's
pick are queued on the list pane's `@sidebar_do` and the list is woken with F12
— so a switch is always the list's own `jump()`, the one place that knows a
proxy window onto another machine from a local one, and two quick presses are
two steps. `bin/fleet-switch-selftest.sh` sends every code to a real list on a
private tmux socket.

## On a phone — one pane, and the top line (issue #1904)

On a screen too narrow for the list beside 80 columns of session — an iPhone or
an iPad in portrait in Termius, a small window anywhere — the client shows **one
pane**: the session, full screen, with its **top line** above it. The list keeps
running behind it (the session is zoomed over it, the window is marked
`@fleet_single`), so every switch still goes through the list's own `jump()`.
Turn the phone, or widen the window, and the list comes back; the session in
view does not change.

    ‹ 3/8 ›  ● working  #1894 机器上一直有会话在忙…   PR #1885 ● 11/13  claude-fleet  @m5

| Tap | Does |
|---|---|
| `‹` / `›` | the session above / below (as ⌘↑ ⌘↓) |
| the title | the **full-screen switcher**: 在等你的 · 最近 (numbered 1–9) · 全部, two-line rows big enough for a thumb; type to filter (`m4`, `?` = only those waiting on you), tap a row or ↵; a digit on an empty filter picks that recent one |
| the key (`#1894`) | the issue, opened on your computer (`fleet-open.sh`) |
| `PR …` | the PR, the same way |
| `@m5` | what is known of that machine, as a note |

**Keys for the Termius extra-key row** (add F1–F4 to it once): **F1** the
switcher · **F2 / F3** the session above / below · **F4** the next one waiting on
you. They act only in the one-pane layout; in the wide layout they go to the
session as they always did. Two taps reach any session: the title, then its row.
*Whether Termius sends F1–F4 and taps on the top line on your own phone is to be
confirmed there; the taps need no setup, and the prefix keys (prefix / · n · p ·
k) do the same jobs if a key does not arrive.*

**The bar** (issue #2365) holds three things: who is signed in (the GitHub login
off `fleet login`'s certificate — orange, with why, when the hub cannot be asked
or refuses this computer), the ⟳ slot, and the keys of WHERE THE KEYBOARD IS — in
a session `⌘P 会话与动作 · ⌘T 派单 · ⌘N 新任务 · ⌘↑↓ 切换 · ⌘Q 退出 fleet`, in the writing
area its keys, in ⌘P the panel's, with the prefix pressed the prefix keys. It is
the same whichever list row is lit. No quota, no 「N 等你」 (the list's red `!` and
⌘P's order say who waits), no machine or issue of the row in view (⌘P and
`fleet show` do).

**The commands** (issue #2365): whatever the menu and ⌘P do, a command does —
`fleet ls [--json]` (名称 · 单号 · 机器 · Agent · 剩余 · 模型 · Effort · 状态 · PR · 回收方式 — 剩余 coloured like the session's own header, 「(N 分钟前)」 past 5 minutes, — from a node too old to report it, issue #2431), `fleet show <会话>`,
`fleet open <会话>` (the client onto it), `fleet rename <会话> <新名>`,
`fleet close <会话> [--yes]`, `fleet reap <会话> <方式>` (merged[:<dur>] ·
done[:<dur>] · loop-end · at:<time> · keep), `fleet answer [<会话>] [<回答>]`. A
session is a name or part of one, `#单号`, or its key; ONE resolver, and two
matches are listed with exit 4 — never a guess (3 = none). They read the
client's own rows and write through the hub by the session's worker_id
(`bin/fleet-session-cli.py`, run inside the client server's environment by
`fleet-shell.sh cli`), so the client must be running — after ⌃D it still is.
`fleet open <url|:port|file>` and `fleet show <file>` are what they were.

**The layout**: `FLEET_CLIENT_LAYOUT=auto` (default — one pane when the list does
not fit beside 80 columns, i.e. under `FLEET_SHELL_WIDTH` + 81 columns, where
the list used to be taken away with nothing in its place) · `single` (always) ·
`split` (never — the old rule, byte for byte) · `multi` (auto's rule, the name
the switcher writes) · `solo` (below).

**The one-session view, `solo`** (issue #2265, EPIC #2259 C6) — what a fresh
install writes: the whole screen is the session. No list (it still runs, zoomed
away behind the session, so the switch keys work), no border, no top line, and
the bar is the same three things as any layout's (below), with `⌃D 放到后台`
where ⌘↑↓ would be. **Leaving is
putting it in the background**: ⌃D (caught by the client; the agent never sees
it — its own `/exit` still ends it), `prefix d` or closing the terminal only
detach, and the terminal says 「会话在后台继续（m5）。下次输入 fleet 回来。」
(`fleet-topbar.py goodbye`, run by `fleet-shell.sh` once the attach returns).
The session runs on under its `@reap_policy`. When the agent ends itself
(`/exit`), the list sees the row in view go `exited` and detaches the client:
「会话已结束（m5）。fleet 可以恢复。」 — the next `fleet` is back on that session's
recovery page (↵ resumes it). `fleet` with the client still running re-attaches
to what it showed; with nothing running it opens the row it showed last (the
switch history's head) once the list has read it, or a new HOME Claude session
when that row is gone (`solo_resume`). The layout lives in the server's
`@fleet_layout` (bar, ⌃D, list); `fleet-shell.sh layout <value>` switches it
live — remembering it in `fleet.conf` is the caller's. Every other layout's
screen is byte for byte what it was: `bin/fleet-client-solo-selftest.sh`.

**⌃\ — the session's shell, and back** (issue #2744; #2566 had it this
computer's). In both one-session views (this layout and `fleet claude`'s own,
below) ⌃\ opens a second window — a login shell of the machine the SESSION runs
on, as its login, in its working directory (the worker's `@worktree`, else its
pane's directory: an orchestrator's `$HOME`, a no-repo session's own), the
fleet's `bin/` first on its PATH, no worker credential in its environment — and
the next ⌃\ is back on the session, the same pane, its connection never dropped;
then the two in turn. `bin/fleet-remote-view.sh shell-open` finds the session
(the window's `@remote`, else the stage's current one) and opens its window,
titled 「shell · <name> @<machine>」 and marked `@solo_shell <machine>:<worker id>`
— one a session: ⌃\ on that session again selects it. Its program (`shell`)
rides the shell's warm master when it answers, else a connection of its own
through the proxy's own ssh (`fleet connect`; a session on THIS computer runs
right here), and runs `shell-here` on the far end, which watches the session's
window: a reaped session closes its shell. A far end older than `shell-here`
gives its login shell in `$HOME`. `prefix \` is the same for a keyboard with no
⌃\ (an iPad's Blink); `prefix !` is THIS computer's shell in `$HOME` (`@solo_shell
local`, also one). The bar's keys read `⌃\ 回到会话` in a shell and `⌃\ 会话 shell`
on the session, and neither the list nor the window list ever shows a shell. The
shell's `exit` closes it (the next ⌃\ opens a new one); ⌃D from it puts the view
in the background as from the session. In every other layout ⌃\ goes to the
pane. `fleet-client-solo-selftest.sh` B and D5, `fleet-remote-view-selftest.sh` S
pin it.

**The top line is the same at every width** — the stage's own status line
(`conf/tmux-shell-stage.conf` → `bin/fleet-topbar.py`): `‹ i/n ›` · state (●
working · ? asking you · ⊘ needs OK · ↻ looping · ✓ done · ○ idle) · key · title
…… PR · repo (only when the client shows more than one) · `@machine` (`⟳ 4s`
while this computer reconnects to it, `offline` when the hub calls it lost, `·
中转` on the hub relay, `旧` behind stable). Narrow, it drops the repo (< 130
columns), the PR (< 110), the state's word (< 70), then clips the title; `‹ i/n
›`, the key and the machine stay. The whole line is red only while the session
asks you a question, grey only while its machine is out of reach.

It reads ONE record, `switch-bar.json` beside the switch history, which the list
writes off the very rows it paints (`fleet-sidebar.py bar_record`) — so the line
and the list never disagree — and bumps the stage's `@fleet_bar_gen`, which the
line's command names: tmux draws it again at once. The title is the issue's
own title (the list's 14th field, carried from the session's machine — #1921),
else the row's name. A session in view that is no row — the orchestrator behind
「新任务」, the steward — gets its record off the refresh loop's cache instead
(`cache_record`, issue #2739); the record lives in `~/.local/state/claude-fleet`,
or `~/.cache/claude-fleet/state` when that cannot be written, a failed write is a
line in `logs/topbar.log`, and a line with no record at all says 「顶行无记录」
rather than pass for a bare shell. Once the client has shown a session (its switch
history), the first screen of a plain `fleet` is the last one you looked at, else
「新任务」 — not the hub's pick's own window, which stays for `fleet <machine>`,
this computer's fleet, and a newcomer's first start (no history: their home page); a bare machine
window an older start left on the stage is cleared at the next start.
`bin/fleet-client-layout-selftest.sh` pins the layout, the keys, a real tap on
the line through the nested client, and the widths.

## A new session in one command — `fleet claude` / `fleet codex` (issue #2264)

`fleet claude [--node m4] [a first sentence…]` (or `fleet codex …`) opens a
**HOME session** — no repo, in your home directory on a fleet machine, with that
agent — and shows it, like running `claude` locally; the words are its first
turn. It is the one HOME-session primitive (EPIC #2259 共同约定 2):
`bin/fleet-home-session.sh` starts the client without attaching (its lease signs
the ask), then `fleet-shell.sh home-session --no-stage` asks
`fleet-client-place.sh - home` — the hub's scratch + `no_repo`, which the node
takes from its warm pool (#2233) or opens cold. A placement that fails prints
the hub's reason and attaches nothing.

**It opens in a view of its own** (issue #2349, `fleet-shell.sh solo <machine>
<worker id>`): the whole terminal is that one session, no list, no top line, one
bottom line 「⌃\ 会话 shell · ⌃D 放到后台 · /exit 结束会话」 with the machine on the right —
whatever layout the client keeps, which `fleet claude` neither reads nor writes.
It is not the client's stage but a tmux server of its own (`-L
<session>-solo-<pid>`, the stage's conf with this bar over it) holding one proxy
pinned to that session, so the client's own view — open in another terminal or
not — never moves with it. A watcher reads the row off the client's list cache
for as long as the view lives: the session going `exited` (the agent's `/exit`)
ends the view, and the terminal is back at its prompt with 「会话已结束（m5）。」.
⌃D, `prefix d` or closing the terminal only put it in the background:
「会话在后台继续（m5）。`fleet` 可以找回。」 — the session runs on, `fleet` lists
it. Either way the view's server goes with the attach, and a client `fleet
claude` had to start for its ask is quit again (`fleet quit`, below), so nothing
of fleet stays behind. No hub (a LOCAL placement): the client attaches, as
before. `--here` is unchanged.

**A regular client already running is never touched** (the issue's hard rule):
`fleet claude` gives it no re-attach pass (which would apply its layout again,
select a machine on its stage, take the lease for this terminal and say where it
is in use) — its lease, held already, signs the ask; the view's server is built
from ONE conf at its start, so the client's top line never runs there; the
view's end, ⌃D or a closed terminal only close the view. Only `fleet quit`
quits the regular client, and `fleet claude`'s own trailing quit (when it had to
start one) is `--if-unattached`: a client someone attached meanwhile stays.
`bin/fleet-client-solo-selftest.sh` D4 pins it with a client attached beside.

A newcomer gets one without asking: a client whose `fleet.conf [client]` says
`FLEET_CLIENT_LAYOUT=solo` (what a fresh install writes) opens ONE HOME Claude
session on its first start, with the line 「这里和本地运行 claude 一样；要在某个
仓库里做，直接告诉我仓库名」 — `home-session.first` in the conf dir records it
(any HOME session writes it). An existing install never sees it.

`--here` is this computer instead — exactly `fleet run` below, which stays as
the 旧写法:

|                    | `fleet claude`            | `fleet claude --here` (= `fleet run claude`) |
|--------------------|---------------------------|-----------------------------------------------|
| runs on            | a fleet machine           | this computer                                 |
| sees the files of  | that machine (`$HOME`)    | this computer (the current directory)         |
| after you quit     | keeps running (reaped by its policy) | ends with the agent                |
| its `/exit`        | back at your prompt       | back at your prompt                           |
| from another device| can be picked up          | no                                            |
| on the session list| yes                       | no                                            |

`bin/fleet-home-session-selftest.sh` pins the dispatch, `--here` ≡ `fleet run`,
a real `fleet codex "hi"` on a fake node (codex · `@norepo` · `$HOME` · "hi"
submitted), and the first-session rule.
`bin/fleet-client-solo-selftest.sh` D pins the view for real (one line, `/exit`
→ the prompt, ⌃D → the background, the client's layout untouched);
`bin/fleet-quit-selftest.sh` E the client quit after it only when `fleet claude`
started it.

## 放到后台 and 退出 fleet — two different things (issue #2349)

- **放到后台** — `prefix d`, closing the terminal window, ⌃D in a one-session
  view: the screen goes, the client and the sessions keep running, the next
  `fleet` is back at once.
- **退出 fleet** — `fleet quit`, ⌘Q (prefix Q without iTerm2; `dash-keymap.sh
  --panel switch`'s `quit` row), the last line of ⌘K and of the row menu: every
  process of the client on this computer goes — the keeper (the lease given
  back at once, so the next client anywhere takes nothing over), the hub loop,
  the actions loop, the warm loop and its ssh masters, the shell's server with
  the list and the bar, the stage with its connections. **The sessions on the
  machines keep running** — a closed proxy only drops its connection — so there
  is no question first, and the terminal says 「fleet 已退出；会话仍在 m5/m4 上运行，
  `fleet` 重新进入。」. From inside the client (a key, a menu) it goes on in the
  background, since what runs it is about to go.
- `fleet status` says which: 「客户端在后台运行（`fleet quit` 退出）。」 or
  「客户端没在运行（`fleet` 进入）。」

`bin/fleet-quit-selftest.sh` pins all of it on private sockets.

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
