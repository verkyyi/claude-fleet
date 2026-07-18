# Cleanup — the fleet never merges; it cleans up after merges (issue #277)

The organizing principle of the fleet's PR lifecycle:

> **The fleet never merges. It arms auto-merge, and it cleans up after merges —
> keeping every session resumable.**

GitHub does the merge (branch protection is the whole gate); the fleet's job is to
(1) arm auto-merge when it opens the PR and (2) reap the leftover worktree/window/
branch and record a resume ledger once the PR is final. This replaces the retired
land / self-land / auto-land machinery — nobody in the fleet self-merges anymore.

## The lifecycle

```
worker: /fleet-claim → implement → ship step (same skill)
                       ├─ verify + push + open PR (Closes #N)
                       └─ gh pr merge --auto --<FLEET_MERGE_METHOD>   ← ARM (not merge)
GitHub:  PR goes green + branch protection satisfied → squash-merge
cleanup: com.claude-fleet.cleanup (~60s) sees the MERGED PR still has a worktree
         → bin/fleet-cleanup.sh <PR>
              ├─ record the resume ledger (fleet-history.sh) BEFORE teardown
              ├─ git -C $FLEET_MAIN pull --ff-only   (under the shared land lease)
              └─ teardown: kill window → remove worktree → delete branch
resume:  /fleet-history (or the dash ⌃t landed view) → claude --resume <session>
```

The merge source does not matter: GitHub auto-merge, a human clicking **Merge** on
the web, or a collaborator — all leave a MERGED PR with a stale worktree, and the
cleanup daemon reaps them all identically (**this closes #260**).

## The pieces

| Piece | What |
|---|---|
| `/fleet-claim` ship step | After opening the PR, runs `gh pr merge --auto --<FLEET_MERGE_METHOD>` (default `squash`). If the repo has auto-merge disabled, it says so instead of failing — the PR stays open and reviewable. It **never** merges. (Issue #283 folded the retired `/fleet-ship` into `/fleet-claim`'s standing contract.) |
| `bin/fleet-cleanup.sh <PR>` | The mechanical, no-LLM, **no-merge** janitor. `bin/fleet-land.sh` MINUS the merge: for a MERGED (or CLOSED-unmerged) PR it records the ledger first, fast-forwards the base under the shared land lease, and tears down window → worktree → branch. Idempotent; an already-reaped PR is a no-op. Result tokens: `cleaned:<sha>` · `cleaned:closed` · `skip:not-final` · `skip:nothing` · `error:<reason>`. |
| `com.claude-fleet.cleanup` (`bin/fleet-cleanup-daemon.sh`, ~60s) | Scans the `prmap` cache pr-refresh already writes (`--state all`, so MERGED/CLOSED rows are present — ZERO extra `gh`) for final PRs whose `issue-<N>` still has a live worktree or window, and drives `fleet-cleanup.sh` for each. Single-writer per repo + disk-gated. **ON by default** (opt out per fleet with `FLEET_CLEANUP=0`) — it merges nothing and relaxes no gate. |
| steward *reap now* op | The manual escape hatch, folded into the `/fleet-steward` charter (issue #286; formerly the standalone `/fleet-cleanup`): clean up one merged/closed PR *now* instead of waiting a daemon tick, by running `FLEET_SESSION=$S bash bin/fleet-cleanup.sh <PR>`. Same mechanical core. |
| `gh pr merge --auto --squash <PR>` | **Arm auto-merge by hand** — for a PR shipped before arming existed, or whose auto-merge got disarmed. The worker's `/fleet-claim` ship step already runs this at PR-open; the old dash `⌃l` affordance (`dash-arm-merge.sh`) was pruned in #289. It arms; GitHub merges when green. |
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
(dash/plan/backlog) and the steward hub are never touched. It **reacts, never
blocks** (SessionEnd can't veto an exit). Idempotent (`fleet_reap_record` +
`gh issue close` dedup), so racing the cleanup daemon / ledger-watch still yields one
row and one close. **OFF by default** — opt a fleet in with `FLEET_CLOSE_ON_EXIT=1`.
It is equivalent to auto-firing the dash `⌃x` one-key reap on exit.

## Config

| Key | Default | Meaning |
|---|---|---|
| `FLEET_CLEANUP` | `1` (on) | Set `0` to opt a fleet out of the cleanup daemon (the worktree-autoclean janitor still backstops merged worktrees). |
| `FLEET_CLEANUP_MAX_PER_TICK` | `4` | Max PRs reaped per fleet per tick (a stampede guard). |
| `FLEET_BASE_SYNC` | `1` (on) | Set `0` to opt a fleet out of the base-sync daemon (the local base then only advances when the cleanup daemon reaps a merged PR). |
| `FLEET_BASE_SYNC_LEASE_TTL` | `120` | Lifetime (seconds) of the shared land lease while base-sync holds it for its quick fetch + ff pull. |
| `FLEET_CLOSE_ON_EXIT` | `0` (off) | Set `1` to arm the `SessionEnd` hook: on a manual worker exit, close the window + gate-reap the worktree + record the `/fleet-history` row at once (the event-driven twin of `FLEET_LEDGER_WATCH`). |

## What was retired

- **Skills**: `/fleet-land`, `/fleet-land-self`, `/fleet-land-train` — deleted. The
  manual merge escape hatch is now `gh pr merge` by hand (`--auto --squash` to arm);
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
worker windows and appends a `closed-unlanded` ledger row (via
`fleet-history.sh record-closed`, idempotent) when one vanishes without landing,
so it too is browsable + resumable via `/fleet-history`. Such a worktree is
unmerged, so worktree-autoclean keeps it → resume just reuses the on-disk worktree
(no squash SHA to reconstruct from). It **records only** — never a reaper.
