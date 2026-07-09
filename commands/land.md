# /land — merge a green PR, then deploy the live install

<!-- fleet skill · owner: steward -->

The steward's finish line for a worker's PR: verify the PR is truly mergeable,
squash-merge it, deploy the new master into both live checkouts, reload only the
daemons that actually need it, and clean up the merged worktree + window. It
**mutates this fleet's `$FLEET_REPO`** (merges a PR) and the two live checkouts
(`$FLEET_MAIN` and `~/.claude/fleet`). Merging + deploying is a steward
operation, so this skill is **steward-only** — a worker never runs it (a worker
`/ship`s; the steward `/land`s).

**Argument** (`$ARGUMENTS`): the PR number to land (`/land 61`). Required — if
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
- **Wrong seat** — `/land` is `owner: steward`. If `$SEAT` isn't `steward`,
  **refuse in one line and stop**, e.g. *"/land is steward-only; you're in the
  worker seat — `/ship` your branch and let the steward land it."* Never merge
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
out in a worker worktree. Branch/worktree cleanup happens in step 5.

## 3. Deploy master into both live checkouts

The merge only moved the remote — the running daemons and dash read from disk.
Fast-forward **both** live checkouts:

```sh
git -C "$FLEET_MAIN" pull --ff-only          # the fleet's base checkout
git -C ~/.claude/fleet pull --ff-only        # the live install the daemons/dash use
```

If either refuses to fast-forward, stop and report — something diverged
locally; resolve it before continuing.

## 4. Reload daemons — only if the change requires it

Most script-body changes need **no reload**: an *interval* daemon
(collector / classify / summarize / diskguard) re-reads its script from disk on
its next tick. Reload only when:

- a **plist/timer interval changed** (macOS: `launchctl bootout` then
  `bootstrap` the unit; Linux: `systemctl --user daemon-reload` + restart the
  timer), **or**
- the **KeepAlive spinner** (`com.claude-fleet.spinner`) script changed — it's
  long-lived, so `launchctl kickstart -k gui/$(id -u)/com.claude-fleet.spinner`
  (Linux: `systemctl --user restart claude-fleet-spinner.service`).

If `hooks/settings-hooks.json` changed, re-merge the delta into
`~/.claude/settings.json` — **append** to the hook arrays, never clobber
existing entries (back it up first).

If the PR touched none of these, say "no reload needed" and move on.

## 5. Clean up the merged worktree + window

The worker's `issue-<N>` worktree and branch are now merged and safe to remove;
close its window too. Find the window by its `@issue` binding.

```sh
issue="<the #issue the PR closed>"          # from the PR body's `Closes #<issue>`
wt=$(git -C "$FLEET_MAIN" worktree list --porcelain | \
     awk -v b="issue-$issue" '/^worktree /{p=$2} $0 ~ "branch refs/heads/"b"$"{print p}')
[ -n "$wt" ] && git -C "$FLEET_MAIN" worktree remove "$wt"      # add --force only if it's clean but errors
git -C "$FLEET_MAIN" branch -D "issue-$issue" 2>/dev/null || true
# close the worker window bound to this issue (this fleet's session only)
win=$(tmux list-windows -t "$S" -F '#{window_id} #{@issue}' 2>/dev/null | awk -v i="$issue" '$2==i{print $1}')
[ -n "$win" ] && tmux kill-window -t "$win"
```

Never remove a worktree with uncommitted changes — if `worktree remove` refuses,
report it rather than forcing; the work may not have shipped.

## 6. Report — one line

```
#<issue> landed → <squash commit sha>
```

Name the PR, the issue it closed, and the deploy sha. If you stopped at step 1
(not mergeable) or step 3 (deploy diverged), report that instead — clearly, with
the one-line reason and what the human/worker must do.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. `/land` never force-pushes and never `--admin`-bypasses
branch protection: it only merges a PR GitHub already considers mergeable, after
CI is green on the master it lands on. Implementation is the worker's job — the
steward triages, lands, and deploys.
