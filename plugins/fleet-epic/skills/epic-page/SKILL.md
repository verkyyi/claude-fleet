---
name: epic-page
description: >-
  The one HTML frame both EPIC pages render into — the design page
  /fleet-epic-plan hosts before the operator confirms a batch, and the batch
  report /fleet-epic-report hosts after it ends — so the operator reads the pair
  as one document. Use when either command builds its page: copy template.html,
  keep the <style> and the section ids, fill the ⟨slots⟩, open it on the operator's computer.
---

# epic-page — the shared frame for the EPIC trio's pages

<!-- fleet skill -->

Two of the three EPIC commands render a page for the operator: `/fleet-epic-plan`
puts a **design page** in front of them before the batch's parent task is opened (issue #809), and
`/fleet-epic-report` renders the **batch report** after the run ends. Both are
model-authored HTML, and without a shared source they came out looking like two
different products — the first two reports on this machine did. This skill is the
shared source: one `template.html`, one `<style>`, one set of section ids.

## Use

```sh
cat ~/.claude/fleet/plugins/fleet-epic/skills/epic-page/template.html     # read the frame, then write your page
```

Then publish it to 活页, private (`mcp__space__publish_file`), and make sure it
reaches the operator's WeChat exactly once — the publish receipt's
`notify.self` true (else `mcp__space__set_publish_notify`: `auto_push` +
`include_me` on) ⇒ it is already pushed, no `mcp__space__push_to_wechat`; else
push it by hand, to them only; a `quiet` update is never pushed (issue #4957, T765). No
活页 tools in the session: serve it on loopback
(`python3 -m http.server --bind 127.0.0.1 <port>`, dies with the session) and open
it with the fleet `open` tool (`:<port>/<page.html>`).

- **Keep** the `<style>` block verbatim and every `id=` on `<section>` /
  member cards. The ids are the contract the commands (and their selftest) refer
  to; the style is what makes the two pages one document.
- **Fill** every `⟨slot⟩`. Labels inside the slots follow the theme's language
  (the fixed Chinese labels are this fleet's default — translate them if the
  theme is in another language; keep the ids).
- **Drop** the sections the other page owns — each is marked PLAN ONLY /
  REPORT ONLY / BOTH in the file. Never add UX chrome — the page is
  reading/print-first by design.
- **Re-render, don't re-send.** Edit the same file and publish it to the same
  page (`publish_file` with its `proposal_id`): the link the operator holds stays
  valid, they reload it.

## One page, two layers (issue #839)

The page has two readers, and the layers keep them from crowding each other out:

- **上层 — 发起人 / stakeholder.** 用例 · 目标 · 指标, readable in two minutes.
  No file names, no fleet jargon (占槽 → 占用时长, reap → 回收, worker → 执行会话),
  and since #881 no keys either: `C1/C2`, source references, task and PR numbers live
  in a card's 技术细节; the surface names a member by its name. A mirror id like
  `prod-3a229eb80` is fold material too.
- **下层 — the people doing the work.** Every technical field, inside
  `<details class="fold">`, **default closed and complete**. The fold changes the
  visible ORDER, never the content: the write-back into the parent task's
  charter carries **both** layers, so a member's session gets a field-for-field
  superset of what the page shows.

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

The folds change the page, never the charter — write-back is unchanged.

### What goes IN the slots (issue #929)

The frame gives every slot; it does not say what a good slot holds. On
2026-09-22 a design page filled every slot of this frame and was still sent back
(「可读性还差很多」) — and every miss was on the surface. These rules are the
difference; `/fleet-epic-plan` step 4 numbers them 0 and 16–23, same wording.

0. **动笔前先读一份已批的样例页 — its SURFACE.** Pick one the 发起人 approved in
   the new format and read it with every fold closed, before you write a word:

   ```sh
   ~/.claude/fleet/bin/epic-page-surface.sh <an approved page.html>   # its surface, folds stripped
   ```

   The current 样例页 is **EPIC #787 「Multi-repo fleet」** (the `Multi-repo fleet`
   row). Read how its subtitle stops, how its metrics count known failures, how
   its 为谁 names one person — then write yours to that bar. If you have no copy
   of #787's page, pick the newest approved plan page, and update this line when
   a better one exists.
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
- **A visual member carries its 改前 / 改后 in its card** (issue #1754, T699; rule 24
  in `/fleet-epic-plan`). A member that changes something the user sees — dash /
  侧栏 rows, 状态栏 / 顶栏, 弹出菜单, 网页, 小程序 pages, a report page's 样式 — gets
  the frame's `div.cmp` block in its card's **upper layer** (under 怎么算成功, never
  in the fold): 改前 from today, 改后 high fidelity — the look and the words that
  will go live — as one pane or several states the reader switches. Never a
  separate `proto-*.html` page or a `p.proto` link. ONE renderer writes it for
  every page: `bin/fleet-task-page.py compare <json>` (the task page's members
  take the same object as their `compare` key):

  ```json
  {"before": {"html": "<pre>今天的顶栏…</pre>", "note": "提醒挤在右边"},
   "states": [{"label": "来了错误", "img": "shots/err.png", "note": "错误留到你看过"},
              {"label": "手机 45 列", "html": "…", "note": "只写图标 + 半句"}]}
  ```

  `after` (one pane) or `states` (several, each with a `label`); a pane is `html`
  (a fragment, its own look in a `<style>` after the frame's — the task spec's
  `css`) or `img` (a path beside the page) + `note`. The frame's `<style>` lays
  it out (two columns, stacked under 640 px; 改前 grey, 改后 accent; buttons ≥ 32 px;
  dark and light) and its one `<script>` switches the states — with no script the
  first state shows; printed, every state shows under its label. At filing it
  becomes words, one line per state (`- 改后 · <标签>：<说明>`). A non-visual member
  drops the block.
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
不做 in the decision table, a visual member card (侧栏 / 状态栏 / 菜单 / 页面 /
顶栏 / 界面 / 样式 …) with no 改前 / 改后 block, or any card still linking a separate
prototype page (`compare`). Treat each WARN as a question, not a verdict (#787
itself warns on its 「PR / CI」 card), and know what it cannot see: whether the
surface answers the theme's question, whether the subtitle says where it stops,
whether 有空再做 is on theme. Those are yours.

## The task page (T661)

`/fleet-task-plan` renders ONE task's design page into the same frame — the same
`<style>`, the same two layers, the same lint — so an EPIC page and a task page
read as one family. It is not a copy of `template.html`: the layout is
`bin/fleet-task-page.py`'s (`render <spec.json>`; `task-page.example.json` here is
a whole approved one), which takes the `<head>` from `template.html` verbatim.
Top to bottom: eyebrow 「任务设计 · repo · date」 (stamped 「任务 <ID>」 once opened)
→ title (≤ 16 字) + subtitle (one sentence ≤ 30 字: where it stops) → number band
(根本原因 / 要改的地方 / 影响面) → `#problem` 问题与原因 (the symptom, then the
`#cause` anchor: lede · the step walk, **each step opening on its own evidence**,
leftovers grouped by kind; a feature: 现在的样子与为什么要做) → `#metrics` 目标 (metric
rows, **each opening on how it is measured**, then the `#charter` anchor: 做 / 不做)
→ `#members` 解决方案 (one card per place, 技术细节 folded) → `#risks` → `#signoff`
需要你定的事 (+`#open`; 「点头即全部按建议」, and 页内反馈 below) → `#evidence`
上线后怎么验收 (是什么 · 在哪取 · 通过标准; status and the proof slot only once building,
and on a done / passed item its 线上实拍 — `screenshots`, phone 390 + desktop 1440 thumbnails).
`epic-page-surface.sh --lint` holds it to the frame (`task-section`,
`task-evidence`, `task-signoff`, `brevity`, `fold-row`, `accept`, `empty-fold`,
`task-evidence-shot`);
`fleet-task-page.py body` turns it into the task's words, both layers, inside the
record's 16 KB.

## 验收要有线上真实截图 (A300)

Both page kinds. Every item the worker marks `done` / `passed` carries
`screenshots` `[{url, mobile, desktop, caption?, at?}]` — the PRODUCTION page shot
AFTER the switch, never a local build or a mock: Playwright against the live URL,
once at 390 wide (phone) and once at 1440 (desktop), a full-page PNG each
(`page.setViewportSize({width: 390, height: 844})` → `screenshot({fullPage: true})`,
then 1440 × 900). Keep them beside the page (`shots/<n>-390.png`, `shots/<n>-1440.png`)
and reference them by relative path, or by a file of the same live page; they are
published WITH the page to the same 活页 (`publish_file` `files`: the page plus each
`shots/…`; a picture over the text limit goes by `url` or `create_upload_link`). The
page draws each as a thumbnail that opens full size. A done / passed item without
both is the lint's `task-evidence-shot` — a must-fix before the worker reports.
On an EPIC report the 已上线 cell is the same rule: the shot is taken on production,
at both widths, and published with the report.

**登录后的页面 (T844)**: a page behind a sign-in — production's console `/app` — is
shot signed in as the person who dispatched the session, read-only, never by a
sign-in of the session's own and never with a person's browser state. Run
`~/.claude/fleet/bin/fleet-console-ticket.sh --next /app/<page>`: the hub hands
THIS session a one-time link (good for 2 minutes, opened once) into its login
owner's `/app`; `browser_navigate` to it in the browser that shoots, then take
both widths in that same browser (the session lasts 15 minutes, `--ttl` up to
1800; past it, ask for a new link). It is a member's view and reads only — a write,
a websocket or the conversation answers 403 (只读票据), an admin's ticket opens no
admin page — so shoot the state, do not drive it. The link is a credential: give
it to the browser only, never to a page, a record or a log. Exit 1 (a login no
person owns, a person off the list) or 3/4 (no hub, not a fleet session) ⇒ that
item's signed-in shot is the person's: say so in its `proof`.

## Rows that open on their own detail (T764)

Both page kinds. A table whose rows carry detail is a `div.xt` (`c2` for 一步 /
发生了什么, `c3` for 指标 / 现在 / 目标, `c4` for the report's 指标 / 之前 / 现在 / 目标):
a row WITH a detail is `<details class="xr"><summary>…cells…<i></i></summary><div
class="xd">…</div></details>`, a row WITHOUT one a plain `<div class="xr">` — no ▸,
nothing to tap. The same rule for a card: nothing past its one line ⇒ `<div
class="card">`, no fold; an empty 技术细节 is dropped, never shown. The lint's
`empty-fold` names an arrow onto nothing, `fold-row` the old shared 证据 / 怎么量 folds.

## 页内反馈 — the page answers itself (T764)

A page published as a 活页 takes the operator's answer where they read it, item by
item. The body tag carries `data-fb-table="replies" data-fb-version="v<N>"` — set it with
`~/.claude/fleet/bin/fleet-task-page.py fb-body <page.html> replies v<N> -o <page.html>`,
which edits only the REAL tag; never a text「replace the first `<body>`」: the frame's own
comments once said the word, the page went into the head's script and opened blank (T869).
`epic-page-surface.sh --lint` says `ERROR body` on such a page — fix it before publishing. Each
answerable item is a `div.fbi` (`data-item`, `data-kind` pick · say · nod) holding
its state line `.fbs` and its form — a 需要你定的事 row with its options in the row
(`signoff-<n>`, `data-default`: the default first, marked 「默认」 and drawn as what
counts while nobody picked, the others, 「改成…」; a tap posts it, a non-default pick
is highlighted), a 「有意见」 under each step (`cause-<step>`) and card
(`card-<key>`), one 「全部按建议」 (`nod`). The frame's script:

- posts `{item, choice, note, version, at}` to `./_data/replies` — a members-only
  table made once after the first publish (`mcp__space__set_data`, columns item ·
  choice · note · version · at: a column the table lacks is dropped);
- on load reads it back — `GET ./_data/replies.json` returns the reviewed rows
  (`_author: true` on a member's); rows this device sent that are not back yet
  (moderation) come from localStorage, marked 待同步 — and draws each item's LAST
  row: 「✓ 你选了…（时间）· 改 · 撤回」, a done 全部按建议 hides its button;
- 撤回 posts the same item with `choice` `withdraw` — the item is unanswered again;
- reads `./_data/replies_done.json` (`{item, state adopted | declined, note}`, base
  rows the owning session writes with `set_data`) and marks the item 已采纳 / 未采纳
  without a new version; the spec's `replies_done` renders the same mark statically.

**The orchestrator's rule** (its agent file, 「方案页的意见表」): every plan page's
`replies` table is read in its routine poll — `list_data_rows` `since` the last
cursor — and each item's last row handed to the session that made the page. A
withdraw is handed on too; if that session already acted on the item, it says
whether it can go back and either does or reports why not.

What the 活页 does not give yet (asked of the 活页 team): a row's server time / id in
`GET` (hence the page's own `at`), which member wrote it (`_author` is a flag),
the author's own held rows, a reader deleting their own row (hence `withdraw`
rows). The 活页's own comment box (bottom right, a selected sentence) reaches the
orchestrator too: `list_feedback` returns the sentence, `reply_feedback` answers on
the page.

## The sections

| id | page | what goes there |
|---|---|---|
| `#delivered` | report | **first section**: what a user can do now that they could not before — capabilities in the reader's words, not PR counts, no keys |
| `#metrics` | both | 目标 — the metric rows 指标 / 现在 / 目标 (report: 之前 / 现在 / 目标, `xt c4`), numbers only; each row opens on ITS 成员 / 多久能读出来 / 读数口径 (T764); the plan's 范围 (做 / 不做) follows under the rows. The plan writes it from the theme's diagnosis (「本批不量」 when there is none, never blank, never invented); the report fills 现在 row by row (「⟨date⟩ 再看」 / 「本批未声明指标」, never back-filled) |
| `#charter` | plan | 先回答 (optional — only when the theme is a question: 别人怎么做 / 我们怎么做 table + 我们的价值, sources folded); 共同约定 folded — verbatim into the parent body. 范围 moved under `#metrics` (T764) |
| `#members` | both | 解决方案 — one `.ob` per member, `id="m-<key>"`, wrapping a `<details class="card">` that is ONE line (名称 + 一句) until tapped, grouped by theme (`h3.grp`), 有空再做 last. Tap 1: 目标 / 为谁 / 解决什么 / 怎么算成功 (+ the report's `.proof` grid); a visual member adds its `div.cmp` 改前 / 改后 block here (`fleet-task-page.py compare`); tap 2, `<details class="fold">`: 编号 / 来源 · 方案 · 接口·约定 · 依赖 · 完成判据 · **上线证据** — the card IS the member's charter section, both layers |
| `#gaps` | report | **还差什么 · 下一步** (issue #929) — one two-column table 还差什么 / 建议下一步, one row per gap, one short clause per cell; an empty kind (待部署, 要人做的) is no row; the next-batch suggestion is a row (「下一批主题：…」); no lede, no trailing note, no 这批不做. Carries the `#next` anchor. The band's 还差什么 = its row count |
| `#risks` | plan | 可能出的问题 — one plain sentence each; technical risks + why this split in the fold |
| `#signoff` | plan | 需要你定的事 — 待决 + 发起人拍板 in one 事项 / 建议 table, a default on every row, 「（批后）」 marks; carries the `#open` anchor. Recorded with the date after the nod |
| `#preflight` | plan | **only when there is something to handle** (issue #929: a warning the 发起人 must act on — quota, a held machine) — 能不能开跑 in one sentence, the check's output verbatim in the fold. Nothing to handle ⇒ the section and the band's 开跑前要处理 tile are dropped, and the screen moves to the end of the `#order` fold |
| `#next` | report | an anchor only — `<span id="next">` inside `#gaps`; the suggestion is that table's last row(s) |
| `#order` | plan | 执行安排 — the whole section folded, last: waves, who waits for whom, what runs in parallel |
| `#ops` | report | 运行情况, **the whole section folded and last**: 墙钟 · 占用时长 · 额度曲线 · 甘特, with the #625 occupancy-not-tokens caveat kept word for word |

Reading orders that fall out of the file order — plan: `#metrics` `#charter`
`#members` `#risks` `#signoff` `#preflight` `#order`; report: `#delivered`
`#metrics` `#members` `#gaps` `#ops`. `#preflight` is optional (above); there is
no obstacles section — a fleet-side defect is RECORDED as a task, its code goes in
the closing summary only, and if the reader needs it, it is a 下一步 row in plain
words.

The **上线证据** line is the seam with `/fleet-epic-report` (issue #810): one
line a worker can follow before landing and the report can collect afterwards —
a URL to screenshot, a command whose output to keep, a pane to `capture-pane`.
Write it so both can act on it without asking.

Artifact publishing is hook-blocked inside fleet sessions (issue #526); the page
goes to 活页, private, and the parent task keeps what must outlive it — the plan
writes the page's content into the charter, the report's closing summary goes on
the parent's record (issue #4957).
