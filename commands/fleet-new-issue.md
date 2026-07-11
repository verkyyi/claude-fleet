# /fleet-new-issue — file a new issue and spin up a worker session for it

<!-- fleet skill · owner: steward -->

Turn a task into tracked, in-progress work: create a new GitHub issue in **this
fleet's** `$FLEET_REPO`, then spawn a fresh Claude worker window (git worktree +
`claude`, bound to the issue) to implement it. It **mutates** the fleet's repo
(files an issue) and spawns a session — so it's the **steward's** job: you file
the work and hand it to a worker; you do NOT implement it yourself.

**Thin by design.** This is a fast inline capture: guard → dedup → milestone →
create → spawn → report, straight from the operator's words. It does **no** code
reading, **no** grounding, and **no** sub-agent — the spawned worker grounds the
issue itself (via `/fleet-claim`) before it implements, and elaboration arrives
as issue comments → bridge relay. Grounding twice (a filing proxy, then the
worker) was wasted work, and a thin inline capture doesn't tie the steward's
thread up long enough to be worth a sub-agent.

**Argument** (`$ARGUMENTS`): the task description — a sentence or a short brief.
A leading `--quick` flag is **retired**: it's now the only behavior, so it's
accepted and silently ignored (strip it off the front of the task text). If the
task text is empty, ask the user what the task is and stop.

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

Everything past this step operates on the resolved `$FLEET_REPO` / `$FLEET_MAIN`
/ `$FLEET_BASE_BRANCH` — this fleet only.

## 1. Dedup first (cheap API call, not grounding)

A duplicate worker is a wasted session, and the worker can't undo that after the
fact — so do one search before you create:

```sh
gh issue list --repo "$FLEET_REPO" --state open --limit 60 --search "<keywords>"
```

If an open issue already covers this task, do **not** create a new one — reuse
that number and skip to step 4 (spawn) with it, then report `— reused, worker
spawned`.

## 2. Pick a milestone (best-fit, live-fetched)

Fetch this repo's OPEN milestones — never hardcode; the user adds/renames/closes
them:

```sh
gh api "repos/$FLEET_REPO/milestones?state=open" --jq '.[].title'
```

They are the fleet's component categories (e.g. *Dashboard & modals*, *Steward &
commands*, *Testing & CI*, *Daemons & automation*). From the task, choose the ONE
title that best fits and pass it as `--milestone "<title>"` in step 3 — but
**only a title that came back from that live list**. If none clearly fits, or the
repo has no open milestones, skip it: file with **no** `--milestone` rather than
forcing a wrong one (a stale/invalid name fails the create). Note the choice
(`<milestone>` or "no milestone matched") for the report.

## 3. Create the issue (thin title + one-line brief)

Straight from the task text — no code reading, no grounding:

1. Write a short imperative **title** (≤ ~70 chars) and a **one-line brief**
   body from the operator's words alone. Carry the standing line in the body so
   the worker knows the issue is thin on purpose:

   > thin by design — ground it yourself before implementing

2. `gh issue create --repo "$FLEET_REPO" --title "<title>" --body "<brief>"`,
   adding `--milestone "<title>"` iff you matched one in step 2. Add a `--label`
   only if you know the value already exists. Capture the new number `<N>` from
   the returned URL. Never force a stale/invalid milestone name — a bad
   `--milestone` fails the create.

## 4. Spawn the worker

Pass the **title you just wrote** as `--title` so the worker's tmux window is
named after the WORK (a short kebab of the title), not the bare `issue-<N>` slug
(issue #216). The brand-new issue isn't in the collector cache yet, and a
post-create `gh issue view` can lag — so `--title` is what makes the window name
reliably explaining/descriptive instead of falling back to `issue-<N>`:

```sh
bash ~/.claude/fleet/bin/dash-issue-session.sh <N> --title "<title>"
```

This creates the `issue-<N>` worktree + a `claude` window (named after `<title>`)
bound to the issue. It
enforces the **global + per-fleet** session caps and its own dedup: if a cap is
hit (or the issue already has a live window) it refuses and prints why — **relay
that refusal verbatim and do NOT retry or force it.** You file and spawn only —
you do NOT implement the task; the spawned worker owns the implementation and
grounds the thin issue itself.

## 5. Report (one line)

One line and nothing else:

- success → `#<N> <title> — worker spawned [milestone: <milestone> | no milestone matched]`
- reused an existing issue → `#<N> <title> — reused, worker spawned`
- cap/dedup refusal → the refusal message from `dash-issue-session.sh`, verbatim

Then stop: the new window owns the issue; you are the steward, not the worker.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. The base checkout is read-only (hook-enforced): the worker
edits inside its own `issue-<N>` worktree and lands via PR. One issue per task;
reuse before you create. You file and spawn — you never implement.
