# /fleet-epic-run — drive a confirmed EPIC to done, unattended

<!-- fleet skill · owner: hub -->

PHASE 2 of the EPIC trio. Takes an EPIC filed by `/fleet-epic-plan` and pushes it
to completion across many hours and many workers: keeps 4–6 workers busy, answers
what it is allowed to answer, lands green PRs, reclaims finished slots, rides out
quota ceilings, and stops when the core layer is empty. It mutates this fleet's
`$FLEET_REPO` (issues, PRs, merges) and this fleet's tmux session (windows).

**Argument** (`$ARGUMENTS`): the EPIC issue number. Optional — with none, resolve
the newest OPEN issue labelled `epic` in this fleet; if there is more than one,
list them and ask rather than guessing which batch the operator meant.

## 0. Resolve fleet + guard seat (run FIRST, every time)

```sh
source ~/.claude/fleet/bin/fleet-lib.sh
S=$(fleet_current_session); fleet_load_conf "$S"   # → FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH
SEAT=$(fleet_seat)
echo "repo=${FLEET_REPO:-} main=${FLEET_MAIN:-} base=${FLEET_BASE_BRANCH:-master} seat=${SEAT:-unknown}"
```

- **No fleet** → **ABORT**: *"not inside a fleet — run this from a fleet session."*
- **Wrong seat** — `owner: hub`: refuse when `$SEAT` is `worker`. A worker driving
  a batch would be spawning its own siblings.

## 1. The stateless rule — read this before anything else

**Every fact this loop needs lives on GitHub, never in the context window.**

A 12-hour loop outlives any context window, so a loop that remembers is a loop
that dies at the boundary. Therefore:

- **Each tick begins by re-reading the EPIC** — the parent body (the charter), the
  sub-issue list and their states, and the repo's open PRs. Never carry a plan
  from the previous tick.
- **Each tick ends by writing what it did** as one marked comment on the parent:

  ```
  <!-- fleet:epic-tick -->
  tick <n> · <UTC>
  quota: <acct> 5h=<x>% wk=<y>% · <acct> …
  slots: <k>/<cap> · spawned: #… · landed: #… · reaped: #…
  blocked: #… (<why>)
  待决: <question that no charter answer covers>
  ```

- **Context full ⇒ `/fleet-handoff`, not a summary.** The handoff doc need only
  say *"driving EPIC #N, re-read it"*; everything else is on the issue. The
  cycle's clear-and-resume is safe here: the stuck-working backstop is pinned to
  fire inside the handoff's idle window by `bin/fleet-handoff-invariant.sh`
  (issue #677), so a fable-capped turn that never fires its Stop hook still gets
  demoted in time to change blood.

If you ever find yourself reasoning from something you remember rather than
something you just read, that is the bug.

## 2. The tick — five things, in this order

### a. Land what is green

Workers land their own PRs once `bin/fleet-pr-verdict.sh` reads `READY`
(issue #441), so this is a **backstop**, not the main path — it catches the worker
that finished and went idle without merging.

For each EPIC member with an open PR:

```sh
bash ~/.claude/fleet/bin/fleet-pr-verdict.sh <PR> -q
```

- `READY` → merge it, **one command, never chained**:
  `gh pr merge <PR> --squash --delete-branch`. A chained `push --delete` once
  closed the wrong issue and got the worker reaped.
- `BEHIND` → `gh pr update-branch <PR>`.
- `PENDING` → nothing; next tick.
- `FAILING` / `CONFLICT` → step 2d (it is a failure, not a merge decision).
- `BLOCKED` → branch protection said no. Not yours to force: note it on the
  parent's 待决 and leave it.

A merged PR is not yet *done* if this fleet has a deploy signal: with
`FLEET_DEPLOY_REF` or `FLEET_DEPLOY_CHECK` set (issue #541), a member counts as
complete only when its deploy state goes green. With neither set, merged ≡ done.
Do **not** run `/fleet-sync-install` mid-batch — the loop runs on the live install,
and swapping the floor under running workers is how one bad merge takes the batch
with it. Sync once, at the end.

### b. Reclaim finished slots

A finished worker holds a slot until something reaps it. Don't wait to be told:
for each member whose PR is MERGED (and deploy-green, if applicable) while its
window still exists, reap it —
`bash ~/.claude/fleet/bin/dash-reap.sh <window-target>` — which records a
`/fleet-history` row before disposing of anything.

### c. Refill to 4–6

Count live EPIC worker windows. While under target and the core layer has an
unstarted member, spawn the next one, highest-priority first:

```sh
bash ~/.claude/fleet/bin/dash-issue-session.sh <N> --title "<the issue's own title>"
```

Always the **live install** path (`~/.claude/fleet/bin/…`), never the base
checkout — the checkout's copy defaults the global cap to 8 and refuses in
silence. Pass `--title` so the window says what the work is.

Then verify the spawn actually happened: a refusal reaches the caller as a bare
exit code and a tmux popup nobody is watching (issue #683). A tick that "spawned"
three workers and shows three fewer windows than it thinks has hit exactly that.
Re-count windows after spawning; on a mismatch, say so on the parent and stop
refilling rather than looping on a silent refusal.

Core empty and quota remaining? Promote from the charter's reserve list. Reserve
items never started are **not** unfinished work.

### d. Handle red lights

`bin/tmux-dash-collect.sh` classifies a stuck window into `?` (a question) and
`⊘` (a permission), issue #640/#645. They get different treatment:

- **`⊘` permission** → approve it. `bash ~/.claude/fleet/bin/fleet-answer.sh …`
- **`?` question** → answer it **only if the charter already covers it.** The
  charter is the operator's stated intent; answering inside it is relaying, and
  answering outside it is making a product decision they never made. Not covered?
  Append the question to the parent's 待决 section, leave the worker parked, and
  refill its slot with the next member. One batch of 待决 answered at breakfast
  beats a decision made at 03:00 by a loop.

- **A failed worker** (PR red, conflicted, or the window died) → **retry once**,
  seeding the new worker with what went wrong. Second failure: label the member
  `blocked`, write the reason on the parent, free the slot.

One caution on red: a red check is not always the code's fault. This suite carries
real-time budgets that only hold on an idle box (`CLAUDE.md`, issue #691/#693), so
a red that names a timing assertion on a loaded machine may be the gate, not the
change. Before spending the retry, re-read the failing check: if it is unrelated
to the member's diff, say so on the parent and re-run the check rather than
burning the one retry on a flake.

### e. Quota

```sh
bash ~/.claude/fleet/bin/fleet-account.sh quota    # label · 5h% · week% · …
```

Quota is a **rate limiter here, not a target.** The goal is the EPIC finishing;
there is no percentage to hit and no reason to spend quota faster than the work
needs. So:

- An account near its ceiling → `fleet-account.sh migrate` moves work off it.
- **Every account at the ceiling → wait, don't stop.** Drop to a low-frequency
  heartbeat (20–30 min) until a 5h window refreshes, then resume. Waiting for a
  window is progress; it is the batch staying alive across a ceiling, which is the
  whole reason a 12-hour run beats three 4-hour ones.
- A quota read that comes back empty is not a quota of zero (issue #684). Treat an
  empty read as unknown, keep the previous decision, and say so on the tick line.

## 3. The loop

Drive this with `/loop` self-paced: each wake-up is one tick of step 2, and the
next delay is chosen from what you are actually waiting for.

| situation | next tick |
|---|---|
| slots free, work queued | as soon as the spawn settles |
| all slots busy, CI running | 10–20 min |
| every account at its ceiling | 20–30 min, until the window refreshes |
| nothing left but a PR's checks | match the check's own runtime |

Do not poll for things the harness reports on its own; a `Monitor` on a PR's
checks is cheaper and more accurate than a tick that wakes to look.

## 4. Stop, and what wakes the operator

**Stop when the core layer is empty** — every core member merged (and
deploy-green where the fleet has a deploy signal), or `blocked` with a reason on
the parent. Then hand off to `/fleet-epic-report <N>`.

Push a notification for exactly two things:

- **Done** — the core is empty and the report is ready.
- **Stalled** — every account is at its ceiling with no window in sight, the
  handoff failed to clear, spawning is refusing, or N consecutive ticks made no
  progress.

Everything else — a single worker's question, one red PR, one reaped window —
goes to the parent's tick log and waits for morning. A batch that wakes its
operator for each worker is a batch that has not been delegated.

## 5. Report (keep it short)

One line per tick in the terminal: tick number, slots, what landed, what blocked.
The durable record is the parent's tick comments — the terminal scrollback is not
where this batch's history lives.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only. This skill merges to the base
branch unattended — that is the operator's standing decision, and CI green is its
only gate; `git revert` is the undo. It does **not** run `/fleet-sync-install`
mid-batch. The base checkout is read-only (hook-enforced): workers edit inside
their own `issue-<N>` worktrees and land via PR.
