# /fleet-status — on-demand estate digest for this fleet

<!-- fleet skill · owner: steward -->

A **read-only** snapshot of this fleet's `$FLEET_REPO`: live worker windows and
their state, open PRs awaiting review/merge, ownerless issues, disk + usage
health — capped with a short list of recommended next actions. It **mutates
nothing** (no issues, branches, or PRs). Reading the estate is the steward's
job, so this skill is **steward-only**. Prefer the collector caches under
`$TMPDIR/.claude-dash/` over live `gh` where they exist and are fresh — cheaper,
and it's the same data the dash shows.

**Argument** (`$ARGUMENTS`): none — takes no argument. It always digests the
current fleet.

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
- **Wrong seat** — `/fleet-status` is `owner: steward`. If `$SEAT` isn't
  `steward`, **refuse in one line and stop**, e.g. *"/fleet-status is
  steward-only; you're in the worker seat."* Never proceed from the wrong seat.

Everything below reads from the resolved `$FLEET_REPO` / `$FLEET_MAIN` — this
fleet only.

## 1. Live worker windows

List this session's windows with their per-window state options. Hooks, the
collector, and the pr-refresh daemon (`@prci`) keep these current; querying
options assumes no TTY:

```sh
tmux list-windows -t "$S" -F \
  '#{window_index}#{window_active} #{window_name}  @issue=#{@issue}  state=#{@claude_state}  ts=#{@claude_state_ts}  prci=#{@prci}' 2>/dev/null
```

Report per window: name, `@issue`, `@claude_state`
(`working`/`needs`/`done`/`looping`), staleness (now − `@claude_state_ts`, in
seconds/minutes), and PR/CI glyph (`@prci`). **Skip the panels** — windows named
`dash`, `plan`, `backlog` aren't Claude sessions. Flag anything `needs` or
`looping`, and anything `working` but stale for many minutes.

## 2. Open PRs awaiting review / merge

Prefer the cached PR map (`branch<TAB>#num<TAB>state<TAB>ci`, written by the
pr-refresh daemon), falling back to live `gh` if the cache is missing/stale:

```sh
C="${TMPDIR:-/tmp}/.claude-dash"; slug=$(fleet_slug_cached "$S")
prmf="$C/prmap"; [ -n "$slug" ] && [ -f "$C/prmap_$slug" ] && prmf="$C/prmap_$slug"
if [ -s "$prmf" ]; then cat "$prmf"
else gh pr list --repo "$FLEET_REPO" --state open \
       --json number,title,mergeStateStatus,statusCheckRollup,isDraft; fi
```

List each open, non-draft PR with its number, title, merge/CI state, and call
out which are **green + mergeable** (ready for `/land` or `/merge-train`) vs.
**red / behind / blocked**.

## 3. Ownerless issues + stuck work

Prefer the issues cache (`milestone<TAB>#num<TAB>assignee<TAB>title`); fall back
to `gh`:

```sh
issf="$C/issues"; [ -n "$slug" ] && [ -f "$C/issues_$slug" ] && issf="$C/issues_$slug"
if [ -s "$issf" ]; then cat "$issf"
else gh issue list --repo "$FLEET_REPO" --state open \
       --json number,title,assignees,milestone; fi
```

Surface open issues with **no assignee** (backlog needing a worker) and any
window stuck on `needs`/`looping` from step 1.

## 4. Disk + usage health

```sh
bash ~/.claude/fleet/bin/fleet-diskguard.sh --free    # free GB on the volume backing $TMPDIR
cat "$C/usage" 2>/dev/null                             # token-consumption proxy (5h / 7d), if the collector wrote it
```

Note low disk (near the diskguard floor) and heavy token usage — both are
reasons to hold off spawning more sessions.

## 5. Report — digest + recommended next actions

Print a tight digest (windows, PRs, ownerless issues, health), then end with a
short **recommended next actions** list, e.g.:

- "PR #61 green → `/land 61`"
- "issue #58 unassigned → spawn a worker"
- "window `issue-42` looping 20m → check in"
- "disk 6GB free (floor 5) → don't spawn"

Keep it short and scannable. This skill only *reports* — it never acts; the
steward decides what to do next.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. `/fleet-status` is read-only: it must not open, edit,
merge, or comment on anything. Implementation and merges are separate skills
(`/claim`, `/ship`, `/land`).
