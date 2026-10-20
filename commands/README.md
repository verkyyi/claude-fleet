# Fleet commands — the repo-shipped `/skill` contract

This directory holds **fleet skills**: Claude Code slash commands, shipped with
the repo, that operate on a fleet (a tmux session ↔ one GitHub repo). They are
the fleet-aware cousins of your personal `~/.claude/commands/` skills
(`/sweep`, …) — optional quality-of-life helpers a fleet operator
runs from inside a session.

They reach a session by one of **two install paths** (issue #611):

| | how | typed as |
|---|---|---|
| **plugin** (preferred) | `claude plugin install fleet@claude-fleet` — the repo root IS the plugin ([`.claude-plugin/`](../.claude-plugin)), shipping these commands, the [`skills/`](../skills) tree and the hook table together; `/plugin update` keeps them current | `/fleet:fleet-history` — Claude Code namespaces every plugin command |
| **copy** (historic, still supported) | `commands/*.md` → `~/.claude/commands/`, appended alongside — never clobbering — any personal commands you already have | `/fleet-history` |

Both may be installed at once; they coexist. Nothing in the fleet hardcodes
either spelling — `fleet_cmd` in [`bin/fleet-lib.sh`](../bin/fleet-lib.sh) probes
which path a machine has and returns the form that resolves, which is how the
spawn seed ([`bin/dash-issue-session.sh`](../bin/dash-issue-session.sh)) stays
correct on both. `FLEET_CMD_PREFIX` forces it either way.

⚠️ **A new `commands/fleet-*.md` must be listed in
[`.claude-plugin/plugin.json`](../.claude-plugin/plugin.json)'s `commands` array**
or it ships to copy installs and silently not to plugin installs.
`bin/fleet-plugin-selftest.sh` fails on exactly that drift.

See the install step in [`docs/dev/INSTALL.md`](../docs/dev/INSTALL.md).

> Phase 0 landed **just the contract** — this README and
> [`_template.md`](_template.md); the functional skills (`/fleet-history`,
> `/fleet-handoff`, …) land one per sub-issue, each cloning the template and filling in
> its body. See **Shipped skills** below for what's live so far.

## Shipped skills

| Skill | Owner | What it does |
|---|---|---|
| [`/fleet-sync-install`](fleet-sync-install.md) | either | Any fleet: maintains the shared live install (`~/.claude/fleet`) — after claude-fleet's own PRs land, re-apply them: pull + reload changed daemons + re-merge the hooks delta + install changed commands. Idempotent; refuses only if `~/.claude/fleet` isn't a git checkout. |
| [`/fleet-history`](fleet-history.md) | hub | Browse & resume **landed** (merged + cleaned-up) sessions from the history ledger (written by the cleanup daemon / a manual reap before worktree removal). Lists finished work, opens the PR, pages the surviving transcript, and **resumes** a session by reconstructing its removed worktree off the squash SHA → `claude --resume` (or `--from-pr`). Backed by [`bin/fleet-history.sh`](../bin/fleet-history.sh); mirrored in the dash's live⇄landed **⌃t** toggle. |
| [`/fleet-handoff`](fleet-handoff.md) | either | Continue the same task across a context or agent boundary. No argument: compose with the base `handoff` skill, store a scrubbed issue comment or local file outside the repo, then clear and resume Claude after the turn ends. `pickup [<source>]`: read and continue an existing handoff. `--to codex`: switch one Claude issue/scratch session to Codex CLI through [`fleet-transfer.sh`](../bin/fleet-transfer.sh), after a clean Stop; private notes, original agent/session/transcript paths and a frozen conversation follow the task. No committed handoff files. |
| [`/fleet-epic-plan`](../plugins/fleet-epic/commands/fleet-epic-plan.md) · [`/fleet-epic-run`](../plugins/fleet-epic/commands/fleet-epic-run.md) · [`/fleet-epic-report`](../plugins/fleet-epic/commands/fleet-epic-report.md) | hub | The EPIC trio (issue #720), on hub tasks since issue #4957 — nothing goes to GitHub: an EPIC is a **parent task** `T<n>` whose record holds the charter, its members are its **child tasks**. **plan** turns a **theme** into a bounded batch, proposed as **one design page** (two layers since #839: 用例/目标/指标 on the surface, every technical field in a closed fold; the decider's-view rules of #881/#929) published to 活页 privately and pushed to the operator's WeChat; nothing is made until the operator nods, then ONE `task` call opens the parent task with the charter as its body and starts its session as the batch's driver (`agent: epic-driver`). **run** is that driver's `/loop`, its entire state on the hub, never in context: each tick reads the batch with one call (`bin/fleet-epic-tick.py status` — the charter off the parent's record, each member's child tasks off `…/children`), dispatches what is due as child tasks (`C<k> · <名称>`, in the member's own repo; the hub binds `parent_task`), retries a failure once, answers only the questions the charter covers, rides out a quota ceiling, and writes its tick onto the parent as a progress word (`fleet_task_control.py progress`; the hub shows it as the parent's `progress`). Members land their own PRs (the task flow). The core emptying switches the tick to a **closing sequence that runs `/fleet-epic-report` itself** (issue #852) — `report: pending` first, so a resumed driver re-enters the close; a report that fails is a stall, never a finish — then closes the parent with its result. **report** rebuilds the batch from the hub into the same frame ([`plugins/fleet-epic/skills/epic-page/`](../plugins/fleet-epic/skills/epic-page/template.html)) — 交付了什么 · 指标怎么样 (the plan's metric table read back row by row; 「还读不出来，⟨date⟩ 再看」, or 「本批未声明指标」, never back-filled) · 成员 with the **改动前 · 改动后 · 已上线** evidence grid (#810) · 还差什么 · 下一步 · a folded 运行情况 (worker-hours, labelled as the proxy it is, #625) — publishes it to 活页 privately, pushes it to WeChat and writes the link onto the parent task. `bin/fleet-epic-hub-selftest.sh` runs plan → run → report against a stub hub with GitHub denied; `bin/epic-autoreport-selftest.sh` pins the run→report seam. |
| [`/fleet-move`](fleet-move.md) | either | Move one or more of this fleet's windows to another login's fleet on another machine (issue #1067): `<window>… to <user>@<host>`. Plans first (`--dry-run` probes the target read-only), confirms, then runs [`bin/fleet-move.sh`](../bin/fleet-move.sh) — push the branch if ahead of base, land it in a fresh worktree on the target, stop the source, tar-pipe the transcript, resume there via `claude --resume`, and close the source only once the target is verified live (the fork hazard; `--keep-source` is the deliberate override). Target half: [`bin/fleet-move-remote.sh`](../bin/fleet-move-remote.sh). Exit code is the reason (#683). |
| [`/fleet-onboard`](fleet-onboard.md) | scratch | The first-login guide (issue #1168; rewritten for a non-developer in #3332, EPIC #3178 C20): two or three minutes — hello, one key (⌘P · phone ⌃Space), then the person writes one thing on ⌘P's ⚡ row and watches the session it opens finish. No repo, no issue, no PR, no GitHub on that walk; it takes no role, spawns nothing, files nothing. Its fixed lines come from `fleet-ui-lang.sh` (`onboard_*`, zh + en). The developer walk (repo → issue → PR) left with #4904. Progress lives in `$FLEET_CONF_DIR/global/onboard.state` via [`bin/fleet-onboard.sh`](../bin/fleet-onboard.sh) (`brief` / `look` / `get` / `set` / `reset`), so calling it back resumes at the step it left. The first `brief` also leaves `global/guide.spoke` — a guide window only counts as alive once it has (issue #1215). |
| [`/fleet-compact-resume`](fleet-compact-resume.md) | either | The turn the fleet submits itself after an in-place compaction (issue #1441): the prep step ends the turn and `/compact` leaves the session idle, so [`bin/refocus-hook.sh`](../bin/refocus-hook.sh) spawns [`bin/fleet-compact-resume.sh`](../bin/fleet-compact-resume.sh), which posts this through the mod inbox (else keystrokes behind the typing hold). Its `--brief` prints the seat's check line, the recovery map and git state; the session re-checks and carries on. Skips on a running turn, `needs`, a pending transfer, a Codex pane; `FLEET_COMPACT_RESUME=0` = off. Read-only. |
| [`/fleet-context`](fleet-context.md) | either | Answer "how full is my own context window?" (issue #464) — the read Claude Code gives the human (`/context`, the pane header's `NN%`) but not the model. Backed by [`bin/fleet-context.sh`](../bin/fleet-context.sh), which folds TWO sources: the `@ctx_pct` stamp `conf/statusline.sh` already writes for the auto-handoff nudge (issue #330), and this session's own transcript — the last main-thread assistant record's usage IS the live context, which also yields turns, output tokens and the pre-compact peak (sidechain/subagent rows excluded). Prints a `verdict:` — `OK` / `WATCH` / `HANDOFF` / `UNKNOWN` — on the same bands the auto-handoff nudge uses, so a worker can decide *mid-task* whether to start one more sweep or run `/fleet-handoff`. Read-only; exit 0 ⇔ `OK`. |

## Two kinds of fleet skill

Not every fleet skill is a human-invoked playbook. The contract covers **two
kinds**, distinguished by how they are invoked and what they may do:

| | **A. Interactive / role skill** | **B. Background-job prompt** |
|---|---|---|
| Examples | `/fleet-history`, `/fleet-sync-install` | `classify-session` |
| Invoked by | the operator or a worker, on demand | a `claude -p` daemon (on a timer/hook) |
| Template | [`_template.md`](_template.md) | [`_template-background.md`](_template-background.md) |
| Step-0 preamble | **yes** — resolve fleet + guard seat | **no** — a daemon has no seat |
| Marker | `<!-- fleet skill · owner: … -->` | frontmatter `disable-model-invocation: true` |
| Body | a numbered playbook that runs `gh`/`git`/tmux | a **pure prompt**, no tool use |
| Contracts | seat guard + fleet guard | an **input** contract + an **output** contract |

Everything under *The contract every fleet skill follows* below describes **kind
A**. Kind B is a versioned prompt, not a playbook: today the daemons carry their
prompt as a hardcoded heredoc (the sleep digest did, until T548);
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

### Create work: a task record, not an issue

The operator's **dispatch a worker** op (the `task` tool, `bin/fleet-task-record.sh
dispatch --spawn`) writes the hub's task record `T<n>` first and opens its session
on it; nothing is filed on GitHub (issue #4898).

> **A note on inline vs. delegated work.** Most hub ops run inline on the
> caller's thread, which is right when the work is cheap (the dispatch op
> fires a handful of hub calls). That op is **thin by
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

- `owner: worker` — only a worker may run it (none ships today: the worker's flow rides its SessionStart hook, issue #4898).
- `owner: hub`    — only the operator hub pane may run it, i.e. `$SEAT` must NOT be
  `worker` (e.g. `/fleet-history`, which browses and resumes other sessions).
- `owner: either` — seat-agnostic (e.g. `/fleet-handoff`, `/fleet-sync-install`).
- `owner: scratch` — guarded like `hub` (`$SEAT` must NOT be `worker`), but meant
  for a window of its own — a scratch the operator or the fleet opens for it
  (e.g. `/fleet-onboard`, the first-login guide, which runs in its own pinned
  window rather than inside a worker bound to one issue).

If `$SEAT` doesn't match a non-`either` `owner`, the skill **refuses in one
line and stops** — e.g. *"/fleet-history is hub-only; you're in a worker."*
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
marker, exactly, with a single concrete owner word (`worker`, `hub`, `either`, `scratch`),
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
