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
- **Wrong seat** — `/fleet-claim` is `owner: worker`. If `$SEAT` isn't `worker`,
  **refuse in one line and stop**, e.g. *"/fleet-claim is worker-only; you're in the
  hub pane."* Never proceed from the wrong seat.

Everything below operates on the resolved `$FLEET_REPO` / `$FLEET_MAIN` /
`$FLEET_BASE_BRANCH` — this fleet only.

## 1. Resolve + read the bound issue

The issue number is NOT an argument (the seed is a bare `/fleet-claim`). Resolve
it from the window's `@issue` binding — the spawner sets it — falling back to the
`issue-<N>` worktree in your cwd if the binding is somehow missing (a hand-attached
or renamed window), mirroring `fleet_seat`. Never guess a number from anything else:

```sh
issue=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@issue}' 2>/dev/null)
issue="${issue//[^0-9]/}"                          # @issue is the source of truth
if [ -z "$issue" ]; then                           # fallback: the issue-<N> worktree
  case "$(pwd -P)" in
    */*issue-[0-9]*) n="$(pwd -P)"; n="${n##*issue-}"; issue="${n%%[!0-9]*}" ;;
  esac
fi
echo "issue=${issue:-none}"
```

- If `$issue` is STILL empty — no `@issue` on the window AND cwd isn't an
  `issue-<N>` worktree — **fail loudly and stop** in one line: *"no issue bound
  (no @issue and cwd isn't an issue-<N> worktree) — run /fleet-claim inside a
  worker window."* Never guess.
- Otherwise read it (reuse the literal number):
  `gh issue view "<issue>" --repo "$FLEET_REPO" --comments`.

## 2. Claim it — natively, via the assignee (the anti-collision rail)

**The assignee IS the claim** (issue #283). Assign yourself; that's the whole
claim — there is no `▶ claiming` comment convention anymore (it false-fired
whenever a comment merely mentioned the marker string).

> Cross-machine dedup (issues #258, #283): the pre-spawn dedup is **ON by
> default** (unless the fleet sets `FLEET_PRESPAWN_DEDUP=0`), so the **spawn
> already pre-claimed** this issue by assigning you the instant it passed the
> pre-spawn check. So this step normally finds you already the assignee and
> **no-ops**. That is by design — the check below makes it idempotent.

```sh
# Am I already the assignee? (empty output = not yet mine)
mine=$(gh issue view "<issue>" --repo "$FLEET_REPO" \
  --json assignees -q '.assignees[].login' 2>/dev/null | grep -Fx "$(gh api user -q .login)")
echo "mine=${mine:-no}"
```

- Assign yourself only if not already yours:
  `gh issue edit "<issue>" --repo "$FLEET_REPO" --add-assignee @me`.
- If you were already the assignee, say so and skip the write — don't re-assign.

## 3. Load your charter (layered — later wins on conflict)

Your standing orders come in up to three layers. The **built-in contract**
(step 5 below) is the base. Two optional FILE layers override it — load them and
treat a later layer as authoritative where it conflicts with an earlier one:

```sh
fleet_worker_charter "$S"    # prints the file layers that apply, low→high precedence
```

- **repo charter** `$FLEET_MAIN/.fleet/worker.md` — printed **only when the
  fleet opts in** with `FLEET_REPO_CHARTER=1` (default OFF, fail-closed). It is
  an injection surface: a worker lands its own PR on green CI with no human
  review, so a PR could rewrite the charter every future worker obeys — hence the
  gate. A fleet that arms it on a public repo should protect `.fleet/` with
  CODEOWNERS + required review.
- **fleet overlay** `~/.config/claude-fleet/fleets/<session>/worker.md` —
  operator-owned and machine-local, so it is always trusted (no gate) and **wins
  on conflict**. This is the operator's per-fleet customization channel.

`fleet_worker_charter` also appends a machine-global **tap-first** block when the
fleet sets `FLEET_TAP_FIRST=1` (default OFF) — it steers you to offer a tappable
`AskUserQuestion` menu instead of an open-ended prose question for a bounded
decision (cheap on a soft keyboard). Guidance, not a mandate: don't ask *more*.

Both files are optional; missing ones are skipped silently. With neither (and the
flag off) you run on the built-in contract == the historic default. Read whatever
prints and fold it into how you work below.

## 4. Ground yourself, then implement

Read what you need — the full issue thread (step 1's output, including any
any design comments) and the code the change touches — then implement. You
decide the approach; the rails and the finish line are below.

Fold in the operator's **per-fleet implementation directive** (issue #234) — the
one place, alongside the charter layers, where a fleet adds specific HOW-to
guidance (it defaults to *"Implement and verify per the repo conventions"*):

```sh
source ~/.claude/fleet/bin/fleet-lib.sh; fleet_load_conf "$(fleet_current_session)"
fleet_worker_prompt_body "<issue>" "$FLEET_REPO"   # FLEET_WORKER_PROMPT / _FILE, else the default
```

## 5. The standing contract (built-in charter — the base layer)

Implement under these invariants (a charter layer from step 3 may extend or
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
  for fleet plumbing only.
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
  `/fleet-handoff` — it writes a durable handoff and cycles the pane.
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

## 6. Report + proceed

One line: the issue number + title, whether you just claimed it or it was
already claimed, and which charter layers loaded (built-in only / + overlay / +
repo). Then start implementing — the rest of the lifecycle (ship + land, or
blocked) is the contract in step 5, run it when the work is done. Don't ask
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
