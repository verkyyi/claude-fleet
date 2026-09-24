# Fleet commands — the repo-shipped `/skill` contract

This directory holds **fleet skills**: Claude Code slash commands, shipped with
the repo, that operate on a fleet (a tmux session ↔ one GitHub repo). They are
the fleet-aware cousins of your personal `~/.claude/commands/` skills
(`/sweep`, …) — optional quality-of-life helpers a fleet operator
runs from inside a session.

They reach a session by one of **two install paths** (issue #611):

| | how | typed as |
|---|---|---|
| **plugin** (preferred) | `claude plugin install fleet@claude-fleet` — the repo root IS the plugin ([`.claude-plugin/`](../.claude-plugin)), shipping these commands, the [`skills/`](../skills) tree and the hook table together; `/plugin update` keeps them current | `/fleet:fleet-claim` — Claude Code namespaces every plugin command |
| **copy** (historic, still supported) | `commands/*.md` → `~/.claude/commands/`, appended alongside — never clobbering — any personal commands you already have | `/fleet-claim` |

Both may be installed at once; they coexist. Nothing in the fleet hardcodes
either spelling — `fleet_cmd` in [`bin/fleet-lib.sh`](../bin/fleet-lib.sh) probes
which path a machine has and returns the form that resolves, which is how the
spawn seed ([`bin/dash-issue-session.sh`](../bin/dash-issue-session.sh)) stays
correct on both. `FLEET_CMD_PREFIX` forces it either way.

⚠️ **A new `commands/fleet-*.md` must be listed in
[`.claude-plugin/plugin.json`](../.claude-plugin/plugin.json)'s `commands` array**
or it ships to copy installs and silently not to plugin installs.
`bin/fleet-plugin-selftest.sh` fails on exactly that drift.

See the install step in [`docs/INSTALL.md`](../docs/INSTALL.md).

> Phase 0 landed **just the contract** — this README and
> [`_template.md`](_template.md); the functional skills (`/fleet-claim`,
> `/fleet-handoff`, …) land one per sub-issue, each cloning the template and filling in
> its body. See **Shipped skills** below for what's live so far.

## Shipped skills

| Skill | Owner | What it does |
|---|---|---|
| [`/fleet-claim`](fleet-claim.md) | worker | The whole worker lifecycle (issue #283). Its step-0 preamble is a SINGLE call — [`bin/fleet-claim-brief.sh`](../bin/fleet-claim-brief.sh) (issue #458) — that resolves the fleet, guards the worker seat, reads the bound issue in ONE `gh` round-trip (thread + comments + the **assignee** that IS the claim, idempotent with the spawner's pre-claim), and prints the layered **worker charter** (built-in ▸ gated repo `.fleet/worker.md` ▸ fleet overlay) plus the per-fleet implementation directive; atomic, so a worker can no longer skip the charter half. Then ground in the issue + code, then implement under a standing contract that ends by opening a PR and **landing it itself** once `bin/fleet-pr-verdict.sh` reads `READY` (`gh pr merge --<FLEET_MERGE_METHOD> --delete-branch`, issue #441) — blocking on CI with a backgrounded `--wait` instead of re-reading (issue #950) — or signals a blocker on the issue. May also `--spawn` the follow-ups it files. Captures the member's **改动前 / 改动后** evidence along the issue's `上线证据:` line — [`bin/fleet-evidence.sh`](../bin/fleet-evidence.sh) `before` at grounding, `after` + `post` with the PR open (issue #810) — so the EPIC report can show what actually shipped. Subsumes the retired `/fleet-ship` + `/fleet-blocked`. |
| [`/fleet-sync-install`](fleet-sync-install.md) | either | Any fleet: maintains the shared live install (`~/.claude/fleet`) — after claude-fleet's own PRs land, re-apply them: pull + reload changed daemons + re-merge the hooks delta + install changed commands. Idempotent; refuses only if `~/.claude/fleet` isn't a git checkout. |
| [`/fleet-history`](fleet-history.md) | hub | Browse & resume **landed** (merged + cleaned-up) sessions from the history ledger (written by the cleanup daemon / a manual reap before worktree removal). Lists finished work, opens the PR, pages the surviving transcript, and **resumes** a session by reconstructing its removed worktree off the squash SHA → `claude --resume` (or `--from-pr`). Backed by [`bin/fleet-history.sh`](../bin/fleet-history.sh); mirrored in the dash's live⇄landed **⌃t** toggle. |
| [`/fleet-handoff`](fleet-handoff.md) | either | Continue the same task across a context or agent boundary. No argument: compose with the base `handoff` skill, store a scrubbed issue comment or local file outside the repo, then clear and resume Claude after the turn ends. `pickup [<source>]`: read and continue an existing handoff. `--to codex`: switch one Claude issue/scratch session to Codex CLI through [`fleet-transfer.sh`](../bin/fleet-transfer.sh), after a clean Stop; private notes, original agent/session/transcript paths and a frozen conversation follow the task. No committed handoff files. |
| [`/fleet-epic-plan`](fleet-epic-plan.md) · [`/fleet-epic-run`](fleet-epic-run.md) · [`/fleet-epic-report`](fleet-epic-report.md) | hub | The EPIC trio (issue #720): turn a **theme** into a bounded batch, drive it to done unattended across many hours and workers, then report on it. **plan** preflights the repo ([`bin/fleet-epic-preflight.sh`](../bin/fleet-epic-preflight.sh), issue #678), proposes a two-layer list (core = the definition of done; reserve = what to promote if the core finishes early) as **one design page** hosted via `doc-preview` (issue #809; since #881 in the decider's order — 指标 · 范围 · 要做的事 as one themed list of one-line cards · 可能出的问题 · 需要你定的事 (待决 + 拍板, a default on every row) · 能不能开跑 · 执行安排 folded; plain words, no C1/R1 keys on the surface, and the concurrency caps left to the operator). Since #839 the page is **one page, two layers**: 用例/目标/指标 on the surface for whoever decides whether the batch is worth running, every technical field (方案/接口/依赖/完成判据/**上线证据**) in a closed `<details>` under it — nothing removed, both layers written back, so a worker's sub-issue body is a superset of what it was — the confirmation is a URL + one sentence, a revision is `share.sh --refresh` on the same URL — and files **nothing** until the operator confirms; then the page is the single source: the charter goes into one `epic` parent (page URL pinned at the top), each member card into its own real GitHub sub-issue body. Both pages render into the shared frame [`skills/epic-page/`](../skills/epic-page/template.html). **run** is a `/loop` whose entire state lives on the issue, never in context: each tick re-reads the EPIC, lands green PRs (a backstop — workers self-land since #441), reaps finished slots, refills to 4–6, approves `⊘` permissions and answers only the `?` questions the charter already covers (the rest park in 待决), retries a failure once, and rides out a quota ceiling on a low-frequency heartbeat rather than stopping. The core emptying does not stop the loop — it switches the tick to a **closing sequence that runs `/fleet-epic-report` itself, in the same hub session** (issue #852): a batch whose report never ran looks exactly like a finished one from outside, and the page plus the parent comment are the only artefacts that outlive the tick log. The closing tick writes `report: pending` **before** calling the report, so a session that dies between the two leaves the next one a one-grep answer to «核心空了，报告跑了没»; a resumed loop that finds core-empty + `pending` re-enters the close instead of refilling, and re-running the report is cheaper than missing one. A report that fails is a *stalled* notification, never a done one — the done notification carries the report's URL. `bin/epic-autoreport-selftest.sh` pins both ends of that seam. **report** rebuilds the batch from the issue's tick log, renders a page via `doc-preview` (artifacts are hook-blocked in fleet panes, #526) into that same frame — each member card's `.proof` grid showing the **改动前 · 改动后 · 已上线** evidence its worker captured (`bin/fleet-evidence.sh list/export`, #810: **无证据** where there is none, never re-shot, never staged; `live` is the hub's one prod capture after deploy goes green) — and posts the durable half back as a comment. It opens with **交付了什么** and **指标怎么样** — the plan's metric table read back row by row, 「还读不出来，⟨date⟩ 再看」 when the horizon has not passed (re-run the command then) and 「本批未声明指标」 for a batch that declared none, never back-filled (#839); then one 还差什么 · 下一步 table (#929: one row per gap, the next-batch suggestion as a row, no obstacles section — a fleet-side defect is filed as an issue and named only in the durable comment). Wall-clock, 占用时长 and the quota curve keep every number but move into a folded 运行情况 — spend is still **worker-hours**, labelled as the proxy it is, because there is no session→spend join yet (#625). |
| [`/fleet-move`](fleet-move.md) | either | Move one or more of this fleet's windows to another login's fleet on another machine (issue #1067): `<window>… to <user>@<host>`. Plans first (`--dry-run` probes the target read-only), confirms, then runs [`bin/fleet-move.sh`](../bin/fleet-move.sh) — push the branch if ahead of base, land it in a fresh worktree on the target, stop the source, tar-pipe the transcript, resume there via `claude --resume`, and close the source only once the target is verified live (the fork hazard; `--keep-source` is the deliberate override). Target half: [`bin/fleet-move-remote.sh`](../bin/fleet-move-remote.sh). Exit code is the reason (#683). |
| [`/fleet-context`](fleet-context.md) | either | Answer "how full is my own context window?" (issue #464) — the read Claude Code gives the human (`/context`, the statusline bar) but not the model. Backed by [`bin/fleet-context.sh`](../bin/fleet-context.sh), which folds TWO sources: the `@ctx_pct` stamp `conf/statusline.sh` already writes for the auto-handoff nudge (issue #330), and this session's own transcript — the last main-thread assistant record's usage IS the live context, which also yields turns, output tokens and the pre-compact peak (sidechain/subagent rows excluded). Prints a `verdict:` — `OK` / `WATCH` / `HANDOFF` / `UNKNOWN` — on the same bands the auto-handoff nudge uses, so a worker can decide *mid-task* whether to start one more sweep or run `/fleet-handoff`. Read-only; exit 0 ⇔ `OK`. |

## Two kinds of fleet skill

Not every fleet skill is a human-invoked playbook. The contract covers **two
kinds**, distinguished by how they are invoked and what they may do:

| | **A. Interactive / role skill** | **B. Background-job prompt** |
|---|---|---|
| Examples | `/fleet-claim`, `/fleet-history`, `/fleet-sync-install` | `classify-session` |
| Invoked by | the operator or a worker, on demand | a `claude -p` daemon (on a timer/hook) |
| Template | [`_template.md`](_template.md) | [`_template-background.md`](_template-background.md) |
| Step-0 preamble | **yes** — resolve fleet + guard seat | **no** — a daemon has no seat |
| Marker | `<!-- fleet skill · owner: … -->` | frontmatter `disable-model-invocation: true` |
| Body | a numbered playbook that runs `gh`/`git`/tmux | a **pure prompt**, no tool use |
| Contracts | seat guard + fleet guard | an **input** contract + an **output** contract |

Everything under *The contract every fleet skill follows* below describes **kind
A**. Kind B is a versioned prompt, not a playbook: today the daemons carry their
prompt as a hardcoded heredoc (`bin/classify-sessions.sh`);
kind B is where those prompts move so they can be reviewed, diffed, and reused.

### The two contracts a kind-B skill declares

- **Input contract** — where the dynamic payload arrives. The daemon appends the
  prompt body as a system prompt and pipes the payload (a terminal capture, a
  diff, …) on **stdin**; the human/`/why` slash path passes it as **`$ARGUMENTS`**.
  The body is written so it refers to "the input/screen below".
- **Output contract** — the exact, machine-parseable reply shape, stated in one
  line (e.g. *"reply with EXACTLY ONE word and nothing else"*). The caller parses
  the reply, so it must be deterministic and preamble-free.

### How the daemon consumes a kind-B prompt

The cheapest, most deterministic path — used by the `claude -p` daemons — feeds
the prompt body as a system prompt and the payload on stdin (verified on claude
2.1.204):

```sh
printf '%s' "$payload" \
  | claude --bare -p --model haiku --allowedTools "" \
      --append-system-prompt-file <body>
```

- `--bare` skips hooks/LSP/plugins (fast, no side effects); `--allowedTools ""`
  forbids tool use (a kind-B body is a pure prompt); `--model haiku` keeps it
  cheap; `<body>` is the skill's prompt body (frontmatter stripped).
- The **human/`/why` path** may invoke the same prompt as a slash command
  (`/classify-session`). That path pays the normal slash-command discovery cost
  and **won't load under `--bare`** — so it's for interactive one-offs, not the
  hot daemon loop. `disable-model-invocation: true` keeps the prompt from ever
  auto-triggering on either path; it runs only when invoked explicitly.

### Create work: auto-categorize from the LIVE milestone list

The operator's **file + spawn a worker** op (`bin/fleet-issue-file.sh --spawn`,
driven from the hub or the dash) also assigns a best-fit
**milestone** — the fleet's component categories. Fetch them at file time — never
hardcode, since the user adds/renames/closes them: `gh api
"repos/$FLEET_REPO/milestones?state=open" --jq '.[].title'`, pick the one title
that best fits the task, and pass only a title that came back from that live list.
When nothing clearly fits (or there are no open milestones), file with **no**
milestone — never force a wrong/stale name (a bad `--milestone` fails the create).
The op does this and notes the choice in its report.

> **A note on inline vs. delegated work.** Most hub ops run inline on the
> caller's thread, which is right when the work is cheap (`/fleet-claim` posts a
> comment; the file+spawn op fires a handful of `gh` calls). That op is **thin by
> design** — no grounding step (the spawned worker grounds itself), so the inline
> path is fast enough to not need a sub-agent. If a future hub op does
> something genuinely expensive inline, the sub-agent-proxy shape is available —
> guard inline and fail-fast first, then launch one self-contained
> `general-purpose` agent (not a fork) with every rail baked into its prompt and a
> one-line output contract to relay back.

## The contract every fleet skill follows

> This section describes **kind A** (interactive/role skills). For **kind B**
> (background-job prompts) see *Two kinds of fleet skill* above.

A fleet skill is a markdown playbook (a header + a numbered body, exactly like
`sweep.md`). Two rules make it *fleet-aware*:

### 1. It opens with the resolve-and-guard preamble (step 0)

Every skill's first step resolves **which fleet** it is running in and **which
seat** the caller occupies, then refuses early if either is wrong. Copy this
verbatim from [`_template.md`](_template.md):

```sh
source ~/.claude/fleet/bin/fleet-lib.sh
S=$(fleet_current_session); fleet_load_conf "$S"   # → FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH
SEAT=$(fleet_seat)                                 # → worker | "" (the hub pane / a stray shell)
echo "repo=${FLEET_REPO:-} main=${FLEET_MAIN:-} base=${FLEET_BASE_BRANCH:-master} seat=${SEAT:-unknown}"
```

- **No fleet** (`FLEET_REPO` empty) → **abort** in one line. Never guess a repo.
- Capture the printed values: env vars do **not** persist across separate Bash
  tool calls, so read them back from the `echo` and reuse the literals.
- Everything after step 0 operates on the resolved `$FLEET_REPO` / `$FLEET_MAIN`
  / `$FLEET_BASE_BRANCH` only — never another fleet's.

### 2. It declares an `owner:` seat and enforces it

The fleet has ONE seat since issue #439 — `worker`. Everything else (the
operator's hub pane, a panel, a stray shell) is *not* a worker:

| `fleet_seat` | How it's detected | Who it is |
|---|---|---|
| `worker`  | the current tmux window has `@issue` set **and** cwd is inside the worktree it is bound to — an `issue-<N>` directory, or the window's own `@worktree` for a scratch bound in place (#520) | a session bound to one issue, implementing it |
| `""`      | anything else | the operator hub pane (`@hub=1` / `FLEET_HUB=1`), a panel, or a stray shell |

Each skill declares which seat(s) it belongs to, on its marker line (see below):

- `owner: worker` — only a worker may run it (e.g. `/fleet-claim`, which ships its branch).
- `owner: hub`    — only the operator hub pane may run it, i.e. `$SEAT` must NOT be
  `worker` (e.g. `/fleet-history`, which browses and resumes other sessions).
- `owner: either` — seat-agnostic (e.g. `/fleet-handoff`, `/fleet-sync-install`).

If `$SEAT` doesn't match a non-`either` `owner`, the skill **refuses in one
line and stops** — e.g. *"/fleet-claim is worker-only; you're in the hub pane."*
Never proceed from the wrong seat.

### 3. It carries the `fleet skill` marker

Just under the `#` title line, every fleet skill carries an HTML comment
declaring the contract and the owner seat:

```
<!-- fleet skill · owner: worker|hub|either -->
```

This marker is how tooling recognises a fleet skill among your personal
commands: `bin/fleet-doctor.sh` scans the head of each `~/.claude/commands/*.md`
for `fleet skill · owner:` to report how many are installed. Keep it near the
top (within the first few lines) so the scan finds it.

The installer (`bin/fleet-install-apply.sh`, run by `/fleet-sync-install`) is
stricter (issue #858): a file is installed only when one of its lines **is** the
marker, exactly, with a single concrete owner word (`worker`, `hub`, `either`),
outside any code fence. So this README, which only quotes the marker, and
`_template.md`, whose owner is the `worker|hub|either` placeholder, are never
installed as `/README` or `/_template`. Put the marker on its own line.

## `fleet-lib.sh` helpers a skill may use

Already exposed (all cheap, `set -u`-safe — see `bin/fleet-lib.sh`):

- `fleet_current_session` — the tmux session the caller runs in.
- `fleet_load_conf "$S"` — overlay that fleet's conf (sets `FLEET_REPO` etc.).
- `fleet_seat` — `worker` / `""` (anything that is not a worker pane).
- `fleet_slug_cached "$S"` — session → filesystem slug from the collector cache.

## Adding a new fleet skill

**Kind A (interactive/role):**

1. Copy `_template.md` → `commands/<name>.md`.
2. Set the title, the `owner:` on the marker line, and the intent sentence.
3. Fill in the numbered body **after** step 0 (leave the preamble intact).
4. Keep every mutation behind the resolved fleet + seat guard. The base
   checkout is read-only (hook-enforced) — a worker edits inside its
   `issue-<N>` worktree and lands via PR.

**Kind B (background-job prompt):**

1. Copy `_template-background.md` → `commands/<name>.md`.
2. Keep the `disable-model-invocation: true` frontmatter; set the title.
3. Rewrite the body as a **pure prompt** — no step-0 preamble, no tools —
   declaring the **input** and **output** contracts (see *Two kinds* above).
4. Point the consuming daemon at the body via
   `claude --bare -p … --append-system-prompt-file <body>`.
