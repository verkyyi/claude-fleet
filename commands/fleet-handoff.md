# /fleet-handoff — hand off across a context boundary, then auto-clear + resume

<!-- fleet skill · owner: either -->

Bridges long-running work across a context-window boundary **inside a fleet
pane**: it stores a full handoff doc (delegating to the operator's base `handoff`
skill), then arms a detached helper that waits for this turn to end, `/clear`s
the pane, and types `/fleet-handoff pickup` so the emptied session resumes from
the handoff — the self-clear the arming session can't do to itself. Runs from
**either** seat. When the pane is **issue-bound** the handoff is stored as a
durable `<!-- fleet:handoff -->`-marked **issue comment** (issue #275) — it
outlives the worktree teardown a committed doc does not, and pickup self-resolves
it from the pane's `@issue`; a raw/no-issue pane falls back to a local file
(`FLEET_HANDOFF_DEST=file` forces file-only for a sensitive repo). It mutates only
the bound issue (one comment) and local files, and never touches branches, PRs, or
another fleet.

**Argument** (`$ARGUMENTS`):
- **empty** → **cycle mode** (default): store the handoff, then arm the clear+resume.
- **`pickup [<source>]`** → **pickup mode**: resume from an existing handoff. The
  `<source>` is OPTIONAL (a file path, comment URL, or issue number) — omitted, it
  self-resolves from the pane's `@issue` (§P). This is what the detached helper
  types into the cleared session; you can also run it by hand if an auto-cycle
  didn't complete.

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

### C1. Compose the handoff doc — delegate to the base skill

Run the operator's base skill **`~/.claude/skills/handoff/SKILL.md` HAND-OFF mode
verbatim** — ground truth first (`git status`/`git log`/branch, re-open the
resume point so the NEXT ACTION is exact), the full doc skeleton, the NEXT ACTION
and the dead-ends already ruled out. Do **not** copy its skeleton here — the base
skill is the one source of truth. If that file is absent, say so and **stop**
(nothing to arm around).

Hold the composed doc text; **where** it is stored is C2's job.

### C2. Store the handoff durably — comment when issue-bound, else file

The handoff must land somewhere a *cleared* session can recover it. Resolve the
destination once, store it, and **verify** before arming anything.

**Resolve the destination.** Read the knob + this pane's binding:

```sh
DEST="${FLEET_HANDOFF_DEST:-comment}"                                  # comment (default) | file
ISSUE=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@issue}' 2>/dev/null | tr -dc 0-9)
# a steward pane has no @issue; its bound thread is the fleet control issue:
[ -z "$ISSUE" ] && [ "$SEAT" = steward ] && ISSUE="${FLEET_STEWARD_ISSUE//[^0-9]/}"
echo "dest=$DEST issue=${ISSUE:-none} seat=$SEAT"
```

Then take the FIRST matching case:

1. **`DEST=comment` AND `$ISSUE` non-empty** → **COMMENT storage** (the primary
   case — a worker's `@issue`, or a steward's `FLEET_STEWARD_ISSUE`). Post the
   SCRUBBED doc (see the scrub rule below) as a comment carrying the pickup marker
   `<!-- fleet:handoff -->`, via `bin/fleet-comment.sh --note` so it also gets the
   `<!-- fleet:no-relay -->` marker (the issue-bridge must NOT relay a handoff back
   into the worker as a turn) and the per-role footer:

   ```sh
   # $SCRUBBED = the doc text with the scrub rule applied; the marker makes pickup find it.
   printf '%s\n\n%s\n' "$SCRUBBED" '<!-- fleet:handoff -->' \
     | ~/.claude/fleet/bin/fleet-comment.sh "$ISSUE" --repo "$FLEET_REPO" --note
   ```

   The command prints the created comment URL on success. **If it fails / prints
   no URL, DO NOT arm comment-mode** — fall through to file storage (case 3) so the
   handoff is never lost.

2. **`DEST=comment` but the pane is NOT issue-bound** (raw scratch / no `@issue` /
   steward without `FLEET_STEWARD_ISSUE`) → **file storage** (case 3). Comment mode
   needs a thread to post to; without one, fall back to a local file.

3. **`DEST=file`, OR any fall-through from above** → **FILE storage** (the prior
   behavior). The path is by seat:
   - **worker** — write `doc/handoff/<slug>.md` **inside your `issue-<N>`
     worktree** and **commit** it (the base checkout is read-only, your worktree is
     not). `<slug>` = short kebab task name. `DOC="$(pwd)/doc/handoff/<slug>.md"`.
   - **steward / raw** — the cwd is the hook-enforced read-only base checkout, so
     do NOT write into it. Use the flat convention
     `~/.claude/handoff/<session>-<YYYY-MM-DD>.md` (create the dir). No commit.

   ```sh
   echo "DOC=$DOC"
   test -s "$DOC" && echo "doc OK (non-empty)" || echo "DOC MISSING/EMPTY — do not arm"
   ```

> **PUBLIC-repo scrub — a HARD rule for COMMENT storage (this repo is public).**
> A handoff comment is world-readable, so before posting scrub the base skeleton's
> "How to operate" / "Live state" / environment sections: **NO credential values
> or their locations, NO internal hostnames (including tailnet names like
> `*.ts.net`), and prefer repo-relative paths** over absolute machine paths. Any
> line you cannot safely scrub does NOT go in the comment — keep it in the local
> **file fallback** instead and have the comment link it as `(local: <path>)`. This
> scrub applies to comment storage only; a private local file needs no scrub.

### C3. Arm the detached clear+resume — the LAST tool call of this turn

**Only if the handoff is verifiably stored** (a posted comment URL, or a non-empty
DOC). Never arm around a missing store. The helper waits for THIS turn to end
(Stop hook → `@claude_state` leaves `working`) before it touches anything, so
arming it as the final tool call is what lets it clear the pane you're still in.
Arm with the mode that matches how you stored it:

```sh
# COMMENT storage — the helper re-confirms the marked comment on the issue, then
# injects an ARGUMENT-FREE pickup (the cleared pane's @issue self-resolves it):
nohup ~/.claude/fleet/bin/fleet-handoff-cycle.sh \
  --pane "$TMUX_PANE" --issue "$ISSUE" --repo "$FLEET_REPO" >/dev/null 2>&1 &
disown 2>/dev/null || true

# FILE storage — the helper gates on the doc + injects `pickup <DOC>`:
nohup ~/.claude/fleet/bin/fleet-handoff-cycle.sh \
  --pane "$TMUX_PANE" --doc "$DOC" >/dev/null 2>&1 &
disown 2>/dev/null || true
```

The helper is fail-safe by construction (see `bin/fleet-handoff-cycle.sh`): it
re-validates the store (marked comment fetchable, or doc non-empty) BEFORE the
first keystroke, refuses a double-arm, aborts *without clearing* if the turn never
goes idle, and withholds the pickup keystrokes if it can't confirm a fresh
session — every failure degrades to *"handoff stored, context not cleared"*, and a
manual `/fleet-handoff pickup` always still works. It self-terminates on a hard
≤5-minute timeout (never an immortal orphan).

### C4. End the turn — tell the operator, then stop

Emit exactly one line and **do not call another tool** (a later tool call would
keep `@claude_state` at `working` and stall the helper's wait-idle):

> Handoff stored (comment on #`<ISSUE>` / `<DOC>`). This pane will auto-`/clear`
> and resume from it in a moment — or run `/fleet-handoff pickup` yourself.

---

## §P. Pickup mode (`pickup [<source>]`) — resume from the handoff

The argument is **optional** (the auto-cycle injects it bare). Resolve the
handoff SOURCE in this order and **announce the chosen source on its own line**
before reading it:

1. **Explicit `<source>` argument** — a local file path, a comment URL, or a bare
   issue number. Use it directly.
2. **Newest `<!-- fleet:handoff -->`-marked comment** on this pane's `@issue`
   (then, for a `@steward` pane, `FLEET_STEWARD_ISSUE`). This is what an
   argument-free pickup resolves to after a comment-mode cycle:

   ```sh
   ISSUE=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@issue}' 2>/dev/null | tr -dc 0-9)
   [ -z "$ISSUE" ] && [ "$SEAT" = steward ] && ISSUE="${FLEET_STEWARD_ISSUE//[^0-9]/}"
   # newest comment carrying the handoff marker:
   gh issue view "$ISSUE" --repo "$FLEET_REPO" --json comments \
     -q 'last(.comments[] | select(.body | contains("<!-- fleet:handoff -->"))) | .body'
   ```
3. **File-fallback search** — the newest `~/.claude/handoff/<session>-*.md` (or the
   worktree's `doc/handoff/*.md`), the prior behavior, when neither above resolves.

Then run the operator's base skill **`~/.claude/skills/handoff/SKILL.md` PICK-UP
mode verbatim** on the resolved source:

1. **Announce the source on its own line** before reading it:
   `Resuming from <source> (<date>).`
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
