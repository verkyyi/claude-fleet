# claude-fleet

Run a **fleet of parallel Claude Code sessions** in one tmux session — one
window per task, each in its own git worktree, with **GitHub issues as the
backlog** and the tmux status bar as a live attention monitor.

Born from driving ~7 concurrent Claude sessions (including long-running
`/loop`s) against a production monorepo from a single always-on Mac mini.

![dashboard](docs/img/dashboard.svg)
![status bar](docs/img/statusbar.svg)

<sub>Screenshots are the real UI captured from a live tmux server, staged with
demo repo data.</sub>

## What you get

- **Attention signals in the window list.** Claude Code hooks stamp each
  window's state the instant it changes: a **cyan braille spinner** pulses
  while a session works, **indigo** while a `/loop` waits between iterations,
  **green ✓** when a turn finishes, **red ! + bell** when a session is blocked
  on your answer. No polling lag — colors flip on the hook, not on the
  status-interval timer.

- **Urgency-sorted windows.** Windows re-slot themselves so position 1 is
  always the session that needs you most (needs > done > working > looping >
  idle). Your view never jumps — the sorter restores focus after every move.
  `prefix+a` hops to the neediest window.

- **A mission-control dashboard** (`prefix+G`): an fzf panel listing every
  session with state glyph, bound issue, model, and context %. It lives as an
  embedded pane in the `plan` hub (dash above, steward below); `prefix+G`
  focuses it and, pressed again, zooms it fullscreen — the mirror of `F9`'s
  steward focus. `Enter` jumps. **Type a task and press Enter** —
  it files a GitHub issue and spawns a new worktree session bound to it.
  `Ctrl-G` binds a window to an existing issue, `Ctrl-E` renames, `Ctrl-S`
  opens a raw scratch session (plain `claude`, no issue/worktree/PR — also
  `prefix+R`).

![backlog](docs/img/backlog.svg)

- **GitHub backlog panel** (`prefix+b`): open issues grouped by milestone
  (roadmap | unplanned panes). `Enter` on an issue creates a worktree
  `issue-<N>` off your base branch and starts `claude` seeded to read, claim,
  and implement it. Issues being worked show `▶ <window>`. Manage issues
  without leaving tmux: the modal is **list-only by default**, and `Space` (or
  `Ctrl-P`) toggles a **preview pane** showing the highlighted issue's body,
  labels, milestone, assignees, and recent comments — word-wrapped to the pane
  so nothing splits mid-word. `/` turns on type-to-filter; `Ctrl-X` closes
  (triages) an issue after a y/n confirm; `Ctrl-O` opens it on the web.
  **Priority** shows as a `p0`/`p1`/`p2` tag on each row and orders issues within
  a milestone; `Ctrl-Y` cycles a highlighted issue's priority (none→p2→p1→p0).
  `Ctrl-N` files a **one-line issue** fast.

- **Background collectors** keep it all instant: a 45-second daemon caches
  git status per worktree, the repo's PR/CI map, open issues, per-session
  context tokens, and a local 5h/7d token-usage proxy. The dashboard only
  ever reads caches — zero inline git/gh/LLM calls.

- **Worktree lifecycle**: `cw <branch>` spawns a worktree + Claude window;
  an hourly janitor removes worktrees that are merged + clean + not attached
  to any live pane (and never anything else).

## Architecture

```
Claude Code hooks (PreToolUse/PostToolUse/Stop/Notification)
      │  instant, semantic-blind
      ▼
@claude_state on the tmux window ──► spinner daemon (0.12s frames, single
      ▲                               writer, change-detected) ──► dash glyphs
      │  slow, semantic                                            + needs tally
LLM classifier (haiku, ~5min, change-gated)
      
collector daemon (60s) ──► cache files ──► fzf dashboard / backlog panels
  git · gh PRs+issues ·                     (read-only producers, render instantly)
  ctx tokens · usage proxy
```

Design rules that made it work:

- **Hooks are fast but blind; the LLM is smart but slow.** Hooks give the
  instant working/done/needs signal; a change-gated haiku classifier later
  corrects what hooks can't know (e.g. "done" that's actually a `/loop`
  between iterations). Both write the same `@claude_state`.
- **One writer per surface.** A single spinner daemon owns all window styling
  (one `tmux source-file` per frame = one repaint); a single collector owns
  every cache file; producers are read-only.
- **Loud/quiet hierarchy.** Only "needs you" is loud (red, bold, bell).
  Everything else is quiet fg-color text — 7 spinning windows shouldn't shout.
- **Change-gate every LLM call.** Summaries/classifications only fire when a
  pane's content checksum changed; a parked session costs zero tokens.
- **Every session is bound to a GitHub issue.** New work enters through the
  backlog (typed tasks auto-file an issue), so nothing runs untracked.

Deeper reference: **[docs/TERMS.md](docs/TERMS.md)** defines every term (what
the collector/steward/dash actually are), and **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**
covers the shared-vs-per-fleet split and the path to running **many fleets on
one machine** (one tmux session per repo).

## Install

The installer is Claude itself — [`docs/INSTALL.md`](docs/INSTALL.md) is the playbook:

```sh
git clone https://github.com/verkyyi/claude-fleet.git
cd claude-fleet
claude "install claude-fleet on this machine"
```

Claude will check dependencies, copy the scripts to `~/.claude/fleet/`, write
your `fleet.conf` (backlog repo, main checkout, base branch), append one
source line to `~/.tmux.conf`, merge five hook entries into
`~/.claude/settings.json`, install the daemons (launchd on macOS, the
`systemd/` user units on Linux), and verify each piece — asking before it
touches anything.

Prefer manual? Every step is in [docs/INSTALL.md](docs/INSTALL.md); the pieces are
plain shell scripts with no hidden state.

### Dependencies

tmux ≥ 3.2 · [fzf](https://github.com/junegunn/fzf) ≥ 0.45 (the dashboard binds
use `transform`) · [gh](https://cli.github.com/) (authed) · python3 ·
[Claude Code](https://claude.com/claude-code) (the `claude` CLI; also used by
the two optional LLM daemons). Soft: perl `Time::HiRes` (sharper dash spinner).

Run [`bin/fleet-doctor.sh`](bin/fleet-doctor.sh) to check all of these at once.
(No standalone `jq` — the collector only uses `gh --jq`, which is built in.)

## Keybindings (prefix defaults to your tmux prefix)

| Key | Action |
|---|---|
| `prefix a` | jump to the next window that needs you (red first, then green) |
| `prefix G` | focus the hub's dash pane (jump / new task / bind issue / rename); press again to zoom it fullscreen |
| `prefix b` | backlog modal — near-fullscreen popup; enter spawns the issue session |
| `prefix R` | raw scratch session — a plain, **non-issue-bound** `claude` window (no issue, no worktree, no PR); listed in the dash but excluded from the issue machinery, and ephemeral (not restored across a crash). Prompts for an **optional name** (Enter empty keeps the auto `scratch`/`scratch-2`… name). Also on the dash as `⌃s` |
| `prefix c` | config modal — view/edit `FLEET_*` by friendly label, grouped + collapsible; identity keys locked, global-only vs per-fleet scoped; `⌃s` toggles the write layer, `?` reveals raw keys, enter edits |
| `prefix u` | usage popup — the on-demand usage / subscription-limit detail: the 5h/7d proxy, the official weekly/N-hour limit line (which limit, reset time), and (multi-account) which account new sessions use. Same target as clicking the footer usage stat |
| `prefix r` | reload tmux config |
| `prefix ?` | keymap cheatsheet — a popup listing **every** fleet shortcut (tmux prefix · dash · backlog · config modal), each with a one-line description; `q`/`esc` closes it (also reachable via `?` in the dash and `⌃k` in the backlog) |
| `F9` | (no prefix) jump back to this session's steward hub |

The dash (`prefix G`) and backlog (`prefix b`) each list their own fzf binds
in a header; `prefix ?` is the one place that shows **all** of them together.

Mouse mode is shipped **on** by the fleet baseline (see below), so the footer is
clickable too: the **fleet name** (`#S`) opens a picker of running fleets and
switches to the chosen one, the red **`● N` needs badge** cycles to the next
window that needs you, the **usage stat** opens the usage popup (`prefix u`), and
the **`◉ <account>` chip** opens the account picker (`prefix A`). (Comment out
`set -g mouse on` in `conf/tmux-attention.conf` to keep native select-to-copy.)

The `#S` chip also carries the **cross-fleet** cue: when you're attached to one
fleet and a **different** live fleet has a needs-attention session, an orange
**`⚑ N` flag** appears next to the fleet name — `N` = how many *other* fleets are
waiting. It reuses the existing `#S` element (no new bar item), so clicking it
opens the same picker to jump straight to the waiting fleet. Orange `⚑` means
"another fleet needs you"; the red `●` means "*this* fleet needs you." The signal
is produced by the spinner daemon, which already reads every live fleet's state
across sockets.

### tmux baseline

`conf/tmux-attention.conf` also carries an opinionated **fleet baseline** the UX
assumes so a clean install behaves consistently: `mouse on` (the clickable
footer + dashboard mouse), truecolor (`default-terminal` + a `Tc`
`terminal-overrides` so the theme's hex colors render), `escape-time 10` (snappy
ESC in the Claude TUI), `history-limit 50000`, `allow-rename`/`automatic-rename`
off (the fleet navigates by explicit window names), and the Tokyo-Night status /
pane / message theme. Every line is documented inline and easy to override —
put your own settings in `~/.tmux.conf` *after* the `source-file` line (later
wins) or comment the baseline out. Truly personal bits (prefix remaps, personal
binds) are intentionally left in your `~/.tmux.conf`.

## Configuration

One file, `~/.claude/fleet/fleet.conf` (see
[fleet.conf.example](fleet.conf.example)):

```sh
FLEET_REPO="you/your-repo"            # backlog + PR/CI source
FLEET_MAIN="$HOME/projects/your-repo" # worktrees are created as its siblings
FLEET_BASE_BRANCH="main"
FLEET_PROTECTED_RE="^(master|main|develop|test)$"
FLEET_CTX_WINDOW=200000               # 1000000 if you run 1M-context models
FLEET_GLOBAL_MAX_SESSIONS=8          # system-wide cap on live Claude sessions; 0 = off
```

## Multiple fleets on one machine

A **fleet ≡ a tmux session ≡ one repo**. Run several at once — each pinned to a
different repo with its own checkout — and they share one collector without
clobbering each other (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).

```sh
cf                                         # already running? (re)attach fast. else: infer the repo + bring it up
bin/fleet-up.sh you/webapp                 # clone-or-reuse ~/projects/webapp, open a 'webapp' session
bin/fleet-up.sh you/infra ~/src/infra      # explicit checkout dir
bin/fleet-list.sh                          # ● live / ○ down · name · repo · checkout
tmux attach -t webapp
bin/fleet-down.sh webapp --purge           # kill session (+ drop its conf/cache); checkout stays
```

`cf` (from `shell/cw.zsh`) is your one-key way to a fleet. With **no args** it
first tries to (re)attach to an already-running fleet (`bin/fleet-attach.sh`,
issue #212): one live fleet → straight in; several → the switch picker; already
inside the only one → a no-op. Crossing from another fleet is a detach+reattach
(each fleet is its own tmux server, issue #159), not a `switch-client`. Only when
**nothing** is running does it fall through to `fleet-up.sh` — inferring the repo
from the current checkout's `origin` and reusing that worktree (no clone). With
args it forwards them straight to `fleet-up.sh` to bring a named fleet up.

Each fleet keeps its durable state in **one directory per fleet** —
`~/.config/claude-fleet/fleets/<session>/` (its `conf` overlay, restore map,
issue-bridge/watch state), so `ls ~/.config/claude-fleet/fleets/` is the list of
running fleets (issue #181). The `conf` overlays the global `fleet.conf`, which
still works as a one-fleet default. Every fleet gets a steward pane in its `plan`
hub; set `FLEET_STEWARD_CMD` (global or per-fleet conf) to override the command it
runs. Upgrading from the old flat layout is automatic — `/fleet-sync-install` runs
`bin/fleet-migrate-layout.sh` once (idempotent; readers dual-read both layouts).

## Multiple subscription accounts (auto-failover)

A busy fleet drains one subscription's rolling 5-hour window quickly. Register
**several Claude subscriptions** and the fleet **fails over to a fresh one** the
moment a session hits its limit — new work keeps flowing instead of parking.

Each account is a `claude setup-token` OAuth token dropped in a file (name =
label, `chmod 600`); the launcher exports `CLAUDE_CODE_OAUTH_TOKEN` per session,
and the collector rotates the active account when it spots a
`You've hit your … limit` banner. Off by default — no token files, no change.

```sh
mkdir -p ~/.config/claude-fleet/accounts
printf '%s\n' "$(claude setup-token)" > ~/.config/claude-fleet/accounts/work   # per account
chmod 600 ~/.config/claude-fleet/accounts/*
bin/fleet-account.sh list          # pool · ● active · limited state
```

Switch by hand with `prefix A` (a popup picker) — or just **click the `◉ <account>`
chip** in the status-bar footer, which opens the same picker. Enter makes the
choice active for new sessions; Esc cancels.

Works on macOS and Linux (a token env var, not `CLAUDE_CONFIG_DIR` — which the
macOS Keychain ignores). One caveat: an **already-running** session can't
hot-swap accounts; only newly-spawned ones pick the fresh subscription. Full
design, setup, and limits: **[docs/MULTI-ACCOUNT.md](docs/MULTI-ACCOUNT.md)**.

## Fleet commands (`/skill`s)

Optional repo-shipped Claude Code slash commands that operate on the current
fleet (its `$FLEET_REPO` only), installed by appending `commands/*.md` into
`~/.claude/commands/`. Each declares an owner seat (`worker` / `steward`) and
refuses from the wrong one. Live so far:

- **`/fleet-cleanup`** (steward) — **the fleet never merges** ([docs/CLEANUP.md](docs/CLEANUP.md)).
  `/fleet-ship` arms GitHub auto-merge, GitHub does the merge when the PR is green,
  and the `com.claude-fleet.cleanup` daemon reaps the leftover worktree/window/branch
  and records the resume ledger. `/fleet-cleanup <n>` is the manual escape hatch to
  clean up a specific merged/closed PR *now* instead of waiting a daemon tick — it
  records the ledger, fast-forwards the base checkout, and tears down the worktree.
  It merges nothing and forces nothing.
- **`/fleet-sync-install`** (steward, any fleet) — after claude-fleet's
  own PRs land, re-applies them to the shared live install (`~/.claude/fleet`): pull +
  reload changed daemons + re-merge the hooks delta + install changed commands.
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

## Assumptions & limitations

- **One tmux session ↔ one GitHub repo.** The PR/issue map is one repo-wide
  `gh` call. Multi-repo fleets would need per-window repo detection.
- Windows named `dash`, `plan`, or `backlog` are treated as panels, not
  Claude sessions.
- The dashboard/hub sits at the lowest index (slot 1), placed once at spawn.
  Window **numbers still shift** when a window closes (`renumber-windows on`),
  so navigate by name — not a memorized index.
- The `Notification` hook (red/bell) can lag a question by up to ~1 min
  (Claude Code's idle threshold); the classifier corrects stragglers.
- The token-usage figures are a **local proxy** — the official rate-limit %
  isn't exposed by any API. Weights: output×1 + input×0.25 + cache-write×0.25
  + cache-read×0.02 over rolling 5h/7d windows. When a session happens to print
  the official "N% of your weekly limit" line, the collector scrapes it and uses
  it to **color the footer usage stat** (indigo → yellow ≥`FLEET_USAGE_WARN_PCT`
  → red ≥`FLEET_USAGE_CRIT_PCT`) rather than adding another always-on footer
  segment; the full detail (which limit, reset time, account) is in the usage
  popup — `prefix u` or click the stat.
- The classifier spends real (haiku-sized, change-gated) tokens. It is
  optional; everything else works without it.
- Daemon units ship for both macOS launchd (`launchd/`) and Linux systemd
  user units (`systemd/` — one always-on service + `.timer`/`.service` pairs,
  `__HOME__`-templated; see `systemd/README.md`).

## Safety notes for parallel fleets

Things that bit us and are worth adding on top (not included here because
they're environment-specific): a `PreToolUse` guard hook that blocks
dangerous commands (force-push to main, prod-database writes, destructive
`kubectl`), a lease file so only one session at a time deploys to a shared
test environment, and "claim the issue before working it" as convention.
The issue-per-session binding in this repo is the foundation for all three.

## Contributing

Shell scripts follow a small `set -u` / `pipefail` policy and are linted by
`shellcheck` in CI — see [CONTRIBUTING.md](CONTRIBUTING.md) before sending a PR.

## License

MIT
