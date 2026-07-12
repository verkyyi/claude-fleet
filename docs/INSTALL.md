# claude-fleet — install playbook

You (Claude Code) are the installer for this repo. When the user asks you to
"install", "set up", or "uninstall" claude-fleet, follow this playbook. Adapt
intelligently to their machine — that is the point of a Claude-orchestrated
install — but keep every change **reversible and announced**: show the user
what you are about to modify (`~/.tmux.conf`, `~/.claude/settings.json`,
LaunchAgents/systemd units) before you do it.

Read `CLAUDE.md` (repo root) for what the repo is and the conventions the code
assumes — this doc is only the install/uninstall procedure.

## Components

| Piece | What | Requires |
|---|---|---|
| Attention layer | hooks → window colors/spinner/urgency-sort; the spinner daemon also demotes stuck-`working` windows (missed Stop hook) via a marker-agnostic `window_activity`-staleness check (`FLEET_STUCK_WORKING_SECS`) | tmux ≥ 3.2 |
| Dashboard (`prefix+G`) | fzf mission control — an embedded pane in the `plan` hub (dash above, steward below); `prefix+G` focuses it and toggles it fullscreen (`dash-zoom.sh`, the mirror of F9's steward focus). No standalone dash window | fzf ≥ 0.45 (0.60+ best); its binds use `transform` |
| Backlog (`prefix+b`) | GitHub issues panel, Enter = spawn issue-bound session. Each row tags its `priority:pN` (from `labels_<slug>`, no extra gh call) and issues sort by priority within a milestone; `⌃y` cycles a row's priority label (none→p2→p1→p0, `bin/dash-issue-priority.sh`, no popup). `⌃n` files a one-line issue | gh (authed) |
| Config modal (`prefix+c`) | fzf popup to view/edit `FLEET_*` config across both layers (per-fleet overlay ▸ global ▸ default); ⌃s toggles the write scope, enter edits a key (typed validation, backup-first) | fzf ≥ 0.45 |
| Cross-machine pre-spawn dedup | every spawn (`bin/dash-issue-session.sh`, the one choke point) consults the shared GitHub issue as a claim ledger before spawning, so two fleets on **different machines / same repo** don't both spawn `issue-<N>` (duplicate worktrees + push race + competing PRs) — the local tmux dedup only sees one machine. **The assignee IS the claim** (issue #283): taken (assignee · non-open state · open PR) ⇒ **refuse**; free ⇒ **claim AT SPAWN** by assigning `@me` (not on the worker's first `/fleet-claim` turn — that gap was the race) so a peer sees the assignee within ~1s. **NOT a mutex** (GitHub has no CAS on an issue) — it shrinks the race window, doesn't eliminate it; the old sub-second REST-comment-id tie-break was retired with the `▶ claiming` marker (workers share one gh account, so no per-attempt tie token exists). `--force`/`--reclaim` spawns past a stale claim. **ON by default** — the cost is a few gh reads/spawn (claim-at-spawn just moves `/fleet-claim`'s assign earlier; a gh outage degrades to spawn-anyway) and it self-disables when gh is absent; a single-machine fleet wanting the zero-gh fast path sets `FLEET_PRESPAWN_DEDUP=0`. `/fleet-claim` stays but no-ops when it finds the pre-claim | gh (authed) |
| Collector daemon | git/gh/usage/issues caches every ~60s | gh, python3 |
| PR-status refresher (recommended) | `com.claude-fleet.pr-refresh` (~15s): owns PR/CI state (`prmap` + window `@prci`/`@pfg`) on a fast tick so CI-green/merged shows within ~15s instead of riding the 60s collector; single writer, no collector race (`FLEET_PR_REFRESH_INTERVAL`) | gh |
| Disk guard daemon (recommended) | disk circuit-breaker + runaway-writer forensics; stops a full disk from crashing a fleet's tmux server (each fleet has its OWN socket now — issue #159 — but a full volume still ENOSPCs every server on it). Its `--watch` tick also runs a **runaway-CPU watchdog** (issue #151): our-user, no-controlling-tty processes held ≥`FLEET_RUNAWAY_CPU_PCT`% for ≥`FLEET_RUNAWAY_CPU_SECS`s → forensic incident + notify, optionally SIGTERM/KILL (`FLEET_RUNAWAY_CPU_ACTION`). Protects each tmux server from a detached orphan spinning a core; the server + launchd/systemd are excluded, live worker panes have a tty so are never touched. OFF by default (`PCT=0`) | — |
| Issue-bridge (optional) | `com.claude-fleet.issue-bridge` (~15s poll, or a webhook via `--deliver`+HMAC): relays a trusted issue comment INTO the bound worker as its next turn — the issue thread becomes the steward↔worker↔collaborator channel (replaces flaky send-keys). Single shared instance. Loop-safe via the `<!-- fleet:no-relay -->` marker (`bin/fleet-comment.sh`); gated by `author_association` (relayed comment = RCE on a bypass-perms worker); idle-gated; deduped. Also routes a per-fleet **steward control issue** (`FLEET_STEWARD_ISSUE`, #146) — comments on it relay into the `@steward` hub pane (the operator↔steward wake/async channel), same gates/marker/idle/dedup. OFF by default (`FLEET_ISSUE_BRIDGE=1` per fleet); spends LLM tokens. See docs/ISSUE-BRIDGE.md | gh (+ python3 for `--deliver`) |
| Cleanup (recommended) | **THE FLEET NEVER MERGES** (issue #277, closes #260) — it arms auto-merge and cleans up after merges. The worker's `/fleet-claim` ship step opens the PR then `gh pr merge --auto --<FLEET_MERGE_METHOD>` (default `squash`, issue #283) **arms** GitHub auto-merge (never merges); GitHub (or a human on the web, or a collaborator) does the merge when green + branch-protection-satisfied. `com.claude-fleet.cleanup` (`bin/fleet-cleanup-daemon.sh`, ~60s) then scans the `prmap` cache pr-refresh already writes (`--state all` ⇒ MERGED/CLOSED rows, ZERO extra `gh`) for a final PR whose `issue-<N>` still has a live worktree/window and drives `bin/fleet-cleanup.sh <PR>` — the mechanical, **no-merge** janitor (`fleet-land.sh` MINUS the merge): record the resume ledger FIRST, `git pull --ff-only` the base under the shared land-lease (`bin/fleet-land-lease.sh`, base-ff serialization), then ordered teardown window → worktree → branch. Merge-source-agnostic, idempotent (`skip:nothing` on an already-reaped PR). Single-writer per repo + disk-gated. **ON by default** (opt out `FLEET_CLEANUP=0`; merges nothing, relaxes no gate). Manual now: `/fleet-cleanup <n>`. See docs/CLEANUP.md | gh |
| Watcher (optional) | `com.claude-fleet.watch` (~45s): the **zero-token event-driven steward wake** (issue #147). Sleeps on the fleet reading ONLY existing state (`@claude_state`/`@issue` + the `labels_<slug>` cache — no LLM, no per-tick `gh`) and wakes the steward ONLY on a decision-worthy **attention edge**: a worker stuck (`looping`), the needs-attention count rising, or a `prod-alert` issue appearing. (Trimmed in #279 — the PR-green→`/land`, worker-opened-PR and free-slot edges were removed once landing retired in #277: nothing triggers a land, the dash shows an opened PR, and a free slot is surfaced by the dash/backlog directly.) Edge-triggered + deduped (transitions not levels; first run seeds silently). Delivery = the steward control issue (`FLEET_STEWARD_ISSUE`, #146) → the issue-bridge relays the wake into the `@steward` pane. Single-writer per repo + disk-gated; `--dry-run` prints edges without posting. OFF by default (`FLEET_WATCH=1` per fleet; needs `FLEET_STEWARD_ISSUE` + in practice `FLEET_ISSUE_BRIDGE=1`); the watcher spends no tokens but each wake makes the steward take a turn. See docs/WATCH.md | gh + issue-bridge |
| Classifier (optional) | Stop-hook does real-time single-window state fix (detects `looping`), plus the spinner's stuck-`working` demote kicks it for a window a Stop missed. It only refines `done`/`needs`/`looping` (trusts the hook for `working`) — so a window stuck at `working` from a missed Stop is handled upstream by the spinner's demote check, which flips it to `done` and then kicks the classifier to refine it | `claude` CLI |
| Summarizer daemon + hooks (optional) | one-line LLM summary per session → dash summary column; refreshed on Stop/SessionStart hooks + a ~180s catch-all daemon | `claude` CLI |
| Worktree janitor (optional) | prunes merged+clean+idle worktrees. Before each removal it **reaps any process still anchored to the worktree** (`fleet_reap_worktree_procs` — argv match + cwd match, SIGTERM→SIGKILL; issue #151) so a detached orphan can't outlive its dir and drain a core against the shared tmux server. The dash's `⌃x`/`⌥x` reap (`dash-reap.sh`) does the same | gh |
| Raw scratch session (`prefix+R` / dash `⌃s`) | opens a plain, **non-issue-bound** `claude` window in the fleet — no GitHub issue, but in its **own writable `scratch-N` git worktree** off the base branch (`bin/dash-raw-session.sh`, issues #214/#290). The counterpart to the issue-bound spawns (`prefix+n` / backlog Enter / `dash-issue-session.sh`), for ad-hoc exploration or experiments that may need to WRITE code (the base checkout is hook-enforced read-only). A scratch that turns real just pushes its branch + opens a PR — the prmap is repo-wide, so the janitor reaps a merged `scratch-N` like any worker (zero new machinery), and the unique cwd makes its transcript resolvable. Marked `@raw=1` + `@worktree=<path>`, named `scratch-N` (or a custom name); **listed in the dash as a real session** (counts toward the session cap) but excluded from the issue machinery — no `@issue`, so the watcher (`@raw` skipped) leaves it alone, while the classifier/summarizer still show its state + summary. The **window** is ephemeral (not snapshotted/restored across a crash); its **worktree** survives on disk and is reaped by the janitor's scratch rules — clean + no unmerged work → removed silently; dirty or unmerged → kept + surfaced once (never silently delete an experiment; `dash ⌃x` disposes it) | claude |
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
   and `hooks/settings-hooks.json` to match. Also copy the steward's charter
   **one level up** — `cp steward.md ~/.claude/steward.md` — this is the
   first-mate standing-orders file `bin/steward-session.sh` reads when it spawns
   or respawns a fleet's `plan` hub. It's a personal rail (flat in `~/.claude/`,
   not under the checkout), so a fresh charter that lands on master reaches the
   live file via `/fleet-sync-install`; if you keep local edits in it, sync will
   refuse to overwrite and tell you.

3. **Write `~/.claude/fleet/fleet.conf`.** Ask the user (or infer from their
   current repo) the values in `fleet.conf.example`: `FLEET_REPO`
   (owner/name of the backlog repo), `FLEET_MAIN` (its main checkout path),
   `FLEET_BASE_BRANCH`, and whether their plan runs 1M-context models
   (`FLEET_CTX_WINDOW`).

4. **Hook up tmux.** Run `sh ~/.claude/fleet/bin/reapply-tmux-attention.sh`
   (idempotently appends one `source-file` line to `~/.tmux.conf`). Warn the
   user about the opinionated bits of `conf/tmux-attention.conf` — a **fleet
   baseline** block (issue #222) + prefix bindings on `a/G/b/n/R/A/u/c/r/?` and a
   status-bar restyle — and comment out anything they don't want. The **fleet
   baseline** ships the tmux defaults the fleet UX assumes so a clean install is
   consistent (they used to live only in a pre-repo install.sh's `~/.tmux.conf`):
   `set -g mouse on` (the clickable footer ranges + dashboard mouse), truecolor
   (`default-terminal` + a `Tc` `terminal-overrides` so the theme's hex colors
   render — most likely to fight a user's own TERM, so flag it), `escape-time 10`,
   `history-limit 50000`, `allow-rename`/`automatic-rename` off, and the
   Tokyo-Night status/pane/message theme. Each line is documented inline and
   overridable — a user's own `~/.tmux.conf` settings AFTER the `source-file` line
   win (later wins), or comment the baseline out. Truly personal bits (a prefix
   remap, personal binds) are intentionally NOT shipped. Note `prefix+c` (the config modal) **rebinds tmux's
   default new-window**, `prefix+n` (quick-dispatch — file an issue + spawn its
   worker) **rebinds tmux's default `next-window`**, and `prefix+?` (the keymap
   cheatsheet popup — `bin/fleet-keys.sh`) **rebinds tmux's default `list-keys`**;
   in a fleet you spawn via the dash/backlog and navigate by name, so all three
   defaults are rarely needed — but call them out. `prefix+R` (raw scratch
   session — `bin/dash-raw-session.sh`) and `prefix+u` (the usage popup —
   `bin/usage-popup.sh`, issue #239) are **not** tmux defaults, so they clobber
   nothing, but mention them too. There are also **root-table** binds (`bind -n …`)
   that intercept the key/mouse in every pane *before* the app, so flag each: `F9`
   jumps back to this session's steward hub (`steward-zoom.sh`) — safe because the
   Claude TUI/shells don't use function keys; `MouseDown1Status` owns the clickable
   footer ranges (hub/fleet/needs/account/usage); and **double-click-to-zoom**
   (`DoubleClick1Pane` → `resize-pane -Z -t=`, `DoubleClick1Border` on the divider)
   toggles a pane's fullscreen as the mouse counterpart to `prefix+G`/`F9` — its
   trade-off is losing tmux's default double-click = select-word (copy), so call it
   out. All are overridable from the user's own `~/.tmux.conf` after the `source-file`
   line, or comment them out — the same framing as the rest of the baseline block.

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
   no-op if you skip the classifier. The `SessionStart` array also fires
   `steward-readopt-hook.sh` (issue #155): a `/clear` keeps the same steward
   process alive but wipes its context, so it forgets it's the steward and — since
   CC reloads the cwd `CLAUDE.md` — could drift off its first-mate charter. The
   hook re-injects `steward.md` (plus a newest-handoff pointer) back into context,
   but ONLY when the pane is `@steward=1` **and** the SessionStart `source` is
   `clear` — so a worker `/clear` is never handed steward identity, and
   startup/resume/compact (already covered by the spawn seed prompt and the
   crash-resume path #143) don't pile on redundant context. No-op outside tmux and
   if `~/.claude/steward.md` is absent.

6. **Daemons.**
   - macOS: for each template in `launchd/`, substitute `__HOME__` with the
     real home dir **and `__BREW_PREFIX__` with `$(brew --prefix)`** (falls back
     to `/opt/homebrew` if `brew` isn't on PATH) — this is what makes tool
     discovery work on Intel (`/usr/local`) as well as Apple Silicon
     (`/opt/homebrew`). Write to `~/Library/LaunchAgents/`, then
     `launchctl bootstrap gui/$(id -u) <plist>` (or `launchctl load` on older
     macOS). The spinner (KeepAlive) and collector (60s) are the required two;
     the **diskguard** watcher (`com.claude-fleet.diskguard`, 60s) is strongly
     recommended — a full volume ENOSPCs any tmux server whose writes fail, and
     though each fleet now runs on its OWN socket (issue #159) so a disk-full no
     longer takes *every* fleet down through one shared server, it can still crash
     each fleet sharing that volume — so the watcher captures forensics + notifies
     on low disk and its `--gate` mode (called by fleet-up and fleet-restore)
     refuses to add load below the floor. The same `--watch` tick also runs the
     **runaway-CPU watchdog** (issue #151) — no extra unit; it's OFF until a fleet
     sets `FLEET_RUNAWAY_CPU_PCT>0`, then a detached orphan spinning a core is
     caught + (optionally) killed before it can overload its fleet's server.
     The **pr-refresh** daemon (`com.claude-fleet.pr-refresh`, 15s) is also
     recommended — it owns PR/CI status (`prmap` + window `@prci`/`@pfg`) on its
     own fast tick, decoupled from the 60s collector, so a PR going green or
     merging shows within ~15s (when the steward is reviewing / the cleanup daemon
     is waiting to reap it) instead
     of up to a minute. It's the single writer of that state (the collector no
     longer touches it), disk work is trivial, and only `gh` is needed;
     `FLEET_PR_REFRESH_INTERVAL` (default 15) tunes it — keep it in step with the
     plist `StartInterval`.
     summarize/worktree-autoclean are optional — ask the user, and mention that
     summarize (and the classify hook) spend (small, change-gated) LLM tokens.
     classify has NO daemon — the real work happens in the `Stop` hook
     (`classify-hook.sh` → `classify-sessions.sh --window`) plus the spinner's
     stuck-`working` demote, so there is nothing to install for it.
     summarize (`com.claude-fleet.summarize`, 180s) writes the dash's one-line
     per-session summary column; without it that column just stays empty.
     issue-bridge (`com.claude-fleet.issue-bridge`, 15s) relays trusted issue
     comments into the bound worker as its next turn (the issue-as-event-bus) —
     install it only if a fleet sets `FLEET_ISSUE_BRIDGE=1`. A relayed comment is
     autonomous tool-use in a bypass-permissions worker (treat as **RCE**), so it
     is OFF by default, gated by `author_association`, and spends LLM tokens per
     relay — ask before installing, mention the cost, and warn that un-gated relay
     on a **public** repo is unsafe. The `--poll` ingress needs only `gh`; the
     faster webhook ingress (`--deliver`) additionally needs `python3` + an HMAC
     secret. Full setup + loop-safety (the `fleet-comment.sh` marker) in
     **docs/ISSUE-BRIDGE.md**.
     watch (`com.claude-fleet.watch`, 45s) is the **zero-token fleet watcher** —
     install it only if a fleet sets `FLEET_WATCH=1` (which needs
     `FLEET_STEWARD_ISSUE` + in practice `FLEET_ISSUE_BRIDGE=1`). It reads only the
     state the collector + pr-refresh already cache and wakes the steward on
     decision-worthy edges (PR green, worker stuck, needs-attention rise, …) via
     the #146 control-issue channel. The daemon spends no tokens, but each wake
     makes the steward take an LLM turn — so it is OFF by default; ask before
     installing and mention that wakes cost steward tokens. `--dry-run` prints the
     edges without posting. Full design in **docs/WATCH.md**.
     cleanup (`com.claude-fleet.cleanup`, 60s) is the **cleanup daemon** —
     **recommended** for every fleet, since **the fleet never merges** (issue #277):
     the worker's `/fleet-claim` ship step arms GitHub auto-merge and this daemon
     reaps the leftover
     worktree/window/branch + records the resume ledger once a PR is final (MERGED
     or CLOSED-unmerged). It scans the prmap cache pr-refresh already writes (MERGED/
     CLOSED rows, ZERO extra `gh`) for a final PR with a live worktree/window and
     drives `bin/fleet-cleanup.sh`, single-writer + disk-gated + rate-limited
     (`FLEET_CLEANUP_MAX_PER_TICK`). It **merges nothing and
     relaxes no approval gate**, so it is **ON by default** per fleet (opt out with
     `FLEET_CLEANUP=0`); it spends no tokens. `--dry-run` prints intent without
     reaping. This closes #260 (a web/collaborator merge is reaped too). Full design
     in **docs/CLEANUP.md**.
   - Linux: use the ready-made units in `systemd/` (parity with the plists,
     `__HOME__`-templated). Substitute `__HOME__` and copy into
     `~/.config/systemd/user/`, then `systemctl --user daemon-reload` and
     `systemctl --user enable --now claude-fleet-spinner.service` +
     `claude-fleet-collect.timer` (the required two) + the recommended
     `claude-fleet-diskguard.timer` (crash-guard) and
     `claude-fleet-pr-refresh.timer` (fast ~15s PR/CI status); the optional
     issue-bridge/watch/cleanup/summarize/worktree-autoclean are `.timer`s too.
     Run `loginctl enable-linger "$USER"` so they run detached. Full recipe in
     `systemd/README.md`.

7. **Shell helpers.** Offer to add `source ~/.claude/fleet/shell/cw.zsh` to
   `~/.zshrc` (bash users: the functions are zsh-flavored; port on request).
   Sourcing it also installs a `tmux()` **destroy-guard** (issue #158): from a
   worker shell it refuses `kill-server` and any `kill-session`/`kill-window`
   aimed at a sibling — one stray kill on the shared `default` socket would take
   down every fleet at once. It's an accident rail, not a security boundary
   (bypass-perms can always `pkill`); self-teardown, isolated sockets (`-L`/`-S`),
   and `FLEET_ALLOW_TMUX_DESTROY=1` all pass through. Tell the user so a
   deliberate live-server destroy isn't a surprise.

   **Optional — multiple subscription accounts w/ auto-failover.** If the user
   holds more than one Claude subscription and wants the fleet to switch when one
   hits its usage limit, set it up per **[docs/MULTI-ACCOUNT.md](MULTI-ACCOUNT.md)**:
   one `claude setup-token` OAuth token per file in
   `~/.config/claude-fleet/accounts/` (name = label, `chmod 600`). Off by default
   (no files → the spawn launcher `bin/fleet-claude.sh` is just `exec claude`).
   `bin/fleet-doctor.sh` validates the token files.

8. **Fleet commands (optional).** Copy `commands/*.md` → `~/.claude/commands/`
   — **APPEND**; do not clobber existing personal commands (e.g. `sweep.md`).
   These are repo-shipped, fleet-aware `/skill`s (optional quality-of-life):
   `fleet-claim` (the whole worker lifecycle — claim via the assignee, load a
   layered charter, ground, implement, then open the PR + arm GitHub auto-merge;
   the fleet never merges — issue #283 folded the retired `fleet-ship` +
   `fleet-blocked` into it), `fleet-cleanup` (manual reap of a merged/closed
   PR, the escape hatch past the cleanup daemon — see docs/CLEANUP.md),
   `fleet-sync-install`, `fleet-status`,
   `fleet-new-issue`, and `fleet-handoff`
   (either seat: writes a handoff doc, then a detached helper auto-`/clear`s the
   pane and resumes from it — `bin/fleet-handoff-cycle.sh`) (plus the
   contract/template — `commands/README.md`,
   `commands/_template.md`). `fleet-doctor.sh` reports how many are installed
   (warn, not fail, if none — they're optional). See `commands/README.md` for
   the skill contract.

9. **Verify.** Inside tmux: start `claude` in a window, run any tool, and
   check `tmux show-options -w @claude_state` flips to `working`; check the
   spinner animates; `prefix+G` focuses the hub's dash pane; `prefix+b` opens the backlog
   (needs the collector to have run once — trigger it by hand:
   `bash ~/.claude/fleet/bin/tmux-dash-collect.sh`). Report each check.

## Uninstall

Remove the LaunchAgents (`launchctl bootout gui/$(id -u)/com.claude-fleet.*`,
delete the plists), delete the `source-file …tmux-attention.conf` line from
`~/.tmux.conf`, remove the five `set-claude-state.sh` hook entries (and the two
`summarize-hook.sh` entries on `Stop`/`SessionStart`, plus the
`steward-readopt-hook.sh` entry on `SessionStart`) from
`~/.claude/settings.json`, delete `~/.claude/fleet/` and the steward charter
`~/.claude/steward.md`, remove any fleet commands
you copied into `~/.claude/commands/` (the ones with a `<!-- fleet skill … -->`
marker — leave your personal commands), and clear per-window state. Each fleet
runs on its own tmux socket now (issue #159), so per-window state lives per
server — the simplest reset is to `fleet-down <sess>` (or `tmux -L <sess>
kill-server`) each fleet; to clear it in place instead, run
`tmux -L <sess> set-window-option -g @claude_state ""` (and `@prci`/`@pfg`, set by
the pr-refresh daemon) once per live fleet socket. (The `com.claude-fleet.*` bootout
glob already covers `com.claude-fleet.pr-refresh`, `com.claude-fleet.issue-bridge`,
`com.claude-fleet.watch`, and `com.claude-fleet.cleanup`; on Linux
`systemctl --user disable --now claude-fleet-pr-refresh.timer` +
`claude-fleet-issue-bridge.timer` + `claude-fleet-watch.timer` +
`claude-fleet-cleanup.timer`.) Per-fleet durable
state (issue #181) lives one directory per fleet under
`~/.config/claude-fleet/fleets/<session>/` (conf, restore map, and — if you
enabled them — the issue-bridge `bridge/` watermark+dedup and the watcher `watch/`
edge-dedup keyset); delete `~/.config/claude-fleet/fleets/` to remove it all. (A
pre-migration estate may still have the old flat `issue-bridge/` + `watch/` dirs —
remove those too.)
