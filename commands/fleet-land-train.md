# /fleet-land-train — serially land a batch of green PRs, one at a time

<!-- fleet skill · owner: steward -->

The batch complement to single-PR `/fleet-land`. Runs a **serial single-writer "land
train"** over this fleet's `$FLEET_REPO`: it merges green PRs **one at a time** —
update-branch → wait for green → merge → advance master → next — so each PR is
tested exactly once against the master it actually lands on (O(N) CI, not the
O(N²) thundering herd you get from updating every PR every time master moves).
Then, like `/fleet-land`, it does the *general* finish work: **base-pull once** after
the whole batch and **cleanup per merged PR**. It **mutates PRs** (update-branch
+ merge) on this fleet's own repo only and the fleet's base checkout
(`$FLEET_MAIN`), and takes a per-repo lease so two sessions never drive the train
at once. Merging is a steward operation, so this skill is **steward-only**.

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

What it does, per PR, in order:

1. **update-branch** — only when it's *this* PR's turn (never the tail early).
2. **wait** until the PR is green **and** up to date (polls; checks re-run
   after the update-branch).
3. **merge** with `--match-head-commit` so a head-sha race (master moved under
   us) is caught and bounded-retried, not merged blind.

A PR that can't make it **does not block the train** — it is **ejected** with a
reason and the train moves on:

| Eject reason | Meaning | What the human does |
|---|---|---|
| `conflict-needs-rebase` | DIRTY / CONFLICTING with base | rebase the branch by hand |
| `required-check-failed` | a required check is red | fix the failing check |
| `blocked-review-required` | green + up to date but still blocked | get the review / approval |
| `stuck-behind` / `merge-failed` | kept losing the head-sha race (≥ retry cap) | re-run land-train later |
| `timeout-<secs>s` | didn't go green within the per-PR budget | investigate CI, re-run |

**Note — a red *non-required* check does not block the train.** A PR whose only
red check is optional lands in GitHub's `UNSTABLE` merge state; branch protection
still considers it mergeable, so the train treats `UNSTABLE` as **READY** and
merges it. Only a **required** check going red (`BLOCKED` + failing) ejects a PR
(`required-check-failed`). This is intentional — the train merges exactly what
GitHub already considers landable — but can surprise you if you expect *any* red
check to hold a PR back.

The lease (`~/.claude/leases/land-train-<repo-slug>.lock`, steal-if-stale)
means a second `/fleet-land-train` on the same repo refuses with *"a train is
already running"* — that is expected; wait for the first to finish.

Note the **PR numbers the train reports as merged** — you need them for steps
3–4.

## 3. Land master into the fleet's base checkout — once, after the batch

The train advanced the remote master with each merge, but the fleet's base
checkout still points at the old master. Fast-forward it **once**, after the
whole batch:

```sh
git -C "$FLEET_MAIN" pull --ff-only          # the fleet's base checkout
```

If it refuses to fast-forward, stop and report — something diverged locally;
resolve it before cleaning up.

## 4. Clean up each merged PR's worktree + window

For **each PR the train merged** (from step 2's summary), remove its merged
`issue-<N>` worktree + branch and close the bound window. Resolve each PR's
issue from its head branch (`issue-<N>`):

```sh
for pr in <the merged PR numbers>; do
  issue=$(gh pr view "$pr" --repo "$FLEET_REPO" --json headRefName -q '.headRefName' | sed -n 's/^issue-\([0-9]\{1,\}\)$/\1/p')
  [ -z "$issue" ] && continue                # not an issue-<N> branch — skip cleanup
  wt=$(git -C "$FLEET_MAIN" worktree list --porcelain | \
       awk -v b="issue-$issue" '/^worktree /{p=$2} $0 ~ "branch refs/heads/"b"$"{print p}')
  [ -n "$wt" ] && git -C "$FLEET_MAIN" worktree remove "$wt"   # add --force only if it's clean but errors
  git -C "$FLEET_MAIN" branch -D "issue-$issue" 2>/dev/null || true
  win=$(tmux list-windows -t "$S" -F '#{window_id} #{@issue}' 2>/dev/null | awk -v i="$issue" '$2==i{print $1}')
  [ -n "$win" ] && tmux kill-window -t "$win"
done
```

Never remove a worktree with uncommitted changes — if `worktree remove` refuses,
report it rather than forcing; the work may not have shipped.

## 5. Report

Relay the tool's final summary: how many **merged**, which were **ejected**
(with reasons) and which **skipped**, plus the base-checkout pull and the
worktrees/windows cleaned up. If anything ejected, name the PRs and the one-line
human action each needs, then stop — do **not** try to rebase or force anything
yourself; ejected PRs are handed back to their authors.

If the batch landed claude-fleet tooling PRs and you're on the self-hosting
tooling fleet, remind the user to run `/fleet-sync-install` once to re-apply them to
the live install — `/fleet-land-train` deliberately does not touch it.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. The train never force-pushes and never `--admin`-bypasses
branch protection: it only merges PRs that GitHub already considers mergeable.
Tune behaviour with the `LAND_TRAIN_*` env knobs documented at the top of
`bin/land-train.sh` (poll interval, per-PR timeout, retry cap, merge method).
