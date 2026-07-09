# /fleet-history — browse & resume landed (merged + cleaned-up) worker sessions

<!-- fleet skill · owner: steward -->

When `/fleet-land` merges a worker's PR it removes the `issue-<N>` worktree and
kills the window — but the worker's Claude transcript **survives** under
`~/.claude/projects/`. This skill surfaces those finished sessions from the
land-time history ledger (`bin/fleet-history.sh`): **list** what landed, **open**
a PR, **review** the recorded transcript, and — the point — **resume** a landed
session by reconstructing its removed worktree off the squash SHA. It reads the
ledger and may recreate a worktree in the fleet's base checkout (`$FLEET_MAIN`);
it never merges or mutates `$FLEET_REPO`. Browsing/landing is a steward concern,
so this skill is **steward-only**.

**Argument** (`$ARGUMENTS`): optional.
- empty → list recent landed sessions (newest first).
- a word → list, filtered to rows matching that substring (issue #, title, PR…).
- `resume <issue|#PR>` → resume that landed session (see step 3).

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
- **Wrong seat** — this skill is `owner: steward`. If `$SEAT` isn't `steward`,
  **refuse in one line and stop**, e.g. *"/fleet-history is steward-only; you're in
  the worker seat."*

Everything below operates on the resolved `$FLEET_REPO` / `$FLEET_MAIN` — this
fleet only.

## 1. List landed sessions

```sh
bash ~/.claude/fleet/bin/fleet-history.sh list --repo "$FLEET_REPO" $ARGUMENTS
```

Each row is `#issue · when · title · PR · squash-sha · one-line-summary`, newest
first. If the ledger is empty, say so — nothing has been landed-and-recorded yet
(the ledger fills as `/fleet-land` / `/fleet-land-train` land PRs). Relay the
list; if the user passed a filter, note it.

Same data is one keystroke away in the dashboard: **⌃t** toggles the dash between
its live session list and this landed view (Enter there opens the PR).

## 2. Per-entry actions (offer these on a chosen row)

- **Open the PR** — `gh pr view <PR> --repo "$FLEET_REPO" --web` (or without
  `--web` for the diff inline).
- **Review the transcript** (read-only, no resume) — page the recorded jsonl:

  ```sh
  read -r tdir sid < <(bash ~/.claude/fleet/bin/fleet-history.sh path --repo "$FLEET_REPO" <issue|#PR>)
  [ -n "$sid" ] && ${PAGER:-less} "$tdir/$sid.jsonl"
  ```

- **Resume** — step 3.

## 3. Resume a landed session

The land cleanup removed the worktree, so resume must **reconstruct** it. The
helper does that off the recorded squash SHA (the branch is usually deleted
post-merge, so it uses the SHA, not the branch) and tells you exactly how to
resume:

```sh
bash ~/.claude/fleet/bin/fleet-history.sh resume --exec \
  --repo "$FLEET_REPO" --main "$FLEET_MAIN" <issue|#PR>
```

It prints ONE verdict line — act on it:

| Verdict | Meaning | What you do |
|---|---|---|
| `RESUME⇥<worktree>⇥<session-id>⇥<cmd>` | worktree recreated off the SHA; transcript present | `cd <worktree>` and run the printed `claude --resume <id> --fork-session` |
| `FROM-PR⇥<PR>⇥<cmd>` | no usable SHA/transcript, but a PR is linked | try the printed `claude --from-pr <PR> --fork-session` |
| `REVIEW-ONLY⇥<reason>` | nothing resumable (SHA gone / no transcript) | fall back to step 2 (review the PR/transcript); don't force it |

Notes:
- **`--fork-session` is the default** — resuming forks a NEW session id so you
  never mutate the original landed transcript. Drop it only if you deliberately
  want to continue the same session (`--no-fork`).
- **Which mechanism proved reliable:** recreating the worktree off the squash SHA
  → `claude --resume <session-id>` is the primary, verified path (it loads the
  surviving transcript regardless of branch deletion). `claude --from-pr <PR>` is
  the degrade path when the SHA/transcript is missing.
- To resume without leaving the worktree behind afterward, remove it when done:
  `git -C "$FLEET_MAIN" worktree remove <worktree>` (it's a throwaway checkout at
  the squash SHA).

## 4. Report — keep it short

For a **list**: relay the rows (or "nothing landed yet"). For a **resume**: name
the issue/PR, which mechanism was used (resume-off-SHA vs `--from-pr` vs
review-only), and the worktree it landed in — then hand control to the resumed
session.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` / `$FLEET_MAIN` only — never another
fleet's repo, sessions, or ledger. This skill never merges, force-pushes, or
edits history; it reads the ledger and, on resume, recreates a **throwaway**
worktree at an already-merged SHA. The ledger is written by `/fleet-land` /
`/fleet-land-train` at land time — this skill only reads and acts on it.
