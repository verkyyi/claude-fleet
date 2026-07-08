# claude-fleet — glossary

Every term used across the scripts and docs, grouped by layer. If a word is
overloaded (looking at you, "session"), that's called out explicitly.

## The substrate — tmux

claude-fleet runs entirely inside **tmux**, the terminal multiplexer. tmux
nests three levels, and this is where the confusing vocabulary starts:

- **tmux session** — a whole workspace. In the multi-fleet model, **one tmux
  session = one fleet = one GitHub repo** (see [ARCHITECTURE](ARCHITECTURE.md)).
- **tmux window** — a tab inside a session. Each window usually holds one Claude
  session working one task in its own worktree, plus a few special windows (the
  dashboard, the steward).
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
  Every ~60s it does all the slow/external work — calls the GitHub API (open
  PRs + their CI state, open issues), runs `git status` on each worktree, counts
  context tokens per Claude session, scrapes usage/rate-limit — and writes each
  result to a small **cache file**. It renders *nothing*. Everything you see is a
  cheap read of the files the collector produced, which is why the UI is
  instant. See [ARCHITECTURE](ARCHITECTURE.md) for why there is exactly **one,
  shared** collector even when you run many fleets.
- **Steward** — a long-lived **Claude session** that watches a whole repo instead
  of working a single task: runs a sweep on a loop, closes finished issues,
  triages new ones, checks prod health, keeps the fleet tooling healthy.
  **One steward per fleet** (per repo). Its standing orders live outside this
  repo (they're operator-specific).
- **Sweep** — the recurring *task* a steward runs (typically `/loop 45m /sweep`).
  One sweep = one pass over repo status → finished-issue closing → new-issue
  triage → prod health → context rotation → fleet hygiene.
- **Scheduler** — whatever starts the collector on a timer: **launchd** on macOS
  (`launchd/com.claude-fleet.collect.plist.tmpl`), a **systemd** user timer on
  Linux (`systemd/claude-fleet-collect.timer`).

## What you see (rendered surfaces)

All three are **read-only views of the cache files** — they do no slow work, so
they repaint instantly:

- **Dash / dashboard** — `bin/tmux-dashboard.sh` + `bin/tmux-dashboard-rows.sh`,
  opened with `prefix+j`. A full-screen grid, one row per Claude session/window:
  branch, dirty flag, context %, PR number + CI symbol. Mission control.
- **Status bar** (a.k.a. status line) — `bin/tmux-status.sh` plus the
  window-name format. The thin strip tmux always shows; renders a per-window
  attention marker (`✓` / `✗` / `!`) and a right-side summary.
- **Backlog panel** — `bin/tmux-issues.sh`, opened with `prefix+b`. An fzf popup
  listing the repo's open GitHub issues — the triage queue.

## The data (files the collector writes, the views read)

- **Cache dir** — `$TMPDIR/.claude-dash/`. Holds the cache files:
  - **`prmap`** — `branch <TAB> #num <TAB> state <TAB> ci-symbol` per open PR.
  - **`issues`** — `milestone <TAB> #num <TAB> assignee <TAB> title` per open issue.
  - **`git_<key>`** — per-worktree branch + dirty flag.
  - **`ctx_<key>`** — per-Claude-session model + context-token count (feeds ctx%).
  - **`usage`** — token-consumption proxy (5h / 7d).
  - **`ratelimit`** — last-seen weekly-% line + timestamp.
  - `*.ts` siblings are fetch timestamps for TTL throttling.
- **Ledger** — a steward's private notes file (last-seen repo HEAD, last-triaged
  issue, armed fixes). **One writer per ledger** — only that steward edits it.
  Lives in the operator's memory store, not in this repo.

## Concepts / mechanisms

- **Worktree** — a `git worktree`: a second working directory sharing one repo's
  history, on its own branch. The core rail — the base checkout is treated as
  read-only, so every edit happens in a per-task worktree that lands via PR.
  `bin/worktree-autoclean.sh` (the **janitor**) removes worktrees whose branch
  has merged.
- **Attention signal** — the collector/hooks tag a window when its Claude session
  needs you: spinner while working, `✗` for failing CI, `!` when blocked on your
  answer. `bin/tmux-sort-windows.sh` slots the most urgent window to position 1.
- **Escalation** (detached notify) — if a session is blocked on your input past a
  threshold **and no tmux client is attached** (you're away), the collector runs
  `FLEET_NOTIFY_CMD` with the message. So you're pinged only when you're not
  looking. A ready WeCom notifier ships in `extras/`.
- **Context rotation** — when a Claude session's context fills (≥ ~50%), the
  steward can hand it off (write a state doc) → clear → pick up fresh, so a
  long-running `/loop` doesn't die at the context limit.
- **Handoff** — a doc that lets a fresh Claude session continue the same work
  from where another left off.
- **Account pool / failover** — an optional set of Claude *subscription* accounts
  (one `claude setup-token` OAuth token per file under `FLEET_ACCOUNTS_DIR`). The
  launcher `bin/fleet-claude.sh` exports the **active** account's token per
  session; when a session prints a usage-limit banner, the collector marks that
  account and `bin/fleet-account.sh` **rotates** the active pointer, so new
  sessions fail over to a fresh subscription. Off unless token files exist. See
  [MULTI-ACCOUNT](MULTI-ACCOUNT.md).

## Configuration

- **`fleet.conf`** — the per-fleet config (`fleet.conf.example` is the template):
  - `FLEET_REPO` — `owner/name` of the repo whose issues/PRs this fleet tracks.
  - `FLEET_MAIN` — path to the local main checkout (worktrees are siblings).
  - `FLEET_BASE_BRANCH` — branch new work forks from / merged-ness is measured against.
  - `FLEET_PROTECTED_RE` — branches the janitor must never touch.
  - `FLEET_CTX_WINDOW` — context size for the ctx% column (200000 / 1000000).
  - `FLEET_NOTIFY_CMD` / `FLEET_ESCALATE_AFTER` — detached-escalation notifier + delay.
  - `FLEET_STATUS_CONTAINER` — optional docker container to show as ●/○.
  - `FLEET_ACCOUNTS_DIR` / `FLEET_ACCOUNTS` / `FLEET_ACCOUNT_LIMIT_TTL` — multi-account
    failover pool (see [MULTI-ACCOUNT](MULTI-ACCOUNT.md)); off unless token files exist.
- **`FLEET_ID`** — the fleet's identity = its tmux session name. In the
  multi-fleet model this is the key that scopes a fleet's config and cache. See
  [ARCHITECTURE](ARCHITECTURE.md).
- **Per-fleet conf** — `$FLEET_CONF_DIR/<session>.conf` (default
  `~/.config/claude-fleet/`), one per fleet; it overlays the global `fleet.conf`
  for that session. Written by `fleet-up.sh`.

## Fleet lifecycle commands

- **`fleet-up.sh <owner/repo> [<dir>]`** — bring up a fleet: reuse-or-clone the
  checkout, write the per-fleet conf, open the `work` + `dash` windows, kick the
  collector. A fleet ≡ a tmux session ≡ one repo.
- **`fleet-down.sh <session> [--purge]`** — kill the session (the checkout is
  always left on disk); `--purge` also removes the conf + this fleet's slug'd
  cache.
- **`fleet-list.sh`** — list fleets: `●` live / `○` down · name · repo · checkout.
- **`fleet-lib.sh`** — the shared helper library the above (and the collector /
  read-side producers) source: session→repo resolution, slug helpers, per-fleet
  conf overlay.

---

**One-liner for "collector":** the background process that talks to GitHub and
git on a timer and dumps the answers into small files, so the dashboard, status
bar, and backlog are cheap reads instead of slow live queries.
