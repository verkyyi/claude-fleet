# claude-fleet — session lifecycle facts (`FLEET_EMIT_URL`)

An optional, **off-by-default** emitter that POSTs four facts about a session's
life to an endpoint you configure. It exists so that spend can be joined to
outcome, and it does nothing else.

OFF by default (issue #625). A fleet opts in by setting `FLEET_EMIT_URL`.

## Why the fleet has to be the one to emit this

The fleet is the **only** component that knows what a session was *for*. It binds
a session to a GitHub issue, gives it a worktree, and watches the PR that comes
out of it. Nothing else in the stack holds that mapping.

Downstream, a usage ledger knows what each session **cost** — but keyed by machine
and session id, with no idea which issue was being worked. The join between the
two is one field, and without this emitter it is nowhere: you can see that a week
burned N tokens, and separately that M issues closed, and you cannot connect them.

This is the emitter half only. The consumer side — the hub that receives these
facts and joins them to token spend — is [verkyyi/tokenledger#32](https://github.com/verkyyi/tokenledger/issues/32).

## Explicitly NOT a web UI for the fleet

Worth writing down because it is the obvious next thought and it is wrong. The
fleet's UI advantage is that it is *where you already are*: hooks flip the status
bar the instant state changes, no polling lag, `prefix+a` jumps you to the session
that needs you. A browser mirror of that is strictly worse — it cannot jump you
anywhere, and it would have to re-derive state the hooks already own.

The view that *does* earn a browser is the cross-session, over-time one — spend
against outcome, backlog flow, what a week of agent work produced. That is a
different product's job, and it only needs the fleet to **emit**. The fleet stays
a tmux product.

## Turning it on

```sh
# in the global fleet.conf, or a fleet's own conf (per-fleet wins)
FLEET_EMIT_URL="https://ledger.example/ingest/fleet"
FLEET_EMIT_TOKEN="…"        # sent as: Authorization: Bearer <token>
```

Per-fleet by design: two fleets watching different repos can report to different
endpoints. Advanced env-only knobs: `FLEET_EMIT_QUEUE_MAX` (spool cap in events,
default 500) and `FLEET_EMIT_TIMEOUT` (per-POST curl timeout in seconds,
default 5).

`fleet-doctor.sh` prints an `emit` line once any fleet is armed — including the
one failure mode that is otherwise invisible: a spool that has stopped draining.

**With `FLEET_EMIT_URL` unset, nothing happens at all** — no spool directory, no
file, no socket, no behaviour change on any path. That is a rail, not a default:
the fleet's value is that it works on a laptop with nothing else installed.

## What leaves the machine — the whole list

| field | example | notes |
|---|---|---|
| `event` | `session.start` | one of the four below |
| `ts` | `2026-09-14T22:08:32Z` | UTC, second granularity |
| `session` | `fleet-claude-fleet` | the fleet's own session name |
| `session_id` | `c4f29b45-7062-…` | **the join key** — Claude Code's session id |
| `repo` | `verkyyi/claude-fleet` | |
| `issue` | `625` | number, or absent for a scratch |
| `pr` | `646` | number |
| `branch` | `issue-625` / `scratch-7` | |
| `from_branch` | `scratch-7` | `session.bind` only |
| `via` | `hook` / `reap` | `session.end` only |
| `source` | `startup` `clear` `resume` `compact` | `session.start` only |
| `reason` | `prompt_input_exit` `clear` `logout` | `session.end via=hook` only |
| `state` `action` | `MERGED` / `merged` | `session.pr` only |
| `outcome` `verdict` | `landed` / `merged-pr` | `session.end via=reap` only |

**And nothing else.** No prompt or transcript content. No file paths (the hook
payload carries `transcript_path` and `cwd`; both are dropped). No issue titles
and no window names — a scratch window is named by free operator text. No
hostname and no username: identity rides in the bearer token, not the payload,
which is the same charter scrub the issue-comment footer follows.

This is enforced by construction, not by discipline. Every value passes through a
per-field charset filter in `bin/fleet-emit.sh` before it reaches the JSON —
which is simultaneously the privacy rail (nothing can ride along in a field) and
the JSON safety rail (no quote, backslash, newline or control byte survives, so a
value can neither break the object nor smuggle in a second key).
`bin/fleet-emit-selftest.sh` asserts both directions, and that the delivered
object contains **only** allowlisted keys.

"My agent orchestrator phones home" is exactly the thing people will — rightly —
check before enabling this. The list above is the answer, and the selftest is the
proof.

## The four facts, and where each one hangs

The hooks already fire on every state transition (that is how window colours flip
without polling), so the emitter hangs off the **existing** paths rather than
introducing a second source of truth for session state.

### `session.start` — SessionStart hook

```json
{"event":"session.start","ts":"…","session":"fleet-claude-fleet",
 "session_id":"c4f29b45-…","repo":"verkyyi/claude-fleet","issue":625,
 "branch":"issue-625","source":"startup"}
```

Emitted on **every** SessionStart, `source` included. A `/fleet-handoff` cycle
ends one session id and starts another on the same issue, and both halves of that
spend belong to the issue — so `source=clear` is a fact worth having, not noise.
A headless `claude -p` helper inherits the pane's hooks but is not the pane's
session (issue #571) and emits nothing.

Codex also emits this event through the shared hook table. Its Claude-only
handoff-latch handler is excluded by `hooks/codex-map.json`.

### `session.bind` — `bin/fleet-bind.sh`

```json
{"event":"session.bind","ts":"…","session":"…","repo":"…","issue":625,
 "branch":"issue-625","from_branch":"scratch-7"}
```

A scratch became the worker for issue N. **This transition must be emitted** or
every scratch that turned into real work is attributed to nothing: the session
spent its tokens under `scratch-7` and landed a PR under `issue-625`, and only
this line joins the two.

### `session.pr` — `bin/tmux-pr-refresh.sh`

```json
{"event":"session.pr","ts":"…","session":"…","repo":"…","issue":625,
 "pr":646,"branch":"issue-625","state":"MERGED","action":"merged"}
```

The PR refresher already rewrites the whole prmap every ~15s, so a PR transition
is a **diff** of the file about to be replaced against the one just fetched — no
second poller, no second source of truth. `action` ∈ `opened` | `merged` |
`closed`. CI churn is not a transition (only `state` is compared), and a **cold**
prmap emits nothing: without that guard the first tick after an install would
report up to 100 PRs as if they had just happened.

### `session.end` — two `via` values, because two different things end

```json
{"event":"session.end","ts":"…","session_id":"c4f29b45-…","repo":"…",
 "issue":625,"branch":"issue-625","via":"hook","reason":"prompt_input_exit"}

{"event":"session.end","ts":"…","session":"…","repo":"…","issue":625,
 "pr":646,"branch":"issue-625","via":"reap","outcome":"landed",
 "verdict":"merged-pr"}
```

- **`via=hook`** — an agent session ended (SessionEnd hook). It carries the
  ledger's session id and the CLI's own `reason`. `reason=clear` is a handoff
  cycle on Claude. Codex currently reports `reason=other` for thread lifecycle
  ends; this event does not close its tmux window. The Codex launcher requests
  the shared close-on-exit cleanup only after its foreground CLI exits
  successfully, with the same global opt-out and worktree preservation rules.
- **`via=reap`** — the *fleet* session ended: the worktree was reaped, so the
  outcome is known. This rides `fleet_reap_record` in `bin/fleet-lib.sh`, the one
  choke point every reaper funnels through (the SessionEnd hook's detached
  `--exec`, the dash ⌃x reap, the cleanup daemon, ledger-watch) — which is what
  keeps "how the work ended" a single source of truth instead of a fifth copy of
  the reap rules. `outcome` is `landed` or `closed-unlanded`; `verdict` is the
  raw gate word (`merged-pr` / `ancestor` / `unmerged` / `dirty`).

The two are different facts about the same session, not duplicates. A worker that
merges and is reaped by the cleanup daemon emits only `via=reap`; a worker the
operator ⌃d's out of emits both.

## How it stays out of the way

Emission is fire-and-forget and **can never block or fail a session**:

- An emit is the write of one small file into a bounded spool, then a **detached**
  drain with every fd closed. The caller — a hook, a reaper, a daemon — returns
  as soon as the file is written.
- A dead endpoint is a silent no-op, never a stalled worker. The drain runs one
  `curl` per event with a hard timeout, stops at the first retryable failure, and
  leaves the rest spooled for the next kick. **Nothing ever retries in the
  foreground**, and nothing sleeps.
- The spool is capped (`FLEET_EMIT_QUEUE_MAX`, default 500) and drops the
  **oldest** on overflow, so a permanently dead endpoint costs a fixed amount of
  disk and keeps the fresh tail rather than wedging on stale events. "Oldest" is
  the spool file's name: fixed-width digits, `<sec>-<µs>-<pid>-<random>.json`,
  so a plain glob is the arrival order even inside one second (issue #815).
- A **4xx is treated as permanent** and the event is dropped. One malformed event
  must not wedge the queue forever.
- Concurrency is free: one file per event, so every window of every fleet can emit
  at once without interleaving, and the drain deletes exactly what it delivered.
  The drain is single-instance via an atomic `mkdir` lock.

Spool location: `$TMPDIR/.claude-dash/emit` (`FLEET_EMIT_DIR` overrides it — the
selftest's seam). `bash ~/.claude/fleet/bin/fleet-emit.sh --queue-depth` prints
how many events are waiting.

## Files

| file | role |
|---|---|
| `bin/fleet-emit.sh` | the ONE outbound channel: filter → spool → detached drain |
| `bin/fleet-emit-selftest.sh` | hermetic tests (off-is-off, the allowlist, injection, the cap, 4xx, the prmap diff, the wiring) |
| `hooks/settings-hooks.json` | `session.start` on SessionStart, `session.end --via hook` on SessionEnd |
| `bin/fleet-bind.sh` | `session.bind` |
| `bin/fleet-lib.sh` (`fleet_reap_record`) | `session.end --via reap` |
| `bin/tmux-pr-refresh.sh` (`emit_pr_transitions`) | `session.pr` |
