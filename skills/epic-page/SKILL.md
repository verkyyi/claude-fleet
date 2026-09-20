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
- **Drop** a section only when the command says it is optional (the report has no
  `#signoff`; the plan has no quota curve). Never add UX chrome — doc-preview's
  viewer is reading/print-first by design.
- **Re-render, don't re-share.** `share.sh <file>` APPENDS a new row with a new
  URL every time; edit the same file and run `share.sh --refresh` so the operator's
  open tab and the URL you already relayed stay valid.

## The sections (plan page)

| id | what goes there |
|---|---|
| `#preflight` | `fleet-epic-preflight.sh` verdict + its warning rows, verbatim |
| `#charter` | theme · scope · does-NOT · shared conventions — verbatim into the parent body |
| `#members` | one `.ob` card per member, `id="m-<key>"`, six fields: 目标 / 方案 / 接口·约定 / 依赖 / 完成判据 / **上线证据** — the card IS the sub-issue body |
| `#order` | dependency order — waves, who waits for whom, what runs in parallel |
| `#risks` | risks + why this split |
| `#open` | 待决 — open questions `run` appends to |
| `#signoff` | 发起人拍板 — the decisions the plan asks for; recorded with the date after the nod |

The **上线证据** line is the seam with `/fleet-epic-report` (issue #810): one
line a worker can follow before landing and the report can collect afterwards —
a URL to screenshot, a command whose output to keep, a pane to `capture-pane`.
Write it so both can act on it without asking.

Artifact publishing is hook-blocked inside fleet sessions (issue #526); doc-preview
is the host, and its URL is tailnet-only and dies with the next reboot — which is
why the plan writes the page's content back into the issues, and the report posts
its durable half as a comment.
