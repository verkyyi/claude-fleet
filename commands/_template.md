# /NAME — one-line description of what this skill does

<!-- fleet skill · owner: worker|steward|either -->

<!--
  This is the fleet-skill TEMPLATE. To add a skill: copy me to commands/NAME.md,
  then (a) set the title above, (b) pick ONE owner on the marker line — delete
  the other choices, leaving e.g. `owner: worker`, (c) write the intent below,
  (d) fill in the numbered body AFTER step 0. Leave step 0 verbatim.
  See README.md for the full contract. Delete this comment in your copy.
-->

Two sentences: what this does and for which seat. Say plainly whether it mutates
anything (issues, branches, PRs) and on whose repo — the fleet's own, never
another's.

**Argument** (`$ARGUMENTS`): describe it, or say "none — takes no argument."
If required and empty, ask the user and stop.

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
- **Wrong seat** — this skill's `owner` is the one on the marker line above. If
  it isn't `either` and `$SEAT` doesn't match, **refuse in one line and stop**,
  e.g. *"/NAME is worker-only; you're in the steward seat."* Never proceed from
  the wrong seat.

Everything below operates on the resolved `$FLEET_REPO` / `$FLEET_MAIN` /
`$FLEET_BASE_BRANCH` — this fleet only.

## 1. First real step

Replace with the skill's actual playbook. Run `gh` / `git` against
`$FLEET_REPO` / `$FLEET_MAIN`.

## 2. …more steps as needed

## N. Report (keep it short)

One line on what changed or what needs the user. If this runs on a timer or a
hook, surface only what changed.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. The base checkout is read-only (hook-enforced): a worker
edits inside its `issue-<N>` worktree and lands via PR; a steward files/triages
and hands implementation to a worker.
