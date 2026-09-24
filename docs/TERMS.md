# claude-fleet — glossary

Every term used across the scripts and docs, grouped by layer. If a word is
overloaded (looking at you, "session"), that's called out explicitly.

## The substrate — tmux

claude-fleet runs entirely inside **tmux**, the terminal multiplexer. tmux
nests three levels, and this is where the confusing vocabulary starts:

- **tmux session** — a whole workspace. **One tmux session = one fleet**, and a
  fleet hosts one or more GitHub repos. **One fleet per login** holds every repo
  that login works on — you pick a repo, you never switch fleets (#980); several
  fleets on one machine means several logins (see [ARCHITECTURE](ARCHITECTURE.md)).
- **tmux window** — a tab inside a session. Each window usually holds one Claude
  session working one task in its own worktree, plus a few special windows (the
  dashboard, the hub).
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
  PRs + their CI state, open issues), reads each worktree's branch (under a
  wall-clock budget, round-robin — #552), counts
  context tokens per Claude session, scrapes usage/rate-limit — and writes each
  result to a small **cache file**. It renders *nothing*. Everything you see is a
  cheap read of the files the collector produced, which is why the UI is
  instant. See [ARCHITECTURE](ARCHITECTURE.md) for why there is exactly **one,
  shared** collector even when you run many fleets.
- **Hub** — the always-on `plan` window: the dash on top, and below it the
  **operator's own Claude session** in the base checkout (a plain `claude`, no
  charter). This is where you file, triage, spawn workers, hand work back and
  land whatever a worker couldn't — a worker lands its own PR on a green gate
  (issue #441), so the hub only steps in for the strays. **One hub per fleet**; its pane carries `@hub=1` and F9 /
  the ⌂ icon jump to it. There is no resident orchestrator agent — the fleet is
  operator-driven (issue #439). Built by
  [`bin/hub-session.sh`](../bin/hub-session.sh).
- **Scheduler** — whatever starts the collector on a timer: **launchd** on macOS
  (`launchd/com.claude-fleet.collect.plist.tmpl`), a **systemd** user timer on
  Linux (`systemd/claude-fleet-collect.timer`).

## What you see (rendered surfaces)

All three are **read-only views of the cache files** — they do no slow work, so
they repaint instantly:

- **Dash / dashboard** — `bin/tmux-dashboard.sh` + `bin/tmux-dashboard-rows.sh`,
  focused with `prefix+g` (an embedded pane in the `plan` hub). A grid, one row per Claude session/window:
  branch, dirty flag, context %, PR number + CI symbol. Mission control.
- **Status bar** (a.k.a. status line) — `bin/tmux-status.sh` plus the
  window-name format. The thin strip tmux always shows; renders a per-window
  attention marker (`✓` / `✗` / `!`) and a right-side summary.
- **Backlog panel** — `bin/tmux-issues.sh`, opened with `prefix+b`. An fzf popup
  listing the repo's open GitHub issues — the triage queue.

## The data (files the collector writes, the views read)

- **Cache dir** — `$TMPDIR/.claude-dash/`. Holds the cache files:
  - **`prmap`** — `branch <TAB> #num <TAB> state <TAB> ci-symbol <TAB> ready <TAB> sha`
    per PR (`--state all`, newest PR per branch). Folded from the `gh` JSON by
    `FLEET_PRMAP_JQ` (`bin/fleet-lib.sh`), the one program the dash and the
    worker's merge gate (`bin/fleet-pr-verdict.sh`) share (issue #533).
    `ci-symbol` ∈ `·` no checks · `✗` any red (FAILURE / TIMED_OUT / CANCELLED /
    ACTION_REQUIRED, or a StatusContext FAILURE / ERROR) · `…` not final ·
    `✓` green. `ready` (land-readiness of an OPEN + green PR, from `isDraft` /
    `mergeStateStatus` / `mergeable`) ∈ `draft|conflict|ready|behind|blocked|unknown|""`;
    the dash decorates a green PR's `✓` with it (`✓d` draft · `✓!` conflict ·
    `✓↑` behind · `✓·` blocked · `✓?` mergeability not computed yet · bare `✓`
    = ready). `sha` is the merge commit of a MERGED PR, else empty (issue #541).
    First 4 fields are a stable contract.
  - **`deploy_<sha>`** — `<live|deploying|failed|unknown> <TAB> <epoch>` per merge
    sha, beside its `prmap` (`fleets/<slug>/`), written by the PR refresher for a
    fleet that sets `FLEET_DEPLOY_REF` (a local checkout that IS the deployment —
    live ⇔ the sha is an ancestor of its HEAD) or `FLEET_DEPLOY_CHECK=actions`
    (the sha's post-merge workflow runs; folded by `FLEET_DEPLOY_RUNS_JQ`). The
    dash renders a MERGED PR as `merged` (no verdict) · `live` · `deploy…` ·
    `deploy✗`; the landed list's `dep` column as `·` · `live` · `…` · `✗` (#541).
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
  answer. These surface on the fzf dashboard (which sorts its own rows); tmux
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
  the key (`issue-<N>` / `scratch-<N>`) of the session that spawned it, empty for
  the hub. The dash GROUPS children under their parent, marking each one `└` in
  the **tree column** (issue #836 — a fixed 2-cell column between `issue` and
  `window`, so every name starts at the same column and gets the window field's
  full 26 cells whatever its depth), and renders `@origin` as a `↳#483` tag — but
  only where that cell cannot say the same thing: a direct child of the row its
  block hangs off draws no tag (the `└` is the tag), while a **grandchild** keeps
  one (the grouping is two-level-flat, so it is drawn under the ultimate root
  beside its own parent, and `↳#<middle>` is the only thing naming that parent),
  as do an **orphan** whose parent window is gone (blank tree cell) and a
  non-window origin (`↳autofill`, `↳bridge`).
  Since #574 `@origin` is also an **address** — `bin/fleet-report-parent.sh`
  resolves it back to the parent's live window and pushes a fixed four-line
  `[child-report]` over the peer inbox when the child merges, blocks, or is
  reaped. So a worker that `--spawn`ed a follow-up hears the outcome instead of
  polling for it. Hub-spawned work sends nothing; `FLEET_CHILD_REPORT=0` turns it
  off per fleet. Since #624 the parent's own row also carries the **aggregate**
  the individual reports never added up to — `3/5 ✓ · 1!`: three of its five
  descendants done, one asking for you. Same attribution as the grouping, so the
  count describes exactly the block under it; a row that spawned nothing draws
  nothing. Since #937 every report is also **recorded**, delivered or not, in
  the parent's **children ledger** — `$FLEET_STATE/children/<parent-key>.ndjson`
  (keyed by the parent's key, not its window id, so a migrated parent keeps its
  book). `bin/fleet-children.sh` merges that ledger with each child's live state
  into one line per child plus the same `3/5 ✓ · 1!` summary the dash draws —
  one command instead of a `gh pr` + capture-pane per report — the check
  `/fleet-claim` and `/fleet-epic-run` prescribe on a report (#940). Since #938
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
- **Fold** — a parent's block is **collapsed by default** on the dash: the list
  shows one line per parent, marked `▸` in the tree column (`▾` when open —
  directly left of the name it folds, since #836), and its aggregate badge is what
  the folded block says. `→` opens the block the cursor's row owns, `←` shuts the
  block the cursor is *in* (from the parent or from any row inside it, which puts
  the cursor back on the parent); with text typed on the prompt line the arrows
  stay that line's cursor keys. Two things never fold: a child in `needs` (the
  quiet layer folds, the loud one does not) and an **orphan**, whose parent
  window is gone — there would be no row left to open it from. The live list
  keeps the bit on the window (`@expand`, so it dies with the window); the
  **landed** list nests the same way off ledger col 11 and keeps its expanded set
  in a per-fleet file the dash clears at every launch.
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
    A benched account returns at the limit banner's own `resets …` instant; the TTL
    is the fallback for banners that carry no clock time.
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
- **`fleet-list.sh`** — list fleets: `●` live / `○` down · name · repo · checkout,
  then `↳` each further repo a fleet hosts.
- **Repo ask** — `fleet-repo-ask.sh`, the per-spawn "which repo?" popup ⌃n opens
  in a 2+ repo fleet when neither the highlighted row nor a heading names one. It
  picks a destination, not a view: the dash and backlog always show every hosted
  repo, grouped (issue #1034 removed the footer repo picker, `fleet-pick.sh`).
- **Repo add** — `dash-repo-add.sh`, the add-a-repo popup (issue #1103): the
  dash's ⌃z and the task sidebar's row menu `g`, one script behind both. Asks only
  `owner/name`, runs `fleet-repo.sh add` (checkout `~/projects/<name>`, cloned if
  missing) and holds the verdict — added · already hosted · the dir is another
  repo · clone failed — until dismissed. The dash regroups on its next frame.
- **`fleet-lib.sh`** — the shared helper library the above (and the collector /
  read-side producers) source: session→repo resolution, slug helpers, per-fleet
  conf overlay.

---

**One-liner for "collector":** the background process that talks to GitHub and
git on a timer and dumps the answers into small files, so the dashboard, status
bar, and backlog are cheap reads instead of slow live queries.
