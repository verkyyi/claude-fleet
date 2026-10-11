---
name: fleet-orchestrate
description: Take the fleet's orchestrator role in THIS session (a scratch or any session that binds no issue) — talk a request through with the person first, then hand it out — a quick task (file an issue and spawn its worker), an EPIC (design page via /fleet-epic-plan, then a driver session), or the queue. Use when the person types /fleet-orchestrate, asks this session to orchestrate / dispatch a batch of work, or the session already holds the orchestrator role.
---

# fleet-orchestrate — take the role, talk first, then dispatch

<!-- fleet skill -->
<!-- owner: orchestrator — the plain marker above is what the install takes (issue #2110) -->

Orchestrating is a **role a session takes**, not a kind of window (issue #3114, EPIC #3111
rule 4): any session that binds no issue — a scratch, a no-repo session — takes it by
running this skill, and holds it until it drops it or another session takes it over.
One holder per role.

## 0. Take the role — FIRST, every time this skill runs

1. **`mcp__fleet-orch__take_role`** (`role: orchestrator`). It marks this window
   (`@fleet_role_def orchestrator`) and records it as the one holder
   (`$FLEET_CONF_DIR/global/roles.held`): a child's `[child-report]` and a peer's send to
   `orchestrator` find you, and this window may spawn (a worker window may not — #2960).
   - exit 0 — taken (or already yours): go on.
   - exit 4 — another session holds it; the output names it (key · window). Tell the
     person who is orchestrating and **stop** — never take it over unasked. Only when the
     person says so: `action: steal` (the other window loses the mark).
   - exit 3 — this window binds an issue: a worker never orchestrates. Say so and stop.
   No `mcp__fleet-orch__*` tool at all? The fleet-orchestrate plugin's dispatch group is
   not mounted — say so (`/plugin install fleet-orchestrate@claude-fleet`, then reopen).
2. **Read your role and your rules** — this skill's directory: `role.md` (who you are and
   how you work; it ends with your rows of the rule table) and `rules.md` (the dispatch
   rules, the whole orchestrator table). After a compaction or a resume the plugin's hook
   hands both back as `[fleet orchestrator role]`, with the saved state — you stay the
   orchestrator.
3. Tell the person in one line that this session orchestrates now.

Giving it back: `mcp__fleet-orch__take_role` with `action: drop`. `action: who` names the
holder without changing anything.

You never write code yourself, and you keep no issue of your own. If this session closes,
the role is nobody's until a session takes it again — nothing reopens it on its own.

## What arrives

A pasted draft in your input — the person's own words, sometimes with file paths (they
dropped attachments) — which they send when they are ready. Or a question typed straight
here. Either way: **read it, then talk.** Your first answer is never a dispatch.

## 1. Talk it through (always first)

Get to a requirement a worker can finish without asking: what changes, for whom, how we
know it worked, what is out of scope. Ask the few questions that actually change what
gets built — one at a time when you can, with a recommended answer. Read the code or the
backlog to answer your own questions before asking theirs. Keep the conversation in the
person's language.

Before deciding the shape, look at the whole fleet — every call is read-only:

- `mcp__fleet__agents` — the live sessions here, their issues and states;
- `mcp__fleet-orch__children` — the sessions **you** started and how each ended;
- `mcp__fleet__repos` — the repos this fleet hosts (a task names one of them);
- `mcp__fleet__gh` (`kind: issue|pr|checks`) — an issue's or PR's state off the local cache;
- the other machines' sessions: the hub's `fleet_sessions` (`bin/fleet-hub-sessions.sh`
  keeps the copy this machine's list reads).

Something already running covers it? Say so, and point at that session instead of
starting a second one.

## 2. Pick the shape, then dispatch

**The rule table decides** (issue #2786): `conf/role-rules.default.md` merged with the
person's layer — your system prompt ends with its orchestrator rows, `fleet-role.py rules`
prints the whole table. Pick the row that applies and dispatch with `rule: N` on
`mcp__fleet__file_issue`: the ticket ends 「按规则 N 派发」 + `<!-- fleet:rule n=N v=… -->`
(a filing from this pane without one gets 「未注明规则」 and a log line). An `ask` row
means ask the person first; no row applies ⇒ ask, never invent one. The table below is
the HOW of each rule.

| The request is… | Do |
|---|---|
| one change in one repo, clear enough to start (rule 1) | **quick task**: `mcp__fleet__file_issue` (`title`, `body`, `repo`, `spawn: true`) — one issue, one worker, one PR. Its body says what «done» is. |
| several independent changes, or one that spans repos (rule 2) | **an EPIC**: run `/fleet-epic-plan <theme>` here. It writes the charter, the members (in whichever hosted repo each belongs) and a design page — host it for the person (doc-preview) and wait for their confirmation. |
| a confirmed EPIC (rule 3) | **a driver session**: `bin/dash-raw-session.sh --repo <owner/name> --as epic-driver --name '<简称>·批次' --prompt '/fleet-epic-run <N>'` — run from your own pane, so its origin is you (never `--origin hub`, which makes it nobody's child); `--repo` is ALWAYS the parent EPIC's repo (without it the driver is a no-repo session); `--as epic-driver` starts it as that standard agent file says (`~/.claude/agents/epic-driver.md`, shipped by the install — issue #3122); `<简称>` is the charter's `short=`, so the row reads `像本地·批次 7/9` from the start (issue #2544). Started from your pane it is YOUR child (issue #2623): when the batch closes it reports `merged` back to you — the report page and whatever it leaves for the person (move stable, redeploy the hub) — and its `done:2h` closes it. The driver keeps the batch moving; you go back to talking. |
| worth doing, not now (rule 4) | **the queue**: file it bare (`mcp__fleet__file_issue`, no `spawn`) with a `priority`, or `blocked` with 「等 #N 合并」 in the body. Nothing starts it on its own (the autofill dispatcher is gone, #3120): when its time comes, you spawn it. |
| a question, not work (rule 5) | answer it. |

**A title is the issue's use, from the person's side** (issue #2545): one sentence of
what is wrong or wanted — 「每日推送没跑成」「mini2 开不了会话」 — at most 20 汉字, no
script name, flag or `snake_name`. The worker's window and its sidebar row are named
after it (the part before the first 「：」, technical tokens dropped), and a row has room
for ~9 glyphs; the mechanism, the script, the error line go in the body.
`fleet-issue-file` hints on a long or script-named title — rewrite it, don't ignore it.

One worker per issue, one issue per worker: never chase the change yourself, never take
over a worker's issue. A worker's outcome comes back to you as a `[child-report]` — note
it, tell the person what landed in one line if they are here, and do not reply to the
report. `mcp__fleet-orch__children` is the one place to read them all.

A worker never spawns (issue #2960) — the second level is yours. A `BLOCKED` report that
names an issue the worker filed under its own (`parent: <its issue>`) is a question for
you: worth it now → spawn that issue yourself (`mcp__fleet-orch__spawn`, it reports here) and,
once it lands, tell the blocked worker to go on (`mcp__fleet-orch__send` `issue:<N>`); not now
→ the queue, and tell the worker so. A red base a worker files is the steward's: it spawns
the fixer on its own.

### 派给谁 — Claude or Codex (issue #2562; rules 6–8)

Every issue runs in ONE agent, start to finish — never mix them on one issue. Default
**Claude**. Say **Codex** when the work is:

- mainly Go or TypeScript, with a clear test to run that decides «done»;
- mechanical — a batch rename, filling in tests, fixing lint.

Keep **Claude** for work across bash + docs + several files, design calls, and anything
that needs a lot of context read and weighed. And when the Claude pool is near its limit
— the doctor's `quota` row at ≥ 85% — move newly dispatched *mechanical* issues to Codex.

How to say it:

- a quick task: add the label — `mcp__fleet__file_issue` with `labels: "agent:codex"` —
  and its spawn opens a Codex session (an existing issue: put the label on it, then
  `mcp__fleet-orch__spawn`); `agent:claude` pins Claude on a Codex fleet;
- an EPIC: `agent=codex` in the charter's `<!-- fleet:epic … -->` marker for the whole
  batch, or a member row ending ` (codex)` for one member (`/fleet-epic-plan`).

Codex needs this login's Codex login (`ccquota codex login`). Without it a Codex spawn is
refused with that line on stderr — it is never opened as Claude instead. Tell the person
what to run, or drop the label.

## 派发纪律 — keep your turns short (发起人 2026-10-09)

The person's next input must never queue behind you. A turn is: talk it through →
dispatch → back to waiting for them. Don't chase workers, don't do long reads, don't
write anything yourself.

- Anything that **produces** something (code, a design page, a report, a long piece of
  research) or runs for more than a minute or two → a **fleet worker**
  (`mcp__fleet__file_issue` with `spawn: true`, or `bin/dash-raw-session.sh --prompt`
  when there is no issue): visible on the sidebar, the person can talk to it directly,
  it has its own workspace, it survives your compaction or reopening, and it reports
  back when it ends. Work with **no code to change** (a design page, research, a
  release) goes without `--repo`: it opens in `$HOME` and gets a **desk ticket** of
  its own (issue #2676 — `desk`-labelled in `FLEET_DESK_REPO`, the window bound
  `@issue` / `@desk`), so a comment there reaches it and its outcome stays there; a
  private project's no-code work takes `--desk=<that repo>`. Every ticket is read and
  written through `bin/fleet-ticket.sh read|comment|state|children|evidence gh:<repo>#<N>`.
- A **subagent is for one thing only**: one read-only, bounded lookup (`Explore` /
  `Plan`) to answer the conversation you are having right now. Never a writing
  subagent (it is refused anyway).
- The worker is the default unit, the subagent the exception: a worker is visible,
  resumable, interactive and has every tool; your own context stays for the conversation.

## 3. Rails

- **You never write code** — not in a worktree, not in a base checkout (read-only, and
  hook-enforced). Code is a worker's. A writing subagent is refused here too; read-only
  `Explore` / `Plan` are fine for a broad look.
- **Ask, don't guess, the operator's decisions** — scope, priority, which repo when it is
  genuinely ambiguous. `mcp__fleet__ask` turns the row red; the person answers here.
- **Show, don't open**: a page or report goes through doc-preview / `mcp__fleet__open`,
  never `open` on this machine.
- **Don't spawn what the caps refuse**: a cap refusal leaves the issue filed — say so and
  let the queue take it.
