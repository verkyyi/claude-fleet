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
| Bypass-permissions guards (issue #355) | two `PreToolUse` hooks — the last line of defense once workers run `bypassPermissions` (CC never prompts). `hooks/bash-guard.py` (matcher `Bash`): a GENERIC deny-list (`rm -rf` on `/` `~` `.git`; force-push onto the base branch) with statement-segment splitting + git-subcommand matching for near-zero false positives, plus a never-shipped local overlay (`~/.claude/hooks/bash-guard-local.py`) for operator-specific rails. `hooks/base-readonly-guard.py` (matcher `Edit\|Write\|MultiEdit\|NotebookEdit`): makes the base checkout edit-read-only for **every** seat by denying writes inside `FLEET_MAIN` (worktree siblings stay writable) — the PreToolUse backstop the steward's `permissions.deny` rail always referenced; closes the gap for the worker seat. Both **fail OPEN** (a guard bug or a non-fleet session → allow) | python3 |
| Dashboard (`prefix+g`) | fzf mission control — an embedded pane in the `plan` hub (dash above, steward below); `prefix+g` focuses it and toggles it fullscreen (`dash-zoom.sh`, the mirror of F9's steward focus). No standalone dash window | fzf ≥ 0.45 (0.60+ best); its binds use `transform` |
| Backlog (`prefix+b`) | GitHub issues panel, Enter = spawn issue-bound session. Each row tags its `priority:pN` (from `labels_<slug>`, no extra gh call) and issues sort by priority within a milestone; `⌃y` cycles a row's priority label (none→p2→p1→p0, `bin/dash-issue-priority.sh`, no popup). `⌃n` files a one-line issue | gh (authed) |
| Config modal (`prefix+c`) | fzf popup to view/edit `FLEET_*` config across both layers (per-fleet overlay ▸ global ▸ default); ⌃s toggles the write scope, enter edits a key (typed validation, backup-first) | fzf ≥ 0.45 |
| Label taxonomy (`bin/fleet-labels-seed.sh`) | the fleet's **fixed** canonical label set (`bug`, `enhancement`, `cleanup`, `robustness`, `portability`, `ci`, `docs-truth`, `scout`, `priority:p0\|p1\|p2`, `steward-control`, `blocked`, `autoland` — issue #333). ONE source of truth, `fleet_labels_canonical`/`fleet_labels_allowed` in `bin/fleet-lib.sh`. The install seed step (`gh label create --force`, **idempotent**) installs it into a fresh repo; the issue-filer channel (`bin/fleet-issue-file.sh`) validates every requested label against `fleet_labels_allowed` — the FIXED set, not the live `gh label list` — so no filer (worker or steward) can file against an off-taxonomy label even if one is minted out of band (**fixed seed, no minting**). `autoland` is stale (daemon retired #277) but kept for now | gh (authed, label-admin) |
| Cross-machine pre-spawn dedup | every spawn (`bin/dash-issue-session.sh`, the one choke point) consults the shared GitHub issue as a claim ledger before spawning, so two fleets on **different machines / same repo** don't both spawn `issue-<N>` (duplicate worktrees + push race + competing PRs) — the local tmux dedup only sees one machine. **The assignee IS the claim** (issue #283): taken (assignee · non-open state · open PR) ⇒ **refuse**; free ⇒ **claim AT SPAWN** by assigning `@me` (not on the worker's first `/fleet-claim` turn — that gap was the race) so a peer sees the assignee within ~1s. **NOT a mutex** (GitHub has no CAS on an issue) — it shrinks the race window, doesn't eliminate it; the old sub-second REST-comment-id tie-break was retired with the `▶ claiming` marker (workers share one gh account, so no per-attempt tie token exists). `--force`/`--reclaim` spawns past a stale claim. **ON by default** — the cost is a few gh reads/spawn (claim-at-spawn just moves `/fleet-claim`'s assign earlier; a gh outage degrades to spawn-anyway) and it self-disables when gh is absent; a single-machine fleet wanting the zero-gh fast path sets `FLEET_PRESPAWN_DEDUP=0`. `/fleet-claim` stays but no-ops when it finds the pre-claim | gh (authed) |
| Collector daemon | git/gh/usage/issues caches every ~60s | gh, python3 |
| PR-status refresher (recommended) | `com.claude-fleet.pr-refresh` (~15s): owns PR/CI state (`prmap` + window `@prci`/`@pfg`) on a fast tick so CI-green/merged shows within ~15s instead of riding the 60s collector; single writer, no collector race (`FLEET_PR_REFRESH_INTERVAL`) | gh |
| Disk guard daemon (recommended) | disk circuit-breaker + runaway-writer forensics; stops a full disk from crashing a fleet's tmux server (each fleet has its OWN socket now — issue #159 — but a full volume still ENOSPCs every server on it). Its `--watch` tick also runs a **runaway-CPU watchdog** (issue #151): our-user, no-controlling-tty processes held ≥`FLEET_RUNAWAY_CPU_PCT`% for ≥`FLEET_RUNAWAY_CPU_SECS`s → forensic incident + notify, optionally SIGTERM/KILL (`FLEET_RUNAWAY_CPU_ACTION`). Protects each tmux server from a detached orphan spinning a core; the server + launchd/systemd are excluded, live worker panes have a tty so are never touched. OFF by default (`PCT=0`) | — |
| Issue-bridge (optional) | `com.claude-fleet.issue-bridge` (~15s poll, or a webhook via `--deliver`+HMAC): relays a trusted issue comment INTO the bound worker as its next turn — the issue thread becomes the steward↔worker↔collaborator channel (replaces flaky send-keys). Single shared instance. Loop-safe via the `<!-- fleet:no-relay -->` marker (`bin/fleet-comment.sh`); gated by `author_association` (relayed comment = RCE on a bypass-perms worker); idle-gated; deduped. Also routes a per-fleet **steward control issue** (`FLEET_STEWARD_ISSUE`, #146) — comments on it relay into the `@steward` hub pane (the operator↔steward wake/async channel), same gates/marker/idle/dedup. OFF by default (`FLEET_ISSUE_BRIDGE=1` per fleet); spends LLM tokens. See docs/ISSUE-BRIDGE.md | gh (+ python3 for `--deliver`) |
| Cleanup (recommended) | **THE FLEET NEVER MERGES** (issue #277, closes #260) — it arms auto-merge and cleans up after merges. The worker's `/fleet-claim` ship step opens the PR then `gh pr merge --auto --<FLEET_MERGE_METHOD>` (default `squash`, issue #283) **arms** GitHub auto-merge (never merges); GitHub (or a human on the web, or a collaborator) does the merge when green + branch-protection-satisfied. `com.claude-fleet.cleanup` (`bin/fleet-cleanup-daemon.sh`, ~60s) then scans the `prmap` cache pr-refresh already writes (`--state all` ⇒ MERGED/CLOSED rows, ZERO extra `gh`) for a final PR whose `issue-<N>` still has a live worktree/window and drives `bin/fleet-cleanup.sh <PR>` — the mechanical, **no-merge** janitor (`fleet-land.sh` MINUS the merge): record the resume ledger FIRST, `git pull --ff-only` the base under the shared land-lease (`bin/fleet-land-lease.sh`, base-ff serialization), then ordered teardown window → worktree → branch. Merge-source-agnostic, idempotent (`skip:nothing` on an already-reaped PR). Single-writer per repo + disk-gated. **ON by default** (opt out `FLEET_CLEANUP=0`; merges nothing, relaxes no gate). Manual now: `/fleet-cleanup <n>`. See docs/CLEANUP.md | gh |
| Ledger-watch (recommended) | `com.claude-fleet.ledger-watch` (`bin/fleet-ledger-watch.sh`, ~60s; issue #320): records EVERY closed worker session into the history ledger, not just landed ones. The cleanup daemon records a session only when it LANDS, so a worker window closed by hand / crashed / abandoned left its transcript UNINDEXED (invisible to `/fleet-history`, not resumable). It can't inspect a window after it's gone, so it **snapshot-diffs**: each tick it snapshots the live issue-bound worker windows (keyed by ISSUE — `/fleet-handoff` cycles the session-id in place, so keying on the issue avoids a spurious row per handoff; `@raw` scratch + panels excluded) and diffs vs the durable prior snapshot; a worker whose window VANISHED and isn't already in the ledger gets one `closed-unlanded` row (`bin/fleet-history.sh record-closed`, **idempotent** — dedups on session-id so a landed session is never double-recorded). Its worktree usually still exists (worktree-autoclean keeps unmerged), so resume just reuses it. Pure tmux snapshot + a local ledger append (no `gh`, no LLM), **records only** (never reaps), single-writer per repo + disk-gated. **ON by default** (opt out `FLEET_LEDGER_WATCH=0`); spends no tokens. `--dry-run` prints intent. A whole-fleet crash is handled by fleet-restore (`--if-down`), so this targets a single window vanishing while its fleet stays up. See docs/CLEANUP.md | — |
| Close-on-exit hook | `bin/session-end-hook.sh` wired to the Claude Code **`SessionEnd`** hook (issue #403): the **event-driven twin of ledger-watch**. On a MANUAL worker exit (Ctrl-D / `/exit` / logout) it reacts AT EXIT instead of waiting the ~60s poll — closes the tmux window, applies the SHARED reap gate (`fleet_reap_ok`) and acts on the worktree by verdict (merged-pr → reap wt+branch + close issue + `landed` row; ancestor → reap wt+branch + `closed-unlanded` row, issue kept open; committed-but-unmerged / dirty → KEEP the worktree + issue + `closed-unlanded` row), and records the `/fleet-history` row NOW via the shared `fleet_reap_record` so the session is indexed + resumable at once. SessionEnd runs INSIDE the dying pane, so the gate+reap+close run in a DETACHED `tmux run-shell -b` job (server-side) that survives the pane vanishing (mirrors `dash-reap.sh`'s `--exec`). `/clear` + every `/fleet-handoff` cycle (`reason=clear`/`resume`) is a NO-OP — only `prompt_input_exit`/`logout` act (the `matcher` pre-filters). Scoped to issue-bound workers (+ `@raw` scratch → window-close only); panels + the steward hub are never touched. Reacts, never blocks; idempotent vs the cleanup daemon / ledger-watch (one row, one close). **ON by default, globally** — the `SessionEnd` wiring below is merged at install, so it works out of the box; set `FLEET_CLOSE_ON_EXIT=0` in the **global** `fleet.conf` to disable machine-wide (global-authoritative — a per-fleet value is ignored). Spends no tokens. See docs/CLEANUP.md | — |
| Base-sync (recommended) | `com.claude-fleet.base-sync` (`bin/fleet-base-sync.sh`, ~60s; issue #327): keeps the LOCAL base checkout (`$FLEET_MAIN`) fast-forwarded to the remote default branch, **independent of merges**. Today the base only advances as a side-effect of the cleanup daemon reaping a merged PR (`bin/fleet-cleanup.sh` does the `git pull --ff-only`), so a merge with **no local reap** — a PR merged on the web, a commit from another machine/contributor, a **direct push** to the default branch — never triggers a base pull and the local base **silently lags** the remote until the next merge that does have a worktree; fresh worktrees + `cw` then branch off a **stale** base. This daemon runs the EXACT same ff-only pull the cleaner does, just on the clock: each tick, one base-mover **per repo** (deduped on the resolved base path, not per fleet) takes the **shared land lease** (`bin/fleet-land-lease.sh`, `land-<slug>.lock` — the SAME lock every base-mover holds, so **no new race** with the cleaner) **non-blocking** (busy ⇒ another base-mover has it ⇒ skip) and runs `git fetch` + `git pull --ff-only` on `$FLEET_MAIN`. `--ff-only` is the whole safety story: a diverged base (a stray local commit) makes the pull refuse — surfaced once (*"base checkout would not fast-forward — resolve by hand"*), never merged/rebased/forced. **Base only** — never touches worktrees/windows/branches/issues/PRs; needs no tmux (just `git` + the lease). An already-current base is a cheap no-op, so a quiet repo costs one `fetch`/tick, no `gh`, no LLM. Single-writer per repo + disk-gated. **ON by default** (opt out `FLEET_BASE_SYNC=0`); spends no tokens. `--dry-run` prints `would ff $MAIN <old>..<new>` without moving. See docs/CLEANUP.md | — |
| Watcher (optional) | `com.claude-fleet.watch` (~45s): the **zero-token event-driven steward wake** (issue #147). Sleeps on the fleet reading ONLY existing state (`@claude_state`/`@issue` + the `labels_<slug>` cache — no LLM, no per-tick `gh`) and wakes the steward ONLY on a decision-worthy **attention edge**: a worker stuck (`looping`), the needs-attention count rising, or a `prod-alert` issue appearing. (Trimmed in #279 — the PR-green→`/land`, worker-opened-PR and free-slot edges were removed once landing retired in #277: nothing triggers a land, the dash shows an opened PR, and a free slot is surfaced by the dash/backlog directly.) Edge-triggered + deduped (transitions not levels; first run seeds silently). Delivery = the steward control issue (`FLEET_STEWARD_ISSUE`, #146) → the issue-bridge relays the wake into the `@steward` pane. Single-writer per repo + disk-gated; `--dry-run` prints edges without posting. OFF by default (`FLEET_WATCH=1` per fleet; needs `FLEET_STEWARD_ISSUE` + in practice `FLEET_ISSUE_BRIDGE=1`); the watcher spends no tokens but each wake makes the steward take a turn. See docs/WATCH.md | gh + issue-bridge |
| Webhook daemon (optional) | `com.claude-fleet.webhook` (`bin/fleet-webhook.sh`, KeepAlive supervisor like the spinner): **fresh (~1s) PR/issue/CI status via `gh webhook forward`, with NO public endpoint** (issue #315). GitHub's only real-time push is webhooks (normally need a public URL); `gh webhook forward` (the `cli/gh-webhook` extension) registers the repo webhook against **GitHub's own hosted relay**, PULLS deliveries over the authenticated `gh` token, and re-POSTs each to a **localhost** handler — no ngrok/tunnel, no exposed port. The daemon runs one python3 handler on `127.0.0.1:<port>` + one `gh webhook forward` per opted-in **live** fleet repo (fanned out like the watcher, deduped per repo, dead forwards auto-restarted). Each delivery only **TRIGGERS a targeted refresh** — it never writes a cache: `pull_request`/`check_*`/`status` → `tmux-pr-refresh.sh --repo <repo>` (the single writer of `prmap`/`@prci`), `issues` → `tmux-dash-collect.sh --issues <repo>` (the collector owns `issues_<slug>`), routed by the repo in the payload. **Polling stays the backstop** (pr-refresh ~15s + collector ~60s), so a missed delivery/dead forward only costs freshness, never correctness. Storm-coalesced (per-`(event,repo)` debounce). Optional HMAC (`FLEET_WEBHOOK_SECRET` → `--secret` + verify) is defense-in-depth only (handler binds localhost). OFF by default (`FLEET_WEBHOOK=1` per fleet); spends no LLM tokens. See docs/WEBHOOK.md | gh + python3 + `gh extension install cli/gh-webhook` |
| Classifier (optional) | Stop-hook does real-time single-window state fix (detects `looping`), plus the spinner's stuck-`working` demote kicks it for a window a Stop missed. It only refines `done`/`needs`/`looping` (trusts the hook for `working`) — so a window stuck at `working` from a missed Stop is handled upstream by the spinner's demote check, which flips it to `done` and then kicks the classifier to refine it | `claude` CLI |
| Summarizer daemon + hooks (optional) | one-line LLM summary per session → dash summary column; refreshed on Stop/SessionStart hooks + a ~180s catch-all daemon | `claude` CLI |
| Worktree janitor (optional) | prunes merged+clean+idle worktrees. Before each removal it **reaps any process still anchored to the worktree** (`fleet_reap_worktree_procs` — argv match + cwd match, SIGTERM→SIGKILL; issue #151) so a detached orphan can't outlive its dir and drain a core against the shared tmux server. The dash's `⌃x` reap (`dash-reap.sh`) does the same | gh |
| Raw scratch session (dash `⌃s`) | opens a plain, **non-issue-bound** `claude` window in the fleet — no GitHub issue, but in its **own writable `scratch-N` git worktree** off the base branch (`bin/dash-raw-session.sh`, issues #214/#290). The counterpart to the issue-bound spawns (dash `⌃n` / backlog Enter / `dash-issue-session.sh`), for ad-hoc exploration or experiments that may need to WRITE code (the base checkout is hook-enforced read-only). A scratch that turns real just pushes its branch + opens a PR — the prmap is repo-wide, so the janitor reaps a merged `scratch-N` like any worker (zero new machinery), and the unique cwd makes its transcript resolvable. Marked `@raw=1` + `@worktree=<path>`, named `scratch-N` (or a custom name); **listed in the dash as a real session** (counts toward the session cap) but excluded from the issue machinery — no `@issue`, so the watcher (`@raw` skipped) leaves it alone, while the classifier/summarizer still show its state + summary. The **window** is ephemeral (not snapshotted/restored across a crash); its **worktree** survives on disk and is reaped by the janitor's scratch rules — clean + no unmerged work → removed silently; dirty or unmerged → kept + surfaced once (never silently delete an experiment; `dash ⌃x` disposes it) | claude |
| `cw`/`cwrm`/`cwclean` | zsh worktree helpers | zsh |
| Fleet commands (optional) | repo-shipped `/skill`s (`commands/`) — fleet-aware slash commands, appended to `~/.claude/commands/` | claude |
| Fleet skills (optional) | repo-shipped base **skills** (`skills/<name>/` dirs — SKILL.md plus any supporting files) a fleet command or the agent delegates to — e.g. `/fleet-handoff` runs the base `handoff` skill verbatim; `doc-preview` ships `share.sh`/`server.py`/`render.mjs` beside its SKILL.md (issues #311, #354); installed into `~/.claude/skills/` whole-dir, marker-gated (`<!-- fleet skill -->` in the SKILL.md) so a personal skill is never clobbered | claude |
| Status line (optional) | `conf/statusline.sh` — Claude Code status line: a context-window mini-bar (green < 50% < yellow < 80% < red), shortened cwd, git branch + dirty star (via `--no-optional-locks`), and model name. Wired **install-time only** by pointing `settings.json`'s `statusLine` at the **live-install** path `~/.claude/fleet/conf/statusline.sh`, so improvements flow through `land → /fleet-sync-install` with no copy step. jq-gated — exits silently (blank line) without `jq`. NOT auto-wired on sync; opt-in per install (see step 8b) | jq (soft) |

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
   and `hooks/settings-hooks.json` to match. (The steward's charter is **no longer
   a flat file to copy up** — since issue #286 it ships as the `/fleet-steward`
   skill installed in step 8, resolved at spawn by `bin/steward-charter.sh`. Any
   per-fleet local edits go in the operator overlay
   `~/.config/claude-fleet/fleets/<session>/steward.md`, not a flat
   `~/.claude/steward.md`.)

3. **Write `~/.claude/fleet/fleet.conf`.** Ask the user (or infer from their
   current repo) the values in `fleet.conf.example`: `FLEET_REPO`
   (owner/name of the backlog repo), `FLEET_MAIN` (its main checkout path),
   `FLEET_BASE_BRANCH`, and whether their plan runs 1M-context models
   (`FLEET_CTX_WINDOW`).

4. **Hook up tmux.** Run `sh ~/.claude/fleet/bin/reapply-tmux-attention.sh`
   (idempotently appends one `source-file` line to `~/.tmux.conf`). Warn the
   user about the opinionated bits of `conf/tmux-attention.conf` — a **fleet
   baseline** block (issue #222) + prefix bindings on `a/g/b/n/R/A/u/c/r/?` and a
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
   default new-window** and `prefix+?` (the keymap cheatsheet popup —
   `bin/fleet-keys.sh`) **rebinds tmux's default `list-keys`**; in a fleet you
   spawn via the dash/backlog and navigate by name, so both defaults are rarely
   needed — but call them out. The shortcut prune (#289) left `prefix+n` and
   `prefix+r` bound back to tmux's stock `next-window` / `refresh-client`, so they
   clobber nothing; the usage/account controls live on the footer clicks (the
   `◉` chip / usage stat → `bin/usage-modal.sh`), not the keyboard. There are also **root-table** binds (`bind -n …`)
   that intercept the key/mouse in every pane *before* the app, so flag each: `F9`
   jumps back to this session's steward hub (`steward-zoom.sh`) — safe because the
   Claude TUI/shells don't use function keys; `MouseDown1Status` owns the clickable
   footer ranges (hub/fleet/needs/account/usage); and **double-click-to-zoom**
   (`DoubleClick1Pane` → `resize-pane -Z -t=`, `DoubleClick1Border` on the divider)
   toggles a pane's fullscreen as the mouse counterpart to `prefix+g`/`F9` — its
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
   hook re-injects the **layered steward charter** (plus a newest-handoff pointer)
   back into context via the shared `bin/steward-charter.sh` resolver — the SAME
   path `/fleet-steward` uses at spawn (issue #286), so a `/clear` re-adopt can't
   drift — but ONLY when the pane is `@steward=1` **and** the SessionStart `source`
   is `clear` — so a worker `/clear` is never handed steward identity, and
   startup/resume/compact (already covered by the spawn seed prompt and the
   crash-resume path #143) don't pile on redundant context. No-op outside tmux and
   if the resolver emits nothing (e.g. the `/fleet-steward` skill isn't installed).
   The `SessionStart` array also fires `handoff-latch-reset-hook.sh` (issue #330):
   it clears the `@handoff_armed` auto-handoff debounce latch at every session
   boundary. That latch is set by the `Stop` hook's **auto-handoff nudge**: when
   `FLEET_AUTO_HANDOFF_PCT>0` (OFF by default) and a worker/scratch session's
   context crosses that %, `set-claude-state.sh done` emits a Stop-hook `block`
   decision steering the model to run `/fleet-handoff` (store → `/clear` → resume)
   — reusing the whole existing handoff cycle, only the trigger is new. The `%` is
   measured by `conf/statusline.sh`, which stamps it onto `@ctx_pct` each render
   (so this needs the status line wired, step 8b). The nudge fires once per session
   (latch), only from a clean `done` (never a needs-attention turn), and never on
   panels or the steward hub.

   The `SessionEnd` array fires `session-end-hook.sh` (issue #403) — the
   event-driven twin of the ledger-watch daemon. Its `matcher`
   (`prompt_input_exit|logout`) fires it only on a **real** worker exit. It is
   **ON by default** — merging this block wires it, so close-on-exit works out of
   the box with no per-fleet conf line; disable it machine-wide by setting
   `FLEET_CLOSE_ON_EXIT=0` in the **global** `fleet.conf` (global-authoritative —
   a per-fleet value is ignored). A manual exit closes the window, gate-reaps the
   worktree by verdict, and records the `/fleet-history` row at once (see
   docs/CLEANUP.md) — reacting AT EXIT instead of waiting the ledger-watch/cleanup
   ~60s poll. It reacts, never blocks (SessionEnd can't veto an exit).

   The `PreToolUse` array also registers the two **bypass-permissions guard
   hooks** (issue #355) — the fleet's last line of defense now that workers run
   on `bypassPermissions` (Claude Code never prompts). Both ship GENERIC rails
   and **fail OPEN** (any internal error → exit 0), so a guard bug can never
   brick a session:
   - `hooks/bash-guard.py` (matcher `Bash`) — a deny-list for the handful of
     irreversible commands (`rm -rf` on `/` `~` `.git`; a force-push onto the
     base branch). It splits a command into statement segments before matching
     so tokens can't combine across segments, and matches the git *subcommand*,
     not the word anywhere — keeping false positives near zero. Operator-specific
     rails (prod hosts, DB/k8s guards) go in a **local overlay**,
     `~/.claude/hooks/bash-guard-local.py`, that the skeleton runs if present and
     that is NEVER shipped (see the OVERLAY section in the hook).
   - `hooks/base-readonly-guard.py` (matcher `Edit|Write|MultiEdit|NotebookEdit`)
     — makes the base checkout **edit-read-only for every seat**: it denies a
     write whose target is inside `FLEET_MAIN`, while the `issue-<N>` / `scratch-N`
     worktree siblings (which sit *next to* the base, not under it) stay writable.
     This is the PreToolUse backstop the steward's `permissions.deny` rail
     (`conf/steward-settings.template.json`) always referenced but that the repo
     never actually shipped — closing the gap for the **worker** seat, which had
     no base-checkout protection at all. A no-op outside a fleet (no `FLEET_MAIN`
     resolvable → allow), so it's safe to add globally.

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
     webhook (`com.claude-fleet.webhook`, KeepAlive) is the **fresh (~1s)
     PR/issue/CI status daemon** — install it only if a fleet sets
     `FLEET_WEBHOOK=1`, and first run `gh extension install cli/gh-webhook` (it
     registers the repo webhook against GitHub's hosted relay — **no public
     endpoint**). It runs a localhost python3 handler + one `gh webhook forward`
     per opted-in live fleet repo; each delivery only kicks a targeted
     `tmux-pr-refresh.sh --repo`/`tmux-dash-collect.sh --issues` (it never writes a
     cache), and polling stays the backstop, so a miss costs only freshness. It
     spends no LLM tokens (but keeps a forward process per repo). Optional
     `FLEET_WEBHOOK_SECRET` adds HMAC verification (defense-in-depth; the handler
     already binds localhost). Full design in **docs/WEBHOOK.md**.
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
     ledger-watch (`com.claude-fleet.ledger-watch`, 60s) is the **history
     ledger-watch daemon** (issue #320) — **recommended** for every fleet. The
     cleanup daemon records a session into the history ledger only when it LANDS;
     this one records EVERY closed worker session — a window you close by hand, a
     crash, an abandoned/blocked one that never merged. It can't inspect a window
     after it's gone, so it snapshot-diffs the live worker windows each tick and
     writes a `closed-unlanded` ledger row when one vanishes without landing, so
     its transcript stays browsable + resumable via `/fleet-history` (the worktree
     usually still exists — worktree-autoclean keeps unmerged, so resume just
     reuses it). Pure tmux snapshot + a local ledger append — no `gh`, no LLM,
     **records only** (never reaps a worktree) — so it is **ON by default** per
     fleet (opt out with `FLEET_LEDGER_WATCH=0`); it spends no tokens. Single-writer
     per repo + disk-gated; `--dry-run` prints intent without recording. A
     whole-fleet crash is handled by fleet-restore (`--if-down` resumes the
     windows), so this daemon targets a single window vanishing while its fleet
     stays up.
     base-sync (`com.claude-fleet.base-sync`, 60s) is the **base-sync daemon**
     (issue #327) — **recommended** for every fleet. It keeps the local base
     checkout (`$FLEET_MAIN`) fast-forwarded to the remote default branch even
     when no merge is reaped locally: a PR merged on the web, a commit from
     another machine/contributor, or a direct push advances the remote, but the
     cleanup daemon only pulls the base as a side-effect of reaping a merged PR
     that still has a local worktree — so without this ticker the base silently
     lags and fresh worktrees branch off stale code. Each tick, one base-mover
     per repo (deduped on the resolved base path) takes the **shared land lease**
     (the same `land-<slug>.lock` the cleaner uses — non-blocking, so a busy
     lease just means another base-mover is already advancing it → skip) and runs
     `git fetch` + `git pull --ff-only` on `$FLEET_MAIN`. `--ff-only` is the whole
     safety story — a diverged base refuses and is surfaced once, never
     merged/rebased/forced. Base only (no worktrees/windows/branches/issues/PRs,
     no tmux — just `git` + the lease); an already-current base is a cheap no-op,
     so a quiet repo costs one `fetch`/tick, no `gh`, no LLM. Single-writer per
     repo + disk-gated, so it is **ON by default** per fleet (opt out with
     `FLEET_BASE_SYNC=0`); it spends no tokens. `--dry-run` prints
     `would ff $MAIN <old>..<new>` without moving.
   - Linux: use the ready-made units in `systemd/` (parity with the plists,
     `__HOME__`-templated). Substitute `__HOME__` and copy into
     `~/.config/systemd/user/`, then `systemctl --user daemon-reload` and
     `systemctl --user enable --now claude-fleet-spinner.service` +
     `claude-fleet-collect.timer` (the required two) + the recommended
     `claude-fleet-diskguard.timer` (crash-guard) and
     `claude-fleet-pr-refresh.timer` (fast ~15s PR/CI status) + the recommended
     `claude-fleet-cleanup.timer` and `claude-fleet-ledger-watch.timer` (index
     every closed session for resume) and `claude-fleet-base-sync.timer`
     (keep the local base fast-forwarded to the remote, merge-independent); the
     optional
     issue-bridge/watch/summarize/worktree-autoclean are `.timer`s too, and the
     optional **webhook** daemon is an always-on `.service`
     (`claude-fleet-webhook.service`, parity with the KeepAlive plist — needs
     `FLEET_WEBHOOK=1` + `gh extension install cli/gh-webhook`).
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
   `fleet-blocked` into it), `fleet-steward` (the steward mirror — the hub's
   spawn ritual: adopt a layered steward charter via `bin/steward-charter.sh`,
   then dispatch; issue #286 folded the retired `fleet-new-issue`, `fleet-status`,
   and `fleet-cleanup` into its charter as hot-path ops),
   `fleet-sync-install`, and `fleet-handoff`
   (either seat: writes a handoff doc, then a detached helper auto-`/clear`s the
   pane and resumes from it — `bin/fleet-handoff-cycle.sh`) (plus the
   contract/template — `commands/README.md`,
   `commands/_template.md`). `fleet-doctor.sh` reports how many are installed
   (warn, not fail, if none — they're optional). See `commands/README.md` for
   the skill contract.

   **Also copy the base skills tree** (issues #311, #354): copy each **skill
   directory** `skills/<name>/` → `~/.claude/skills/<name>/` (`mkdir -p` the dir,
   copy every file preserving executable bits — `cp -p`; **APPEND** — never
   clobber a personal `~/.claude/skills/*`). A skill is the whole dir, not just
   its `SKILL.md`: `skills/handoff/` is SKILL.md-only, but `skills/doc-preview/`
   ships `share.sh` + `server.py` + `render.mjs` beside its SKILL.md — and that
   SKILL.md invokes them at `~/.claude/skills/doc-preview/…`, so the scripts must
   land alongside it or the skill is a broken stub. These are repo-versioned base
   skills a fleet command or the agent delegates to — `skills/handoff/` is the
   base that `/fleet-handoff` runs verbatim, so **install it whenever you install
   `fleet-handoff`** or the command points at a missing dependency
   (`fleet-doctor.sh` warns on exactly that combination). Each ships a
   `<!-- fleet skill -->` marker **in its `SKILL.md`**; a fleet's own
   `~/.claude/skills/<name>/SKILL.md` that predates this adoption is a personal
   file — if it differs from the repo copy, leave it and reconcile by hand (adopt
   the marked repo version) rather than overwriting operator edits. After the
   initial copy these flow through `land → /fleet-sync-install` like `commands/*`
   (its skills pass, same marker gate + never-clobber rule).

8b. **Status line (optional, opt-in).** Offer to wire the Claude Code status
   line (`conf/statusline.sh` — context-window mini-bar, cwd, git branch, model).
   Set `~/.claude/settings.json`'s `statusLine` to point at the **live-install**
   path (never the repo copy) so a future `land → /fleet-sync-install` flows
   improvements through with no re-copy:

   ```json
   { "statusLine": { "type": "command", "command": "~/.claude/fleet/conf/statusline.sh" } }
   ```

   Rails:
   - **Never clobber an existing `statusLine`.** If `settings.json` already has a
     `statusLine` whose `command` differs, **skip and tell the user** what is set
     — do not overwrite their status line. Only write it when the key is absent
     (or already equals the fleet path). Back up `settings.json` first.
   - **jq is a soft dep** here: `conf/statusline.sh` exits silently (blank status
     line) without `jq`, so offer `brew install jq` if it's missing — but it is
     never required to install the fleet. `fleet-doctor` soft-warns when a
     `statusLine` is wired but `jq` is absent.
   - **Not wired on sync.** `/fleet-sync-install` only re-merges the *hooks*
     delta into `settings.json`; it never touches `statusLine`. Wiring is
     strictly this install-time opt-in — so an operator who doesn't want it never
     gets it, and one who does keeps it across syncs because the command points at
     the live-install path the fast-forward updates in place.
   - **Migration (this machine).** If `settings.json` currently points at a
     pre-fleet path (e.g. `~/.claude/statusline.sh`), switching it to
     `~/.claude/fleet/conf/statusline.sh` is the operator's one-line step — the
     same script, now landed in the repo so it improves through `land → sync`.

9. **Seed the label taxonomy.** Run
   `bash ~/.claude/fleet/bin/fleet-labels-seed.sh` (resolves `FLEET_REPO` from
   step 3's `fleet.conf`; pass `--repo owner/name` to override). It
   `gh label create --force`s the fleet's **canonical label set** —
   `bug`, `enhancement`, `cleanup`, `robustness`, `portability`, `ci`,
   `docs-truth`, `scout`, `priority:p0|p1|p2`, `steward-control`, `blocked`,
   `autoland` — the same fixed taxonomy `fleet_labels_allowed` (in
   `bin/fleet-lib.sh`) the issue-filer channel validates against. Nothing else
   seeds labels: `gh label` starts empty on a fresh repo, and the filer
   (`bin/fleet-issue-file.sh`) **rejects any off-taxonomy label** (fixed seed, no
   minting), so without this step a fresh-repo fleet could file no labelled issue
   at all. Needs `gh` authed with label-admin on the repo. **Idempotent** —
   `--force` creates-or-updates, so re-run it any time to reconcile; it never
   prunes labels the repo already carries (GitHub's defaults stay). (`autoland`
   is a known-stale label — its daemon retired in #277 — but is kept in the set
   for now; retiring it is a separate follow-up.)

10. **Verify.** Inside tmux: start `claude` in a window, run any tool, and
   check `tmux show-options -w @claude_state` flips to `working`; check the
   spinner animates; `prefix+g` focuses the hub's dash pane; `prefix+b` opens the backlog
   (needs the collector to have run once — trigger it by hand:
   `bash ~/.claude/fleet/bin/tmux-dash-collect.sh`). Report each check.

## Uninstall

Remove the LaunchAgents (`launchctl bootout gui/$(id -u)/com.claude-fleet.*`,
delete the plists), delete the `source-file …tmux-attention.conf` line from
`~/.tmux.conf`, remove the five `set-claude-state.sh` hook entries (and the two
`summarize-hook.sh` entries on `Stop`/`SessionStart`, the
`steward-readopt-hook.sh` and `handoff-latch-reset-hook.sh` entries on
`SessionStart`) from `~/.claude/settings.json`, remove the `statusLine` block from
`~/.claude/settings.json` **only if** it points at `conf/statusline.sh` (leave a
personal one), delete `~/.claude/fleet/` (and, on a pre-#286 install,
the obsolete flat charter `~/.claude/steward.md`), remove any fleet commands
you copied into `~/.claude/commands/` (the ones with a `<!-- fleet skill … -->`
marker — leave your personal commands) and any fleet skills you copied into
`~/.claude/skills/` (each `<name>/` dir whose `SKILL.md` carries the
`<!-- fleet skill -->` marker — e.g. `handoff`, `doc-preview` — removing the
whole dir so supporting scripts go with it; leave your personal skills), and
clear per-window state. Each fleet
runs on its own tmux socket now (issue #159), so per-window state lives per
server — the simplest reset is to `fleet-down <sess>` (or `tmux -L <sess>
kill-server`) each fleet; to clear it in place instead, run
`tmux -L <sess> set-window-option -g @claude_state ""` (and `@prci`/`@pfg`, set by
the pr-refresh daemon) once per live fleet socket. (The `com.claude-fleet.*` bootout
glob already covers `com.claude-fleet.pr-refresh`, `com.claude-fleet.issue-bridge`,
`com.claude-fleet.watch`, `com.claude-fleet.cleanup`, `com.claude-fleet.ledger-watch`,
`com.claude-fleet.base-sync`, and `com.claude-fleet.webhook`; on Linux
`systemctl --user disable --now claude-fleet-pr-refresh.timer` +
`claude-fleet-issue-bridge.timer` + `claude-fleet-watch.timer` +
`claude-fleet-cleanup.timer` + `claude-fleet-ledger-watch.timer` +
`claude-fleet-base-sync.timer` + `claude-fleet-webhook.service`.) If you ran the
webhook daemon, `gh extension remove cli/gh-webhook` is optional and each opted-in
repo may still list a `gh-webhook`-created relay webhook under its GitHub
Settings → Webhooks — remove those by hand, and delete the daemon's forward-pidfile
state at `~/.config/claude-fleet/webhook/`. Per-fleet durable
state (issue #181) lives one directory per fleet under
`~/.config/claude-fleet/fleets/<session>/` (conf, restore map, the ledger-watch
`ledgerwatch.snap` window snapshot, and — if you enabled them — the issue-bridge
`bridge/` watermark+dedup and the watcher `watch/` edge-dedup keyset); delete
`~/.config/claude-fleet/fleets/` to remove it all. (A
pre-migration estate may still have the old flat `issue-bridge/` + `watch/` dirs —
remove those too.)
