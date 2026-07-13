# /fleet-claim — the worker lifecycle: claim → charter → ground → work → ship+arm

<!-- fleet skill · owner: worker -->

The one skill a freshly-spawned worker runs. It formalizes the whole worker
lifecycle that the seed prompt used to spell out across three skills: **claim**
the bound issue, **load your charter**, **ground** yourself in the issue + code,
then implement under a **standing contract** that ends by opening a PR and
**arming GitHub auto-merge** (the fleet never merges) — and signals a blocker
loudly rather than stalling. Mutates ONLY the bound issue on this fleet's
`$FLEET_REPO` (an assignee at claim time; issue comments as you go) and — at
ship — pushes your branch, opens/updates a PR, and arms auto-merge. It never
touches the base checkout.

**Argument** (`$ARGUMENTS`): none — the seed is a bare `/fleet-claim`, so the
issue is self-discovered from the window's `@issue` binding (fallback: the
`issue-<N>` worktree name), never an argument.

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
- **Wrong seat** — `/fleet-claim` is `owner: worker`. If `$SEAT` isn't `worker`,
  **refuse in one line and stop**, e.g. *"/fleet-claim is worker-only; you're in the
  steward seat."* Never proceed from the wrong seat.

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
  an injection surface: PRs auto-merge on green CI with no human review, so a PR
  could rewrite the charter every future worker obeys — hence the gate. A fleet
  that arms it on a public repo should protect `.fleet/` with CODEOWNERS +
  required review.
- **fleet overlay** `~/.config/claude-fleet/fleets/<session>/worker.md` —
  operator-owned and machine-local, so it is always trusted (no gate) and **wins
  on conflict**. This is the operator's per-fleet customization channel.

Both files are optional; missing ones are skipped silently. With neither, you
run on the built-in contract == the historic default. Read whatever prints and
fold it into how you work below.

## 4. Ground yourself before you edit

Restate scope, then read before you write:

- One line restating what the issue asks for, in your own words.
- Load the **per-fleet implementation directive** — the operator's standing
  instruction for HOW to implement on this fleet (issue #234), the one piece the
  old paragraph seed used to inject inline. Fold whatever it prints into your plan
  (it defaults to *"Implement and verify per the repo conventions"*):
  ```sh
  source ~/.claude/fleet/bin/fleet-lib.sh; fleet_load_conf "$(fleet_current_session)"
  fleet_worker_prompt_body "<issue>" "$FLEET_REPO"   # FLEET_WORKER_PROMPT / _FILE, else the default
  ```
- Read the **full issue thread** (step 1's output — including any steward design
  comments), then the **relevant code** the change touches, before editing.
- Sketch a short numbered plan (the steps you'll take).

## 5. The standing contract (built-in charter — the base layer)

Implement under these invariants (a charter layer from step 3 may extend or
override them):

- **Work only in this worktree.** You are in the `issue-<N>` git worktree off
  `$FLEET_BASE_BRANCH`; never commit to or edit the base checkout (it's
  hook-enforced read-only). Converse with the steward/collaborators by
  **commenting on the bound issue** (via
  `~/.claude/fleet/bin/fleet-comment.sh "<issue>" --repo "$FLEET_REPO" --note --body '…'`
  so it carries the no-relay marker + worker footer).
- **Hand off before you run out of context.** When the window fills, run
  `/fleet-handoff` — it writes a durable handoff and cycles the pane.
- **Done = ship + arm auto-merge (the fleet never merges).** When the change is
  complete:
  1. **Verify** per *this* repo's own conventions (its tests/linters/CI —
     discover them from its `CLAUDE.md` / `README` / `.github/workflows`; don't
     hardcode one project's commands). Don't ship red.
  2. **Push** the clean worktree: `git status --porcelain` empty (commit
     anything left), then `git push -u origin issue-<N>`.
  3. **Open (or update) the PR** with a body containing `Closes #<issue>` plus a
     short summary + how you verified:
     `gh pr create --repo "$FLEET_REPO" --base "$FLEET_BASE_BRANCH" --fill` (or
     `gh pr edit … --body …` if one exists).
  4. **Arm** GitHub auto-merge — this is *not* a merge; GitHub merges when the PR
     is green and branch protection is satisfied:
     ```sh
     gh pr merge --repo "$FLEET_REPO" --auto --"$(fleet_merge_method)" issue-<N>
     ```
     `fleet_merge_method` resolves `FLEET_MERGE_METHOD` (default `squash`).
     If arming fails because the repo has auto-merge disabled, **do not merge by
     hand** — say so; the PR is open and reviewable, a human enables auto-merge
     or merges on the web when green.
  5. **Stop.** Never merge the PR yourself and never pass `--admin`. GitHub
     merges when green; `com.claude-fleet.cleanup` reaps the worktree/window/
     branch and records the resume ledger afterward.
- **Blocked = say why, never stall silently.** If you can't make progress, post
  a `⛔ blocked: <why>` comment on the issue (same `fleet-comment.sh --note`
  wrapper) and set the window red so the steward sees it:
  `sh ~/.claude/fleet/bin/set-claude-state.sh needs`. Then stop — don't spin.

## 6. Report + proceed

One line: the issue number + title, whether you just claimed it or it was
already claimed, and which charter layers loaded (built-in only / + overlay / +
repo). Then restate scope + the plan from step 4 and start implementing — the
rest of the lifecycle (ship + arm, or blocked) is the contract in step 5, run it
when the work is done.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. The base checkout is read-only (hook-enforced): a worker
edits inside its `issue-<N>` worktree and lands via PR; a steward files/triages
and hands implementation to a worker.

**Never run destructive tmux on the live server.** Every fleet shares ONE tmux
server on the `default` socket, so a stray `tmux kill-server` (or a
`kill-session`/`kill-window` aimed at a sibling) takes down *every* fleet on the
machine at once (issue #158). If you're developing or testing tmux tooling, run
it on an **isolated socket** — `tmux -L scratch …`, or the `-S <sock>` PATH-shim
pattern the selftests use (`bin/dash-marker-selftest.sh`). A `tmux()` guard in
`shell/cw.zsh` refuses the common accidental forms from a worker shell (it's an
accident rail, not a security boundary); set `FLEET_ALLOW_TMUX_DESTROY=1` for the
rare legitimate destroy on the live server.
