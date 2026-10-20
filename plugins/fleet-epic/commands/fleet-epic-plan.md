---
description: Turn a theme into a confirmed, two-layer EPIC — one design page first, the hub's parent task only after you say yes.
---

# /fleet-epic-plan — turn a theme into a confirmed, two-layer EPIC

<!-- fleet skill · owner: hub -->

PHASE 1 of the EPIC trio (`/fleet-epic-plan` → `/fleet-epic-run` →
`/fleet-epic-report`). You name a **theme**; this proposes a bounded batch as
**one design page** you read on your phone or computer, and — **only after you say
yes** — opens ONE **parent task** on the hub (`T<n>`) whose record holds the
batch charter, with every member written into it as its own section. The parent
task's session IS the batch's driver (`/fleet-epic-run`, started by the same
call); each member becomes a **child task** of it when the driver dispatches it
(issue #4957). Nothing goes to GitHub: no issue, no sub-issue, no label, no
comment — the hub's task records are the batch. Until you confirm, nothing is
made at all: the plan exists only in your scratchpad and on the page.

**Argument** (`$ARGUMENTS`): the theme, in your own words — *"让无人值守的失败会
出声"*, *"collect/dash 性能"*, *"额度池化"*. Required: with no argument, ask for
one and stop. Never infer a theme from a backlog; the whole point of a theme is
that it is the operator's judgment about what matters this week, and a cluster the
model picks is a cluster nobody chose.

**Which repo** (issues #803, #1942): a fleet may host several repos, and a
batch's members may change any of them — each member names the ONE repo its code
changes in, and its child task opens a worktree there. `--repo <owner/name>`
anywhere in `$ARGUMENTS` names the batch's default repo (the charter marker's
`repo=`); without it the preamble resolves the pane's own repo, else asks.

## 0. Resolve fleet + guard seat + the hub (run FIRST, every time)

Env vars do NOT persist across separate Bash tool calls — run this once, then
reuse the literal values it prints:

```sh
source ~/.claude/fleet/bin/fleet-lib.sh
S=$(fleet_current_session); fleet_load_conf "$S"
REPO=$(fleet_target_repo "$S" "<the --repo value, or empty>"); RC=$?   # issue #803
[ "$RC" = 0 ] && fleet_load_repo_conf "$S" "$REPO"   # → that repo's FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH
bash ~/.claude/fleet/bin/fleet-task-record.sh authority >/dev/null 2>&1; HUB=$?
echo "repo=${FLEET_REPO:-} main=${FLEET_MAIN:-} base=${FLEET_BASE_BRANCH:-master} rc=$RC hub=$HUB"
```

- **`RC=4` — several repos, none current**: list them (`fleet_repos "$S"`) and
  ASK which one in an `AskUserQuestion` menu — never guess — then re-run this
  block with the answer as `--repo`.
- **`RC=1`** — the named `--repo` is not one this fleet hosts: ABORT in one line.
- **`hub≠0` — no hub here**: an EPIC is a hub task and its members are hub tasks
  (issue #4957); without a hub there is nowhere to record it. Say so in one line
  and stop — never fall back to GitHub issues.
- **No fleet** (`FLEET_REPO` empty) → **ABORT** in one line: *"not inside a fleet
  — run this from a fleet session."* Never guess a repo.

## 1. Can this batch run?

Nothing about the repo has to be checked on GitHub any more. What can hurt is the
fleet's own state — say it on the page, never as a blocker of your own making:

```sh
bash -c 'source ~/.claude/fleet/bin/fleet-lib.sh; fleet_machine_admit' && echo admit || echo 'held now'
```

Keep any warning (the machine held) for the
page's `#preflight` section; whether it hurts enough to wait is the operator's
call in step 4.

**The concurrency caps are not this skill's business** (issue #881).
`FLEET_MAX_SESSIONS` / `FLEET_GLOBAL_MAX_SESSIONS` are the operator's own
settings: the plan never suggests a different value, never asks about one, and
never puts one on the page. The run works inside whatever cap is set; the
charter's `cap=` only says how many members the driver keeps running at once
(default 4).

## 2. Gather what the theme covers

The theme is the operator's. Its members come from what they told you, the code
itself (read it), and anything they point at — a doc, a page, a task `T<n>`
(`fleet-task-record.sh get T<n>`), an old issue link. Read those as INPUT; the
batch is recorded on the hub only, never written back to any of them.

Exclude anything already being worked: a live session on the same thing (ask
`mcp__fleet__status` / the person) is someone's live work, and re-planning it is
how two workers implement the same fix.

For each candidate, note in one line: what it is, which repo its code changes in,
and whether it is one worker's work or several.

## 3. Split what is too big — as a PROPOSAL, make nothing

The unit is **one worker, one PR**. A piece of work that is half a project (a
migration, a subsystem swap) gives you a worker that runs six hours and ships
nothing, which is the single worst outcome for an unattended batch: it holds a
slot, burns a 5h window, and leaves no artifact.

For each oversized one, draft the split — 2–4 members, each independently
shippable, each with a one-line scope. They go onto the step-4 page as member
cards. **Nothing is created yet.** The operator confirming the list is the same
act as authorizing the batch.

## 4. Render the design page — then STOP and wait

The proposal is a **page**, not a terminal screen (issue #809). The operator reads
it on whatever device they have — a terminal long-read on an iPad is where plans
went to die — and the same page is what gets written into the charter after the
nod, so the charter, the member sections and the dependency order are read in one
place and recorded from one place. Build it from the shared frame:

```sh
cat ~/.claude/fleet/plugins/fleet-epic/skills/epic-page/template.html   # the ONE frame plan + report share — keep <style> + ids
```

Write it to your scratchpad (`<scratchpad>/epic-plan-<slug>.html`; **not** into the
repo — this skill ships to team repos and a proposal is not their artifact). Fill
the seven sections; the ids are the contract, the labels follow the theme's
language.

**One page, two layers** (issue #839). The page has two readers and they are not
the same person: the **发起人 / stakeholder** decides whether this batch is worth
running, and the **workers** have to start from it. Serve the decider on the
surface — 用例 · 目标 · 指标, two minutes, no file names and no fleet jargon
(占槽→占用时长, reap→回收, worker→执行会话) — and put every technical field one
click down, in the frame's `<details class="fold">`, default closed and complete.
Nothing is dropped and nothing is summarized away: **the write-back in step 5
transcribes BOTH layers**, so what a worker receives is a field-for-field superset
of what it received before this change.

**The decider's view — the rules** (issue #881: six rounds of 发起人 feedback on
EPIC #883's page, fixed into the frame so the next page starts there instead of
at round one; rules 0 and 16–23 from issue #929, rule 24 from issue #1754, a page that filled every slot
and was still sent back for its surface). The surface is for someone deciding,
not someone executing — same rules as `plugins/fleet-epic/skills/epic-page/SKILL.md`'s
「What goes IN the slots」:

0. **动笔前先读一份已批的样例页 — its surface, folds closed.**
   `~/.claude/fleet/bin/epic-page-surface.sh <an approved page.html>`. The
   样例页 is EPIC #787 「Multi-repo fleet」, else the newest approved plan page you
   have as a file. Write yours to that bar.
1. **Plain words in the number band** — 要做的事 / 有空再做 / 要看的指标 /
   开跑前要处理. Never 核心层 / 储备层 / 新建子单 / 预检警告.
2. **The preflight says only the problem** — one sentence on what to handle
   before the run; the preflight screen itself goes into a fold.
3. **How a number is read is hidden** — 读数口径, the measuring command, paths,
   log names: all in the metrics section's 「怎么量」 fold. No command, path or
   log name anywhere on the surface.
4. **One page shows the whole batch; each item opens on demand** — the member
   list IS the overview (rule 11): every card is one line until tapped, tap once
   for the upper layer, again for 技术细节.
5. **Few words** — a section lede is one sentence or nothing.
6. **Execution detail is folded** — 先后顺序, 依赖, 来源单号, 复读时间 all live in a
   fold; the order section is folded whole and sits last.
7. **No keys on the surface** — `C1` / `R1` and source references appear only
   inside a card's 技术细节 (its 编号 / 来源 field) and in the folded order table.
   Card titles and every cross-reference on the surface use the member's
   **name**. The charter's `- [ ] **C1** <名称>` list and `/fleet-epic-run`'s parsing
   are untouched — this rule is about the page.
8. **有空再做 is a list too** — the reserve is the last group of the same member
   list, same one-line cards.
9. **The metric table is numbers or ranges** — header 指标 / 现在 / 目标, almost
   no words in the cells.
10. **Order: 指标 → 范围 → 要做的事**, and 范围 is short items.
11. **要做的事 and the member cards are ONE list** — grouped by theme (e.g.
    少写文件 / 少起进程 / 看得见 / 有空再做, `<h3 class="grp">`), each card one line
    (名称 + one sentence of 解决什么) until tapped. No separate overview table.
12. **能不能开跑 comes last** among the visible sections — after 需要你定的事 —
    and **only when there is something to handle** (issue #929): a warning the
    发起人 has to act on. READY with nothing to do ⇒ drop the whole
    `#preflight` section AND the band's 开跑前要处理 tile (a 0 says nothing); the
    screen moves to the end of the `#order` fold as 预检原文, so nothing is lost.
13. **范围 in plain words** — short items, no code, no tool names
    (「清掉不用的工作文件夹」「后台少干没用的活」「机器快扛不住时提前提醒」).
14. **Risks in plain words** — each one sentence, 「会出什么事 — 我们怎么兜住」;
    technical risks and 为什么这样切 go into the fold.
15. **待决 + 发起人拍板 = 需要你定的事** — one two-column table 事项 / 建议, and
    **every row carries a default recommendation**; an item that is only decided
    after the batch is approved is marked 「（批后）」. Under the table, one line:
    「点头即全部按建议。」
16. **When the theme is a question, the surface answers it — 先回答.** The
    optional 先回答 slot at the top of `#charter`: a 3–4 row plain table 别人怎么做
    / 我们怎么做, plus 我们的价值 as a few items; sources, links and unverified
    claims in its fold. Research folded away while the surface shows only a task
    list is the miss this rule exists for.
17. **The subtitle says two things** — what this is, and where the batch stops.
    Not a slogan.
18. **Metrics are outcomes the decider can feel and count** — prefer
    **已知 N 种 X → 0** (#787: 「Known ways work leaks across repos 9 → 0」).
    Never a target with no number (「首跑定」), a meaningless one (「> 0」
    「> 现值」), or 现在 / 目标 in different units (「3 处 → 1 行」); no number
    today ⇒ 「本批不量」.
19. **为谁 names a person or role, with a count** — 「你，一个人管 3 个 repo，多数时候
    用 iPad」. Never 「所有 Agent」 / 「维护团队」.
20. **No implementation nouns on the surface** — rule 7 extended from keys and
    file names to technical words: CSP, SDK, 接口, 注入, 渲染, 埋点, 回执, 域名,
    状态码 / 404. A card is named for what the user gets; its sentence is the
    trouble they hit today.
21. **有空再做 only extends the same theme** — unrelated backlog bugs stay on the
    backlog; the 「更多风险与拆分理由」 fold names what was left out and why.
22. **需要你定的事 is real either/or decisions** — one concrete recommendation per
    row, no code, no paths, no parameter spelling. 不做 lives in 范围.
23. **Self-check the surface before sharing** —
    `~/.claude/fleet/bin/epic-page-surface.sh --lint <page.html>` prints the page
    as the decider sees it (folds stripped, each card one line) plus a `WARN`
    line per machine-visible miss. Walk rules 16–22 against that output; a WARN is
    a question, not a verdict, and rules 16, 17 and 21 are yours to read.
24. **A visual member ships a clickable prototype, not a sketch** (issue #1754).
    A member is **visual** when it changes anything the user sees — a dash /
    侧栏 row, the 状态栏, a 弹出菜单, a 网页, a 小程序 page, a report page's
    样式. For each one, build **one single-file HTML prototype** in your
    scratchpad (`<scratchpad>/proto-<slug>-<key>.html`), served beside the
    design page, and put the frame's
    `<p class="proto"><a href="…">▶ 打开可交互原型</a></p>` in that card's
    **upper layer** (under 怎么算成功 — never in the 技术细节 fold). The
    prototype must:
    - use the **real shape of the data** — real rows, names, states; no lorem;
    - **switch the key scenarios** (another device, 失联, 空态, 出错 …);
    - compare **现在 / 改后** side by side or by a toggle;
    - make the main interactions **clickable and keyable**;
    - work at **phone width**;
    - **explain itself** — someone who never opened the design page gets it.

    The 「客户端新建与位置」 prototype is the reference: a dark terminal frame
    whose sidebar, status bar and popup menu are real DOM, scenario + 现在 / 改后
    switches along the top, keyboard and taps both drive it. An ASCII sketch or a
    still screenshot is **not** a delivery. When the design page changes, the
    prototype changes with it — edit the same file, so the link already on
    the page stays valid. `--lint` (rule 23) WARNs
    `prototype` for a card that reads visual (侧栏 / 状态栏 / 菜单 / 页面 / 界面 /
    样式 …) with no such link; a non-visual card that trips it is yours to wave
    through, a visual one is not. At step 5 the link goes into the
    member's charter section beside its 上线证据.

Visible order, top to bottom: title → number band → `#metrics` → `#charter` →
`#members` → `#risks` → `#signoff` → `#preflight` (only with something to
handle, rule 12) → `#order` (folded whole).
The template's file order already is this order — fill it, don't rearrange it.

The sections, as the template lays them out:

1. **`#metrics`** — **指标**: the contract this batch is asking to be judged by
   (issue #839). On the surface a table of **指标 / 现在 / 目标**, numbers or
   ranges only:

   | 指标 | 现在 | 目标 |
   |---|---|---|
   | 已知的「本地好好的，传上去就不行」的情况 | 6 种 | 0 种 |
   | 真实读者 / 30 天 | 62 | > 100 |
   | 新会话启动 | 5–13 秒 | ≤ 6 秒 |

   and in its 「怎么量」 fold, per row: which member moves it (by name, or 全批),
   **多久能读出来**, and the **读数口径** — the data source, the filter rules
   (whose traffic is excluded, how duplicates are dropped, which timezone), the
   exact command. Without the 口径 the report cannot re-read the same number.
   - **The numbers come from the theme's own diagnosis** — whatever the operator
     brought when they named the theme. **No diagnosis ⇒ write 「本批不量」** in
     the 现在 column. Never leave it blank, and **never invent a number**: the
     report reads this table back row by row, so a made-up baseline becomes a
     made-up improvement.
   - A metric may be **batch-level or hang off one member** — both are supported;
     name the member in the fold and make that member's 怎么算成功 point at the
     same row, by the 指标's name.
2. **`#charter`** — **先回答** first when the theme is a question (rule 16; drop
   the slot otherwise), then **范围**: 做 and 不做 as short plain items on the
   surface (the theme itself is the page's title; the subtitle says where the
   batch stops, rule 17); **共同约定** — the conventions every
   member shares (*"this batch does not change conf format"*) — in a fold. It is
   horizontal instruction for the workers and can be as technical as it needs to
   be. All of it goes verbatim into the parent body later.
3. **`#members`** — **要做的事**: one card per member, core (6–8) grouped by theme,
   then reserve (8–10) as the last group 「有空再做」, `id="m-<key>"` (`C1`…,
   `R1`…) — the id carries the key so the page stays addressable, the title does
   not. Each card is a `<details class="card">` whose summary is **名称 + one
   sentence of 解决什么**; the card IS the member's section of the charter later.

   **上层 — 给决定的人** (tap 1), four fields, plain words, no file names:
   - **目标** — what it delivers, one sentence.
   - **为谁** — which real person or role, and how many of them
     (*"在微信里收到成果页的读者（每月约 62 人）"*).
   - **解决什么** — what goes wrong for them today, as they experience it — not
     the code's shortcoming (*"他看完整页，没有任何地方告诉他这东西自己也能做"*).
   - **怎么算成功** — what the decider would look at to believe it worked
     (*"带 utm 的点击从 0 变成有数"*). Where a `#metrics` row covers it, say so —
     that row and this line must not disagree.

   **下层 — 技术细节** (tap 2), inside `<details class="fold">`, default closed:
   first **编号 / 来源** — the key, **the repo its code changes in**, and where it
   came from (`C1 · o/r · 来自 <what the operator pointed at>` / `C2 · o/r · 拆自
   C1 的原题` / `C3 · o/r · 新`; issue #1942). One member, one repo, one worker;
   work that changes two repos is two members. Then the five
   fields exactly as before, none of them shortened:
   - **方案** — 改哪里、怎么改: the files / scripts / surfaces and the shape of the
     change. Enough that a worker starts from the code, not from a re-read.
   - **接口 / 约定** — what it exposes or promises the others: a helper name, a
     conf key, a file layout, a marker. This is the horizontal information the
     old charter kept as one line in "共同约定 7"; it belongs on the member.
   - **依赖** — who it waits for, who waits for it (keys are fine down here).
   - **完成判据** — testable acceptance. **A load criterion names a short,
     bounded run** — `fleet-loadgen.sh 4 300 -- …`, not `8 900` — **or defers to
     the CI runner** (issue #922). The criterion runs on the operator's shared
     machine beside every other fleet's work; an `8 900` did exactly that on
     2026-09-23, took load to 152, and stalled every fleet daemon for 14-20 min.
     Loadgen now refuses on a busy host and clamps to half the cores, so an
     oversized criterion can't be met as written — size it to what it proves.
   - **上线证据** — **ONE line a worker and the report can both follow**: which
     URL to screenshot, which command's output to keep, which pane to
     `capture-pane`. E.g. *`tmux capture-pane -p` of the dash after `⌃r`, showing
     the `rNm` marker*; *截图 `/solutions/space` 首屏 (匿名态)*; *`curl -s …/api/x |
     jq .count` 的输出*. This line is `/fleet-epic-report`'s input (issue #810):
     the worker captures 改动后 along it and puts it in its PR, and the report
     follows the same line. Write it so neither has to ask.

   **Reserve items left untouched do not count as unfinished** — they exist so a
   batch that runs faster than expected does not idle, not to inflate the scope.
4. **`#risks`** — **可能出的问题**: each risk one plain sentence,
   「会出什么事 — 我们怎么兜住」. The technical risks and **why this split** (which
   seams, what was too big, what was left whole) go into its fold.
5. **`#signoff`** — **需要你定的事** (the `#open` anchor lives here too): one table,
   事项 / 建议, **every row with a default recommendation**, phrased so that
   nodding settles it; 「（批后）」 on an item decided only after approval. One
   line under it: 「点头即全部按建议。」 After the nod these are recorded with the
   date and workers do not re-open them.
6. **`#preflight`** — **omitted when there is nothing to handle** (rule 12).
   Otherwise **能不能开跑**: one sentence — can it run, and what to
   handle first. The step-1 screen, verbatim, in the fold.
7. **`#order`** — the whole section folded, last: **执行安排** — waves, who waits
   for whom, what runs in parallel. A table is enough; draw an inline SVG (load the
   `dataviz` skill first) only when the graph has real branches. 「先后」 never
   appears on the surface.

Self-check the surface (rule 23), fix what it shows, then **publish it to 活页,
private** and put it in front of the operator with **one sentence** (issue #4957):

1. `mcp__space__publish_file` — `title` 「EPIC 提案：<主题>」, `filename`
   `epic-plan-<slug>.html`, `content` the page (a page with prototypes beside it:
   `files`, each by its relative path). A new page starts **private** — only the
   operator's workspace can open it; never make it public or passcode-shared
   yourself. Keep the returned `proposal_id` and link.
2. `mcp__space__push_to_wechat` — `proposal_id`, `to` omitted (the operator only).
3. Say: *"设计方案页 <link>（已推到你微信，仅你可见）— 要做的事 N · 有空再做 M · 指标 j 条（或「本批不量」）·
   开跑前要处理 w（为 0 时不写）。改哪条直接说；点头即全部按建议，开父任务开跑。"* On a fleet that runs
   tap-first (`FLEET_TAP_FIRST=1`), the nod is a bounded choice — an
   `AskUserQuestion` menu of *开父任务开跑 / 改清单 / 放弃* is the right shape; keep
   free text for what they want changed.

No 活页 tools in this session (`mcp__space__*` not mounted)? Serve it on
loopback instead — `(cd <scratchpad> && python3 -m http.server --bind 127.0.0.1 <port> >/dev/null 2>&1 &)`
— and open it with the fleet `open` tool (`:<port>/epic-plan-<slug>.html`).

Then **stop and wait**. No task is created and no worker is spawned until the
operator answers. If they change the list, **edit the same file and publish it
again to the same page** (`publish_file` with that `proposal_id`) — the same
link, they reload it. Never a second page for a revision: the operator ends up
with three copies of the same plan.

Deliberately **not** on the page: an estimate in hours or tokens. This fleet has
no session→spend join yet (issue #625), so any number would be invented.

## 5. After the nod — open the parent task from the page

**The page is the single source of truth.** The charter below is transcribed from
the page section by section — not re-drafted from the conversation, which is where
a "small change" agreed in chat and never made to the page goes missing. **Folds
change the page, never the record** (issue #881): every fold — 怎么量, 共同约定,
技术细节, 更多风险与拆分理由, 预检原文, 执行安排 — is written in full. Only now, in
this order:

1. **Record the nod on the page** — `#signoff` gets the operator's name and the
   date, and any change they asked for goes into the page first.
2. **Write the charter** (`<scratchpad>/epic-charter-<slug>.md`) in exactly this
   shape. Its FIRST line tells the driver what to run — plain words, never a
   slash command (T646: a first turn's leading `/fleet-epic-run` is read as a
   command, and a plugin's command is only `/fleet-epic:fleet-epic-run`, so the
   driver's first turn ended at 「Unknown command」 before the model ran; plain
   words reach the model on Claude and Codex alike, and `dash-raw-session.sh`
   rewrites an older charter's bare `/fleet-epic-run` line into them — KEEP IN
   SYNC with its `FLEET_EPIC_RUN_LINE`). The marker and the member lines are what
   `bin/fleet-epic-tick.py` parses every tick — keep them literal:

   ```markdown
   按 fleet-epic-run 的流程驱动这一批：先调用技能 fleet-epic:fleet-epic-run，本条消息下面是这一批的章程。

   <!-- fleet:epic repo=<owner/name> short=<简称> cap=4 -->
   # EPIC: <主题>
   > 设计方案页：<活页 link>（私密）

   ## 主题
   <the page's subtitle>
   ## 范围
   <#charter's 做 items>
   ## 这批不做
   <#charter's 不做 items>
   ## 打算移动的指标
   <ONE markdown table, the surface and the 「怎么量」 fold joined per row:
    指标 / 现在 / 期望 (= the page's 目标) / 多久能读出来 / 成员 — then the 读数口径
    line(s) under it. /fleet-epic-report reads THIS table back row by row;
    「本批不量」 when the theme brought no diagnosis>
   ## 共同约定
   ## 成员
   ### 核心 — definition of done (the batch is done when each is merged or blocked)
   - [ ] **C1** <名称>
   - [ ] **C2** owner/other — <名称> (codex)     ← another repo than the marker's; its agent
   ### 备选 — dispatched only when the person (or the driver, within scope) adds one
   - [ ] **R1** <名称>
   ## 依赖顺序
   <the #order table, as a markdown table — a bare `C4` is THIS batch's member;
    another batch's member carries its parent: `T542 C5` (`T542 C7、C8` — the
    prefix holds until other words or a `+`), released once that member merged>
   ## 风险与拆分理由
   <the surface risks, then the fold's technical risks + 为什么这样切>
   ## 待决
   <every 「（批后）」 row of 需要你定的事: 事项 — 建议>
   ## 发起人拍板
   发起人 <name> YYYY-MM-DD 拍板，worker 照做，不再讨论方向：
   1. <事项>：<建议>   ← EVERY row of 需要你定的事, 「（批后）」 ones included

   ## C1 · <名称>
   <the card, both layers — see below>
   ## C2 · <名称>
   …
   ```

   **Each member's section** (`## C<k> · <名称>`, one per card, core and reserve)
   is what its child task's session receives as its body — the tick hands the
   section verbatim to the dispatch. Both layers, the fold changing the ORDER,
   never the content:

   ```markdown
   ## C1 · <名称>
   **目标** … · **为谁** … · **解决什么** … · **怎么算成功** …
   **方案（改哪里、怎么改）** …
   **接口 / 约定** …
   **依赖** 依赖 C1 · 被依赖 C3 C4
   **完成判据** …
   上线证据：<the one line, verbatim from the page>
   交互原型：<the card's ▶ 打开可交互原型 link — visual members only, drop the line otherwise>
   ```

   - **`上线证据` is a LABELLED LINE** (`上线证据：…`): one line, one label, one
     colon — the worker captures 改动后 along it and the report follows it.
   - `repo=` is the default repo; a member whose code changes elsewhere names its
     repo in its line (`owner/name — <名称>`). A member with no repo at all is never
     dispatched — the tick says 没写仓库.
   - `short=` is the batch's 简称 (issue #2355): 2–4 letters/digits from the theme
     (托管 · 安全 · 上手 · 3秒) — the driver's window wears `<简称>·批次`.
   - `agent=` (optional, issue #2562) is which agent the members run; a line
     ending ` (codex)` / ` (claude)` overrides it for that member. Pick Codex for
     a member that is mostly Go / TS with a test that decides done, or a mechanical
     change, and for new mechanical members while Claude's quota is ≥ 85%.
   - `cap=` is how many members run at once (default 4).
   - The record's body is capped (16 KB with its envelope): a charter over ~12 KB
     moves its longest technical folds to the page and names the page there.

3. **Open the parent task — it starts the driver** (one call):
   `mcp__fleet-orch__task` with `title` 「EPIC: <主题>」, `body` the charter file's
   content, `agent` `epic-driver`, `spawn: true`, `reap` `loop-end`. Its first
   stdout line is the parent's `T<n>`; the driver's window is the batch's parent
   ID (`K3F9` on ⌘P), the one its members' IDs name as `parent` (EPIC T497 C5).
   The driver opens bound to that record — it
   reads the charter off it every tick, its children are this batch's members, and
   its final report comes back here. No hub ⇒ exit 3: say so and stop.
4. **Stamp the page** — the eyebrow's 「提案」 becomes `EPIC <T<n>>`, republished to
   the same page (`publish_file` with its `proposal_id`), so the link the operator
   holds says what it became.

## 6. Report (keep it short)

One line: the parent task `T<n>`, the design page link, core/reserve counts, and
that its driver is running (`/fleet-epic-run` on `T<n>`; the batch shows on the
hub's 任务 page and ⌘P as `T<n>` with the driver's latest tick). If you stopped at
step 0 (no hub) or step 4 (awaiting the nod — the page link is the whole report
then), say that instead, with the reason.

---

Rails: operate on YOUR fleet's repos only — never another fleet's repo, sessions,
or ledgers. Nothing here writes to GitHub. The design page goes to 活页 privately
(or loopback + `open`), never the Artifact tool (hook-blocked in fleet sessions,
issue #526), and its source lives in your scratchpad, never in the repo. This skill
never edits code, opens a PR, or spawns a member — dispatching members is
`/fleet-epic-run`'s job, and the split between them is what keeps "deciding the
batch" a waking-hours act and "running it" an unattended one. The base checkout is
read-only (hook-enforced).
