# /fleet-epic-run — drive a confirmed EPIC to done, unattended

<!-- fleet skill · owner: hub -->

PHASE 2 of the EPIC trio. Takes an EPIC filed by `/fleet-epic-plan` and pushes it
to completion across many hours and many workers: keeps 4–6 workers busy, answers
what it is allowed to answer, lands green PRs, reclaims finished slots, rides out
quota ceilings, and stops when the core layer is empty. It mutates this fleet's
repos — the parent's `$FLEET_REPO` and each hosted repo a member is filed in
(issues, PRs, merges) — and this fleet's tmux session (windows).

**Argument** (`$ARGUMENTS`): the EPIC issue number. Optional — with none, resolve
the newest OPEN issue labelled `epic` in this fleet; if there is more than one,
list them and ask rather than guessing which batch the operator meant.

**Which repo** (issues #803, #1942): a fleet may host several repos. An EPIC's
parent lives in ONE of them — `--repo <owner/name>` anywhere in `$ARGUMENTS`
names it; without it the preamble resolves the pane's own repo, else refuses and
lists the choices. Its **members may live in other repos** the fleet hosts: each
is the pair (repo, issue), read off the charter's list (§1 «Members are (repo,
issue)»), and everything done to a member — spawn, verdict, merge, reap, label —
names the member's OWN repo. A one-repo fleet always gets its repo — nothing to
pass, nothing changes.

## 0. Resolve fleet + guard seat (run FIRST, every time)

```sh
source ~/.claude/fleet/bin/fleet-lib.sh
S=$(fleet_current_session); fleet_load_conf "$S"
REPO=$(fleet_target_repo "$S" "<the --repo value, or empty>"); RC=$?   # issue #803
[ "$RC" = 0 ] && fleet_load_repo_conf "$S" "$REPO"   # → that repo's FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH / deploy
SEAT=$(fleet_seat)
PKEY=$(fleet_epic_parent_key "$S" "${FLEET_REPO:-}" <EPIC>)   # issue #1110: this loop's ledger key
echo "repo=${FLEET_REPO:-} main=${FLEET_MAIN:-} base=${FLEET_BASE_BRANCH:-master} seat=${SEAT:-unknown} rc=$RC pkey=${PKEY:-}"
```

- **`pkey=` is the key this loop's children ledger is kept under** (issue #1110)
  — this pane's own key: the scratch (or worker) the loop runs in IS the parent
  every member reports to. **Empty `pkey=` ⇒ STOP** (issue #1355): a hub pane (or
  one whose `$TMUX_PANE` was lost) has no key, and the old fallback — the EPIC's
  own key — named a parent no window answers to, so every report was ledgered and
  never relayed; every spawn now refuses such a parent with exit 4 anyway. Say in
  one line that the loop must run from a scratch pane (dash ⌃s) and stop.
  Use the value it printed — literally — as `<PKEY>` below: every spawn passes it
  as `--origin`, every ledger read and backstop names it.

- **`RC=4` — several repos, none current** (the dash is on `all`): list them
  (`fleet_repos "$S"`) and ASK which one in an `AskUserQuestion` menu — never
  guess — then re-run this block with the answer as `--repo`.
- **`RC=1`** — the named `--repo` is not one this fleet hosts: ABORT in one line.
- From here on **every** `$FLEET_REPO` below is the resolved repo — the
  PARENT's; a member's own repo is `$MREPO` (§1 «Members are (repo, issue)»).
  Every `gh` call names its repo with `--repo` — the hub pane of a multi-repo
  fleet sits in `$HOME`, where a bare `gh` has no repo to infer.
- **The charter's `<!-- fleet:epic repo=… -->` marker** (an EPIC planned since
  #803 has one) must equal `$FLEET_REPO`; a mismatch means this run resolved the
  wrong repo — stop and say so, spawn nothing. No marker: an older EPIC; go on.
- **Carry `--repo "$FLEET_REPO"` in every `/loop` / wake-up prompt** that
  re-enters this skill (`/fleet-epic-run <N> --repo <owner/name>`): the next tick
  resolves the repo afresh, and a hub or scratch pane has no repo of its own.

- **No fleet** → **ABORT**: *"not inside a fleet — run this from a fleet session."*
- **Wrong seat** — `owner: hub`: refuse when `$SEAT` is `worker`. A worker driving
  a batch would be spawning its own siblings.

## 1. The stateless rule — read this before anything else

**Every fact this loop needs lives on GitHub, never in the context window.**

A 12-hour loop outlives any context window, so a loop that remembers is a loop
that dies at the boundary. Therefore:

- **The first command of every tick stamps the heartbeat** (issue #953):

  ```sh
  bash ~/.claude/fleet/bin/fleet-epic-heartbeat.sh <N> --tick <n> --repo "$FLEET_REPO" \
    --landed <k> --members <m> --live <l> --inflight <p> --short <简称>
  ```

  `<l>` is how many member sessions were alive at the LAST tick's read (a member
  window still open, running or waiting), `<p>` how many member PRs were open and
  not yet merged (issue #2247). They decide whether this batch holds the
  machine's upgrade: a mark stamped `--live 0 --inflight 0` — the batch is only
  waiting on the operator — does NOT hold install-sync, so an idle batch never
  keeps the machine on an old version. Leave both off and the mark holds as it
  always did. Never stamp `0 0` while a member is running or a PR is in flight:
  that is exactly what lets the floor move under the batch.

  `<m>` is the charter's Core count, `<k>` how many of them are merged — as of
  the LAST tick's read (the first tick: `--landed 0`, or leave both off). They
  are the badge of this batch's ONE row in the task list (issue #1958): the
  stamp also marks THIS pane's window `@epic <owner/name>#<N>`, so the batch is
  ONE row with its members hanging under it by their `@origin` — another repo's
  member too, tagged with its repo. `--clear <N>` unmarks the window.

  `<简称>` is the charter's `<!-- fleet:epic … short=<简称> -->` (no `short=` —
  an EPIC planned before #2355 — leave the flag off). The stamp renames THIS
  window `<简称>·批次` (issue #2544) when its name is one the fleet gave it
  (`scratch-<N>` …), so five batches at once are five rows like
  `像本地·批次 7/9`, on every machine — never `scratch-3`.

  It rewrites THIS batch's mark, `$FLEET_CONF_DIR/global/epic-running.d/<repo
  slug>-<N>` — one file per batch (issue #2062), so a second loop on this login
  never overwrites yours — and the install-sync daemon (`bin/fleet-install-sync.sh`,
  C3 of #1117) holds the whole version switch while ANY mark on this login is
  fresh (`deferred`, never `switched`). Without it the daemon cannot see this
  batch: between ticks this pane is idle and the workers sit idle while CI runs,
  so no busy gate reads anything but a quiet machine, and the live install moves
  under a batch that is still merging onto it. A lease, not a lock — fresh for
  45 min, past the longest planned gap in step 3 — so a loop that dies without
  its closing tick holds nothing forever; the closing tick clears it (step 4).
  And capped: one mark holds the same stable at most 2 hours
  (`FLEET_EPIC_HOLD_CAP_SECS`); past it install-sync switches anyway and leaves
  a note on this EPIC saying who, when and from which version to which.
- **Each tick begins by re-reading the EPIC** — the parent body (the charter), the
  sub-issue list and their states, and each member repo's open PRs. Never carry
  a plan from the previous tick.
- **Members are (repo, issue)** (issue #1942). The charter's Core / Reserve lines
  are the member list: `- [ ] **C1** #N — title` is a member in the parent's own
  repo, `- [ ] **C1** owner/name#N — title` one filed in another hosted repo.
  `fleet_member_ref "$FLEET_REPO" "<#N | owner/name#N>"` turns either into
  `<repo>\t<N>` — call that repo `$MREPO` below — and the sub-issues come back
  with their repo too (`fleet_sub_issues "$FLEET_REPO" <EPIC>` →
  `<repo>\t<N>\t<state>`; never `.[].number` alone: numbers repeat across repos).
  When the two disagree the LIST wins — a member GitHub would not link across
  repos is still in it (the operator's ruling 4 on EPIC #1935). A member's
  session key is `<slug>:issue-<N>` with ITS repo's slug
  (`fleet_okey_prefix "$S" "$MREPO"`) — what the ledger, the backstop and the
  reap all take.
- **Member state is ONE read: the children ledger** (issue #937/#940). Every
  worker this loop spawns carries `<PKEY>` as its `@origin`, and every
  report it sends is written to this loop's ledger — so the per-member picture is
  one command, not a `gh pr list` plus a `capture-pane` per member:

  ```sh
  bash ~/.claude/fleet/bin/fleet-children.sh "<PKEY>" --json   # {summary, children[{child, bucket, state, pr, pr_state, last, …}]}
  ```

  It merges the ledger with each child's live window state and the dash's PR
  cache, needs no `gh`, and survives the loop's own handoff (the ledger is keyed
  by the parent's key, not its window). Read it FIRST each tick; go to `gh` /
  `fleet-pr-verdict.sh` only for what it cannot say — a PR's merge verdict in
  step 2a, or a member that has never spawned. A `[child-report]` that arrives
  between ticks is a wake-up, not a claim to re-verify: the next tick's ledger
  read already accounts for it.
- **Each tick ends by writing what it did** as one marked comment on the parent:

  ```
  <!-- fleet:epic-tick -->
  tick <n> · <UTC>
  quota: <acct> 5h=<x>% wk=<y>% · <acct> …
  slots: <k>/<cap> · spawned: #… · landed: #… · reaped: #…
  backstop skipped: child busy (<child> <why>)   ← one per held READY PR (step 2a)
  blocked: #… (<why>)
  待决: <question that no charter answer covers>
  report: <pending | the report's URL>      ← closing tick only (step 4)
  ```

  Post it through `~/.claude/fleet/bin/fleet-comment.sh <parent> --repo "$FLEET_REPO" --note --body-file -`,
  never a bare `gh issue comment`: when the account's GraphQL budget is spent the
  wrapper posts the same marked body over REST (issue #1042), where a bare call
  just fails and the tick goes unrecorded.

  The `report:` line appears on the **closing** tick and nowhere else. It is the
  one piece of state that outlives the core going empty, so a session that picks
  this EPIC up after a handoff can tell «核心空了，报告还没跑» from «跑完了» by
  reading it instead of guessing (issue #852).

- **Context full ⇒ `/fleet-handoff`, not a summary.** The handoff doc need only
  say *"driving EPIC #N, re-read it"*; everything else is on the issue. The
  cycle's clear-and-resume is safe here: the stuck-working backstop is pinned to
  fire inside the handoff's idle window by `bin/fleet-handoff-invariant.sh`
  (issue #677), so a fable-capped turn that never fires its Stop hook still gets
  demoted in time to change blood.

If you ever find yourself reasoning from something you remember rather than
something you just read, that is the bug.

## 2. The tick — five things, in this order

### a. Land what is green

Workers land their own PRs once `bin/fleet-pr-verdict.sh` reads `READY`
(issue #441), so this is a **backstop**, not the main path — it catches the worker
that finished and went idle without merging.

For each EPIC member with an open PR (the ledger read above names them):

```sh
bash ~/.claude/fleet/bin/fleet-pr-verdict.sh <PR> --repo "$MREPO" -q    # the member's own repo
```

- `READY` → first ask whether the worker still owns it (issue #921):

  ```sh
  bash ~/.claude/fleet/bin/fleet-epic-backstop.sh <child-key> --pr <PR> --parent "<PKEY>"
  ```

  `READY` is CI green + mergeable — it says nothing about the member's own
  完成判据, which the worker runs locally *after* CI. On EPIC #875 this step
  merged PR #917 while its worker was still `looping` through a 10× loadgen
  acceptance run. Exit `1` prints `backstop skipped: child busy (<child> <why>)`
  — the worker is mid-turn (`working` / `looping` / `waking`) or its turn ended
  with a background job still running (`fleet_child_busy` → `bg`): **don't
  merge**, copy that line into this tick's comment, next tick. A member the
  ledger has no live window for is looked up before it is called gone (issue
  #1110): this fleet's windows by key, then — hub on — the hub's session table
  by (repo, issue), so one running on another machine reads `… hub: working on
  m5` and holds; a hub that has not answered for 10 minutes holds too (`cannot
  rule out a session elsewhere`) — a failed lookup is never "idle". A member on
  another machine is judged by THAT machine's word (issue #1607): its node
  reports a held `/loop` round or a running Bash-tool job on the hub, so
  `… hub: bg on m4` / `… hub: looping on m4` holds exactly as it would here; a
  machine the hub has lost reads `hub: lost on m4` and holds; and with the hub
  off, a member the ledger places on another machine holds (`on m4, hub off:
  cannot see it`) rather than reading as gone. Exit `0`
  (`clear: …` — idle / done, no window here and none on the hub (`hub says
  gone`), or its own MERGED ship report is in the ledger) → merge it, **one command, never chained**:
  `~/.claude/fleet/bin/fleet-pr-merge.sh <PR> --repo "$MREPO" --squash` (re-reads the gate,
  merges with the branch deleted, confirms `MERGED`; under a GraphQL rate limit it merges over
  REST instead of failing, issue #1042). A chained `push --delete` once
  closed the wrong issue and got the worker reaped.
- `BEHIND` → `gh pr update-branch <PR> --repo "$MREPO"`.
- `PENDING` → nothing; next tick.
- `FAILING` / `CONFLICT` → step 2d (it is a failure, not a merge decision).
- `BLOCKED` → branch protection said no. Not yours to force: note it on the
  parent's 待决 and leave it.

A merged PR is not yet *done* if its repo has a deploy signal: with
`FLEET_DEPLOY_REF` or `FLEET_DEPLOY_CHECK` set (issue #541; per repo in a
multi-repo fleet, from its `repos/<slug>.conf` — #805), a member counts as
complete only when its deploy state goes green. With neither set, merged ≡ done.
Do **not** run `/fleet-sync-install` mid-batch — the loop runs on the live install,
and swapping the floor under running workers is how one bad merge takes the batch
with it. Sync once, at the end (step 4). The same rule binds the workers through
`/fleet-claim` (issue #953: on EPIC #883 one synced right after its own merge and
reloaded a daemon under the rest of the batch), and the install-sync daemon holds
off on its own while this loop's heartbeat — or any other batch's on this login —
is fresh (step 1; issue #2062).

### b. Reclaim finished slots

A finished worker holds a slot until something reaps it. Don't wait to be told:
for each member whose PR is MERGED (and deploy-green, if applicable) while its
window still exists, reap it —
`bash ~/.claude/fleet/bin/dash-reap.sh <slug>:issue-<N> --yes` (the member's key,
with its own repo's slug — issue #1942; never a `session:index` or a window
name — those are `refused:target`, exit 4, issue #869) — which records a
`/fleet-history` row before disposing of anything. A member whose window lives
on ANOTHER machine is reaped by the same command (issue #1589): with the hub on,
`dash-reap.sh` asks that machine's node to run the reap there and answers with
its token and exit status (`reaped:*` 0 · `skip:live` 3 with the node's reason ·
`failed:*` 5 = unknown, not a reap — re-check next tick). Never ssh over and set
`TMUX` by hand.

**A member still running its `/loop` is delivered, and KEPT** (issue #1331, the
operator's ruling A on EPIC #1312). Merged is done — the DoD and the closing
tick do not wait for the Loop — but the reap refuses it with `retained:loop`
(its `@loop` mark or loop ledger says a round is pending). That is not a failed
reap: write 「保留：仍在循环」 for that member in the tick line, free nothing,
and move on. The window ends on its own when its Loop stops (`stop:true`,
`CronDelete`, or a wakeup nobody renews), and the cleanup daemon reaps it then
by the ordinary rules. Never clear `@loop` to force a reap.

### c. Refill to 4–6

Count live EPIC worker windows. While under target and the core layer has an
unstarted member, spawn the next one, highest-priority first. The target is 4–6
**within the fleet's existing caps** — `FLEET_MAX_SESSIONS` /
`FLEET_GLOBAL_MAX_SESSIONS` are the operator's settings, and the run never
changes them, suggests changing them, or asks (issue #881). A full cap is
normal: the spawn exits `2` and the next tick retries.

The machine is a cap too (issue #1090): the same exit `2` comes back with
`暂停开新：内存紧张` / `暂停开新：负载过高` on stderr while memory pressure,
free memory or load/core is over its line (`fleet_machine_admit`). Same handling —
stop refilling this tick, say so in the tick's comment, retry next tick; it
resumes on its own when the reading drops. Read it **before** this tick runs any
heavy acceptance of its own (a member's 完成判据 replayed here, a loadgen run, a
full selftest gate) and skip that too while it holds:

```sh
bash -c 'source ~/.claude/fleet/bin/fleet-lib.sh; fleet_machine_admit' || echo 'held — next tick'
```

```sh
AG=$(bash -c 'source ~/.claude/fleet/bin/fleet-lib.sh; fleet_epic_charter_agent "$1" "$2" "$3" "$4"' _ \
       "$FLEET_REPO" "<the charter body this tick read>" "$MREPO" <N>)
bash ~/.claude/fleet/bin/dash-issue-session.sh <N> --repo "$MREPO" --origin "<PKEY>" --title "<the issue's own title>" ${AG:+--agent "$AG"}
```

**Which agent** (issue #2562): the member's own charter row wins — a row ending
`(codex)` / `(claude)` (`- [ ] **C3** #N — 标题 (codex)`) — then the charter's
`<!-- fleet:epic … agent=codex -->`, then nothing: with no `--agent` the spawn
reads the member's `agent:codex` / `agent:claude` label, else the fleet's
`FLEET_AGENT`. `fleet_epic_charter_agent` is that rule — never re-spell it here.
A Codex member on a login with no Codex login is refused (exit 1, `ccquota codex
login` named on stderr) — never opened as Claude: say so on the parent once and
stop refilling that member; the operator logs in or edits the row.

`--repo` is not optional, and it is the MEMBER's repo (issue #1942): a member
filed in repo B opens its session in B even though the parent is A's. A fleet
hosting 2+ repos refuses a spawn without it (exit 1 — `this fleet hosts several
repos`, issue #972), and in a one-repo fleet `$MREPO` is the only repo, so it is
always correct to pass. The child still reports to `<PKEY>` — one loop drives
every repo's members.

**Exit 4 = no live parent** (issue #1355): `<PKEY>` names no live session (this
pane's window closed or lost its key) or the shell lost `$TMUX_PANE`. Nothing was
opened. Never retry with a hand-exported `$TMUX` or a blank `--origin` — that is
exactly the orphan this refuses; re-run step 0 from the loop's own pane.

**Which machine** (issue #1425): with the hub module on (`CCQUOTA_FLEET=1`) the
spawn is `--node auto` by default — after the issue's lease, the hub picks the
least busy of the operator's machines that host the repo, and a member placed on
another machine exits `0` with `#<N> → <machine> (hub operation …) — <reason>` on
stderr: it is spawned, its `[child-report]` comes back to this pane through the
hub. Add `--node local` (or a machine name) only to pin one member. With the
module off nothing changes.

Always the **live install** path (`~/.claude/fleet/bin/…`), never the base
checkout — the checkout's copy defaults the global cap to 8 instead of reading
the installed cap. Pass `--title` so the window says what the work is.

Then READ the outcome, don't assume it: a refusal used to reach the caller as a
bare exit code and a tmux popup nobody was watching (issue #683). Since #683 the
reason is on **stderr** and the exit code names the class — `2` at capacity
(retry next tick), `3` already claimed (a peer holds it — pick the next member,
never `--force` a live claim), `1` infrastructure (stop and say so). Keep the
stderr line beside the number in your tally. Then re-count windows anyway: a
tick that "spawned" three workers and shows three fewer windows than it thinks
has hit a refusal it never read. On a mismatch, say so on the parent and stop
refilling rather than looping on a silent refusal.

Core empty and quota remaining? Promote from the charter's reserve list. Reserve
items never started are **not** unfinished work.

### d. Handle red lights

`bin/tmux-dash-collect.sh` classifies a stuck window into `ask` (a question) and
`perm` (a permission), issue #640/#645 — the window tab shows `?` / `⊘`, the dash
one red `!` with the kind in words (`在问你` / `等授权`, #1328). They get different
treatment:

- **`⊘` permission** → approve it. `bash ~/.claude/fleet/bin/fleet-answer.sh …`
- **`?` question** → answer it **only if the charter already covers it.** The
  charter is the operator's stated intent; answering inside it is relaying, and
  answering outside it is making a product decision they never made. Not covered?
  Append the question to the parent's 待决 section, leave the worker parked, and
  refill its slot with the next member. One batch of 待决 answered at breakfast
  beats a decision made at 03:00 by a loop.

- **A failed worker** (PR red, conflicted, or the window died) → **retry once**,
  seeding the new worker with what went wrong. Second failure: label the member
  `blocked` (`gh issue edit <N> --repo "$MREPO" --add-label blocked`), write the
  reason on the parent, free the slot.

One caution on red: a red check is not always the code's fault. This suite carries
real-time budgets that only hold on an idle box (`CLAUDE.md`, issue #691/#693), so
a red that names a timing assertion on a loaded machine may be the gate, not the
change. Before spending the retry, re-read the failing check: if it is unrelated
to the member's diff, say so on the parent and re-run the check rather than
burning the one retry on a flake. And if the base branch itself is red (the same
check fails on `master`'s head), it is ONE breakage for every member and every
loop: file it once through `~/.claude/fleet/bin/fleet-issue-file.sh --title …
--breakage --spawn --repo "$MREPO"` (issue #2078) — exit 5 + a URL means someone
already did, and a 「同一故障」 comment was left there — then wait for that issue
before retrying any member. Three issues and three conflicting fixes for one
duplicate route (2026-10-07, #2039 #2040 #2041) is what this replaces.

### e. Quota

```sh
bash ~/.claude/fleet/bin/fleet-account.sh quota    # label · 5h% · week% · …
```

Quota is a **rate limiter here, not a target.** The goal is the EPIC finishing;
there is no percentage to hit and no reason to spend quota faster than the work
needs. So:

- An account near its ceiling → `fleet-account.sh migrate` moves work off it.
- **Every account at the ceiling → wait, don't stop.** Drop to a low-frequency
  heartbeat (20–30 min) until a 5h window refreshes, then resume. Waiting for a
  window is progress; it is the batch staying alive across a ceiling, which is the
  whole reason a 12-hour run beats three 4-hour ones.
- A quota read that comes back empty is not a quota of zero (issue #684). Treat an
  empty read as unknown, keep the previous decision, and say so on the tick line.

## 3. The loop

Drive this with `/loop` self-paced: each wake-up is one tick of step 2, and the
next delay is chosen from what you are actually waiting for.

| situation | next tick |
|---|---|
| slots free, work queued | as soon as the spawn settles |
| all slots busy, CI running | 10–20 min |
| every account at its ceiling | 20–30 min, until the window refreshes |
| nothing left but a PR's checks | match the check's own runtime |

Do not poll for things the harness reports on its own; a `Monitor` on a PR's
checks is cheaper and more accurate than a tick that wakes to look.

## 4. Stop — the report is the last tick, not a handoff

**The core layer going empty is not the end of the run. The report is**
(issue #852). Core empty = every core member merged (and deploy-green where the
fleet has a deploy signal), or `blocked` with a reason on the parent. That
condition does not stop the loop; it switches this tick to the closing sequence
below, which **runs in this same hub session, now** — `/fleet-epic-report` is a
hub skill and you are the hub, so there is nothing to hand it to.

Why it is not prose advice: a batch whose report never runs looks, from the
outside, exactly like a batch that finished. The tick log holds the whole
12-hour run and nobody reads it; the page and the parent comment are the only
artefacts that survive the tailnet reboot, the context boundary and the morning.
**An EPIC whose report never ran is not finished** — treat a core-empty EPIC
with no `report:` line the way you would treat an unmerged PR.

The closing sequence, in this order — it is a tick like any other, so it
survives a context boundary the same way everything else here does:

1. **Write the closing tick first, carrying `report: pending`** (step 1's
   format). Before running the report, not after: if this session dies between
   the two, `pending` is what tells the next one there is work left.
2. **Run `/fleet-epic-report <N> --repo "$FLEET_REPO"` right here.** Not «hand off to», not «suggest
   the operator run» — execute it, this tick. It gathers, builds the page, hosts
   it via doc-preview, posts the durable comment, and closes the EPIC when every
   member is resolved. Its own rails still apply; you are just its caller.
3. **Post the URL back on the parent** as one final tick whose `report:` line
   carries the tailnet URL in place of `pending` — one grep now separates a
   reported EPIC from an unreported one. Then push the done notification, with
   the URL in it.
4. **Clear the heartbeat** — `bash ~/.claude/fleet/bin/fleet-epic-heartbeat.sh --clear <N>`
   (issue #953) — `<N>` is this EPIC: it removes THIS batch's mark and no other's
   (issue #2062: a bare `--clear` once took the file every batch on the login
   shared, and the other loop ran unprotected until its next tick). Only now —
   once every batch on this login has cleared its own — may the live install move: the batch-end sync is
   `/fleet-sync-install` by hand, or `fleet-stable.sh move` and every login's
   install-sync daemon follows on its next tick. After the report, not before —
   the closing sequence is one tick, and a floor that moves while the report is
   still building is the mid-batch bug in miniature. A loop that never reaches
   this line leaves a mark that expires on its own, 45 min after its last tick.
5. **Report to whoever started this driver** (issue #2623) — one call, the last
   of the run: `mcp__fleet__report` with `state: merged` and a `summary` that
   carries the report page's URL and what the batch leaves for the person
   (`move stable`, a hub redeploy, a member still blocked). The orchestrator that
   started this driver gets it as a `[child-report]`; with no parent it exits 0
   silently, so it is unconditional. Then stop: the driver's own `done:2h`
   closes it — no `/loop` left armed, no handoff.

**Resuming into a `report: pending`.** The stateless rule (step 1) covers this
with no extra bookkeeping: a tick that re-reads the parent, finds the core empty
and finds `pending` on the newest tick re-enters step 4.2 — it does **not**
refill slots, and it does not start over. Re-running `/fleet-epic-report` is
safe and expected (the skill is built to be re-run — read it), so a duplicated
report is a far cheaper failure than a missing one.

**The report failing is a stall, not a finish.** If the report cannot complete —
doc-preview down, gh refusing, the page unbuildable — leave `report: pending`
standing, say why on the parent, and push the *stalled* notification. Never
write the done notification off a report that did not run.

Push a notification for exactly two things:

- **Done** — the core is empty **and the report has run**: the notification
  carries its URL.
- **Stalled** — every account is at its ceiling with no window in sight, the
  handoff failed to clear, spawning is refusing, the closing report failed, or N
  consecutive ticks made no progress.

Everything else — a single worker's question, one red PR, one reaped window —
goes to the parent's tick log and waits for morning. A batch that wakes its
operator for each worker is a batch that has not been delegated.

## 5. Report (keep it short)

One line per tick in the terminal: tick number, slots, what landed, what blocked.
The durable record is the parent's tick comments — the terminal scrollback is not
where this batch's history lives. The closing tick's line carries the report's
URL, because that is the one thing the operator will want to click.

---

Rails: operate on YOUR fleet's repos only — the parent's `$FLEET_REPO` and the
hosted repos its members are filed in. This skill merges to the base
branch unattended — that is the operator's standing decision, and CI green is its
only gate; `git revert` is the undo. It does **not** run `/fleet-sync-install`
mid-batch. The base checkout is read-only (hook-enforced): workers edit inside
their own `issue-<N>` worktrees and land via PR.
