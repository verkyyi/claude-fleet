# /fleet-claim — the worker lifecycle: claim → charter → ground → work → ship

<!-- fleet skill · owner: worker -->

The one skill a freshly-spawned worker runs. It formalizes the whole worker
lifecycle that the seed prompt used to spell out across three skills: **claim**
the bound issue, **load your charter**, **ground** yourself in the issue + code,
then implement under a **standing contract** that ends by **opening a PR, landing
it yourself once the gate is green, and reporting the outcome back to whoever
spawned you** — and signals a blocker loudly rather than stalling. Mutates the bound issue on this fleet's `$FLEET_REPO` (an assignee
at claim time; issue comments as you go) — and, for adjacent work it spots, MAY
file a *new* tracked issue through the one filer channel, and spawn a worker for
it — then, at ship, pushes your branch, opens a PR, and merges it when the checks
go green. It never touches the base checkout.

**You are a full agent, not a deckhand** (issue #441). The rails below are safety
rails — the read-only base checkout, the one filer channel, bridge-only messaging,
branch protection — and they are absolute. Everything *else* is your call: how to
implement it, when it's done, whether a follow-up is worth a worker now, and when
to land. Nothing in this fleet is waiting to approve your work.

**Argument** (`$ARGUMENTS`): none — the seed is a bare `/fleet-claim`, so the
issue is self-discovered from the window's `@issue` binding (fallback: the
`issue-<N>` worktree name), never an argument.

## 0. Resolve fleet + guard seat + read the issue — ONE call (run FIRST)

Everything the preamble used to take four steps and ~13 turns to assemble comes
out of a single command (issue #458). One shell, one `gh` round-trip, one atomic
block — so no piece of it can be half-run, and "env vars don't persist between
Bash calls" stops mattering:

```sh
~/.claude/fleet/bin/fleet-claim-brief.sh
```

It prints, in order: the **fleet** (session / repo / base branch / read-only base
checkout / merge method / seat), the **issue** it resolved from your window's
`@issue` binding — falling back to the `issue-<N>` worktree in cwd for a window
that lost the binding — with its title, state, labels, **assignees**, body and
every comment; the **claim** verdict; your **charter layers**; and this fleet's
**implementation directive**. It also prints an **`origin:`** line — who spawned
you (issue #574). When it names a window key rather than `none`, a live session is
waiting on this issue's outcome, and reporting back to it is the last step of the
ship sequence below.

Act on the exit code — these are the rails, one code each, each printed on stderr:

- **0** — worker seat, fleet resolved, issue read. Everything you need is in the
  brief; go.
- **2 `ABORT`** — not inside a fleet. Say so in one line and stop. Never guess a repo.
- **3 `REFUSE`** — wrong seat: `/fleet-claim` is worker-only and you're in the hub
  pane or a stray shell. Refuse in one line and stop.
- **4 `FAIL`** — no issue bound (no `@issue`, and cwd isn't an `issue-<N>`
  worktree). Say so in one line and stop. Never guess a number.
- **5** — the fleet + charter half printed, but the `gh` read failed (gh missing /
  auth / no such issue). Fix or report that; never implement off a half-read issue.

Two lines in the brief want something from you:

- **`claim:`** — the assignee IS the claim (issue #283), and the spawn already
  pre-claimed the issue for you, so this normally reads `HELD` ⇒ **do nothing,
  never re-assign**. On the rare `UNCLAIMED`, run the exact
  `gh issue edit … --add-assignee @me` the brief prints.
- **the charter layers** — the built-in contract (step 2 below) is the base; the
  gated repo charter (`$FLEET_MAIN/.fleet/worker.md`, printed only when the fleet
  sets `FLEET_REPO_CHARTER=1` — it's an injection surface, so it's fail-closed)
  and the operator's always-trusted fleet overlay
  (`~/.config/claude-fleet/fleets/<session>/worker.md`) print **low→high
  precedence**: a later layer wins where it conflicts with an earlier one. Fold
  whatever printed into how you work. Nothing printed = the built-in contract,
  which is the historic default.

Everything below operates on the repo the brief resolved — this fleet only. (If
the brief is missing, on an install predating issue #458, do it by hand:
`source ~/.claude/fleet/bin/fleet-lib.sh`, then `fleet_load_conf
"$(fleet_current_session)"`, `fleet_seat`, `gh issue view`,
`fleet_worker_charter`, `fleet_worker_prompt_body`.)

## 1. Ground yourself, then implement

Read what you need — the full issue thread the brief printed (design comments
included) and the code the change touches — then implement. You decide the
approach; the rails and the finish line are below. The brief's **implementation
directive** section is the operator's per-fleet HOW-to guidance (issue #234;
default *"Implement and verify per the repo conventions"*) — fold it in.

### Ground cheaply — keep the broad sweep out of the main context

Grounding is the most expensive phase of a worker session by an order of
magnitude: across the 10 real worker sessions on this repo it cost a median 53k
output tokens against the preamble's 4.9k, and the first file write landed with
91k of context already loaded (issue #460). That is context spent before any
work exists, so the window fills sooner and `/fleet-handoff` fires earlier — and
a handoff is itself expensive, since the fresh session re-grounds from a doc.

Three habits buy most of it back:

- **Delegate the broad sweep — to a READ-ONLY subagent.** "Which files touch
  X, and where" is a fan-out search — hand it to the `Explore` subagent and you
  get back the conclusion instead of every file it read on the way. Keep the
  main window for the code you are actually changing. `Explore`, `Plan` and
  `claude-code-guide` are the only subagent types a fleet pane can start:
  `hooks/agent-guard.py` blocks `general-purpose`, `claude`, `fork`, an
  unnamed type and any `isolation: worktree` (issue #811). A writing subagent
  runs outside every fleet rail — invisible to the dash, no state, killed
  mid-edit when the quota migration moves the *window*, several writing one
  worktree, no one-worker-one-PR, no history row, no handoff — so work that
  writes code is a WORKER: `fleet-issue-file.sh --parent N --spawn` below, and
  its `[child-report]` is how the result comes back — and
  `~/.claude/fleet/bin/fleet-children.sh` is where you read all of them at once.
  Need the result BEFORE you can go on, the way a subagent would hand it back?
  `~/.claude/fleet/bin/fleet-await.sh <N>` (with `run_in_background: true`)
  spawns #N's worker if none is live and blocks until it lands, blocks or is
  reaped, then prints the verdict + PR + summary (issue #812).
- **Don't dump a whole file to answer a narrow question.** A `grep -n` for the
  symbol plus a targeted `sed -n '<a>,<b>p'` range costs a fraction of a full
  `cat -n` — read the function, not the file that contains it.
- **Ground from the diff, not the tree.** For a fix that builds on prior work,
  `git log -p --follow <file>` (or `git log -S '<symbol>'`) is usually smaller
  and far more informative than reading every caller.

Judgment, not a mandate: **you are a full agent, not a deckhand** (issue #441) —
what to read is your call, and *under*-grounding ships the wrong change, which
costs more than any dump. This steers HOW you load context, not how much you are
allowed to know.

### Before you touch code: the 「改动前」 capture

Read the issue body's **`上线证据:`** line — `~/.claude/fleet/bin/fleet-evidence.sh line`
prints it (`/fleet-epic-plan` writes one per EPIC member, issue #809: which URL to
screenshot, which command's output, which pane to capture). It names what the
EPIC report will show side by side as 改动前 / 改动后 / 已上线 — so take the
**before** now, along that line, while the change does not exist yet; a "before"
taken later is fiction (issue #810):

```sh
~/.claude/fleet/bin/fleet-evidence.sh before --note '一句话：这是什么' <file>   # `-` = a command's output on stdin · `--pane <t>` = a TUI
```

No such line (exit 1)? Your judgment — at minimum one after-image or one output
of the changed thing at ship time (step 4 below). It lands in
`$FLEET_CONF_DIR/fleets/<sess>/epic/<E>/evidence/<M>/` when the issue has an EPIC
parent (GitHub's link, resolved for you), else `…/fleets/<sess>/evidence/<M>/`,
named `<stage>-<UTC>-<name>`, and is never committed to the repo. A playwright-MCP
screenshot lands under the worktree (`.playwright-mcp/`): pass `--mv` so the ship
step's `git status --porcelain` stays empty.

## 2. The standing contract (built-in charter — the base layer)

Implement under these invariants (a charter layer from the brief may extend or
override them):

- **Work only in this worktree.** You are in the `issue-<N>` git worktree off
  `$FLEET_BASE_BRANCH`; never commit to or edit the base checkout (it's
  hook-enforced read-only). Converse with the operator/collaborators by
  **commenting on the bound issue** (via
  `~/.claude/fleet/bin/fleet-comment.sh "<issue>" --repo "$FLEET_REPO" --note --body '…'`
  so it carries the no-relay marker + worker footer). ⚠️ **`--note` is the DEFAULT
  and it is RECORD-ONLY — a bare `fleet-comment.sh` posts something the target
  worker will NEVER see, while printing a URL and exiting 0.** To actually reach
  another worker, pick a channel: **SendMessage** for a pure instruction (direct
  to that worker's session, immediate, returns a delivery receipt — preferred),
  or `fleet-comment.sh --to-worker` when the instruction also belongs in the
  issue record. Since #489 the wrapper prints which of the two happened on
  stderr, and warns when you post record-only to an issue that has a live
  worker — read that line instead of assuming delivery. NEVER drive
  another agent's pane with `tmux send-keys` — it's racy (bracketed-paste swallows
  the Enter) and is hook-blocked (#437). The bridge relays your comment as the
  target's next clean turn; `FLEET_ALLOW_SENDKEYS=1` is the sanctioned override,
  for fleet plumbing only. An **isolated** test socket (`tmux -S /tmp/x.sock`, or
  `-L <label>` owning no fleet conf) is not a pane and is not guarded — drive it
  freely when testing tmux tooling. Reaching for `gh issue comment` needs no
  ceremony either: the guard rewrites it onto the wrapper for you and lets the
  rest of your command run (#528). Closing the issue with a final comment (a
  research/no-PR task) goes through the same wrapper —
  `fleet-comment.sh "<issue>" --repo "$FLEET_REPO" --close --body '…'` — never a
  bare `gh issue close --comment`: that posts an UNMARKED comment the bridge
  relays straight back into your own pane as a turn (issue #486).
- **Spot adjacent work? File it — and spawn it if it's worth doing now.** File
  through the ONE filer channel (issue #332), so a follow-up you notice lands on
  the backlog instead of scope-creeping this PR — and the base checkout stays
  untouched:
  `~/.claude/fleet/bin/fleet-issue-file.sh --title "<title>" [--body "<brief>"] [--spawn]`.
  **Related to your current issue N → add `--parent N`** — it files a GitHub
  *sub-issue* linked under N; **unrelated → file top-level** (omit `--parent`).
  A sub-issue is an ordinary issue — its own number, `@issue`, and `issue-<num>`
  worktree/branch — plus GitHub's parent pointer, so the claim / worktree /
  ledger flow is unchanged.
  **`--bind` is the SCRATCH escalation** (issue #520), and it is not for you: a
  worker is already bound, so `--bind` refuses here. It belongs to a scratch
  session (dash ⌃s) that has talked its way to a clear requirement — filing with
  `--bind` makes *that* session the new issue's worker in place, rather than
  spawning one that must re-ground from zero.
  **`--spawn` is yours to use** (issue #441): it hands the new number to the same
  spawn choke point the hub uses, so the session caps + cross-machine pre-spawn
  dedup still apply and a cap refusal just leaves the issue filed. Spawn when the
  follow-up is genuinely independent and worth a worker *now*; otherwise file it
  bare and let it sit on the backlog. What stays fixed either way: **don't chase
  it in THIS worktree** — one worktree, one issue, one PR. A spawned worker
  claims and ships it on its own, and **pushes a `[child-report]` back to you**
  when it does (issue #574) — so don't poll for it. Every report is also written
  to your **children ledger** (issue #937), so the whole picture is one command
  away: `~/.claude/fleet/bin/fleet-children.sh` (`--json` for a script) prints one
  line per child — its ledger outcome, live window state and PR — plus a
  `3/5 ✓ · 1!` summary. See the acknowledge-don't-take-over rule below for what to
  do when one arrives.
- **Hand off before you run out of context.** When the window fills, run
  `/fleet-handoff` — it writes a durable handoff and cycles the pane. You can't
  see your own context meter (Claude Code shows it to the human, not the model),
  so when you're unsure whether there's room for one more expensive sweep, **ask**
  — `/fleet-context`, or its one-line read
  `~/.claude/fleet/bin/fleet-context.sh` (issue #464). It prints a verdict on the
  same bands the auto-handoff nudge uses: `WATCH` means finish this thread and
  hand off rather than starting a broad sweep, `HANDOFF` means do it now.
- **Done = ship it AND land it.** You own the change end to end — nobody is
  queued up to merge it for you (issue #441). When the change is complete:
  1. **Verify** per *this* repo's own conventions (its tests/linters/CI —
     discover them from its `CLAUDE.md` / `README` / `.github/workflows`; don't
     hardcode one project's commands). Don't ship red.
  2. **Push** the clean worktree: `git status --porcelain` empty (commit
     anything left), then `git push -u origin issue-<N>`.
  3. **Open (or update) the PR** with a body containing `Closes #<issue>` plus a
     short summary + how you verified:
     `gh pr create --repo "$FLEET_REPO" --base "$FLEET_BASE_BRANCH" --fill` (or
     `gh pr edit … --body …` if one exists).
  4. **Capture the 「改动后」 evidence** (issue #810) — PR open, nothing landed
     yet, the same URL / command / pane as your before-capture (the issue's
     `上线证据:` line, or your own judgment: at least one image or output of the
     changed thing), then leave the record on your issue:

     ```sh
     ~/.claude/fleet/bin/fleet-evidence.sh after --note '一句话：改了什么、看哪里' <file>   # `-` = stdin · `--pane <t>` = a TUI · `--mv` for a .playwright-mcp/ shot
     ~/.claude/fleet/bin/fleet-evidence.sh post    # ONE record-only comment: every path + its note
     ```

     The EPIC report collects exactly these files and writes **无证据** for a
     member that has none — it never re-shoots and never invents, so this is the
     only moment the "after" can be taken honestly. `gh` cannot attach an image to
     a comment: the comment carries the paths, the files stay on this machine.
  5. **Land it once the gate is green.** READ the gate, never eyeball it — one
     command folds state + mergeability + every check into one verdict
     (exit 0 ⇔ `READY`):

     ```sh
     ~/.claude/fleet/bin/fleet-pr-verdict.sh <PR> --repo "$FLEET_REPO"
     ```

     - **`READY`** → merge it, with this fleet's method (`FLEET_MERGE_METHOD`,
       default `squash`) and the remote branch deleted, then **confirm**:

       ```sh
       source ~/.claude/fleet/bin/fleet-lib.sh; fleet_load_conf "$(fleet_current_session)"
       gh pr merge <PR> --repo "$FLEET_REPO" "--$(fleet_merge_method)" --delete-branch
       ~/.claude/fleet/bin/fleet-pr-verdict.sh <PR> --repo "$FLEET_REPO"   # → MERGED
       ```

       `--delete-branch` removes the *remote* branch; your local branch +
       worktree are the cleanup daemon's to reap, and gh may decline or fail to
       delete the local one (you're standing on it) — harmless, which is why the
       confirming read above, not gh's exit code, is what tells you it landed.

       ⚠️ **ONE command. Never chain a separate `push --delete` after the merge**
       (issue #544). `--delete-branch` is conditional on the merge succeeding;
       a hand-written `gh pr merge … | tail && git push origin --delete <branch>`
       is not — and a pipeline's exit code is `tail`'s, not the merge's. #534's
       worker ran exactly that, the squash lost a conflict race, the `&&` fired
       anyway, and deleting the head branch made GitHub auto-CLOSE the PR. The
       worker then spent four minutes resolving the conflict by hand and was
       SIGKILLed mid-edit by the reaper. **A failed merge must not delete the
       branch.** If the merge fails: fix it, push, re-read the verdict, merge
       again — the branch stays until a merge actually lands.
     - **`PENDING`** → CI is still running. **Don't re-read in a loop** — block
       on it (issue #950), with the Bash tool's `run_in_background: true`:

       ```sh
       ~/.claude/fleet/bin/fleet-pr-verdict.sh <PR> --repo "$FLEET_REPO" --wait
       ```

       The harness wakes you when it exits, zero turns spent in between; the
       token it prints is the verdict — branch on it with this same list. It
       fails fast (the first red check is `FAILING`), waits out a check set that
       hasn't registered yet or was reset by a push, and paces its polls to the
       account's shared GraphQL budget. `TIMEOUT` (exit 3) is *undetermined*,
       never red: its stderr note carries the `mergeStateStatus` — re-run the
       wait, or treat a PR that never resolves as blocked below. (No background
       shell in your harness? Run the same command in the foreground.)
     - **`BEHIND`** → `gh pr update-branch <PR> --repo "$FLEET_REPO"`, then re-read.
     - **`FAILING` / `CONFLICT`** → yours to fix: fix, push, re-read. Never merge
       red, never `--admin`, never force-push the base. Notify the spawning session
       once of the red gate before fixing it:
       `~/.claude/fleet/bin/fleet-report-parent.sh --state failed --pr <PR> --summary 'RED: CI failure or merge conflict; fixing it'`.
     - **`BLOCKED`** → branch protection (a required review) refuses the merge.
       That is a real gate, not a hedge — you can't and shouldn't force it: say so
       on the issue (blocked, below) and stop.
  6. **Report to whoever spawned you** (issue #574) — one command, right after the
     merge is confirmed and before you stop:

     ```sh
     ~/.claude/fleet/bin/fleet-report-parent.sh --state merged --pr <PR> \
       --summary 'one or two lines: what changed, anything the parent must know'
     ```

     It reads the `origin:` line the brief printed (your window's `@origin`) and
     pushes a fixed 4-line report to that session over the peer channel. **A
     hub-spawned worker needs no special case**: with no parent — or a parent that
     has already been reaped — it exits 0 silently, so this is one unconditional
     line on every ship path, never a decision. It cannot fail your merge.
  7. **Then stop.** `com.claude-fleet.cleanup` reaps the worktree/window/branch
     and records the resume ledger after the merged grace (default 10 minutes)
     and liveness checks; the dash marks pending cleanup with `rNm`.
     Don't start new work in a
     landed worktree; a follow-up gets its own issue (and, if it's worth one now,
     its own worker via `--spawn` above).
- **Host for the operator with doc-preview, never an Artifact.** A report, plan,
  design doc, dashboard or mockup the operator should open in a browser goes
  through the fleet's doc-preview skill —
  `~/.claude/skills/doc-preview/share.sh <file.md|file.html>`, then relay the
  `READY` tailnet URL (any device, no login, every session's shares in one list).
  Artifact pages are scoped to the claude.ai account that published them, and the
  fleet rotates accounts under sessions, so the operator cannot know which login
  would show yours; the Artifact tool's publish is hook-blocked in fleet sessions
  (issue #526). Reading or commenting on an artifact someone shared with you is
  fine.
- **Blocked = say why, never stall silently.** Blocked means *actually* stuck —
  a required review you can't grant, credentials you don't have, a decision only
  the operator can make — not "I'd like a second opinion". Post a
  `⛔ blocked: <why>` comment on the issue (same `fleet-comment.sh --note`
  wrapper) and set the window red so it's visible on the dash:
  `sh ~/.claude/fleet/bin/set-claude-state.sh blocked`. This stamps `needs/blocked`
  (red `⊠`): tool hooks, Stop, the classifier and an idle transcript preserve it.
  A new `UserPromptSubmit` clears it so you can resume. If that input does not
  resolve the blocker (for example, a `[child-report]`), re-stamp `blocked` before
  stopping again. Then stop — don't spin.
  This is visibility, not permission-seeking: everything you *can* unblock
  yourself, you should. Blocked is an OUTCOME too, so report it the same way a
  merge is reported:
  `~/.claude/fleet/bin/fleet-report-parent.sh --state blocked --summary '<why>'`
  Add `--pr <PR>` when a PR exists.
  — a session that spawned you and is waiting on the result should not learn it
  by watching the dash go red.
- **A `[child-report]` arriving in YOUR pane: acknowledge, don't take over.** A
  worker you spawned (`--spawn`) pushes its outcome to you when it lands, blocks,
  or is reaped. It is four lines and it ends `no reply needed` — that is literal.
  **Do not reply to it, do not open its PR, do not adopt its follow-up work.**
  Note it, and go straight back to your own issue. **Want to check it? ONE read,
  not an investigation:** `~/.claude/fleet/bin/fleet-children.sh` answers "did it
  really land / stop / block, and how are the rest doing" from the ledger plus
  each child's live state and the dash's PR cache — no `gh pr list`, no
  `capture-pane` per child, no re-verifying a report by hand (issue #940; that
  per-report verification averaged 3.3 extra tool calls a report). The report is
  context, not a task: replying costs you a turn you are not being asked for, and taking over
  the child's work is how one worker ends up holding two issues and neither
  worktree matches. If it says `BLOCKED` and the blocker is genuinely yours to
  clear, clear it — in your own worktree, or by filing an issue — but that is the
  exception, not the default reading.

## 3. Report + proceed

One line: the issue number + title, whether you just claimed it or it was
already claimed, and which charter layers loaded (built-in only / + overlay / +
repo). Then start implementing — the rest of the lifecycle (ship + land, or
blocked) is the contract in step 2, run it when the work is done. Don't ask
whether to proceed; the claim IS the go-ahead.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. The base checkout is read-only (hook-enforced): a worker
edits inside its `issue-<N>` worktree and lands its own PR; the operator files and
triages from the hub, and is a collaborator here — not a gate you wait on.

**Never run destructive tmux on the live server.** Your fleet runs its own tmux
server on its own named socket (`tmux -L <session>`, issue #159), so a stray
`tmux kill-server` (or a `kill-session`/`kill-window` aimed at a sibling window)
takes down every window in THIS fleet at once — every worker beside you, mid-turn
(issue #158). If you're developing or testing tmux tooling, run
it on an **isolated socket** — `tmux -L scratch …`, or the `-S <sock>` PATH-shim
pattern the selftests use (`bin/dash-marker-selftest.sh`). A `tmux()` guard in
`shell/cw.zsh` refuses the common accidental forms from a worker shell (it's an
accident rail, not a security boundary); set `FLEET_ALLOW_TMUX_DESTROY=1` for the
rare legitimate destroy on the live server.

**Putting the machine under load? Use `bin/fleet-loadgen.sh`, never your own
`trap`.** Load experiments are legitimate — verifying an assertion on a busy box
is real work. Hand-rolled ones are how the machine dies: on 2026-09-15 a worker's
`(while :; do :; done) & … trap 'kill $BURN' EXIT` leaked 8 spinners that ran
**3h20m at ~70% CPU each** as `PPID=1` orphans, took the box to load 108 until
`ps` itself timed out, wedged both daemons and poisoned another issue's evidence
(issue #697). The trap never fired — a trap lives in the parent, and the parent
died. Every worker sharing the machine paid for it.

    ~/.claude/fleet/bin/fleet-loadgen.sh 8 120 -- <your experiment>   # load only while it runs
    ~/.claude/fleet/bin/fleet-loadgen.sh --status / --stop            # a detached batch

Each burner carries its own kernel deadline, so SIGKILLing the parent or closing
your pane cannot leak one, and the caps refuse an absurd `n`/duration. If you
suspect something already leaked — yours or anyone's —
`~/.claude/fleet/bin/fleet-diskguard.sh --orphans` lists the `PPID=1` runaways
the worktree- and pane-keyed reapers structurally cannot see.
