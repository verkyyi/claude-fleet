---
description: Drive a confirmed EPIC to done, unattended — dispatch its members as child tasks, keep slots full, write the report.
---

# /fleet-epic-run — drive a confirmed EPIC to done, unattended

<!-- fleet skill · owner: hub -->

PHASE 2 of the EPIC trio. The EPIC is a **parent task on the hub** (`T<n>`,
opened by `/fleet-epic-plan`), and this session is that task's session — the
batch's **driver**. Its members are **child tasks** it dispatches: each one a
session in a worktree of its member's repo, bound to its own record, that opens
its PR, merges it once the gate is green and closes its record with its report
(the task flow, issue #4897). This loop keeps 4–6 of them busy, retries a failure
once, answers what the charter already answers, rides out quota ceilings, and
stops when the core is empty — with the report (issue #4957).

**Every session is a window ID** (EPIC T497 C5, docs/dev/FLEET-ID.md): this driver
is the parent ID (`K3F9`, the short code ⌘P shows), each member's session is a
child ID, and a member's **redo is a new ID whose `prev` is the one it replaces** —
so a member is a chain of batons and the tick reads the newest one. Records
(`T<n>`) are still written beside the IDs; the tick reads both. It reads and writes
**the hub only**: no GitHub issue, sub-issue, label or comment anywhere.

**Argument** (`$ARGUMENTS`): ignored except `--task T<n>` (a driver resumed in
another session) — the parent is this session's own record (`@task`), and its
body (the charter, which follows the command in the first message) is re-read
from the hub every tick, never from this conversation.

## 0. Resolve the parent (run FIRST, every tick)

```sh
P=$(bash ~/.claude/fleet/bin/fleet-task-record.sh of) || P=''      # this session's own task
echo "parent=${P:-none}"
python3 ~/.claude/fleet/bin/fleet-epic-tick.py status ${P:+--task=$P} --line   # one word in zsh too
```

- **`parent=none`** and no `--task T<n>` in `$ARGUMENTS` → STOP in one line: a
  batch is driven by its parent task's session — open it with `/fleet-epic-plan`
  (which starts this driver), never from a bare pane. A driver resumed elsewhere
  passes `--task T<n>` explicitly; its dispatches then carry no parent binding, so
  say so on the tick and prefer reopening the parent's own session.
- **The tick exits 3** — no hub here: say so and stop. Never fall back to GitHub.
- **Exits 2** — the record has no charter member list: say which and stop.
- **Exits 1** — the hub did not answer: this is a quiet tick (step 3's
  20–30 min), never a guess from memory.

## 1. The stateless rule — read this before anything else

**Every fact this loop needs lives on the hub, never in the context window.**

A 12-hour loop outlives any context window, so a loop that remembers is a loop
that dies at the boundary. Therefore:

- **Each tick begins with ONE read** — the full picture, as JSON:

  ```sh
  python3 ~/.claude/fleet/bin/fleet-epic-tick.py status --task "$P"
  ```

  `{parent, parent_id, parent_short, mark, title, short, cap, running, free,
  counts, done, members[], next[], no_repo[], last_tick}` — every member of the
  charter (and every child added within scope) with its `state` (succeeded ·
  running · stalled · retry · blocked · waiting · unstarted), its newest baton's `id` /
  `short` (`K3F9`), its `ids` (every baton, a redo's `prev` naming the one it
  replaced), its child tasks, its PR; `waiting` = a member the charter's 依赖顺序
  says waits on one that has not succeeded (`waits_on`) — released by that
  member's newest ID, never dispatched before (拍板 6); a `waits_on` entry
  `T542 C5` is ANOTHER batch's member (that parent's child `C5 · …`), released
  once it succeeded and never by the cycle rule; `next` is exactly what to
  dispatch now (retries first, then unstarted core members, as many as the free
  slots), each with its `title`, `repo`, `agent`, the `body` its session gets and,
  for a retry, the `prev` ID it continues. It reads the hub — the parent's record,
  `GET …/children`, and the ID mirror (`fleet-id.sh family <parent_id>`: this
  machine's ledgers + the hub's) — so it is the same answer after a handoff, a
  compaction or a reboot. A `[child-report]` that arrives
  between ticks is a wake-up, not a claim to re-verify: the next tick's read
  already accounts for it.

- **The first command after the read stamps the heartbeat** (issue #953):

  ```sh
  bash ~/.claude/fleet/bin/fleet-epic-heartbeat.sh "<mark>" --task "$P" --tick <n> \
    --landed <counts.succeeded> --members <counts.core> --live <running> --inflight <running> \
    --short <short> --title "<title>"
  ```

  `<mark>` is the read's `mark` — the parent's ID code `K3F9` (its record
  `T<n>` while it has no ID); `--task "$P"` keeps the record beside it. It marks the batch running on this login (`fleet doctor`'s `epic` row; the
  person's opt-in EPIC hold, off by default — issue #2934) and renames this window
  `<简称>·批次` (issue #2544). A lease, not a lock — fresh 45 min, so a loop that
  dies leaves a mark that expires; the closing tick clears it (step 4).

- **Each tick ends by writing what it did onto the parent** — one progress word,
  never relayed to anyone. With the ID switch on (EPIC T497) it lands on this
  window's own ID — the parent's ID — as a `progress` event on its ledger, pushed
  to the hub mirror (`fleet-id.sh get <ID>` shows it); before the switch the hub
  keeps it as the parent record's `progress`. Same command either way:

  ```sh
  python3 ~/.claude/fleet/bin/fleet_task_control.py progress --event "tick-<n>" --summary \
    "tick <n> · <UTC> · slots <running>/<cap> · 派 <keys> · 合 <keys> · 重试 <keys> · 卡住 <keys> · 待决 <question> · quota <acct> 5h=<x>% wk=<y>% · report: <pending | link>"
  ```

  The `report:` field appears on the **closing** ticks only (step 4). It is the
  one piece of state that outlives the core going empty, so a session that picks
  this batch up after a handoff can tell «核心空了，报告还没跑» from «跑完了» by
  reading `last_tick` instead of guessing (issue #852) — the tick's read gives that
  word's `report:` as `report` (`pending`, or the link), and `last_tick_src` says
  where it came from (`id`, else `record`).

- **Context full ⇒ `/fleet-handoff`, not a summary.** The handoff doc need only
  say *"driving EPIC $P, re-read it"*; everything else is on the hub.

If you ever find yourself reasoning from something you remember rather than
something you just read, that is the bug.

## 2. The tick — four things, in this order

### a. Refill to the cap

For each item of `next`, dispatch it — **one call per member**:

`mcp__fleet-orch__task` with `title` = the item's `title` (`C<k> · <名称>` — the
tick finds the member by that prefix, so never reword it), `repo` = its `repo`
(the member's own repo — a batch may span the fleet's repos, issue #1942),
`body` = its `body` **verbatim** (a retry's ends in `<!-- fleet:prev <ID> -->`: the
spawner records that ID as the new window's `prev`, which is how the redo joins
its member's chain — never strip it), `spawn: true`, and `coding_agent` = its
`agent` when it names one. Because this session carries the parent task, the hub binds the new record
as its child (`parent_task`); its session reports back here.

The first stdout line is the child's `T<m>`. Then record the version it starts on
(issue #2934 — the report says 「本批跨了 K 个版本」):

```sh
bash ~/.claude/fleet/bin/fleet-epic-floor.sh record "$P" <T<m>>
```

READ each outcome, don't assume it: exit `2` at capacity (stop refilling this
tick — the fleet's own caps are the operator's, never changed or questioned, issue
#881), `暂停开新：内存紧张` / `负载过高` on stderr (the machine is held: stop
refilling, say so on the tick), `3` no hub (stop), `1` say why on the tick and
stop refilling. A Codex member on a login with no Codex sign-in is refused, never
opened as Claude: write it on the tick and leave that member. `no_repo` members
are never dispatched — write 「没写仓库：<keys>」 on the tick for the person.

Reserve members (`R<k>`) are never in `next`. Core empty with time and quota left
and a reserve worth doing? Add it within scope by dispatching it under its own key
(`R1 · <名称>`) — the tick counts every child it sees as a member.

### b. Read the results — retries and blocks are the tick's

The workers land their own PRs (merge on green, then `report merged`), so there is
no merge step here: a `succeeded` member is done. A `failed` member is `retry`
once — the next tick's `next` carries it with 「这是重试」, the failed task's
`T<m>` and ID code in its body and its `prev`; seed nothing else by hand. A member
whose window closed with no result (its ID `exited`, its record left open) counts
as a failure the same way — it no longer sits `running` forever. A member someone
continued by hand (「从这一段继续」 in /fleet-history: a new ID, `prev` = the old one,
no record of its own) is read off that newest ID. A second failure is `blocked`: name
it on the tick with the reason its `[child-report]` gave. `cancelled` (the person
stopped it) is `blocked` too — never re-dispatched.

`stalled` (T642) is a member the records call running whose agent never came up
or went down — the wrapper's 「未起来」/「已掉」 on its ID, its window holding only a
shell, or no native session five minutes after its record opened. Its `stall`
carries `{word, why, hint}` (the top-level `stalled[]` lists them all): it keeps
its slot and the batch is not done. Do what the hint says — restart it ON ITS
RECORD (`fleet-task-record.sh respawn T<m> --prev <ID>`, or ↵ on its recovery
page / `fleet-id.sh reopen <code> --exec`), never a new task; put it on the tick
(`未起来 <key>`), and a second stall of the same member is the person's (`ask`).

One caution on red: a red check is not always the code's fault. If the base branch
itself is red (the same check fails on its head), it is ONE breakage for every
member: dispatch its fix once as a task (`mcp__fleet-orch__task`, `repo`, `spawn:
true`, outside this batch — no `C<k>` prefix) and `mcp__fleet-orch__await` its
`T<n>` before the members' retries burn on it.

### c. Questions and permissions

A member waiting on a dialog is answered **only if the charter already covers it**
(`mcp__fleet-orch__answer_dialog`, `by: session`, `basis` = the charter's line). The
charter is the operator's stated intent; answering inside it is relaying, answering
outside it is making a product decision they never made. Not covered? Put the
question on the tick's 待决 and, once per question, `mcp__fleet__ask` (it writes
「问过你」 on this parent task); leave the member waiting and keep the other slots
full. One batch of 待决 answered at breakfast beats a decision made at 03:00 by a
loop.

A member reporting `BLOCKED` on work it found inside the charter's scope: dispatch
that work as a new member (`C<next> · <名称>`, its repo, a body saying which member
waits on it); when it lands tell the waiting one to go on —
`mcp__fleet-orch__send` with `to:` the waiting member's `short` (`K3F9`, the
tick's newest baton — routed by ID: a closed ID's message goes on to the ID that
continued it, docs/dev/FLEET-ID.md). The charter's own 依赖顺序 needs no send: the
tick holds a `waiting` member and puts it in `next` once what it waits on
succeeded. Outside the scope → 待决.

### d. Quota

Not the driver's to watch (T549): a full subscription is the credential pool's to
change, and each session's own 剩余 % is on its window. If a member's session says
it is out of quota, record it on the tick and keep going — never stop the batch
for it, never move the session.

## 3. The loop

Drive this with `/loop` self-paced: each wake-up is one tick of step 2, the next
delay chosen from what you are actually waiting for.

| situation | next tick |
|---|---|
| slots free, work queued | as soon as the dispatches settle |
| every slot running | 10–20 min (a `[child-report]` wakes you sooner) |
| every account at its ceiling, or the hub silent | 20–30 min |
| nothing due — every member left waits on another batch (`T542 C5`), a fix outside the batch, or a person | 20–30 min — **still a wakeup** |

**Waiting is a tick too: every tick that does not close the run ends by arming the
next wakeup** (`ScheduleWakeup`, the same `/loop` prompt), even when nothing is due
and nothing runs (EPIC T497 C18). This window is `reap: loop-end`: a turn that ends
with no wakeup armed IS the loop's end, and the fleet closes the window — on
10-20 T580's driver waited on T497 C16 that way and was reaped mid-batch. There is
no «pause and wait to be told»: the only turn without a wakeup is §4.5's last call.
If a successor window continues this one (`fleet-id.sh continue`), it is the same
driver — it carries the parent `@task`, and the tick reads what any ID of the line
dispatched as the batch's (`lineage` in the status).

## 4. Stop — the report is the last tick, not a handoff

**The core going empty is not the end of the run. The report is** (issue #852).
`done: true` (every core and added member succeeded or blocked, nothing running)
does not stop the loop; it switches this tick to the closing sequence, which runs
**in this session, now**:

1. **Write the closing tick first, carrying `report: pending`** (step 1's
   progress word). Before the report, not after: if this session dies between the
   two, `pending` is what tells the next one there is work left. Name in the same
   word what the batch leaves for a person (a hub redeploy, a real-device check
   with its date) — the report names them again.
2. **Run `/fleet-epic-report` right here** (it reads `$P` the same way). Not «hand
   off to», not «suggest the operator run» — execute it, this tick. It builds the
   page, publishes it to 活页 privately and pushes it to the operator's WeChat.
3. **Write the link back**: one more progress word on the parent whose `report:`
   carries the page's link in place of `pending`.
4. **Clear the heartbeat** — `bash ~/.claude/fleet/bin/fleet-epic-heartbeat.sh --clear "$P"`.
5. **Close the parent task — the last call of the run**: `mcp__fleet__report`
   with `state: waiting`, `outcome: succeeded` (completed work with no PR of its
   own — FLEET-MCP.md «Task children and results»), and a `summary` that carries the
   report's link and what the batch leaves for the person (合 K · 卡住 B, the
   followups). That records the parent's result on the hub and tells whoever
   opened the plan; then stop — no `/loop` left armed, no handoff (`reap:
   loop-end` closes this window).

**Resuming into a `report: pending`.** A tick that reads `done: true` and finds
`report: pending` in `last_tick` re-enters step 4.2 — it does **not** refill
slots. Re-running the report is safe (it republishes to the same page).

**The report failing is a stall, not a finish.** If the report cannot complete —
the page cannot be published, the hub refusing — leave `report: pending`
standing, say why on the tick, `mcp__fleet__ask` the person once, and keep the
parent open. Never close the parent off a report that did not run.

Wake the person for exactly two things: **done** (the report has run — step 4.5's
report carries its link) and **stalled** (every account at its ceiling with no
window in sight, dispatching refusing, the closing report failed, or N ticks with
no progress — `mcp__fleet__ask`). Everything else — one member's question, one
red PR, one retry — goes on the tick and waits for morning.

## 5. Report (keep it short)

One line per tick in the terminal: `fleet-epic-tick.py status --line`'s words. The
durable record is the parent's progress word (on its ID with the switch on, else
its task record) and its children's results on the hub — not the terminal scrollback.

---

Rails: operate on YOUR fleet's repos only — the members' repos the charter names.
Members merge to their base branch unattended on a green gate — the operator's
standing decision; `git revert` is the undo. Never `/fleet-sync-install` mid-batch:
the loop runs on the live install. The base checkout is read-only (hook-enforced):
members edit inside their own worktrees and land via PR.
