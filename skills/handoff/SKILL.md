---
name: handoff
description: Bridge a long task across sessions. Invoke when the context window is filling up and you want to continue the SAME work in a fresh session — it writes a complete, self-sufficient handoff document ("hand off", "save state / context", "running low on context", "continue this later / in a new session"). Also invoke at the START of a new session to pick up from one ("resume", "pick up <topic>", "continue the handoff"). Two modes: HAND-OFF (write the doc) and PICK-UP (read it and continue).
---

# Session handoff

<!-- fleet skill -->

Carries long-running work across a context-window boundary so a fresh session continues seamlessly. Two modes — **HAND-OFF** (write a doc) and **PICK-UP** (resume one).

### Decide the mode
Explicit words always win: "hand off / save state / running low on context" → HAND-OFF; "pick up / resume / continue" → PICK-UP. Otherwise infer from the session, and **default to PICK-UP in a fresh session**:
- **Fresh session** — you've done little/no substantial work yet this turn — **AND** a handoff doc exists → **PICK-UP** (resume the most recent one). This is the default at the start of a new session.
- **Deep in a task** — lots already done this session, context filling up → **HAND-OFF** (write the doc).
- **No handoff doc exists anywhere** → can only be HAND-OFF.

State which mode you chose in one line, then proceed. Only ask if genuinely ambiguous (e.g. mid-task *and* a fresh-looking handoff exists).

---

## HAND-OFF mode — write the document

Assume the next session has **zero memory of this one**. Optimize for: *someone resumes from the doc alone and loses nothing.* The hardest-won, highest-value content is the **exact next action** and the **dead-ends already ruled out**.

### 1. Gather ground truth first (don't write from memory)
- `git status`, `git log --oneline -15`, current branch; open PRs (`gh pr list` / `gh pr view`).
- Re-open the actual file/code at the resume point so the NEXT ACTION is exact (file:line, real symbol names).
- List any **live external state you changed** that must be restored or is risky to leave: a feature flag toggled, a service redeployed, test data created, a background process/job left running, creds staged on a box.

### 2. Write the doc
Path: `doc/handoff/<slug>.md` (create the dir; `<slug>` = short kebab task name, e.g. `vote-smoke`). If not a git repo or there's no `doc/`, use `./HANDOFF-<slug>.md`. Keep every section; drop only a section's *body* if truly N/A (write "—").

```
# Handoff: <task> — <YYYY-MM-DD>

## Objective
<the standing goal, precise/verbatim. Why this work exists. Success = ?>

## ▶ NEXT ACTION (start here)
<The single most important next thing, executable WITHOUT guessing:
 the file:line to edit, the exact command to run, the assertion to make.
 If mid-debug: the exact failing symptom + your current hypothesis + the
 fix you were in the middle of applying.>

## Status
| Piece | State | Notes |
|---|---|---|
| <subtask> | ✅ done&verified / 🔶 in-progress / ⛔ blocked | <how verified / what's left> |

## How to operate (env · access · commands)
<How to actually run and verify: hosts/boxes, where creds come from, the
 dev→deploy→verify loop, the exact commands. Anything non-obvious about
 the setup a newcomer would stumble on.>

## Findings & decisions (do NOT re-derive)
<What's proven true; what's safe vs UNSAFE; dead-ends already tried and
 WHY they fail; key contract facts (endpoints, params, file:line, schema).
 This is what stops the next session from repeating hours of investigation.>

## Live state to restore / watch
<External state THIS session changed: flags toggled, deploys, seeded test
 data, staged creds, running jobs. What to revert; what's safe to leave.>

## Artifacts
- Branch: … | PR(s): … | Key files: … | This doc: <path>
- Notable commits: <sha — one line each>

## Open questions / pending decisions
<Anything needing a human call or still undecided.>
```

### 3. Commit + hand the user the resume line
- If in a git repo: `git add <doc>` and commit (do **not** push unless asked). End the commit message with the repo's required co-author/footer if it has one.
- Output, verbatim, the line to paste into the new session, plus a 2-line "where we stand":

  ```
  Resume in a new session with:
      /handoff pick up doc/handoff/<slug>.md
  ```

---

## PICK-UP mode — resume from a document

1. **Locate the handoff — never guess silently:**
   - If the user named a path, use it.
   - Otherwise list candidates newest-first with their titles:
     `for f in $(ls -t doc/handoff/*.md ./HANDOFF-*.md 2>/dev/null); do printf '%s\t%s\n' "$f" "$(head -1 "$f")"; done`
     - **Zero found** → say so; offer to HAND-OFF instead, or ask for the path.
     - **Exactly one**, or one **clearly newest** (others much older / obviously a different task) → use it.
     - **Several recent / plausibly relevant** → do NOT pick for them: show the list (path + title + date) and ask which to resume.
   - **Always announce the chosen doc before reading it**, on its own line:
     `Resuming from \`<path>\` (<date>).` — so the user can redirect if it's the wrong one.
2. **Read it fully**, then re-establish ground truth: `git status` / `git log`, confirm the branch, and **verify the "Live state to restore / watch" claims still hold** (a flag it says is off → confirm; a file/symbol it cites → confirm it still exists). Treat the doc as *what was true when written*, not gospel.
3. **Restate in 3–5 lines**: the objective, where things stand, and the NEXT ACTION you're about to take.
4. **Resume from the NEXT ACTION.** Don't redo finished/verified work; don't re-investigate ruled-out dead-ends; honor the "safe vs unsafe" findings.

---

## Quality bar
- The NEXT ACTION must be executable without guessing — exact file:line / command / expected result.
- Findings MUST include the **dead-ends and why** (what NOT to try) — these are the most valuable lines.
- Prefer exact paths, commands, and `file:line` over prose.
- Thoroughness scales with depth: a shallow task needs a short doc; a multi-day debug needs the full skeleton.
- Never invent state — if you didn't verify it this turn, say "unverified" rather than asserting it.
