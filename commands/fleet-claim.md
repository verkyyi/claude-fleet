# /fleet-claim — startup ritual for a freshly-spawned worker

<!-- fleet skill · owner: worker -->

Formalizes the one-shot seed prompt a worker is spawned with: read the bound
issue, stake a collision-proof claim on it, then restate the scope and sketch a
plan before you implement. Mutates ONLY the bound issue on this fleet's
`$FLEET_REPO` (an assignee + a one-time `▶ claiming` comment) — it touches no
branches or PRs. Idempotent: re-running it after you already claimed does not
re-comment.

**Argument** (`$ARGUMENTS`): none — the issue is read from the window's `@issue`
binding, not an argument.

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
- **Wrong seat** — `/fleet-claim` is `owner: worker`. If `$SEAT` isn't `worker`,
  **refuse in one line and stop**, e.g. *"/fleet-claim is worker-only; you're in the
  steward seat."* Never proceed from the wrong seat.

Everything below operates on the resolved `$FLEET_REPO` / `$FLEET_MAIN` /
`$FLEET_BASE_BRANCH` — this fleet only.

## 1. Read the bound issue

Get the issue number from the window (set by the spawner), then read the issue
with its comments:

```sh
issue=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@issue}')
echo "issue=${issue:-none}"
```

- If `$issue` is empty, this window isn't bound to an issue — **stop** in one
  line: *"no @issue on this window — nothing to claim."*
- Otherwise read it (reuse the literal number):
  `gh issue view "<issue>" --repo "$FLEET_REPO" --comments`.

## 2. Claim it (the anti-collision rail)

The fleet uses two markers so nothing else grabs an owned issue: the GitHub
assignee **and** a `▶ claiming` comment. Set both — but idempotently.

```sh
# Am I already the assignee? (empty output = not yet mine)
mine=$(gh issue view "<issue>" --repo "$FLEET_REPO" \
  --json assignees -q '.assignees[].login' 2>/dev/null | grep -Fx "$(gh api user -q .login)")
# Is there already a "▶ claiming" comment? (non-empty = already claimed)
claimed=$(gh issue view "<issue>" --repo "$FLEET_REPO" \
  --json comments -q '.comments[].body' 2>/dev/null | grep -F '▶ claiming' | head -n1)
echo "mine=${mine:-no} claimed=${claimed:+yes}"
```

- Assign to yourself only if not already yours:
  `gh issue edit "<issue>" --repo "$FLEET_REPO" --add-assignee @me`.
- Post the claim comment only if none exists yet:
  `gh issue comment "<issue>" --repo "$FLEET_REPO" --body '▶ claiming'`.
- If both were already set, say so and skip both writes — do **not** re-comment.

## 3. Restate scope + plan, then hand back

- One line restating what the issue asks for, in your own words.
- A short numbered plan (the steps you'll take to implement it).
- Stop here. Implementation is the worker's job (yours or the human's) — `/fleet-claim`
  only gets you a clean, uncontested start. `/fleet-ship` is the finish line.

## 4. Report (keep it short)

One line: the issue number + title, and whether you just claimed it or it was
already claimed. Then the restated scope + plan from step 3.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. The base checkout is read-only (hook-enforced): a worker
edits inside its `issue-<N>` worktree and lands via PR; a steward files/triages
and hands implementation to a worker.
