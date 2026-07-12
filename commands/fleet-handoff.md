# /fleet-handoff — hand off across a context boundary, then auto-clear + resume

<!-- fleet skill · owner: either -->

Bridges long-running work across a context-window boundary **inside a fleet
pane**: it writes a full handoff doc (delegating to the operator's base `handoff`
skill), then arms a detached helper that waits for this turn to end, `/clear`s
the pane, and types `/fleet-handoff pickup <doc>` so the emptied session resumes
from the doc — the self-clear the arming session can't do to itself. Runs from
**either** seat. Mutates only local files: a worker commits its doc inside its
own `issue-<N>` worktree; a steward writes a flat charter-adjacent doc. It never
touches branches, PRs, or another fleet.

**Argument** (`$ARGUMENTS`):
- **empty** → **cycle mode** (default): write the doc, then arm the clear+resume.
- **`pickup <path>`** → **pickup mode**: resume from an existing handoff doc. This
  is what the detached helper types into the cleared session; you can also run it
  by hand if an auto-cycle didn't complete.

## 0. Resolve fleet + guard seat (run FIRST, every time)

Env vars do NOT persist across separate Bash tool calls — run this once, then
reuse the literal values it prints:

```sh
source ~/.claude/fleet/bin/fleet-lib.sh
S=$(fleet_current_session); fleet_load_conf "$S"   # → FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH
SEAT=$(fleet_seat)                                 # → worker | steward | "" (ambiguous)
echo "repo=${FLEET_REPO:-} main=${FLEET_MAIN:-} base=${FLEET_BASE_BRANCH:-master} seat=${SEAT:-unknown} session=$S pane=${TMUX_PANE:-none}"
```

- **No fleet** (`FLEET_REPO` empty) → **ABORT** in one line: *"not inside a
  fleet — run this from a fleet session."* Never guess a repo.
- **Seat** — `owner: either`, so both `worker` and `steward` may run it. Only the
  **doc path** differs by seat (below). If `$SEAT` is `""` (ambiguous — a stray
  shell), still refuse: *"/fleet-handoff needs a worker or steward seat."*

Branch on the argument: `pickup <path>` → **§P**; anything else → **§C**.

---

## §C. Cycle mode (no argument) — hand off, then arm the auto-clear

### C1. Write the handoff doc — delegate to the base skill

Run the operator's base skill **`~/.claude/skills/handoff/SKILL.md` HAND-OFF mode
verbatim** — ground truth first (`git status`/`git log`/branch, re-open the
resume point so the NEXT ACTION is exact), the full doc skeleton, the NEXT ACTION
and the dead-ends already ruled out. Do **not** copy its skeleton here — the base
skill is the one source of truth. If that file is absent, say so and **stop**
(nothing to arm around).

**One fleet override — the doc PATH, by seat:**

- **worker** — write `doc/handoff/<slug>.md` **inside your `issue-<N>` worktree**
  and **commit** it (per the base skill; the base checkout is read-only, your
  worktree is not). `<slug>` = short kebab task name.
- **steward** — the steward's cwd is the **hook-enforced read-only base
  checkout**, so do NOT write into it. Use the existing steward-handoff
  convention: `~/.claude/handoff/<session>-<YYYY-MM-DD>.md` (create the dir). No
  commit.

Capture the **absolute** path you wrote — the helper needs it literal:

```sh
# worker: DOC="$(pwd)/doc/handoff/<slug>.md"   (cwd is the worktree)
# steward: DOC="$HOME/.claude/handoff/<session>-<YYYY-MM-DD>.md"
echo "DOC=$DOC"
test -s "$DOC" && echo "doc OK (non-empty)" || echo "DOC MISSING/EMPTY — do not arm"
```

### C2. Arm the detached clear+resume — the LAST tool call of this turn

**Only if the doc verifiably exists and is non-empty.** Never arm around a
missing/empty doc. The helper waits for THIS turn to end (Stop hook →
`@claude_state` leaves `working`) before it touches anything, so arming it as the
final tool call is what lets it clear the pane you're still in:

```sh
nohup ~/.claude/fleet/bin/fleet-handoff-cycle.sh \
  --pane "$TMUX_PANE" --doc "$DOC" >/dev/null 2>&1 &
disown 2>/dev/null || true
```

The helper is fail-safe by construction (see `bin/fleet-handoff-cycle.sh`): it
refuses a double-arm, aborts *without clearing* if the turn never goes idle, and
withholds the pickup keystrokes if it can't confirm a fresh session — every
failure degrades to *"doc written, context not cleared"*, and a manual
`/fleet-handoff pickup <DOC>` always still works. It self-terminates on a hard
≤5-minute timeout (never an immortal orphan).

### C3. End the turn — tell the operator, then stop

Emit exactly one line and **do not call another tool** (a later tool call would
keep `@claude_state` at `working` and stall the helper's wait-idle):

> Handoff written to `<DOC>`. This pane will auto-`/clear` and resume from it in a
> moment — or run `/fleet-handoff pickup <DOC>` yourself.

---

## §P. Pickup mode (`pickup <path>`) — resume from the doc

Run the operator's base skill **`~/.claude/skills/handoff/SKILL.md` PICK-UP mode
verbatim** on the given `<path>`:

1. **Announce the doc on its own line** before reading it:
   `Resuming from \`<path>\` (<date>).`
2. **Read it fully**, then re-establish ground truth — `git status` / `git log`,
   confirm the branch, and verify the doc's "Live state to restore / watch"
   claims still hold (treat the doc as *what was true when written*).
3. **Restate in 3–5 lines**: objective, where things stand, the NEXT ACTION.
4. **Resume from the NEXT ACTION** — don't redo finished work or re-investigate
   ruled-out dead-ends.

This composes cleanly with the steward re-adopt hook: on a `@steward` pane the
`/clear` fires `SessionStart(source=clear)` → `steward-readopt-hook.sh` re-injects
the charter FIRST, then this pickup arrives as the first user turn (identity from
the hook, task state from the doc). No special-casing beyond the doc path.

## N. Report (keep it short)

- **Cycle:** the one line from C3 (doc path + auto-clear notice). Nothing else.
- **Pickup:** the 3–5 line restatement, then get to work.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. The base checkout is read-only (hook-enforced): a worker
edits inside its `issue-<N>` worktree and lands via PR; a steward files/triages
and hands implementation to a worker. The detached helper drives ONLY this pane,
on this fleet's own tmux socket (it inherits `$TMUX` from the arming pane).
