# /fleet-epic-report — what the batch actually did, as a page you can read

<!-- fleet skill · owner: hub -->

PHASE 3 of the EPIC trio. Reconstructs a finished (or abandoned) EPIC from
GitHub and the fleet's own records, renders a reader-friendly HTML page, hosts it
on this machine's tailnet, and posts a durable summary back onto the EPIC issue.
Read-only against the repo except for that one closing comment.

**Argument** (`$ARGUMENTS`): the EPIC issue number. Optional — with none, resolve
the most recently updated `epic` issue in this fleet. Works on any past EPIC, not
just the one that just ended, so a report can be re-run after the fact.

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
SEAT=$(fleet_seat)
echo "repo=${FLEET_REPO:-} main=${FLEET_MAIN:-} base=${FLEET_BASE_BRANCH:-master} seat=${SEAT:-unknown}"
```

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
  it (issue #810) — `~/.claude/fleet/bin/fleet-evidence.sh list --epic <N>`
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
(`#delivered` `#metrics` `#members` `#gaps` `#obstacles` `#next` `#ops`), drop the
plan-only ones (`#preflight` `#charter` `#order` `#risks` `#signoff`), and fill
the report-only block inside each member card — the `.proof` grid under its
`上线证据` line (issue #810, below).

**Write it in the order below, and mean the order** (issue #839). A report whose
headline is 「8/8 合并 · 84 分墙钟 · 2 次调度阻塞」 has told the reader that the
machine ran, and nothing about whether it was worth running. The delivery and the
metrics come first; how the batch ran is real, stays complete, and goes **into the
folded `#ops`** at the bottom. **上层不用 fleet 黑话**: 占槽 → 占用时长, reap →
回收, worker → 执行会话 (or just don't mention it), and the mirror ids
(`prod-3a229eb80`) belong in the fold. `C1/C2` keys and PR numbers stay — they are
how a reader gets from the page back to the record.

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
   charter's 打算移动的指标 table (step 1) and fill the 现在 column row by row,
   with the 数据截至 date on the section lede and the 读数口径 line carried over
   verbatim — the same filter rules, or the two numbers are not comparable:

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
3. **成员** (`#members`) — **the same two layers as the design page**: 目标 · 为谁
   · 解决什么 · 怎么算成功 on the surface with the `.proof` grid; PR link, 占用时长,
   mirror id, 方案/接口/依赖/完成判据/上线证据 inside the card's
   `<details class="fold">`. For anything unfinished, *why* — quoted from the tick
   log or the `blocked` reason, not paraphrased — belongs on the surface, not in
   the fold: a reader must not have to click to find out something did not ship.
4. **还差什么** (`#gaps`) — 待部署 / 要人做的 / 没验证的, split by who has to act.
   This is where an honest 「要注册一个全新微信账号才看得到首次种入，本次未造号」
   lives, in those words. Restate 这批不做 here so an out-of-scope item is not read
   as a miss, and repeat that **储备层未动不算欠**.
5. **障碍** (`#obstacles`) — see the split below.
6. **建议下一批** (`#next`) — the theme's leftovers plus what this batch surfaced,
   as input to `/fleet-epic-plan`, **explicitly not a decision**; keep the wording
   that says so.
7. **运行情况** (`#ops`) — **folded, complete, last.** 墙钟 · 执行会话占用时长 ·
   额度曲线（annotated where an account was benched or a window was waited out —
   the waits are where the batch's wall-clock went）· 甘特, plus the PR-merge
   count. Nothing here is cut — including step 1's occupancy-not-tokens caveat,
   which sits beside the numbers it qualifies and **keeps its wording**. Folding
   is about position, not about softening.

**Obstacles split by one test** (issue #839): *would this obstacle still exist in
another repo, on another theme?*

- **No → 产品侧**, it stays in the body, in full: why this change was hard, which
  red was the change and which was the gate, which 待决 parked a member.
- **Yes → fleet 侧** (并发上限, 回收拒收, dash-reap 目标写法, 占用时长口径…) —
  it is a fleet defect, not this batch's story. **File it as an issue on the fleet
  repo** and leave exactly one line in the body: *「fleet 侧问题已开 issue #N #M」*.
  A report whose four obstacles are all fleet plumbing has spent its most valuable
  section on something the reader cannot act on — and the defect gets fixed by
  being an issue, not by being a paragraph.

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
  - **已上线** is yours, once. When the fleet has a deploy signal
    (`FLEET_DEPLOY_REF` / `FLEET_DEPLOY_CHECK`, #541) and the member's deploy state
    is green, capture ONE shot from prod along the same line the worker followed,
    and store it where a re-run of this report finds it again:
    `~/.claude/fleet/bin/fleet-evidence.sh live --issue <M> --epic <N> --note '…' <file>`
    (`-` for a command's output on stdin, `--pane <t>` for a TUI). No deploy
    signal, not yet green, or prod unreachable from this machine → a `.none` cell
    reading **未取到** and the reason. Reachability is an egress fact, not a
    constant: the monorepo's smoke suite says prod needs a China-reachable host,
    while a 2026-09-19 probe from the macbook got HTTP 200 — try once, report what
    happened.
  - **Getting the files into the page**:
    `~/.claude/fleet/bin/fleet-evidence.sh export --epic <N> <dir-of-the-report-html>`
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
「本批未声明指标」） · 还差什么 · 产品侧障碍 + the one fleet-side issue line ·
建议下一批 — then the counts, the completed/unfinished/blocked lists, the run
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
