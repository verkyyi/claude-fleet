# /fleet-context — how full is my own context window?

<!-- fleet skill · owner: either -->

Claude Code shows the context meter to the **human** — the `/context` command,
the statusline bar — but gives the *model* no way to ask it about itself. This
skill is that missing read: run it from inside your own pane and it reports how
much of this session's context window is already spent, how much headroom is
left, and whether to hand off now. Read-only — it touches no issue, branch, PR,
worktree or window, and works from any seat (a worker, the operator's hub pane,
or a scratch session).

**Argument** (`$ARGUMENTS`): none — it measures the session it is run from.

## 0. Resolve fleet + guard seat (run FIRST, every time)

Env vars do NOT persist across separate Bash tool calls — run this once, then
reuse the literal values it prints:

```sh
source ~/.claude/fleet/bin/fleet-lib.sh
S=$(fleet_current_session); fleet_load_conf "$S"   # → FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH
SEAT=$(fleet_seat)                                 # → worker | "" (the hub pane / a stray shell)
echo "repo=${FLEET_REPO:-} main=${FLEET_MAIN:-} base=${FLEET_BASE_BRANCH:-master} seat=${SEAT:-unknown}"
```

- **No fleet** (`FLEET_REPO` empty) → **ABORT** in one line: *"not inside a
  fleet — run this from a fleet session."* Never guess a repo.
- **Seat**: this skill's owner is `either`, so both the worker seat and the hub
  pane may run it. There is no refusal path beyond the fleet guard above.

## 1. Read the meter

One call — it resolves *this* session's transcript and this pane's statusline
stamp on its own, so pass nothing:

```sh
~/.claude/fleet/bin/fleet-context.sh
```

It prints four lines — `context` (the percentage, the token count, which source
it came from and **which denominator** it used), `session` (turns, output tokens
spent, and the pre-compact peak when the window has already been cleared),
`handoff` (the thresholds in force), and `verdict:` — plus a `cross` line when the
two sources disagree and a `bus` line when this pane's measurement bus is dead
(see below). Add `--json` when you want to branch on a field, or `-q`
for the bare verdict token. Exit code mirrors
[`fleet-pr-verdict.sh`](../bin/fleet-pr-verdict.sh): **0 ⇔ `OK`**, 1 for any
other verdict, 2 for a hard error.

### Where the number comes from

Two independent sources; the script prefers the first and reports both when they
disagree (they legitimately do — see below):

| `src=` | What it is | Caveat |
|---|---|---|
| `statusline` | Claude Code's **own** percentage, stamped onto the pane's window as `@ctx_pct` by [`conf/statusline.sh`](../conf/statusline.sh) every render (issue #330's measurement bus) | only present once a statusline has rendered in this pane — a fleet without one never stamps |
| `transcript` | derived from this session's `~/.claude/projects/<enc-cwd>/<session-id>.jsonl`: the **last main-thread assistant record**'s usage sums to the live context (`input + cache_creation + cache_read + output`) — exactly what the next request re-sends | the percentage needs a denominator (next section), and even with the right one it reads a little **lower** than Claude Code's own number, which also counts the autocompact reserve |

### The denominator, and why the line names it (#477)

The derived percentage is only as good as the window size it divides by, and
getting that wrong is not a rounding error — a **1M-window session measured
against 200k reads 197%** and a false `HANDOFF`. So the `context` line ends with
`limit=<source>`:

| `limit=` | Where it came from | Trust |
|---|---|---|
| `stamp` | `@ctx_limit`, stamped by `conf/statusline.sh` from Claude Code's own `context_window_size` | authoritative — follows the model with no operator action |
| `conf` | `FLEET_CONTEXT_LIMIT` in this fleet's conf | as good as whoever set it; goes stale when the model changes |
| `default` | the built-in 200000 | **suspect on any long-context model** — treat a `HANDOFF` here as unproven |

When both sources exist and disagree, the `cross` line says which explanation
applies: a few points apart is the autocompact reserve; a wide gap means the
derived figure used the wrong window, and the stamp is the one to trust.

### When the `bus` line appears

`bus  @ctx_pct is not stamped on this pane …` means this pane's statusline is not
the fleet's stamping one, so there is no authoritative reading here. It matters
beyond this command: [`bin/set-claude-state.sh`](../bin/set-claude-state.sh) reads
the same `@ctx_pct` at every Stop to decide whether to fire the auto-handoff nudge
(#330), and an unstamped pane reads as `-1` — which never crosses a threshold, so
**auto-handoff cannot fire at all**. That failure is invisible everywhere else, so
it is reported here. The fix is install-side: point `settings.json`'s `statusLine`
at `~/.claude/fleet/conf/statusline.sh` (see [`docs/INSTALL.md`](../docs/INSTALL.md)
step 8b), or add the same stamping block to whatever statusline the machine runs.

Sidechain records are excluded — a fanned-out `Explore` subagent's context is not
yours. A `/clear` or an autocompact just moves the last record, so the live
figure follows it down; when the peak is well above it the `session` line says
so, since a freshly-compacted number looks roomy while the work behind it is not.

## 2. Act on the verdict

| Verdict | Meaning | Do |
|---|---|---|
| `OK` | under the watch band | carry on — no action |
| `WATCH` | getting full | finish the thread you're on, then `/fleet-handoff`. Don't *start* a broad sweep here — delegate it to the `Explore` subagent instead, so the fan-out lands in its context and not yours (the grounding advice in [`/fleet-claim`](fleet-claim.md) step 4) |
| `HANDOFF` | at/over the threshold | run `/fleet-handoff` **now**, before the window forces a compaction — a structured handoff preserves task state far better than near-limit auto-compaction |
| `UNKNOWN` | nothing measurable | no `@ctx_pct` stamp on this pane *and* no usage record yet. Say so; don't guess a number |

A verdict computed on `limit=default` deserves the same caution as `UNKNOWN` if
the fleet runs a long-context model: report the percentage *and* that the
denominator was a guess, rather than acting on a `HANDOFF` that may be arithmetic.

The bands agree with the auto-handoff nudge rather than competing with it: when
`FLEET_AUTO_HANDOFF_PCT` is set (issue #330), `HANDOFF` **is** that threshold and
`WATCH` the 15 points below it, so this read tells you in advance what the Stop
hook is about to say. With the knob off, the fallback bands are the statusline's
own colours — yellow at 50%, red at 80%.

## 3. Report (keep it short)

One line: the percentage, the verdict, and — if it isn't `OK` — what you're doing
about it. Don't paste the whole block back at the operator; they can see the
statusline. If the verdict is `HANDOFF`, don't ask whether to hand off: run
`/fleet-handoff`.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. This skill is read-only, so the base-checkout rail is not
in play: it reads a transcript and three tmux options and writes nothing at all.
