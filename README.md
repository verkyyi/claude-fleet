# claude-fleet

**English** | [简体中文](README.zh-CN.md)

**Product blueprint:** [Fleet product direction and design principles (中文)](docs/dev/PRODUCT-DIRECTION.md)
guides future product decisions. The rest of this README describes the current implementation.

**Share a team's AI subscriptions, and run the work in the cloud.**

claude-fleet does two things: **subscription sharing** — a small team's Claude
and ChatGPT/Codex subscriptions become one pool, metered and routed by headroom —
and a **cloud runtime** — Claude Code and Codex CLI sessions run on managed
machines, each task in its own session and git worktree, and keep running when
you close your laptop. You reach them from a terminal (`fleet`), a phone or the
web console.

**A task is a hub record, `T<n>`, and it belongs to a person, not to a
repository.** You say what you want (⌘P's ⚡ line, the web console, or the `task`
tool from another session); the hub writes the record first, then opens the
session that does it. A task that names a repository works in a worktree of it
and lands a pull request — **GitHub only hosts the code and the PRs**. Nothing
claims, comments on or closes a GitHub issue, and a task with no repository
(a page, a document, a conversation) needs no GitHub at all.

The core workflow uses the CLIs' **subscription sign-in**, with no separate model
API key required. Claude subscription account pools and quota-aware routing
assign new work by available 5-hour / 7-day headroom and resume tasks on another
account when needed; Codex account homes are selected by native quota headroom.
See the [agent capability table](#agents-claude-code-and-codex).

Built from daily use on an always-on Mac mini. A local transcript audit found a
**historical peak of 25 Claude main sessions processing tasks in parallel,
across 25 independent worktrees**, on September 1, 2026. A separate interval
held at least **15 concurrent task directories for 14.46 minutes**. These count
overlapping CLI processing turns, not simultaneous server-side token generation
or a throughput multiplier. [Evidence and counting method](docs/dev/USAGE-EVIDENCE.md).

For people who use fleet rather than build it, the guides are in
[`docs/public/en/`](docs/public/en/index.md) (members, admins, self-hosting).

## What you get

- **One task, one session, one worktree.** Each task gets its own session and,
  when it names a repository, its own worktree and branch; the session lands its
  own pull request when the gate is green, and reports back. Worktrees separate
  uncommitted changes; related tasks still need an agreed merge order and may
  have conflicts.

- **Attention signals.** Claude Code hooks (and Codex's native events) stamp each
  session's state the instant it changes: a **cyan braille spinner** while it
  works, **indigo** while a `/loop` waits between iterations, **green ✓** when a
  turn finishes, **red ! + bell** when it is blocked on your answer. The task
  list puts the session that needs you first, and ⌘P's panel lets you answer it
  without attaching.

- **A view from anywhere** (`fleet`): the session in view, the task list beside
  it, and the ⌘P panel to switch, dispatch, answer or open a shell — on your own
  computer, over SSH from a phone, or in the web console. Sessions on other
  machines are rows of the same list.

- **Background collectors** keep it all instant: a 60-second daemon caches each
  worktree's branch, per-session context tokens and a local 5h/7d token-usage
  proxy. The task list only ever reads caches — zero inline git/gh/LLM calls.

- **Subscription-aware scheduling.** Pool Claude subscription accounts, choose
  where new sessions start, and move existing sessions with their transcripts
  when an account needs a break. With [TokenLedger](https://github.com/verkyyi/claude-fleet/tree/master/tokenledger)
  (`ccquota`), use account-wide 5h/7d readings to warn before a limit, rotate
  early, stagger window starts, and optionally pause remote starts. See
  [subscription and quota management](#subscription-accounts-and-quota-management).

- **Worktree lifecycle**: a cleanup daemon reaps a session's window, worktree
  and branch once its PR has merged (recording it in `/fleet-history` first, so it
  stays resumable), and an hourly janitor removes worktrees that are merged +
  clean + not attached to any live pane (and never anything else).

- **Optional Claude Code status line** (`conf/statusline.sh`): wired as a
  *measurement bus*, not a visible line (issue #1452) — it prints nothing and
  stamps the context %, window size, model and effort level (plus the account's
  rate limits) onto the pane's tmux window, where the client's top line shows
  `剩余 62% · Opus 5.5 · high` on its right and the auto-handoff nudge reads the %.
  Opt-in at install time by pointing `settings.json`'s `statusLine` at the
  live-install path, so it improves through `land → /fleet-sync-install`;
  jq-gated (inert without it). Never auto-wired. The fleet mod feeds the same
  script from inside the session (`statusline.sh --from mod`, issue #1459), so
  once every Claude window carries the mod the key can go —
  `bin/fleet-statusline.sh off` removes it (and the blank bottom row Claude Code
  keeps for any `statusLine`), refusing while a window would be left blind.

## Architecture

```
Claude Code hooks (PreToolUse/PostToolUse/Stop/Notification)
      │  instant, semantic-blind
      ▼
@claude_state on the tmux window ──► spinner daemon (0.12s frames, single
      ▲                               writer, change-detected) ──► list glyphs
      │  native state (OSC 7501)                                   + needs tally
the agent's own status report

collector daemon (60s) ──► cache files ──► task list / top line / ⌘P panel
  git · ctx tokens ·                        (read-only producers, render instantly)
  usage proxy

hub (tokenledger) ──► task records T<n> · placement · subscription pool · console
```

Design rules that made it work:

- **Native state first; model inference is opt-in.** Hooks and native reports give
  working/done/needs signals. Only an explicitly enabled screen classifier adds
  model-based corrections to `@claude_state`; it is not required for recorded
  schedules, explicit waits or native pending requests.
- **One writer per surface.** A single spinner daemon owns all window styling
  (one `tmux source-file` per frame = one repaint); a single collector owns
  every cache file; producers are read-only.
- **Loud/quiet hierarchy.** Only "needs you" is loud (red, bold, bell).
  Everything else is quiet fg-color text — 7 spinning windows shouldn't shout.
- **Change-gate every LLM call.** Summaries/classifications only fire when a
  pane's content checksum changed; a parked session costs zero tokens.
- **Every piece of work is a hub task record.** The record is written before its
  session starts and closed by the session's report, so nothing runs untracked —
  and nothing depends on GitHub being reachable except pushing, the PR and its
  checks.

Deeper reference: **[docs/dev/TERMS.md](docs/dev/TERMS.md)** defines every term (what
the collector, the hub and a task record actually are), **[docs/dev/ARCHITECTURE.md](docs/dev/ARCHITECTURE.md)**
covers the shared-vs-per-fleet split and how **several logins' fleets share one
machine**, and **[docs/dev/STATE.md](docs/dev/STATE.md)**
traces how each window's Claude state (`working`/`done`/`needs`/`looping`) is set,
rendered, and corrected. **[docs/dev/EMIT.md](docs/dev/EMIT.md)** covers the optional,
off-by-default emitter that POSTs session lifecycle facts (session → task → PR)
so an external ledger can join what a week of agent work **cost** to what it
**produced** — including the exact list of what does, and does not, leave the
machine.

## Install

The installer is Claude itself — [`docs/dev/INSTALL.md`](docs/dev/INSTALL.md) is the playbook:

```sh
git clone https://github.com/verkyyi/claude-fleet.git
cd claude-fleet
claude "install claude-fleet on this machine"
```

Claude will check dependencies, copy the scripts to `~/.claude/fleet/`, write
your `fleet.conf` (first repo, main checkout, base branch), append one
source line to `~/.tmux.conf`, merge five hook entries into
`~/.claude/settings.json`, install the daemons (launchd on macOS, the
`systemd/` user units on Linux), and verify each piece — asking before it
touches anything.

Prefer manual? Every step is in [docs/dev/INSTALL.md](docs/dev/INSTALL.md); the pieces are
plain shell scripts with no hidden state.

Running it on an unattended machine (a Mac mini you reach over SSH)? Read
**[docs/dev/HOST.md](docs/dev/HOST.md)** — the host setup that keeps the machine busy only
with its sessions: [turning off Spotlight](docs/dev/HOST.md#spotlight), the
[unattended-Mac checklist](docs/dev/HOST.md#headless) (never sleep, no Siri, no
iCloud sync, no GUI apps on the console) and [how much a container VM may
take](docs/dev/HOST.md#containers). `fleet-doctor`'s `host` section checks each item;
[`fleet-host-tune.sh`](docs/dev/HOST.md#tune) plans them all (`--apply` asks per item).

### The Claude-Code side ships as a plugin

The fleet's slash commands, the base `skills/` tree and the hook table also
install as a **Claude Code plugin**, served by a marketplace in this same repo:

```sh
claude plugin marketplace add verkyyi/claude-fleet
claude plugin install fleet@claude-fleet --scope user --yes
```

That replaces the copy-and-merge passes above for those three, and
`/plugin update fleet` keeps them current — so on a second machine, or a
teammate's, nobody has to remember `/fleet-sync-install` for them. Plugin
commands are namespaced (`/fleet:fleet-history`); the fleet detects which install
path a machine has and seeds the form that resolves, so spawns work either way.
Codex does not consume Claude plugin commands directly; `/fleet-sync-install`
generates native Codex skills from `commands/*.md` under each known
`$CODEX_HOME/skills/<name>/SKILL.md`, so the same command becomes
`$fleet-history` there.

It does **not** replace the playbook: `bin/`, `conf/`, the tmux layer and the
daemons are machine-level and stay at `~/.claude/fleet`. A plugin's install path
is version-scoped and moves on every update, so nothing with a stable absolute
path — a launchd unit, a tmux bind, a hook command — can point into it.

### Dependencies

tmux ≥ 3.2 · [fzf](https://github.com/junegunn/fzf) ≥ 0.59 (the node's pickers use
`--no-input`) · [gh](https://cli.github.com/) (authed — only to push, open and merge PRs on a GitHub repo; a repo at any other git address, and a task with no repo, need none) · python3 ·
[Claude Code](https://claude.com/claude-code) (the `claude` CLI; also used by
the sleep digest). Soft: perl `Time::HiRes` (sharper list spinner).

Run [`bin/fleet-doctor.sh`](bin/fleet-doctor.sh) to check all of these at once.
Its `install` lines also answer *"is this machine's live install current?"* — the
`~/.claude/fleet` half is a hand-run `git pull` per machine, so it goes stale in
silence (see [`bin/fleet-install-version.sh`](bin/fleet-install-version.sh)) —
and *"is each login still following `refs/tags/stable` on its own, and if not,
why?"* (see [`bin/fleet-install-follow.sh`](bin/fleet-install-follow.sh)).
(No standalone `jq` for the core — the collector only uses `gh --jq`, which is
built in; `jq` is a soft dep only for the optional `conf/statusline.sh` status
line, which exits silently without it.)

## Keybindings

`fleet` opens the thin client. **⌘P** in iTerm2, **⌃空格**, **F12** or **⌃] p**
opens the panel: choose a session, start a task, open its shell, or quit fleet.
Tab on a row shows its actions. The panel and top bar run on the home machine
(`fleet_view.py`, `fleet-topbar.py --node`, `conf/tmux-view.conf`).
Your computer runs one foreground Python loop and one connection; closing it
leaves the sessions running. See [the client guide](docs/dev/CLIENT.md) for key
customization, phone controls and the completed sidebar migration checklist.

A direct node attach keeps tmux's stock keys. One fleet per login holds every
repo you work on; the panel includes your sessions on other machines too.

### tmux baseline

`conf/tmux-attention.conf` also carries an opinionated **fleet baseline** the UX
assumes so a clean install behaves consistently: `mouse on`, truecolor (`default-terminal` + a `Tc`
`terminal-overrides` so the theme's hex colors render), `escape-time 10` (snappy
ESC in the Claude TUI), `history-limit 50000`, `allow-rename`/`automatic-rename`
off (the fleet navigates by explicit window names), and the Tokyo-Night status /
pane / message theme. Every line is documented inline and easy to override —
put your own settings in `~/.tmux.conf` *after* the `source-file` line (later
wins) or comment the baseline out. Truly personal bits (prefix remaps, personal
binds) are intentionally left in your `~/.tmux.conf`.

## Configuration

One file, `~/.claude/fleet/fleet.conf` (see
[fleet.conf.example](fleet.conf.example); every key with its default and help is in
[conf/fleet.conf.reference](conf/fleet.conf.reference)):

```sh
FLEET_REPO="you/your-repo"            # the first hosted repo: its code + PRs
FLEET_MAIN="$HOME/projects/your-repo" # worktrees are created as its siblings
FLEET_BASE_BRANCH="main"
FLEET_PROTECTED_RE="^(master|main|develop|test)$"
FLEET_CTX_WINDOW=200000               # 1000000 if you run 1M-context models
FLEET_GLOBAL_MAX_SESSIONS=0          # optional hard cap on live sessions; 0 (default) = the machine's admission decides
FLEET_AGENT="claude"                  # or "codex" — see the capability matrix below
```

## One fleet per login

A **fleet ≡ a tmux session** on its own tmux server, and a login runs exactly
**one** (issues #977/#979/#980). Every repo that login works on lives in that one
fleet — add them with `bin/fleet-repo.sh add` — so moving between repos is the
task list's grouped rows, never a switch between fleets. There is no fleet picker.

**Several fleets on one machine means several logins.** Each login has its own
`~/.config/claude-fleet/`, its own fleet and its own tmux socket, so a crash in
one never touches another. They share one collector without clobbering each other
(see [docs/dev/ARCHITECTURE.md](docs/dev/ARCHITECTURE.md)). A repo you want isolated
from the rest goes to a second login. A login that ended up with two fleets folds
one into the other with `bin/fleet-repo.sh fold` (below).

```sh
fleet                                      # open the client — the one way in (on this machine, or through the hub)
bin/fleet-up.sh you/webapp                 # first repo: clone-or-reuse ~/projects/webapp, bring the fleet up
bin/fleet-repo.sh add you/infra ~/src/infra   # another repo in the same fleet (explicit checkout dir)
bin/fleet-list.sh                          # ● live / ○ down · name · repo · checkout (+ ↳ each further repo)
bin/fleet-down.sh fleet                    # kill the fleet after you type its name; `fleet up --undo` brings it back
bin/fleet-down.sh fleet --yes --purge      # from a script, and drop its conf/cache too; checkouts stay
```

On SSH login, `shell/fleet-intro.sh` prints a short, phone-width banner: this
login's fleet and its repo count, the `fleet` line to get in, and any machine-local
`intro.d` lines — and then opens the **client**: an interactive SSH login runs
`bin/fleet`, the same client you run on your own computer, here reading this
machine (its bar says 客户端在 <机器> 上运行) — never a direct attach to the node's
own session (issue #1711). scp / rsync / `ssh host cmd` are never touched;
`~/.hushfleet-attach` keeps the banner only. See
[docs/dev/INSTALL.md](docs/dev/INSTALL.md) step 7 for the one `~/.zshrc` line,
`source ~/.claude/fleet/shell/fleet-login.zsh`.

**Several repos in one fleet.** From inside the fleet, `bin/dash-repo-add.sh`
(issue #1103) opens a popup that asks just `owner/name` (a GitHub URL is fine) and
adds it — so on an iPad nothing leaves the screen: the
checkout is `~/projects/<name>` (reused if it already is that repo, cloned if
missing, the clone's progress in the popup), the verdict stays up until you dismiss
it, and the new repo's heading is in the task list's next frame — no restart. The shell
form, `bin/fleet-repo.sh add you/infra [<checkout>]`, is the same registration
(clone-or-reuse, like `fleet-up.sh`) and the one that takes a different checkout
dir; `list` shows what it hosts and `remove` drops one. The rest follows on its
own, as it does for the first repo: a warning if Claude Code has not trusted the
checkout, and the background daemons woken so the list picks the repo up within a
tick; `fleet-doctor.sh`'s `repos` row lists every hosted repo and whether it is
healthy. All hosted repos are equal — there is no main repo. Once a fleet hosts two:

- every session carries its repo (`@repo`), shown in the task list as a repo
  heading / short-tag badge;
- the task list shows every repo at once, grouped under a heading per repo —
  there is no per-repo view to switch to;
- a new task names its repo when you dispatch it; one with no repo runs in
  `$HOME`;
- cleanup, PR status and restore are keyed on (repo, branch), so repo A's
  `issue-12` never touches repo B's.

**Folding a fleet into another.** `bin/fleet-repo.sh fold <old-fleet> --into
<fleet> --dry-run` shows what would move; drop `--dry-run` to do it. The old
fleet's repo and its per-repo settings become an overlay of `<fleet>` (a setting
that only a fleet conf can hold is warned about, not carried). Every idle or
finished session exits cleanly and resumes in `<fleet>` with the same conversation
and folder, and a hibernating one is woken first. Busy sessions are left where they
are, or moved as each one finishes with `--wait`. Once the old fleet is empty, its
server goes down and its conf is archived under
`~/.config/claude-fleet/archive/`. It is never deleted.

`bin/multirepo-e2e-selftest.sh` proves the whole path end to end. One crash of
the fleet's tmux server takes every repo in it down — and a login runs exactly
**one fleet** (issue #979): `fleet-up <owner/repo>` / `fleet repo add <owner/repo>` with a fleet
already configured ADDS the repo to it, and a second
fleet is refused. A repo you want isolated needs a second login. A brand-new fleet
is named `fleet`; an existing one keeps its name.

`fleet` is your one way into a fleet (issue #1711, EPIC #1710): the client, on
your own computer or after an ssh login (the old `cf` helper, `shell/cw.zsh`,
is gone — issue #4902). `bin/fleet-attach.sh` — a direct attach to the node's own session — still
works for a script or a person who types it, but is no longer advertised.

Each fleet keeps its durable state in **one directory per fleet** —
`~/.config/claude-fleet/fleets/<session>/` (its `conf` overlay, restore map), so `ls ~/.config/claude-fleet/fleets/` is the list of
running fleets (issue #181). The `conf` overlays the global `fleet.conf`, which
still works as a one-fleet default. **One settings file per login** (issue #979):
`bin/fleet-settings.sh merge` folds the install's `fleet.conf` and the fleet's
`conf` into `~/.config/claude-fleet/fleet.settings` (the `conf` keeps only
`FLEET_REPO`/`FLEET_MAIN`/`FLEET_BASE_BRANCH`; the old files stay as
`*.pre-merge`). Read order is install `fleet.conf` < `fleet.settings` < the
fleet `conf`, so an unmerged login loads exactly as before. The config
panel writes only the two layers you can tell apart — **this fleet** (a
global-only key goes to `fleet.settings`, any other to the fleet `conf`) and **a
hosted repo** — and never the install's `fleet.conf`, which it reads as legacy
(issue #1102). A fleet's resting window is `home`, a plain shell the task list
draws beside; nothing spawns a Claude session for you, and there is no resident
orchestrator. Run your own `claude` in whatever window you like, or open an
orchestrator session (`spawn agent:orchestrator`) to talk a request through and
dispatch it. Workers land their own PRs on green (#441).
The base checkout stays edit-read-only for every pane (`hooks/base-readonly-guard.py`),
so an operator's session can drive the fleet without ever committing to it.
Upgrading from the old flat layout is automatic — `/fleet-sync-install` runs
`bin/fleet-migrate-layout.sh` once (idempotent; readers dual-read both layouts).

### Manage registered machines through MCP

The optional **Fleet Hub** gives authorized Agents one MCP endpoint for Fleets
on several machines, including SSH-connected hosts. It supports scoped status
queries, worker starts, messaging / graceful stop / resume of a worker by
a durable identity that survives handoffs and account migrations, limited
configuration updates and persistent operation tracking. Nodes use a fixed SSH control entry point; existing workers
continue if the Hub disconnects. A launchd installer runs a persistent Hub on
macOS, with private HTTPS grant tokens or an OAuth HTTP deployment.
See [Fleet Hub setup and authorization](docs/dev/FLEET-HUB.md).

<a id="multiple-subscription-accounts-auto-failover"></a>

## Subscription accounts and quota management

The fleet manages **which Claude subscription each session uses**, as well as
its task. The account pool is machine-wide, shared across fleets; it is optional
and off when no token files are registered. Without a pool, your existing login
continues to work. These capabilities apply to **Claude Code**; the Codex adapter
has no equivalent quota or account-migration integration yet.

There are two layers: a token pool handles limit banners and session recovery;
adding [TokenLedger](https://github.com/verkyyi/claude-fleet/tree/master/tokenledger) supplies account-wide
quota readings for decisions **before** a subscription is exhausted. TokenLedger
is the product name; its executable and settings are still `ccquota` and
`CCQUOTA_*`. Its CLI and hub are separate dependencies, covered in
[the install playbook](docs/dev/INSTALL.md).

| Capability | What happens | Requires |
|---|---|---|
| Account pool | New sessions choose an eligible account. A running session that fills is not moved: the credential pool changes its subscription. | Account token pool |
| Live-session migration | Reopen the same worktree and Claude transcript on another account, preserving task bindings — by hand (`fleet-migrate.sh <window>` / `--account <label>`). | Account token pool |
| Per-model fallback | Distinguish one model's cap from the account's overall limit. Switch affected sessions to `FLEET_MODEL_FALLBACK` in place when possible; otherwise restart + resume. | Account token pool; available fallback model |
| Quota-aware account selection | Rank eligible accounts using `5h headroom × 2 + 7d headroom`, with hysteresis to avoid needless switching. Both windows must be below the account ceiling. | Pool + ccquota hub readings |
| Early warning and rotation | At 70% utilization, warn sessions; at 85%, bench the account and migrate its sessions to a readable account below the ceiling. Thresholds use the higher of 5h and 7d usage and are configurable. | Pool + ccquota hub readings |
| 5-hour window staggering | Plan when idle accounts first open their next window, so windows need not all reset together. Automatic replanning is opt-in. | Pool + ccquota hub readings |
| Remote-start quota gate | Optionally stop sessions the hub starts or resumes near the selected subscription's ceiling (90% by default). Hand spawns and running sessions are unaffected by this gate. | ccquota hub; `FLEET_QUOTA_GATE=1` |
| Quota-watch health | Surface stale readings and repeated empty fetches in the status bar and doctor, so missing data is visible. | Configured pool + ccquota hub |

### Register accounts and see which one a session uses

Run `claude setup-token` under each subscription's login. Create the accounts
directory if needed, then save **only the returned OAuth token** in
`~/.config/claude-fleet/accounts/<label>`, one file per account
(for example `work` and `personal`), and restrict each file to mode `600`:

```sh
chmod 600 ~/.config/claude-fleet/accounts/work
~/.claude/fleet/bin/fleet-account.sh list
```

Full setup, optional account subsets and per-account fallback reset durations
are in [docs/dev/MULTI-ACCOUNT.md](docs/dev/MULTI-ACCOUNT.md#setup). Tokens stay outside
the repository. Account choice is per launch through `CLAUDE_CODE_OAUTH_TOKEN`;
settings, hooks and transcripts continue to use the shared Claude configuration.

The **usage + account modal** (`bin/usage-modal.sh`; its `prefix u` door left the
node with #1714 — #1739 decides the client's) is read-only: a Claude session's
subscription is the pool's pick behind the credential proxy, else the login's
own (T550) — nothing here, and no sidebar item, picks one. From inside a fleet
pane, check that session's actual account:

```sh
~/.claude/fleet/bin/fleet-account.sh whoami
```

**Account changes require a restart.** A live Claude process cannot hot-swap its
token; the fleet closes it and resumes the same transcript in the same worktree
under the new account. That preserves conversation history, not the original
process or its background agents. When no suitable migration destination exists,
the fleet leaves the sessions in place instead of repeatedly restarting them
onto another exhausted account.

### Add account-wide quota readings

Configure the `ccquota` CLI, its hub and viewer credential as described in the
[install playbook](docs/dev/INSTALL.md), then set the hub URL in `fleet.conf` so the
background services inherit it. The remaining values below are the defaults:

```sh
export CCQUOTA_HUB_URL="https://your-ccquota-hub.example"
FLEET_ACCOUNT_CEILING=85
FLEET_ACCOUNT_PICK=pace
```

The viewer credential can live in `~/.ccquota/viewer-token`. Match each ccquota
account name to its fleet label, or set `CCQUOTA_ACCOUNT=<uuid>` in the label's
companion `<label>.conf` file. Unreadable or unmapped accounts have **no quota
reading**, rather than a misleading 0%; they are not destinations for a
quota-triggered migration.

New spawns rank the accounts by the **weekly pace** — how far ahead of or behind
an even burn of its 7-day budget each account is — so the pool's weeks drain
together instead of worst-first
([details](docs/dev/MULTI-ACCOUNT.md#pacing-the-weekly-budget-across-the-pool-issue-1231)).
Nothing watches the pool every minute to warn or move a running session: a full
subscription is the credential pool's to change, and each session's own 剩余 %
is on its window. Work is not blocked just because the optional hub is
unavailable.

For optional window staggering, inspect a plan before applying it:

```sh
~/.claude/fleet/bin/fleet-account.sh phase --plan
~/.claude/fleet/bin/fleet-account.sh phase --plan --apply
```

This schedules the first use of idle accounts; it does not change the provider's
reset clock or hold an account already mid-window. A phase hold is relaxed when
needed to keep an account available for a spawn. Set `FLEET_ACCOUNT_PHASE=0` to
ignore a written plan.

The **remote-start quota gate is separate from account rotation** and off by default:

```sh
# In fleet.conf; choose the subscription the gate should judge.
FLEET_QUOTA_GATE=1
FLEET_QUOTA_CEILING=90
# FLEET_QUOTA_ACCOUNT="<subscription-uuid>"  # or "all"; unset uses ccquota's default
```

It gates only the starts and resumes the hub sends (the autofill dispatcher it
was first written for is gone, #3120). Missing ccquota, an unreachable
hub or an unreadable limit leaves the gate open; it is not a hard spending cap.

### Model caps and operational checks

A cap on one model need not exhaust the account's other models. The fleet tracks
caps per `(account, model)` and, where a usable fallback exists, keeps the account
in service. It tries an in-place `/model` switch, preserving the process and
context; an unverifiable switch falls back to restart + resume. New sessions use
`FLEET_MODEL_FALLBACK` (default `opus`) while the cap holds and return to
`FLEET_MODEL` after reset. Existing sessions stay on their fallback model.

Use these commands to inspect the policy and data:

```sh
~/.claude/fleet/bin/fleet-account.sh list
~/.claude/fleet/bin/fleet-quotaguard.sh --status
sh ~/.claude/fleet/bin/fleet-doctor.sh
```

Full policies and recovery commands:
[docs/dev/MULTI-ACCOUNT.md](docs/dev/MULTI-ACCOUNT.md).

## Fleet commands (`/skill`s)

Optional repo-shipped Claude Code slash commands that operate on the current
fleet (its `$FLEET_REPO` only), installed either as [the plugin](#the-claude-code-side-ships-as-a-plugin)
(typed `/fleet:fleet-history`) or by appending `commands/*.md` into
`~/.claude/commands/` (typed `/fleet-history`). The same files are generated as
Codex skills under `$CODEX_HOME/skills/` and invoked as `$fleet-history`,
`$fleet-context`, and so on. Each declares an owner seat (`worker` / `hub` /
`either`) and refuses from the wrong one. Live so far:

- A worker runs no command to start: its flow (the `brief` tool, a PR, `pr_verdict` →
  `pr_merge`, `report`) rides its SessionStart hook (`bin/fleet-worker-start-hook.sh`,
  issue #4898); the cleanup daemon reaps afterwards (see [docs/dev/CLEANUP.md](docs/dev/CLEANUP.md)).
- **`/fleet-history`** (hub) — browse & resume closed sessions (landed + unlanded,
  workers **and** `scratch-<N>` sessions) from the history ledger, reconstructing a
  reaped worktree off the recorded SHA so `claude --resume` still works.
- **`/fleet-handoff`** (either) — bridge long-running work across a context-window
  boundary: write a durable handoff, then `/clear` and pick it up clean.
- **`/fleet-sync-install`** (either, any fleet) — after claude-fleet's
  own PRs land, re-applies them to the shared live install (`~/.claude/fleet`): pull +
  reload changed daemons + re-merge the hooks delta + install changed commands
  and Codex skill mirrors.
  Maintains machine-global tooling, so it runs from any fleet; refuses only if
  `~/.claude/fleet` isn't a git checkout. See [`commands/README.md`](commands/README.md).

## Opening links over SSH

`--web`-style commands open a browser on the *remote* host — useless over
SSH. Everything here routes URLs through `bin/open-url.sh` instead:

1. **Tunnel mode (recommended)** — on your laptop, add to `~/.ssh/config`:

   ```
   Host your-remote
     RemoteForward 2226 127.0.0.1:2226
   ```

   and keep `extras/laptop-url-opener.sh` running (ad hoc, or as a login
   item). URLs sent by the remote host then open instantly in your local
   browser, riding the existing SSH connection — nothing else exposed.

2. **Fallback (zero setup)** — without the tunnel, you get a tmux popup with
   the URL (cmd-clickable in iTerm) already OSC52-copied to your local
   clipboard (`set-clipboard on` is in the shipped tmux conf).

### Copying text out of a session

In the `fleet` client, text you select in the right pane — another machine's
session — lands in your own clipboard (#1766). The machine's tmux copies it and
sends it outward as OSC 52; the home view and thin loop pass it to your
terminal. The node enables `set-clipboard on`, and the terminal must accept it:

- **iTerm2** — Settings → General → Selection → 「Applications in terminal may
  access clipboard」 (`AllowClipboardAccess`). `fleet doctor` on the client
  prints a `clipboard` row: WARN while it is off; it never changes it for you.
- **Termius (phone)** — not yet measured whether its OSC 52 reaches the iOS
  clipboard. Until it is, use Termius's own selection: long-press in the
  terminal → Select → Copy. `bin/clipboard-osc52-selftest.sh` pins the chain up
  to the terminal.

### `fleet-open`'s laptop half (iTerm2)

`fleet-open` (#1379) asks the iTerm2 you are typing in to open a link — and, for
a service on the fleet machine's loopback (a dev server, a page), to add a
`-L` forward to the SSH connection you already have and open
`http://localhost:<port>` here. The receiving end is an iTerm2 AutoLaunch
script, `extras/iterm2/fleet_open.py`; install it on the laptop with

```
bash extras/iterm2/install.sh --mini <your ssh alias for the fleet machine>
# or, from the fleet machine:
ssh <laptop> 'bash -s -- --mini <alias>' < ~/.claude/fleet/extras/iterm2/install.sh
```

It needs iTerm2 ≥ 3.5 with the Python API turned on (you flip that switch; the
installer only checks it), reads the shared secret back over SSH, and adds
`ControlMaster`/`ControlPath`/`ControlPersist` to that `Host` block if missing
(backing up `~/.ssh/config` first). `--dry-run` shows every step; re-running is a
no-op; `--uninstall` removes it. Outside links open at once only for hosts in
`~/.config/fleet-open/allow` (default github.com, claude.ai) — anything else asks
first — and every action is logged to `~/.config/fleet-open/log`. On the fleet
machine, `FLEET_OPEN_LAPTOP=<laptop ssh alias>` adds a `laptop` row to
`fleet-doctor` (installed? same version?; `?` when the laptop is asleep).

## Showing a file on your own terminal

An agent that wants you to look at an image, a PDF or a QR code must not `open`
it — that opens it on the fleet machine's screen, where nobody is sitting. It
runs `bin/fleet-show.sh <file>` instead, and the file arrives on **your** side of
the SSH connection: iTerm2 asks you to accept the download, then saves it to
your `~/Downloads`. `--inline` draws it in the terminal instead, on a screen of
its own: a title row (name · size · pixels), the image scaled to fit and
centered, and a footer — `任意键返回 tmux · d 同时下载到 ~/Downloads · 30s 后自动返回`,
counting down `FLEET_SHOW_HOLD_SECS` (default 30). `d` also sends it as a
download. Centering needs the client's cell size (`#{client_cell_width}`, tmux
3.4+); without it the image goes top-left at its own size. A PDF or any other
non-image cannot be drawn inline, so `--inline` sends it as a download and says
so. The screen text is Chinese, fixed — the fleet has no UI-language setting.

- **iTerm2 side:** nothing to install (3.5+, for multipart transfers), but iTerm2
  **asks you to confirm each download** — the file lands only after you accept.
  iTerm2 has no documented setting that silences it
  (`NoSyncSuppressDownloadConfirmation` did not, on 3.6.10).
- **The receipt** (issue #3541): each file's line is `saved:<path>` (your side said
  where it landed), `failed:<why>`, or `unconfirmed` (no answer within
  `FLEET_SHOW_ACK_WAIT`, 12 s). Through the thin client (`fleet`) the loop fetches
  the file over its own connection into `~/Downloads` and answers by itself; through
  iTerm2 directly, `extras/iterm2/fleet_open.py` v3 watches `~/Downloads` for it
  (an older script, or none: `unconfirmed`).
- **Which terminal:** the one you are using — the most recently active tmux
  client of this session — and only if its terminal type (`#{client_termtype}`,
  e.g. `iTerm2 3.6.10`) matches `FLEET_SHOW_TERM_RE`. Reading from your phone over
  SSH while an old iTerm2 is still attached at home? It prints the file's path
  instead (exit 2) and names the client it saw, rather than sending the file to a
  screen nobody is looking at. An unknown terminal type (tmux < 3.4, or a terminal
  that does not answer XTVERSION) degrades the same way, and so do `FLEET_SHOW=0`
  and a file over `FLEET_SHOW_MAX_BYTES` (20 MB). `--client <tty>` picks one
  outright.
- **The screen flashes once.** The file is written by the tmux client itself, run
  as a one-shot `lock-command`: tmux stops drawing to that terminal while it sends
  and redraws when it is done (a fraction of a second for a few MB). Writing the
  terminal directly while tmux paints it corrupts anything past a few hundred KB —
  tmux's bytes land inside the file's escape sequence (issue #1367).

## Agents: Claude Code and Codex

A fleet spawns **Claude Code** by default and can spawn **OpenAI Codex CLI**
instead (`FLEET_AGENT=codex` for the fleet, or `--agent codex` / the tools'
`coding_agent` for one session).
Two agents, not thirty — which is what makes it honest to print the grading in
full, gaps included.

To hand **one existing Claude session** to Codex, run `/fleet-handoff --to codex`
in that Claude conversation (`/fleet:fleet-handoff --to codex` for plugin installs).
The skill writes task notes and arms a switch after its turn ends. From another
pane or terminal, use
`bin/fleet-transfer.sh --session <fleet> --window b3 --to codex --dry-run`, then
repeat without `--dry-run`. The same window and worktree continue with a local
handoff packet that tells Codex the source agent, session ID and original
transcript path, plus a frozen copy for later lookup. Optional `--handoff` notes
carry the exact next action. See [single-session transfer](docs/dev/SESSION-TRANSFER.md)
for prerequisites, export-only mode and failure recovery.

**Why the gaps are published.** A feature table that lists only ticks tells you
nothing about whether the second agent is usable for *your* work. Every ❌ below
says which kind of gap it is — **Codex has no such mechanism**, or **the
mechanism exists and the fleet has not adapted it** — because those are different
promises about the roadmap.

**Why these two agents.** The hardest part of an agent-neutral layer is the live
state signal, and Codex's hook system *is* Claude Code's schema: same event
names, same stdin JSON, `exit 2` blocks, `$TMUX_PANE` inherited (measured on
codex-cli 0.154). So the task list colours a Codex worker off real hooks instead
of degrading to a pane-content heuristic.

| Capability | Claude Code | Codex | Why |
|---|:--:|:--:|---|
| worktree per task · `@issue` / `@task` binding · PR/CI map · cleanup · session caps | ✅ | ✅ | Not agent code at all — `git`, `gh` and tmux window options. The whole worker path is agent-agnostic. |
| hook state signals → task-list colours (busy / working / done) | ✅ | ✅ | Codex's hook system *is* Claude Code's schema — same event names, same stdin JSON, `exit 2` blocks, `$TMUX_PANE` inherited (measured on codex-cli 0.154). This launcher inlines the fleet's own hooks as `-c hooks.<Event>=[…]`. |
| bypass-permissions guardrails (bash-guard · base-checkout read-only) | ✅ | ✅ | full access from config.toml (else `--dangerously-bypass-approvals-and-sandbox`, issue #4724) + `--dangerously-bypass-hook-trust`; the base-checkout guard matches `apply_patch` on Codex where Claude matches Edit/Write/MultiEdit. |
| session keeps ONE language (non-English sessions stay non-English) | ✅ | ✅ | `bin/fleet-brief.sh` ends every worker's opening read with the seed rule, and every text the fleet injects later (resume nudge, quota warning, child report, auto-handoff directive) carries its own — one English sentence per injection point instead of a translated nudge per language (issue #620, `bin/fleet-lang.sh`). Codex additionally has the rule in `conf/codex-preamble.md`, where it originated. |
| project instructions file | `CLAUDE.md` | `AGENTS.md` | `-c project_doc_fallback_filenames=["CLAUDE.md"]` makes a Codex worker read this repo's `CLAUDE.md` when it has no `AGENTS.md`. |
| worker model pinned at spawn | `FLEET_MODEL` | `FLEET_CODEX_MODEL` | Two knobs on purpose: Codex model names are not Claude aliases, so `FLEET_MODEL` never reaches a Codex pane. |
| transferred recurring loop | Fleet adapter / native `/loop` | Fleet adapter | Active Fleet loops keep their ID, cadence and ownership generation across agent/account transfers. Codex uses private RPC; Claude inbox delivery requires transcript acknowledgement. Exact crash restore can reattach active owners; stopped or ambiguous deliveries never replay. Managed HOME transfers can preserve verified session-only calendar jobs, including one-shots. |
| optional plugins (fleet-epic · fleet-browser · …) | ✅ `/plugin` | ⚠️ partial | Legacy bridge pending native plugin migration: `bin/fleet-codex-plugins.py sync` follows what the Claude side installed and enabled before every launch: skills linked as `$CODEX_HOME/skills/fleet-plugin-*`, plugin commands as adapter skills, the `.mcp.json` servers as one marked block in `config.toml`, hooks merged by `fleet-hooks-emit.sh --plugin-dir`. Not carried by this bridge: mod interface modules (/qd), PreCompact, an agent file's `tools` limits, native plugin ownership (issue #3123; docs/dev/NATIVE-AGENT-BOUNDARY.md). |
| fleet command seed (`/fleet-handoff`) | native | native | Claude Code expands `/fleet-handoff`; Codex invokes the installed `$fleet-handoff` skill from `$CODEX_HOME/skills/fleet-handoff/SKILL.md`. If an old Codex build has no skills, or that home has not been synced, the launcher falls back to the prose expansion. |
| directory trust prompt | pre-granted | trusted-node pre-grant | `bin/fleet-trust.sh` fills missing trust for the fleet checkout and a managed no-repo launch in physical HOME on a trusted node. Codex entries persist through proxy config symlinks; explicit untrusted and pre-trust opt-out remain unchanged. Transfer checks readiness before source exit. |
| red `needs` + bell when a session is blocked on you | ✅ | ✅ | The private-server monitor reads native waitingOnUserInput/waitingOnApproval flags and marks the exact launcher/thread. No Notification hook is needed. Resolved native attention clears only its own subtype; explicit worker blockers survive. |
| `AskUserQuestion` + the panel's answer | ✅ | ✅ | Codex has native request_user_input. The panel replies to the replayed server request, including choices and free text; exact launcher/thread/request fingerprints prevent stale answers. Esc sends nothing; native resolution confirms completion. |
| permission prompts readable + refusable from the panel | ✅ | ✅ | Native command/file/additional-permission and MCP requests are readable. fleet-permission.sh --deny sends only the native refusal, requires the displayed request token and the existing opt-in. Default bypass posture normally suppresses command/file prompts; no approval is automated. |
| close the window when the operator exits the agent | ✅ | ✅ | The Codex launcher waits for a successful CLI exit, then calls the shared close-on-exit policy. Dirty/unmerged work survives, hubs/panels are excluded, and the global `FLEET_CLOSE_ON_EXIT=0` opt-out applies. Failed launches stay visible; thread `SessionEnd(reason=other)` never closes a window. |
| session lifecycle events | ✅ | ✅ | Both agents emit `session.start` and `session.end` through the shared hook table. Codex thread lifecycle events are separate from process-exit window cleanup. |
| `/fleet-handoff` + the auto-handoff nudge | ✅ | ✅ | Codex runs `fleet-transfer.sh --to codex --handoff NOTES --after-turn` directly. The same clean-Stop, typing hold, lease and source-identity checks preserve notes, exact rollout, account home and worktree before a fresh conversation. `FLEET_AUTO_HANDOFF_PCT` nudges this native path. |
| `/fleet-context` + the task list's ctx % | ✅ | ✅ | Run `fleet-context.sh` directly on Codex. SessionStart binds the exact root UUID, launcher lifetime and CODEX_HOME; rollout token telemetry supplies the current model/window. Missing data stays unknown; no Claude transcript or default denominator is reused. |
| peer messages + child reports | ✅ | ✅ | Fleet pane launches give each worker a private local app-server. `codex queue` reaches that exact endpoint, UUID and CODEX_HOME; failed delivery is never stamped as success. A guardian shuts down the owned server even if the launcher is killed. `FLEET_CODEX_SERVER=0` opts back into embedded mode without live queue delivery. |
| fleet tools (`status` / `repos` / `agents` / `brief` · `report` / `ask` / `handoff` / `pr_verdict` / `pr_merge` · `context` / `transfer` / `where` / `show` / `open` / `set_reap`; the dispatch group `spawn` / `task` / `await` / `children` / `send` / `answer_dialog` / `clear`) | ✅ | ✅ | Both launchers mount the one tool service `fleet` (`bin/fleet-mcp.py`, defined once in `conf/mcp-worker.json`, issues #1807 / #1808 / #1811) and its dispatch group `fleet-orch` (`conf/mcp-orch.json`): the same tools for Claude and Codex, each a checked wrapper over the existing script. The worker skills name only these tools — a script path appears only under a 排障 / 运营者 heading (`bin/skill-tools-selftest.sh`). Spec: `docs/dev/FLEET-MCP.md`. `FLEET_MCP=0` turns it off. |
| `--resume` paths (restore · migrate · `/fleet-history`) | ✅ | ✅ | Crash snapshots and history retain the exact Codex UUID, CODEX_HOME and rollout. Native resume/fork stays in that home; account migration uses a durable packet to start fresh in a different home with source recovery preserved. |
| multi-account rotation + native quota collector | ✅ | ✅ | Register independent CODEX_HOME directories and select fresh launches by native quota headroom. Windows/reset times are reported by Codex. Unknown data stays unknown; gating and idle-only protected account migration are separate opt-ins. |
| subscription failover across Coding Agents | opt-in | opt-in | `FLEET_FAILOVER=1` picks an eligible subscription when a session STARTS: same-agent first, then the allowed other agent. A running session is never moved when it fills — the credential pool changes the subscription (the per-session planner is retired, T546). |
| per-model cap fallback (same thread) | ✅ | ✅ | Native thread/settings/update changes an idle Codex model and verifies it without keystrokes or restart. Opt-in fallback requires explicit model-to-limit IDs and fresh quota on both buckets. Only an exact native quota-failed turn receives a continuation. |
| MCP servers + subagent model | ✅ | ✅ | `FLEET_MCP_CONFIG` translates stdio/HTTP allowlists — recommended value `~/.claude/fleet/conf/mcp-worker.json`, the minimal worker set shipped with the fleet (the `fleet` tool service only, issues #1078/#1807); `FLEET_CODEX_MCP_CONFIG` also accepts native JSON/TOML. Strict policies disable inherited servers and apps. Codex subagent model/effort use separate native knobs; explicit caller overrides win. Both TUI and private server receive the policy. |
| PR + check status in the session header (`PR #N ✓ 检查通过` · `… 检查中` · `✗ <check>`) | ⚠️ | ⚠️ | tmux would draw it, not the agent: `conf/tmux-attention.conf`'s `pane-border-format` reads `@pr_num` / `@pr_ci` / `@pr_fail`, which nothing stamps since the PR-map refresher left (issue #4899; it was #1954) — so the header draws no PR today. `pr_verdict` is the PR's one reading. |
| knows where the person is from the first turn (device · terminal · what it can do) | ✅ | ✅ | One reader, `bin/fleet-client-where.sh`. Claude Code gets the line from the mod (`where.ts`, every request); Codex gets the same text as SessionStart `additionalContext` from `bin/fleet-where-hook.sh`, in the shared hook table and gated to a Codex pane so Claude never reads it twice (issue #1954). A takeover mid-session reaches Codex through the `where` tool. |
| native panel prompts (rename · answer · message) | ✅ | ✅ | `bin/fleet_view.py` handles the prompts without changing the agent pane. |
| questions and permission requests in the panel and notifications | ✅ | ✅ | Claude's AskUserQuestion / permission payload and Codex's app-server requests flow through `bin/fleet_needs_detail.py` into `@claude_needs_detail`. The node inventory and hub preserve the words; the native panel and `bin/fleet_notify.py` show them through the thin client's lease and OSC 9. |
| orchestrating: an orchestrator session template (spawn agent:orchestrator); nothing opens or reopens a resident one | ✅ | ✅ | The template is a standard agent file (`conf/agent-defaults/claude/agents/orchestrator.md`, issue #4335): its body is Claude's system prompt and Codex's `model_instructions_file`, its model `fleet.codex_model`; the dispatch group ships with the core (issue #4334). No seat, no state hook (issue #4340). |

That table says what the `MATRIX` block in
[`bin/fleet-codex.sh`](bin/fleet-codex.sh)'s header grades — the source of truth,
sitting next to the code it grades; edit a row there, then here.

Codex context tracking, recovery/history, handoff, messaging, startup policy,
native account quotas and panel answers are implemented in
[the Codex runtime adapter](docs/dev/CODEX-RUNTIME.md). Account homes must be
registered separately; quota gating and automatic idle migration are opt-in.
The shared screen classifier is disabled by default; explicitly enabled backends
still use or fall back to a Claude helper. Native
attention and replies require the private worker server, enabled by default.

Codex needs one manual setup step: it asks "Do you trust the contents of this
directory?" once per project and no flag or `-c` override satisfies it, so answer
Yes once in your base checkout (run `codex` in `$FLEET_MAIN`). Worktrees inherit
it. The launcher pre-reads that trust and turns the first Codex pane red with the
instruction in it, rather than letting a spawn stall on a prompt nobody is
watching.

## Assumptions & limitations

- **A fleet hosts zero or more repos, all on one tmux server.** Each window's repo
  is `@repo`; PR state is read per hosted repo.
- A window is told by its `@fleet_role` (`home` · `panel` · `worker`); windows
  named `home`, `dash`, `plan` or `backlog` count as panels, not sessions.
  Window **numbers shift** when a window closes (`renumber-windows on`), so
  address a session by its identity or key — never a memorized index.
- The `Notification` hook (red/bell) can lag a question by up to ~1 min
  (Claude Code's idle threshold); optional screen inference is not enabled by default.
- Local transcript token counters are a **usage proxy**, aggregated across
  accounts, not a subscription quota or bill. Weights: output×1 + input×0.25 +
  cache-write×0.25 + cache-read×0.02 over rolling 5h/7d windows. With TokenLedger
  configured, the account pool additionally uses **account-wide quota readings**
  from ccquota; these are separate from that local estimate. The usage + account
  modal shows the usage/limit details and the account pool.
- Daemon units ship for both macOS launchd (`launchd/`) and Linux systemd
  user units (`systemd/` — one always-on service + `.timer`/`.service` pairs,
  `__HOME__`-templated; see `systemd/README.md`).

## Safety notes for parallel fleets

Things that bit us and are worth adding on top (not included here because
they're environment-specific): a `PreToolUse` guard hook that blocks
dangerous commands (force-push to main, prod-database writes, destructive
`kubectl`), and a lease file so only one session at a time deploys to a shared
test environment. The one-record-per-task binding in this repo is the
foundation for both.

## Contributing

Shell scripts follow a small `set -u` / `pipefail` policy and are linted by
`shellcheck` in CI — see [CONTRIBUTING.md](CONTRIBUTING.md) before sending a PR.

## License

MIT
