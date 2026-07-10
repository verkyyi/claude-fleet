# /fleet-scout — delegate a read-only investigation to a scout worker

<!-- fleet skill · owner: steward -->

Delegate *investigation* instead of doing research inline: file a **`scout`-labeled
issue** (the durable question + report sink) in **this fleet's** `$FLEET_REPO`,
then spawn a **read-only** worker bound to it that investigates and posts its
findings as a comment — **no branch, no PR, no ship mandate**. It mutates the
fleet's repo (files one issue) and spawns a session, so it's the **steward's**
job. Use it for a *substantial, trackable* investigation; for a throwaway lookup
use the ephemeral tier instead (see step 1).

**Argument** (`$ARGUMENTS`): the investigation question — a sentence or short
brief (e.g. *"where does the spinner decide a window is stuck, and is the
threshold configurable?"*). If empty, ask the user what to investigate and stop.

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
- **Wrong seat** — `/fleet-scout` is `owner: steward`. If `$SEAT` isn't
  `steward`, **refuse in one line and stop**, e.g. *"/fleet-scout is
  steward-only; you're in the worker seat."* Never proceed from the wrong seat.

Everything below operates on the resolved `$FLEET_REPO` / `$FLEET_MAIN` /
`$FLEET_BASE_BRANCH` — this fleet only.

## 1. Pick the weight — ephemeral vs. scout worker

Two tiers, by weight (full write-up in **[docs/SCOUT.md](../docs/SCOUT.md)**):

- **Ephemeral sub-agent** — a quick, throwaway lookup. Do **not** run this
  command: just fire your own `Explore`/`Agent` sub-agent inline, read its
  answer, and move on. **No issue, no window.** Choose this when the answer is
  small, one-shot, and doesn't need to be durable or linkable.
- **Scout worker** (this command) — a substantial investigation whose report
  should be **durable, linkable, and reachable by the issue-bridge** (follow-up
  questions relay in) and can **convert** cleanly into a ship issue. Choose this
  when the finding is worth tracking.

If the question is clearly throwaway, stop here and run the ephemeral tier
instead. Otherwise continue.

## 2. Ensure the `scout` label exists

The spawn files with `--label scout`; create the label first so the create can't
fail on a missing label (idempotent — a second create is a harmless no-op):

```sh
gh label create scout --repo "$FLEET_REPO" \
  --description "Read-only investigation (no PR expected)" --color 0e8a16 2>/dev/null || true
```

## 3. File the scout issue

Write a concise imperative **title** (prefix it `Scout:` so it reads as an
investigation, ≤ ~70 chars) and a **body** that states the question, that this is
a **read-only investigation** (no PR expected), and that the findings are
expected back **as a comment**. Then create it with the `scout` label:

```sh
gh issue create --repo "$FLEET_REPO" --label scout \
  --title "Scout: <question, imperative>" \
  --body "<the question + any pointers>

_Read-only investigation — no PR expected; findings land as a comment on this issue._"
```

Capture the new number `<N>` from the returned URL.

**Optional — best-fit milestone (live-fetched).** Same rule as `/fleet-new-issue`:
`gh api "repos/$FLEET_REPO/milestones?state=open" --jq '.[].title'`, pick the ONE
open title that best fits, and pass `--milestone "<title>"` **only** if it came
back from that live list. If none fits (or there are none), skip it — never force
a stale name (a bad `--milestone` fails the create).

## 4. Spawn the read-only scout worker

```sh
bash ~/.claude/fleet/bin/dash-issue-session.sh <N> --scout
```

`--scout` seeds the worker to **investigate + report** (not implement): no
branch, no PR, no ship mandate, and its window is marked `@scout`. It enforces
the **global + per-fleet** session caps exactly like a normal spawn — if a cap is
hit it refuses and prints why; **relay that refusal verbatim and do NOT retry or
force it.** The scout's closing move (`/fleet-scout-report`) posts its findings
and self-cleans its window/worktree — there is no PR to land.

## 5. Report (one line)

`#<N> Scout: <title> — read-only scout spawned` (noting the milestone if you
matched one), or the cap refusal. Then stop: the scout owns the investigation;
you are the steward, not the investigator. When its findings land, you decide
whether they **convert to ship work** (file/spawn a normal worker) or the scout
already closed the issue.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. A scout is **read-only**: it never edits the base checkout,
never opens a PR, and self-cleans when done. The base checkout is read-only
(hook-enforced); implementation, when a finding converts to ship work, is a
separate normal worker's job.
