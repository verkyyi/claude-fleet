---
name: epic-page
description: >-
  The one HTML frame both EPIC pages render into — the design page
  /fleet-epic-plan hosts before the operator confirms a batch, and the batch
  report /fleet-epic-report hosts after it ends — so the operator reads the pair
  as one document. Use when either command builds its page: copy template.html,
  keep the <style> and the section ids, fill the ⟨slots⟩, share via doc-preview.
---

# epic-page — the shared frame for the EPIC trio's pages

<!-- fleet skill -->

Two of the three EPIC commands render a page for the operator: `/fleet-epic-plan`
puts a **design page** in front of them before anything is filed (issue #809), and
`/fleet-epic-report` renders the **batch report** after the run ends. Both are
model-authored HTML, and without a shared source they came out looking like two
different products — the first two reports on this machine did. This skill is the
shared source: one `template.html`, one `<style>`, one set of section ids.

## Use

```sh
cat ~/.claude/skills/epic-page/template.html     # read the frame, then write your page
~/.claude/skills/doc-preview/share.sh <page.html> # host it; relay the READY URL
~/.claude/skills/doc-preview/share.sh --refresh   # after editing the SAME file — URL unchanged
```

- **Keep** the `<style>` block verbatim and every `id=` on `<section>` /
  member cards. The ids are the contract the commands (and their selftest) refer
  to; the style is what makes the two pages one document.
- **Fill** every `⟨slot⟩`. Labels inside the slots follow the theme's language
  (the fixed Chinese labels are this fleet's default — translate them if the
  theme is in another language; keep the ids).
- **Drop** the sections the other page owns — each is marked PLAN ONLY /
  REPORT ONLY / BOTH in the file. Never add UX chrome — doc-preview's viewer is
  reading/print-first by design.
- **Re-render, don't re-share.** `share.sh <file>` APPENDS a new row with a new
  URL every time; edit the same file and run `share.sh --refresh` so the operator's
  open tab and the URL you already relayed stay valid.

## One page, two layers (issue #839)

The page has two readers, and the layers keep them from crowding each other out:

- **上层 — 发起人 / stakeholder.** 用例 · 目标 · 指标, readable in two minutes.
  No file names, no fleet jargon (占槽 → 占用时长, reap → 回收, worker → 执行会话),
  and since #881 no keys either: `C1/C2`, source issue numbers and PR numbers live
  in a card's 技术细节; the surface names a member by its name. A mirror id like
  `prod-3a229eb80` is fold material too.
- **下层 — the people doing the work.** Every technical field, inside
  `<details class="fold">`, **default closed and complete**. The fold changes the
  visible ORDER, never the content: the write-back to the parent and the
  sub-issues carries **both** layers, so a worker's body is a field-for-field
  superset of what it was before.

The fold's `<summary>` is a real tap target on a phone, and the `@media print`
block force-opens every `<details>` (both the `::details-content` path and the
legacy `display:none` one), so nothing is lost to paper.

## The decider's view (issue #881)

Six rounds of 发起人 feedback on EPIC #883's page, fixed into the frame so the
next page starts where that one ended. `/fleet-epic-plan` step 4 lists them as
numbered rules; the frame's comment block and slots already follow them:

- **Plain words** — the number band reads 要做的事 / 有空再做 / 要看的指标 /
  开跑前要处理; 范围 and 风险 are short plain sentences (「会出什么事 — 我们怎么兜住」).
- **One line per card** — `<details class="card">` folds a whole member card to
  名称 + 一句「解决什么」, grouped by theme under `<h3 class="grp">`, 有空再做 last.
  The list IS the overview; tap once for 为谁 / 解决什么 / 怎么算成功, again for
  技术细节.
- **Numbers only** in the metric table (指标 / 现在 / 目标); 读数口径, commands and
  paths in its 「怎么量」 fold.
- **Execution folded** — 先后, 依赖, 来源单号, 复读时间, 预检原文, 共同约定.
- **Decisions in one table** — 需要你定的事: 事项 / 建议, a default on every row,
  「（批后）」 for what waits for approval; 能不能开跑 comes after it — and only
  when there is something to handle (#929): 「可以。不用先处理什么」 is not
  information, so a clean preflight drops the section and the zero tile.

The folds change the page, never the issue — write-back is unchanged.

### What goes IN the slots (issue #929)

The frame gives every slot; it does not say what a good slot holds. On
2026-09-22 a design page filled every slot of this frame and was still sent back
(「可读性还差很多」) — and every miss was on the surface. These rules are the
difference; `/fleet-epic-plan` step 4 numbers them 0 and 16–23, same wording.

0. **动笔前先读一份已批的样例页 — its SURFACE.** Pick one the 发起人 approved in
   the new format and read it with every fold closed, before you write a word:

   ```sh
   ~/.claude/skills/doc-preview/share.sh --list | grep -i epic      # the header line is the base URL
   ~/.claude/fleet/bin/epic-page-surface.sh <base-url>/d/<id>/      # its surface, folds stripped
   ```

   The current 样例页 is **EPIC #787 「Multi-repo fleet」** (the `Multi-repo fleet`
   row). Read how its subtitle stops, how its metrics count known failures, how
   its 为谁 names one person — then write yours to that bar. A tailnet page dies
   on reboot: if #787's row is gone, pick the newest approved plan page, and
   update this line when a better one exists.
- **When the theme is a question, the surface answers it first — 先回答.** A theme
  like 「别人怎么做、我们该怎么做、价值在哪」 is answered at the top of `#charter`,
  not in a fold: the frame's optional 先回答 slot — a 3–4 row plain table 别人怎么做
  / 我们怎么做, plus 我们的价值 as a few short items. Sources, links, unverified
  claims go in its fold. A theme that is a plain goal drops the slot.
- **The subtitle says two things** — what this is, and where the batch stops
  (「…两个仓库的试跑通过就停」). Never a slogan.
- **A metric is an outcome the decider can feel and count.** Prefer the shape
  **已知 N 种 X → 0** (#787: 「Known ways work leaks across repos 9 → 0」; fixed:
  「已知的『本地好好的，传上去就不行』的情况 6 种 → 1 种」). Banned: a target with no
  number (「首跑定」), a meaningless one (「> 0」「> 现值」), 现在 and 目标 in
  different units (「3 处 → 1 行」). No number today ⇒ 「本批不量」 (#839).
- **为谁 is a person or role, with a count** — 「你，一个人管 3 个 repo，多数时候用
  iPad」, 「在微信里收到成果页的读者（每月约 62 人）」. Never 「所有 Agent」 / 「维护团队」.
- **No implementation nouns on the surface** — #881's no-key / no-file-name rule
  extends to technical words: CSP, SDK, 接口, 注入, 渲染, 埋点, 回执, 域名, 状态码
  (404) and their kin. A card's name is what the user GETS; its one sentence is
  the trouble they hit today, in their words. The technical word goes in 技术细节.
- **有空再做 only extends the same theme.** An unrelated backlog bug stays on the
  backlog, however cheap; the 「更多风险与拆分理由」 fold names what was left out
  and why, so leaving it out reads as a choice.
- **需要你定的事 is real decisions only** — each row a genuine either/or with one
  concrete recommendation, no code, no paths, no parameter spelling. The 不做 list
  lives in 范围, never here.

### Self-check before sharing

Read your page the way the decider will — surface only — and walk the rules above:

```sh
~/.claude/fleet/bin/epic-page-surface.sh <page.html>          # the surface: folds gone, cards = one line
~/.claude/fleet/bin/epic-page-surface.sh --lint <page.html>   # + WARN lines, exit 1 on any
```

`--lint` catches what a machine can see — keys, implementation nouns, file names,
metrics with no / meaningless / mismatched numbers, a 为谁 with no count, code or
不做 in the decision table. Treat each WARN as a question, not a verdict (#787
itself warns on its 「PR / CI」 card), and know what it cannot see: whether the
surface answers the theme's question, whether the subtitle says where it stops,
whether 有空再做 is on theme. Those are yours.

## The sections

| id | page | what goes there |
|---|---|---|
| `#delivered` | report | **first section**: what a user can do now that they could not before — capabilities in the reader's words, not PR counts, no keys |
| `#metrics` | both | 指标 — surface 指标 / 现在 / 目标 (report: 之前 / 现在 / 目标), numbers only; the 「怎么量」 fold carries 成员 / 多久能读出来 / 读数口径. The plan writes it from the theme's diagnosis (「本批不量」 when there is none, never blank, never invented); the report fills 现在 row by row (「⟨date⟩ 再看」 / 「本批未声明指标」, never back-filled) |
| `#charter` | plan | 先回答 (optional — only when the theme is a question: 别人怎么做 / 我们怎么做 table + 我们的价值, sources folded), then 范围 — 做 / 不做 as short plain items; 共同约定 folded — verbatim into the parent body |
| `#members` | both | 要做的事 — one `.ob` per member, `id="m-<key>"`, wrapping a `<details class="card">` that is ONE line (名称 + 一句) until tapped, grouped by theme (`h3.grp`), 有空再做 last. Tap 1: 目标 / 为谁 / 解决什么 / 怎么算成功 (+ the report's `.proof` grid); tap 2, `<details class="fold">`: 编号 / 来源 · 方案 · 接口·约定 · 依赖 · 完成判据 · **上线证据** — the card IS the sub-issue body, both layers |
| `#gaps` | report | **还差什么 · 下一步** (issue #929) — one two-column table 还差什么 / 建议下一步, one row per gap, one short clause per cell; an empty kind (待部署, 要人做的) is no row; the next-batch suggestion is a row (「下一批主题：…」); no lede, no trailing note, no 这批不做. Carries the `#next` anchor. The band's 还差什么 = its row count |
| `#risks` | plan | 可能出的问题 — one plain sentence each; technical risks + why this split in the fold |
| `#signoff` | plan | 需要你定的事 — 待决 + 发起人拍板 in one 事项 / 建议 table, a default on every row, 「（批后）」 marks; carries the `#open` anchor. Recorded with the date after the nod |
| `#preflight` | plan | **only when there is something to handle** (issue #929: FIXABLE, or a warning the 发起人 must act on) — 能不能开跑 in one sentence, the `fleet-epic-preflight.sh` screen verbatim in the fold. Nothing to handle ⇒ the section and the band's 开跑前要处理 tile are dropped, and the screen moves to the end of the `#order` fold |
| `#next` | report | an anchor only — `<span id="next">` inside `#gaps`; the suggestion is that table's last row(s) |
| `#order` | plan | 执行安排 — the whole section folded, last: waves, who waits for whom, what runs in parallel |
| `#ops` | report | 运行情况, **the whole section folded and last**: 墙钟 · 占用时长 · 额度曲线 · 甘特, with the #625 occupancy-not-tokens caveat kept word for word |

Reading orders that fall out of the file order — plan: `#metrics` `#charter`
`#members` `#risks` `#signoff` `#preflight` `#order`; report: `#delivered`
`#metrics` `#members` `#gaps` `#ops`. `#preflight` is optional (above); there is
no obstacles section — a fleet-side defect is FILED as an issue, its number goes in
the durable comment only, and if the reader needs it, it is a 下一步 row in plain
words.

The **上线证据** line is the seam with `/fleet-epic-report` (issue #810): one
line a worker can follow before landing and the report can collect afterwards —
a URL to screenshot, a command whose output to keep, a pane to `capture-pane`.
Write it so both can act on it without asking.

Artifact publishing is hook-blocked inside fleet sessions (issue #526); doc-preview
is the host, and its URL is tailnet-only and dies with the next reboot — which is
why the plan writes the page's content back into the issues, and the report posts
its durable half as a comment.
