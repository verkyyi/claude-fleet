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

## One page, two layers (issue #839)

The page has two readers, and the layers keep them from crowding each other out:

- **上层 — 发起人 / stakeholder.** 用例 · 目标 · 指标, readable in two minutes.
  No file names, no fleet jargon (占槽 → 占用时长, reap → 回收, worker → 执行会话);
  `C1/C2` keys and PR numbers stay, because they are how a reader gets back to the
  record. A mirror id like `prod-3a229eb80` does not.
- **下层 — the people doing the work.** Every technical field, inside
  `<details class="fold">`, **default closed and complete**. The fold changes the
  visible ORDER, never the content: the write-back to the parent and the
  sub-issues carries **both** layers, so a worker's body is a field-for-field
  superset of what it was before.

The fold's `<summary>` is a real tap target on a phone, and the `@media print`
block force-opens every `<details>` (both the `::details-content` path and the
legacy `display:none` one), so nothing is lost to paper.
- **Re-render, don't re-share.** `share.sh <file>` APPENDS a new row with a new
  URL every time; edit the same file and run `share.sh --refresh` so the operator's
  open tab and the URL you already relayed stay valid.

## The sections

| id | page | what goes there |
|---|---|---|
| `#preflight` | plan | `fleet-epic-preflight.sh` verdict + its warning rows, verbatim |
| `#delivered` | report | **first section**: what a user can do now that they could not before — capabilities in the reader's words, not PR counts |
| `#metrics` | both | 打算移动的指标 — 指标 / 现在 / 期望 / 多久能读出来 + 读数口径. The plan writes it from the theme's diagnosis (「本批不量」 when there is none, never blank, never invented); the report fills 现在 row by row (「还读不出来 ⟨date⟩ 再看」 / 「本批未声明指标」, never back-filled) |
| `#charter` | plan | theme · scope · does-NOT · shared conventions — verbatim into the parent body |
| `#members` | both | one `.ob` card per member, `id="m-<key>"`, **two layers**: 目标 / 为谁 / 解决什么 / 怎么算成功 on the surface (+ the report's `.proof` grid), and 方案 / 接口·约定 / 依赖 / 完成判据 / **上线证据** in a closed `<details class="fold">` — the card IS the sub-issue body, both layers |
| `#gaps` | report | 还差什么 — 待部署 / 要人做的 / 没验证的 / 这批不做; 储备层未动不算欠 |
| `#obstacles` | report | product-side obstacles in full; fleet-side ones become ONE line pointing at filed issues (*would it still exist in another repo, on another theme?*) |
| `#order` | plan | dependency order — waves, who waits for whom, what runs in parallel |
| `#risks` | plan | risks + why this split |
| `#open` | plan | 待决 — open questions `run` appends to |
| `#next` | report | 建议下一批 — a suggestion for `/fleet-epic-plan`, explicitly not a decision |
| `#signoff` | plan | 发起人拍板 — the decisions the plan asks for; recorded with the date after the nod |
| `#ops` | report | 运行情况, **the whole section folded and last**: 墙钟 · 占用时长 · 额度曲线 · 甘特, with the #625 occupancy-not-tokens caveat kept word for word |

Reading orders that fall out of the file order — plan: `#preflight` `#metrics`
`#charter` `#members` `#order` `#risks` `#open` `#signoff`; report: `#delivered`
`#metrics` `#members` `#gaps` `#obstacles` `#next` `#ops`.

The **上线证据** line is the seam with `/fleet-epic-report` (issue #810): one
line a worker can follow before landing and the report can collect afterwards —
a URL to screenshot, a command whose output to keep, a pane to `capture-pane`.
Write it so both can act on it without asking.

Artifact publishing is hook-blocked inside fleet sessions (issue #526); doc-preview
is the host, and its URL is tailnet-only and dies with the next reboot — which is
why the plan writes the page's content back into the issues, and the report posts
its durable half as a comment.
