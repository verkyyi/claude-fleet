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
| `/fleet-cleanup <n>` | The manual escape hatch: clean up one merged/closed PR *now* instead of waiting a daemon tick. Same mechanical core. |
| dash `⌃l` (`bin/dash-arm-merge.sh`) | **Arm auto-merge now** on the highlighted row's open PR — for a PR shipped before arming existed, or whose auto-merge got disarmed. It arms; it never merges. |
| `bin/fleet-land-lease.sh` | Kept for the per-repo **base fast-forward** serialization (renamed conceptually to a base lease). `fleet-cleanup.sh` takes it only for the quick base pull — no hold-through-green. |

## Config

| Key | Default | Meaning |
|---|---|---|
| `FLEET_CLEANUP` | `1` (on) | Set `0` to opt a fleet out of the cleanup daemon (the worktree-autoclean janitor still backstops merged worktrees). |
| `FLEET_CLEANUP_MAX_PER_TICK` | `4` | Max PRs reaped per fleet per tick (a stampede guard). |

## What was retired

- **Skills**: `/fleet-land`, `/fleet-land-self`, `/fleet-land-train` — deleted. The
  manual merge escape hatch is now `gh pr merge` by hand (or the dash `⌃l` to arm);
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
