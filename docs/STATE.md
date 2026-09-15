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
| `needs` | waiting on **you** — a question, a permission/elicitation prompt, or a `⛔ blocked` | `?` / `⊘` / `!` (see below) | red (loud: bold + bell) |
| `looping` | stopped, but really cycling between `/loop` iterations (not truly done) | `↻` | indigo |
| *(unset / empty)* | never ran a turn — idle/ad-hoc pane | blank | dim |

Only **`needs`** is loud (red font, bold, a terminal bell). Everything else is
quiet colored text — a fleet of seven spinning workers should not shout. See the
"loud/quiet hierarchy" rule in the README.

A companion option, **`@claude_state_ts`**, is stamped with the epoch second on
every state write; it drives the dashboard's *"Nm ago"* last-activity column.

### `@claude_needs` — *why* a window is red (issue #640)

`needs` has two causes that want **opposite reflexes**, and until #640 they shared
one glyph, so the operator had to attach to each red window to find out which:

| `@claude_needs` | What is open | Dash / tab glyph | What to do |
|---|---|---|---|
| `ask` | an `AskUserQuestion` | `?` | answer it from the dash — `⌃k`, no attach |
| `perm` | a **permission prompt** | `⊘` | only a human may approve one; `⌃k` shows you *what* is blocked |
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

### 2. The needs badge + cross-fleet dot (the spinner daemon)

[`bin/tmux-spinner.sh`](../bin/tmux-spinner.sh) is an always-on daemon (launchd
`com.claude-fleet.spinner`) that scans every window ~8×/second (`SPIN_INTERVAL`,
default `0.12s`), **change-detected** — it only re-writes an option when the value
actually moves, so a calm fleet costs a handful of `tmux` reads per frame. Its
live jobs today:

- **The needs tally.** It counts windows whose `@claude_state == needs` per
  session and publishes `@attn_needs`; the status-left renders it as the red
  **`● N`** badge (see [`conf/tmux-attention.conf`](../conf/tmux-attention.conf)).
  It also publishes `@attn_other_windows` so a fleet you are attached to shows an
  **orange `● N`** when a *different* fleet has needy windows.
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

A hook cannot tell a **clean finish** from a `/loop` paused **between iterations**
— both look like `Stop` → `done`. And a `done` window may actually hold a pending
question the Notification filter left untouched. So `done` / `needs` / `looping`
are *ambiguous, quiet* states worth a second look by an LLM.

[`bin/classify-sessions.sh`](../bin/classify-sessions.sh) reads the pane text and
asks `claude -p --model haiku` to classify it as `STOPPED` / `WAITING` /
`LOOPING` / `ERROR`, then writes the reconciled `@claude_state` (`done` / `needs`
/ `looping` / `needs`). It is the **only** way the purple `looping` state is ever
set. It is heavily gated so it is cheap and safe:

- **State gate** — it only ever classifies windows already in `done` / `needs` /
  `looping`. A `working` window is never touched (the hook heartbeat is trusted).
- **Change-hash gate** — it hashes the visible pane and skips the LLM call when
  the screen is unchanged since last check, so a static/parked window costs **zero
  tokens**.
- **Per-window lock** — a `mkdir` lock so a Stop-hook fire and a spinner demote
  can't double-run the same window.

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
`FLEET_STUCK_WORKING_SECS=0` to disable.

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

> The spinner carries this errand — as it carries the stuck-`working` sweep and the
> interval-daemon self-heal — because it is **KeepAlive**: one process, up since
> boot, while every other fleet daemon is a `StartInterval` unit,
> and #639 showed those can be pended by launchd for over an hour. A reconcile that
> lived in an interval unit would go dark alongside its patient.

## Who writes `@claude_state` — the whole picture

Four writers, one option, exactly one source of truth per window:

| Writer | When | Writes |
|---|---|---|
| `set-claude-state.sh` (hooks) | every turn edge — instant | `working` / `done` / `needs` (+ the `@claude_needs` reason) |
| `classify-sessions.sh` (haiku) | on `Stop`, and after a stuck-demote — ~1–2s / change-gated | `done` / `needs` / `looping` (reason **cleared**) |
| `tmux-spinner.sh` stuck-demote | a `working` pane frozen ≥120s | `done` (reason **cleared**; then kicks the classifier) |
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
  · change-gated + locked      └──────────────► cross-fleet  →  ● N orange (@attn_other_windows)
      ▲
      │
   stuck-working demote (spinner, #101): a working pane frozen ≥120s → done → re-classify
   stale-needs reconcile (spinner, #658): a `needs` the TRANSCRIPT contradicts → cleared
                                          (or its reason re-settled) — never re-reddened
```

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
- [ARCHITECTURE.md](ARCHITECTURE.md) — the shared-vs-per-fleet split and the
  many-fleets-on-one-machine model.
- [TERMS.md](TERMS.md) — definitions of collector / hub / dash.
