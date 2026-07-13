# /fleet-history — browse & resume closed worker sessions (landed + unlanded)

<!-- fleet skill · owner: steward -->

When the cleanup daemon (or the steward's manual reap op) reaps a merged worker's
PR it removes the `issue-<N>` worktree and kills the window — but the worker's Claude transcript
**survives** under
`~/.claude/projects/`. This skill surfaces those finished sessions from the
history ledger (`bin/fleet-history.sh`): **list** what closed, **open**
a PR, **review** the recorded transcript, and — the point — **resume** a session.
It reads the ledger and may recreate a worktree in the fleet's base checkout
(`$FLEET_MAIN`); it never merges or mutates `$FLEET_REPO`. Browsing/landing is a
steward concern, so this skill is **steward-only**.

Two kinds of row live in the ledger (the `state` column, #320, distinguishes them
— `✓` vs `✗` in the list):
- **landed** (`✓`) — recorded on the land path when a merged PR was reaped:
  carries a PR + squash SHA, so resume reconstructs the removed worktree off the SHA.
- **closed-unlanded** (`✗`) — recorded by the ledger-watch daemon
  (`com.claude-fleet.ledger-watch`) when a worker window VANISHED without landing
  (closed by hand, crashed, abandoned/blocked). No PR/SHA — but its worktree
  usually **still exists on disk** (worktree-autoclean keeps unmerged), so resume
  just **reuses it** (no SHA reconstruction). If it was force-removed there is no
  SHA to rebuild from → resume degrades to REVIEW-ONLY.

**Argument** (`$ARGUMENTS`): optional.
- empty → list recent closed sessions (newest first, landed + unlanded).
- a word → list, filtered to rows matching that substring (issue #, title, PR…).
- `resume <issue|#PR>` → resume that session, landed or unlanded (see step 3).

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

## 1. List closed sessions

```sh
bash ~/.claude/fleet/bin/fleet-history.sh list --repo "$FLEET_REPO" $ARGUMENTS
```

Each row is `glyph · #issue · when · title · PR · squash-sha · one-line-summary`,
newest first — the glyph is `✓` (landed) or `✗` (closed-unlanded, #320), and
`when` is a friendly relative span (`2 hours`, `3 days`), not a raw timestamp
(issue #228). A closed-unlanded row has no PR/SHA (both `-`). If the ledger is
empty, say so — nothing has been recorded yet (the ledger fills as the cleanup
daemon reaps merged PRs and the ledger-watch daemon indexes closed-but-unlanded
windows). Relay the list; if the user passed a filter, note it.

Same data is one keystroke away in the dashboard: **⌃t** toggles the dash between
its live session list and this landed view. The landed view shares the SAME
aligned columns as the live list (issue · window · summary · **act** · PR · ctx,
where `act` is time-since-merge), so the two read as one table. In the landed
view **Enter** opens the PR and **⌃o** restores the highlighted session into a new
window (the one-key form of step 3's resume).

## 2. Per-entry actions (offer these on a chosen row)

- **Open the PR** — `gh pr view <PR> --repo "$FLEET_REPO" --web` (or without
  `--web` for the diff inline).
- **Review the transcript** (read-only, no resume) — page the recorded jsonl:

  ```sh
  read -r tdir sid < <(bash ~/.claude/fleet/bin/fleet-history.sh path --repo "$FLEET_REPO" <issue|#PR>)
  [ -n "$sid" ] && ${PAGER:-less} "$tdir/$sid.jsonl"
  ```

- **Resume** — step 3.

## 3. Resume a session

Resume needs a worktree to run in. For a **landed** row the land cleanup removed
it, so the helper **reconstructs** it off the recorded squash SHA (the branch is
usually deleted post-merge, so it uses the SHA, not the branch). For a
**closed-unlanded** row (#320) the worktree usually **still exists on disk**
(worktree-autoclean keeps unmerged), so the helper just **reuses it** — no SHA
needed. Either way it prints how to resume:

```sh
bash ~/.claude/fleet/bin/fleet-history.sh resume --exec \
  --repo "$FLEET_REPO" --main "$FLEET_MAIN" <issue|#PR>
```

It prints ONE verdict line — act on it:

| Verdict | Meaning | What you do |
|---|---|---|
| `RESUME⇥<worktree>⇥<session-id>⇥<cmd>` | worktree present (reused for an unlanded row, or recreated off the SHA for a landed one); transcript present | `cd <worktree>` and run the printed `claude --resume <id> --fork-session` |
| `FROM-PR⇥<PR>⇥<cmd>` | no usable SHA/transcript, but a PR is linked | try the printed `claude --from-pr <PR> --fork-session` |
| `REVIEW-ONLY⇥<reason>` | nothing resumable (SHA gone / worktree force-removed / no transcript) | fall back to step 2 (review the PR/transcript); don't force it |

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
  the squash SHA). Or just close the restored window — its reconstructed worktree
  is merged+clean+unattached, so the worktree janitor prunes it on the next sweep.
- **One-key restore from the dash** (issue #228): in the landed view (⌃t), press
  **⌃o** on a row to run exactly this reconstruct-off-SHA resume and open the
  session in a NEW window — no manual `cd`/`claude --resume`. It is cap-gated and
  non-invasive (the window surfaces in the dash without yanking you over), and is
  driven by `bin/dash-restore-session.sh`, which calls the same `resume --exec`.

## 4. Report — keep it short

For a **list**: relay the rows (or "nothing landed yet"). For a **resume**: name
the issue/PR, which mechanism was used (resume-off-SHA vs `--from-pr` vs
review-only), and the worktree it landed in — then hand control to the resumed
session.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` / `$FLEET_MAIN` only — never another
fleet's repo, sessions, or ledger. This skill never merges, force-pushes, or
edits history; it reads the ledger and, on resume, recreates a **throwaway**
worktree at an already-merged SHA (landed rows) or reuses the surviving worktree
(closed-unlanded rows). The ledger has two writers — the cleanup daemon (or the
steward's manual reap op) records **landed** rows at reap time, and the
ledger-watch daemon records **closed-unlanded** rows when a worker window vanishes
(#320); this skill only reads and acts on them.
