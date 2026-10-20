# claude-fleet — glossary

Every term used across the scripts and docs, grouped by layer. If a word is
overloaded (looking at you, "session"), that's called out explicitly.

## The substrate — tmux

claude-fleet runs entirely inside **tmux**, the terminal multiplexer. tmux
nests three levels, and this is where the confusing vocabulary starts:

- **tmux session** — a whole workspace. **One tmux session = one fleet**, and a
  fleet hosts zero or more repos. **One fleet per login** holds every repo
  that login works on — you pick a repo, you never switch fleets (#980); several
  fleets on one machine means several logins (see [ARCHITECTURE](ARCHITECTURE.md)).
- **tmux window** — a tab inside a session. Each window usually holds one Claude
  (or Codex) session working one task in its own worktree, plus the resting `home`
  window.
- **tmux pane** — a split within a window.

> ⚠️ **"session" is overloaded.** Two different things:
> - **tmux session** — the workspace above.
> - **Claude session** — one running instance of Claude Code (one conversation).
>   A Claude session lives *inside* a tmux window.
>
> When it's ambiguous, the docs say "tmux session" or "Claude session"
> explicitly.

## The moving parts (things that run)

- **Collector** — `bin/tmux-dash-collect.sh`. The background data-gatherer.
  Every ~60s it does all the slow/external work — reads each hosted GitHub
  repo's open issues, reads each worktree's branch (under a
  wall-clock budget, round-robin — #552), counts
  context tokens per Claude session, scrapes usage/rate-limit — and writes each
  result to a small **cache file**. It renders *nothing*. Everything you see is a
  cheap read of the files the collector produced, which is why the UI is
  instant. See [ARCHITECTURE](ARCHITECTURE.md) for why there is exactly **one,
  shared** collector even when you run many fleets.
- **Task record (任务记录, `T<n>`)** — the one ticket a piece of work has: a row
  of the hub's `fleet_tasks`, written BEFORE its session starts (⌘P, the `task`
  tool, an EPIC's members). A task belongs to a **person**, not to a repo; a task
  that names a repo opens a session in a worktree of it, bound to `T<n>`, which
  lands its own PR and closes the record with its report. GitHub hosts the code and
  the PR — nothing claims, comments on or closes a GitHub issue.
- **Hub (入口)** — the coordinator, `tokenledger`'s `ccquota` server: accounts,
  the subscription pool, task records, placement, the console. (A tmux pane marked
  `@hub=1` — `bin/hub-session.sh` — is an older, local meaning: a plain operator
  session in the base checkout.)
- **Orchestrator** (编排会话) — a session TEMPLATE, not a seat or a window the fleet
  keeps: `spawn agent:orchestrator` (or `claude --agent orchestrator`) opens one bound
  to no task; it talks a request through with you and then dispatches it (a quick
  task, an EPIC), never writing code itself (issues #1957, #4335). Several
  may run at once, each looking after what it dispatched; nothing opens or reopens one
  (issue #3118), and there is no role to take (issue #4340). Instructions: the
  template, [`conf/agent-defaults/claude/agents/orchestrator.md`](../../conf/agent-defaults/claude/agents/orchestrator.md).
- **Scheduler** — whatever starts the collector on a timer: **launchd** on macOS
  (`launchd/com.claude-fleet.collect.plist.tmpl`), a **systemd** user timer on
  Linux (`systemd/claude-fleet-collect.timer`).

## What you see (rendered surfaces)

Both are **read-only views of the cache files and window options** — they do no
slow work, so they repaint instantly:

- **看台 (the view) and its task list** — `fleet` on a person's terminal
  (`bin/fleet_view.py`): the session in view, the task list beside it (rows from
  `bin/tmux-dashboard-rows.sh`, one per session) and ⌘P's panel to switch, open or
  answer. See [CLIENT](CLIENT.md).
- **Status bar** (a.k.a. top line) — `bin/fleet-topbar.py`. The thin strip
  above the session; renders its attention marker (`✓` / `✗` / `!`), context and
  model.

## The data (files the collector writes, the views read)

- **Cache dir** — `$TMPDIR/.claude-dash/`. Holds the cache files:
  - **`prmap`** — `branch <TAB> #num <TAB> state <TAB> ci-symbol <TAB> ready <TAB> sha`
    per PR (newest PR per branch); for a repo with no GitHub the cleanup daemon
    writes git's own (one MERGED row per landed branch). The worker's merge gate
    (`bin/fleet-pr-verdict.sh`) asks GitHub itself.
    `ci-symbol` ∈ `·` no checks · `✗` any red (FAILURE / TIMED_OUT / CANCELLED /
    ACTION_REQUIRED, or a StatusContext FAILURE / ERROR) · `…` not final ·
    `✓` green. `ready` (land-readiness of an OPEN + green PR, from `isDraft` /
    `mergeStateStatus` / `mergeable`) ∈ `draft|conflict|ready|behind|blocked|unknown|""`;
    the list decorates a green PR's `✓` with it (`✓d` draft · `✓!` conflict ·
    `✓↑` behind · `✓·` blocked · `✓?` mergeability not computed yet · bare `✓`
    = ready). `sha` is the merge commit of a MERGED PR, else empty (issue #541).
    First 4 fields are a stable contract.
  - **`issues`** — `milestone <TAB> #num <TAB> assignee <TAB> title` per open issue.
  - **`git_<key>`** — per-worktree branch (+ahead/-behind). Field 2 was a dirty
    flag no reader consumed; the `git status` that computed it was the collector's
    single slowest call and is gone (#552).
  - **`ctx_<key>`** — per-Claude-session model + context-token count (feeds ctx%).
  - **`usage`** — token-consumption proxy (5h / 7d).
  - **`ratelimit`** — last-seen weekly-% line + timestamp.
  - `*.ts` siblings are fetch timestamps for TTL throttling.
- **Ledger** — the operator's private notes file for a fleet (last-seen repo
  HEAD, last-triaged issue, armed fixes). **One writer per ledger.**
  Lives in the operator's memory store, not in this repo.

## Concepts / mechanisms

- **Worktree** — a `git worktree`: a second working directory sharing one repo's
  history, on its own branch. The core rail — the base checkout is treated as
  read-only, so every edit happens in a per-task worktree that lands via PR.
  `bin/worktree-autoclean.sh` (the **janitor**) removes worktrees whose branch
  has merged.
- **Attention signal** — the collector/hooks tag a window when its Claude session
  needs you: spinner while working, `✗` for failing CI, `!` when blocked on your
  answer. These surface in the task list (which sorts its own rows); tmux
  windows themselves are not reordered.
- **Escalation** (detached notify) — if a session is blocked on your input past a
  threshold **and no tmux client is attached** (you're away), the collector runs
  `FLEET_NOTIFY_CMD` with the message. So you're pinged only when you're not
  looking. A ready WeCom notifier ships in `extras/`.
- **Context rotation** — when a Claude session's context fills (≥ ~50%), it can
  hand itself off (`/fleet-handoff`: write a state doc → clear → pick up fresh),
  so long-running work doesn't die at the context limit.
- **Handoff** — a doc that lets a fresh Claude session continue the same work
  from where another left off.
- **Spawn provenance / child report** — every spawned window carries `@origin`:
  the key (`issue-<N>` / `scratch-<N>`, or the `@fleet_id` of a session with no
  key) of the session that spawned it, empty for the operator. The task list NESTS
  every child directly under its own parent, one level per generation (issue #1328;
  the indent stops growing at 4), two cells a level. Every level folds on its own. Position is the whole story — there is no
  `↳#483` parent tag any more; an **orphan** whose parent window is gone sinks
  below the live list (blank tree cell).
  Since #574 `@origin` is also an **address** — `bin/fleet-report-parent.sh`
  resolves it back to the parent's live window and pushes a fixed four-line
  `[child-report]` over the peer inbox when the child merges, blocks, or is
  reaped. So a worker that dispatched a follow-up hears the outcome instead of
  polling for it. Operator-spawned work sends nothing; `FLEET_CHILD_REPORT=0` turns it
  off per fleet. Since #624 the parent's own row also carries the **aggregate**
  the individual reports never added up to — `3/5`: three of its five
  descendants done — on EVERY level (#1328), so each count describes exactly the
  block under it; a child asking for you is the red `!` on its own row, which no
  fold hides. A row that spawned nothing draws nothing. Since #937 every report is also **recorded**, delivered or not, in
  the parent's **children ledger** — `$FLEET_STATE/children/<parent-key>.ndjson`
  (keyed by the parent's key, not its window id, so a migrated parent keeps its
  book). `bin/fleet-children.sh` merges that ledger with each child's live state
  into one line per child plus the same `3/5 ✓ · 1!` summary the list draws —
  one command instead of a `gh pr` + capture-pane per report — the check
  `/fleet-epic-run` prescribes on a report (#940). Since #938
  each event also carries a **tier** (`report_tier`): **loud** (someone must act —
  BLOCKED, FAILED not being fixed, REAPED unmerged/dirty, a true STOPPED, a child
  in `needs`) and **quiet** (MERGED, FAILED while fixing) are delivered; **silent**
  (WAITING / IDLE — a turn ended on an open PR or a background job) is ledger-only
  and never wakes the parent. Since #939 `FLEET_CHILD_REPORT=batch` also holds
  the quiet ones: the cleanup tick (`bin/fleet-children-flush.sh`) delivers them
  merged into one **children digest** — `[children-digest] 3/5 ✓ · 1 ⏳ · 1 !`
  plus one line per child that changed since the last digest (a
  `<parent-key>.cursor` beside the ledger) — when a loud report arrives (at once),
  every child is terminal, the parent is idle, or the oldest has waited
  `FLEET_CHILD_REPORT_BATCH_SECS` (300). The default stays `immediate`.
- **Fold** — a parent's block is **collapsed by default** in the task list: the
  list shows one line per parent, marked `▸` (`▾` when open), and its aggregate
  badge is what the folded block says. The `fold` key (⌘., bound when the person
  names it in `FLEET_KEYS_EXTRA`) opens or shuts the block of the session in view. Two things never fold: a child in `needs` (the
  quiet layer folds, the loud one does not) and an **orphan**, whose parent
  window is gone — there would be no row left to open it from. The live list
  keeps the bit on the window (`@expand`, so it dies with the window).
- **Account pool / failover** — an optional set of Claude *subscription* accounts
  (one `claude setup-token` OAuth token per file under `FLEET_ACCOUNTS_DIR`). The
  launcher `bin/fleet-claude.sh` exports the **active** account's token per
  session. A running session that fills is never moved: the credential pool
  changes its subscription (the per-session failover planner is retired, T546).
  Off unless token files exist. See
  [MULTI-ACCOUNT](MULTI-ACCOUNT.md).

## What a computer is — client, hub, managed node

A fleet has three roles, and only one runs tasks (issue #4886):

- **client (客户端)** — a person's terminal: it connects, looks and opens
  windows. It hosts no repo and runs no task.
- **hub (入口)** — the coordinator (`tokenledger`'s `ccquota` server).
- **managed node (托管节点)** — a login of a 托管 machine (the two Mac minis) or
  an execution pod of the `fleet-workers` cluster. Tasks run here only.

The hub types every node it knows — `endpoints.role`, `managed` or `client` —
when it joins (a 托管 join code and a login the hub opened: managed; a device's
`fleet login`: client; a plain code: the `role` it was minted with, else
untyped), and the operator changes it
(`bin/fleet-node-role.sh plan|set|apply`, `GET/POST /v1/fleet/nodes/role`). A row
from before #4886 is untyped ("") until the backfill writes it: untyped is never
client, so everything reads as before. A client is passed over by placement,
skipped by the repo-authority check (listed under `client_hosts`, blocks
nothing), may not reserve a local start, and refuses on its own side —
`fleet-client-core.sh`'s `fleet_client_refuse` (the hub's word through
`GET /v1/node/self`, kept an hour in `$FLEET_CONF_DIR/node-role` and refreshed
by the diskguard tick's `node_role_watch`) in `fleet-repo.sh add` and
`fleet host on` (asked fresh) and a spawn that would open here (the kept word
only — a spawn never asks the hub):
「这台是客户端，任务在托管节点上跑」. `FLEET_ALLOW_CLIENT_TASKS=1` is the hatch.
No hub, no node token ⇒ unknown ⇒ byte for byte as before.
`fleet-node-role-selftest.sh`, `TestRepoAuthorityClientHostBlocksNothing`,
`TestNodeRoleRoute`.

## What a computer is — fleet and 承载

A person sees two words for a computer, and only two (issue #1806, EPIC #1813):

- **fleet** — the part every computer has: the `fleet` command, the client it
  opens, the Agent configuration package. Installed with the one install line.
  This is what used to be called the **client**.
- **承载 (host)** — the optional capability on top: this computer also **runs
  sessions**. One key in `fleet.conf`, **`FLEET_HOST=1`**; switched with
  **`fleet host on|off|status`** (`bin/fleet-host.sh`). `fleet doctor` says it in
  one row — `能力  基础 · 承载` or `能力  基础 · 承载 未开（fleet host on）` — and
  a hosting computer gets a `承载` row (which machine, the hub's verdict).

| What you read | What the code and the hub call it | Note |
|---|---|---|
| fleet | client (`fleet-client-update.sh`, `.client-version`, the hub's client manifest) | the installed part everyone has |
| 承载 (host) | **node** — `node.env`, `/v1/node/*`, `fleet node join` / `fleet node compute`, `ccquota agent` | the hub protocol keeps `node`; `fleet host on` runs `fleet node join` (when needed) + `fleet node compute on` |
| 只看只派 / 承载 未开 | a node with `CCQUOTA_FLEET_COMPUTE=0` and no fleet of its own (the install line's coordinate-only join, #1719) | not 承载 |
| `FLEET_HOST=1` | `FLEET_ROLE="client,node"` / `"node"` (issue #1623) | the old key is rewritten by `fleet-conf.sh migrate` and read for one more version |

⚠️ **"host" is overloaded.** `docs/HOST.md` and the doctor's spotlight / pmset
rows (EPIC #1074) mean *the machine itself*; **承载 / `FLEET_HOST`** means the
capability. When it matters, the docs say 承载.

## Configuration

- **`fleet.conf`** — the per-fleet config (`fleet.conf.example` is the template):
  - `FLEET_REPO` — `owner/name` of a hosted repo (one `repos/<slug>.conf` each).
  - `FLEET_MAIN` — path to the local main checkout (worktrees are siblings).
  - `FLEET_BASE_BRANCH` — branch new work forks from / merged-ness is measured against.
  - `FLEET_PROTECTED_RE` — branches the janitor must never touch.
  - `FLEET_CTX_WINDOW` — context size for the ctx% column (200000 / 1000000).
  - `FLEET_NOTIFY_CMD` / `FLEET_ESCALATE_AFTER` — detached-escalation notifier + delay.
  - `FLEET_STATUS_CONTAINER` — optional docker container to show as ●/○.
  - `FLEET_ACCOUNTS_DIR` / `FLEET_ACCOUNTS` / `FLEET_ACCOUNT_LIMIT_TTL` — multi-account
    failover pool (see [MULTI-ACCOUNT](MULTI-ACCOUNT.md)); off unless token files exist.
    A benched account returns at the limit banner's own `resets …` instant; the TTL
    is the fallback for banners that carry no clock time.
- **`FLEET_ID`** — the fleet's identity = its tmux session name. In the
  multi-fleet model this is the key that scopes a fleet's config and cache. See
  [ARCHITECTURE](ARCHITECTURE.md).
- **Per-fleet conf** — `$FLEET_CONF_DIR/<session>.conf` (default
  `~/.config/claude-fleet/`), one per fleet; it overlays the global `fleet.conf`
  for that session. Written by `fleet-up.sh`.

- **Agent 配置的来源：团队 / 个人 / 本机** (EPIC #1855) — where an item an
  agent gets (MCP server, setting, hook, skill, Codex key) comes from. A person
  reads only these words; see [AGENT-CONFIG](AGENT-CONFIG.md).
  - **团队配置 (team layer)** — one bundle for the whole team on the hub (#1726);
    the operator's to change.
  - **个人配置 (personal layer)** — your own bundle on the hub, per person, with
    versions; it follows you to every machine you have a login on (#1856, #1857).
    Only you write it; the operator can only roll it back to one of your versions.
  - **本机 (local)** — this login's own files; it wins over 个人 and 团队.
    「本机独有 N 项」 counts what only this machine has — `fleet config promote`
    takes one into your personal layer.
  - **fleet** — the default (`conf/agent-defaults/`) and the locked items
    (`conf/agent-locked.list`). Machine-readable fields keep the English words
    `default|team|personal|local` (`agent-effective.json`'s `source`).

## Fleet lifecycle commands

- **`fleet-up.sh <owner/repo> [<dir>]`** — bring up a fleet: reuse-or-clone the
  checkout, write the per-fleet conf, open the `home` window, kick the
  collector. A fleet ≡ a tmux session, hosting every repo of the login.
- **`fleet-down.sh <session> [--yes] [--purge]`** — kill the session (the checkout is
  always left on disk) once you type its name (`--yes` from a script); `--purge`
  also removes the conf + this fleet's slug'd cache. `fleet up --undo` brings the
  last down back.
- **`fleet-list.sh`** — list fleets: `●` live / `○` down · name · repo · checkout,
  then `↳` each further repo a fleet hosts.
- **Repo add** — `dash-repo-add.sh`, the add-a-repo popup (issue #1103). Asks only
  `owner/name`, runs `fleet-repo.sh add` (checkout `~/projects/<name>`, cloned if
  missing) and holds the verdict — added · already hosted · the dir is another
  repo · clone failed — until dismissed. The task list regroups on its next frame.
- **`fleet-lib.sh`** — the shared helper library the above (and the collector /
  read-side producers) source: session→repo resolution, slug helpers, per-fleet
  conf overlay.

---

**One-liner for "collector":** the background process that reads git, the
sessions and the usage on a timer and dumps the answers into small files, so the
task list and the top line are cheap reads instead of slow live queries.
