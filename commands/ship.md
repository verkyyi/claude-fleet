# /ship — finish ritual: verify, push, open the PR (never merge)

<!-- fleet skill · owner: worker -->

The worker's finish line: verify the change, make sure the `issue-<N>` worktree
is clean and pushed, and open (or update) a PR that `Closes #<issue>`. Mutates
this fleet's `$FLEET_REPO` — pushes your branch, opens/updates a PR, and leaves
a one-line issue comment. It does **not** touch the base checkout.

**HARD RULE: /ship never merges.** Pushing + opening the PR is the finish line;
the steward's `/land` does the merge + deploy. (This is the exact discipline we
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
echo "repo=${FLEET_REPO:-} main=${FLEET_MAIN:-} base=${FLEET_BASE_BRANCH:-master} seat=${SEAT:-unknown}"
```

- **No fleet** (`FLEET_REPO` empty) → **ABORT** in one line: *"not inside a
  fleet — run this from a fleet session."* Never guess a repo.
- **Wrong seat** — `/ship` is `owner: worker`. If `$SEAT` isn't `worker`,
  **refuse in one line and stop**, e.g. *"/ship is worker-only; you're in the
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

## 2. Verify per the repo's conventions

Run the project's checks and only continue if they pass:

- `/verify` — exercise the change end-to-end.
- `/code-review` — review the working diff.
- `bash bin/ci-shellcheck.sh` — runs the **exact** shellcheck invocation CI
  runs (pinned version from `.shellcheck-version`, `--severity=warning`), so its
  verdict matches the PR gate. Run it before pushing; it exits non-zero on any
  finding and warns if your local shellcheck has drifted from the pinned version.
- Plus anything else the repo requires (e.g. `bash bin/fleet-doctor.sh`).

If verification fails, **do not open the PR** — report what failed and stop.

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

- One-line summary comment on the issue:
  `gh issue comment "<issue>" --repo "$FLEET_REPO" --body 'Shipped → <PR URL>'`.
- Leave the window in a done-ish state (the turn ending naturally sets it).

## 6. Report — and stop

Print the PR URL and state explicitly: **the steward will land it (`/land`);
/ship does not merge.** Do not merge, do not deploy. Stop here.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. The base checkout is read-only (hook-enforced): a worker
edits inside its `issue-<N>` worktree and lands via PR; a steward files/triages
and hands implementation to a worker.
