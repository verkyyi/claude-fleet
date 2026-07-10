# /fleet-land — merge a green PR, then land it into the fleet's base checkout

<!-- fleet skill · owner: steward -->

The steward's finish line for a worker's PR: verify the PR is truly mergeable,
squash-merge it, fast-forward the fleet's base checkout to the new master, and
clean up the merged worktree + window. It **mutates this fleet's `$FLEET_REPO`**
(merges a PR) and the fleet's base checkout (`$FLEET_MAIN`). Merging is a
steward operation, so this skill is **steward-only** — a worker never runs it (a
worker `/fleet-ship`s; the steward `/fleet-land`s).

This skill is **fleet-agnostic**: it does the *general* finish work only —
merge + base-checkout pull + cleanup. It does **not** touch the live install
(`~/.claude/fleet`), reload daemons, re-merge hooks, or reinstall commands; that
tooling re-apply is a separate, tooling-fleet-only concern — run `/fleet-sync-install`
for it after landing a claude-fleet tooling PR.

**Argument** (`$ARGUMENTS`): the PR number to land (`/fleet-land 61`). Required — if
empty, ask the user which PR and stop.

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
- **Wrong seat** — `/fleet-land` is `owner: steward`. If `$SEAT` isn't `steward`,
  **refuse in one line and stop**, e.g. *"/fleet-land is steward-only; you're in the
  worker seat — `/fleet-ship` your branch and let the steward land it."* Never merge
  from the wrong seat.

Everything below operates on the resolved `$FLEET_REPO` / `$FLEET_MAIN` /
`$FLEET_BASE_BRANCH` — this fleet only.

## 1. Verify the PR is genuinely mergeable

Never merge a red or incomplete PR. Read its state:

```sh
gh pr view "<N>" --repo "$FLEET_REPO" \
  --json number,title,headRefName,mergeable,mergeStateStatus,statusCheckRollup,state
```

Decide from `mergeable` + `statusCheckRollup`:

- **`MERGEABLE` + all checks green** → proceed to step 2.
- **Red/blocked *only* because the branch is behind master** (mergeStateStatus
  `BEHIND`, checks otherwise green) → bring it up to date and re-check, do **not**
  merge blind:

  ```sh
  gh pr update-branch "<N>" --repo "$FLEET_REPO"
  ```

  Then wait for CI to re-run and re-view (re-run step 1) until it's green + up to
  date. Poll, don't merge on the stale result.
- **Genuinely failing** (a required check is red on its own merits), **CONFLICTING**
  (needs a real rebase), or the **work looks incomplete** → **STOP and report**.
  Do not merge, do not `--admin`-bypass, do not rebase the worker's branch
  yourself — hand it back with the one-line reason.

## 2. Squash-merge

```sh
gh pr merge "<N>" --repo "$FLEET_REPO" --squash
```

Do **not** rely on `--delete-branch`: it errors when the branch is still checked
out in a worker worktree. Branch/worktree cleanup happens in step 4.

## 3. Land master into the fleet's base checkout

The merge only moved the remote — the fleet's base checkout still points at the
old master. Fast-forward it:

```sh
git -C "$FLEET_MAIN" pull --ff-only          # the fleet's base checkout
```

If it refuses to fast-forward, stop and report — something diverged locally;
resolve it before continuing.

## 4. Clean up the merged worktree + window

The worker's `issue-<N>` worktree and branch are now merged and safe to remove;
close its window too. Find the window by its `@issue` binding. **Before** removing
the worktree, append a **history-ledger row** so the finished session stays
reviewable/resumable after cleanup (`/fleet-history`) — the worker's transcript
survives, but the index only exists if we capture it here, while the worktree
path (→ transcript dir + session id) is still known.

```sh
issue="<the #issue the PR closed>"          # from the PR body's `Closes #<issue>`
wt=$(git -C "$FLEET_MAIN" worktree list --porcelain | \
     awk -v b="issue-$issue" '/^worktree /{p=$2} $0 ~ "branch refs/heads/"b"$"{print p}')
win=$(tmux list-windows -t "$S" -F '#{window_id} #{@issue}' 2>/dev/null | awk -v i="$issue" '$2==i{print $1}')

# LEDGER (before removal): derives title/sha/mergedAt from the PR and
# transcript-dir + session-id from the worktree path; pulls the one-line summary
# from the dash cache via --win. Best-effort — never blocks the land on failure.
bash ~/.claude/fleet/bin/fleet-history.sh record \
  --repo "$FLEET_REPO" --main "$FLEET_MAIN" --session "$S" \
  --pr "<N>" --issue "$issue" --worktree "$wt" --win "$win" || true

[ -n "$wt" ] && git -C "$FLEET_MAIN" worktree remove "$wt"      # add --force only if it's clean but errors
git -C "$FLEET_MAIN" branch -D "issue-$issue" 2>/dev/null || true
# close the worker window bound to this issue (this fleet's session only)
[ -n "$win" ] && tmux kill-window -t "$win"
```

Never remove a worktree with uncommitted changes — if `worktree remove` refuses,
report it rather than forcing; the work may not have shipped.

## 5. Report — one line

```
#<issue> landed → <squash commit sha>
```

Name the PR, the issue it closed, and the landed sha. If you stopped at step 1
(not mergeable) or step 3 (base checkout diverged), report that instead —
clearly, with the one-line reason and what the human/worker must do.

If the PR changed the claude-fleet tooling itself and you're on the self-hosting
tooling fleet, note that the live install still needs `/fleet-sync-install` to pick
up the change — `/fleet-land` deliberately does not touch it.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. `/fleet-land` never force-pushes and never `--admin`-bypasses
branch protection: it only merges a PR GitHub already considers mergeable, after
CI is green on the master it lands on. Implementation is the worker's job — the
steward triages, lands, and hands the live-install re-apply to `/fleet-sync-install`.
