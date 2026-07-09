# Fleet commands — the repo-shipped `/skill` contract

This directory holds **fleet skills**: Claude Code slash commands, shipped with
the repo, that operate on a fleet (a tmux session ↔ one GitHub repo). They are
the fleet-aware cousins of your personal `~/.claude/commands/` skills
(`/sweep`, `/new-issue`, …) — optional quality-of-life helpers a fleet operator
runs from inside a session.

They are **installed by copying** `commands/*.md` into the Claude Code user
commands dir (`~/.claude/commands/`), appended alongside — never clobbering —
any personal commands you already have. See the install step in
[`CLAUDE.md`](../CLAUDE.md).

> Phase 0 landed **just the contract** — this README and
> [`_template.md`](_template.md); the functional skills (`/claim`, `/ship`,
> `/land`, …) land one per sub-issue, each cloning the template and filling in
> its body. See **Shipped skills** below for what's live so far.

## Shipped skills

| Skill | Owner | What it does |
|---|---|---|
| [`/merge-train`](merge-train.md) | steward | Serial single-writer "merge train": merges a batch of green, auto-merge-armed PRs one at a time (update-branch → wait green → merge → next), ejecting any that can't land. A client-side stand-in for a merge queue under `strict:true` branch protection. Backed by [`bin/merge-train.sh`](../bin/merge-train.sh). |

## The contract every fleet skill follows

A fleet skill is a markdown playbook (a header + a numbered body, exactly like
`sweep.md` / `new-issue.md`). Two rules make it *fleet-aware*:

### 1. It opens with the resolve-and-guard preamble (step 0)

Every skill's first step resolves **which fleet** it is running in and **which
seat** the caller occupies, then refuses early if either is wrong. Copy this
verbatim from [`_template.md`](_template.md):

```sh
source ~/.claude/fleet/bin/fleet-lib.sh
S=$(fleet_current_session); fleet_load_conf "$S"   # → FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH
SEAT=$(fleet_seat)                                 # → worker | steward | "" (ambiguous)
echo "repo=${FLEET_REPO:-} main=${FLEET_MAIN:-} base=${FLEET_BASE_BRANCH:-master} seat=${SEAT:-unknown}"
```

- **No fleet** (`FLEET_REPO` empty) → **abort** in one line. Never guess a repo.
- Capture the printed values: env vars do **not** persist across separate Bash
  tool calls, so read them back from the `echo` and reuse the literals.
- Everything after step 0 operates on the resolved `$FLEET_REPO` / `$FLEET_MAIN`
  / `$FLEET_BASE_BRANCH` only — never another fleet's.

### 2. It declares an `owner:` seat and enforces it

The two seats a fleet skill can run from (`fleet_seat` prints these):

| Seat | How it's detected | Who it is |
|---|---|---|
| `worker`  | the current tmux window has `@issue` set **and** cwd is inside an `issue-<N>` git worktree | a session bound to one issue, implementing it |
| `steward` | no `@issue` on the window **and** cwd is the fleet base checkout (`$FLEET_MAIN`) | the hub session that triages/backlogs, doesn't implement |
| `""`      | neither (a stray shell, or cwd somewhere else) | ambiguous — treat as wrong-seat |

Each skill declares which seat(s) it belongs to, on its marker line (see below):

- `owner: worker`  — only a worker may run it (e.g. `/ship` a branch).
- `owner: steward` — only the steward may run it (e.g. `/new-issue`, `/sweep`).
- `owner: either`  — seat-agnostic.

If `$SEAT` doesn't match a non-`either` `owner`, the skill **refuses in one
line and stops** — e.g. *"/ship is worker-only; you're in the steward seat."*
Never proceed from the wrong seat.

### 3. It carries the `fleet skill` marker

Just under the `#` title line, every fleet skill carries an HTML comment
declaring the contract and the owner seat:

```
<!-- fleet skill · owner: worker|steward|either -->
```

This marker is how tooling recognises a fleet skill among your personal
commands: `bin/fleet-doctor.sh` scans the head of each `~/.claude/commands/*.md`
for `fleet skill · owner:` to report how many are installed. Keep it near the
top (within the first few lines) so the scan finds it.

## `fleet-lib.sh` helpers a skill may use

Already exposed (all cheap, `set -u`-safe — see `bin/fleet-lib.sh`):

- `fleet_current_session` — the tmux session the caller runs in.
- `fleet_load_conf "$S"` — overlay that fleet's conf (sets `FLEET_REPO` etc.).
- `fleet_seat` — `worker` / `steward` / `""` (needs `FLEET_MAIN`, so call
  `fleet_load_conf` first).
- `fleet_slug_cached "$S"` — session → filesystem slug from the collector cache.

## Adding a new fleet skill

1. Copy `_template.md` → `commands/<name>.md`.
2. Set the title, the `owner:` on the marker line, and the intent sentence.
3. Fill in the numbered body **after** step 0 (leave the preamble intact).
4. Keep every mutation behind the resolved fleet + seat guard. The base
   checkout is read-only (hook-enforced) — a worker edits inside its
   `issue-<N>` worktree and lands via PR.
