# /fleet-claim — the worker lifecycle: claim → charter → ground → work → ship

<!-- fleet skill · owner: worker -->

The one skill a freshly-spawned worker runs. It formalizes the whole worker
lifecycle that the seed prompt used to spell out across three skills: **claim**
the bound issue, **load your charter**, **ground** yourself in the issue + code,
then implement under a **standing contract** that ends by **opening a PR and
landing it yourself once the gate is green** — and signals a blocker loudly rather
than stalling. Mutates the bound issue on this fleet's `$FLEET_REPO` (an assignee
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
**implementation directive**.

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

- **Delegate the broad sweep.** "Which files touch X, and where" is a fan-out
  search — hand it to the `Explore` subagent and you get back the conclusion
  instead of every file it read on the way. Keep the main window for the code
  you are actually changing.
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

## 2. The standing contract (built-in charter — the base layer)

Implement under these invariants (a charter layer from the brief may extend or
override them):

- **Work only in this worktree.** You are in the `issue-<N>` git worktree off
  `$FLEET_BASE_BRANCH`; never commit to or edit the base checkout (it's
  hook-enforced read-only). Converse with the operator/collaborators by
  **commenting on the bound issue** (via
  `~/.claude/fleet/bin/fleet-comment.sh "<issue>" --repo "$FLEET_REPO" --note --body '…'`
  so it carries the no-relay marker + worker footer). To message another worker,
  use `fleet-comment.sh --to-worker` (the issue-bridge). NEVER drive
  another agent's pane with `tmux send-keys` — it's racy (bracketed-paste swallows
  the Enter) and is hook-blocked (#437). The bridge relays your comment as the
  target's next clean turn; `FLEET_ALLOW_SENDKEYS=1` is the sanctioned override,
  for fleet plumbing only. Closing the issue with a final comment (a
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
  **`--spawn` is yours to use** (issue #441): it hands the new number to the same
  spawn choke point the hub uses, so the session caps + cross-machine pre-spawn
  dedup still apply and a cap refusal just leaves the issue filed. Spawn when the
  follow-up is genuinely independent and worth a worker *now*; otherwise file it
  bare and let it sit on the backlog. What stays fixed either way: **don't chase
  it in THIS worktree** — one worktree, one issue, one PR. A spawned worker
  claims and ships it on its own.
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
  4. **Land it once the gate is green.** READ the gate, never eyeball it — one
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
     - **`PENDING`** → CI is still running. Wait and re-read (minutes between
       reads — don't busy-poll). If it never resolves, treat it as blocked below.
     - **`BEHIND`** → `gh pr update-branch <PR> --repo "$FLEET_REPO"`, then re-read.
     - **`FAILING` / `CONFLICT`** → yours to fix: fix, push, re-read. Never merge
       red, never `--admin`, never force-push the base.
     - **`BLOCKED`** → branch protection (a required review) refuses the merge.
       That is a real gate, not a hedge — you can't and shouldn't force it: say so
       on the issue (blocked, below) and stop.
  5. **Then stop.** `com.claude-fleet.cleanup` reaps the worktree/window/branch
     and records the resume ledger, so expect this window to vanish a minute or
     so after the merge — that's the reap, not a crash. Don't start new work in a
     landed worktree; a follow-up gets its own issue (and, if it's worth one now,
     its own worker via `--spawn` above).
- **Blocked = say why, never stall silently.** Blocked means *actually* stuck —
  a required review you can't grant, credentials you don't have, a decision only
  the operator can make — not "I'd like a second opinion". Post a
  `⛔ blocked: <why>` comment on the issue (same `fleet-comment.sh --note`
  wrapper) and set the window red so it's visible on the dash:
  `sh ~/.claude/fleet/bin/set-claude-state.sh needs`. Then stop — don't spin.
  This is visibility, not permission-seeking: everything you *can* unblock
  yourself, you should.

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
