# claude-fleet — install playbook

You (Claude Code) are the installer for this repo. When the user asks you to
"install", "set up", or "uninstall" claude-fleet, follow this playbook. Adapt
intelligently to their machine — that is the point of a Claude-orchestrated
install — but keep every change **reversible and announced**: show the user
what you are about to modify (`~/.tmux.conf`, `~/.claude/settings.json`,
LaunchAgents/systemd units) before you do it.

## What this repo is

A tmux + Claude Code setup for running many parallel Claude sessions in one
tmux session — one window per task, each in its own git worktree, with GitHub
issues as the backlog. See README.md for the architecture. Components:

| Piece | What | Requires |
|---|---|---|
| Attention layer | hooks → window colors/spinner/urgency-sort | tmux ≥ 3.2 |
| Dashboard (`prefix+j`) | fzf mission control | fzf ≥ 0.45 (0.60+ best); its binds use `transform` |
| Backlog (`prefix+b`) | GitHub issues panel, Enter = spawn issue-bound session | gh (authed) |
| Collector daemon | git/gh/usage caches every ~45s | gh, python3 |
| Disk guard daemon (recommended) | circuit-breaker + runaway-writer forensics; stops a full disk from crashing the shared tmux server | — |
| Classifier daemon (optional) | corrects state, detects `looping` | `claude` CLI |
| Summarizer daemon + hooks (optional) | one-line LLM summary per session → dash summary column; refreshed on Stop/SessionStart hooks + a ~180s catch-all daemon | `claude` CLI |
| Worktree janitor (optional) | prunes merged+clean+idle worktrees | gh |
| `cw`/`cwrm`/`cwclean` | zsh worktree helpers | zsh |

## Install steps

1. **Preflight.** Run `sh ~/.claude/fleet/bin/fleet-doctor.sh` (or from the repo
   before copying) — it checks tmux ≥ 3.2 · fzf ≥ 0.45 · gh (+ auth) · python3 ·
   claude · perl `Time::HiRes` and prints pass/warn/fail. Offer to
   `brew install` anything that fails. Notes: standalone `jq` is **not** needed
   (the collector only uses `gh --jq`, which is built in); perl `Time::HiRes` is
   a soft dep (without it the dash spinner ticks at whole-second granularity).
   If `gh` is not authed, the backlog/PR features silently show nothing — tell
   the user.

2. **Copy to the install dir.** Canonical: `~/.claude/fleet/`. Copy `bin/`,
   `conf/`, `shell/`, `fleet.conf.example` there; `mkdir -p ~/.claude/fleet/logs`;
   `chmod +x ~/.claude/fleet/bin/*.sh`. If the user wants a different dir,
   also rewrite the `~/.claude/fleet` paths inside `conf/tmux-attention.conf`
   and `hooks/settings-hooks.json` to match.

3. **Write `~/.claude/fleet/fleet.conf`.** Ask the user (or infer from their
   current repo) the values in `fleet.conf.example`: `FLEET_REPO`
   (owner/name of the backlog repo), `FLEET_MAIN` (its main checkout path),
   `FLEET_BASE_BRANCH`, and whether their plan runs 1M-context models
   (`FLEET_CTX_WINDOW`).

4. **Hook up tmux.** Run `sh ~/.claude/fleet/bin/reapply-tmux-attention.sh`
   (idempotently appends one `source-file` line to `~/.tmux.conf`). Warn the
   user about the opinionated bits of `conf/tmux-attention.conf` — prefix
   bindings on `a/j/b/i/r` and a status-bar restyle — and comment out anything
   they don't want.

5. **Merge Claude Code hooks.** Merge `hooks/settings-hooks.json` into
   `~/.claude/settings.json` — APPEND to any existing hook arrays, never
   replace them (jq: `.hooks.PreToolUse += [...]` etc., creating keys that
   don't exist). Back up settings.json first. These hooks are no-ops outside
   tmux and always exit 0, so they are safe to add globally. The `Stop` +
   `SessionStart` entries also fire `summarize-hook.sh`, which refreshes the
   dash summary for *that* window the instant a turn ends / a session starts
   (backgrounded, so it never slows a turn); it self-disables if `claude` isn't
   on PATH, and is a no-op if you skip the summarizer.

6. **Daemons.**
   - macOS: for each template in `launchd/`, substitute `__HOME__` with the
     real home dir **and `__BREW_PREFIX__` with `$(brew --prefix)`** (falls back
     to `/opt/homebrew` if `brew` isn't on PATH) — this is what makes tool
     discovery work on Intel (`/usr/local`) as well as Apple Silicon
     (`/opt/homebrew`). Write to `~/Library/LaunchAgents/`, then
     `launchctl bootstrap gui/$(id -u) <plist>` (or `launchctl load` on older
     macOS). The spinner (KeepAlive) and collector (45s) are the required two;
     the **diskguard** watcher (`com.claude-fleet.diskguard`, 60s) is strongly
     recommended — it's the crash-guard: a full volume ENOSPCs the collector and
     kills the *shared* tmux server, taking every fleet down at once, so the
     watcher captures forensics + notifies on low disk and its `--gate` mode
     (called by fleet-up and fleet-restore) refuses to add load below the floor.
     classify/summarize/worktree-autoclean are optional — ask the user, and
     mention classify and summarize spend (small, change-gated) LLM tokens.
     summarize (`com.claude-fleet.summarize`, 180s) writes the dash's one-line
     per-session summary column; without it that column just stays empty.
   - Linux: use the ready-made units in `systemd/` (parity with the plists,
     `__HOME__`-templated). Substitute `__HOME__` and copy into
     `~/.config/systemd/user/`, then `systemctl --user daemon-reload` and
     `systemctl --user enable --now claude-fleet-spinner.service` +
     `claude-fleet-collect.timer` (the required two) + the recommended
     `claude-fleet-diskguard.timer` (crash-guard); the optional
     classify/summarize/worktree-autoclean are `.timer`s too. Run `loginctl
     enable-linger "$USER"` so they run detached. Full recipe in
     `systemd/README.md`.

7. **Shell helpers.** Offer to add `source ~/.claude/fleet/shell/cw.zsh` to
   `~/.zshrc` (bash users: the functions are zsh-flavored; port on request).

   **Optional — multiple subscription accounts w/ auto-failover.** If the user
   holds more than one Claude subscription and wants the fleet to switch when one
   hits its usage limit, set it up per **[docs/MULTI-ACCOUNT.md](docs/MULTI-ACCOUNT.md)**:
   one `claude setup-token` OAuth token per file in
   `~/.config/claude-fleet/accounts/` (name = label, `chmod 600`). Off by default
   (no files → the spawn launcher `bin/fleet-claude.sh` is just `exec claude`).
   `bin/fleet-doctor.sh` validates the token files.

8. **Verify.** Inside tmux: start `claude` in a window, run any tool, and
   check `tmux show-options -w @claude_state` flips to `working`; check the
   spinner animates; `prefix+j` opens the dash; `prefix+b` opens the backlog
   (needs the collector to have run once — trigger it by hand:
   `bash ~/.claude/fleet/bin/tmux-dash-collect.sh`). Report each check.

## Uninstall

Remove the LaunchAgents (`launchctl bootout gui/$(id -u)/com.claude-fleet.*`,
delete the plists), delete the `source-file …tmux-attention.conf` line from
`~/.tmux.conf`, remove the five `set-claude-state.sh` hook entries (and the two
`summarize-hook.sh` entries on `Stop`/`SessionStart`) from
`~/.claude/settings.json`, delete `~/.claude/fleet/`, and clear per-window
state: `tmux set-window-option -g @claude_state ""` (or just restart tmux).

## Conventions the code assumes (tell the user)

- **One tmux session ↔ one GitHub repo.** The PR map is one repo-wide
  `gh pr list`; multi-repo fleets need per-window repo detection (not built).
- Windows named `dash`, `plan`, `backlog` are treated as panels, not Claude
  sessions (excluded from the dash list).
- The lowest-indexed window is pinned by the urgency sorter — keep your
  hub/dashboard there. Window numbers are NOT stable; navigate by name or
  position (slot 1 = most urgent).
- Claude Code re-reads settings.json hooks per turn, so running sessions pick
  up the hooks without restart.
