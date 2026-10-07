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
| the next session waiting on you | ⌘J | prefix k | as a tap on 「! N 个在问你」 |
| zoom the right pane | ⌘↩ | F9 | again to restore |
| every key | ⌘/ | prefix ? | |
| quick open | ⌘P | prefix / | type a few letters, ↵ |
| a new task: the writing area on the right | ⌘N | prefix c | below |
| the orchestrating session ⇄ the writing area (issue #2146) | ⌘N again | prefix c again | only with an orchestrator; also the 「新任务」 row's right-click menu |

**Quick open** lists every session — one folded under its parent too. An empty
query lists the most recent first and the one in view last, so ⌘P ↵ is «the one
I was just on». A query keeps the rows it matches: a substring of the name first
(earlier is better, a word start best), then a substring of the machine, state
or repo (`m4`, `needs`), then the letters in order (`crr` → 「Codex: reap
rules」); ties go to the more recent. ⌘P + two letters + ↵ reaches any session
in four keys.

From a zoomed session, ⌘↓ ⌘↑ ⌘[ ⌘] ⌘J unzoom first (⌘P keeps the zoom while you
pick). With no task list on screen they do nothing — prefix h is then still
«the machine before», as prefix q.

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
at once, the machine files the issue (`fleet-issue-file.sh`) and opens its
worker, and the right pane switches to it when its row appears — no token spent
on the way. esc goes back to the session before; the draft is kept on disk
(`~/.local/state/claude-fleet/compose-draft`) until it is sent. The orchestrating
session is reached from its own row, not from the writing area.

## How a ⌘ chord reaches the client

A terminal sends nothing for ⌘ — macOS keeps it. So the client installs an
**iTerm2 Dynamic Profile** named `fleet`
(`~/Library/Application Support/iTerm2/DynamicProfiles/fleet.json`,
`bin/fleet-iterm-profile.py`) whose Keyboard Map turns each chord into a
**private code**:

    ESC [ <code> ~        code 920 next · 921 prev · 922 back · 923 fwd ·
                               924 needs · 925 zoom · 926 help · 927 quickopen ·
                               928 new

No terminal sends `ESC [ 92x ~` for a real key. `conf/tmux-shell.conf` catches
each as `user-keys[<code>]` → `User<code>`, bound to the same body as the prefix
key. The one table is `bin/dash-keymap.sh --panel switch list` (action · ⌘ glyph
· iTerm2 key · code · prefix key); the conf, the `?` sheet and the profile are
all held to it by `bin/fleet-keys-selftest.sh` leg 10.

The profile **adds** a profile and changes none: every other setting comes from
its parent — the profile the window was in when it was written, else iTerm2's
default — and its Keyboard Map is the parent's own with the eight rows on top.
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

**The layout**: `FLEET_CLIENT_LAYOUT=auto` (default — one pane when the list does
not fit beside 80 columns, i.e. under `FLEET_SHELL_WIDTH` + 81 columns, where
the list used to be taken away with nothing in its place) · `single` (always) ·
`split` (never — the old rule, byte for byte).

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
else the row's name.
`bin/fleet-client-layout-selftest.sh` pins the layout, the keys, a real tap on
the line through the nested client, and the widths.

## A session on this computer — `fleet run` (issue #2136)

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
