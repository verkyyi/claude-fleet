# claude-fleet — how Claude state refreshes on windows

> Answers issue #426: *"how [is] Claude state refreshed on windows?"*

Every fleet window carries a **semantic state** — what its Claude session is
doing right now — that the dashboard, the needs badge, and the watcher all read.
This doc traces the whole refresh path: **who sets the state, where it lives, how
it is rendered, and the backstops that correct it** when the fast signal is wrong —
or when it was right once and nothing has re-checked it since.

The design rule underneath it all (see [ARCHITECTURE.md](ARCHITECTURE.md) and the
README): **hooks are fast but semantically blind; the LLM is smart but slow.**
Hooks give the instant signal on every turn edge; a change-gated haiku classifier
later corrects what a hook cannot know. Both write the **same** window option, so
there is exactly one source of truth per window.

## The states

State lives in one tmux **window option**, `@claude_state`, whose value is one of:

| `@claude_state` | Meaning | Dash glyph | Color |
|---|---|---|---|
| `working` | mid-turn — a tool is running or a prompt was just submitted | braille spinner (`⠋…`, animated) | cyan |
| `done` | turn finished cleanly, nothing pending | `✓` | green |
| `needs` | waiting on **you** — a question, a permission/elicitation prompt, or a `⛔ blocked` | `!` — one glyph for every kind since #1328; the kind is in words (see below) | red (loud: bold + bell) |
| `looping` | stopped, but really cycling between `/loop` iterations (not truly done) | `↻` | indigo |
| *(unset / empty)* | never ran a turn — idle/ad-hoc pane | blank | dim |

Only **`needs`** is loud (red font, bold, a terminal bell). Everything else is
quiet colored text — a fleet of seven spinning workers should not shout. See the
"loud/quiet hierarchy" rule in the README.

A companion option, **`@claude_state_ts`**, is stamped with the epoch second on
every state write; it drives the dashboard's *"Nm ago"* last-activity column.

### `@claude_needs` — *why* a window is red (issue #640)

The subtype tells the operator how to respond to a red window:

The dash and the sidebar draw ONE red `!` for every kind (issue #1328 — ten state
glyphs were more than anyone could keep apart); the kind is said in words: the
hub's act column (`在问你` / `等授权` / `被卡住` / `恢复失败` / `运行失败`) and the
sidebar's line under the list for the selected row. The window *tab* keeps the
glyphs below.

| `@claude_needs` | What is open | Tab glyph | What to do |
|---|---|---|---|
| `ask` | an `AskUserQuestion` | `?` | answer it from the dash — `⌃k`, no attach |
| `perm` | a **permission prompt** | `⊘` | only a human may approve one; `⌃k` shows you *what* is blocked |
| `blocked` | a worker-declared blocker (#704) | `⊠` | read the issue's `⛔ blocked` comment and send a new prompt when resolved |
| *(empty)* | anything else (the classifier's `WAITING`/`ERROR`, an unrecognized `Notification`) | `!` | go look |

`ask` arrives at `set-claude-state.sh` free, off the `PreToolUse` `tool_name`. The
`Notification` leg costs one transcript read, and **#656 is why the wording could
never have done it**. Measured on Claude Code 2.1.272, an open `AskUserQuestion`
fires the *identical* `Notification` a blocked `Bash` call does:

```json
{"hook_event_name":"Notification","message":"Claude needs your permission",
 "notification_type":"permission_prompt", …}
```

So the `*permission*` match overwrote the `ask` `PreToolUse` had just stamped, and
the dash showed `⊘` — *"only a human can press this"* — on a question `⌃k` could
have answered. The first real remote-answer attempt hit exactly that and gave up.
The subtype is now settled against the **transcript**, via
[`bin/fleet-pending-tool.sh`](../bin/fleet-pending-tool.sh): the newest `tool_use`
with no `tool_result`. That is the same rule `fleet-answer.sh` and
`fleet-permission.sh` already gate on, so **the dash glyph and the two tools that
act on it can no longer disagree** — which was the actual defect, not the glyph.
A pending `AskUserQuestion` ⇒ `ask`; anything else ⇒ the wording's `perm`; and any
failure (no `python3`, no `transcript_path`, unreadable file) also falls back to
`perm`, the direction that sends the operator to the pane rather than promising an
answer channel that is not there.

**Freshness is by construction, not by timestamp.** `@claude_needs` is written on
*every* non-`leave` state write — a `working`/`done` write clears it — and the other
writers of `@claude_state`
([`classify-sessions.sh`](../bin/classify-sessions.sh), the spinner's
stale-`working` demote) clear it as well. So no reader can ever pair a fresh state
with a stale reason, and readers consult it only while the state is `needs`.
Pinned end to end by [`bin/needs-reason-selftest.sh`](../bin/needs-reason-selftest.sh).

**Worker-declared blockers persist across the rest of the turn (#704).** The
charter uses `sh ~/.claude/fleet/bin/set-claude-state.sh blocked`, which stamps
`needs/blocked` and rings. Ordinary `PreToolUse`, `PostToolUse`, `Stop` and benign
idle notifications preserve both the red and its timestamp. A classifier skips
it, including when the declaration arrives during its model call. An idle
transcript cannot expire it: a blocked worker has stopped with no tool pending.
The reconcile also re-checks the stamp after its probe before applying a verdict.

A new `UserPromptSubmit` clears the declaration and resumes `working`. Its root
`hook_event_name` is parsed only on the blocked path, since prompts and tool
results share the installed `working` hook argument. Invalid input preserves red.
If that prompt did not resolve the blocker, the worker re-stamps `blocked` before
stopping. A live question or permission notification supersedes the declaration
with `ask`/`perm`; those dialogs then follow their ordinary lifecycle. Two checks
confirming no live Claude also clear it; Codex remains outside the Claude
transcript reconcile. The lifecycle and in-flight-reader cases are pinned by
[`bin/blocked-state-selftest.sh`](../bin/blocked-state-selftest.sh).

Construction keeps the reason *consistent with its state*; it cannot keep either
consistent with **reality**, because both are written on events and a blocked session
produces no further event. That is what the [stale-`needs`
reconcile](#the-other-backstop--stale-needs-reconcile-658) below is for.

## The fast path — Claude Code hooks (instant, semantic-blind)

Claude Code fires shell **hooks** on turn edges. Each one runs
[`bin/set-claude-state.sh`](../bin/set-claude-state.sh), which stamps
`@claude_state` on the **current pane's window** (`$TMUX_PANE`). It is wired in
[`hooks/settings-hooks.json`](../hooks/settings-hooks.json):

| Claude Code hook | Arg passed | Resulting state |
|---|---|---|
| `PreToolUse` | `busy` | `working` (**except** the `AskUserQuestion` tool → `needs` + bell + `@claude_needs=ask`) |
| `PostToolUse` | `working` | `working` |
| `UserPromptSubmit` | `working` | `working` |
| `Notification` | `needs bell` | `needs` + bell (**except** the benign idle prompt → *leave as-is*); the subtype (`perm` / `ask`) comes from the transcript, not the wording (#656) |
| `Stop` | `done` | `done` (then hands off to `classify-hook.sh`) |

The `working`/`done` results above preserve an existing `needs/blocked`, except
for `UserPromptSubmit`, which clears it. `AskUserQuestion` still takes precedence.

Because Claude Code **re-reads `settings.json` hooks every turn**, a running
session picks up hook changes with no restart.

`set-claude-state.sh` is more than a bare write — it carries two important
discriminations so the fast signal does not cry wolf:

- **`AskUserQuestion` → `needs`.** That tool opens a blocking multiple-choice
  popup mid-turn. Left alone the window would masquerade as `working` the whole
  time it is really waiting on you, so the `busy` path inspects the hook's stdin
  JSON for `"tool_name":"AskUserQuestion"` and flips to `needs` + bell immediately.
  (A `Notification` *does* follow about a minute later — as `permission_prompt`,
  indistinguishable from a real permission prompt; this doc used to say none fired
  at all. #656 measured it, and the `Notification` leg now defends the `ask` this
  path stamped rather than overwriting it.)
  **Answer it from the dash** (`⌃k` → `bin/dash-answer.sh` → `bin/fleet-answer.sh`,
  issue #605). A `SendMessage` structurally cannot: a peer message is delivered
  *between* turns, and a pending question **is** the turn — measured, the frame
  reaches the pane and only queues (`enqueue` … then `remove … "absorbed_mid_turn"`
  once answered). So the message waits for the answer that waits for the message;
  somebody has to answer first. `fleet-answer.sh` types the option's digit at the
  pane, but only while the **transcript** shows an `AskUserQuestion` tool_use with
  no tool_result — which is why it can never mistake the OTHER thing `needs` means,
  a permission prompt, for a question. It also stamps `@claude_needs=ask`, which is
  what puts the `?` on the row.
  Every comparison it makes **against the screen** is whitespace-insensitive
  (#656): a narrow pane wraps a long question or option label onto follow-on lines
  — and a CJK break inserts no space where a Latin one eats the space it broke at
  — so a literal `grep -F` missed and the answerer refused a dialog that was on the
  screen and that `--show` had just parsed correctly. Squashing whitespace out of
  both sides keeps the gate exactly as strong while making a line break a non-event.
  And every one of those comparisons is anchored on **the row it is about to press,
  never on the question text** (#702). The question text is the weaker anchor — it
  proves the dialog exists, not that the target row does — and it is the part that
  goes first: options with per-option descriptions routinely run taller than the
  pane, so the question scrolls off the top while every option row is still plainly
  visible, and the gate refused four remote answers in one evening on dialogs the
  operator could read. `right_tab` keeps the only thing that anchor was
  load-bearing for: that a *multi-question* dialog is on OUR tab, which matters
  because two tabs can share option labels in different orders. The same issue's
  second cause is a **column** one: options carrying `preview` text render a
  bordered panel to the RIGHT, and `capture-pane` returns whole terminal rows, so a
  slice of that panel is glued onto every option row — "the row equals the label"
  was false for every row at once, and squashing only pulled the panel's words into
  the comparison. Each row is therefore cut at its column boundary (the first
  whitespace-preceded box-drawing character) before anything looks at it. The three
  screen shapes that broke it — wrapped label, scrolled question, preview panel —
  have a selftest leg each, because the fourth shape will look like none of them.
- **A permission prompt → `needs` + `@claude_needs=perm`.** The `Notification` says
  only that *some* dialog is open, so what puts `⊘` on the row is the transcript's
  pending `tool_use` being something other than an `AskUserQuestion` (#656). This is the half #605 left open, and on 2026-09-14 it
  cost a worker its session: the prompt is mid-turn for its whole life, so
  `SendMessage` queued underneath it, the issue bridge was dead, `fleet-answer.sh`
  correctly refused (not a question), and `tmux send-keys` is hook-blocked (#437) —
  and a relayed message could not have pressed the key anyway.
  [`bin/fleet-permission.sh`](../bin/fleet-permission.sh) closes it, without ever
  approving anything:
  - `--show` makes the **blocked command and the prompt's own reason readable
    without attaching** (the transcript gives the pending `tool_use`; the reason is
    Claude Code's own text and exists only on the screen, so it is scraped with
    `capture-pane`). This is what `⌃k` falls through to on a `⊘` row.
  - `--deny` presses **`No`, and only `No`** — behind `FLEET_ALLOW_AUTO_DENY=1`,
    **off by default**. Refusing a blocked operation destroys nothing; it hands
    control back to the worker, which can then rewrite the command safely (in the
    real case, `[ -n "$G" ] && rm -f "$G"/*.tick`). "May I auto-answer No?" and "may
    I auto-answer Yes?" are different questions, and nothing in the fleet may answer
    the second. The digit comes from the row the **screen** labels `No` and is
    re-asserted against `/^No\b/` before a key is sent; a missing, ambiguous or
    Yes-only dialog refuses with nothing sent. After the refusal lands (confirmed in
    the transcript, not on the screen) the deadlock is gone, so the reason is handed
    to the worker over the ordinary peer channel.
- **Benign idle prompt → *leave*.** Claude Code emits an idle
  `Notification` (*"Claude is waiting for your input"*) ~60s after **any** session
  goes idle. Unfiltered, that would flip every finished window to `needs` + bell
  and clobber the classifier's verdict. The `needs` path substring-matches the
  wording; a match writes **nothing** (state `leave`) — it just drops the bell —
  so whatever the Stop-hook classifier decided stays authoritative. Anything
  unrecognized keeps `needs` + bell (the safe direction: an idle session rings
  rather than a real prompt being silently missed).

The hook always exits `0`, so it never blocks or slows a turn.

## Where the state is rendered

`@claude_state` is a plain tmux option — a shared **state bus** on the window.
Several read-only surfaces render off it; none of them owns it.

### 1. The fzf dashboard — the primary visible surface

[`bin/tmux-dashboard-rows.sh`](../bin/tmux-dashboard-rows.sh) is a **self-contained
renderer**: it reads `@claude_state` (and `@claude_state_ts`) directly off every
window and paints one row per session — the state glyph, bound issue, summary, PR
status, and context %. It animates the `working` spinner from **its own** frame
clock (perl `Time::HiRes`, quarter-second frames), independent of the spinner
daemon. This is where you actually *see* per-window state.

### 2. The needs badge (the spinner daemon)

[`bin/tmux-spinner.sh`](../bin/tmux-spinner.sh) is an always-on daemon (launchd
`com.claude-fleet.spinner`) that scans every window ~8×/second (`SPIN_INTERVAL`,
default `0.12s`), **change-detected** — it only re-writes an option when the value
actually moves, so a calm fleet costs a handful of `tmux` reads per frame. Its
live jobs today:

- **The needs tally.** It counts windows whose `@claude_state == needs` per
  session and publishes `@attn_needs`; the status-left renders it as the red
  **`● N`** badge (a node's bar until issue #1714; the client's task list reads it now).
  It also still publishes `@attn_other_windows` (needy windows in OTHER fleets),
  but nothing renders it: one fleet per login retired the orange other-fleet dot
  and its jump (#980); the loop is left as is, and with one fleet it reads 0.
- **Per-window styling options** `@spin` / `@sfg` / `@nfg` — historically these
  drove an inline per-window status strip, but that strip was **removed in #105**
  (`window-status-format` is now empty). The options are still tracked; they are
  simply not painted inline anymore. The dashboard (above) is the glyph surface.

> **Per-fleet fan-out (#159).** Each fleet is its own tmux server on its own named
> socket, so there is no single `tmux list-windows -a` across the estate. The
> spinner iterates the live fleet sockets (a POSIX copy of `fleet_sockets`, kept
> in sync with `bin/fleet-lib.sh`) and applies one batched `tmux -L <sock>
> source-file` per fleet per frame.

## The slow path — the haiku classifier (corrects what hooks can't know)

**The deterministic half: `@loop`** (issue #1331). A `/loop` is not invisible to
the hooks after all — the agent schedules its own next round with `ScheduleWakeup`
or `CronCreate`, and a PostToolUse hook (`bin/fleet_loop_mark.py hook`, matcher
`ScheduleWakeup|CronCreate|CronDelete`) records it on the window as `@loop`
(`kind=wakeup next=<epoch> ttl=<s>` / `kind=cron id=<job>@<until>,…`; cleared by
`stop:true` / the last `CronDelete`). Expiry is the reader's: a wakeup not renewed
by `next + max(600, ttl/2)` has stopped; a recurring cron lapses after 7 days. A
`fleet-loop.py` ledger that will still deliver counts too. `fleet_window_loop`
(shell) / `fleet_loop_mark.status` (Python) is the one answer. The Stop hook stamps
`looping` instead of `done` while it is active; the classifier's `STOPPED` read
defers to it; `fleet-reap-live.py` answers `retained:loop` before any age or state
gate; the dash's `k/N` and `fleet-children.sh` count only `done` with no Loop
(sleeping / preparing / waking are quiet, not finished). A Codex worker has no
such tools — its `@loop` stays empty and nothing changes for it.

**Why a ↻ is waiting: `@claude_wait`** (issue #1370). A Loop is not the only way a
quiet window is unfinished. At every Stop (and at the mod's own `done` report)
`fleet_stop_wait` → `fleet_window_wait` asks three things and the Stop writes
`looping` + `@claude_wait=<reasons>` (comma-separated, fixed order) when any holds:

- `loop` — the `@loop` answer above. A session that scheduled its wakeup BEFORE the
  PostToolUse hook was synced has no mark, so when the window has no `@loop` and no
  live mod heartbeat, the Stop first replays the tail of its own transcript
  (`fleet_loop_mark.py backfill`, ≤ `FLEET_LOOP_BACKFILL_BYTES`, default 256 KiB,
  5 s timebox) through the same `apply()` and writes the mark only if it is still
  pending. `fleet-install-apply.sh`'s `loopmark` step does the same for every
  Claude window at sync time (`fleet_loop_mark.py sweep`). Only adds, never clears.
- `children` — a sub-task it spawned is not finished: `fleet_window_waiting_children`
  walks the live windows whose `@origin` chain climbs to this window's key (every
  level, as the dash's `k/N` does) and counts `done` with no live Loop as finished;
  a child whose PR merged leaves the count when cleanup reaps it.
- `bg` — its agent still owns a Bash-tool job (`fleet_window_bg_busy`: the
  `fleet-sleep.py busy` walk behind `fleet_child_busy`'s `bg`, gated on a direct
  `…/shell-snapshots/snapshot-…` child so an idle pane pays one `ps`).

`@claude_wait` only explains `looping` — no new state value — and a Stop with no
reason removes it, so a window that waits on nothing carries exactly the options
it always did. The classifier's `STOPPED` read defers to all three, the reapers
answer `retained:children` / `retained:bg`, and the sidebar's selected-row line
says `等子任务 k/N` / `后台命令在跑`. When the last child lands (its child-report is
a new turn) or the job ends (its task notification is too), the next Stop is `done`.

**Re-asked while idle** (issue #1376). A Stop decides this once, at the edge — so a
window that stopped before #1370 was synced, a parent whose last child just went
idle, or a job that ended without waking its agent would otherwise keep the edge's
answer until its next turn. `fleet_window_reeval` re-asks `fleet_window_wait` for a
window that is `done`, or `looping` WITH a `@claude_wait` (a reasonless `looping` is
the classifier's screen read and is left), and rewrites only `done` ↔ `looping` +
`@claude_wait` — never `working`/`needs`, never a sleep transition, never
`@claude_state_ts` (nothing ran in the pane); the write re-checks the state
server-side. `bin/fleet-wait-reeval.sh` drives it from three places: every
`fleet-sleep-daemon.sh` tick right after the #806 reconcile, the
`fleet-install-apply.sh` `reeval:` step after `loopmark` (`N of M idle window(s)
changed`), and a child's own Stop (`--parent-of`, detached) so the parent flips the
moment its last child goes idle. A pass that changed something runs again (≤ 3) so
a grandchild finishing cascades up. Changes log to `logs/reconcile.log` with
`via=reeval`; `FLEET_WAIT_REEVAL=0` turns it off.

For everything the hooks cannot see, the screen classifier below stays. A hook
cannot tell a **clean finish** from a `/loop` paused **between iterations** when
no schedule was recorded — both look like `Stop` → `done`. And a `done` window may actually hold a pending
question the Notification filter left untouched. So `done` / `needs` / `looping`
are *ambiguous, quiet* states worth a second look by an LLM.

[`bin/classify-sessions.sh`](../bin/classify-sessions.sh) reads the pane text and
asks `claude -p --model haiku` to classify it as `STOPPED` / `WAITING` /
`LOOPING` / `ERROR`, then writes the reconciled `@claude_state` (`done` / `needs`
/ `looping` / `needs`). It is heavily gated so it is cheap and safe:

- **State gate** — it only ever classifies windows already in `done` / `needs` /
  `looping`. A `working` window is never touched (the hook heartbeat is trusted).
- **Change-hash gate** — it hashes the visible pane and skips the LLM call when
  the screen is unchanged since last check, so a static/parked window costs **zero
  tokens**.
- **Per-window lock** — a `mkdir` lock so a Stop-hook fire and a spinner demote
  can't double-run the same window.

**Which model reads the screen is a switch** (issue #1229): `CLASSIFY_BACKEND`,
set in the install's `fleet.conf` / `fleet.settings` or the environment.

- `haiku` (default) — `claude -p --model haiku`, today's behaviour byte for byte
  (measured p50 6.7s / p95 18s per call, accuracy 0.79 on 39 hand-labelled screens).
- `jev` — Jev (TypeSafe System One, `POST /v1/systemone`) with the same five rubric
  lines as choice criteria and the same capture as its state: 0.90 on the same
  screens at 124ms p50, and 100% on the 28/39 it was ≥0.7 confident about — so a
  verdict under `CLASSIFY_JEV_MIN_CONF` (0.7) **falls back to haiku**, as does a
  missing key (`TYPESAFE_API_KEY`, else `~/.config/typesafe/api_key`), a request
  that fails or exceeds `CLASSIFY_JEV_TIMEOUT` (1s), or an unparseable answer — each
  with one `classify.log` line. With no key it is exactly `haiku`. A verdict line
  Jev decided carries `via=jev conf=…`; the #846 rule (a WORKING read never promotes
  a quiet window) applies to it too.
- `shadow` — haiku decides exactly as `haiku`; Jev is asked the same capture and
  `{ts, window, hook_state, haiku, jev, conf, hash, latencies}` is appended to
  `logs/classify-shadow.ndjson` (0600; the capture text only on a disagreement, so
  the rows to hand-label are self-contained). Window state is never touched by
  the Jev half. `bin/classify-shadow-report.py [--labels FILE]` prints agreement,
  per-confidence buckets, WORKING misreads per side and the disagreement list —
  the week-long shadow run the issue asks for before the default moves.

`bin/classify-backend-selftest.sh` pins all three legs against a loopback fake
Jev (never a real key or network).

Two things trigger it:

1. **`classify-hook.sh` on `Stop`** — the real-time path. The moment
   `set-claude-state.sh` stamps `done`, [`bin/classify-hook.sh`](../bin/classify-hook.sh)
   backgrounds a `--window` classification so the `done`→`looping`/`needs`
   correction lands within ~1–2s. It backgrounds the work and exits `0`, so it
   never slows the turn; it is a no-op if `claude` isn't on `PATH`.
2. **The stuck-working demote** (below), which kicks the same classifier to refine
   a window it just demoted.

The classifier is **optional** — everything else works without it; you simply lose
`looping` detection and false-alarm correction.

## The floor — native-truth reconcile (#806)

The demoter below reads *activity*; this pass reads the **agent**. Every tick of the
sleep daemon ([`bin/fleet-sleep-daemon.sh`](../bin/fleet-sleep-daemon.sh), 60s, its
own launchd/systemd unit — not the spinner) runs
[`bin/fleet-state-reconcile.py`](../bin/fleet-state-reconcile.py) first, over every
live fleet socket, whatever `FLEET_SLEEP` says:

- **Claude** — Claude Code registers each TUI under `~/.claude/sessions/<pid>.json`
  with `status` (`busy` / `idle` / `shell`), `statusUpdatedAt`, its tmux pane and
  `procStart`, written by the TUI itself with no hook involved. A `working` window
  whose record says `idle`, when both that idle status and the `working` stamp are
  at least `FLEET_STATE_IDLE_SECS` (default **30s**) old, has no turn running —
  either its turn ended without a `Stop`, or the classifier promoted a screen it
  misread after Claude had already stopped: it is demoted to `done`, the reason
  cleared, and the classifier kicked to refine it exactly as the demoter does.
  `busy`, `shell`, a stamp younger than the grace (a turn the TUI has not marked
  yet), or a record whose pid is gone or reused are all left alone.
- **Codex (bound)** — the private app-server RPC: thread `idle` with its last turn
  completed at least the grace ago, stamp equally old → the same demotion.
  Legacy/unbound Codex is left alone.
- **No agent under the pane** (a dead pane, a bare shell) with a stamp older than
  120s → `done` with reason `exited`, so nothing spins on a window nothing runs in.

It only ever demotes `working` — never promotes, never touches `needs`/`blocked`,
panels, or a window in a sleep transition — and the write is one server-side
`if-shell` that re-checks `working`, so a prompt submitted between the read and the
write is never overwritten. Each change is one line in `logs/reconcile.log`; the
heartbeat `global/reconcile.heartbeat` (`at=`, `working=`, `demoted=`, `skipped=`)
feeds `fleet-doctor.sh`'s `state` line.

Why it exists: on 2026-09-19 a window sat `working` for 50+ min at an empty prompt
while the TUI's footer repaint kept `window_activity` bouncing between 44s and
209s — under the demoter's 120s bar as often as not — and the spinner, with the
demoter inside it, had just spent 15h wedged in a busy loop. `logs/stuck.log` held
300 missed-Stop demotions averaging 757s late, 39 of them past 30 min, and the
sleep daemon's largest rejection (`worker is not done`, 34% of verdicts) was fed by
the same windows. Pinned by
[`bin/fleet-state-reconcile-selftest.sh`](../bin/fleet-state-reconcile-selftest.sh).

## The backstop — stuck-working demotion (#101)

A window pinned at `working` whose `Stop` hook was **missed** (a crash, a race, a
turn that didn't emit `Stop`) would otherwise stay `working` *forever* — and the
classifier deliberately skips `working` windows. The spinner daemon catches this
**marker-agnostically**: a genuinely-working Claude session repaints its pane at
least once a second (the elapsed-time counter ticks), so tmux's `window_activity`
stays fresh; a stopped pane freezes and its activity goes stale.

So a `working` window whose `window_activity` age exceeds
`FLEET_STUCK_WORKING_SECS` (default **120s**) across **two consecutive** checks
(a 2-strike debounce) is provably idle → demoted to `done`, and the classifier is
kicked to refine it into `done` / `needs` / `looping`. The large threshold + the
debounce make a false demote of a live session effectively impossible. Set
`FLEET_STUCK_WORKING_SECS=0` to disable. Since #806 this is the **fallback** for a
worker with neither a registry record nor a bound endpoint; the reconcile above is
the floor, and it is not fooled by a pane that keeps repainting while idle.

### This backstop is the floor under auto-handoff (#677)

It is not only a cosmetic fix for a stale window colour. `/fleet-handoff`'s
auto-cycle waits for `@claude_state` to leave `working` and, past
`FLEET_HANDOFF_IDLE_TIMEOUT`, **aborts without clearing**. For the case that
matters most — a turn that emitted no `Stop` hook *at all* (a model cap, #580; a
crash), which pins `working` forever — this demotion is the **only** thing that
can ever open that gate. So two numbers in two different files are load-bearing
on each other:

```
FLEET_STUCK_WORKING_SECS + 2 × STUCK_CHECK_SECS  <  FLEET_HANDOFF_IDLE_TIMEOUT
            (bin/tmux-spinner.sh)                      (bin/fleet-handoff-cycle.sh)
```

Reverse it and nothing errors: an overnight loop simply fills its context and
stops. Shipped, the margin was 40s and nothing was guarding it; it is now 100s
(140s vs 240s), with a required minimum, because the spinner runs at launchd's
lowest CPU/IO tier where a sweep can slip several-fold under load (#653).

`bin/fleet-handoff-invariant.sh` is the explicit check — it parses both constants
out of the two scripts rather than re-declaring them, then layers the conf on top.
`fleet-doctor.sh` prints its verdict per fleet next to a spinner liveness line
(`logs/spinner.heartbeat`, stamped every ~20s — this unit is KeepAlive, so it is
absent from the interval-daemon registry every other daemon's liveness comes
from), `fleet-handoff-cycle.sh` reads both when it has to explain a wait-idle
abort, and `bin/fleet-handoff-invariant-selftest.sh` reds if either default moves
into a dangerous relation.

## The other backstop — stale-`needs` reconcile (#658)

Every writer above fires on an **event**. Nothing re-reads a stamp afterwards — so a
red that was right when it was written stays red once its cause is gone, and a
window that has stopped moving is exactly the window nothing will re-evaluate. Two
shapes of that were live on 2026-09-14:

- a window whose Claude **exited** while red — no hook can ever fire there again;
- two windows showing `⊘` (*"only a human may press this"*) over an **open
  `AskUserQuestion`**. They were stamped by the pre-#657 wording rule minutes before
  that fix went live, and were out of its reach forever after, because a session
  blocked on a dialog fires no further hook. The mislabel is **self-sealing**: it is
  precisely what tells the operator not to answer the thing that would end it.

So the spinner reconciles the stamp against the **transcript**, using the same
[`bin/fleet-pending-tool.sh`](../bin/fleet-pending-tool.sh) oracle that set the
subtype in the first place — asked now about a **window** rather than a file
(`fleet-pending-tool.sh [-L <sock>] <target>` resolves pane → Claude pid → the
session registry's `sessionId` → the transcript, and reports *no live Claude* and
*could not find out* as distinct exit codes, because a reconcile must act on the
first and never on the second). Per red window:

| What the oracle says | Verdict |
|---|---|
| subtype `ask`/`perm`, **nothing** pending | clear to `done` — the red is provably over |
| **empty** subtype, **nothing** pending, stamp older than `FLEET_NEEDS_PLAIN_SECS` | clear to `done` — the screen verdict has served its dwell and the transcript still holds nothing |
| **empty** subtype, **nothing** pending, stamp *inside* that dwell | **leave it** — a worker that stopped to ask a question in prose is really waiting, and must outlive the 20s grace |
| **empty** subtype, something pending | **leave it** — the reconcile re-settles a *wrong* subtype; it never invents a missing one |
| subtype `blocked`, live Claude, any transcript result | **leave it** — the worker's declaration is cleared by a new prompt, not a dwell timer (#704) |
| **no live Claude** in the pane (any subtype) | clear to *(empty)* — nothing can be waiting |
| subtype `ask`/`perm`, something pending | re-settle the **subtype** only (`ask` ⇄ `perm`); the window stays red and `@claude_state_ts` is left alone — the session's activity did not move, only our reading of it |
| anything unknown (no transcript, no `python3`, …) | **leave it alone** |

Three rails make this safe to run unattended:

- **One direction only.** It never creates a `needs` and never re-reddens a window;
  inferring a red out of band is the hook's job, and a second guesser would only
  manufacture false alarms. It also does *not* kick the classifier afterwards (the
  stuck-`working` demote does): the classifier can return `needs` off a stale screen,
  which would re-redden what was just cleared, every tick.
- **Strong evidence clears fast; weak evidence clears slowly** (#699). `ask`/`perm`
  are *defined* by a pending `tool_use` (#656 settles both off this very oracle), so
  "nothing pending" refutes the stamp outright — clear at the ordinary grace. A
  **plain `needs`** (empty subtype) is a judgement about the *screen*, and #658 read
  that as no evidence at all: it required `ask`/`perm`, so a plain `needs` produced
  **no verdict** and nothing could ever clear it. That stranded an entire red path,
  not a few legacy stamps — an empty subtype is what
  [`classify-sessions.sh`](../bin/classify-sessions.sh) writes (it clears the subtype
  by design, #640), and the classifier only ever runs at **Stop**, where a pending
  `tool_use` cannot exist. Clearing it on the same 20s grace is no better, because
  that red is a real **category**: a worker that ends its turn asking the operator a
  question *in prose* is genuinely waiting on a human with nothing open. So the empty
  subtype gets its own, far longer age, `FLEET_NEEDS_PLAIN_SECS` (default **900s**).
  The number is a **trade** — lower and a real "I asked you something" red fades
  before the operator looks; higher and a stale red survives longer. `0` collapses it
  onto the ordinary grace; a very large value restores #658's "never clear an empty
  subtype". The *no live Claude* verdict is deliberately **not** slowed by it: that is
  proof nothing can be waiting, not weak evidence about what is.
- **Grace on both axes.** A stamp younger than `FLEET_NEEDS_RECONCILE_SECS`
  (default **20s**, `0` disables) is still settling, and the same verdict must repeat
  across **two consecutive checks** before anything is written — the same 2-strike
  idiom as the stuck-`working` sweep, keyed on the *verdict* so a changed reading
  restarts the count. The strike table is a file, aged out at `FLEET_NEEDS_STRIKE_TTL`
  (default **3× the interval**), so a restart cannot let one stale reading count as
  agreement. That age is a **separate knob** from the interval (#691) because the two
  answer different questions — how *often* to look, and how long one reading stays
  meaningful. Welded together, turning the interval down (as
  `needs-reconcile-selftest.sh` does, to pin the 2-strike rule by **count**) silently
  turned it back into a wall-clock rule: at an interval of 1s the test's arm-then-act
  pair had 3 seconds to run two forking scans, and went red on a busy machine with
  nothing wrong in the code under test. The daemon's own default is unchanged.

Cost, measured on the machine that reported #658: **0.33 s for one pass over the
whole estate** (4 fleet sockets, 22 windows, 2 of them red) — ~150 ms per *candidate*
(a `ps` tree walk for the pane's Claude, plus a `python3` read of the transcript:
35 ms on a 2.1 MB file), and 0.03 s for the window scans. Candidates are only windows
already stamped `needs`, which is 0–2 on a live fleet. At one pass per 20 s that is a
**1.7% duty cycle**, and the cost inside a *frame* is one integer compare — the 0.12 s
animation loop is untouched. `NEEDS_BUDGET` caps a pathological fleet at 8 windows
per pass; the rest are picked up by the next one.

`tmux-spinner.sh --needs-check` runs exactly **one** pass and exits — for an operator
who wants a stale red re-judged now instead of at the next tick, and for
[`bin/needs-reconcile-selftest.sh`](../bin/needs-reconcile-selftest.sh), which drives
passes one at a time so the two-checks-agree rule is pinned by *count* rather than by
wall clock (a wall-clock assertion passes for the wrong reason, which is the mistake
#658 itself was filed on).

`FLEET_NEEDS_TRACE=1` makes every pass leave a line in `logs/needs.log`, acting or
not (#675):

```
12:52:35  (reconcile)   pass  cand=8 acted=0 starved=2 armed=|fleetR:@1:dead|fleetR:@2:idle|
```

`needs.log` is otherwise a record of what the reconcile **did** — a pass that only
arms a strike writes nothing, which is right for a daemon ticking every 20 s forever
but leaves the one question a *stalled* reconcile raises unanswerable. #675 was filed
on seven assertions that all read `got: state=needs` and nothing else, and that single
symptom covers three different defects: a daemon that never started, a pass starved
out by `NEEDS_BUDGET`, and passes that ran but could never get two readings to agree.
The trace separates them at a glance — `cand=` says the pass saw the window, `acted=`
says whether it wrote, `starved=` says the budget ran out first, and `armed=` is the
strike table verbatim, so a stall shows as the *same* set armed over and over. (It was
the third: #691's 3 s strike TTL.) Off by default;
[`needs-reconcile-selftest.sh`](../bin/needs-reconcile-selftest.sh) drives its daemon
with it **on** and dumps the trace, the strike table and every window's stamps when
PART B goes red, so a flake there arrives with its own evidence.

> The spinner carries this errand — as it carries the stuck-`working` sweep and the
> interval-daemon self-heal — because it is **KeepAlive**: one process, up since
> boot, while every other fleet daemon is a `StartInterval` unit,
> and #639 showed those can be pended by launchd for over an hour. A reconcile that
> lived in an interval unit would go dark alongside its patient.

## Who writes `@claude_state` — the whole picture

Five writers, one option, exactly one source of truth per window:

| Writer | When | Writes |
|---|---|---|
| `set-claude-state.sh` (hooks) | every turn edge — instant | `working` / `done` / `needs` (+ the `@claude_needs` reason) |
| `classify-sessions.sh` (haiku) | on `Stop`, and after a stuck-demote — ~1–2s / change-gated | `done` / `needs` / `looping` (reason **cleared**) |
| `fleet-state-reconcile.py` (sleep daemon tick, #806) | a `working` window whose agent is natively idle since after the stamp, or has no agent process | `done` (reason **cleared**; then kicks the classifier) |
| `tmux-spinner.sh` stuck-demote | a `working` pane frozen ≥120s (fallback) | `done` (reason **cleared**; then kicks the classifier) |
| `tmux-spinner.sh` needs-reconcile | a `needs` window the transcript contradicts, ≥2 checks running | `done` / *(empty)*, or the **reason** re-settled — never a new `needs` |

Only the hook knows *why* a window went red, so only the hook **invents**
`@claude_needs`; the classifier and the stuck-demote clear it rather than let a stale
`ask`/`perm` ride a state they just rewrote, and the reconcile only ever corrects it
against the same transcript the hook read.

```
Claude Code hooks (PreToolUse / PostToolUse / UserPromptSubmit / Stop / Notification)
      │  instant, semantic-blind
      ▼
set-claude-state.sh  ─►  @claude_state + @claude_state_ts + @claude_needs  (window options)
      ▲                        │  state bus (one source of truth per window)
      │  slow, semantic        ├──────────────► fzf dashboard  (tmux-dashboard-rows.sh)
LLM classifier (haiku)         │                 self-contained glyph renderer
  classify-sessions.sh         ├──────────────► spinner daemon (tmux-spinner.sh, 0.12s)
  · on Stop (classify-hook.sh) │                 needs tally  →  ● N badge  (@attn_needs)
  · change-gated + locked      └──────────────► (@attn_other_windows — unrendered since #980)
      ▲
      │
   native-truth reconcile (sleep daemon, #806): a working window whose agent's own
                                          registry/RPC says idle since the stamp → done → re-classify
   stuck-working demote (spinner, #101): a working pane frozen ≥120s → done → re-classify (fallback)
   stale-needs reconcile (spinner, #658): a `needs` the TRANSCRIPT contradicts → cleared
                                          (or its reason re-settled) — never re-reddened
```

**How often the spinner reads the bus (#887).** Not every frame. A fleet with an
animated window (`working`/`looping`/`preparing`/`waking`) is read by the same tmux
process that writes its frame (`list-windows ';' source-file`); a quiet fleet is
re-read every 1s, or on its next 0.25s tick when `set-claude-state.sh` has dropped
`<socket path>.dirty` beside the tmux socket. So a hook write reaches the bar in
≲0.3s, any other writer in ≤1s, and a machine with nothing working pays ~1 tmux
fork/s per fleet instead of ~8. `logs/spinner.heartbeat` is `<epoch>
tmux_calls_per_s=<n.n>` — the epoch stays the first token for the liveness readers.

## The fleet mod — the session reports from inside (#1335, EPIC #1334)

Every Claude session `bin/fleet-claude.sh` opens loads the repo's `mod/fleet/`
plugin (`--plugin-dir`, while `FLEET_MOD` is on — the default). It is one more
writer on the same bus — never a second store — and its first job is to say it
is there:

| Option | Written | Means |
|---|---|---|
| `@mod_state` | at `session.start` | `on`, or `off:version` — Claude Code is outside `SUPPORTED` (`mod/fleet/hooks/version.ts`) and the mod registered nothing |
| `@mod_ver` | at `session.start` | the mod's own version |
| `@mod_alive` | at start, then every 15s; unset on a real exit | epoch seconds of the last beat; survives `/clear` (the timer is the module's, not the session's) |

`fleet_mod_alive <win> [session]` (`bin/fleet-lib.sh`) is the one reader: a beat
within `FLEET_MOD_ALIVE_SECS` (45) → take the mod's path; stale, missing, or
`FLEET_MOD=0` → take today's path, which is never removed. `fleet-doctor.sh`'s
`mod` line counts each Claude window as alive / out of range / stale / not loaded.
Feature files under `mod/fleet/hooks/` stand behind the version gate
(`gate.ts`); `lifecycle.ts` owns `session.start` / `session.end`, since the
engine takes one unmatched hook per event per plugin. Checks:
`claude plugin validate mod/fleet` and `claude plugin test mod/fleet`
(`bin/fleet-mod-selftest.sh` runs both where a `claude` CLI exists).

**Context + quota (#1338, `hooks/usage.ts`).** The engine pushes
`session.measure` after every turn and when a rate-limit window moves a point —
rendered or not, so a background window nobody watches reports too. The mod
writes the SAME options [`conf/statusline.sh`](../conf/statusline.sh) does, on
the same scale (newest write wins): `@ctx_pct` / `@ctx_limit`, and — only when
both windows have a reading — `@rl5h` `@rl7d` `@rl_reset` `@rl_ts` plus
`@rl_src mod` (a status-line stamp unsets `@rl_src`, so absent = the status
line). The status line alone also stamps `@ctx_band` / `@model` / `@effort` for
the pane header's right segment (issue #1452); the mod does not write those. The quota watch merges both per `@cc_account` as before
(`fleet_quota_merge`, source column `mod` | `statusline` | `ccquota`), and when
EVERY pool account has a `mod` stamp under 60s old and the ccquota cache is
younger than half `FLEET_ACCOUNT_QUOTA_STALE`, it reads that cache instead of
calling the hub (`fleet-quotawatch: … ccquota fetch skipped`). No mod ⇒ no `mod`
stamp ⇒ every fetch runs as before.

**Tools** (`mod/fleet/hooks/tools.ts`, issue #1340): once the gate is open the
session carries `mcp__fleet__fleet_status` (read-only: this window's binding +
`fleet-children.sh` + `fleet-repo.sh list`), `mcp__fleet__fleet_spawn`
(`issue`, optional `repo` → `dash-issue-session.sh`) and `mcp__fleet__fleet_await`
(`issue`, optional `repo` / `timeout` ≤ 570s → `fleet-await.sh`). A missing,
mistyped or unknown argument, or a repo the fleet does not host, is refused with
the reason before anything runs; a valid call runs the script unchanged and
returns its exit code, stdout and stderr — every cap and guard is the script's.

**The state, said by the session (#1336).** `mod/fleet/hooks/state.ts` writes
the same `@claude_state` the settings hooks do, as the engine knows it:
`turn.start` → `working`; `turn.complete` → `done` (or `looping` while `@loop`
says a Loop is pending); an `AskUserQuestion` call → `needs` + `@claude_needs=ask`
while it is open, `working` once answered; `ScheduleWakeup` / `CronCreate` /
`CronDelete` → `@loop`, through `fleet_loop_mark.py hook` with the PostToolUse
payload (same writer, same value, whichever arrives first). Every state write is
`set-claude-state.sh --via mod <working|done|ask>`: the state write alone —
stdin pinned to `/dev/null`, no Stop decision, no bell, no parent report; the
Stop hook still owns those. Subagent turns are skipped. With the mod alive,
`classify-sessions.sh --window` (the Stop-hook fire and the spinner's demote
alike) makes no capture and no model call and logs `skip:mod` in
`logs/classify.log`; a Codex window or a dead/off mod is classified as before.
`bin/mod-state-selftest.sh` holds both paths.

### The command inbox — commands run, not typed (#1337)

`/clear` + the handoff pickup (`bin/fleet-handoff-cycle.sh`), `/compact …`
(`bin/fleet-compact-send.sh`) and `/model …` (`bin/fleet-model-switch.sh`) used to
be TYPED into the pane. Each now goes through `fleet_session_command [--socket L]
[--from who] <target> '/cmd args'` (`bin/fleet-lib.sh`; `bin/fleet-session-command.sh`
is its CLI) first:

```
$FLEET_CONF_DIR/global/mod-inbox/<socket-label>/<pane-number>/
  <seq>.json    {"cmd":"/clear","args":"","from":"handoff-cycle"}  (posted by rename)
  <seq>.taken   the mod's claim — an atomic mv of the .json
  <seq>.done    {"ok":true} | {"ok":false,"error":"…"}
```

The mod (`mod/fleet/hooks/inbox.ts`) polls it every second on a module timer — so
it keeps polling after a `/clear`, which fires no new `session.start` — and runs
each post with `$.command.run`, which the engine queues until the session is idle.
Keyed by socket label as well as pane id: a pane id is unique per tmux server only.

| exit | meaning | caller |
|---|---|---|
| 0 | ran (`.done` ok) | done — logs `via mod` |
| 6 | taken, not done within `FLEET_MOD_DONE_SECS` (20) — running, e.g. a long `/compact` | done — never type it as well |
| 3 | no mod (`fleet_mod_alive` false, `FLEET_MOD=0`, no pane / socket) | today's send-keys |
| 4 | not taken within `FLEET_MOD_TAKE_SECS` (5) — cancelled by the same rename, so a late mod can never run it | today's send-keys |
| 5 | the engine refused it (`.done` ok=false, reason on stderr) | today's send-keys |

The callers' own gates (idle wait, the operator-typing hold, the handoff's
fresh-session verify, the model switch's status-line verify) are unchanged and
run on both paths. Logs: `handoff-cycle.log` (`/clear via mod`, `… pickup via
mod`), `compact-send.log` (`/compact via mod|send-keys`), and the model switch's
report line (`… in place (Ns) via mod|send-keys`).

Two things a feature file must know about the engine. First, `$` is followed
only within the file it is spelled in, so a feature cannot hand `$` to a
function in another file (validate refuses it). It starts its own timer from a
**matched** `session.start` hook in its own file (e.g. `{ isInteractive: true }`),
which calls `await next(e)` first so the gate in `lifecycle.ts` has run. Second,
a `ui.render` hook is pure: a state write made while it is drawing is denied. A
render hook also has to `read()` its atom on **every** draw, before any early
return, because that read is what subscribes it to redraws.

**Task-progress band** (#1339, trimmed in #1527; `hooks/progress.tsx` +
`progress-model.ts`). Above the prompt it shows one segment, this issue's PR:
`PR #<n> ✓|✗!|…` (plus `冲突!` / `落后` / `待审` / `草稿`, or `已合并` /
`已关闭`). The task number, EPIC k/N, children k/N and context % used to sit
beside it; the top-right corner and the sidebar already show those, so the
band no longer repeats them. A window with no PR — the hub, a scratch, an
issue not yet pushed — draws nothing, and the row takes no height. Every 10s
it refreshes with one `tmux display-message ; list-windows` call and `$.fs`
reads of the dash's `prmap` and the children ledger. It makes no network
calls and writes nothing outside the mod. Children are the windows whose
`@origin` names this one, plus any ledger rows, bucketed as
`fleet-children.py` buckets them — they no longer draw, but every window
(hub and scratch included) still toasts once when a child goes to `!`, as
does an issue window when its PR's checks go red. A toast fires again only
after that condition has cleared and come back.

## Related

- **Auto-handoff nudge (#330).** `set-claude-state.sh`'s `done` branch also emits
  the Stop-hook `block` decision that steers a near-full session into
  `/fleet-handoff` when context crosses `FLEET_AUTO_HANDOFF_PCT`. It reads the
  context % from `@ctx_pct`, which [`conf/statusline.sh`](../conf/statusline.sh)
  stamps on the same window-option bus each render, and the threshold from the
  **conf** — `bin/fleet-hook-conf.sh` (global `fleet.conf` → this fleet's overlay),
  never the hook's environment, which nothing exports into (#561). That is a
  separate feature that happens to ride the `done` state edge — see the inline
  comments in `set-claude-state.sh`. Two rails around it (#571): a **headless**
  `claude -p` child (`CLAUDE_CODE_ENTRYPOINT≠cli` — the Stop-hook classifier, a
  worker's own helper) is not the pane's session, so `set-claude-state.sh` and
  `handoff-latch-reset-hook.sh` exit before touching any window option (its Stop
  used to read the pane's `@ctx_pct`, nudge *itself* into `/fleet-handoff` and
  `/clear` the operator's pane); and the nudge is **held** — no latch, re-judged
  at the next Stop, `@handoff_deferred_ts` stamped — while an attached client
  whose current window is this one has a keypress within
  `FLEET_HANDOFF_DEFER_SECS` (default 30 s; ceiling: threshold+10 fires anyway).
  `SessionStart(source=clear)` also unsets `@ctx_pct`, the stale percentage of
  the session that just ended.
- **Compact in place before the handoff (#1269).** The same `done` edge runs a
  three-step compaction for a **worker** or a **scratch** (`@raw=1`, #1318) whose `@ctx_pct` sits in
  `[FLEET_COMPACT_PREP_PCT, FLEET_AUTO_HANDOFF_PCT)` (defaults 55 / 80, #1571; handoff 0 =
  no upper line; either line set as `FLEET_*_TOKENS` is converted against the
  pane's `@ctx_limit` and wins, #1317), tracked in the window option `@compact_stage`:
  `prep` (a `block` asking for a recovery map at `fleet_recovery_map_path`:
  `<git-dir>/fleet-recovery-map.md`, or — a scratch with no git dir —
  `$FLEET_CONF_DIR/fleets/<sess>/recovery/w<window-id>.md`)
  → `compacting` (next clean Stop: `bin/fleet-compact-send.sh`, detached, types
  `/compact <keep the map>` once the pane is idle and nobody is typing at it)
  → `restored` (`SessionStart(compact)`: `refocus-hook.sh` re-states the charter
  plus a "check the map against git and the PR" line — for a scratch, which has
  no charter, the map itself inline). Hub, panels and codex panes never enter it. Side options:
  `@compact_rearm` (0 after a prep; 1 once a Stop sees the context below the prep
  line), `@compact_prep_ts` / `@compact_send_ts` (60 s dedup each) and
  `@compact_ts` (≥ 600 s between compactions). At or over the handoff line the
  auto-handoff above owns the Stop and none of this runs.
- **Compact at most three times, then hand off (#1316).** Each `compacting → restored`
  bumps `@compact_count`. Once it reaches `FLEET_COMPACT_MAX` (default 3, #1571; 0 = no
  cap), a Stop in `[FLEET_COMPACT_PREP_PCT, FLEET_AUTO_HANDOFF_PCT)` gets the
  auto-handoff `block` ("already compacted in place N times") instead of a new
  `prep` — same `@handoff_armed` latch and typing hold, even with auto-handoff
  OFF. `SessionStart(clear|startup)` (`handoff-latch-reset-hook.sh`) unsets the
  count; `compact` and `resume` keep it.
- **Every step on one ledger (#1320).** `logs/context-ladder.log` (beside
  `handoff-cycle.log`, same size cap — `FLEET_LADDER_LOG_MAX_BYTES`, default
  1 MiB) gets one tab-separated row per step, written by the script that performs
  it through `bin/fleet-ladder-log.sh`: `prep` / `handoff-nudge` (the Stop hook;
  nudge reason `pct`, `cap` or `codex`), `compacting` (`fleet-compact-send.sh`),
  `restored` (`refocus-hook.sh`; reason `fleet`, or `auto` for Claude Code's own
  auto-compaction, which left no other trace) and `handoff-complete`
  (`fleet-handoff-cycle.sh`, with the context % and count from before its
  `/clear`), plus `native-precompact` (`precompact-hook.sh`, #1321: Claude Code's
  own compaction is about to run — reason `<trigger> saved` when the hook wrote
  the recovery map itself, `kept` when the prep step's newer map stands, `no-map`
  on the hub). Columns — epoch, time, step, session, pane, window, ctx %, count,
  reason — are in the file's `#` header. `fleet-doctor`'s `context` row reads it:
  the last 24h's compactions and handoffs, plus the live window highest on the
  ladder and the step it is at.
- **The hub is warned, never cleared (#1319).** A pane with no `@issue`, no
  `@raw` and not a panel has no `/fleet-handoff` cycle to fire and is where the
  operator types, so at the handoff line (`FLEET_AUTO_HANDOFF_PCT` / `_TOKENS`)
  its Stop is never blocked: it gets `@ctx_warn=1` (dash row `⚠ ctx`), ONE
  `FLEET_NOTIFY_CMD` message naming `/fleet-handoff` (the hub's doc goes to FILE
  storage) and one `hub-warn` ladder row. `@ctx_warn` is the once-per-climb latch:
  the first Stop under the line, or `SessionStart(clear|startup)`, unsets it.
  `FLEET_HUB_CTX_ACTION=off` turns it off (default `notify`).
- [ARCHITECTURE.md](ARCHITECTURE.md) — the shared-vs-per-fleet split and the
  many-fleets-on-one-machine model.
- [TERMS.md](TERMS.md) — definitions of collector / hub / dash.
