# claude-fleet — how Claude state refreshes on windows

> Answers issue #426: *"how [is] Claude state refreshed on windows?"*

Every fleet window carries a **semantic state** — what its Claude session is
doing right now — that the dashboard, the needs badge, and the watcher all read.
This doc traces the whole refresh path: **who sets the state, where it lives, how
it is rendered, and the two backstops that correct it** when the fast signal is
wrong.

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
| `needs` | waiting on **you** — a question, a permission/elicitation prompt, or a `⛔ blocked` | `!` | red (loud: bold + bell) |
| `looping` | stopped, but really cycling between `/loop` iterations (not truly done) | `↻` | indigo |
| *(unset / empty)* | never ran a turn — idle/ad-hoc pane | blank | dim |

Only **`needs`** is loud (red font, bold, a terminal bell). Everything else is
quiet colored text — a fleet of seven spinning workers should not shout. See the
"loud/quiet hierarchy" rule in the README.

A companion option, **`@claude_state_ts`**, is stamped with the epoch second on
every state write; it drives the dashboard's *"Nm ago"* last-activity column.

## The fast path — Claude Code hooks (instant, semantic-blind)

Claude Code fires shell **hooks** on turn edges. Each one runs
[`bin/set-claude-state.sh`](../bin/set-claude-state.sh), which stamps
`@claude_state` on the **current pane's window** (`$TMUX_PANE`). It is wired in
[`hooks/settings-hooks.json`](../hooks/settings-hooks.json):

| Claude Code hook | Arg passed | Resulting state |
|---|---|---|
| `PreToolUse` | `busy` | `working` (**except** the `AskUserQuestion` tool → `needs` + bell) |
| `PostToolUse` | `working` | `working` |
| `UserPromptSubmit` | `working` | `working` |
| `Notification` | `needs bell` | `needs` + bell (**except** the benign idle prompt → *leave as-is*) |
| `Stop` | `done` | `done` (then hands off to `summarize-hook.sh` + `classify-hook.sh`) |

Because Claude Code **re-reads `settings.json` hooks every turn**, a running
session picks up hook changes with no restart.

`set-claude-state.sh` is more than a bare write — it carries two important
discriminations so the fast signal does not cry wolf:

- **`AskUserQuestion` → `needs`.** That tool opens a blocking multiple-choice
  popup mid-turn, and **no `Notification` hook fires for it**. Left alone the
  window would masquerade as `working` the whole time it is really waiting on you,
  so the `busy` path inspects the hook's stdin JSON for
  `"tool_name":"AskUserQuestion"` and flips to `needs` + bell.
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

### 3. The watcher

The zero-token watcher ([docs/WATCH.md](WATCH.md)) reads `@claude_state` off the
same bus to fire its `stuck` / `needs` edges — it never polls GitHub for this.

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

## Who writes `@claude_state` — the whole picture

Three writers, one option, exactly one source of truth per window:

| Writer | When | Writes |
|---|---|---|
| `set-claude-state.sh` (hooks) | every turn edge — instant | `working` / `done` / `needs` |
| `classify-sessions.sh` (haiku) | on `Stop`, and after a stuck-demote — ~1–2s / change-gated | `done` / `needs` / `looping` |
| `tmux-spinner.sh` stuck-demote | a `working` pane frozen ≥120s | `done` (then kicks the classifier) |

```
Claude Code hooks (PreToolUse / PostToolUse / UserPromptSubmit / Stop / Notification)
      │  instant, semantic-blind
      ▼
set-claude-state.sh  ──►  @claude_state  +  @claude_state_ts   (tmux window options)
      ▲                        │  state bus (one source of truth per window)
      │  slow, semantic        ├──────────────► fzf dashboard  (tmux-dashboard-rows.sh)
LLM classifier (haiku)         │                 self-contained glyph renderer
  classify-sessions.sh         ├──────────────► spinner daemon (tmux-spinner.sh, 0.12s)
  · on Stop (classify-hook.sh) │                 needs tally  →  ● N badge  (@attn_needs)
  · change-gated + locked      │                 cross-fleet  →  ● N orange (@attn_other_windows)
      ▲                        └──────────────► watcher (fleet-watch.sh)  stuck/needs edges
      │
   stuck-working demote (spinner, #101): a working pane frozen ≥120s → done → re-classify
```

## Related

- **Auto-handoff nudge (#330).** `set-claude-state.sh`'s `done` branch also emits
  the Stop-hook `block` decision that steers a near-full session into
  `/fleet-handoff` when context crosses `FLEET_AUTO_HANDOFF_PCT`. It reads the
  context % from `@ctx_pct`, which [`conf/statusline.sh`](../conf/statusline.sh)
  stamps on the same window-option bus each render. That is a separate feature
  that happens to ride the `done` state edge — see the inline comments in
  `set-claude-state.sh`.
- [ARCHITECTURE.md](ARCHITECTURE.md) — the shared-vs-per-fleet split and the
  many-fleets-on-one-machine model.
- [WATCH.md](WATCH.md) — the zero-token steward wake that reads this state bus.
- [TERMS.md](TERMS.md) — definitions of collector / steward / dash.
