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

## How a ⌘ chord reaches the client

A terminal sends nothing for ⌘ — macOS keeps it. So the client installs an
**iTerm2 Dynamic Profile** named `fleet`
(`~/Library/Application Support/iTerm2/DynamicProfiles/fleet.json`,
`bin/fleet-iterm-profile.py`) whose Keyboard Map turns each chord into a
**private code**:

    ESC [ <code> ~        code 920 next · 921 prev · 922 back · 923 fwd ·
                               924 needs · 925 zoom · 926 help · 927 quickopen

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
