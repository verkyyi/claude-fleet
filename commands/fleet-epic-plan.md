# /fleet-epic-plan — turn a theme into a confirmed, two-layer EPIC

<!-- fleet skill · owner: hub -->

PHASE 1 of the EPIC trio (`/fleet-epic-plan` → `/fleet-epic-run` →
`/fleet-epic-report`). You name a **theme**; this reads the fleet's open issues,
proposes a bounded batch as **one design page** you open in a browser (hosted via
doc-preview, issue #809), and — **only after you say yes** — files ONE parent
`epic` issue whose body is the batch charter, with every member linked as a real
GitHub sub-issue whose body is that member's section of the page. It mutates this
fleet's `$FLEET_REPO` and nothing else, and it mutates **nothing at all** until
you confirm: before the nod the plan exists only in your scratchpad and on the
tailnet.

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

- **0 READY** → carry the screen forward to the page's `#preflight` section (step 4) and plan.
- **1 FIXABLE** → only labels are missing. Do **not** run `--fix` yet. Carry the
  screen to the page's `#preflight` section and put the seed in front of the
  operator as part of the confirmation: seeding creates the WHOLE canonical set,
  and a team repo sprouting a dozen unexplained labels overnight is how an
  operator loses the room.
- **3 BLOCKED** → **stop here** and report the blocking row verbatim. No repo
  permission / no sub-issues API is not something a plan can work around.
- **2** → no fleet resolved; report and stop.

Keep the warning rows (base drift, quota). They are the *"this will hurt"*
column, and whether it hurts enough to wait is the operator's call in step 4.

**The concurrency caps are not this skill's business** (issue #881).
`FLEET_MAX_SESSIONS` / `FLEET_GLOBAL_MAX_SESSIONS` are the operator's own
settings: the preflight's `slots` row only states them, and the plan never
suggests a different value, never asks about one, and never puts one on the page
— not in 开跑前要处理, not in 需要你定的事. The run works inside whatever cap is
set.

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
shippable, each with a one-line scope. They go onto the step-4 page as member
cards marked *new*. **Do not create them yet.** The operator confirming the
list is the same act as authorizing the issues; filing first and asking second is
the thing this skill exists to not do.

## 4. Render the design page — then STOP and wait

The proposal is a **page**, not a terminal screen (issue #809). The operator reads
it on whatever device they have — a terminal long-read on an iPad is where plans
went to die — and the same page is what gets written back after the nod, so the
charter, the member sections and the dependency order are read in one place and
recorded from one place. Build it from the shared frame:

```sh
cat ~/.claude/skills/epic-page/template.html   # the ONE frame plan + report share — keep <style> + ids
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
at round one; rules 0 and 16–23 from issue #929, a page that filled every slot
and was still sent back for its surface). The surface is for someone deciding,
not someone executing — same rules as `skills/epic-page/SKILL.md`'s
「What goes IN the slots」:

0. **动笔前先读一份已批的样例页 — its surface, folds closed.**
   `share.sh --list | grep -i epic` (the header line is the base URL), then
   `~/.claude/fleet/bin/epic-page-surface.sh <base-url>/d/<id>/`. The current
   样例页 is EPIC #787 「Multi-repo fleet」; if its row is gone, the newest approved
   plan page. Write yours to that bar.
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
7. **No keys on the surface** — `C1` / `R1` and source issue numbers appear only
   inside a card's 技术细节 (its 编号 / 来源 field) and in the folded order table.
   Card titles and every cross-reference on the surface use the member's
   **name**. The parent's `- [ ] **C1** #N` list and `/fleet-epic-run`'s parsing
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
    and **only when there is something to handle** (issue #929): FIXABLE, or a
    warning the 发起人 has to act on. READY with nothing to do ⇒ drop the whole
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
   sentence of 解决什么**; the card IS the sub-issue body later.

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
   first **编号 / 来源** — the key and where it came from (`C1 · 已有 #N` /
   `C2 · 拆自 #N` / `C3 · 新建`, a proposed split from step 3) — then the five
   fields exactly as before, none of them shortened:
   - **方案** — 改哪里、怎么改: the files / scripts / surfaces and the shape of the
     change. Enough that a worker starts from the code, not from a re-read.
   - **接口 / 约定** — what it exposes or promises the others: a helper name, a
     conf key, a file layout, a marker. This is the horizontal information the
     old charter kept as one line in "共同约定 7"; it belongs on the member.
   - **依赖** — who it waits for, who waits for it (keys are fine down here).
   - **完成判据** — testable acceptance.
   - **上线证据** — **ONE line a worker and the report can both follow**: which
     URL to screenshot, which command's output to keep, which pane to
     `capture-pane`. E.g. *`tmux capture-pane -p` of the dash after `⌃r`, showing
     the `rNm` marker*; *截图 `/solutions/space` 首屏 (匿名态)*; *`curl -s …/api/x |
     jq .count` 的输出*. This line is `/fleet-epic-report`'s input (issue #810):
     the worker reads it with `bin/fleet-evidence.sh line` and captures 改动前 /
     改动后 along it before landing, the report shows those side by side in the
     member's card. Write it so neither has to ask.

   **Reserve items left untouched do not count as unfinished** — they exist so a
   batch that runs faster than expected does not idle, not to inflate the scope.
4. **`#risks`** — **可能出的问题**: each risk one plain sentence,
   「会出什么事 — 我们怎么兜住」. The technical risks and **why this split** (which
   seams, what was too big, what was left whole) go into its fold.
5. **`#signoff`** — **需要你定的事** (the `#open` anchor lives here too): one table,
   事项 / 建议, **every row with a default recommendation**, phrased so that
   nodding settles it; 「（批后）」 on an item decided only after approval. One
   line under it: 「点头即全部按建议。」 After the nod these are recorded with the
   date and workers do not re-open them — the section is the template for what
   #7773's charter did by hand.
6. **`#preflight`** — **omitted when there is nothing to handle** (rule 12).
   Otherwise **能不能开跑**: one sentence — can it run, and what to
   handle first. The step-1 screen, verbatim, in the fold, plus (on FIXABLE) the
   labels `--fix` would seed.
7. **`#order`** — the whole section folded, last: **执行安排** — waves, who waits
   for whom, what runs in parallel. A table is enough; draw an inline SVG (load the
   `dataviz` skill first) only when the graph has real branches. 「先后」 never
   appears on the surface.

Self-check the surface (rule 23), fix what it shows, then host it and put
**one URL + one sentence** in front of the operator:

```sh
~/.claude/skills/doc-preview/share.sh <scratchpad>/epic-plan-<slug>.html   # → READY <url>
```

*"设计方案页 <READY url> — 要做的事 N · 有空再做 M · 指标 j 条（或「本批不量」）·
开跑前要处理 w（为 0 时不写）。改哪条直接说；点头即全部按建议，照页面建单。"* On a fleet that runs tap-first (`FLEET_TAP_FIRST=1`), the nod is a
bounded choice — an `AskUserQuestion` menu of *照页面建单 / 改清单 / 放弃* is the
right shape; keep free text for what they want changed.

Then **stop and wait**. No issue is created, no label is seeded, no worker is
spawned until the operator answers — `gh issue list` must show nothing new. If
they change the list, **edit the same file and re-render the same URL**:

```sh
~/.claude/skills/doc-preview/share.sh --refresh   # same URL; their open tab is now current
```

Never `share.sh <file>` a second time for a revision — every call APPENDS a new
row with a new URL, and the operator ends up with three tabs of the same plan
(the share list on this machine shows exactly that). The loop here is cheap and
the alternative is a batch nobody chose.

Deliberately **not** on the page: an estimate in hours or tokens. This fleet has
no session→spend join yet (issue #625), so any number would be invented.
`/fleet-epic-run` extrapolates from the batch's own measured rate once it has
1–2 hours of evidence, and says so then.

## 5. After the nod — file the EPIC from the page

**The page is the single source of truth.** Every body below is transcribed from
the page section by section — not re-drafted from the conversation, which is where
a "small change" agreed in chat and never made to the page goes missing. **Folds
change the page, never the issue** (issue #881): every fold — 怎么量, 共同约定,
技术细节, 更多风险与拆分理由, 预检原文, 执行安排 — is written back in full, in the
same section shape as before, so `/fleet-epic-run` and the workers read exactly
the bodies they always did. Only now, and in this order:

1. **Record the nod on the page** — `#signoff` gets the operator's login and the
   date, and any change they asked for goes into the page first
   (`share.sh --refresh`).
2. **Seed labels** if the operator approved it: `fleet-epic-preflight.sh --fix`.
3. **Create the parent**, labelled `epic`, titled after the theme. Its body is
   the charter, in this shape — the **page URL pinned at the top**, and the
   Core / Reserve list lines in exactly the form `/fleet-epic-run` reads
   (`- [ ] **C1** #N — title`; a proposed split is `#new` until step 4 fills it):

   ```markdown
   > 设计方案页：<READY url>（tailnet 内可达，重启即失效；页面内容已全部写回本 issue 与各子单，页面失效不丢信息）

   ## 主题
   <the page's subtitle>
   ## 范围
   <#charter's 做 items>
   ## 这批不做
   <#charter's 不做 items>
   ## 打算移动的指标
   <ONE markdown table, the surface and the 「怎么量」 fold joined per row, in the
    columns it has always had: 指标 / 现在 / 期望 (= the page's 目标) /
    多久能读出来 / 成员 — then the 读数口径 line(s) under it.
    /fleet-epic-report reads THIS table back row by row; 「本批不量」 when the
    theme brought no diagnosis>
   ## 共同约定
   ## Core — definition of done (the run stops when all are merged)
   - [ ] **C1** #N — title
   ## Reserve — promoted only when the core is done and quota remains
   - [ ] **R1** #N — title
   ## 依赖顺序
   <the #order table, as a markdown table>
   ## 风险与拆分理由
   <the surface risks, then the fold's technical risks + 为什么这样切>
   ## 待决 / open questions
   <every 「（批后）」 row of 需要你定的事: 事项 — 建议>
   <!-- /fleet-epic-run appends here -->
   ## 发起人拍板
   发起人 @login YYYY-MM-DD 拍板，worker 照做，不再讨论方向：
   1. <事项>：<建议>   ← EVERY row of 需要你定的事, 「（批后）」 ones included
   ```

   `## 依赖顺序` is the folded 执行安排 table, keys and all. The page's grouping of
   要做的事 by theme is page-only: the Core / Reserve lists keep their exact
   `- [ ] **C1** #N — title` shape and order-by-key, because that is what
   `/fleet-epic-run` parses.

   ```sh
   gh issue create --repo "$FLEET_REPO" --label epic \
     --title "EPIC: <theme>" --body-file <charter.md>
   ```

   The charter body is load-bearing. `/fleet-epic-run` seeds each worker to read
   the parent before it starts, so a charter edited mid-batch reaches every worker
   still to come without re-dispatching anything.
4. **Give every member its section — both layers.** Each `#members` card becomes a
   markdown body in this shape: the four surface fields first, then the five
   technical ones under a `<details>` that mirrors the page's fold, the **上线证据
   line kept as one line**, and the parent pointer as the footer. The worker gets
   everything it got before #839 — the fold changes the ORDER, never the content.
   The card's page-only bits stay on the page: its one-line summary (the title
   already says it) and its 编号 / 来源 field (the key rides in the
   `fleet:epic-member` marker, the source in the parent's list):

   ```markdown
   ## 目标
   ## 为谁
   ## 解决什么
   ## 怎么算成功

   <details>
   <summary>实现细节（方案 · 接口约定 · 依赖 · 完成判据 · 上线证据）</summary>

   ## 方案（改哪里、怎么改）
   ## 接口 / 约定
   ## 依赖
   依赖 C1 (#N) · 被依赖 C3 (#N) C4 (#N)
   ## 完成判据
   **上线证据**：<the one line, verbatim from the page>

   </details>

   ---
   Part of EPIC #<P>. **Read its charter before starting.** 设计方案页：<url>（tailnet，重启即失效）
   <!-- fleet:epic-member epic=<P> key=C1 -->
   ```

   Two shapes that are load-bearing, not cosmetic:
   - **Write `上线证据` as a LABELLED LINE, not a heading.** `bin/fleet-evidence.sh
     line` reads `上线证据：…` / `evidence: …` (the label, then a colon, then the
     line) first; since #841 it also falls back to a `## 上线证据` heading with the
     text underneath, so bodies filed in the old shape still read — but the fallback
     is a compatibility path for what is already on GitHub, not a second format to
     write. One line, one label, one colon.
   - **Keep the blank lines around the `<details>` tags.** GitHub renders
     `<details>` in an issue body, but without a blank line after `<summary>` the
     markdown inside stops being parsed as markdown.

   - A **proposed split** (`new`) is created with this body (titles in the repo's
     own language — CJK titles survive into window names, issue #579), then its
     number replaces `#new` in the parent's list (`gh issue edit <P> --body-file`).
   - An **existing issue** keeps its own body: **append** the section below it
     (`gh issue view <N> --json body -q .body`, append, `gh issue edit <N>
     --body-file`). The `<!-- fleet:epic-member … -->` marker makes a second
     round replace the section rather than stack another one — never overwrite
     an issue somebody else wrote.
5. **Link every member** as a real sub-issue. The API takes the child's database
   **id**, not its number:

   ```sh
   cid=$(gh api "repos/$FLEET_REPO/issues/<child>" --jq .id)
   gh api --method POST "repos/$FLEET_REPO/issues/<parent>/sub_issues" -f sub_issue_id="$cid"
   ```

   Sub-issues are what make the batch visible: the dash nests them under the
   parent and shows subtree progress, and `run` re-derives its entire state from
   them every tick.
6. **Mark the reserve.** Reserve members are sub-issues too, distinguished in the
   charter's own list — `run` promotes from that list, so it must be in the body,
   not only in this conversation.
7. **Stamp the page** — the eyebrow's 「提案」 becomes `EPIC #<P>`, then
   `share.sh --refresh` once more, so the tab the operator still has open says
   what it became.

## 6. Report (keep it short)

One line: the EPIC number and URL, the design page URL, core/reserve counts, the
preflight verdict, and the single next command — `/fleet-epic-run <N>`. If you
stopped at step 1 (BLOCKED) or step 4 (awaiting the nod — the page URL is the
whole report then), say that instead, with the reason.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. The design page is hosted with doc-preview, never the
Artifact tool (hook-blocked in fleet sessions, issue #526), and lives in your
scratchpad, never in the repo. This skill files issues; it never edits code,
opens a PR, or spawns a worker — spawning is `/fleet-epic-run`'s job, and the
split between them is what keeps "deciding the batch" a waking-hours act and
"running it" an unattended one. The base checkout is read-only (hook-enforced).
