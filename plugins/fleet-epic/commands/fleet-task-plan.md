---
description: One task's design page — 问题与原因 · 目标 · 解决方案 · 风险 · 需要你定的事 · 上线后怎么验收 — answered on the page, and the task opened from it only after you say yes.
---

# /fleet-task-plan — one task, one design page, then the task

<!-- fleet skill · owner: hub -->

`/fleet-epic-plan`'s little sibling (T661). An EPIC is a batch; this is ONE piece
of work — most often a problem someone has to explain: what goes wrong, why, what
we change, where it stops. You name the **subject**; this writes **one design
page** the operator reads on their phone, publishes it to 活页 privately and pushes
it to their WeChat, and — **only after they nod** — opens ONE hub task (`T<n>`)
whose words are the page, both layers, and whose session implements it.

**Argument** (`$ARGUMENTS`): the subject in the operator's words — *"批次报告送不到
你手里"*, *"新会话开得慢"*. Required: with none, ask for one and stop.
`--repo <owner/name>` names the repo the change lands in (else the pane's own,
else ask — the same resolution as `/fleet-epic-plan` step 0).

**Why it lives in the fleet-epic plugin.** It renders into the SAME frame as the
EPIC pages (`skills/epic-page`: one `<style>`, one two-layer rule, one lint), so
the operator reads an EPIC page and a task page as one family, and a change to
the frame changes both. The core keeps the parts any caller can use — the page
script `bin/fleet-task-page.py` and the lint `bin/epic-page-surface.sh`; the
command is the plugin's, like its siblings. No plugin ⇒ no command; the `task`
tool still opens a task from plain words.

## 0. Resolve the fleet, the repo and the hub (FIRST, every time)

Run `/fleet-epic-plan`'s step 0 block verbatim (fleet, `fleet_target_repo`,
`fleet-task-record.sh authority`). `RC=4` ⇒ ask which repo; `RC=1` ⇒ abort; no
hub ⇒ say so in one line and stop: a task is a hub record (issue #4898) and there
is nowhere else to put it.

## 1. Find out what is true

Read before you write. A cause on the page is a claim the operator will act on:

- **现象** — what the person sees, counted, one fact a line (「3 个批次的完成通知一个都没到」).
- **原因** — reproduce it, then walk it step by step in plain words; keep the
  **证据** — code lines (`file:line`), log lines, the live state (tmux options,
  ledger rows, a command's output) — each on the step it proves (T764).
- No cause to find (a plain new feature) ⇒ the spec's `"kind": "feature"`: the
  section is 「现在的样子与为什么要做」 (`lede` + `points`).

Exclude what someone is already doing (`mcp__fleet__status`, ask the person).

## 2. Write the spec, render the page

Copy the example and fill it — `plugins/fleet-epic/skills/epic-page/task-page.example.json`
is a whole, approved page (the orchestrator's first one, 2026-10-20):

```sh
cp ~/.claude/fleet/plugins/fleet-epic/skills/epic-page/task-page.example.json <scratchpad>/task-<slug>.json
# … edit …
python3 ~/.claude/fleet/bin/fleet-task-page.py render <scratchpad>/task-<slug>.json -o <scratchpad>/task-<slug>.html
```

The script owns the frame (epic-page's `<head>` + the task layout); you own the
words. Top to bottom:

| part | spec key | what goes there |
|---|---|---|
| 标题 + 副题 | `title` · `sub` | the subject in **≤ 16 字**; the subtitle ONE sentence **≤ 30 字**, no brackets, only where it stops (「…0 份丢失就停」) |
| 数字条 | `band` | 根本原因数 / 要改的地方 / 影响面 (e.g. 已经丢的回报 15) |
| `#problem` 问题与原因 | `problem` | the symptom first: ONE sentence (a string, ≤ 40 字), or a few facts — one a line, **≤ 25 字**, the number first, no reasons |
| ↳ `#cause` (anchor) | `cause.lede` · `cause.steps[]` · `cause.other[]` | one-sentence lede; the walk `{step, what, evidence [li]}` — **each step opens on ITS evidence** (file:line, the log, the scene); a step with none is a plain row, no ▸. What fits no step / metric / card goes in `other` `{kind: code·log·scene·ref, title, ref (file:line), excerpt (a line or two), text}` — grouped by kind, a title each |
| `#metrics` 目标 | `metrics[]` | `{name, now, target, how}` — numbers only on the row; **each row opens on how IT is measured** |
| ↳ `#charter` (anchor) | `charter.do` · `charter.dont` | 做 / 不做 under the metric rows, short plain items |
| `#members` 解决方案 | `members[]` | one card per place we change: `name` + `line` (one line until tapped), `what` (做什么, plain), `tech` [[方案 …], [完成判据 …]] folded; a visual change adds `compare` (改前 / 改后, below). A card with nothing past its line has no ▸ |
| `#risks` | `risks` · `risks_tech` | 「会出什么事 — 我们怎么兜住」 |
| `#signoff` 需要你定的事 | `signoff` | `{q, rec, default, options}` — 事项, 建议, the DEFAULT (what counts when nobody picks; old `[事项, 建议]` rows default to 按建议) and the other options; the line under it says 「点头即全部按建议」 |
| `#evidence` 上线后怎么验收 | `evidence[]` · `phase` | one item per proof `{what, where, pass, status, proof}`: 是什么 · 在哪取 · 通过标准. The plan (`phase` plan, the default) shows only those three; the worker renders `phase: build` and fills each `status` (pending · done · passed · failed), `proof` ({img · text · url · html, caption}) and, on every done / passed item, `screenshots` (the production page, phone 390 + desktop 1440 — below) — the filled card is the report's 已上线 |
| 页内反馈 | `feedback` · `replies_done` | `{table: "replies", version: "v<N>", poll: "12 分钟"}` — below |

**Nothing to open, no ▸** (T764): a step, a metric row or a card with no detail
renders as a plain line — never an arrow onto nothing (lint `empty-fold`). An old
spec (`steps` [[…]] + `cause.evidence`, `metrics` [[…]] + `metrics_how`, a one-line
`evidence`) still renders, and the lint asks to migrate it (`fold-row`, `accept`).

**页内反馈** (T764): the page is a live page, so the operator answers ON it, each
item on its own: every 需要你定的事 row lays its options out in the row — the default
first, marked 「默认」 and drawn as what counts while nobody picked, then the others,
then 「改成…」 (a note); a tap posts that pick, a non-default pick is highlighted —
「有意见」 on every 原因 step and card, one 「全部按建议」 — each opens or posts THAT item
only. A submit POSTs `{item, choice, note, version, at}` to the page's own table —
`item` is `signoff-<n>` · `cause-<step>` · `card-<key>` · `nod`; a withdraw is the same
item with `choice` `withdraw`. On load the page reads the table back (`GET
./_data/replies.json` returns the reviewed rows; rows this device sent that are not
back yet come from localStorage, marked 待同步) and draws each item's LAST row — what
was chosen, when, 改 · 撤回; a done 全部按建议 hides its button. Make the tables once,
right after the first publish:
`mcp__space__set_data` `replies` (`revision` 0, `rows` [], `columns` [item, choice,
note, version, at] — a column the table lacks is dropped from a row, `append_open`
true, `members_only` true) and `replies_done` (`columns` [item, state, note],
`append_open` false). The orchestrator reads `replies` (its 「方案页的意见表」 rule)
and hands each item's last row to the session that owns the page; that session marks
it by writing `replies_done` (`{item, state: adopted | declined, note}` — the page
shows it at once, no new version) — `replies_done` in the spec renders the same mark
into the page itself.

The **two-layer rules are epic-page's** (`skills/epic-page/SKILL.md`, rules 0 and
16–24 of `/fleet-epic-plan` step 4): plain words, no keys, file names or
implementation nouns on the surface; every technical field one tap down, complete.
**A visual change carries its 改前 / 改后 in its card** (rule 24, T699): the
member's `compare` — `{"before": {"html"|"img": …, "note": "…"}, "after": {…}}`, or
`"states": [{"label": "…", "html"|"img": …, "note": "…"}, …]` for several 改后
scenarios the reader switches with buttons. 改前 is taken from today (a real
capture); 改后 is high fidelity — the look and the words that will go live, not a
sketch. A pane's own look goes in the spec's `css`; an `img` is a path beside the
page. No separate prototype page: `proto` still renders for an old spec, and the
lint WARNs it (`compare`). The task's words carry the block as text — one line per
state (`- 改后 · <标签>：<说明>`), never its HTML.

## 3. Self-check

```sh
~/.claude/fleet/bin/epic-page-surface.sh --lint <scratchpad>/task-<slug>.html
```

The surface as the operator reads it, plus a `WARN` per machine-visible miss —
epic-page's rules, and the task page's own: `task-section` (a section missing),
`task-evidence` (a 原因 with no folded 证据), `task-signoff` (no 「点头即全部按建议」), and epic-page's `compare` (a visual change
with no 改前 / 改后, or a link to a separate prototype page), `brevity` (标题 > 16 字,
副题 > 30 字 or bracketed, a 现象 line > 25 字), `fold-row` (the old shared 证据 /
怎么量 folds), `accept` (上线证据 still one line, or an item with no 通过标准),
`empty-fold` (an arrow onto nothing), `task-evidence-shot` (an item marked done /
passed with no production screenshots, phone 390 + desktop 1440 — below).
A WARN is a question, not a verdict; fix what is real.

**线上真实截图 (A300)**: every item the worker marks `done` / `passed` carries
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

## 4. Publish privately, push, wait

1. `mcp__space__publish_file` — `title` 「任务设计：<标题>」, `filename`
   `task-<slug>.html`, `content` the page (with pictures: `files`, each by its
   relative path). New pages start **private**; never widen that yourself. Keep
   the `proposal_id` and link.
2. **Make sure it reaches their WeChat exactly once** (T765): the publish receipt's `notify.self` is `true` ⇒ the workspace's automatic push already sends it to them — do NOT call `mcp__space__push_to_wechat` (it would arrive twice); say 已自动推送. No such field? Ask `mcp__space__set_publish_notify` (no arguments: `auto_push` + `include_me`; with the `proposal_id`: `page_notify` off overrides) — both on ⇒ the same. Otherwise call `mcp__space__push_to_wechat` once — that `proposal_id`, `to` omitted (the operator only). A `quiet` update is never pushed, by hand or otherwise.
3. One sentence: *"任务设计页 <link>（已推到你微信，仅你可见）— 根本原因 n · 要改 m 处 ·
   需要你定 k 件。改哪条直接说；点头即全部按建议，开任务。"*

No 活页 tools (`mcp__space__*` not mounted)? Serve it on loopback
(`python3 -m http.server --bind 127.0.0.1 <port>` in the scratchpad, dies with the
session) and open it with the fleet `open` tool.

Then **stop and wait**. A revision edits the spec, re-renders, and publishes to
the SAME page (`publish_file` with its `proposal_id`) — one link, they reload it.

## 5. After the nod — open the task from the page

The page is the source: never re-draft the task from the chat.

1. Anything changed in the chat goes into the spec first; re-render.
2. **The words** — both layers, every fold written out, the nod recorded:

   ```sh
   python3 ~/.claude/fleet/bin/fleet-task-page.py body <scratchpad>/task-<slug>.html \
     --link <活页 link> --nod "<operator> YYYY-MM-DD" > <scratchpad>/task-<slug>.md
   ```

   It measures the words as they travel (UTF-8 JSON; the hub reads 16 KB with the
   envelope) and, over `--max` (13000), moves folds to the page one kind at a time
   — the steps' evidence, then 解决方案's 技术细节 — each line saying 「见设计页」;
   the 上线后怎么验收 items always stay. Page controls (buttons, forms) are never words. Exit 1 = even the surface is too long: shorten the page.
3. **Open the task** — the `task` tool (`mcp__fleet-orch__task`: `title` the page's
   title, `body` the file's content, `repo`, `spawn: true`), which is
   `fleet-task-record.sh dispatch --title … --body-file <md> --repo <owner/name> --spawn`.
   Its first stdout line is the task's ID; the session opens in a worktree of that
   repo bound to it, implements, opens its PR and merges on a green gate.
4. **Stamp the page** — `fleet-task-page.py stamp <page.html> <ID> -o <page.html>`
   (「任务设计」 → 「任务 <ID>」) and publish it to the same page.

## 6. Report

One line: the task's ID, the page link, that its session is running. Stopped at
step 0 (no hub) or step 4 (waiting for the nod — the link is the whole report)?
Say that.

---

Rails: the page's source lives in your scratchpad, never the repo; it goes to 活页
privately (never the Artifact tool, hook-blocked in fleet sessions — issue #526).
Nothing here writes to GitHub, edits code or merges: the task's own session does.
