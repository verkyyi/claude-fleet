---
description: What the batch actually did, as a page you can read — 改动前 / 改动后 / 已上线 per member.
---

# /fleet-epic-report — what the batch actually did, as a page you can read

<!-- fleet skill · owner: hub -->

PHASE 3 of the EPIC trio. Reconstructs a finished (or abandoned) EPIC from the
hub — its parent task (its code `K5H0`, the charter and the driver's ticks) and its child
tasks (the members' results) — plus the fleet's own records, renders a
reader-friendly HTML page, **publishes it to 活页 privately and pushes it to the
operator's WeChat**, and writes the link back onto the parent task (issue #4957).
Nothing is read from or written to GitHub issues; a member's PR is linked as its
child task recorded it.

**Argument** (`$ARGUMENTS`): the parent task's code (`T<n>` read one more version).
Optional — with none, this
session's own task (`fleet-task-record.sh of`: the driver's closing tick runs it
that way). Works on any past EPIC, not just the one that just ended, so a report
can be re-run after the fact.

**Its usual caller is not a human.** `/fleet-epic-run`'s closing tick runs this
skill itself, in the driver's session, the moment the core empties (issue #852) —
a batch is not finished until it has. So this skill is **re-runnable and
self-contained**: it rebuilds everything from the hub on every run and republishes
to the same page, which is why a resumed loop re-entering the closing tick can
just call it again. Being run by hand — on this EPIC or a two-week-old one — is the
same code path, not a special case.

**Re-run it in two weeks.** Most of what a batch was *for* cannot be read on the
day it ends — a metric with a 「2 周」 horizon is still blank when the last PR
merges. That is not a reason to skip the metric or to invent one: write 「还读不
出来，⟨date⟩ 再看」, and on that date run `/fleet-epic-report <code>` again. Say this at
the bottom of the page too, with the date, so the operator knows to come back.

## 0. Resolve the parent (run FIRST, every time)

```sh
P=<the code argument, or empty>
[ -n "$P" ] || P=$(bash ~/.claude/fleet/bin/fleet-task-record.sh of) || P=''
echo "parent=${P:-none}"
python3 ~/.claude/fleet/bin/fleet-epic-tick.py status --task "$P"          # the members, their results, their PRs
bash ~/.claude/fleet/bin/fleet-task-record.sh get "$P"                       # the charter (request_payload.body); the last tick is the status' last_tick
```

- **`parent=none`** → ask which task and stop; never guess.
- **The tick exits 3** (no hub) or **2** (not an EPIC parent, or a code naming
  several tasks) → say so and stop.
- **Exits 1** (the hub did not answer) → the report cannot be rebuilt now: say so;
  a driver leaves its `report: pending` standing.

## 1. Gather — seven sources, no invention

- **The parent**: the charter (its record's dispatch body), its ticks — the
  driver's progress words (the newest is the status' `last_tick` — the parent ID's
  progress word with the ID switch on, else `progress` on its record; each child's
  `[child-report]` and the ticks in this session's own scrollback when you are the
  driver), and the charter's 待决 section.
- **The metric contract** (issue #839): the charter's **打算移动的指标** table —
  指标 / 现在 / 期望 / 多久能读出来, plus the 读数口径 line under it, written by
  `/fleet-epic-plan` before the batch ran. This is what the batch asked to be
  judged by, and step 2 reads it back **row by row**. Two honest outcomes when it
  is absent: a batch planned before #839, or one whose theme brought no
  diagnosis, has **no table** — report 「本批未声明指标」 and stop there. **Never
  reconstruct a baseline after the fact**: a "现在" measured today against a
  "之前" nobody wrote down is a number the next batch would be planned against.
- **The members**: every member `fleet-epic-tick.py status` lists — the charter's
  core / reserve plus any child added within scope — with its `state` (succeeded ·
  blocked · retry · running · waiting · unstarted), its child tasks (a retried
  member from before the switch has two), its PR (the child's recorded result),
  its `code` — the member's one name (EPIC T644: a redo keeps it, its `attempt`
  says 第几次) — and, for a pre-switch batch, its `ids` (every baton oldest first,
  a redo a new ID whose `prev` names the one it replaced). For a member's why, read its
  child's record (`fleet-task-record.sh get <code>`: outcome, evidence). Its
  charter section carries a **上线证据** line (issue #809): the evidence the
  worker was asked to leave — a URL, a command's output, a pane — and what to look
  for per member (issue #810).
- **The spend proxy**: **worker × hours**, from each member's window lifetime
  (spawn → reap) as recorded in `/fleet-history` and the tick log.
- **The quota trace**: the 5h% / week% snapshots the tick lines carry.
- **The versions it ran on** (issue #2934): installs follow stable even while a
  batch runs, so members spawned later may start on a newer version —
  `~/.claude/fleet/bin/fleet-epic-floor.sh show "$P"` prints
  `versions: K` and one line per version with the members that started on it
  (recorded by `/fleet-epic-run` at each spawn). Spanning versions is allowed,
  never a defect; `versions: 0` = nothing recorded (a batch from before #2934) —
  say so, never guess.
- **The evidence**: what each member looks like, as its own worker showed it in
  its merged PR (the PR body, its screenshots) along the member's `上线证据:`
  line. **Collect, never create** — a member whose PR shows nothing is reported
  as **无证据**, in those words. 占用时长 comes from the member's `/fleet-history
  list` row, not the ticks.

**A hard limit to state plainly in the page, not to paper over:** this fleet
cannot attribute tokens to an issue. There is no session→spend join yet
(issue #625), so "cost per issue" is **worker-hours**, and the quota curve is
**pool-wide** — it includes whatever else ran on those accounts. Say that on the
page. A number presented as a token attribution when it is an occupancy proxy is
worse than no number, because the next batch would be planned against it. Since
#839 this declaration rides in the folded `#ops` section beside the numbers it
qualifies — **folded, not softened**: keep the wording, and never let the
occupancy figure resurface upstairs as a cost.

## 2. Build the page

Before writing any chart, load the `dataviz` skill; before the page itself, load
`artifact-design`. This is a document somebody reads at breakfast, not a log dump.
Start from the shared frame — `cat ~/.claude/fleet/plugins/fleet-epic/skills/epic-page/template.html` —
the same `<style>` and section ids the batch's design page used (issue #809), so
the operator reads plan and report as one document; keep the report's sections
(`#delivered` `#metrics` `#members` `#gaps` `#ops`; `#next` is an anchor inside
`#gaps`), drop the
plan-only ones (`#preflight` `#charter` `#order` `#risks` `#signoff`), and fill
the report-only block inside each member card — the `.proof` grid under its
`上线证据` line (issue #810, below).

**Write it in the order below, and mean the order** (issue #839). A report whose
headline is 「8/8 合并 · 84 分墙钟 · 2 次调度阻塞」 has told the reader that the
machine ran, and nothing about whether it was worth running. The delivery and the
metrics come first; how the batch ran is real, stays complete, and goes **into the
folded `#ops`** at the bottom. **上层不用 fleet 黑话**: 占槽 → 占用时长, reap →
回收, worker → 执行会话 (or just don't mention it), and the mirror ids
(`prod-3a229eb80`) belong in the fold.

**The decider's view holds here too** (issue #881 — the rules `/fleet-epic-plan`
step 4 lists; the report takes five of them):

- **Plain words in the number band** — 上线能力 / 指标已读出 / 未上线 / 还差什么,
  never 核心层 / 储备层 / PR 数.
- **How a number was read is hidden** — 读数口径, commands, paths, log names go
  in the metrics section's 「怎么量」 fold; none of them on the surface.
- **Few words** — a section lede is one sentence or nothing.
- **Execution detail is folded** — PR numbers, merge times, 占用时长, 依赖,
  来源单号, the whole of `#ops`.
- **No keys on the surface** — `C1` / `R1`, a task's code and PR numbers live in a
  card's 技术细节 (its 编号 / 来源 and PR fields); `#delivered`, `#gaps` and
  every card title name the member by its **name**.

Members use the same one-line card as the design page (`<details class="card">`,
grouped by the plan's themes): the summary line is the name, one sentence and the
status pill — and **for anything unfinished that one sentence is the why**, so a
reader never has to open a card to learn something did not ship.

**已合并，仍在循环** (issue #1331) is a status of its own: a member whose PR merged
while its session still runs a `/loop` (watching production, a metric, a deploy).
Merged is delivered — it counts as done in the band — but the reader must see that
something of this batch is still running: a succeeded member whose child's live
word (`fleet-task-record.sh get <code>` → `live.state`) reads `looping` →
pill 「已合并，仍在循环」; anything else → 「已合并」.

What earns its place, in page order:

1. **交付了什么** (`#delivered`) — **first, and in the reader's words**: what a
   user can do now that they could not before. Not PR counts, not member counts —
   the capability, who it is for, and whether it is live or merely merged. This
   is the section a stakeholder reads if they read exactly one, and it is where
   the old verdict's one real question goes: **did the batch achieve the thing the
   charter said?** The counts behind it did not disappear — completed /
   unfinished / blocked live in the band above the fold and in `#gaps`, and the
   run figures in `#ops` — they just stopped being the headline.
2. **指标怎么样** (`#metrics`) — **the effect, before the verdict.** Take the
   charter's 打算移动的指标 table (step 1) and fill it row by row — on the surface
   **指标 / 之前 / 现在 / 目标**, numbers or ranges only, with the 数据截至 date as
   the section's one-line lede; the 读数口径 line carried over **verbatim** into the
   「怎么量」 fold — the same filter rules, or the two numbers are not comparable:

   ```
   说好要移动的指标                     数据截至 2026-10-04（批次后 14 天）
     真实读者/30天    62 → 149        ↑ 140%
     读者转作者       0 人 → 3 人      ↑ 首次 >0
     产品入口点击     0 → 88           ↑ 首次有数
     空工作区占比     78/104 → 未量    本批未覆盖存量，仅新建生效
   ```

   Three outcomes, all of them honest, none of them a blank:
   - **Readable now** → the number, and the delta.
   - **Not readable yet** (the usual case on the day a batch ends) → 「还读不出来，
     ⟨date⟩ 再看」 with the horizon the plan gave it. Better than a number nobody
     measured, and better than silence.
   - **No table** (a pre-#839 batch, or a theme with no diagnosis) → 「本批未声明
     指标」. Do **not** back-fill a baseline — see step 1.
3. **成员** (`#members`) — **the same card as the design page**: one line until
   tapped (name · one sentence · status pill), then 目标 · 为谁 · 解决什么 ·
   怎么算成功 with the `.proof` grid; 编号 (the member's `code`, `K5H0 · 第 2 次`
   on a redo; a pre-switch chain `AAAA → BBBB（重做）` off `ids`) / 来源, PR link, 占用时长, mirror id,
   方案/接口/依赖/完成判据/上线证据 inside the card's `<details class="fold">`.
   For anything unfinished, *why* — quoted from its child's report or the tick that
   blocked it, not paraphrased — is the summary line's sentence, not buried in the
   fold: a reader must not have to click to find out something did not ship.
4. **还差什么 · 下一步** (`#gaps`, carrying the `<span id="next">` anchor) — ONE
   two-column table, **还差什么 | 建议下一步**, one row per gap, **one short clause
   per cell** (issue #929; the layout of EPIC #875's report). The gaps are 待部署 /
   要人做的 / 没验证的 — an honest 「要注册一个全新微信账号才看得到首次种入，本次未造号」
   is a row, in those words — and **an empty kind is no row at all**. The
   next-batch suggestion is a row too (「下一批主题：…」), not a list of its own:
   the theme's leftovers plus what this batch surfaced, as input to
   `/fleet-epic-plan`. **No lede, no trailing note** — no 这批不做 (the charter
   carries it), no 有空再做未动不算欠 (untouched reserve is simply not a row), no
   「建议，不是决定」 (the closing summary may say 下一步是建议). The
   band's 还差什么 = this table's row count.

   **The 列车结果 line on the fleet tooling repo** (issue #4917; it replaced
   #1124's 挪稳定版 row — stable is the release train's to move, never a
   person's followup). ONE read, never a move:

   ```sh
   # the members' merge commits, off the base branch's own history (squash: `… (#<PR>)`) — git, no GitHub API
   git -C "$FLEET_MAIN" fetch -q origin "$FLEET_BASE_BRANCH"
   SHAS=$(for pr in <each succeeded member's PR number in this repo>; do
     git -C "$FLEET_MAIN" log "origin/$FLEET_BASE_BRANCH" -n 1 --format=%H --grep "(#$pr)\$"; done)
   ~/.claude/fleet/bin/fleet-epic-stable-row.sh --repo <the repo> --main "$FLEET_MAIN" \
     --base "$FLEET_BASE_BRANCH" $(printf -- '--merged %s ' $SHAS)
   ```

   Once per repo the members landed in (issue #1942 — stable is per repo; `$FLEET_MAIN` /
   `$FLEET_BASE_BRANCH` from `source ~/.claude/fleet/bin/fleet-lib.sh;
   fleet_load_repo_conf "$(fleet_current_session)" <that repo>`), and only the repo
   carrying `bin/fleet-stable.sh` answers.

   Its `line:` goes into 交付了什么 (page and closing summary) **verbatim**:
   「已随列车上线（stable = <sha7>）」 · 「列车在跑（<run>）」 · 「卡在红车 <run>」 ·
   「等下一趟列车」. Exit 0 also prints a `row:` (the two cells, TAB-separated)
   and its `tr:` — the batch has not shipped yet, so add that row to this table
   verbatim (the `tr:` on the page, the two cells in the closing summary). Exit 1
   with `kind: current` is the line alone; `skip` / `nomerge` is nothing at all.
   A `mark:` (a red train, stable off trunk, unreadable) goes into the closing
   summary verbatim (issue #2672) — a person looks; no `mark:` asks anyone to
   move stable, and **the report never runs a move**.
5. **运行情况** (`#ops`) — **folded, complete, last.** 墙钟 · 执行会话占用时长 ·
   额度曲线（annotated where an account was benched or a window was waited out —
   the waits are where the batch's wall-clock went）· 甘特, plus the PR-merge
   count and one line 「本批跨了 K 个版本」 (each version's short sha and the
   members that started on it, from step 1's `fleet-epic-floor.sh show`; K = 1 is
   「本批在同一版本上跑完」, nothing recorded is 「版本未记录」). Nothing here is cut — including step 1's occupancy-not-tokens caveat,
   which sits beside the numbers it qualifies and **keeps its wording**. Folding
   is about position, not about softening.

**No obstacles section** (issue #929; it was #839's split). The test still sorts
what you found — *would this obstacle still exist in another repo, on another
theme?*

- **Yes → fleet 侧** (并发上限, 回收拒收, 占用时长口径…) — a fleet defect, not this
  batch's story. **Record it as a task** (`mcp__fleet-orch__task`, `repo` the fleet
  repo, no `spawn`: the record waits for whoever picks it up); its code goes in
  the closing summary, never on the page. If the reader should know, it is a 下一步
  row in plain words.
- **No → 产品侧** — what made a member hard lives in that member's card (its
  one-line why, or its fold); what is still missing because of it is a 还差什么
  row.

Item 3 in detail — the evidence grid (issue #810):

- **Per member, 「上线后长什么样」** — inside that member's card (`#members` ›
  `.ob#m-<key>`), under its `上线证据` line, the frame's `.proof` grid: three
  columns **改动前 · 改动后 · 已上线**, each cell an `<img>`, a `<pre>` (a
  command's output, a `tmux capture-pane -p`) or a `.none` placeholder, with the
  capture's note and UTC stamp as the caption. The FORM is whatever the member's
  `上线证据:` line chose (issues #809/#810). A dash before/after pair remains the
  right form for a fleet-side change — one form among several, not the
  definition of "graphically": this skill ships to web products too, and a report
  on one that shows only the dash has shown nothing.
  - **改动前 / 改动后** come from the members' PRs (step 1). A missing stage is a
    `.none` cell reading **无证据**. Do not take a "before" now — the change has
    landed, and the picture would be fiction.
  - **已上线** is yours, once. When the member's repo has a deploy signal
    (`FLEET_DEPLOY_REF` / `FLEET_DEPLOY_CHECK`, #541 — per repo in a multi-repo
    fleet, from its `repos/<slug>.conf`, #805) and the member's deploy state
    is green, capture ONE shot from prod along the same line the worker followed
    and save it beside the report page (`<dir>/evidence/<key>/live-….png`). No deploy
    signal, not yet green, or prod unreachable from this machine → a `.none` cell
    reading **未取到** and the reason — try once, report what happened.
  - **Getting the files into the page**: copy each PR's images into
    `<dir>/evidence/<key>/…` and reference them by RELATIVE path
    (`<img src="evidence/C1/after.png">`); they are published with the page
    (step 3), so the pictures ride along.

## 3. Publish — 活页, private, and the operator's WeChat

**Artifact publishing is hook-blocked inside fleet sessions** (issue #526/#527).
The report goes to 活页 (issue #4957):

1. `mcp__space__publish_file` — `title` 「EPIC 报告：<主题>」; one file
   (`filename` `epic-report-<slug>.html`, `content`) or, with evidence pictures,
   `files` (the page plus each `evidence/<key>/…` by its relative path; a picture
   that is a local file and not text goes by its public URL, else is left out and
   its cell reads **未取到**). A new page starts **private** — only the operator's
   workspace opens it; never make it public or passcode-shared yourself. **A
   re-run republishes to the same page**: find it first (`mcp__space__list_proposals`
   with the title) and pass its `proposal_id`, so the link already written on the
   parent stays the link.
2. `mcp__space__push_to_wechat` — that `proposal_id`, `to` omitted (the operator
   only).
3. **Write the link back onto the parent** — one progress word, on the parent's
   ID with the ID switch on, else its task record (only from
   the parent's own session, i.e. as the driver; run by hand elsewhere, put the
   link in step 5's line instead):

   ```sh
   python3 ~/.claude/fleet/bin/fleet_task_control.py progress --event "report-<YYYYMMDDHHMM>" \
     --summary "report: <link> · 合 K · 卡住 B · 指标 <已读出 / ⟨date⟩ 再看 / 本批未声明>"
   ```

No 活页 tools in this session (`mcp__space__*` not mounted)? Serve the page's
directory on loopback — `(cd <dir> && python3 -m http.server --bind 127.0.0.1 <port> >/dev/null 2>&1 &)`
— open it with the fleet `open` tool (`:<port>/<report.html>`), and say that the
link dies with the session.

The page is the report; there is no separate comment to post. What must outlive
the page — 交付了什么 · 指标 · 还差什么 · 下一步 · the 列车结果 line · the fleet-side
task records · the re-run date — is the **closing summary** the driver puts on its
parent task (`/fleet-epic-run` step 4.5): hand it those lines, in the page's order,
so the record stands on its own without the page. Do **not** commit the report or
the evidence into the repo — this skill ships to team repos too, and a batch
report is not their artifact. Keep the source under
`$FLEET_CONF_DIR/fleets/<sess>/epic/<$P>/`.

## 4. Close the loop

Closing the parent task is the driver's (`/fleet-epic-run` step 4.5 — its result
on its own record). Run by hand, this skill closes nothing: a batch with a member
still `blocked` stays as it is, and the page says which.

## 5. Report (keep it short)

One line: the link, what the batch delivered, where the metrics stand (filled /
「⟨date⟩ 再看」 / 「本批未声明指标」), and the suggested next theme.

---

Rails: operate on YOUR fleet's repos only — the repos its members changed.
Read-only except for the 活页 page and one progress word on the parent task. Never
writes to GitHub. Never invent a number
the fleet cannot measure — an honest worker-hours figure labelled as such beats a
token attribution this fleet has no way to compute.
