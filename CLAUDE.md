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
| Attention layer | hooks → window colors/spinner/urgency-sort; the spinner daemon also demotes stuck-`working` windows (missed Stop hook) via a marker-agnostic `window_activity`-staleness check (`FLEET_STUCK_WORKING_SECS`) | tmux ≥ 3.2 |
| Dashboard (`prefix+j`) | fzf mission control | fzf ≥ 0.45 (0.60+ best); its binds use `transform` |
| Backlog (`prefix+b`) | GitHub issues panel, Enter = spawn issue-bound session | gh (authed) |
| Config modal (`prefix+c`) | fzf popup to view/edit `FLEET_*` config across both layers (per-fleet overlay ▸ global ▸ default); ⌃s toggles the write scope, enter edits a key (typed validation, backup-first) | fzf ≥ 0.45 |
| Collector daemon | git/gh/usage/issues caches every ~60s | gh, python3 |
| PR-status refresher (recommended) | `com.claude-fleet.pr-refresh` (~15s): owns PR/CI state (`prmap` + window `@prci`/`@pfg`) on a fast tick so CI-green/merged shows within ~15s instead of riding the 60s collector; single writer, no collector race (`FLEET_PR_REFRESH_INTERVAL`) | gh |
| Disk guard daemon (recommended) | circuit-breaker + runaway-writer forensics; stops a full disk from crashing the shared tmux server | — |
| Autofill dispatcher (optional) | `com.claude-fleet.dispatch` (~60s): auto-spawns the highest-priority eligible backlog issue whenever both caps have headroom. OFF by default (`FLEET_AUTOFILL=1` per fleet); single-writer, disk-gated, rate-limited; spends LLM tokens | gh |
| Classifier (optional) | Stop-hook does real-time single-window state fix (detects `looping`); a slow ~1800s daemon backstops missed windows. It only refines `done`/`needs`/`looping` (trusts the hook for `working`) — so a window stuck at `working` from a missed Stop is handled upstream by the spinner's demote check, which flips it to `done` and then kicks the classifier to refine it | `claude` CLI |
| Summarizer daemon + hooks (optional) | one-line LLM summary per session → dash summary column; refreshed on Stop/SessionStart hooks + a ~180s catch-all daemon | `claude` CLI |
| Worktree janitor (optional) | prunes merged+clean+idle worktrees | gh |
| `cw`/`cwrm`/`cwclean` | zsh worktree helpers | zsh |
| Fleet commands (optional) | repo-shipped `/skill`s (`commands/`) — fleet-aware slash commands, appended to `~/.claude/commands/` | claude |

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
   bindings on `a/j/G/b/A/c/r/?` and a status-bar restyle — and comment out
   anything they don't want. Note `prefix+c` (the config modal) **rebinds tmux's
   default new-window**, and `prefix+?` (the keymap cheatsheet popup —
   `bin/fleet-keys.sh`) **rebinds tmux's default `list-keys`**; in a fleet you
   spawn via the dash/backlog and rarely need raw `list-keys`, so both are free
   — but call them out. There's also one **root-table** bind (`bind -n F9`): F9
   from any window jumps back to this session's steward hub (`steward-zoom.sh`).
   Unlike the prefix binds it intercepts the key in every pane before the app —
   safe because the Claude TUI/shells don't use function keys — so flag it too.

5. **Merge Claude Code hooks.** Merge `hooks/settings-hooks.json` into
   `~/.claude/settings.json` — APPEND to any existing hook arrays, never
   replace them (jq: `.hooks.PreToolUse += [...]` etc., creating keys that
   don't exist). Back up settings.json first. These hooks are no-ops outside
   tmux and always exit 0, so they are safe to add globally. The `Stop` +
   `SessionStart` entries also fire `summarize-hook.sh`, which refreshes the
   dash summary for *that* window the instant a turn ends / a session starts
   (backgrounded, so it never slows a turn); it self-disables if `claude` isn't
   on PATH, and is a no-op if you skip the summarizer. The `Stop` entry also
   fires `classify-hook.sh`, the real-time path for state classification: it
   hands just the stopped window to `classify-sessions.sh --window`, so the
   ambiguous `done` is resolved to `looping`/`needs`/`done` within ~1-2s instead
   of waiting for the daemon backstop. Also backgrounded + self-disabling; a
   no-op if you skip the classifier.

6. **Daemons.**
   - macOS: for each template in `launchd/`, substitute `__HOME__` with the
     real home dir **and `__BREW_PREFIX__` with `$(brew --prefix)`** (falls back
     to `/opt/homebrew` if `brew` isn't on PATH) — this is what makes tool
     discovery work on Intel (`/usr/local`) as well as Apple Silicon
     (`/opt/homebrew`). Write to `~/Library/LaunchAgents/`, then
     `launchctl bootstrap gui/$(id -u) <plist>` (or `launchctl load` on older
     macOS). The spinner (KeepAlive) and collector (60s) are the required two;
     the **diskguard** watcher (`com.claude-fleet.diskguard`, 60s) is strongly
     recommended — it's the crash-guard: a full volume ENOSPCs the collector and
     kills the *shared* tmux server, taking every fleet down at once, so the
     watcher captures forensics + notifies on low disk and its `--gate` mode
     (called by fleet-up and fleet-restore) refuses to add load below the floor.
     The **pr-refresh** daemon (`com.claude-fleet.pr-refresh`, 15s) is also
     recommended — it owns PR/CI status (`prmap` + window `@prci`/`@pfg`) on its
     own fast tick, decoupled from the 60s collector, so a PR going green or
     merging shows within ~15s (when the steward is watching to `/fleet-land`) instead
     of up to a minute. It's the single writer of that state (the collector no
     longer touches it), disk work is trivial, and only `gh` is needed;
     `FLEET_PR_REFRESH_INTERVAL` (default 15) tunes it — keep it in step with the
     plist `StartInterval`.
     classify/summarize/worktree-autoclean are optional — ask the user, and
     mention classify and summarize spend (small, change-gated) LLM tokens.
     classify (`com.claude-fleet.classify`, 1800s) is now just a backstop — the
     real work happens in the `Stop` hook (`classify-hook.sh`); install the
     daemon only if you want the periodic net for windows a Stop never revisits.
     summarize (`com.claude-fleet.summarize`, 180s) writes the dash's one-line
     per-session summary column; without it that column just stays empty.
     dispatch (`com.claude-fleet.dispatch`, 60s) is the **autofill** daemon —
     install it only if a fleet sets `FLEET_AUTOFILL=1`; it auto-spawns the
     highest-priority eligible backlog issue under both caps (per-fleet
     `FLEET_MAX_SESSIONS` + global), single-writer + disk-gated + rate-limited.
     OFF by default; it spends LLM tokens (one real Claude session + PR per
     spawn), so ask before installing and mention the cost.
   - Linux: use the ready-made units in `systemd/` (parity with the plists,
     `__HOME__`-templated). Substitute `__HOME__` and copy into
     `~/.config/systemd/user/`, then `systemctl --user daemon-reload` and
     `systemctl --user enable --now claude-fleet-spinner.service` +
     `claude-fleet-collect.timer` (the required two) + the recommended
     `claude-fleet-diskguard.timer` (crash-guard) and
     `claude-fleet-pr-refresh.timer` (fast ~15s PR/CI status); the optional
     dispatch/classify/summarize/worktree-autoclean are `.timer`s too. Run `loginctl
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

8. **Fleet commands (optional).** Copy `commands/*.md` → `~/.claude/commands/`
   — **APPEND**; do not clobber existing personal commands (e.g. `sweep.md`).
   These are repo-shipped, fleet-aware `/skill`s (optional quality-of-life):
   `fleet-claim`, `fleet-ship`, `fleet-blocked`, `fleet-land`,
   `fleet-land-train`, `fleet-sync-install`, `fleet-status`, and
   `fleet-new-issue` (plus the contract/template — `commands/README.md`,
   `commands/_template.md`). `fleet-doctor.sh` reports how many are installed
   (warn, not fail, if none — they're optional). See `commands/README.md` for
   the skill contract.

9. **Verify.** Inside tmux: start `claude` in a window, run any tool, and
   check `tmux show-options -w @claude_state` flips to `working`; check the
   spinner animates; `prefix+j` opens the dash; `prefix+b` opens the backlog
   (needs the collector to have run once — trigger it by hand:
   `bash ~/.claude/fleet/bin/tmux-dash-collect.sh`). Report each check.

## Uninstall

Remove the LaunchAgents (`launchctl bootout gui/$(id -u)/com.claude-fleet.*`,
delete the plists), delete the `source-file …tmux-attention.conf` line from
`~/.tmux.conf`, remove the five `set-claude-state.sh` hook entries (and the two
`summarize-hook.sh` entries on `Stop`/`SessionStart`) from
`~/.claude/settings.json`, delete `~/.claude/fleet/`, remove any fleet commands
you copied into `~/.claude/commands/` (the ones with a `<!-- fleet skill … -->`
marker — leave your personal commands), and clear per-window state:
`tmux set-window-option -g @claude_state ""` (and `@prci`/`@pfg`, set by the
pr-refresh daemon) — or just restart tmux. (The `com.claude-fleet.*` bootout
glob already covers `com.claude-fleet.pr-refresh`; on Linux
`systemctl --user disable --now claude-fleet-pr-refresh.timer`.)

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
