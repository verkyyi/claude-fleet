# /fleet-epic-report — what the batch actually did, as a page you can read

<!-- fleet skill · owner: hub -->

PHASE 3 of the EPIC trio. Reconstructs a finished (or abandoned) EPIC from
GitHub and the fleet's own records, renders a reader-friendly HTML page, hosts it
on this machine's tailnet, and posts a durable summary back onto the EPIC issue.
Read-only against the repo except for that one closing comment.

**Argument** (`$ARGUMENTS`): the EPIC issue number. Optional — with none, resolve
the most recently updated `epic` issue in this fleet. Works on any past EPIC, not
just the one that just ended, so a report can be re-run after the fact.

**Which repo** (issue #803): a fleet may host several repos, and an EPIC lives in
ONE of them. `--repo <owner/name>` anywhere in `$ARGUMENTS` names it; without it
the preamble resolves the pane's own repo, else refuses and lists the choices. A
one-repo fleet always gets its repo — nothing to pass, nothing changes.

**Its usual caller is not a human.** `/fleet-epic-run`'s closing tick runs this
skill itself, in the same hub session, the moment the core layer empties
(issue #852) — a batch is not finished until it has. So this skill is written to
be **re-runnable and self-contained**: it rebuilds everything from GitHub and the
fleet's records on every run, which is why a resumed run loop re-entering the
closing tick can just call it again rather than reasoning about whether a report
already exists. Being run by hand — on this EPIC or a two-week-old one — is the
same code path, not a special case.

**Re-run it in two weeks.** Most of what a batch was *for* cannot be read on the
day it ends — a metric with a 「2 周」 horizon is still blank when the last PR
merges. That is not a reason to skip the metric or to invent one: write 「还读不
出来，⟨date⟩ 再看」, and on that date run `/fleet-epic-report <N>` again. It
rebuilds from GitHub and the fleet's records every time, so a second run costs one
command and produces a page whose 指标 section is finally answerable. Say this at
the bottom of the page too, with the date, so the operator knows to come back.

## 0. Resolve fleet + guard seat (run FIRST, every time)

```sh
source ~/.claude/fleet/bin/fleet-lib.sh
S=$(fleet_current_session); fleet_load_conf "$S"
REPO=$(fleet_target_repo "$S" "<the --repo value, or empty>"); RC=$?   # issue #803
[ "$RC" = 0 ] && fleet_multirepo "$S" && fleet_load_repo_conf "$S" "$REPO"   # → that repo's FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH / deploy
SEAT=$(fleet_seat)
echo "repo=${FLEET_REPO:-} main=${FLEET_MAIN:-} base=${FLEET_BASE_BRANCH:-master} seat=${SEAT:-unknown} rc=$RC"
```

- **`RC=4` — several repos, none current** (the dash is on `all`): list them
  (`fleet_repos "$S"`) and ASK which one in an `AskUserQuestion` menu — never
  guess — then re-run this block with the answer as `--repo`.
- **`RC=1`** — the named `--repo` is not one this fleet hosts: ABORT in one line.
- From here on **every** `$FLEET_REPO` below is the resolved repo, and every
  `gh` call names it with `--repo` — the hub pane of a multi-repo fleet sits in
  `$HOME`, where a bare `gh` has no repo to infer.
- **The charter's `<!-- fleet:epic repo=… -->` marker**, when present, must equal
  `$FLEET_REPO` — else stop: a report built from the wrong repo's issue #N is
  a page about someone else's batch.

- **No fleet** → **ABORT**: *"not inside a fleet — run this from a fleet session."*
- **Wrong seat** — `owner: hub`: refuse when `$SEAT` is `worker`.

## 1. Gather — six sources, no invention

- **The parent**: charter, the `<!-- fleet:epic-tick -->` comment stream (the
  batch's own minute-by-minute log), the 待决 section.
- **The metric contract** (issue #839): the charter's **打算移动的指标** table —
  指标 / 现在 / 期望 / 多久能读出来, plus the 读数口径 line under it, written by
  `/fleet-epic-plan` before the batch ran. This is what the batch asked to be
  judged by, and step 2 reads it back **row by row**. Two honest outcomes when it
  is absent: a batch planned before #839, or one whose theme brought no
  diagnosis, has **no table** — report 「本批未声明指标」 and stop there. **Never
  reconstruct a baseline after the fact**: a "现在" measured today against a
  "之前" nobody wrote down is a number the next batch would be planned against.
- **The members**: every sub-issue — state, labels (`blocked` and why), its PR,
  merge time, and deploy state where the fleet has one. A member filed by
  `/fleet-epic-plan` carries a **上线证据** line in its body (issue #809): that
  line names the evidence the worker was asked to leave — a URL, a command's
  output, a pane — and is what to look for per member (issue #810).
- **The spend proxy**: **worker × hours**, from each member's window lifetime
  (spawn → reap) as recorded in `/fleet-history` and the tick log.
- **The quota trace**: the 5h% / week% snapshots the tick lines carry.
- **The evidence**: what each member looks like live, as its own worker captured
  it (issue #810) — `~/.claude/fleet/bin/fleet-evidence.sh list --repo "$FLEET_REPO" --epic <N>`
  prints one row per capture (`member · stage · ts · path · note`) and a `none`
  row for a member with nothing. The stages are `before` / `after` — the
  worker's, taken at the same URL / command / pane the member's `上线证据:` line
  named, before touching code and after the PR was open — and `live`, which is
  yours (step 2). **Collect, never create**: a missing before/after is not
  re-shot and not staged; the member is reported as **无证据**, in those words.

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
Start from the shared frame — `cat ~/.claude/skills/epic-page/template.html` —
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
- **No keys on the surface** — `C1` / `R1` and issue / PR numbers live in a
  card's 技术细节 (its 编号 / 来源 and PR fields); `#delivered`, `#gaps` and
  every card title name the member by its **name**. Fleet-side issue numbers
  appear only in the durable comment (step 3), never on the page.

Members use the same one-line card as the design page (`<details class="card">`,
grouped by the plan's themes): the summary line is the name, one sentence and the
status pill — and **for anything unfinished that one sentence is the why**, so a
reader never has to open a card to learn something did not ship.

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
   怎么算成功 with the `.proof` grid; 编号 / 来源, PR link, 占用时长, mirror id,
   方案/接口/依赖/完成判据/上线证据 inside the card's `<details class="fold">`.
   For anything unfinished, *why* — quoted from the tick log or the `blocked`
   reason, not paraphrased — is the summary line's sentence, not buried in the
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
   「建议，不是决定」 (the durable comment's heading may say 下一步是建议). The
   band's 还差什么 = this table's row count.
5. **运行情况** (`#ops`) — **folded, complete, last.** 墙钟 · 执行会话占用时长 ·
   额度曲线（annotated where an account was benched or a window was waited out —
   the waits are where the batch's wall-clock went）· 甘特, plus the PR-merge
   count. Nothing here is cut — including step 1's occupancy-not-tokens caveat,
   which sits beside the numbers it qualifies and **keeps its wording**. Folding
   is about position, not about softening.

**No obstacles section** (issue #929; it was #839's split). The test still sorts
what you found — *would this obstacle still exist in another repo, on another
theme?*

- **Yes → fleet 侧** (并发上限, 回收拒收, dash-reap 目标写法, 占用时长口径…) — a
  fleet defect, not this batch's story. **File it as an issue on the fleet repo**;
  its number goes in the durable comment, never on the page (「fleet 侧：#N #M」
  was unreadable to the 发起人). If the reader should know, it is a 下一步 row in
  plain words.
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
  - **改动前 / 改动后** come from the workers through `fleet-evidence.sh` (step 1).
    A missing stage is a `.none` cell reading **无证据**. Do not take a "before"
    now — the change has landed, and the picture would be fiction.
  - **已上线** is yours, once. When the member's repo has a deploy signal
    (`FLEET_DEPLOY_REF` / `FLEET_DEPLOY_CHECK`, #541 — per repo in a multi-repo
    fleet, from its `repos/<slug>.conf`, #805) and the member's deploy state
    is green, capture ONE shot from prod along the same line the worker followed,
    and store it where a re-run of this report finds it again:
    `~/.claude/fleet/bin/fleet-evidence.sh live --repo "$FLEET_REPO" --issue <M> --epic <N> --note '…' <file>`
    (`-` for a command's output on stdin, `--pane <t>` for a TUI). No deploy
    signal, not yet green, or prod unreachable from this machine → a `.none` cell
    reading **未取到** and the reason. Reachability is an egress fact, not a
    constant: the monorepo's smoke suite says prod needs a China-reachable host,
    while a 2026-09-19 probe from the macbook got HTTP 200 — try once, report what
    happened.
  - **Getting the files into the page**:
    `~/.claude/fleet/bin/fleet-evidence.sh export --repo "$FLEET_REPO" --epic <N> <dir-of-the-report-html>`
    copies every file to `<dir>/evidence/<M>/…` and prints the same rows with
    RELATIVE paths — reference those (`<img src="evidence/42/after-….png">`).
    doc-preview copies a relative `<img src>` file beside the served page (as it
    already did for Markdown images), so the pictures ride along to the tailnet
    URL. A playwright-MCP screenshot lands under the worktree (`.playwright-mcp/`):
    that is a source to hand to `fleet-evidence.sh live`, not a path to reference.

## 3. Publish

**Artifact publishing is hook-blocked inside fleet sessions** (issue #526/#527) —
use doc-preview, which is the repo-shipped skill for exactly this:

```sh
~/.claude/skills/doc-preview/share.sh <report.html>
```

Relay the READY tailnet URL to the operator.

Then post the **durable half** as one comment on the EPIC issue, **in the page's
order** (issue #839): 交付了什么 · 指标（filled, 「还读不出来 ⟨date⟩ 再看」, or
「本批未声明指标」） · 还差什么 · 下一步（建议） · the fleet-side issues filed
(their numbers — the one place they appear) — then the counts, the completed/unfinished/blocked lists, the run
figures with their caveat, the URL, and per member which evidence exists — the
`dir:` path from its worker's 📎 comment, or **无证据**. The tailnet URL dies with
the next reboot; the comment is what survives, so it must stand on its own without
the page — including the sentence telling the operator to re-run this command on
⟨date⟩ when the metrics can be read. `gh` cannot attach an
image to a comment, so the paths ARE the evidence's durable half; the files stay
under `$FLEET_CONF_DIR/fleets/<sess>/epic/<N>/evidence/`. Do **not** commit the
report or the evidence into the repo — this skill ships to team repos too, and a
batch report is not their artifact (committing evidence under a repo path is a
deliberate opt-in that does not exist yet; follow-up #816).

## 4. Close the loop

If every member is resolved, close the EPIC issue with the summary comment as its
closing note. Leave it open when anything is still `blocked`, and say which.

## 5. Report (keep it short)

One line: the URL, what the batch delivered, where the metrics stand (filled /
「⟨date⟩ 再看」 / 「本批未声明指标」), and the suggested next theme.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only. Read-only except for one
comment (and closing the EPIC when it is genuinely done). Never invent a number
the fleet cannot measure — an honest worker-hours figure labelled as such beats a
token attribution this fleet has no way to compute.
