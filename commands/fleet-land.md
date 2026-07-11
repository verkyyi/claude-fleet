# /fleet-land — merge a green PR, then land it into the fleet's base checkout

<!-- fleet skill · owner: steward -->

The steward's finish line for a worker's PR. This skill is now a **thin approval
wrapper** over `bin/fleet-land.sh`: your job here is the **judgment** — verify the
PR is truly mergeable and the work is complete — and then hand the **mechanics**
(lease → merge → base fast-forward → history ledger → worktree/window teardown) to
the script, which runs them OUTSIDE this LLM turn. It **mutates this fleet's
`$FLEET_REPO`** (merges a PR) and the fleet's base checkout (`$FLEET_MAIN`).
Merging is a steward operation, so this skill is **steward-only** — a worker never
runs it (a worker `/fleet-ship`s; the steward `/fleet-land`s).

This skill is **fleet-agnostic**: it does the *general* finish work only. It does
**not** touch the live install (`~/.claude/fleet`), reload daemons, re-merge hooks,
or reinstall commands; that tooling re-apply is a separate concern — run
`/fleet-sync-install` for it after landing a claude-fleet tooling PR.

**Argument** (`$ARGUMENTS`): the PR number to land (`/fleet-land 61`). Required — if
empty, ask the user which PR and stop.

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
- **Wrong seat** — `/fleet-land` is `owner: steward`. If `$SEAT` isn't `steward`,
  **refuse in one line and stop**, e.g. *"/fleet-land is steward-only; you're in the
  worker seat — `/fleet-ship` your branch and let the steward land it."* Never merge
  from the wrong seat.

Everything below operates on the resolved `$FLEET_REPO` / `$FLEET_MAIN` /
`$FLEET_BASE_BRANCH` — this fleet only.

## 1. The judgment — review the PR before you approve it (this is the whole point)

The script lands what it's told; **you** are the approval gate. Never hand a red,
incomplete, or wrong PR to the lander. Read its state and its diff:

```sh
gh pr view "<N>" --repo "$FLEET_REPO" \
  --json number,title,headRefName,mergeable,mergeStateStatus,statusCheckRollup,state
gh pr diff "<N>" --repo "$FLEET_REPO"
```

- **Genuinely failing** (a required check is red on its own merits), **CONFLICTING**
  (needs a real rebase), or the **work looks incomplete / wrong** → **STOP and report**.
  Do not run the lander, do not `--admin`-bypass, do not rebase the worker's branch
  yourself — hand it back with the one-line reason.
- **Merely `BEHIND`** (out of date with base, checks otherwise green) is **fine to
  approve** — the lander brings it up to date under the lease and waits for green
  before merging. You do **not** need to `update-branch` by hand first.
- **Mergeable + green (or BEHIND-but-otherwise-green) + work looks right** → approve
  it: go to step 2.

## 2. Hand the mechanics to the lander

`bin/fleet-land.sh` does the mechanical land with no further LLM turn: it takes the
**per-repo land lease** (the SAME lock `/fleet-land-train` and `/fleet-land-self`
take, so landing stays single-writer — this also closes the old gap where
`/fleet-land` took *no* lease and could race a train), **holds it through the
green-wait** (if `BEHIND` it `update-branch`es and waits for CI *while holding the
lease*, so base can't advance under it), re-validates ownership + `--match-head-commit`
(a stolen lease / a head-sha race aborts instead of landing blind), squash-merges,
`pull --ff-only`s the base checkout, records the history ledger **before** removal,
then tears down the worker's window + worktree + branch in order.

```sh
bash ~/.claude/fleet/bin/fleet-land.sh "<N>" 2>&1
```

Read the single result token it prints on the last line:

- `landed:<sha>` / `landed:already` → **success.** The PR is merged, the base is
  fast-forwarded, the ledger row is recorded, and the worker's window/worktree/branch
  are cleaned up. Report it (step 3).
- `eject:<reason>` (conflict / failing / blocked / draft / gone / max-hold / lease
  timeout) → it refused to force. Do **not** retry blindly — report the reason and
  hand the PR back (rebase / fix checks / get review, per the reason).
- `error:<reason>` (no repo / no main / no gh / PR not found) → a precondition
  failed. Fix it and retry, or report.

Preview without mutating anything with `--dry-run` (prints the verdict + planned
action, takes no lease):

```sh
bash ~/.claude/fleet/bin/fleet-land.sh "<N>" --dry-run 2>&1
```

Tune behaviour with the `LAND_*` env knobs documented at the top of
`bin/fleet-land.sh` (poll interval, hold/queue timeouts, retry cap, merge method,
lease TTL).

## 3. Report — one line

```
#<issue> landed → <squash commit sha>
```

Name the PR, the issue it closed (from the head branch / PR body), and the landed
sha. If the lander ejected (not mergeable) or errored, report **that** instead —
clearly, with the one-line reason and what the human/worker must do next.

If the PR changed the claude-fleet tooling itself and you're on the self-hosting
tooling fleet, note that the live install still needs `/fleet-sync-install` to pick
up the change — `/fleet-land` deliberately does not touch it.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. `/fleet-land` never force-pushes and never `--admin`-bypasses
branch protection: the lander only merges a PR GitHub already considers mergeable,
after CI is green on the base it lands on. Implementation is the worker's job — the
steward triages, approves the land, and hands the live-install re-apply to
`/fleet-sync-install`.
