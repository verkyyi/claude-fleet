# /fleet-move — move a session to another login/machine

<!-- fleet skill · owner: either -->

Moves one or more of THIS fleet's live (or done) windows to another login's
fleet, on another machine, over ssh — driven entirely from here via
`bin/fleet-move.sh` / `bin/fleet-move-remote.sh` (issue #1067). It mutates this
fleet (stops + closes the source window) and, over ssh, the TARGET login's
fleet (a new worktree, a new tmux window) — never any other fleet on this
machine. Nothing is pushed anywhere the caller didn't ask for except the moved
branch itself, which is pushed to `origin` when it is ahead of base (needed so
the target can land the exact same commits).

**Argument** (`$ARGUMENTS`): one or more window targets (a `@wid` handle like
`b3`, a name, or a tmux id), then `to <user>@<host>` — e.g.
`/fleet-move b3 to verkydev@mini`. Missing the target host → ask for it (an
`AskUserQuestion` menu of recently-used hosts, if any are known from this
session, else free text) rather than guessing. Missing a window → ask which one
(the current window is never assumed; a move is deliberate, always named).

## 0. Resolve fleet + guard seat (run FIRST, every time)

```sh
source ~/.claude/fleet/bin/fleet-lib.sh
S=$(fleet_current_session); fleet_load_conf "$S"
SEAT=$(fleet_seat)
echo "repo=${FLEET_REPO:-} main=${FLEET_MAIN:-} seat=${SEAT:-unknown}"
```

- **No fleet** → **ABORT** in one line: *"not inside a fleet — run this from a
  fleet session."*
- **Seat**: `owner: either` — both a worker (moving itself, or a sibling
  window it spotted) and the hub pane (the operator's usual seat for this) may
  run it.

## 1. The one-fleet-per-login target (`--fleet` is the exception, not the rule)

With one fleet per login (#979/#980), `<user>@<host>` names the target
**login**, and that login runs exactly one fleet — `bin/fleet-move-remote.sh`
resolves it on its own. Only pass `--fleet <sess>` when you already know the
target login still runs more than one fleet (a pre-#980 install, or a login
that never converged) — asking without evidence of that is asking the wrong
question; when in doubt, omit it and let the target refuse if it's genuinely
ambiguous (`fleet-move.sh` reports that refusal by name, it never guesses).

## 2. Plan first, always

```sh
~/.claude/fleet/bin/fleet-move.sh <window>… --to <user>@<host> --dry-run
```

This is READ-ONLY on both ends (it probes the target — reachable, fleet
installed, repo hosted there — but allocates nothing and stops nothing).
Read its plan lines before doing anything else: repo, branch, whether the
branch is ahead of base (⇒ it will be pushed), and whether the target probe
came back ready. A `refused:*` line here is the same reason the real run
would give — fix that first (see the per-window refusal reasons in
`fleet-move.sh`'s own header) rather than re-running and hoping.

## 3. Confirm, then run

**This is a hard-to-reverse action on shared state** — it stops a live agent,
closes a window, and creates a new live session on someone else's machine —
so confirm the plan with the operator before running it for real, even when
`$SEAT` is a worker moving itself. State what will happen in one line (windows,
repo/branch, target, and whether `--keep-source` is in play) and wait for a go
ahead; don't infer consent from the dry-run having looked clean.

```sh
~/.claude/fleet/bin/fleet-move.sh <window>… --to <user>@<host>
```

Multiple windows move ONE AT A TIME; each gets its own plan line above and its
own ✓/✗ result line here. Read `fleet-move.sh`'s exit code — it IS the reason
(issue #683): 0 = moved, and every non-zero code names a specific refusal or
failure class (dirty worktree, push failed, target failed, the agent never
exited, or — the one that leaves the SOURCE running on purpose — the target
window opened but no Claude ever appeared under it, `failed:verify`). Never
retry blindly on a non-zero exit; read which window and why first.

### The fork hazard — why `--keep-source` is not the default

A session's transcript is one append-only file. The instant it's been copied
to the target, TWO live agents resuming the same session id would each append
to their OWN copy from that point on — nothing reconciles that afterwards, on
either side. The default move avoids this by construction: the source agent
is stopped and its window closed **only after** the target side is verified
live, so at every moment exactly one side is resumable.

`--keep-source` deliberately breaks that guarantee — it copies and resumes on
the target while leaving the source running untouched. Reach for it only to
**inspect the target before committing** (peek at the resumed window, confirm
it looks right, THEN either re-run without the flag to actually cut over, or
manually close whichever side you don't want) — never as a way to "duplicate"
a working session, and never leave both sides open past that inspection. If
you used it, say so plainly and remind whoever's listening which side is now
the one true copy.

## 4. Report

One line per window: moved (with the target host + new window) or refused/
failed (with the reason `fleet-move.sh` printed). If anything failed partway
with the target side already provisioned, its recovery/cleanup already ran
(`fleet-move.sh` discards a target worktree it can't finish landing) — nothing
further to clean up by hand unless a `failed:verify` line told you the source
is still running and named the pane to inspect.

---

Rails: operates on THIS fleet's windows and the ONE target login named by
`--to` — never a third fleet, and never another window than the ones named.
The base checkout is read-only; this script never mutates it (it works only
inside worktrees, on both ends). See `docs/ARCHITECTURE.md`'s "moving a
session" section for how this compares to `fleet-migrate.sh` (account swap,
one machine), `fleet-transfer.sh` (claude↔codex, one pane) and
`/fleet-handoff` (a doc, no process ever stops).
