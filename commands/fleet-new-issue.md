# /fleet-new-issue — file a new issue and spin up a worker session for it

<!-- fleet skill · owner: steward -->

Turn a task into tracked, in-progress work in ONE step: create a new GitHub
issue in **this fleet's** `$FLEET_REPO`, then spawn a fresh Claude worker window
(git worktree + `claude`, bound to the issue) to implement it. It **mutates**
the fleet's repo (files an issue) and spawns a session — so it's the
**steward's** job: you file the work and hand it to a worker; you do NOT
implement it yourself.

**Argument** (`$ARGUMENTS`): the task description — a sentence or a short brief.
If empty, ask the user what the task is and stop.

## 0. Resolve fleet + guard seat (run FIRST, every time)

Env vars do NOT persist across separate Bash tool calls — run this once, then
reuse the literal values it prints:

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

Everything below operates on the resolved `$FLEET_REPO` / `$FLEET_MAIN` /
`$FLEET_BASE_BRANCH` — this fleet only.

## 1. Don't duplicate

Skim the fleet's open issues for the same task before filing:

```sh
gh issue list --repo "$FLEET_REPO" --state open --limit 60 --search "<keywords>"
```

If one already covers it, spawn on THAT (skip to step 3 with its number) instead
of creating a duplicate.

## 2. Create the issue

From `$ARGUMENTS`, write a concise **title** (imperative, ≤ ~70 chars) and a
**body** with the goal, a short definition-of-done / acceptance criteria, and any
concrete pointers you already know (files, endpoints, related issues). Stay
evidence-based — don't invent scope; a one-liner task gets a short body.

```sh
gh issue create --repo "$FLEET_REPO" --title "<title>" --body "<body>"
```

Capture the new issue **number** from the returned URL. Add `--label` /
`--milestone` ONLY if you know they already exist (a bad value fails the call).

## 3. Spawn the worker window

```sh
bash ~/.claude/fleet/bin/dash-issue-session.sh <number>
```

This creates the `issue-<N>` worktree off the base branch and a tmux window
running `claude`, seeded to read → claim → implement the issue, bound via
`@issue` and named after the title. It enforces the global session cap
(`FLEET_GLOBAL_MAX_SESSIONS`): if the cap is hit it refuses and prints why —
relay that and do NOT retry or force it.

## 4. Report (one line)

`#<N> <title> — worker spawned` (or the cap refusal). Then stop: the new window
owns the issue; you are the steward, not the worker.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. The base checkout is read-only (hook-enforced): the worker
edits inside its own `issue-<N>` worktree and lands via PR. One issue per task;
reuse before you create.
