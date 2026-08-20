# Fleet commands — the repo-shipped `/skill` contract

This directory holds **fleet skills**: Claude Code slash commands, shipped with
the repo, that operate on a fleet (a tmux session ↔ one GitHub repo). They are
the fleet-aware cousins of your personal `~/.claude/commands/` skills
(`/sweep`, …) — optional quality-of-life helpers a fleet operator
runs from inside a session.

They are **installed by copying** `commands/*.md` into the Claude Code user
commands dir (`~/.claude/commands/`), appended alongside — never clobbering —
any personal commands you already have. See the install step in
[`docs/INSTALL.md`](../docs/INSTALL.md).

> Phase 0 landed **just the contract** — this README and
> [`_template.md`](_template.md); the functional skills (`/fleet-claim`,
> `/fleet-handoff`, …) land one per sub-issue, each cloning the template and filling in
> its body. See **Shipped skills** below for what's live so far.

## Shipped skills

| Skill | Owner | What it does |
|---|---|---|
| [`/fleet-claim`](fleet-claim.md) | worker | The whole worker lifecycle (issue #283). Its step-0 preamble is a SINGLE call — [`bin/fleet-claim-brief.sh`](../bin/fleet-claim-brief.sh) (issue #458) — that resolves the fleet, guards the worker seat, reads the bound issue in ONE `gh` round-trip (thread + comments + the **assignee** that IS the claim, idempotent with the spawner's pre-claim), and prints the layered **worker charter** (built-in ▸ gated repo `.fleet/worker.md` ▸ fleet overlay) plus the per-fleet implementation directive; atomic, so a worker can no longer skip the charter half. Then ground in the issue + code, then implement under a standing contract that ends by opening a PR and **landing it itself** once `bin/fleet-pr-verdict.sh` reads `READY` (`gh pr merge --<FLEET_MERGE_METHOD> --delete-branch`, issue #441) — or signals a blocker on the issue. May also `--spawn` the follow-ups it files. Subsumes the retired `/fleet-ship` + `/fleet-blocked`. |
| [`/fleet-sync-install`](fleet-sync-install.md) | either | Any fleet: maintains the shared live install (`~/.claude/fleet`) — after claude-fleet's own PRs land, re-apply them: pull + reload changed daemons + re-merge the hooks delta + install changed commands. Idempotent; refuses only if `~/.claude/fleet` isn't a git checkout. |
| [`/fleet-history`](fleet-history.md) | hub | Browse & resume **landed** (merged + cleaned-up) sessions from the history ledger (written by the cleanup daemon / a manual reap before worktree removal). Lists finished work, opens the PR, pages the surviving transcript, and **resumes** a session by reconstructing its removed worktree off the squash SHA → `claude --resume` (or `--from-pr`). Backed by [`bin/fleet-history.sh`](../bin/fleet-history.sh); mirrored in the dash's live⇄landed **⌃t** toggle. |
| [`/fleet-handoff`](fleet-handoff.md) | either | Bridge long-running work across a context-window boundary **inside a fleet pane**. Cycle mode writes a full handoff doc (delegating to the repo-shipped base `handoff` skill — `skills/handoff/SKILL.md`, issue #311; a worker commits `doc/handoff/<slug>.md`, the hub writes `~/.claude/handoff/<session>-<date>.md`) then arms a detached, self-terminating helper ([`bin/fleet-handoff-cycle.sh`](../bin/fleet-handoff-cycle.sh)) that waits for the turn to end (`@claude_state` leaves `working`), `/clear`s the pane, and types `/fleet-handoff pickup <doc>` to resume — the self-clear a session can't do to itself. `pickup <path>` mode runs the base PICK-UP. Fail-safe: every failure degrades to "doc written, context not cleared". |
| [`/fleet-context`](fleet-context.md) | either | Answer "how full is my own context window?" (issue #464) — the read Claude Code gives the human (`/context`, the statusline bar) but not the model. Backed by [`bin/fleet-context.sh`](../bin/fleet-context.sh), which folds TWO sources: the `@ctx_pct` stamp `conf/statusline.sh` already writes for the auto-handoff nudge (issue #330), and this session's own transcript — the last main-thread assistant record's usage IS the live context, which also yields turns, output tokens and the pre-compact peak (sidechain/subagent rows excluded). Prints a `verdict:` — `OK` / `WATCH` / `HANDOFF` / `UNKNOWN` — on the same bands the auto-handoff nudge uses, so a worker can decide *mid-task* whether to start one more sweep or run `/fleet-handoff`. Read-only; exit 0 ⇔ `OK`. |

## Two kinds of fleet skill

Not every fleet skill is a human-invoked playbook. The contract covers **two
kinds**, distinguished by how they are invoked and what they may do:

| | **A. Interactive / role skill** | **B. Background-job prompt** |
|---|---|---|
| Examples | `/fleet-claim`, `/fleet-history`, `/fleet-sync-install` | `classify-session`, `summarize-session` |
| Invoked by | the operator or a worker, on demand | a `claude -p` daemon (on a timer/hook) |
| Template | [`_template.md`](_template.md) | [`_template-background.md`](_template-background.md) |
| Step-0 preamble | **yes** — resolve fleet + guard seat | **no** — a daemon has no seat |
| Marker | `<!-- fleet skill · owner: … -->` | frontmatter `disable-model-invocation: true` |
| Body | a numbered playbook that runs `gh`/`git`/tmux | a **pure prompt**, no tool use |
| Contracts | seat guard + fleet guard | an **input** contract + an **output** contract |

Everything under *The contract every fleet skill follows* below describes **kind
A**. Kind B is a versioned prompt, not a playbook: today the daemons carry their
prompt as a hardcoded heredoc (`bin/classify-sessions.sh`, `bin/tmux-summarize.sh`);
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
| `worker`  | the current tmux window has `@issue` set **and** cwd is inside an `issue-<N>` git worktree | a session bound to one issue, implementing it |
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
