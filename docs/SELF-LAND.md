# Worker-owned self-land

> **Opt-in.** OFF by default; the steward-lands model (`/fleet-land`) stays the
> default. A fleet enables it with `FLEET_SELF_LAND=1` (steward-triggered) or
> `FLEET_SELF_LAND=auto` (no trigger — issue #270), or a single worker is spawned
> with `dash-issue-session.sh <N> --self-land[=auto]`. Issue #138.

## Two modes: triggered (`=1`) and auto (`=auto`)

Self-land has two gates, chosen by `FLEET_SELF_LAND`:

| | `FLEET_SELF_LAND=1` — **triggered** | `FLEET_SELF_LAND=auto` — **auto** (issue #270) |
|---|---|---|
| after `/fleet-ship` | worker **waits** | worker flows **straight into** `/fleet-land-self` |
| what starts the land | the steward's `/land` comment (relayed by the bridge) | nothing — it's automatic |
| approval gate | the steward's **pre-trigger review** | **CI-green + branch protection** only |
| needs the issue-bridge | **yes** (the trigger channel) | **no** (there is no trigger to relay) |
| relaxation class | "workers never self-merge", re-gated by the trigger | same **and** removes the human approval gate — like `FLEET_AUTOLAND` |

Everything else is identical — both run the exact same `bin/fleet-land-self.sh`
(lease-serialized, hold-through-green, `--match-head-commit`, base fast-forward,
self-destruct). `auto` only drops the trigger wait; it still **waits for CI green**
under the hold-through-green lease, still sanitizes, still ejects to
`/fleet-blocked` rather than force-merging a red or conflicting PR.

Normally a worker `/fleet-ship`s its PR and the **steward** does the land —
verify green, squash-merge, fast-forward the base checkout, clean up the worktree.
Landing N PRs is N multi-step steward turns.

**Self-land** gives a worker ownership of its **entire lifecycle including the
land**, so the steward only *approves* (triggers) instead of *performing* the
merge — "land 6 PRs = 6 multi-step turns" becomes "review 6 PRs, drop 6 `/land`
comments."

| Step | Steward-lands (default) | Self-land |
|---|---|---|
| verify green/mergeable · sanitize · squash-merge · base fast-forward | steward | **worker** (its own PR) |
| worktree + window cleanup | steward | **worker** (self-destruct; autoclean backstop) |
| **decision to land** | steward | **steward — trigger only** |

## The relaxed rail (state it honestly)

Self-land deliberately **relaxes the "workers never self-merge" rail** — the
exact discipline the fleet adopted after a worker once self-merged its own PR. In
`=1` (triggered) mode it is safe because it is **re-gated by the steward's explicit
trigger**; in `=auto` mode the trigger gate is **removed** and CI-green + branch
protection become the only gate (the same relaxation `FLEET_AUTOLAND` makes —
choose `auto` only where that trade is acceptable):

- **In triggered mode, the trigger is the approval gate.** Nothing self-lands
  until the steward comments `/land`; the worker *waits* after `/fleet-ship`.
  Review discipline moves to "eyeball the PR before you trigger." **In auto mode
  there is no trigger** — `/fleet-ship` flows straight into `/fleet-land-self` and
  CI + branch protection are the sole gate.
- **Sanitize still runs** in `/fleet-land-self` (on the worker's own diff), but
  it is a self-check — the steward's pre-trigger review is the real independent
  gate.
- **Live-install sync stays OUT of self-land.** `/fleet-sync-install` mutates the
  shared `~/.claude/fleet`; concurrent workers must not. Self-land is merge +
  base-pull only; the tooling re-apply remains a separate single-writer step
  (steward / daemon).

## Lifecycle

**Triggered (`FLEET_SELF_LAND=1`):**

```
spawn (--self-land)  →  /fleet-claim  →  implement  →  /fleet-ship  →  WAIT
                                                                        │
      steward reviews the PR, comments  /land  on the issue            │
                     │                                                  │
       issue-bridge relays it into the worker as its next turn  ───────┘
                     │
              /fleet-land-self  →  re-verify green · sanitize own diff ·
                                   lease-serialized merge · base fast-forward ·
                                   self-destruct (kill window + remove worktree)
```

**Auto (`FLEET_SELF_LAND=auto`, issue #270)** — no WAIT, no `/land`:

```
spawn (--self-land=auto)  →  /fleet-claim  →  implement  →  /fleet-ship
                                                                │  (PR opened)
                                                                ▼
              /fleet-land-self  →  wait for CI green (hold-through-green lease) ·
                                   re-verify · sanitize · lease-serialized merge ·
                                   base fast-forward · self-destruct
```

The worker is seeded with the appropriate lifecycle at spawn (the
`--self-land[=auto]` seed prompt). Workers spawned without it stay steward-landed
— the switch is **gradual and per-worker**.

## The bridge is the solo channel

All steward↔worker comms for a self-land worker — the `/land` trigger, scope
adds, rebase handbacks — are **issue comments the [#132 issue-bridge](ISSUE-BRIDGE.md)
relays**. `send-keys` is retired as a control channel; the whole lifecycle
(spawn → ship → `/land` → merged) reads back from the issue timeline.

Because the trigger rides the bridge, **`FLEET_SELF_LAND=1` implies
`FLEET_ISSUE_BRIDGE=1`**. With no bridge there is no trigger channel, so a
triggered self-land worker falls back to steward-lands (and `dash-issue-session.sh`
warns at spawn if you asked for `--self-land` on a fleet whose bridge is off).

**`FLEET_SELF_LAND=auto` needs no bridge** — there is no `/land` trigger to relay,
so auto mode lands with the bridge off (the spawn skips that warning for `auto`).
The bridge is still useful in auto mode for *other* steward↔worker comms (scope
adds, a rebase handback), but it is no longer required for the land itself.

### Triggering a land

The steward reviews the PR, then comments on the **issue** (not the PR):

```
/land
```

or the invisible marker form `<!-- fleet:land -->`. The bridge relays any comment
from a trusted `author_association` (the bridge's gate), so a bare `/land` typed
straight into the GitHub issue works — or post it via
`bin/fleet-comment.sh <issue> --to-worker --body '/land'` to be explicit that it
is meant to drive the worker. Fleet-internal record comments (posted with
`--note`) carry `<!-- fleet:no-relay -->` and are never relayed, so they can't
accidentally trigger a land.

> **Security.** A relayed comment is autonomous tool-use in a bypass-permissions
> worker — and here it can *merge*. Treat the trigger as RCE-with-merge: keep the
> bridge's `author_association` floor tight (OWNER/MEMBER/COLLABORATOR) and never
> enable self-land with an un-gated bridge on a **public** repo. See
> [ISSUE-BRIDGE.md](ISSUE-BRIDGE.md).

## Concurrency — one lander per repo, hold-through-green

Self-land is **not** a central conductor. Each worker runs a one-PR merge-train
step gated by a shared **per-repo land lease**
(`~/.claude/leases/land-<repo-slug>.lock`, mkdir-atomic) — the same lock
`/fleet-land-train` takes, so a batch land-train and a self-landing worker
interlock instead of racing. `bin/fleet-land-lease.sh` is the shared helper;
`bin/fleet-land-self.sh` is the driver.

The lease protocol (generalized from `bin/land-train.sh`, issue #62):

- **Acquire the lease → if `BEHIND`, `gh pr update-branch` → wait for green *while
  HOLDING the lease* → merge (`--squash --match-head-commit`) → `git -C $FLEET_MAIN
  pull --ff-only` → release.** Holding through the green-wait means master can't
  advance under you, so **green ⇒ still-up-to-date ⇒ the merge lands first try** —
  no wasted CI, no starvation. (Releasing during the CI wait would re-stale the
  branch under contention — rejected.)
- **Only `update-branch` while holding the lease** (its turn) — never
  speculatively, which keeps the herd O(N), not O(N²).
- **`max-hold` timeout** — the holder bails and releases if its CI overruns the
  cap, so a stuck PR can't pin the queue (→ `/fleet-blocked`).
- **steal-if-stale** — a waiter reclaims a lease whose holder crashed, so a
  killed holder can't deadlock the queue. **Liveness beats the TTL:** a lander
  legitimately *holds through a green-wait that can outlast the TTL* and nothing
  renews the expiry, so a same-host holder is stolen only when its **PID is dead**
  (probed directly), never merely because the TTL elapsed — stealing a live
  holder would race two landers on the base branch. The TTL is the fallback only
  for a holder we cannot probe: a cross-host holder, or a lock whose holder file
  never appeared.
- **re-validate-on-resume** — because a lease *can* be stolen, the holder
  re-checks `land_lease_mine` (still ours?) and `--match-head-commit` (head sha
  unchanged?) right before the merge. This is the correctness partner to
  steal-if-stale.

Correctness is the merge-train's (serial CI-against-tip, single-writer base);
ownership is decentralized (no conductor).

## Self-cleanup (the final act)

A worker can't remove the ground it stands on directly, so `fleet-land-self.sh`
launches a **detached, server-side** teardown that outlives its own window:

```sh
tmux run-shell -b "tmux kill-window -t $SELF_WIN; \
  git -C $FLEET_MAIN worktree remove --force $WT; \
  git -C $FLEET_MAIN branch -D issue-$N"
```

`run-shell -b` runs in the tmux **server**, not the pane. The ordering is
load-bearing: **kill the window first** (the worker process dies, releasing the
worktree cwd), *then* remove the worktree + branch — removing a busy cwd first
would fail. `bin/worktree-autoclean.sh` stays the **backstop** if the
self-destruct ever fails (it prunes merged + clean + idle worktrees on its timer).

## Failure → /fleet-blocked, never force

If the PR can't land cleanly — conflicting, a required check red, blocked by
branch protection, not the worker's own PR, or the hold exceeded `max-hold` —
`fleet-land-self.sh` **ejects** with a reason (`eject:<why>`) and merges nothing.
The skill then runs `/fleet-blocked` with that reason: it posts to the issue and
flips the window red for the steward. Self-land never `--admin`-bypasses, never
force-pushes, and never rebases past a real conflict.

## Files

| File | Role |
|---|---|
| [`commands/fleet-land-self.md`](../commands/fleet-land-self.md) | the `owner: worker` skill (re-verify · sanitize · land · self-destruct; failure → `/fleet-blocked`) |
| [`bin/fleet-land-self.sh`](../bin/fleet-land-self.sh) | the mechanical driver (lease-gated hold-through-green merge + base pull + self-destruct) |
| [`bin/fleet-land-lease.sh`](../bin/fleet-land-lease.sh) | the shared per-repo land lease (mkdir-atomic · PID+TTL holder · steal-if-stale · `land_lease_mine`) |
| [`bin/dash-issue-session.sh`](../bin/dash-issue-session.sh) | `--self-land[=auto]` / `FLEET_SELF_LAND=1\|auto` seeds the extended lifecycle prompt (triggered or auto) |
| [`bin/worktree-autoclean.sh`](../bin/worktree-autoclean.sh) | the cleanup backstop if self-destruct fails |
| [`bin/fleet-land-self-selftest.sh`](../bin/fleet-land-self-selftest.sh) | hermetic tests (lease primitives + self-land driver) |

## Env knobs

Configured in `fleet.conf` / a per-fleet overlay (see `fleet.conf.example`):

| Var | Default | Meaning |
|---|---|---|
| `FLEET_SELF_LAND` | `0` | `0` off · `1` self-land, steward-triggered (implies `FLEET_ISSUE_BRIDGE=1`) · `auto` self-land, no trigger — `/fleet-ship` flows straight into the land, needs no bridge (issue #270) |

`fleet-land-self.sh` also honors these process-level knobs (rarely changed):
`LAND_SELF_METHOD` (squash), `LAND_SELF_POLL` (15s), `LAND_SELF_MAX_HOLD`
(1800s), `LAND_SELF_QUEUE_TIMEOUT` (1800s), `LAND_SELF_MAX_RETRY` (3),
`LAND_SELF_LEASE_TTL` (3600s). The land-lock directory is the **shared**
`FLEET_LAND_LEASE_DIR` (default `~/.claude/leases`) — set it in one place so
land-train and self-land relocate the lock together; `LAND_SELF_LEASE_DIR` /
`LAND_TRAIN_LEASE_DIR` remain per-tool overrides used by the selftests.
