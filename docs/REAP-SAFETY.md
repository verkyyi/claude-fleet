# Dash reap liveness

`dash-reap.sh` checks both Git eligibility and whether the target can still be
working. A clean worktree, even one with a merged PR, does not authorize killing
an active session. This is the dash-specific liveness part of #565; the janitor
keeps its existing, separate worktree/pane/process/rotation guards.

The script accepts stable `@window_id`, `%pane_id`, registered fleet handles
(such as `a1`), `issue-N` / quoted `#N`, and `scratch-N`. Issue/scratch/handle
lookup must match exactly one window on this fleet's socket. Missing or duplicate
matches are refused; an unknown handle never falls back to a window name.
Scratch lookup uses the bound `@worktree`, falling back to pane cwd only when the
binding is absent. Handles and issue/scratch keys describe current windows and
can be reused after a window closes; use a captured `@id` for delayed actions.

Bare numbers, `session:index`, relative targets and arbitrary names are refused
with `refused:target` (exit 4). The diagnostic shows the current resolution but
never acts on it. Use `issue-123` for an issue number, not bare `123`. A second
target or unknown argument returns `refused:bad-args`; batch callers must loop
over captured IDs. Each resolved target is pinned to `@id` before popup or
background dispatch. The dashboard reap binding uses its existing second row
field (`@id`), so renumbering since the row was drawn cannot redirect a reap.

Before dispatch/disposal, stderr describes the pinned window, name, issue, state,
worktree and reason. Stdout retains its existing single result-token contract.

The read-only `fleet-reap-live.py` gate blocks disposal when:

- `@claude_state` is anything other than `done` or empty, including `working`,
  `looping`, `busy` and `waiting`;
- any pane in that window contains a Claude or Codex process younger than
  `FLEET_REAP_MIN_AGE` seconds (default **1800**, or 30 minutes);
- window/process metadata cannot be read reliably. Probes have a five-second
  timeout and fail closed; missing Python/helper files also block disposal.

The process check walks descendants of every pane PID, not just the pane's shell
or `pane_current_command`. It recognizes native Claude/Codex binaries and their
Node/Bun CLI entrypoints. An unrelated agent elsewhere on the machine is not a
match. A process whose elapsed time cannot be parsed is treated as new. Set the
age threshold in global or per-fleet configuration; `0` disables only the age
test, never the state/metadata checks. Arbitrary renamed binaries and custom CLI
wrappers are not guaranteed to be recognized; keep their state hooks enabled.

Checks run before offering disposal and again inside the disposal path, including
the delayed `--exec` tail. A worker that resumes while cleanup waits is protected.
The window is checked again after the parent report, before killing/removing it.
This narrows the check/action gap; it is not an atomic lock against a process
starting in the instant after a check.

`--yes`, `--force` and popup confirmation do **not** override liveness. A blocked
script call returns `skip:live`, exit **3**, and a reason on stderr; interactive
confirmation mode suppresses the result token, as before. No worktree or issue is
disposed on that path. Finish the session or wait for the age threshold before
trying again. If a recheck blocks after a prior history/report step, that earlier
record can remain; liveness refusal prevents the destructive step itself.

The shared Git gate (`fleet_reap_ok`) also requires **strict** ancestry: a clean
branch at exactly the current base commit, with no merged PR, returns `unmerged`
(rc 1). SHA/ref spellings are resolved before comparing. The dash requires its
existing explicit confirmation; the janitor keeps the worktree; manual SessionEnd
still closes the exited window but keeps its worktree, branch and issue. A merged
PR remains independent evidence and can authorize disposal even at the base tip.
Dirty worktrees remain protected before either condition is considered.

This equality check is conservative: a fast-forwarded branch at the base tip with
no GitHub merged-PR evidence is also kept. It does not reconstruct the branch's
creation point; after base advances, a branch created at the previous base can
become a strict ancestor. The separate liveness guards remain necessary.

The cleanup daemon separately enforces a [merged grace](CLEANUP.md#the-pieces)
of 600 seconds by default. Idle-scratch auto-reaping and dashboard grace markers
remain separate work in #565. A SessionEnd hook is also a different path: the user has already ended that
agent, so it is not routed through the dash's active-agent policy.
