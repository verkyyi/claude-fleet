# /fleet-epic-plan — turn a theme into a confirmed, two-layer EPIC

<!-- fleet skill · owner: hub -->

PHASE 1 of the EPIC trio (`/fleet-epic-plan` → `/fleet-epic-run` →
`/fleet-epic-report`). You name a **theme**; this reads the fleet's open issues,
proposes a bounded batch, and — **only after you say yes** — files ONE parent
`epic` issue whose body is the batch charter, with every member linked as a real
GitHub sub-issue. It mutates this fleet's `$FLEET_REPO` and nothing else, and it
mutates **nothing at all** until you confirm.

**Argument** (`$ARGUMENTS`): the theme, in your own words — *"让无人值守的失败会
出声"*, *"collect/dash 性能"*, *"额度池化"*. Required: with no argument, ask for
one and stop. Never infer a theme from the backlog; the whole point of a theme is
that it is the operator's judgment about what matters this week, and a cluster the
model picks is a cluster nobody chose.

## 0. Resolve fleet + guard seat (run FIRST, every time)

Env vars do NOT persist across separate Bash tool calls — run this once, then
reuse the literal values it prints:

```sh
source ~/.claude/fleet/bin/fleet-lib.sh
S=$(fleet_current_session); fleet_load_conf "$S"   # → FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH
SEAT=$(fleet_seat)                                 # → worker | "" (the hub pane / a stray shell)
echo "repo=${FLEET_REPO:-} main=${FLEET_MAIN:-} base=${FLEET_BASE_BRANCH:-master} seat=${SEAT:-unknown}"
```

- **No fleet** (`FLEET_REPO` empty) → **ABORT** in one line: *"not inside a fleet
  — run this from a fleet session."* Never guess a repo.
- **Wrong seat** — this is `owner: hub`: refuse when `$SEAT` is `worker`, in one
  line: *"/fleet-epic-plan is hub-only; you're in a worker pane."* A worker
  planning a batch is a worker deciding its own scope.

## 1. Preflight — can this repo run an EPIC at all?

`/fleet-epic-*` is a **generic** fleet skill: it ships to every fleet and may
assume nothing about the target repo. Ask before planning, not at 03:00:

```sh
bash ~/.claude/fleet/bin/fleet-epic-preflight.sh; echo "verdict=$?"
```

Branch on the exit code — it is the whole point of the script:

- **0 READY** → carry the screen forward to step 4 and plan.
- **1 FIXABLE** → only labels are missing. Do **not** run `--fix` yet. Carry the
  screen to step 4 and put the seed in front of the operator as part of the
  confirmation: seeding creates the WHOLE canonical set, and a team repo sprouting
  a dozen unexplained labels overnight is how an operator loses the room.
- **3 BLOCKED** → **stop here** and report the blocking row verbatim. No repo
  permission / no sub-issues API is not something a plan can work around.
- **2** → no fleet resolved; report and stop.

Keep the warning rows (base drift, slots, quota). They are the *"this will hurt"*
column, and whether it hurts enough to wait is the operator's call in step 4.

## 2. Read the backlog inside the theme

```sh
gh issue list --repo "$FLEET_REPO" --state open --limit 100 \
  --json number,title,labels,createdAt,body
```

Select the ones the theme actually covers. Two rules:

- **The theme decides, not the label.** Labels in a mature backlog describe kind
  (`bug`, `robustness`), not batch. Read the titles and enough of each body to
  know what the work IS.
- **Exclude anything already claimed.** An issue with an assignee, or with an
  open PR, is someone's live work — `gh issue view <N> --json assignee` and the
  repo-wide `gh pr list`. Re-planning live work is how two workers implement the
  same fix.

For each survivor, note in one line: what it is, and whether it is one worker's
work or several.

## 3. Split what is too big — as a PROPOSAL, file nothing

The unit is **one worker, one PR**. An issue that is half a project (a migration,
a subsystem swap) gives you a worker that runs six hours and ships nothing, which
is the single worst outcome for an unattended batch: it holds a slot, burns a 5h
window, and leaves no artifact.

For each oversized issue, draft the split — 2–4 children, each independently
shippable, each with a one-line scope. Write them into the step-4 proposal as
*proposed sub-issues*. **Do not create them yet.** The operator confirming the
list is the same act as authorizing the issues; filing first and asking second is
the thing this skill exists to not do.

## 4. Propose the two-layer batch — then STOP and wait

Put ONE screen in front of the operator:

- **Preflight verdict** + any warning rows, and (on FIXABLE) the labels that
  `--fix` would seed.
- **Core, 6–8 items.** This layer IS the definition of done: `/fleet-epic-run`
  stops when the core is empty. Each line: `#N` (or *new*) · one-line scope ·
  whether it is an existing issue or a proposed split.
- **Reserve, 8–10 items.** Same theme, pulled up automatically when the core
  finishes and quota remains. **Reserve items left untouched do not count as
  unfinished** — they exist so a batch that runs faster than expected does not
  idle, not to inflate the scope.
- **The charter**, drafted: the batch's scope, what it explicitly does NOT do, the
  conventions every member shares (*"this batch does not change conf format"*),
  and an empty **待决 / open questions** section for `run` to append to.

Then **stop and wait**. No issue is created, no label is seeded, no worker is
spawned until the operator answers. If they change the list, redraft and ask
again — the loop here is cheap and the alternative is a batch nobody chose.

Deliberately **not** reported: an estimate in hours or tokens. This fleet has no
session→spend join yet (issue #625), so any number would be invented.
`/fleet-epic-run` extrapolates from the batch's own measured rate once it has
1–2 hours of evidence, and says so then.

## 5. After the nod — file the EPIC

Only now, and in this order:

1. **Seed labels** if the operator approved it: `fleet-epic-preflight.sh --fix`.
2. **Create the parent**, labelled `epic`, titled after the theme. Its body is
   the charter from step 4 — verbatim, because every worker will read it:

   ```sh
   gh issue create --repo "$FLEET_REPO" --label epic \
     --title "EPIC: <theme>" --body-file <charter.md>
   ```

   The charter body is load-bearing. `/fleet-epic-run` seeds each worker to read
   the parent before it starts, so a charter edited mid-batch reaches every worker
   still to come without re-dispatching anything.
3. **Create the proposed splits** as ordinary issues (titles in the repo's own
   language — CJK titles now survive into window names, issue #579).
4. **Link every member** as a real sub-issue. The API takes the child's database
   **id**, not its number:

   ```sh
   cid=$(gh api "repos/$FLEET_REPO/issues/<child>" --jq .id)
   gh api --method POST "repos/$FLEET_REPO/issues/<parent>/sub_issues" -f sub_issue_id="$cid"
   ```

   Sub-issues are what make the batch visible: the dash nests them under the
   parent and shows subtree progress, and `run` re-derives its entire state from
   them every tick.
5. **Mark the reserve.** Reserve members are sub-issues too, distinguished in the
   charter's own list — `run` promotes from that list, so it must be in the body,
   not only in this conversation.

## 6. Report (keep it short)

One line: the EPIC number and URL, core/reserve counts, the preflight verdict, and
the single next command — `/fleet-epic-run <N>`. If you stopped at step 1 (BLOCKED)
or step 4 (awaiting confirmation), say that instead, with the reason.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. This skill files issues; it never edits code, opens a PR, or
spawns a worker — spawning is `/fleet-epic-run`'s job, and the split between them
is what keeps "deciding the batch" a waking-hours act and "running it" an
unattended one. The base checkout is read-only (hook-enforced).
