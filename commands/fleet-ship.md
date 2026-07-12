# /fleet-ship — finish ritual: verify, push, open the PR (never merge)

<!-- fleet skill · owner: worker -->

The worker's finish line: verify the change, make sure the `issue-<N>` worktree
is clean and pushed, and open (or update) a PR that `Closes #<issue>`. Mutates
this fleet's `$FLEET_REPO` — pushes your branch, opens/updates a PR, and leaves
a one-line issue comment. It does **not** touch the base checkout.

**HARD RULE: /fleet-ship never merges.** Pushing + opening the PR is the finish line;
the steward's `/fleet-land` does the merge + deploy. (This is the exact discipline we
want after a worker self-merged its own PR.)

**Argument** (`$ARGUMENTS`): none — the issue is read from the window's `@issue`
binding.

## 0. Resolve fleet + guard seat (run FIRST, every time)

Env vars do NOT persist across separate Bash tool calls — run this once, then
reuse the literal values it prints:

```sh
source ~/.claude/fleet/bin/fleet-lib.sh
S=$(fleet_current_session); fleet_load_conf "$S"   # → FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH
SEAT=$(fleet_seat)                                 # → worker | steward | "" (ambiguous)
echo "repo=${FLEET_REPO:-} main=${FLEET_MAIN:-} base=${FLEET_BASE_BRANCH:-master} seat=${SEAT:-unknown} self_land=${FLEET_SELF_LAND:-0}"
```

`self_land` decides what you do **after** the PR is open (step 6): `0` = stop, the
steward lands (`/fleet-land`); `1` = self-land, but WAIT for the steward's `/land`
trigger; `auto` = self-land straight away — flow into `/fleet-land-self` yourself.

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

## 5. Comment on the issue + leave the window sensible

- One-line summary comment on the issue — via `fleet-comment.sh --note` so this
  worker's own record comment carries `<!-- fleet:no-relay -->` and never loops
  back in when the issue-bridge is on (issue #132), and the per-role `worker`
  footer (issue #224); the fallback keeps the marker INLINE (without it the bridge
  would relay this comment back into the worker) plus a minimal static `worker`
  footer so attribution survives degraded mode:
  `~/.claude/fleet/bin/fleet-comment.sh "<issue>" --repo "$FLEET_REPO" --note --body 'Shipped → <PR URL>' || gh issue comment "<issue>" --repo "$FLEET_REPO" --body $'Shipped → <PR URL>\n\n— fleet · worker · #<issue>\n<!-- fleet:from role=worker issue=<issue> -->\n<!-- fleet:no-relay -->'`.
- Leave the window in a done-ish state (the turn ending naturally sets it).

## 6. Report — then follow the fleet's land lifecycle

**/fleet-ship never merges** — pushing + opening the PR is always the finish of
*ship*. What happens next depends on `self_land` (from step 0):

- **`0` (steward-lands, default)** — Print the PR URL and state explicitly: **the
  steward will land it (`/fleet-land`).** Do not merge, do not deploy. **Stop here.**
- **`1` (self-land, triggered)** — Print the PR URL and **WAIT.** Do not merge. The
  steward reviews and triggers the land by commenting `/land` on the issue (relayed
  to you by the issue-bridge); only then do you run `/fleet-land-self`. **Stop here.**
- **`auto` (self-land, auto — issue #270)** — the steward trigger is OPTIONAL.
  After the PR is open, **immediately continue into `/fleet-land-self`** (no `/land`
  comment required). It waits for CI green under the hold-through-green lease, then
  squash-merges your own PR, fast-forwards the base, and self-destructs. If it
  can't land cleanly, it hands back via `/fleet-blocked` — never force.

Only the `auto` path continues past ship on its own; `0`/`1` stop and wait.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. The base checkout is read-only (hook-enforced): a worker
edits inside its `issue-<N>` worktree and lands via PR; a steward files/triages
and hands implementation to a worker.
