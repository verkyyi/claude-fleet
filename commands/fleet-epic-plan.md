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
language:

1. **`#preflight`** — the step-1 verdict + every warning row, verbatim, and (on
   FIXABLE) the labels `--fix` would seed.
2. **`#charter`** — theme · scope · what this batch does **NOT** do · the
   conventions every member shares (*"this batch does not change conf format"*).
   Verbatim into the parent body later, so write it for the workers who will read
   it, not for the operator alone.
3. **`#members`** — **one card per member**, core (6–8) first, then reserve
   (8–10), `id="m-<key>"` (`C1`…, `R1`…). Each card carries six fields, and the
   card IS the sub-issue body later:
   - **目标** — what it delivers, one sentence.
   - **方案** — 改哪里、怎么改: the files / scripts / surfaces and the shape of the
     change. Enough that a worker starts from the code, not from a re-read.
   - **接口 / 约定** — what it exposes or promises the others: a helper name, a
     conf key, a file layout, a marker. This is the horizontal information the
     old charter kept as one line in "共同约定 7"; it belongs on the member.
   - **依赖** — who it waits for, who waits for it.
   - **完成判据** — testable acceptance.
   - **上线证据** — **ONE line a worker and the report can both follow**: which
     URL to screenshot, which command's output to keep, which pane to
     `capture-pane`. E.g. *`tmux capture-pane -p` of the dash after `⌃r`, showing
     the `rNm` marker*; *截图 `/solutions/space` 首屏 (匿名态)*; *`curl -s …/api/x |
     jq .count` 的输出*. This line is `/fleet-epic-report`'s input (issue #810):
     the worker reads it with `bin/fleet-evidence.sh line` and captures 改动前 /
     改动后 along it before landing, the report shows those side by side in the
     member's card. Write it so neither has to ask.
   Mark each card `已有 #N` or `new · 拆自 #N` (a proposed split from step 3).
   **Reserve items left untouched do not count as unfinished** — they exist so a
   batch that runs faster than expected does not idle, not to inflate the scope.
   Say so in the section lede.
4. **`#order`** — dependency order: waves, who waits for whom, what runs in
   parallel. A table is enough; draw an inline SVG (load the `dataviz` skill
   first) only when the graph has real branches.
5. **`#risks`** — the risks, and **why this split**: which seams, what was too big,
   what was left whole.
6. **`#open`** — 待决, the questions no charter answer covers. `/fleet-epic-run`
   appends here after filing.
7. **`#signoff`** — 发起人拍板: the decisions this plan asks the operator to make,
   numbered, phrased so that nodding confirms them (*"C3 的视觉方向按样例 A；点头
   即确认"*). After the nod these are recorded with the date and workers do not
   re-open them — the section is the template for what #7773's charter did by
   hand.

Then host it and put **one URL + one sentence** in front of the operator:

```sh
~/.claude/skills/doc-preview/share.sh <scratchpad>/epic-plan-<slug>.html   # → READY <url>
```

*"设计方案页 <READY url> — 核心 N · 储备 M · 新建 k · 预检 READY。改哪条直接说；点头
就照页面建单。"* On a fleet that runs tap-first (`FLEET_TAP_FIRST=1`), the nod is a
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
a "small change" agreed in chat and never made to the page goes missing. Only
now, and in this order:

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
   ## 范围
   ## 这批不做
   ## 共同约定
   ## Core — definition of done (the run stops when all are merged)
   - [ ] **C1** #N — title
   ## Reserve — promoted only when the core is done and quota remains
   - [ ] **R1** #N — title
   ## 依赖顺序
   <the #order table, as a markdown table>
   ## 风险与拆分理由
   ## 待决 / open questions
   <!-- /fleet-epic-run appends here -->
   ## 发起人拍板
   发起人 @login YYYY-MM-DD 拍板，worker 照做，不再讨论方向：
   1. …
   ```

   ```sh
   gh issue create --repo "$FLEET_REPO" --label epic \
     --title "EPIC: <theme>" --body-file <charter.md>
   ```

   The charter body is load-bearing. `/fleet-epic-run` seeds each worker to read
   the parent before it starts, so a charter edited mid-batch reaches every worker
   still to come without re-dispatching anything.
4. **Give every member its section.** Each `#members` card becomes a markdown
   body in this shape — the six fields as headings, the **上线证据 line kept as
   one line**, and the parent pointer as the footer:

   ```markdown
   ## 目标
   ## 方案（改哪里、怎么改）
   ## 接口 / 约定
   ## 依赖
   依赖 C1 (#N) · 被依赖 C3 (#N) C4 (#N)
   ## 完成判据
   ## 上线证据
   <the one line, verbatim from the page>

   ---
   Part of EPIC #<P>. **Read its charter before starting.** 设计方案页：<url>（tailnet，重启即失效）
   <!-- fleet:epic-member epic=<P> key=C1 -->
   ```

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
