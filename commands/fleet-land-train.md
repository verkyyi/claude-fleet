# /fleet-land-train — serially land a batch of green PRs, one at a time

<!-- fleet skill · owner: steward -->

The batch complement to single-PR `/fleet-land`. Runs a **serial single-writer "land
train"** over this fleet's `$FLEET_REPO`: it lands green PRs **one at a time** —
update-branch → wait for green → merge → advance base → base-pull → clean up → next
— so each PR is tested exactly once against the base it actually lands on (O(N) CI,
not the O(N²) thundering herd you get from updating every PR every time the base
moves). Since issue #231 the train is a thin batch driver over `bin/fleet-land.sh`:
each PR gets the **full mechanical land** (merge + base fast-forward + history
ledger + worktree/window teardown) inside the script — **no manual base-pull or
cleanup follow-up**. It **mutates PRs** (update-branch + merge) on this fleet's own
repo only and the fleet's base checkout (`$FLEET_MAIN`), and every lap takes the
shared per-repo land lease so two landers never advance the base at once. Merging
is a steward operation, so this skill is **steward-only**.

This skill is **fleet-agnostic**: it never touches the live install
(`~/.claude/fleet`), reloads no daemons, re-merges no hooks, reinstalls no
commands. If the batch landed claude-fleet tooling PRs and you're on the
self-hosting tooling fleet, run `/fleet-sync-install` **once** afterward to re-apply
them to the live install.

**Argument** (`$ARGUMENTS`): optional. Pass explicit PR numbers to run exactly
those, in the order given (`/fleet-land-train 41 42 43`). With **no** argument it
auto-discovers the repo's open, non-draft, **green** PRs (ascending / FIFO) —
regardless of auto-merge arming — pre-filtering out the DIRTY/failing/draft
ones; this is the batch complement to single-PR `/fleet-land`. Prefix with `--dry-run`
to print the plan and each PR's current state and mutate **nothing**.

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
- **Wrong seat** — this skill is `owner: steward`. If `$SEAT` is not `steward`,
  **refuse in one line and stop**, e.g. *"/fleet-land-train is steward-only; you're
  in the worker seat."* Never drive the train from the wrong seat.

Everything below operates on the resolved `$FLEET_REPO` / `$FLEET_MAIN` — this
fleet only.

## 1. Preview the plan (dry-run first)

Always look before you leap. Print the serial plan and each PR's current
verdict without touching anything:

```sh
bash ~/.claude/fleet/bin/land-train.sh --dry-run $ARGUMENTS
```

Each line reads `#<n>  [<mergeState>/<checks>]  → <planned action>`
(`merge now` / `update-branch → wait green → merge` / `EJECT (reason)` / …).
If the queue is empty or every PR would eject, say so and stop — there is
nothing to run.

## 2. Run the train

When the plan looks right, run it for real:

```sh
bash ~/.claude/fleet/bin/land-train.sh $ARGUMENTS
```

What it does, **per PR, in order** — each lap is one `bin/fleet-land.sh` call:

1. **lease** — take the shared per-repo land lease and hold it through this PR's
   green-wait (so the base can't advance under it).
2. **update-branch** — only when it's *this* PR's turn (never the tail early),
   only if it's `BEHIND`.
3. **wait** until the PR is green **and** up to date (polls; checks re-run after
   the update-branch).
4. **merge** with `--match-head-commit` so a head-sha race (base moved under us)
   is caught and bounded-retried, not merged blind.
5. **finish the land** — `git -C $FLEET_MAIN pull --ff-only`, record the history
   ledger row (for `/fleet-history`), then tear down the worker's window +
   worktree + branch **in order** (window first, so the busy cwd frees). This all
   happens inside the script now — you do **not** base-pull or clean up by hand.

A PR that can't make it **does not block the train** — `fleet-land.sh` **ejects**
it with a reason and the train moves on:

| Eject reason | Meaning | What the human does |
|---|---|---|
| `conflict-needs-rebase` | DIRTY / CONFLICTING with base | rebase the branch by hand |
| `required-check-failed` | a required check is red | fix the failing check |
| `blocked` | green + up to date but still blocked (review required) | get the review / approval |
| `stuck-behind` / `merge-failed` | kept losing the head-sha race (≥ retry cap) | re-run land-train later |
| `max-hold-timeout` | didn't go green within the per-PR budget | investigate CI, re-run |
| `lease-wait-timeout` | another lander held the lease past the queue budget | wait / re-run |

**Note — a red *non-required* check does not block the train.** A PR whose only
red check is optional lands in GitHub's `UNSTABLE` merge state; branch protection
still considers it mergeable, so the train treats `UNSTABLE` as **READY** and
merges it. Only a **required** check going red (`BLOCKED` + failing) ejects a PR
(`required-check-failed`). This is intentional — the train merges exactly what
GitHub already considers landable — but can surprise you if you expect *any* red
check to hold a PR back.

The lease (`~/.claude/leases/land-<repo-slug>.lock`, steal-if-stale) is the
shared **per-repo land lease** — the SAME lock a worker `/fleet-land-self` and a
single `/fleet-land` take (issues #138, #231). The train takes it **per PR** (not
once for the whole batch), so a second landing path on the same repo interlocks
lap-by-lap rather than racing the base — that is expected; landing on a repo is
single-writer.

## 3. Report

Relay the tool's final summary: how many **merged**, which were **ejected**
(with reasons) and which **skipped**, plus a note that each merged PR was fully
landed (base fast-forwarded, ledger recorded, worktree + window cleaned up) by the
script. If anything ejected, name the PRs and the one-line human action each needs,
then stop — do **not** try to rebase or force anything yourself; ejected PRs are
handed back to their authors.

If the batch landed claude-fleet tooling PRs and you're on the self-hosting
tooling fleet, remind the user to run `/fleet-sync-install` once to re-apply them to
the live install — `/fleet-land-train` deliberately does not touch it.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. The train never force-pushes and never `--admin`-bypasses
branch protection: it only merges PRs that GitHub already considers mergeable.
Tune behaviour with the `LAND_TRAIN_*` env knobs documented at the top of
`bin/land-train.sh` (poll interval, per-PR timeout, retry cap, merge method) —
they are forwarded to `bin/fleet-land.sh` as its `LAND_*` knobs.
