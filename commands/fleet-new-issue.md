# /fleet-new-issue — file a new issue and spin up a worker session for it

<!-- fleet skill · owner: steward -->

Turn a task into tracked, in-progress work: create a new GitHub issue in **this
fleet's** `$FLEET_REPO`, then spawn a fresh Claude worker window (git worktree +
`claude`, bound to the issue) to implement it. It **mutates** the fleet's repo
(files an issue) and spawns a session — so it's the **steward's** job: you file
the work and hand it to a worker; you do NOT implement it yourself.

**By default this skill delegates.** The steward is single-threaded, and the
expensive part of filing a good issue is *grounding* it — reading code, greps,
tracing the bug — before the body is drafted. Doing that inline ties the steward
up for a long turn per issue and serializes back-to-back calls. So after the
inline fail-fast guard, the steward launches **one background sub-agent** to do
the grounding + drafting + create + spawn, and its own turn ends immediately —
free to land PRs, triage, or file the next issue while the sub-agent works.
Several `/fleet-new-issue` calls then ground **in parallel** instead of
serializing. Use `--quick` when you want a thin inline capture with no grounding.

**Argument** (`$ARGUMENTS`): the task description — a sentence or a short brief.
An optional leading `--quick` flag selects the thin inline path (see step 3).
If the task text is empty, ask the user what the task is and stop.

## 0. Resolve fleet + guard seat (run FIRST, every time)

This is the ONLY thing that runs inline before delegating — a cheap, fail-fast
guard so a wrong-seat / no-fleet call aborts *before* spending a sub-agent. Env
vars do NOT persist across separate Bash tool calls — run this once, then reuse
the literal values it prints:

```sh
source ~/.claude/fleet/bin/fleet-lib.sh
S=$(fleet_current_session); fleet_load_conf "$S"   # → FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH
SEAT=$(fleet_seat)                                 # → worker | steward | "" (ambiguous)
echo "repo=${FLEET_REPO:-} main=${FLEET_MAIN:-} base=${FLEET_BASE_BRANCH:-master} seat=${SEAT:-unknown}"
```

- **No fleet** (`FLEET_REPO` empty) → **ABORT** in one line: *"not inside a
  fleet — run this from a fleet session."* Never guess a repo.
- **Wrong seat** — `/fleet-new-issue` is `owner: steward`. If `$SEAT` isn't
  `steward`, **refuse in one line and stop**, e.g. *"/fleet-new-issue is
  steward-only; you're in the worker seat."* Never proceed from the wrong seat.

Capture the printed `FLEET_REPO` / `FLEET_MAIN` / `FLEET_BASE_BRANCH` literals —
you'll paste them into the delegation prompt below. Everything past this step
operates on this fleet only.

## 1. Pick the path

- **No `--quick`** (the default) → step 2: delegate the whole thing to a
  sub-agent and end your turn.
- **`--quick <task>`** → step 3: thin inline capture, no grounding.

## 2. Delegate-by-default — launch one sub-agent, then stop

Launch **exactly one** background sub-agent with the **Agent tool** — a fresh
`general-purpose` agent (**not** a fork: a self-contained prompt with no
inherited cross-fleet context). Hand it a prompt that bakes in the resolved
fleet literals and all the rails below, then **end your turn**. You do NOT wait
inline; when the sub-agent finishes, its final line comes back to you and you
relay it (step 4).

Compose the delegation prompt from this template, substituting the step-0
literals for `<FLEET_REPO>` / `<FLEET_MAIN>` / `<FLEET_BASE_BRANCH>` and the
task text (everything after the optional flag) for `<TASK>`:

> You are the steward's filing proxy for one GitHub issue on the claude-fleet
> **`<FLEET_REPO>`** fleet. Base checkout: `<FLEET_MAIN>`; base branch:
> `<FLEET_BASE_BRANCH>`. Operate on **`<FLEET_REPO>` only** — never another
> fleet's repo, sessions, or ledgers.
>
> Task to file: **<TASK>**
>
> Do exactly this, in order:
> 1. **Dedup first.** `gh issue list --repo <FLEET_REPO> --state open --limit 60
>    --search "<keywords>"`. If an open issue already covers this task, do NOT
>    create a new one — reuse that number and skip to step 4 with it.
> 2. **Ground the task** against the code in `<FLEET_MAIN>` (read the relevant
>    files, grep, trace the bug/behavior) so the body is evidence-based. Don't
>    invent scope; a one-liner task gets a short body.
> 3. **Create the issue.** Write a concise imperative **title** (≤ ~70 chars)
>    and a **body** with the goal, a short definition-of-done / acceptance
>    criteria, and concrete pointers (files, related issues). Then
>    `gh issue create --repo <FLEET_REPO> --title "<title>" --body "<body>"`.
>    Add `--label`/`--milestone` only if you know the value already exists.
>    Capture the new number `<N>` from the returned URL.
> 4. **Spawn the worker.** `bash ~/.claude/fleet/bin/dash-issue-session.sh <N>`.
>    This creates the `issue-<N>` worktree + a `claude` window bound to the
>    issue. It enforces the **global + per-fleet** session caps: if a cap is
>    hit it refuses and prints why — **relay that refusal verbatim and do NOT
>    retry or force it.**
> 5. **You file and spawn only — you do NOT implement the task.** The spawned
>    worker owns the implementation.
>
> Return **only** one line and nothing else:
> - success → `#<N> <title> — worker spawned`
> - reused an existing issue → `#<N> <title> — reused, worker spawned`
> - cap refusal → the refusal message from `dash-issue-session.sh`

**Graceful fallback.** If this runtime has no sub-agent / Agent-tool capability,
do NOT hard-fail — fall back to running steps 1–4 of the sub-agent prompt above
**inline yourself** (dedup → ground → `gh issue create` → `dash-issue-session.sh
<N>`), then report per step 4. This is the old behavior; it costs the steward a
long turn, but it never leaves the task unfiled.

## 3. `--quick` — thin inline capture (no grounding)

The `⌃n` backlog behavior as a command: capture the task fast and let the
**worker** do the discovery. Inline (no sub-agent), from the task text alone:

1. Write a short imperative **title** and a **one-line brief** body straight
   from `<TASK>` — no code reading, no grounding.
2. `gh issue create --repo "$FLEET_REPO" --title "<title>" --body "<brief>"`;
   capture `<N>` from the URL.
3. `bash ~/.claude/fleet/bin/dash-issue-session.sh <N>` — same cap enforcement
   as above; relay a refusal, don't retry.

Then report per step 4. The spawned worker grounds the thin issue itself.

## 4. Report (one line)

Relay the sub-agent's (or inline path's) single line: `#<N> <title> — worker
spawned` (or `— reused, worker spawned`, or the cap refusal). Then stop: the new
window owns the issue; you are the steward, not the worker.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. The base checkout is read-only (hook-enforced): the worker
edits inside its own `issue-<N>` worktree and lands via PR. One issue per task;
reuse before you create. The delegated sub-agent is the steward's proxy for
*filing* — it dedups, grounds, files, and spawns, but never implements.
