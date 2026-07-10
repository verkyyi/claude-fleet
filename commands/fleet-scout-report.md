# /fleet-scout-report — a scout's closing move: post findings + self-clean

<!-- fleet skill · owner: worker -->

The read-only scout's finish line (the `/fleet-ship` analogue for an
investigation, issue #148): post your findings as a comment on the bound issue,
decide whether the finding **converts to ship work** (leave the issue open) or is
done (close it), then **self-clean** this window/worktree. It mutates only the
bound issue on this fleet's `$FLEET_REPO` (one comment, optional close) — it
touches **no branches and no PRs** (a scout never opens one).

**HARD RULE: a scout never opens a PR and never edits the base checkout.** This
command's only writes are the findings comment and the optional issue close.

**Argument** (`$ARGUMENTS`): none — the issue is read from the window's `@issue`
binding, and the findings come from your own investigation (this turn's context).

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
- **Wrong seat** — `/fleet-scout-report` is `owner: worker`. If `$SEAT` isn't
  `worker`, **refuse in one line and stop**, e.g. *"/fleet-scout-report is
  worker-only; you're in the steward seat."* Never proceed from the wrong seat.

Everything below operates on the resolved `$FLEET_REPO` / `$FLEET_MAIN` /
`$FLEET_BASE_BRANCH` — this fleet only.

## 1. Identify the issue (and confirm you're a scout)

```sh
issue=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@issue}')
scout=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@scout}')
echo "issue=${issue:-none} scout=${scout:-no}"
```

- If `$issue` is empty this window isn't bound to an issue — **stop**: *"no
  @issue on this window — nothing to report."*
- If `$scout` isn't `1` this window wasn't spawned as a scout. You almost
  certainly want `/fleet-ship` instead — **stop and say so** rather than
  self-cleaning a normal worker.

## 2. Post the findings as a comment

Write your findings up as a clear, self-contained comment (what you looked at,
what you found, concrete file:line pointers, and — if relevant — a recommended
next step). Post it via `fleet-comment.sh --note` so the record comment carries
`<!-- fleet:no-relay -->` and never loops back into a worker when the
issue-bridge is on (issue #132); the fallback keeps the marker INLINE:

```sh
~/.claude/fleet/bin/fleet-comment.sh "<issue>" --repo "$FLEET_REPO" --note --body '<findings>' \
  || gh issue comment "<issue>" --repo "$FLEET_REPO" --body $'<findings>\n\n<!-- fleet:no-relay -->'
```

For a long report, pipe the body on stdin:
`printf '%s' "$report" | ~/.claude/fleet/bin/fleet-comment.sh "<issue>" --repo "$FLEET_REPO" --note`.

## 3. Decide: convert to ship work, or done?

- **Converts to ship work** — the investigation surfaced something worth
  building/fixing. **Leave the issue OPEN** and end your comment with a one-line
  "recommend converting to ship work" so the steward can spawn a normal worker
  (or re-label + `/fleet-new-issue`-style follow-up). Self-clean **without**
  `--close`.
- **Done** — the question is answered and nothing needs building. **Close** the
  issue as part of the teardown (`--close` below).

## 4. Self-clean this window/worktree

A scout has no PR to merge, so the closing move is a teardown only — kill this
window and drop its read-only worktree (mirrors self-land's ordered
self-destruct: window dies first, releasing the cwd, then the worktree is
removed):

```sh
# done (nothing to build) → also close the issue:
bash ~/.claude/fleet/bin/fleet-scout-clean.sh --close
# converts to ship work → leave the issue open:
bash ~/.claude/fleet/bin/fleet-scout-clean.sh
```

If the teardown can't run cleanly (e.g. no tmux server), the worktree is left
behind — say so; it can be removed by hand (`cwrm` / `git worktree remove
--force`).

## 5. Report (one line, before the teardown fires)

State it plainly: *findings posted on #<issue> → <left open for ship
conversion | closed>; self-cleaning.* Then stop — the teardown kills this window.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. A scout is read-only: it never opens a PR and never edits
the base checkout (hook-enforced). Implementation, when a finding converts to
ship work, is a separate normal worker's job.
