# /fleet-history — browse & resume closed sessions (landed + unlanded + scratch)

<!-- fleet skill · owner: hub -->

When the cleanup daemon (or a manual reap from the hub) reaps a merged worker's
PR it removes the `issue-<N>` worktree and kills the window — but the worker's Claude transcript
**survives** under
`~/.claude/projects/`. This skill surfaces those finished sessions from the
history ledger (`bin/fleet-history.sh`): **list** what closed, **open**
a PR, **review** the recorded transcript, and — the point — **resume** a session.
Both kinds of session are in there: issue-bound **workers** and `@raw` **scratch**
sessions (#466), which have their own worktree + transcript since #290 and so
browse and resume the same way.
It reads the ledger and may recreate a worktree in the fleet's base checkout
(`$FLEET_MAIN`); it never merges or mutates `$FLEET_REPO`. Browsing *finished*
sessions is an operator concern — a live worker lands its own PR and has no reason
to trawl the ledger — so this skill runs from the **hub pane**, never a worker.

Two ROW STATES live in the ledger (the `state` column, #320, distinguishes them
— `✓` vs `✗` in the list):
- **landed** (`✓`) — recorded on the land path when a merged PR was reaped:
  carries a PR + squash SHA, so resume reconstructs the removed worktree off the SHA.
- **closed-unlanded** (`✗`) — recorded when a session's window VANISHED without
  landing (closed by hand, crashed, abandoned/blocked) — by the ledger-watch daemon
  (`com.claude-fleet.ledger-watch`), the SessionEnd hook at the moment of exit, the
  dash ⌃x reaper, or the worktree janitor. No PR — but it carries the worktree's
  **HEAD SHA**, and its worktree usually **still exists on disk**
  (worktree-autoclean keeps unmerged/dirty), so resume **reuses it**, or rebuilds
  it off that SHA once a reaper has removed it.

And two KINDS of session, told apart by the **key column**:
- **worker** — `#<issue>`: an issue-bound session. Keyed by its issue number.
- **scratch** — `~<N>`: an `@raw` scratch session (#466). It has no GitHub issue,
  so it is keyed by its `scratch-<N>` slug — the name of both its branch and its
  worktree. Resume by that key (`resume scratch-3`), and the restored window comes
  back marked `@raw` + `@worktree` rather than bound to an issue it never had.

**Argument** (`$ARGUMENTS`): optional.
- empty → list recent closed sessions (newest first, landed + unlanded, workers +
  scratch).
- a word → list, filtered to rows matching that substring (issue #, title, PR,
  `scratch`…).
- `resume <issue|scratch-<N>|#PR>` → resume that session, landed or unlanded (see step 3).

## 0. Resolve fleet + guard seat (run FIRST, every time)

Env vars do NOT persist across separate Bash tool calls — run this once, then
reuse the literal values it prints:

```sh
source ~/.claude/fleet/bin/fleet-lib.sh
S=$(fleet_current_session); fleet_load_conf "$S"   # → FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH
SEAT=$(fleet_seat)                                 # → worker | "" (the hub pane / a stray shell)
echo "repo=${FLEET_REPO:-} main=${FLEET_MAIN:-} base=${FLEET_BASE_BRANCH:-master} seat=${SEAT:-unknown}"
```

- **No fleet** (`FLEET_REPO` empty) → **ABORT** in one line: *"not inside a
  fleet — run this from a fleet session."* Never guess a repo.
- **Wrong seat** — this skill is `owner: hub`. If `$SEAT` IS `worker`,
  **refuse in one line and stop**, e.g. *"/fleet-history runs from the hub pane;
  you're in a worker seat."*

Everything below operates on the resolved `$FLEET_REPO` / `$FLEET_MAIN` — this
fleet only.

## 1. List closed sessions

```sh
bash ~/.claude/fleet/bin/fleet-history.sh list --repo "$FLEET_REPO" $ARGUMENTS
```

Each row is `glyph · key · when · title · PR · sha · one-line-summary`,
newest first — the glyph is `✓` (landed) or `✗` (closed-unlanded, #320), the key is
`#<issue>` for a worker or `~<N>` for a scratch (#466), and
`when` is a friendly relative span (`2 hours`, `3 days`), not a raw timestamp
(issue #228). A closed-unlanded row has no PR (`-`). If the ledger is
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
  read -r tdir sid < <(bash ~/.claude/fleet/bin/fleet-history.sh path --repo "$FLEET_REPO" <issue|scratch-N|#PR>)
  [ -n "$sid" ] && ${PAGER:-less} "$tdir/$sid.jsonl"
  ```

- **Resume** — step 3.

## 3. Resume a session

Resume needs a worktree to run in. For a **landed** row the land cleanup removed
it, so the helper **reconstructs** it off the recorded squash SHA (the branch is
usually deleted post-merge, so it uses the SHA, not the branch). For a
**closed-unlanded** row (#320) the worktree usually **still exists on disk**
(worktree-autoclean keeps unmerged/dirty), so the helper just **reuses it**; if a
reaper already removed it, the HEAD SHA recorded at close time (#466) rebuilds it
at the same path. Scratch rows resume through exactly this path — that recorded SHA
is what makes a silently-pruned clean scratch resumable at all. Either way it prints
how to resume:

```sh
bash ~/.claude/fleet/bin/fleet-history.sh resume --exec \
  --repo "$FLEET_REPO" --main "$FLEET_MAIN" <issue|scratch-N|#PR>
```

It prints ONE verdict line — act on it:

| Verdict | Meaning | What you do |
|---|---|---|
| `RESUME⇥<worktree>⇥<session-id>⇥<cmd>` | worktree present (reused when it survived, or recreated off the recorded SHA); transcript present | `cd <worktree>` and run the printed `claude --resume <id> --fork-session` |
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
- **Scratch resume** rebuilds a `scratch-<N>` worktree the same way and opens it
  marked `@raw` — so the fleet keeps treating it as an experiment (reapers skip it;
  dash ⌃x disposes of it; the janitor never silently deletes it while dirty).
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
the issue/scratch/PR, which mechanism was used (resume-off-SHA vs `--from-pr` vs
review-only), and the worktree it landed in — then hand control to the resumed
session.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` / `$FLEET_MAIN` only — never another
fleet's repo, sessions, or ledger. This skill never merges, force-pushes, or
edits history; it reads the ledger and, on resume, recreates a **throwaway**
worktree at an already-merged SHA (landed rows) or reuses the surviving worktree
(closed-unlanded rows). The ledger's writers are the reapers themselves — the cleanup daemon and the
worktree janitor record **landed** rows at reap time; the ledger-watch daemon, the
SessionEnd hook and the dash ⌃x reaper record **closed-unlanded** rows when a window
vanishes (#320, #403, #466). All of them go through one idempotent helper, so a
session is recorded once whichever reaper gets there first; this skill only reads
and acts on them.
