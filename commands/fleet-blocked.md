# /fleet-blocked — signal a blocker instead of silently stalling

<!-- fleet skill · owner: worker -->

When a worker can't make progress, this records why on the bound issue and flips
the window to the `needs` state so it surfaces red in the dash and status bar for
the steward to see. Mutates ONLY the bound issue on this fleet's `$FLEET_REPO`
(one comment) and this window's local tmux state — no branches, no PRs.

**Argument** (`$ARGUMENTS`): `<why>` — a one-line reason you're blocked
(required). If empty, ask the user for the reason and stop.

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
- **Wrong seat** — `/fleet-blocked` is `owner: worker`. If `$SEAT` isn't `worker`,
  **refuse in one line and stop**, e.g. *"/fleet-blocked is worker-only; you're in the
  steward seat."* Never proceed from the wrong seat.

Everything below operates on the resolved `$FLEET_REPO` / `$FLEET_MAIN` /
`$FLEET_BASE_BRANCH` — this fleet only.

## 1. Require a reason + the bound issue

```sh
issue=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@issue}')
echo "issue=${issue:-none}"
```

- If `$ARGUMENTS` is empty, ask the user what's blocking them and **stop** — a
  blocker with no reason helps no one.
- If `$issue` is empty this window isn't bound to an issue — **stop**: *"no
  @issue on this window — nowhere to post the blocker."*

## 2. Post the blocker on the issue

Prefix the comment so it's scannable in the steward's sweep. Post it through
`fleet-comment.sh --note` (a worker→steward record comment) so it carries the
`<!-- fleet:no-relay -->` marker and never loops back into this worker when the
issue-bridge is on (issue #132). The fallback keeps the marker INLINE (without it
the bridge would relay the worker's own blocker back into itself):

```sh
~/.claude/fleet/bin/fleet-comment.sh "<issue>" --repo "$FLEET_REPO" --note --body '⛔ blocked: <why>' \
  || gh issue comment "<issue>" --repo "$FLEET_REPO" --body $'⛔ blocked: <why>\n\n<!-- fleet:no-relay -->'
```

## 3. Flip the window to `needs`

This is what makes the window go red in the dash + status bar so the steward
notices it:

```sh
sh ~/.claude/fleet/bin/set-claude-state.sh needs
```

## 4. Report (keep it short)

One line: that you posted the blocker on issue #`<issue>` and set the window to
`needs`. Note the steward will see it and can unblock or reassign. Then stop —
don't keep spinning on the blocked work.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. The base checkout is read-only (hook-enforced): a worker
edits inside its `issue-<N>` worktree and lands via PR; a steward files/triages
and hands implementation to a worker.
