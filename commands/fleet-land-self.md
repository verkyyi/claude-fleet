# /fleet-land-self — land your OWN PR after the steward triggers it

<!-- fleet skill · owner: worker -->

The worker's own finish-the-lifecycle skill, and a **mirror of `/fleet-land`
scoped to this worker's own issue/PR**: re-verify the PR is genuinely green +
mergeable, sanitize your own diff, take the per-repo land lease, squash-merge,
fast-forward the fleet's base checkout, and self-destruct (kill this window +
remove the worktree). It **mutates this fleet's `$FLEET_REPO`** (merges your PR)
and the base checkout (`$FLEET_MAIN`). It is **worker-only** and — unlike every
other worker skill — it *merges*. What gates that relaxed rail depends on the
fleet's `FLEET_SELF_LAND` mode (step 0): in `=1` (triggered) it runs solely on the
steward's explicit `/land` trigger and the steward's pre-trigger review is the
approval gate; in `=auto` (issue #270) the trigger is optional and CI-green +
branch protection are the gate. See [docs/SELF-LAND.md](../docs/SELF-LAND.md).

**In triggered mode (`=1`), do not run this on your own initiative** — after
`/fleet-ship` you **wait** and run this only when the steward triggers the land (a
`/land` / `<!-- fleet:land -->` comment relayed onto the issue by the #132
issue-bridge) or the human in your pane tells you to. **In `auto` mode you flow
here directly from `/fleet-ship`** — no wait, no trigger. Either way, if it can't
land cleanly, run `/fleet-blocked` with the reason instead of forcing.

**Argument** (`$ARGUMENTS`): none — the PR is resolved from your `issue-<N>`
branch. (You may pass an explicit PR number to override, but the default is
correct.)

## 0. Resolve fleet + guard seat (run FIRST, every time)

Env vars do NOT persist across separate Bash tool calls — run this once, then
reuse the literal values it prints:

```sh
source ~/.claude/fleet/bin/fleet-lib.sh
S=$(fleet_current_session); fleet_load_conf "$S"   # → FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH
SEAT=$(fleet_seat)                                 # → worker | steward | "" (ambiguous)
echo "repo=${FLEET_REPO:-} main=${FLEET_MAIN:-} base=${FLEET_BASE_BRANCH:-master} seat=${SEAT:-unknown} self_land=${FLEET_SELF_LAND:-0}"
```

`self_land` decides the gate in step 1: `1` = you may land **only** after the
steward's `/land` trigger; `auto` (issue #270) = no trigger required — you flow
here straight from `/fleet-ship`.

- **No fleet** (`FLEET_REPO` empty) → **ABORT** in one line: *"not inside a
  fleet — run this from a fleet session."* Never guess a repo.
- **Wrong seat** — `/fleet-land-self` is `owner: worker`. If `$SEAT` isn't `worker`,
  **refuse in one line and stop**, e.g. *"/fleet-land-self is worker-only; a steward
  lands with `/fleet-land`."* Never proceed from the wrong seat.

Everything below operates on the resolved `$FLEET_REPO` / `$FLEET_MAIN` /
`$FLEET_BASE_BRANCH` — this fleet only.

## 1. Confirm you're cleared to land

The gate depends on `self_land` (from step 0):

- **`self_land=auto` (issue #270)** — **no trigger required.** In auto mode the
  steward trigger is optional; you flow here straight from `/fleet-ship`. Skip
  the trigger check and go to step 2. CI-green + branch protection are the gate
  (the same relaxation `FLEET_AUTOLAND` makes) — step 2's re-verify + step 4's
  hold-through-green enforce it.
- **`self_land=1` (triggered, the default self-land)** — the trigger IS the
  approval gate. Land **only** when one of these is true:
  - The steward (or a trusted collaborator) left a comment containing `/land` or
    `<!-- fleet:land -->` on your bound issue — relayed to you as a turn by the
    issue-bridge (that turn is likely *how you got here*).
  - The human in your pane told you to land.

  If you are here on your own initiative with no trigger, **stop** — go back to
  waiting. Do not self-land un-triggered.

## 2. Identify the PR + re-verify it's genuinely mergeable

```sh
issue=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@issue}')
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
echo "issue=${issue:-none} branch=${branch:-none}"
gh pr view "$branch" --repo "$FLEET_REPO" \
  --json number,headRefName,mergeable,mergeStateStatus,statusCheckRollup,state
```

- You must be on the `issue-<N>` branch inside its worktree (the worker seat
  guarantees this) and the PR's `headRefName` must equal `$branch` — it's *your*
  PR. If not, **stop**.
- Read `mergeable` + `statusCheckRollup`. Genuinely failing, **CONFLICTING**, or
  incomplete → do **not** land; go to step 5 (`/fleet-blocked`). Merely `BEHIND`
  is fine — step 4 brings it up to date under the lease and waits for green.

## 3. Sanitize your own diff

A self-check (the steward's pre-trigger review is the real independent gate, but
never merge obvious junk): scan the diff that will land for secrets, leftover
conflict markers, and debug noise.

```sh
git -C "$PWD" fetch origin "$FLEET_BASE_BRANCH" --quiet 2>/dev/null
git diff "origin/$FLEET_BASE_BRANCH"...HEAD | \
  grep -nE '^\+' | \
  grep -niE 'BEGIN (RSA|OPENSSH|PRIVATE) KEY|AKIA[0-9A-Z]{16}|<<<<<<<|>>>>>>>|=======$|xoxb-|ghp_[0-9A-Za-z]{20,}|password[[:space:]]*=[[:space:]]*[^[:space:]]|TODO: ?remove|console\.log\(|binding\.pry|debugger;' \
  || echo "sanitize: clean"
```

If anything real surfaces (a committed secret, a stray conflict marker, debug
left in), **stop and fix it** on the branch (commit + push), then re-verify —
do not land a diff that fails this check. A false positive (e.g. the pattern
appears in this skill's own docs) is fine to wave through with a note.

## 4. Land it — lease-serialized, hold-through-green, self-destruct

`bin/fleet-land-self.sh` does the mechanical land exactly as `bin/land-train.sh`
does one lap, scoped to your PR: it takes the **per-repo land lease** (the same
lock `/fleet-land-train` uses, so landing stays single-writer), and **holds it
through the green-wait** — if the branch is `BEHIND` it `update-branch`es, waits
for CI to go green *while holding the lease* (so master can't advance under you),
re-validates it still owns the lease (`--match-head-commit` guards the head-sha
race), squash-merges, `pull --ff-only`s the base checkout, records the history
ledger, and launches a **detached** `tmux run-shell` that kills this window and
removes the worktree + branch after your process exits.

```sh
bash ~/.claude/fleet/bin/fleet-land-self.sh 2>&1
```

Read the single result token it prints on the last line:

- `landed:<sha>` / `landed:already` → **success.** Your PR is merged, the base is
  fast-forwarded, and the window/worktree teardown is underway. You're done —
  say so in one line and stop; the window will close under you.
- `eject:<reason>` (conflict / failing / blocked / not-own / max-hold / lease
  timeout) → it refused to force. Do **not** retry blindly — go to step 5.
- `error:<reason>` → a precondition failed (no PR, wrong branch). Fix and retry,
  or go to step 5.

The teardown is detached on purpose — the worker can't remove the ground it
stands on, so the tmux server does it after you exit. `worktree-autoclean.sh`
is the backstop if the self-destruct ever fails.

## 5. If it can't land — /fleet-blocked, don't force

On any `eject:`/`error:` you can't resolve, signal it instead of forcing:

```sh
/fleet-blocked <the eject/error reason, e.g. "self-land: conflict-needs-rebase — needs a rebase onto master">
```

That posts the reason on the issue (bridge-safe, no-relay marker) and flips the
window red for the steward. Never `--admin`-bypass, never force-merge, never
rebase-and-merge past a real conflict — hand it back.

## 6. Report — one line

On success: `#<issue> self-landed → <sha>` (note the window is self-destructing).
On eject/error: the one-line reason and that you posted `/fleet-blocked`.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. `/fleet-land-self` merges **only your own** `issue-<N>` PR,
**only after the steward's trigger**, and only a PR GitHub already considers
mergeable on a green base — it never force-pushes, never `--admin`-bypasses, and
never touches the live install (`~/.claude/fleet`); that tooling re-apply stays a
separate single-writer step (`/fleet-sync-install`).
