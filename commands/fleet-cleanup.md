# /fleet-cleanup — reap a merged/closed PR's worktree now (don't wait for the daemon)

<!-- fleet skill · owner: steward -->

The **fleet never merges** — `/fleet-ship` arms GitHub auto-merge and GitHub (or a
human on the web, or a collaborator) does the merge. The `com.claude-fleet.cleanup`
daemon then reaps the leftover worktree/window/branch and records the resume ledger
within ~60s. This command is the **manual escape hatch**: run it to clean up a
specific PR *immediately* instead of waiting for the next daemon tick. It drives
the same mechanical, no-merge janitor (`bin/fleet-cleanup.sh`) the daemon drives —
it records the ledger, fast-forwards the base checkout under the shared land lease,
and tears down window → worktree → branch. It **merges nothing and forces nothing**.

**Argument** (`$ARGUMENTS`): a PR number (the merged/closed PR to clean up). A bare
issue number also works — resolve it to its `issue-<N>` PR first.

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
- **Wrong seat** — `/fleet-cleanup` is `owner: steward`. If `$SEAT` isn't
  `steward`, **refuse in one line and stop**, e.g. *"/fleet-cleanup is
  steward-only; you're in the worker seat."* Never proceed from the wrong seat.

Everything below operates on the resolved `$FLEET_REPO` / `$FLEET_MAIN` — this
fleet only.

## 1. Run the mechanical janitor

Hand the PR number to the shared, no-LLM janitor. It streams progress on stderr
and prints exactly ONE result token on stdout — capture that:

```sh
tok=$(FLEET_SESSION="$S" bash ~/.claude/fleet/bin/fleet-cleanup.sh "<PR>")
echo "$tok"
```

Result tokens:

- `cleaned:<sha>` — the PR was MERGED: ledger recorded, base fast-forwarded, and
  the worktree/window/branch reaped. Done.
- `cleaned:closed` — the PR was CLOSED-unmerged: its orphaned worktree/window was
  reaped (no base pull, no ledger — the work was abandoned).
- `skip:not-final` — the PR is still **OPEN** (not merged/closed). Nothing to clean
  yet. If you meant to get it merged, let auto-merge do it (arm it with the dash
  `⌃l` if it wasn't armed at ship time); do NOT merge it by hand here.
- `skip:nothing` — the PR is final but its worktree/window are already gone (the
  daemon or the janitor beat you to it). No-op — safe.
- `error:<reason>` — a precondition failed (no repo/main/gh, or the PR wasn't
  found). Fix the precondition; nothing was changed.

`--dry-run` reports the verdict (`dry:*`) without touching anything.

## 2. Report

One line: the PR number and the result token in plain words (e.g. *"cleaned #123 —
base fast-forwarded, worktree reaped"* or *"#123 is still open — nothing to clean;
auto-merge will land it"*). Never merge a PR from this command — cleanup runs
*after* a merge, never instead of one.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. **The fleet never merges** — this command cleans up after a
merge; if a PR isn't merged yet, arming auto-merge (or a human merging on the web)
is what lands it, not this.
