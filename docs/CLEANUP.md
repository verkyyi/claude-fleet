# Cleanup — cleaning up after merges, whoever made them (issues #277, #441)

The organizing principle of the fleet's PR lifecycle:

> **Cleanup is merge-source-agnostic. Whoever merged — the worker itself, a human
> on the web, a collaborator — the janitor reaps what's left and keeps every
> session resumable.**

The cleanup half has never merged anything and still doesn't: its job is to reap
the leftover worktree/window/branch and record a resume ledger once the PR is
final. What changed in **#441** is who does the merge. Issue #277 retired the
land / self-land / auto-land *machinery*; #441 gave the decision back to the
worker as plain judgment: a worker reads the gate
(`bin/fleet-pr-verdict.sh` → `READY`) and squash-merges its own PR. Branch
protection is still the hard gate — a `BLOCKED` verdict is not something a worker
may force.

## The lifecycle

```
worker: /fleet-claim → implement → ship + land (same skill)
                       ├─ verify + push + open PR (Closes #N)
                       ├─ fleet-pr-verdict.sh <PR>            ← READ the gate
                       └─ READY ⇒ gh pr merge --<FLEET_MERGE_METHOD> --delete-branch
cleanup: com.claude-fleet.cleanup (~60s) sees the MERGED PR still has a worktree
         → bin/fleet-cleanup.sh <PR>
              ├─ record the resume ledger (fleet-history.sh) BEFORE teardown
              ├─ git -C $FLEET_MAIN pull --ff-only   (under the shared land lease)
              └─ teardown: kill window → DROP worktree → delete branch
                           (drop = mv into .fleet-trash/ + prune; the bytes go to
                            the tick-end budgeted sweep — issue #586)
resume:  /fleet-history (or the dash ⌃t landed view) → claude --resume <session>
```

The merge source does not matter: the worker's own `gh pr merge`, a human clicking
**Merge** on the web, or a collaborator — all leave a MERGED PR with a stale
worktree, and the cleanup daemon reaps them all identically (**this closes #260**).
A worker that merges its own PR is reaped by the same path: `fleet-cleanup.sh`
detaches its teardown into the tmux server when the caller stands on the worktree
being removed, and the daemon (which runs outside every window) kills the window
first, then the worktree, then the branch.

## The pieces

| Piece | What |
|---|---|
| `/fleet-claim` ship + land step | After opening the PR, the worker polls `bin/fleet-pr-verdict.sh <PR>` and, on `READY`, runs `gh pr merge <PR> --<FLEET_MERGE_METHOD> --delete-branch` (default `squash`) then re-reads the verdict to confirm `MERGED` (issue #441). `FAILING`/`CONFLICT`/`BEHIND` are the worker's to fix; `BLOCKED` (branch protection) is a real gate it must not force — it says so on the issue and stops. (Issue #283 folded the retired `/fleet-ship` into `/fleet-claim`'s standing contract.) |
| `bin/fleet-pr-verdict.sh <PR>` | The **merge gate**, read-only: ONE `gh` call folded through `land_classify`/`land_verdict` (bin/fleet-land-lease.sh) into one token — `READY` · `PENDING` · `BEHIND` · `FAILING` · `CONFLICT` · `BLOCKED` · `DRAFT` · `MERGED` · `CLOSED`. Exit 0 only for `READY`, 1 for any other verdict, 2 on error. Stricter than the dash's glance on purpose: a red or still-running check outranks a `CLEAN` mergeStateStatus, because `CLEAN` only means nothing *required* blocks the merge. |
| `bin/fleet-cleanup.sh <PR>` | The mechanical, no-LLM, **no-merge** janitor. `bin/fleet-land.sh` MINUS the merge: for a MERGED (or CLOSED-unmerged) PR it records the ledger first, fast-forwards the base under the shared land lease, and tears down window → worktree → branch (the worktree is **dropped**, not deleted — see below). Idempotent; an already-reaped PR is a no-op. Result tokens: `cleaned:<sha>` · `cleaned:closed` · `skip:not-final` · `skip:nothing` · `error:<reason>`. |
| `com.claude-fleet.cleanup` (`bin/fleet-cleanup-daemon.sh`, ~60s) | Scans the `prmap` cache pr-refresh already writes (`--state all`, so MERGED/CLOSED rows are present — ZERO extra `gh`) for final PRs whose `issue-<N>` still has a live worktree or window, and drives `fleet-cleanup.sh` for each, **each under a wall-clock budget** (`FLEET_CLEANUP_CANDIDATE_TIMEOUT`, 120s). Single-writer per repo + disk-gated. **ON by default** (opt out per fleet with `FLEET_CLEANUP=0`) — it merges nothing and relaxes no gate. |
| *reap now* from the hub | The manual escape hatch: clean up one merged/closed PR *now* instead of waiting a daemon tick, by running `FLEET_SESSION=$S bash bin/fleet-cleanup.sh <PR>` from the hub pane. Same mechanical core. |
| `gh pr merge <PR>` from the hub | **Land by hand** — for a PR whose worker is gone (window closed, context exhausted, blocked) or one the operator simply wants in now. `--auto` still works if you'd rather let GitHub merge it when green; the old dash `⌃l` arming affordance (`dash-arm-merge.sh`) was pruned in #289. Either way the cleanup daemon reaps afterwards. |
| `bin/fleet-land-lease.sh` | Kept for the per-repo **base fast-forward** serialization (renamed conceptually to a base lease). `fleet-cleanup.sh` takes it only for the quick base pull — no hold-through-green. |
| `com.claude-fleet.base-sync` (`bin/fleet-base-sync.sh`, ~60s; issue #327) | The **merge-independent base fast-forward** — see below. |

## Base-sync — keep the base current between merges (issue #327)

The cleanup base pull above only fires when a **merged PR still has a local
worktree to reap**. So a merge with **no local reap** never advances the base:

- a PR **merged on the web** (or by a collaborator) for an issue with no live
  worktree here,
- the default branch advanced by **another machine / contributor / a direct
  push**.

→ no cleanup tick → no base pull → the local base **silently lags** the remote
until the next merge that *does* have a worktree, and fresh worktrees + `cw`
branch off a **stale** base.

`com.claude-fleet.base-sync` (`bin/fleet-base-sync.sh`, ~60s) closes that gap
with a dedicated ff-only ticker. Each tick, one base-mover **per repo** (deduped
on the resolved base path — two fleets sharing one base checkout move it once)
takes the **shared land lease** (`land-<slug>.lock`, the SAME lock
`fleet-cleanup.sh` holds — so there is **no new race**; the lease already
serializes base movers) **non-blocking** — if a cleaner or another base-syncer
holds it, the base is already being advanced, so it skips — and runs the exact
same `git fetch` + `git pull --ff-only` on `$FLEET_MAIN` the cleaner does.

`--ff-only` is the whole safety story: a diverged base (a stray local commit —
which the read-only hook already forbids, but defense-in-depth) makes the pull
**refuse**, surfaced once (*"base checkout would not fast-forward — resolve by
hand"*) and non-fatal; never merged, rebased, or forced. It is **base only** —
never a worktree/window/branch/issue/PR, no `gh`, no LLM, no tmux (just `git` +
the lease). An already-current base is a cheap no-op, so a quiet repo costs one
`fetch`/tick. Single-writer per repo + disk-gated. **ON by default** (opt out
with `FLEET_BASE_SYNC=0`); `--dry-run` prints `would ff $MAIN <old>..<new>`
without moving.

The cleaner keeps doing its own post-reap pull (so a reap stays atomic with its
base advance); base-sync only adds the **merge-independent** trigger for the
same ff-only pull.

## Close the window + reap on manual exit — the SessionEnd hook (issue #403)

The daemons above are POLLERS: `com.claude-fleet.cleanup` reaps a merged PR's
worktree within ~60s, and `com.claude-fleet.ledger-watch` records a hand-closed
worker within ~60s of noticing its window vanished. When an operator **manually
exits** a worker (Ctrl-D / `/exit`, or logout), `bin/session-end-hook.sh` — wired
to the Claude Code **`SessionEnd`** hook — closes that ~60s gap by reacting **at
exit**:

1. **Close the tmux window** — no leftover shell to exit by hand.
2. **Apply the shared reap gate** (`fleet_reap_ok`) and act on the worktree by
   verdict (committed ≠ merged):

   | verdict | action |
   |---|---|
   | `merged-pr` (clean, a merged PR exists) | reap worktree + branch, **close the issue**, record a `landed` row |
   | `ancestor` (clean, tip is an ancestor of base) | reap worktree + branch, record a `closed-unlanded` row — the **issue is kept open** (no merged work) |
   | `unmerged` (clean, committed but not merged) | **KEEP** the worktree + issue, record a `closed-unlanded` row (resumable) |
   | `dirty` (uncommitted/untracked) | **KEEP** the worktree (plain `git worktree remove` refuses it), record a `closed-unlanded` row |

3. **Record the `/fleet-history` row now** (via the shared `fleet_reap_record`), so
   the session is indexed + resumable the instant it ends — not ~60s later.

It is the **event-driven twin of ledger-watch**, reusing the *same* shared reap
primitives (`fleet_reap_ok` / `fleet_reap_record` / `fleet_reap_worktree_procs`) so
it never diverges from the other reapers. SessionEnd runs **inside the dying pane**,
so the gate + reap + close run in a **detached `tmux run-shell -b` job** (server-side)
that survives the pane vanishing and can remove the cwd it stood in — mirroring
`dash-reap.sh`'s `--exec` pattern. A `/clear` or a `/fleet-handoff` cycle
(`reason=clear`/`resume`) is a **no-op** — the same window continues — so it never
fires on a handoff; only a genuine `prompt_input_exit`/`logout` acts. Scoped to
issue-bound workers (a raw `@raw` scratch → **window-close only**); panels
(dash/plan/backlog) and the hub pane are never touched. It **reacts, never
blocks** (SessionEnd can't veto an exit). Idempotent (`fleet_reap_record` +
`gh issue close` dedup), so racing the cleanup daemon / ledger-watch still yields one
row and one close. **ON by default, globally** — set `FLEET_CLOSE_ON_EXIT=0` in the
**global** `~/.claude/fleet/fleet.conf` to disable it machine-wide. The value is
**global-authoritative** (snapshotted before the per-fleet overlay), so a stray
per-fleet `FLEET_CLOSE_ON_EXIT` is ignored — the switch is global-only, not per-fleet.
It is equivalent to auto-firing the dash `⌃x` one-key reap on exit.

## A wedged candidate can't stall the pipeline

The daemon is a **single process** on `StartInterval=60`: launchd starts no new
tick while the previous one is still alive. So a `fleet-cleanup.sh` call that
never returns does not merely slow *its* fleet down — it stops the cleanup of
**every** fleet on the machine behind it. On 2026-09-13 one tick sat **67 minutes**
inside a single candidate and froze all three fleets' pipelines (issue #587).

`fleet-cleanup.sh` has several calls that can block indefinitely — `gh pr view`,
`git pull --ff-only`, the land-lease queue — and hardening them one at a time
never covers the next one. So the budget sits in the daemon, around the **whole**
call: every candidate runs under `fleet_timebox` (`bin/fleet-lib.sh`; pure bash,
because macOS ships neither `timeout(1)` nor `gtimeout`).

On expiry the whole process **tree** is TERMed and then KILLed a second later —
tree, because a script blocked in a child only reaches its own `TERM` trap once
that child dies, and for `fleet-cleanup.sh` that trap is what releases the shared
land lease. The daemon logs

```
… fleet-cleanup: <sess>: PR #123 (#45) — timeout after 120s (FLEET_CLEANUP_CANDIDATE_TIMEOUT) — killed, next candidate  [slot 1/4]
```

and moves on to the next candidate. The killed one keeps its debris and is simply
re-tried next tick. A timeout **spends a per-tick slot**, so a tick is bounded by
`FLEET_CLEANUP_MAX_PER_TICK × FLEET_CLEANUP_CANDIDATE_TIMEOUT` (default 8 minutes,
worst case) however many sick candidates the `prmap` holds — the point being that
the *next* tick starts on time. Set `FLEET_CLEANUP_CANDIDATE_TIMEOUT=0` to run
unbudgeted (the pre-#587 behaviour); a non-numeric value is treated as a typo and
falls back to 120.

The budget is the **backstop**, not the cure for that particular 67 minutes: the
teardown that caused it no longer deletes a worktree inline at all (next section).
The two are complementary — one removes the known wedge, the other bounds the next
unknown one.

## Dropping a worktree — why teardown never deletes (issue #586)

`git worktree remove` deletes the tree **synchronously, one unlink at a time**. In
a monorepo worktree that is 2.8 GB / **308k files** of `node_modules`, and it
measured **~0.4 files/s** on a live machine: one teardown held the cleanup daemon
for **67 minutes** on 54 seconds of CPU. The daemon is a single-process loop on
`StartInterval=60`, so launchd starts no new tick while the old one lives — and the
reaping of **three fleets** stopped dead behind it. Merged workers stayed on the
dash holding their slots, and the base fast-forward (same script) stalled with
`master` four commits behind, so new workers branched off a stale base. The second
occurrence the same night was worse: the tick outlived its 300 s lease TTL, the next
tick stole the lease and SIGTERMed it mid-unlink, leaving a half-deleted 359 MB
orphan directory.

So **no unattended teardown deletes a tree inline.** It **drops** it:

```
fleet_worktree_drop <main> <worktree> [--force]      (bin/fleet-lib.sh)
  1. mv <worktree> → <sibling>/.fleet-trash/<name>.<epoch>.<pid>   O(1), milliseconds
  2. git -C <main> worktree prune                                  registry clean at once
  3. the bytes wait for fleet_trash_sweep                           budgeted, interruptible
```

The trash is a **sibling** of the worktree, never a fixed path, because a rename is
only O(1) (and only atomic) within one filesystem and a sibling shares one by
construction. Fleet worktrees are siblings of `$FLEET_MAIN`, so the same directory
is reachable from either. It carries a `.gitignore` of `*`, so a layout that parks
worktrees inside a checkout can't make every later `git status` dirty.

Without `--force` a worktree holding uncommitted or untracked work is **refused**
(`dirty`, rc 1) — the same gate plain `git worktree remove` (no `-f`) enforces.
Nothing here is destructive on its own: the bytes survive in the trash until a sweep
reaches them.

`fleet_trash_sweep <main> [budget]` is the only place the fleet pays for those
bytes, and it pays in bounded instalments — `FLEET_TRASH_SWEEP_BUDGET` seconds
(default 20) per cleanup-daemon tick, shared across every fleet's distinct base
checkout. An entry the budget cuts short stays half-deleted and the next sweep
continues it, which is harmless precisely because it is already out of
`git worktree list` and nothing waits on it. The sweep runs **before** the diskguard
gate: a closed gate means the volume is full, and emptying the trash is exactly what
unsticks it — gating the sweep on free disk is the one ordering that can deadlock.

| Caller | Uses |
|---|---|
| `bin/fleet-cleanup.sh` `teardown()` | `fleet_worktree_drop … --force` (the window is already killed, the PR is final) — and `bin/fleet-worktree-drop.sh`, the CLI shim, on the detached arm, because `tmux run-shell` runs its command string under `/bin/sh` where the bash library can't be sourced |
| `bin/worktree-autoclean.sh` | `fleet_worktree_drop` with **no** `--force` — its liveness/merged gates already proved the worktree clean, and the drop's own dirty gate is the last check |
| `bin/fleet-cleanup-daemon.sh` | `fleet_trash_sweep`, once per tick, before the disk gate |

Interactive teardowns (`dash-reap.sh` ⌃x, `bin/session-end-hook.sh`) still call
`git worktree remove` directly — a human is watching there, and a follow-up issue
tracks moving them over.

`dash-reap.sh` is also a **script** interface (it accepts any window handle), and
a script has no human to answer a confirm popup. Issue #596 gave it a
non-interactive entry: `--yes` (alias `--force`) takes the branch the confirm
would have taken — `dirty` → KEEP the worktree, close window + issue; anything
else → full reap — synchronously, and with **no** attached client it refuses to
draw a popup at all rather than blocking on a keypress nobody can make. Every
script-facing exit prints one token on stdout with its own status:
`reaped:full` / `reaped:keep` (0), `skip:needs-confirm` (3),
`refused:<slug>` (4). `--yes` removes no dirty worktree, so it adds no data-loss
path — it only skips the question.

## Config

| Key | Default | Meaning |
|---|---|---|
| `FLEET_CLEANUP` | `1` (on) | Set `0` to opt a fleet out of the cleanup daemon (the worktree-autoclean janitor still backstops merged worktrees). |
| `FLEET_CLEANUP_MAX_PER_TICK` | `4` | Max PRs reaped per fleet per tick (a stampede guard). |
| `FLEET_CLEANUP_CANDIDATE_TIMEOUT` | `120` | Wall-clock budget (seconds) for ONE candidate's `fleet-cleanup.sh` call — see [A wedged candidate can't stall the pipeline](#a-wedged-candidate-cant-stall-the-pipeline). `0` disables the budget. |
| `FLEET_CLEANUP_SCRATCH_HEADS` | `0` (off) | Set `1` to also reap a **MERGED** PR whose head branch is not `issue-<N>` — a scratch that grew into a PR (issue #589). Behind the strict gate below; `CLOSED`-unmerged non-issue heads are never included. |
| `FLEET_BASE_SYNC` | `1` (on) | Set `0` to opt a fleet out of the base-sync daemon (the local base then only advances when the cleanup daemon reaps a merged PR). |
| `FLEET_BASE_SYNC_LEASE_TTL` | `120` | Lifetime (seconds) of the shared land lease while base-sync holds it for its quick fetch + ff pull. |
| `FLEET_CLOSE_ON_EXIT` | `1` (on) | **Global only** (`~/.claude/fleet/fleet.conf`). The `SessionEnd` hook: on a manual worker exit, close the window + gate-reap the worktree + record the `/fleet-history` row at once (the event-driven twin of `FLEET_LEDGER_WATCH`). Set `0` to disable machine-wide; global-authoritative, so a per-fleet value is ignored. |
| `FLEET_TRASH_SWEEP_BUDGET` | `20` | **Global only** (read once per tick, before any per-fleet conf). Seconds a cleanup-daemon tick may spend deleting the worktrees teardown renamed into `.fleet-trash/` (issue #586). `0` disables the sweep — the trash then only drains on `worktree-autoclean`'s hourly run. |
| `FLEET_MERGE_METHOD` | `squash` | `squash` · `merge` · `rebase` — the strategy a worker lands its own PR with (`bin/fleet-lib.sh` `fleet_merge_method`; an unset/typo'd value falls back to `squash`). |

## Non-`issue-<N>` heads — the opt-in scratch reap (issue #589)

Everything above is addressed by `issue-<N>`: the daemon's candidate filter, the
"live worktree/window" set, and `fleet-cleanup.sh`'s teardown. So a session that
started as a **scratch** (dash `⌃s` → a `scratch-<N>` worktree and branch), talked
its way into real work, and shipped a PR is **never reaped** — not because the
pipeline is stuck, but because it was never addressable. `worktree-autoclean.sh`
is no backstop here: it only reaps a worktree whose *window is already gone*, and
the window is exactly what never closes. Two such windows were found on one dash
long after their PRs merged, holding 1.2 GB and 5.4 GB of worktree.

Relaxing this unconditionally is not an option. **#543/#544 protects a non-issue
head on purpose**: a `scratch-<N>` window is routinely the operator's own
workbench, and it is normal for one to hold a merged PR *and* still be in use.
Reaping on head branch alone kills live work.

So the relaxation is opt-in and narrow. With `FLEET_CLEANUP_SCRATCH_HEADS=1`:

- the daemon adds **MERGED** non-`issue-<N>` heads to its candidate set (`CLOSED`
  stays issue-only — a closed-unmerged PR's work is still in its worktree), and
  pre-screens each locally, spending no `gh` on a window that isn't `done`;
- `bin/fleet-cleanup.sh` then applies the authoritative gate — so the manual
  *reap now* path (`bash bin/fleet-cleanup.sh <PR>` from the hub) is gated
  identically. **Every** condition must hold:

| Gate | Refusal token |
|---|---|
| a worktree is checked out on the PR's head branch | `skip:nothing` |
| it is not the base checkout, and the branch is not `FLEET_PROTECTED_RE` | `skip:protected` |
| the local branch tip is **exactly** the commit GitHub merged | `skip:unmerged` |
| the worktree is clean — untracked counts as dirty | `skip:dirty` |
| a live window's pane cwd **is** inside the worktree (fails closed) | `skip:nothing` |
| that window reports `@claude_state=done` — not `working`, `needs`, or unset | `skip:busy` |

Three details are load-bearing.

The window is addressed by **pane cwd**, not by `@issue` — a scratch window has no
such binding, so cwd is the only link back (`fleet_wt_window`, exact-or-subdir, the
same rule the janitor uses).

That lookup therefore **fails closed**: a worktree with *no* window found is
refused, not reaped. Any reason the path comparison comes up empty — a symlinked
checkout, a pane whose cwd hasn't settled — would otherwise read as "nobody home"
and kill a live session. Requiring the window costs nothing: a clean, merged
worktree with no live pane is already `worktree-autoclean.sh`'s case, and that is
the reaper that handles it.

And the "nothing unmerged" check compares against the PR's **`headRefOid`**, not
`merge-base --is-ancestor`: a squash merge (the fleet default) leaves the head tip
off the base's history entirely, so an ancestor test would read *every*
squash-merged branch as unmerged and the feature would never fire.

The reaped session still lands in `/fleet-history`: with no issue number,
`fleet_reap_record` keys the row by the branch's `scratch-<N>` slug (issue #466).

## What was retired

- **Skills**: `/fleet-land`, `/fleet-land-self`, `/fleet-land-train` — deleted. A
  worker now lands its own PR from `/fleet-claim` (#441) with a plain `gh pr merge`
  behind `bin/fleet-pr-verdict.sh`; no lease-hold-through-green, no land train. The
  hub's escape hatch is the same `gh pr merge` by hand (`--auto` to let GitHub do it);
  the cleanup daemon handles the rest.
- **Config**: `FLEET_AUTOLAND` (+ `FLEET_AUTOLAND_MAX_PER_TICK` / `FLEET_AUTOLAND_LABEL`)
  and `FLEET_SELF_LAND` — removed. A migration that applies this change should flip
  both off / remove them from every fleet conf.
- **Scripts**: `bin/fleet-land.sh` (shrank into `bin/fleet-cleanup.sh`),
  `bin/fleet-land-self.sh`, `bin/fleet-autoland.sh`, `bin/land-train.sh`,
  `bin/dash-land.sh` — deleted. `bin/fleet-land-lease.sh` is kept.
- **Daemon**: `com.claude-fleet.land` → `com.claude-fleet.cleanup`.
- **Docs**: `docs/AUTOLAND.md` + `docs/SELF-LAND.md` → this file.

## Resume

The resume path is unchanged and now complete for **every** merge: `fleet-cleanup.sh`
records the history ledger before teardown, so `/fleet-history` and the dash's
live⇄landed **⌃t** view can resume any landed session with `claude --resume`. See
`bin/fleet-history.sh`.

**Closed-but-unlanded sessions** (issue #320): a worker window closed by hand /
crashed / abandoned never reaches this land path, so it used to leave its
transcript unindexed. The **ledger-watch daemon** (`com.claude-fleet.ledger-watch`,
`bin/fleet-ledger-watch.sh`, ~60s) closes that gap — it snapshot-diffs the live
session windows and appends a `closed-unlanded` ledger row (via
`fleet-history.sh record-closed`, idempotent) when one vanishes without landing,
so it too is browsable + resumable via `/fleet-history`. Such a worktree is
unmerged, so worktree-autoclean keeps it → resume just reuses the on-disk worktree.
It **records only** — never a reaper.

**The dash ⌃x reaper** (issue #471): ⌃x is the one disposal path no other writer
covers in time — the SessionEnd hook does not fire (a `kill-window` is not a
walk-away exit) and ledger-watch only notices ~60s later, by which point the
worktree is gone and the row it writes has no sha to rebuild from. So ⌃x records
the row itself, before it removes anything: a merged-PR reap writes a `landed`
row (PR resolved from the branch), and ancestor / force-reaped-unmerged / dirty
write `closed-unlanded`. The gate verdict is computed on the interactive pass and
**threaded into** the backgrounded reap rather than re-derived there — a second
`fleet_reap_ok` could disagree with what the operator just confirmed. Caveat: on a
force-reaped *unmerged* row the recorded sha is unreachable once the branch is
deleted, so the rebuild works only until `git gc` prunes it (~2 weeks).

**Scratch sessions** (issue #466): an `@raw` scratch has no issue, so nothing keyed
by an issue number could index it — its transcript used to be dropped on the floor
the moment its window closed (and its clean worktree pruned silently). It is now
recorded like any worker, keyed by its `scratch-<N>` slug (the name of both its
branch and its worktree) in the same ledger column, and shows in `/fleet-history` +
the dash ⌃t view as `~<N>`. Every reaper records it before disposing of anything:
the ledger-watch daemon, the SessionEnd hook, the dash **⌃x** reaper and the
worktree janitor all go through `fleet_reap_record`. Because a scratch's worktree is
usually the thing that gets removed (a clean scratch is pruned silently by #290's
rules), the closed row also stores the worktree's **HEAD sha** — captured while it
still stands — so `resume` can rebuild the worktree at its original path and
`claude --resume` still finds the transcript. That sha applies to worker
closed-unlanded rows too: a reaped-clean session no longer degrades to REVIEW-ONLY.

A scratch **bound in place** (`fleet-bind.sh`, issue #520) leaves this path
entirely: from the bind onward its branch is `issue-<N>`, so every reaper takes
the ordinary worker route — the merged-PR gate, the `issue-<N>` ledger key, the
issue close — even though its directory is still named `<repo>-scratch-<K>`.
Branch, not directory, is what the reapers read.
