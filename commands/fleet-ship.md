# /fleet-ship — finish ritual: verify, push, open the PR, arm auto-merge (never merge)

<!-- fleet skill · owner: worker -->

The worker's finish line: verify the change, make sure the `issue-<N>` worktree
is clean and pushed, open (or update) a PR that `Closes #<issue>`, and **arm
GitHub auto-merge** so the PR merges itself when it goes green. Mutates this
fleet's `$FLEET_REPO` — pushes your branch, opens/updates a PR, arms auto-merge,
and leaves a one-line issue comment. It does **not** touch the base checkout.

**HARD RULE: /fleet-ship never merges.** The fleet never merges — it arms
auto-merge and cleans up afterward. Arming auto-merge (`gh pr merge --auto`) is
*not* a merge: GitHub performs the merge only when the PR is green and branch
protection is satisfied — that is the whole gate. Once the merge happens, the
cleanup daemon (`com.claude-fleet.cleanup`) reaps the worktree/window/branch and
records the resume ledger. You push, open the PR, arm, and **stop**.

**Argument** (`$ARGUMENTS`): none — the issue is read from the window's `@issue`
binding.

## 0. Resolve fleet + guard seat (run FIRST, every time)

Env vars do NOT persist across separate Bash tool calls — run this once, then
reuse the literal values it prints:

```sh
source ~/.claude/fleet/bin/fleet-lib.sh
S=$(fleet_current_session); fleet_load_conf "$S"   # → FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH
SEAT=$(fleet_seat)                                 # → worker | steward | "" (ambiguous)
echo "repo=${FLEET_REPO:-} main=${FLEET_MAIN:-} base=${FLEET_BASE_BRANCH:-master} seat=${SEAT:-unknown}"
```

After the PR is open you always do the **same** thing (step 6): arm auto-merge and
stop. There is no self-land branch and no waiting for a `/land` trigger — GitHub
merges when green, and the cleanup daemon reaps afterward.

- **No fleet** (`FLEET_REPO` empty) → **ABORT** in one line: *"not inside a
  fleet — run this from a fleet session."* Never guess a repo.
- **Wrong seat** — `/fleet-ship` is `owner: worker`. If `$SEAT` isn't `worker`,
  **refuse in one line and stop**, e.g. *"/fleet-ship is worker-only; you're in the
  steward seat."* Never proceed from the wrong seat.

Everything below operates on the resolved `$FLEET_REPO` / `$FLEET_MAIN` /
`$FLEET_BASE_BRANCH` — this fleet only.

## 1. Identify the issue + branch

```sh
issue=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@issue}')
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
echo "issue=${issue:-none} branch=${branch:-none}"
```

- If `$issue` is empty this window isn't bound to an issue — **stop**: *"no
  @issue on this window — nothing to ship."*
- You should be on the `issue-<N>` branch inside its worktree (the worker seat
  guarantees this). If not, stop and say why.

## 2. Verify per the repo's own conventions

Before you push, make sure the change passes whatever **this** repo uses to gate
a PR — its own tests, linters, and CI (discover them from its `CLAUDE.md` /
`README` / `.github/workflows` if you're unsure what they are). Don't open a red
PR: the repo's own PR checks are the real gate, and the steward reviews before
landing.

Keep this step **repo-agnostic** — `/fleet-ship` runs for a worker on ANY repo a
fleet targets, so discover and run the *target* repo's checks; do NOT hardcode
one project's commands (a specific `bin/…` script, a named test runner) into this
shared skill.

If the checks fail, **do not open the PR** — report what failed and stop.

## 3. Ensure the worktree is clean and pushed

```sh
git status --porcelain                       # must be empty — commit anything left
git push -u origin "<branch>"                # publish the branch
```

- Commit any outstanding work with a clear message before pushing.
- Never commit or push from the base checkout — only from this `issue-<N>`
  worktree.

## 4. Open or update the PR (Closes #<issue>)

If no PR exists for `<branch>`, create one; otherwise update its body. The body
**must** contain `Closes #<issue>` (so the merge auto-closes it) plus a short
summary of the change and how it was verified:

```sh
gh pr view --repo "$FLEET_REPO" "<branch>" >/dev/null 2>&1 \
  && gh pr edit  --repo "$FLEET_REPO" "<branch>" --body "<body>" \
  || gh pr create --repo "$FLEET_REPO" --base "$FLEET_BASE_BRANCH" \
       --head "<branch>" --title "<title>" --body "<body>"
```

Body shape:

```
<one-line summary of the change>

Closes #<issue>

## How it was verified
- <what you ran and what it showed>
```

## 4b. Arm GitHub auto-merge (the fleet never merges — GitHub does)

The finish move: tell GitHub to merge the PR **itself** the moment it is green and
branch protection is satisfied. You do NOT merge — you arm.

```sh
gh pr merge --repo "$FLEET_REPO" --auto --squash "<branch-or-PR>" 2>&1
```

- On success the PR is queued: GitHub squash-merges it when the required checks
  pass. Nothing else in the fleet merges it — the `com.claude-fleet.cleanup`
  daemon reaps the worktree/window/branch and records the resume ledger afterward.
- If arming **fails because the repo has auto-merge disabled** (GitHub returns
  *"Auto-merge is not allowed for this repository"* or similar), do **not** fail
  the ship and do **not** merge by hand — the PR is still open and reviewable.
  **Say so in the ship report**: the PR is open but auto-merge could not be armed
  (enable it in the repo's Settings → General, or merge on the web when green).
- Never pass `--admin` and never merge the PR yourself — arming is the only
  merge-adjacent action /fleet-ship takes.

## 5. Comment on the issue + leave the window sensible

- One-line summary comment on the issue — via `fleet-comment.sh --note` so this
  worker's own record comment carries `<!-- fleet:no-relay -->` and never loops
  back in when the issue-bridge is on (issue #132), and the per-role `worker`
  footer (issue #224); the fallback keeps the marker INLINE (without it the bridge
  would relay this comment back into the worker) plus a minimal static `worker`
  footer so attribution survives degraded mode:
  `~/.claude/fleet/bin/fleet-comment.sh "<issue>" --repo "$FLEET_REPO" --note --body 'Shipped → <PR URL>' || gh issue comment "<issue>" --repo "$FLEET_REPO" --body $'Shipped → <PR URL>\n\n— fleet · worker · #<issue>\n<!-- fleet:from role=worker issue=<issue> -->\n<!-- fleet:no-relay -->'`.
- Leave the window in a done-ish state (the turn ending naturally sets it).

## 6. Report — then stop

**/fleet-ship never merges** — pushing + opening the PR + arming auto-merge is the
whole finish of *ship*. There is no self-land and no `/land` trigger to wait for.

- Print the PR URL and state explicitly: **auto-merge is armed** — GitHub will
  squash-merge it when it goes green, and `com.claude-fleet.cleanup` will reap the
  worktree/window/branch and record the resume ledger. Do not merge, do not deploy.
  **Stop here.**
- If auto-merge could not be armed (step 4b — repo has it disabled), say so: the
  PR is open and reviewable but will not self-merge; a human enables auto-merge or
  merges it on the web when green. Still **stop** — never merge it yourself.

If the checks in step 2 failed you should already have stopped without opening the
PR. A blocker you can't resolve is `/fleet-blocked`, not a forced merge.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. The base checkout is read-only (hook-enforced): a worker
edits inside its `issue-<N>` worktree and lands via PR; a steward files/triages
and hands implementation to a worker.
