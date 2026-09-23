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
| Bypass-permissions guards (issue #355) | `PreToolUse` hooks — the last line of defense once workers run `bypassPermissions` (CC never prompts). `hooks/bash-guard.py` (matcher `Bash`): a GENERIC deny-list (`rm -rf` on `/` `~` `.git`; force-push onto the base branch) with statement-segment splitting + git-subcommand matching for near-zero false positives, plus a never-shipped local overlay (`~/.claude/hooks/bash-guard-local.py`) for operator-specific rails. `hooks/base-readonly-guard.py` (matcher `Edit\|Write\|MultiEdit\|NotebookEdit`): makes the base checkout edit-read-only for **every** seat by denying writes inside `FLEET_MAIN` (worktree siblings stay writable) — closes the gap for the worker seat, which had no base-checkout protection at all. `hooks/artifact-guard.py` (matcher `Artifact`, #526): a fleet session never *publishes* an Artifact (account-scoped; use doc-preview). `hooks/agent-guard.py` (matcher `Agent`, #811): in a fleet pane only the read-only `Explore` / `Plan` / `claude-code-guide` subagents may start — code-writing work is a fleet WORKER (`dash-issue-session.sh` / `fleet-issue-file.sh --spawn`), since a subagent gets none of the fleet's rails; `FLEET_ALLOW_SUBAGENT=1` overrides. All **fail OPEN** (a guard bug or a non-fleet session → allow) | python3 |
| Dashboard (`prefix+g`) | fzf mission control — an embedded pane in the `plan` hub, which holds the dash and nothing else (no hub Claude session — that pane is retired because it rebuilt itself on every ⌂ tap / F9 / fresh fleet / crash recovery); `prefix+g` focuses it and toggles it fullscreen (`dash-zoom.sh`), as does F9. No standalone dash window | fzf ≥ 0.45 (0.60+ best); its binds use `transform` |
| Backlog (`prefix+b`) | GitHub issues panel, Enter = spawn issue-bound session. Each row tags its `priority:pN` (from `labels_<slug>`, no extra gh call) and issues sort by priority within a milestone; `⌃y` cycles a row's priority label (none→p2→p1→p0, `bin/dash-issue-priority.sh`, no popup). `⌃n` files a one-line issue | gh (authed) |
| Config modal (`prefix+c`) | fzf popup to view/edit `FLEET_*` config across both layers (per-fleet overlay ▸ global ▸ default); ⌃s toggles the write scope, enter edits a key (typed validation, backup-first) | fzf ≥ 0.45 |
| Label taxonomy (`bin/fleet-labels-seed.sh`) | the fleet's **fixed** canonical label set (`bug`, `enhancement`, `cleanup`, `robustness`, `portability`, `ci`, `docs-truth`, `scout`, `priority:p0\|p1\|p2`, `blocked`, `autoland`, `autofill`, `epic` — issues #333, #421, #678). ONE source of truth, `fleet_labels_canonical`/`fleet_labels_allowed` in `bin/fleet-lib.sh`. The install seed step (`gh label create --force`, **idempotent**) installs it into a fresh repo; the issue-filer channel (`bin/fleet-issue-file.sh`) validates every requested label against `fleet_labels_allowed` — the FIXED set, not the live `gh label list` — so no filer can file against an off-taxonomy label even if one is minted out of band (**fixed seed, no minting**). A fleet can also opt into a **default milestone** so nothing lands unsorted: set `FLEET_DEFAULT_MILESTONE` (e.g. `Triage`) and every filing that passes no `--milestone` auto-lands there for you to re-bucket — the milestone is **auto-created if absent** (idempotent) and it's best-effort, so a milestone hiccup never blocks a filing (issue #433). `autoland` is stale (daemon retired #277) but kept for now; `autofill` opts an issue into hands-off auto-spawn by the dispatcher (issue #421); `epic` marks the tracking parent of a batch planned and run together (issue #678). **The descriptions are written for strangers** — this set is seeded into TEAM repos too, where these labels show up in the picker of people who have never heard of claude-fleet, so each one names what it means and who acts on it. Check a repo before planning a batch with `bash bin/fleet-epic-preflight.sh` (next row) rather than seeding blind | gh (authed, label-admin) |
| Cross-machine pre-spawn dedup | every spawn (`bin/dash-issue-session.sh`, the one choke point) consults the shared GitHub issue as a claim ledger before spawning, so two fleets on **different machines / same repo** don't both spawn `issue-<N>` (duplicate worktrees + push race + competing PRs) — the local tmux dedup only sees one machine. **The assignee IS the claim** (issue #283): taken (assignee · non-open state · open PR) ⇒ **refuse**; free ⇒ **claim AT SPAWN** by assigning `@me` (not on the worker's first `/fleet-claim` turn — that gap was the race) so a peer sees the assignee within ~1s. **NOT a mutex** (GitHub has no CAS on an issue) — it shrinks the race window, doesn't eliminate it; the old sub-second REST-comment-id tie-break was retired with the `▶ claiming` marker (workers share one gh account, so no per-attempt tie token exists). `--force`/`--reclaim` spawns past a stale claim. **ON by default** — the cost is a few gh reads/spawn (claim-at-spawn just moves `/fleet-claim`'s assign earlier; a gh outage degrades to spawn-anyway) and it self-disables when gh is absent; a single-machine fleet wanting the zero-gh fast path sets `FLEET_PRESPAWN_DEDUP=0`. `/fleet-claim` stays but no-ops when it finds the pre-claim | gh (authed) |
| EPIC preflight (`bin/fleet-epic-preflight.sh`) | **can this repo run a batch?** (issue #678) — the check `/fleet-epic plan` opens with, in `fleet-doctor.sh`'s `TAG STATE detail` shape: `gh` authed · `viewerPermission` ≥ WRITE · the **sub-issues API** answers for this repo · the `epic` / `autofill` / `blocked` labels exist · `FLEET_BASE_BRANCH` is the repo's real trunk (#603) · what *done* means here (`FLEET_DEPLOY_REF` / `FLEET_DEPLOY_CHECK`, #541, neither ⇒ merged ≡ done) · the effective concurrent-session cap, stated only — it is the operator's setting, never warned about or advised on (#881) · how many pool accounts sit under `FLEET_ACCOUNT_CEILING`. Three-way verdict so the caller can branch: **0 READY · 1 FIXABLE · 3 BLOCKED** (2 = usage). It exists to put "this repo can't do that" in front of the operator during planning, while they are awake — not at 03:00 when the batch is half-spawned. **Read-only by default**: `--fix` is the only writing path and it writes exactly one thing, `fleet-labels-seed.sh` against this repo — opt-in because seeding is not surgical (it reconciles the WHOLE canonical set, and a team repo sprouting a dozen unexplained labels overnight is how you lose the room). `--session <fleet>` preflights ANOTHER fleet — repo **and** conf knobs together, so the screen never describes two fleets at once; a bare `--repo` that disagrees with the loaded conf says so on its own line. `bin/fleet-epic-preflight-selftest.sh` pins all three verdicts on a faked `gh` | gh (authed) |
| Collector daemon | git/gh/usage/issues caches every ~60s. Since issue #551: **one tick at a time** (`global/collect.pid`; a previous tick older than `FLEET_COLLECT_DEADLINE`, 600s, is killed + superseded — a tick wedged on an un-timeboxed `gh` used to block every later phase for hours) and a **per-phase heartbeat** (`global/collect.heartbeat`: phase, per-phase seconds, end/dur — `fleet-doctor.sh` prints the last tick's age, duration and slowest phase). It runs the quota watch (next row) first thing, before any gh work. Since issue #636 its heartbeat is also an **alarm + self-heal**: launchd can PEND this unit indefinitely (103 min observed on 2026-09-14 — `state = not running`, `pended nondemand spawn = interval`, `last exit code = 0`), which does not empty the dash, it FREEZES it. A stale heartbeat shows `⚠ dash stale 47m` on the status bar and self-heals; since issue #639 that threshold is **relative to this unit's own 60s interval** (`FLEET_DAEMON_STALE_MULT` × 60 = 300s, `FLEET_COLLECT_STALE` overrides absolutely) because the absolute 600s default read `fresh` through a collector that was running once per 7–14 min. The kick itself moved to the next row | gh, python3 |
| Interval-daemon watch + self-heal (issue #639) | **Every** `StartInterval` unit, not just the collector: launchd was observed to stop scheduling the whole user domain at once (all seven logs freezing inside the same two minutes; over 27.8 min `collect` got 3 runs of ~28 due and `cleanup`/`dispatch`/`base-sync`/`issue-bridge`/`ledger-watch`/`quotawatch` got **zero**, while the two KeepAlive units never missed a frame). Nothing errors, so nothing shows: workers stop being reaped, autofill stops, the base stops fast-forwarding, `fleet-comment.sh --to-worker` silently reaches nobody. Each daemon now stamps `global/<unit>.tick` at the top of its script, `bin/fleet-daemon-watch.sh` judges it against **`FLEET_DAEMON_STALE_MULT` × that unit's own `StartInterval`** (floored at `FLEET_DAEMON_STALE_FLOOR`), and `⚠ daemon stale cleanup,dispatch+2` goes on the status bar + a per-unit `WARN daemons` in `fleet-doctor.sh`. Self-heal runs from the **KeepAlive spinner** — an interval unit is pended right alongside its patient — one `kickstart -k` per unit per cooldown (which SCALES with that unit's own interval since #711 — a flat 600s made the 15s units ten-minute daemons whenever kicking was the only execution path left), never against a unit whose tick is `running` (that would abort working work), escalating to a real `bootout`+`bootstrap` after `FLEET_DAEMON_RELOAD_AFTER` ineffective kicks, because **a kickstart buys one execution, not restored scheduling**. A unit found not loaded at all but with its plist on disk is bootstrapped back. History in `logs/daemon-kick.log`; `bin/fleet-daemon-watch.sh --status` prints the whole table | launchctl / systemctl |
| launchd **domain** probe (issue #711) | The rung above the per-unit ladder. On 2026-09-15 the whole `gui/501` domain stopped spawning jobs on one machine: nine of nine interval units frozen, and a throwaway agent bootstrapped beside them (different label, `ProcessType=Standard`, a one-line `/bin/sh`) never ran once — not even its `RunAtLoad`. The same install at the same commit ticked normally on the other host, so the fault is the MACHINE, and the remedy is a log out or a reboot. What the fleet owes the operator there is not nine "nothing is scheduling com.claude-fleet.`<x>`" lines — nine true statements that add up to "your daemons are broken" and send them to read plists. `bin/fleet-launchd-probe.sh` settles it in ~40s by counting how often launchd runs that throwaway agent (`ok` ≥2 · `no-interval` =1 · `no-spawn` =0 · `unknown` = not measured, never a verdict), and `fleet-doctor.sh` collapses the N unit lines into ONE that names the machine. It probes only on the domain signature — several units stalled at once, **or** several kicked inside the last hour, which is the signal that survives a working self-heal (measured on the wedged host: 1 overdue, 9 kicked in two minutes). The probe's deadline lives inside the job, not the parent's trap (#697): what leaks here is a registered LaunchAgent. Verdict cached for `FLEET_LAUNCHD_PROBE_TTL`; `--cached` reads it without re-probing | launchctl |
| Quota-watch daemon (recommended with a ccquota hub) | `com.claude-fleet.quotawatch` (`bin/fleet-quotawatch.sh`, 60s; issue #551): the ccquota-driven **pre-emptive account rotation** (warn every session on an account at `FLEET_ACCOUNT_WARN_PCT`, bench + `migrate --account` at `FLEET_ACCOUNT_CEILING` — issue #513) on its **own** tick, decoupled from the collector's gh/git/python phases. It used to be the LAST block of the collector tick, so a slow or wedged tick starved it: on 2026-09-11 the cache went 2.5h stale, neither branch fired, and 21 sessions rode a 5h window to 100%. Now: own 60s unit + a CONDITIONAL fallback at the TOP of the collector tick (issue #671) — the collector runs it only while this unit is not demonstrably ticking (`global/<root>/quotawatch.tick`, the #639 scheduling stamp, older than `FLEET_DAEMON_STALE_MULT × 60s` floored at 180s, or absent), so an install whose daemon set predates #551 still watches at the collector's cadence while a healthy one pays ~0 instead of the measured 3-57s a tick the unconditional call cost; it cannot flap because `--caller collect` is the one caller that does not write that stamp, and `FLEET_COLLECT_QUOTAWATCH=always|never` forces the old behaviour or switches the fallback off; `mkdir` lock against overlap; `global/quotawatch.heartbeat`; and a **staleness alarm** — `account.quota.ts` older than `FLEET_ACCOUNT_QUOTA_STALE` (600s) with a pool + hub configured shows `⚠ quota stale 47m` on the status bar, FAILs in `fleet-doctor.sh`, and the next tick that runs notifies once (`FLEET_NOTIFY_CMD`) how long the watch was blind — plus, since issue #684, its twin: a cache that is FRESH but EMPTY (the fetch restamps even when it brought nothing back, so zero rows read as healthy) raises `⚠ quota blind 6m` / a `qwatch` FAIL / one notify after `FLEET_ACCOUNT_QUOTA_BLIND_STREAK` (3) consecutive empty reads. `--status` / `--dry-run` for scripts and rehearsal. No-op without `FLEET_ACCOUNTS_DIR` tokens + `CCQUOTA_HUB_URL` — **and equally a no-op without the `ccquota` binary**, which nothing here ships and no package manager carries: get it in step 6 | ccquota (see step 6), python3 |
| PR-status refresher (recommended) | `com.claude-fleet.pr-refresh` (~15s): owns PR/CI state (`prmap` + window `@prci`/`@pfg`) on a fast tick so CI-green/merged shows within ~15s instead of riding the 60s collector; single writer, no collector race (`FLEET_PR_REFRESH_INTERVAL`). Also probes whether a MERGED PR is actually **live** (issue #541) for a fleet that sets `FLEET_DEPLOY_REF` (a local checkout that is the deployment — zero network) or `FLEET_DEPLOY_CHECK=actions` (post-merge runs); the dash PR cell then reads `live` / `deploy…` / `deploy✗` instead of `merged` | gh |
| Disk guard daemon (recommended) | disk circuit-breaker + runaway-writer forensics; stops a full disk from crashing a fleet's tmux server (each fleet has its OWN socket now — issue #159 — but a full volume still ENOSPCs every server on it). Its `--watch` tick also runs a **runaway-CPU watchdog** (issue #151): our-user, no-controlling-tty processes held ≥`FLEET_RUNAWAY_CPU_PCT`% for ≥`FLEET_RUNAWAY_CPU_SECS`s → forensic incident + notify, optionally SIGTERM/KILL (`FLEET_RUNAWAY_CPU_ACTION`). Protects each tmux server from a detached orphan spinning a core; the server + launchd/systemd are excluded, live worker panes have a tty so are never touched. OFF by default (`PCT=0`) | — |
| Autofill dispatcher (optional) | `com.claude-fleet.dispatch` (`bin/fleet-dispatch.sh`, ~60s; issues #70, #421): auto-spawns the highest-priority eligible backlog issue whenever both caps have headroom — automating the "file → hold for cap → spawn when a slot frees" loop. **Opt-in per issue**: only issues carrying the canonical `autofill` label are eligible (you tag exactly which issues may fill idle slots hands-off, like `autoland` for landing), so it never touches the whole backlog. Eligible = open, unassigned, `autofill`-labelled, no live `issue-<N>` window bound, not `blocked`. Priority = the `priority:pN` tier (p0 first), then FIFO by issue number. Single-writer per repo (lease) + disk-gated + rate-limited (`FLEET_AUTOFILL_MAX_PER_TICK`). OFF by default — a two-key gate: the fleet armed (`FLEET_AUTOFILL=1`) **and** the issue labelled; spends LLM tokens (one real Claude session + PR per spawn). `--dry-run` prints intended spawns without spawning | gh |
| Issue-bridge (optional) | `com.claude-fleet.issue-bridge` (~15s poll, or a webhook via `--deliver`+HMAC): relays a trusted issue comment INTO the bound worker as its next turn — the issue thread becomes the operator↔worker↔collaborator channel (replaces flaky send-keys). Single shared instance. Loop-safe via the `<!-- fleet:no-relay -->` marker (`bin/fleet-comment.sh`); gated by `author_association` (relayed comment = RCE on a bypass-perms worker); idle-gated; deduped. OFF by default (`FLEET_ISSUE_BRIDGE=1` per fleet); spends LLM tokens. See docs/ISSUE-BRIDGE.md | gh (+ python3 for `--deliver`) |
| Cleanup (recommended) | **CLEANUP NEVER MERGES — it cleans up after merges** (issue #277, closes #260), whoever made them. The worker's `/fleet-claim` ship+land step opens the PR, polls `bin/fleet-pr-verdict.sh <PR>` and squash-merges it itself on `READY` (`FLEET_MERGE_METHOD`, default `squash`; issues #283, #441) — branch protection still decides what's mergeable, and a `BLOCKED` verdict stops the worker. A human on the web or a collaborator merging instead changes nothing downstream. `com.claude-fleet.cleanup` (`bin/fleet-cleanup-daemon.sh`, ~60s) then scans the `prmap` cache pr-refresh already writes (`--state all` ⇒ MERGED/CLOSED rows, ZERO extra `gh`) for a final PR whose `issue-<N>` still has a live worktree/window and drives `bin/fleet-cleanup.sh <PR>` — the mechanical, **no-merge** janitor (`fleet-land.sh` MINUS the merge): record the resume ledger FIRST, `git pull --ff-only` the base under the shared land-lease (`bin/fleet-land-lease.sh`, base-ff serialization), then ordered teardown window → worktree → branch — where the worktree is **dropped**, not deleted: `fleet_worktree_drop` renames it into a sibling `.fleet-trash/` and prunes the registry (O(1)), and the daemon deletes the bytes at tick start under `FLEET_TRASH_SWEEP_BUDGET` seconds (default 20), before the disk gate (issue #586 — a 308k-file `node_modules` worktree once held one teardown, and every fleet's reaping behind it, for 67 minutes). Merge-source-agnostic, idempotent (`skip:nothing` on an already-reaped PR). Single-writer per repo + disk-gated. **ON by default** (opt out `FLEET_CLEANUP=0`; merges nothing, relaxes no gate). Manual now: `/fleet-cleanup <n>`. See docs/CLEANUP.md | gh |
| Ledger-watch (recommended) | `com.claude-fleet.ledger-watch` (`bin/fleet-ledger-watch.sh`, ~60s; issue #320): records EVERY closed worker session into the history ledger, not just landed ones. The cleanup daemon records a session only when it LANDS, so a worker window closed by hand / crashed / abandoned left its transcript UNINDEXED (invisible to `/fleet-history`, not resumable). It can't inspect a window after it's gone, so it **snapshot-diffs**: each tick it snapshots the live issue-bound worker windows (keyed by ISSUE — `/fleet-handoff` cycles the session-id in place, so keying on the issue avoids a spurious row per handoff; `@raw` scratch + panels excluded) and diffs vs the durable prior snapshot; a worker whose window VANISHED and isn't already in the ledger gets one `closed-unlanded` row (`bin/fleet-history.sh record-closed`, **idempotent** — dedups on session-id so a landed session is never double-recorded). Its worktree usually still exists (worktree-autoclean keeps unmerged), so resume just reuses it. Pure tmux snapshot + a local ledger append (no `gh`, no LLM), **records only** (never reaps), single-writer per repo + disk-gated. **ON by default** (opt out `FLEET_LEDGER_WATCH=0`); spends no tokens. `--dry-run` prints intent. A whole-fleet crash is handled by fleet-restore (`--if-down`), so this targets a single window vanishing while its fleet stays up. See docs/CLEANUP.md | — |
| Close-on-exit hook | `bin/session-end-hook.sh` wired to the Claude Code **`SessionEnd`** hook (issue #403): the **event-driven twin of ledger-watch**. On a MANUAL worker exit (Ctrl-D / `/exit` / logout) it reacts AT EXIT instead of waiting the ~60s poll — closes the tmux window, applies the SHARED reap gate (`fleet_reap_ok`) and acts on the worktree by verdict (merged-pr → reap wt+branch + close issue + `landed` row; ancestor → reap wt+branch + `closed-unlanded` row, issue kept open; committed-but-unmerged / dirty → KEEP the worktree + issue + `closed-unlanded` row), and records the `/fleet-history` row NOW via the shared `fleet_reap_record` so the session is indexed + resumable at once. SessionEnd runs INSIDE the dying pane, so the gate+reap+close run in a DETACHED `tmux run-shell -b` job (server-side) that survives the pane vanishing (mirrors `dash-reap.sh`'s `--exec`). `/clear` + every `/fleet-handoff` cycle (`reason=clear`/`resume`) is a NO-OP — only `prompt_input_exit`/`logout` act (the `matcher` pre-filters). Scoped to issue-bound workers (+ `@raw` scratch → window-close only); panels + the hub pane are never touched. Reacts, never blocks; idempotent vs the cleanup daemon / ledger-watch (one row, one close). **ON by default, globally** — the `SessionEnd` wiring below is merged at install, so it works out of the box; set `FLEET_CLOSE_ON_EXIT=0` in the **global** `fleet.conf` to disable machine-wide (global-authoritative — a per-fleet value is ignored). Spends no tokens. See docs/CLEANUP.md | — |
| Base-sync (recommended) | `com.claude-fleet.base-sync` (`bin/fleet-base-sync.sh`, ~60s; issue #327): keeps the LOCAL base checkout (`$FLEET_MAIN`) fast-forwarded to the remote default branch, **independent of merges**. Today the base only advances as a side-effect of the cleanup daemon reaping a merged PR (`bin/fleet-cleanup.sh` does the `git pull --ff-only`), so a merge with **no local reap** — a PR merged on the web, a commit from another machine/contributor, a **direct push** to the default branch — never triggers a base pull and the local base **silently lags** the remote until the next merge that does have a worktree; fresh worktrees + `cw` then branch off a **stale** base. This daemon runs the EXACT same ff-only pull the cleaner does, just on the clock: each tick, one base-mover **per repo** (deduped on the resolved base path, not per fleet) takes the **shared land lease** (`bin/fleet-land-lease.sh`, `land-<slug>.lock` — the SAME lock every base-mover holds, so **no new race** with the cleaner) **non-blocking** (busy ⇒ another base-mover has it ⇒ skip) and runs `git fetch` + `git pull --ff-only` on `$FLEET_MAIN`. `--ff-only` is the whole safety story: a diverged base (a stray local commit) makes the pull refuse — surfaced once (*"base checkout would not fast-forward — resolve by hand"*), never merged/rebased/forced. **Base only** — never touches worktrees/windows/branches/issues/PRs; needs no tmux (just `git` + the lease). An already-current base is a cheap no-op, so a quiet repo costs one `fetch`/tick, no `gh`, no LLM. Single-writer per repo + disk-gated. **ON by default** (opt out `FLEET_BASE_SYNC=0`); spends no tokens. `--dry-run` prints `would ff $MAIN <old>..<new>` without moving. See docs/CLEANUP.md | — |
| Webhook daemon (optional) | `com.claude-fleet.webhook` (`bin/fleet-webhook.sh`, KeepAlive supervisor like the spinner): **fresh (~1s) PR/issue/CI status via `gh webhook forward`, with NO public endpoint** (issue #315). GitHub's only real-time push is webhooks (normally need a public URL); `gh webhook forward` (the `cli/gh-webhook` extension) registers the repo webhook against **GitHub's own hosted relay**, PULLS deliveries over the authenticated `gh` token, and re-POSTs each to a **localhost** handler — no ngrok/tunnel, no exposed port. The daemon runs one python3 handler on `127.0.0.1:<port>` + one `gh webhook forward` per opted-in **live** fleet repo (fanned out like the watcher, deduped per repo, dead forwards auto-restarted). Each delivery only **TRIGGERS a targeted refresh** — it never writes a cache: `pull_request`/`check_*`/`status` → `tmux-pr-refresh.sh --repo <repo>` (the single writer of `prmap`/`@prci`), `issues` → `tmux-dash-collect.sh --issues <repo>` (the collector owns `issues_<slug>`), routed by the repo in the payload. **Polling stays the backstop** (pr-refresh ~15s + collector ~60s), so a missed delivery/dead forward only costs freshness, never correctness. Storm-coalesced (per-`(event,repo)` debounce). Optional HMAC (`FLEET_WEBHOOK_SECRET` → `--secret` + verify) is defense-in-depth only (handler binds localhost). OFF by default (`FLEET_WEBHOOK=1` per fleet); spends no LLM tokens. See docs/WEBHOOK.md | gh + python3 + `gh extension install cli/gh-webhook` |
| Lifecycle emitter (optional, issue #625) | `bin/fleet-emit.sh` — an **off-by-default** outbound channel that POSTs four session lifecycle facts to `FLEET_EMIT_URL` (bearer `FLEET_EMIT_TOKEN`; both per-fleet, so two fleets can report to different endpoints). It exists because the fleet is the ONLY component that knows what a session was **for** — it binds a session to an issue, gives it a worktree, and watches the PR — while a usage ledger downstream knows only what each session **cost**, keyed by session id. The join is one field. `session.start` (SessionStart hook — every source, so a `/fleet-handoff` cycle's new session id still maps to the issue), `session.bind` (`bin/fleet-bind.sh` — without it every scratch that turned into real work is attributed to nothing), `session.pr` (a **diff** of the prmap `bin/tmux-pr-refresh.sh` already rewrites — no second poller; a cold prmap seeds silently), `session.end` (twice over, discriminated by `via`: the SessionEnd hook knows the Claude session id + `reason`, `fleet_reap_record` knows the outcome — `landed`/`closed-unlanded` — and is the one choke point EVERY reaper funnels through). Hangs off the EXISTING hook paths, never a second source of truth for session state. **Unset ⇒ nothing happens at all**: no spool dir, no file, no socket, no behaviour change. What is sent is an enforced allowlist — event, timestamp, fleet session name, Claude session id, repo, issue, PR, branch, outcome words — and **nothing else**: no prompt or transcript content, no file paths, no issue/window titles, no hostname or username (identity rides the token). Every value passes a per-field charset filter, which is the privacy rail and the JSON-injection rail at once (`bin/fleet-emit-selftest.sh` asserts both, plus that the delivered object has only allowlisted keys). Fire-and-forget: one file per event into a bounded spool (`FLEET_EMIT_QUEUE_MAX`, default 500, drops the OLDEST on overflow), then a DETACHED drain with a hard curl timeout — a dead endpoint is a silent no-op, never a stalled worker, and nothing retries in the foreground; a 4xx is permanent so one bad event can't wedge the queue. `fleet-doctor.sh` prints an `emit` line (and flags a spool that stopped draining — otherwise invisible). Spends no LLM tokens. See docs/EMIT.md | curl |
| Fleet Hub (optional) | `bin/fleet-hub.py` — an **off-by-default** MCP endpoint that drives Fleets on SEVERAL machines through one connection, for an authorized Agent rather than a human at a dash. Nodes answer a fixed JSON control entry point (`bin/fleet-control.py rpc`) over the administrator's own SSH config; they open no new listener and need no MCP package. The Hub keeps the registry (persistent machine UUID + UUID5 Fleet ids, so a name collision across machines is not one), expiring per-caller grants (ONE per Agent and purpose, #833 — `grant` defaults to read-only for 24h, `principals` lists every grant with its scopes and last call, `revoke` takes one principal), an operation journal and an audit trail in `~/.config/claude-fleet/hub`. Nine tools — `fleet_list` / `fleet_status` / `config_get` / `worker_start` / `worker_message` / `worker_stop` / `worker_resume` / `config_set` / `operation_get`; the three lifecycle tools address a worker by its durable `worker_id` (`<fleet UUID>/issue-<N>`, issue #834), re-resolved on the fleet at action time, each behind its own scope — and no shell, no raw tmux, no arbitrary path, no `--force`, no registration or granting: those stay administrator CLI. Every call re-checks the live grant, so a visible tool is not an authorization decision. Writes are recorded before they are sent, deduped per caller by idempotency key, and an unconfirmed one stays `unknown` rather than replaying. Config writes are three integer keys (`FLEET_MAX_SESSIONS`, `FLEET_AUTOFILL`, `FLEET_AUTOFILL_MAX_PER_TICK`) behind a compare-and-set on the Fleet overlay, through the SAME kernel-held lock + atomic writer the dash `prefix+c` modal uses. `worker_start` reuses `dash-issue-session.sh`, so capacity/claim/disk/quota gates all still apply. Nodes keep running their workers if the Hub goes down. `bin/fleet-hub-service.py install` adds a KeepAlive `com.claude-fleet.hub` LaunchAgent on loopback behind an HTTPS proxy (Tailscale Serve, no Funnel) with `--auth grant-token`; an OAuth JWT resource-server mode exists but advertises no authorization server. Spends no LLM tokens by itself — `worker_start` spawns a real session. See docs/FLEET-HUB.md | python3 + `pip install -r requirements-mcp.txt` (Hub only) |
| Classifier (optional) | Stop-hook does real-time single-window state fix (detects `looping`), plus the spinner's stuck-`working` demote kicks it for a window a Stop missed. It only refines `done`/`needs`/`looping` (trusts the hook for `working`) — so a window stuck at `working` from a missed Stop is handled upstream by the spinner's demote check, which flips it to `done` and then kicks the classifier to refine it | `claude` CLI |
| Worktree janitor (optional) | prunes merged+clean+idle worktrees. Before each removal it **reaps any process still anchored to the worktree** (`fleet_reap_worktree_procs` — argv match + cwd match, SIGTERM→SIGKILL; issue #151) so a detached orphan can't outlive its dir and drain a core against the shared tmux server. The dash's `⌃x` reap (`dash-reap.sh`) does the same. It never kills a process running under a **live tmux pane**, and it skips a worktree that is mid **account rotation** or still running a pane's processes — the close→resume gap makes every tmux-metadata gate momentarily read a live worker as finished (issue #550; see docs/CLEANUP.md) | gh |
| Raw scratch session (dash `⌃s`) | opens a plain, **non-issue-bound** `claude` window in the fleet — no GitHub issue, but in its **own writable `scratch-N` git worktree** off the base branch (`bin/dash-raw-session.sh`, issues #214/#290). The counterpart to the issue-bound spawns (dash `⌃n` / backlog Enter / `dash-issue-session.sh`), for ad-hoc exploration or experiments that may need to WRITE code (the base checkout is hook-enforced read-only). A scratch that turns real just pushes its branch + opens a PR — the prmap is repo-wide, so the janitor reaps a merged `scratch-N` like any worker (zero new machinery), and the unique cwd makes its transcript resolvable. Spawns on the keystroke — **no name popup, no confirm** — with the slow half (fetch + worktree add + window launch) backgrounded so the dash never freezes; a name is still available off the dash via `--name`. The dash's always-visible **prompt line** is the NAMED variant (#534): **type a name, Enter** → the same scratch spawn with the text as the window name (`--name-file`, staged through a file — never interpolated; capped at 24 display columns, so Chinese and spaces are fine), with the full text prefilled at `❯` as an editable, **unsent draft** (the draft is not clipped to the window title). Cold spawns wait for the input to settle; warm-pool spawns prefill the ready input. A prefill never presses Enter or overwrites existing input. A SEEDED scratch is still available off the dash via `--prompt <text>` (the cross-fleet handoff pattern) — the text rides as `claude`'s launch argument, so a seeded scratch skips the warm pool. Marked `@raw=1` + `@worktree=<path>`, named `scratch-N` (or a custom name); **listed in the dash as a real session** (counts toward the session cap) but excluded from the issue machinery — no `@issue`, so the watcher (`@raw` skipped) leaves it alone, while the classifier still shows its state. The **window** is ephemeral (not snapshotted/restored across a crash); its **worktree** survives on disk and is reaped by the janitor's scratch rules — clean + no unmerged work → removed silently; dirty or unmerged → kept + surfaced once (never silently delete an experiment; `dash ⌃x` disposes it) | claude |
| Codex workers (optional, issue #547) | `FLEET_AGENT=codex` in a fleet's conf — or `--agent codex` on one `dash-issue-session.sh` / `dash-raw-session.sh` spawn (scripts; the dash prompt line has no agent prefix, issue #559) — makes the spawn launcher `bin/fleet-claude.sh` hand the session to **`bin/fleet-codex.sh`**, which execs **OpenAI Codex CLI** in the same `issue-<N>` worktree, claimed at spawn like any worker. Codex has no slash commands, so the bare `/fleet-claim` seed is **expanded into prose** (`conf/codex-preamble.md` — how to read a Claude Code skill as a Codex agent — followed by `commands/fleet-claim.md`, `$ARGUMENTS` substituted): the lifecycle text stays single-sourced. The fleet's hooks ride inline as `-c hooks.<Event>=[…]` — Codex's hook system is Claude Code's schema (verified on 0.154: same events, same stdin JSON, exit 2 blocks, env inherited): PreToolUse `busy` + `bash-guard.py` (`Bash`) + `base-readonly-guard.py` (`apply_patch` — it parses the patch's `*** Add/Update/Delete File:` / `Move to:` targets), PostToolUse / UserPromptSubmit `working`, Stop `done` — so the dash colours a Codex window like a Claude one, and the two bypass-permissions rails hold. `CLAUDE.md` is read as the project doc (`project_doc_fallback_filenames`). Posture: `--dangerously-bypass-approvals-and-sandbox` (a bypassPermissions worker's footing; hooks are the rails) + `--dangerously-bypass-hook-trust` (the fleet vets its own hooks). Claude-only and skipped: `--model`/`FLEET_MODEL` + the model-cap fallback (Codex uses `FLEET_CODEX_MODEL` → `-m`, else your `~/.codex/config.toml`), the MCP allowlist, the subagent model, account rotation (Codex auth = `codex login`), `/fleet-handoff` + auto-handoff, `/fleet-context` + the dash ctx %, the warm scratch pool, and SessionEnd close-on-exit (Codex reports `reason=other` for every end; the cleanup daemon / ledger-watch reap instead — a vanished Codex window is recorded **transcript-less** (`-`, review-only) in `/fleet-history`). `--resume`-shaped launches (restore, migrate) are always Claude. The window is stamped `@cc_agent codex` (dash tag `codex`). The dash prompt line shows the fleet's default for a NEW session (`claude ▸` / `codex ▸`, codex in the row-tag colour) and **⌃v** flips it — `FLEET_AGENT` written to the fleet's conf through the config-modal path, so every spawn path follows (`bin/dash-agent-toggle.sh` + `bin/dash-agent-prompt.sh`, issue #554; `bin/dash-agent-toggle-selftest.sh`). Every dash ⌃-key is resolved against your tmux `prefix`/`prefix2` at launch by **`bin/dash-keymap.sh`** (issue #556 — ⌃a was the operator's prefix, so tmux ate it): a colliding key moves to its ⌥ twin, the `?` sheet shows the key actually bound, and `fleet-doctor.sh` warns (`bin/dash-keymap-selftest.sh`). **One-time:** trust the base checkout in Codex (`codex` in `$FLEET_MAIN` → Yes) — a worktree inherits its main repo's trust; the launcher flags an untrusted base as `needs` instead of letting the pane stall on the prompt. Default fleets are byte-for-byte unchanged (`bin/fleet-codex-selftest.sh`) | `codex` ≥ 0.154, logged in, base checkout trusted |
| `cw`/`cwrm`/`cwclean` | zsh worktree helpers | zsh |
| Several repos per fleet (`bin/fleet-repo.sh`, issue #788/#795) | `fleet-repo.sh add <owner/repo> [<checkout>] [--base <b>]` registers another repo with a fleet (clone-or-reuse, overlay at `fleets/<sess>/repos/<slug>.conf`); `list` / `remove [--force]`. Nothing to install and no switch to set — a fleet with no overlay behaves exactly as before. Once 2+ repos are hosted, the fleet picker gains repo rows, sessions carry `@repo` and a short tag, and the hub opens in `$HOME`. Proven by `bin/multirepo-e2e-selftest.sh` | git (+ gh to clone) |
| Fleet commands (optional) | repo-shipped `/skill`s (`commands/`) — fleet-aware slash commands, appended to `~/.claude/commands/` | claude |
| Fleet skills (optional) | repo-shipped base **skills** (`skills/<name>/` dirs — SKILL.md plus any supporting files) a fleet command or the agent delegates to — e.g. `/fleet-handoff` runs the base `handoff` skill verbatim; `doc-preview` ships `share.sh`/`server.py`/`render.mjs` beside its SKILL.md (issues #311, #354), `epic-page` ships the `template.html` both EPIC pages render into (issue #809); installed into `~/.claude/skills/` whole-dir, marker-gated (`<!-- fleet skill -->` in the SKILL.md) so a personal skill is never clobbered | claude |
| Status line (optional) | `conf/statusline.sh` — Claude Code status line: a context-window mini-bar (green < 50% < yellow < 80% < red), shortened cwd, git branch + dirty star (via `--no-optional-locks`), and model name. Wired **install-time only** by pointing `settings.json`'s `statusLine` at the **live-install** path `~/.claude/fleet/conf/statusline.sh`, so improvements flow through `land → /fleet-sync-install` with no copy step. jq-gated — exits silently (blank line) without `jq`. NOT auto-wired on sync; opt-in per install (see step 8b) | jq (soft) |

## Install steps

Worker hibernation is described in [WORKER-SLEEP.md](WORKER-SLEEP.md). Install
`com.claude-fleet.sleep` / `claude-fleet-sleep.timer` with the other interval
daemons in step 6. Its default `FLEET_SLEEP=observe` reports candidates only;
after validating native sleep/resume, set `FLEET_SLEEP=on` to retain idle workers
in the dashboard while releasing their agent processes. Existing sessions pick
up the native Stop evidence writer through `set-claude-state.sh` without restart.

1. **Preflight.** Run `sh ~/.claude/fleet/bin/fleet-doctor.sh` (or from the repo
   before copying) — it checks tmux ≥ 3.2 · fzf ≥ 0.45 · gh (+ auth) · python3 ·
   claude · perl `Time::HiRes` and prints pass/warn/fail. Offer to
   `brew install` anything that fails. On a machine that already has a live
   install its `install` line answers the question nothing used to (issue #635):
   **is this machine's `~/.claude/fleet` current?** — one `git fetch` of one
   branch, then `PASS install … up to date` or `WARN install … is N commit(s)
   behind` with the fix (`git -C ~/.claude/fleet pull --ff-only`, then
   `/fleet-sync-install`, which also reloads the changed daemons). A fetch that
   fails reports **unknown**, never up-to-date: on 2026-09-14 macmini sat 28
   commits behind master with a fully green doctor on both machines, and silence
   reading as green is the whole failure. `bin/fleet-install-version.sh` is the
   same check standalone (`--json` for a reporter, `--no-fetch` for anything that
   must not touch the network). Notes: standalone `jq` is **not** needed
   (the collector only uses `gh --jq`, which is built in); perl `Time::HiRes` is
   a soft dep (without it the dash spinner ticks at whole-second granularity).
   If `gh` is not authed, the backlog/PR features silently show nothing — tell
   the user. Its `trust` line checks, per configured fleet, that `FLEET_MAIN` is
   trusted in `~/.claude.json` (issue #563): Claude Code keys its "trust this
   folder?" dialog on the resolved project root — a worktree resolves to its main
   checkout — so an untrusted base parks every unattended worker on that dialog.
   The spawn launcher pre-trusts the fleet's own checkout automatically
   (`bin/fleet-claude.sh` → `bin/fleet-trust.sh`, scoped to `FLEET_MAIN` + its
   worktrees, atomic; `FLEET_PRETRUST=0` opts out); the doctor/`fleet-up` warning
   is for an install that predates it, with the one-line fix
   (`sh bin/fleet-trust.sh grant --main <FLEET_MAIN>`).

2. **Copy to the install dir.** Canonical: `~/.claude/fleet/`. Copy `bin/`,
   `conf/`, `shell/`, `fleet.conf.example`, `requirements-mcp.txt` there; `mkdir -p ~/.claude/fleet/logs`;
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
   usage stat → `bin/usage-modal.sh`), not the keyboard. There are also **root-table** binds (`bind -n …`)
   that intercept the key/mouse in every pane *before* the app, so flag each: `F9`
   jumps back to this session's hub (`hub-zoom.sh`) — safe because the
   Claude TUI/shells don't use function keys; `MouseDown1Status` owns the clickable
   footer ranges (hub/fleet/needs/account/usage); and **double-click-to-zoom**
   (`DoubleClick1Pane` → `resize-pane -Z -t=`, `DoubleClick1Border` on the divider)
   toggles a pane's fullscreen as the mouse counterpart to `prefix+g`/`F9` — its
   trade-off is losing tmux's default double-click = select-word (copy), so call it
   out; a worker whose task sidebar is on screen is the exception and keeps
   select-word (issue #820). All are overridable from the user's own `~/.tmux.conf` after the `source-file`
   line, or comment them out — the same framing as the rest of the baseline block.

5. **Wire the Claude Code hooks.** Two ways, and **the plugin in step 8 does
   this for you** — if you install it, skip the merge below and read this section
   only for what the hooks are.

   By hand: `python3 bin/fleet-hooks-merge.py merge` merges
   `hooks/settings-hooks.json` into `~/.claude/settings.json` — it keeps every
   existing hook that isn't the fleet's, wires each fleet hook exactly once by
   identity `(event, matcher, script basename)` (issue #818 — never a jq `+=`,
   which stacks a second copy the first time a command string changes), and
   backs settings.json up first. `fleet-doctor`'s `hooks` line checks the result. These hooks are no-ops outside
   tmux and always exit 0, so they are safe to add globally. The `Stop` entry also
   fires `classify-hook.sh`, the real-time path for state classification: it
   hands just the stopped window to `classify-sessions.sh --window`, so the
   ambiguous `done` is resolved to `looping`/`needs`/`done` within ~1-2s instead
   of waiting for the daemon backstop. Also backgrounded + self-disabling; a
   no-op if you skip the classifier. The `SessionStart` array also fires
   `handoff-latch-reset-hook.sh` (issue #330):
   it clears the `@handoff_armed` auto-handoff debounce latch at every session
   boundary and, on a `/clear`, drops the stale `@ctx_pct` of the session that just
   ended (issue #571). Both hooks exit untouched for a **headless** `claude -p`
   child (`CLAUDE_CODE_ENTRYPOINT≠cli`) — not the pane's session — and the nudge
   is **held** while a client is typing at that window (`FLEET_HANDOFF_DEFER_SECS`,
   default 30 s; 0 = off). That latch is set by the `Stop` hook's **auto-handoff nudge**: when
   `FLEET_AUTO_HANDOFF_PCT>0` (OFF by default) and a worker/scratch session's
   context crosses that %, `set-claude-state.sh done` emits a Stop-hook `block`
   decision steering the model to run `/fleet-handoff` (store → `/clear` → resume)
   — reusing the whole existing handoff cycle, only the trigger is new. The `%` is
   measured by `conf/statusline.sh`, which stamps it onto `@ctx_pct` each render
   (so this needs the status line wired, step 8b); the threshold is read from the
   **conf** (global `fleet.conf`, then the fleet's overlay) through
   `bin/fleet-hook-conf.sh` — nothing to export, and `fleet-doctor.sh`'s `handoff`
   line shows what the hook actually sees (issue #561). The nudge fires once per session
   (latch), only from a clean `done` (never a needs-attention turn), and never on
   panels or the hub pane.

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
     This closes the gap for the **worker** seat, which had
     no base-checkout protection at all. A no-op outside a fleet (no `FLEET_MAIN`
     resolvable → allow), so it's safe to add globally.
   - `hooks/artifact-guard.py` (matcher `Artifact`, issue #526) — a fleet
     session never *publishes* an Artifact: the page is scoped to the claude.ai
     account that published it and the fleet rotates accounts under sessions, so
     the refusal points at the `doc-preview` share instead. Reading / listing /
     commenting stays allowed; `FLEET_ALLOW_ARTIFACT=1` overrides.
   - `hooks/agent-guard.py` (matcher `Agent`, issue #811) — in a fleet pane,
     **code-writing work goes to a fleet worker, never a subagent**. Only the
     read-only `Explore` / `Plan` / `claude-code-guide` subagent types may start;
     `general-purpose`, `claude`, `fork`, an unnamed type and any
     `isolation: worktree` are refused with a pointer at
     `dash-issue-session.sh <N>` / `fleet-issue-file.sh --spawn` /
     `dash-raw-session.sh`. A subagent runs outside every fleet rail (invisible
     to the dash, no state, killed mid-edit when the quota migration moves the
     window, several writing one worktree, no one-worker-one-PR / history /
     handoff). Fleet-scoped: a no-op without `$TMUX`, or in a tmux session that
     has no fleet conf. `FLEET_ALLOW_SUBAGENT=1` overrides. Codex has no Agent
     tool, so `hooks/codex-map.json` drops the group.

6. **Daemons.**
   - macOS: for each template in `launchd/`, substitute `__HOME__` with the
     real home dir **and `__BREW_PREFIX__` with `$(brew --prefix)`** (falls back
     to `/opt/homebrew` if `brew` isn't on PATH) — this is what makes tool
     discovery work on Intel (`/usr/local`) as well as Apple Silicon
     (`/opt/homebrew`). Write to `~/Library/LaunchAgents/`, then
     `launchctl bootstrap gui/$(id -u) <plist>` (or `launchctl load` on older
     macOS). The spinner (KeepAlive) and collector (60s) are the required two;
     with a ccquota hub + account pool, the **quotawatch** unit
     (`com.claude-fleet.quotawatch`, 60s, issue #551) is the pre-emptive
     rotation's own tick — install it whenever `CCQUOTA_HUB_URL` is set (the
     collector runs the same watch first thing each tick as a backstop, but its
     cadence then rides the collector's). **Get the `ccquota` binary before you
     load that unit**: it is not a brew formula and this repo does not ship it,
     so a quotawatch unit without it loads clean and then silently no-ops forever
     (`bin/fleet-quotaguard.sh` exits 0 when `ccquota` is off `PATH` — fail-open,
     so nothing ever complains). It comes from **TokenLedger**
     (<https://github.com/verkyyi/tokenledger>), which has no tagged releases
     yet, so build it:

     ```sh
     go install github.com/verkyyi/ccquota/cmd/ccquota@latest   # needs Go 1.25+
     ```

     Because there is no tagged release, the binary on each machine is whatever
     `@latest` was the day you ran that — so the builds drift per machine. The
     doctor's `quota` line prints the version it got from `ccquota version`
     (issue #668), which is the first thing to compare when one machine's quota
     line is red and another's is green.

     The product was renamed to TokenLedger on 2026-09-14 but **the identifiers
     were deliberately not**: the command, the Go module path above, the
     `CCQUOTA_*` variables and `~/.ccquota/` are all still spelled `ccquota`, and
     this fleet reads them under those names. See that repo's README for standing
     up the hub and pointing `CCQUOTA_HUB_URL` at it.

     Next, the **diskguard** watcher (`com.claude-fleet.diskguard`, 60s) is strongly
     recommended — a full volume ENOSPCs any tmux server whose writes fail, and
     though each fleet now runs on its OWN socket (issue #159) so a disk-full no
     longer takes *every* fleet down through one shared server, it can still crash
     each fleet sharing that volume — so the watcher captures forensics + notifies
     on low disk and its `--gate` mode (called by fleet-up and fleet-restore)
     refuses to add load below the floor. The same `--watch` tick also runs the
     **runaway-CPU watchdog** (issue #151) — no extra unit; it's OFF until a fleet
     sets `FLEET_RUNAWAY_CPU_PCT>0`, then a detached orphan spinning a core is
     caught + (optionally) killed before it can overload its fleet's server.
     That same tick also runs the **orphaned-runaway watchdog** (issue #697),
     which unlike the one above is **ON by default and report-only** — it flags
     `PPID=1` processes holding ≥`FLEET_ORPHAN_CPU_PCT` (50) for
     ≥`FLEET_ORPHAN_CPU_SECS` (300) whose argv carries a Claude/fleet fingerprint.
     Still no extra unit, so **installing diskguard is what arms it**; a machine
     without that unit has no machine-level runaway defense at all. Check it any
     time with `bin/fleet-diskguard.sh --orphans`, or on the `machine` line of
     `bin/fleet-doctor.sh`.
     The **pr-refresh** daemon (`com.claude-fleet.pr-refresh`, 15s) is also
     recommended — it owns PR/CI status (`prmap` + window `@prci`/`@pfg`) on its
     own fast tick, decoupled from the 60s collector, so a PR going green or
     merging shows within ~15s (when you are reviewing / the cleanup daemon
     is waiting to reap it) instead
     of up to a minute. It's the single writer of that state (the collector no
     longer touches it), disk work is trivial, and only `gh` is needed;
     `FLEET_PR_REFRESH_INTERVAL` (default 15) tunes it — keep it in step with the
     plist `StartInterval`.
     worktree-autoclean is optional — ask the user. The classify hook spends
     (small, change-gated) LLM tokens; it is the fleet's only `claude -p` helper
     now that the dash summarizer retired (issue #535).
     classify has NO daemon — the real work happens in the `Stop` hook
     (`classify-hook.sh` → `classify-sessions.sh --window`) plus the spinner's
     stuck-`working` demote, so there is nothing to install for it.
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
     dispatch (`com.claude-fleet.dispatch`, 60s) is the **autofill** daemon —
     install it only if a fleet sets `FLEET_AUTOFILL=1`; it auto-spawns the
     highest-priority eligible backlog issue under both caps (per-fleet
     `FLEET_MAX_SESSIONS` + global), single-writer + disk-gated + rate-limited.
     It is **opt-in per issue** (issue #421): only issues carrying the `autofill`
     label are auto-spawned, so you tag exactly which ones may fill idle
     slots hands-off — it never drains the whole backlog. OFF by default; it spends
     LLM tokens (one real Claude session + PR per spawn), so ask before installing
     and mention the cost. `--dry-run` prints the intended spawns without spawning.
     cleanup (`com.claude-fleet.cleanup`, 60s) is the **cleanup daemon** —
     **recommended** for every fleet, since **nothing else reaps** (issue #277):
     the worker's `/fleet-claim` ship+land step merges its own PR (#441) and this
     daemon reaps the leftover
     worktree/window/branch + records the resume ledger once a PR is final (MERGED
     or CLOSED-unmerged). It runs OUTSIDE every window, so it can reap the very
     window whose worker did the merge. It scans the prmap cache pr-refresh already writes (MERGED/
     CLOSED rows, ZERO extra `gh`) for a final PR with a live worktree/window and
     drives `bin/fleet-cleanup.sh`, single-writer + disk-gated + rate-limited
     (`FLEET_CLEANUP_MAX_PER_TICK`), each candidate under a wall-clock budget
     (`FLEET_CLEANUP_CANDIDATE_TIMEOUT`, 120s) so one wedged reap can't stall
     every fleet's pipeline behind it (#587). It **merges nothing and
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
     `claude-fleet-pr-refresh.timer` (fast ~15s PR/CI status) +
     `claude-fleet-quotawatch.timer` when a ccquota hub is configured (the
     pre-emptive rotation's own 60s tick, issue #551 — install the `ccquota`
     binary first, as in the macOS step above, or the timer no-ops silently)
     + the recommended
     `claude-fleet-cleanup.timer` and `claude-fleet-ledger-watch.timer` (index
     every closed session for resume) and `claude-fleet-base-sync.timer`
     (keep the local base fast-forwarded to the remote, merge-independent); the
     optional
     dispatch/issue-bridge/watch/worktree-autoclean are `.timer`s too, and the
     optional **webhook** daemon is an always-on `.service`
     (`claude-fleet-webhook.service`, parity with the KeepAlive plist — needs
     `FLEET_WEBHOOK=1` + `gh extension install cli/gh-webhook`).
     Run `loginctl enable-linger "$USER"` so they run detached. Full recipe in
     `systemd/README.md`.

   **Ship the units as written — the scheduling class is load-bearing** (issue
   #588). Seven plists deliberately carry `ProcessType=Standard` rather than the
   `Background` the other six use: **cleanup**, **worktree-autoclean**,
   **diskguard**, **base-sync**, **dispatch**, **sleep** and **collect**. `ProcessType=Background` puts
   the job's whole process TREE at QoS BACKGROUND, and that class carries
   **throttled disk I/O** — measured on macOS 26, two identical LaunchAgents
   deleting two identical 20k-file trees ran at **104 files/s (Background) vs
   10967 files/s (Standard)**, ~100x, and the gap widens as the machine gets
   busier: in the field a `git worktree remove` of a 308k-file worktree crawled
   at **~0.4 files/s** — 67 minutes of wall clock for 54 seconds of CPU. The
   first six do bulk filesystem work (worktree reclaim, `du` tree walks, a
   base ff-pull under the shared land lease, a full checkout on spawn) that the
   dash, the next worker or the operator is waiting behind, so throttling them
   penalises exactly the wrong thing; their `StartInterval` is the throttle that
   matters. **collect** is Standard too, for a different reason (issue #651):
   its tick forks per worktree, window and socket, Background makes each fork
   ~8x dearer (80 `git` calls: 16s vs 2s at load 12 on 10 cores), and launchd
   never overlaps a `StartInterval` job — so a throttled tick outran its 60s
   interval and the dash refreshed every 3.5–5 minutes. The six pollers
   (pr-refresh, spinner, quotawatch, issue-bridge, ledger-watch, webhook) only
   touch gh/tmux/network and stay `Background`. Don't "normalise" the templates in either direction — the split
   is asserted by `bin/daemon-processtype-selftest.sh`, which also fails on a new
   daemon that hasn't been classified. On Linux the same rule reads as: no
   `IOSchedulingClass=idle` and no positive `Nice=` on those five services.

   **Verify what you actually loaded.** `bin/fleet-doctor.sh` checks each optional
   daemon's agent, not just the fleet conf flag that asks for it (issue #492) — a
   fleet that wants ledger-watch but never had `com.claude-fleet.ledger-watch`
   installed now WARNs instead of passing. Re-run the doctor after this step and
   after any upgrade that adds a daemon: an agent added upstream is NOT installed
   retroactively on a machine that installed the fleet before it existed.

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

   **Optional — Codex workers.** To run a fleet's workers on OpenAI Codex CLI
   instead, set `FLEET_AGENT="codex"` in that fleet's conf (`prefix+c`, or
   `~/.config/claude-fleet/fleets/<session>/conf`) and make sure `codex` is on
   PATH and logged in (`codex login`), and **trust the base checkout once**:
   run `codex` inside `$FLEET_MAIN` and answer *1. Yes* to "Do you trust the
   contents of this directory?" — Codex persists that per project, and a git
   worktree inherits its main repo's trust, so every `issue-<N>` / `scratch-<N>`
   spawn is then silent (an untrusted base turns the first Codex pane red with
   the instruction; nothing is written to `~/.codex` by the fleet). Nothing else
   to install: the launcher branches to `bin/fleet-codex.sh` and the fleet's
   hooks are passed to Codex inline (see the component table).
   `FLEET_CODEX_MODEL` picks the model. The dash prompt line reads `codex ▸`
   once it is set, and **⌃v** on the dash flips the fleet back and forth
   (issue #554; the `?` sheet shows the key actually bound). The toggle key,
   `prefix+c` or the conf are the ways to pick the agent — typed text on the
   prompt line supplies the window name and an editable, unsent input draft.

8. **Fleet commands + skills (optional) — install the plugin.** The fleet's
   Claude-Code-side surface (the `/fleet-*` slash commands, the base `skills/`
   tree they delegate to, and the hook table from step 5) ships as a **Claude
   Code plugin**, served by a marketplace in this same repo (issue #611):

   ```sh
   claude plugin marketplace add verkyyi/claude-fleet
   claude plugin install fleet@claude-fleet --scope user --yes
   ```

   That is the whole step — no copying, no never-clobber rules, and
   `/plugin update fleet` replaces the `commands`/`skills`/hooks passes of
   `/fleet-sync-install` from then on. Three things to know:

   - **Plugin commands are NAMESPACED**: `/fleet:fleet-claim`, not
     `/fleet-claim`. The fleet resolves this itself — `fleet_cmd` in
     `bin/fleet-lib.sh` probes which install path this machine has and seeds the
     form that expands, so spawns work unchanged. `FLEET_CMD_PREFIX` forces it
     either way.
   - **Register it in `settings.json` for a team**, so a teammate's machine picks
     it up (and keeps itself current) without anyone running `/plugin`:

     ```json
     {
       "extraKnownMarketplaces": {
         "claude-fleet": {
           "source": { "source": "github", "repo": "verkyyi/claude-fleet" },
           "autoUpdate": true
         }
       },
       "enabledPlugins": { "fleet@claude-fleet": true }
     }
     ```

     ⚠️ `autoUpdate` is **marketplace-level and off by default** for third-party
     marketplaces — a plugin does *not* get session-start auto-update merely by
     existing. With it on, the update lands after a session starts (with a short
     random delay) and applies to the **next** session, not the running one. A
     first install on a new machine still needs the `claude plugin install` line
     above; `enabledPlugins` alone does not fetch an external source.
   - **It does not replace this playbook.** The plugin covers only what Claude
     Code loads. `bin/`, `conf/`, the tmux layer and the daemons are machine-level
     and stay at `~/.claude/fleet` — steps 2, 4, 6 and 7. That split is
     deliberate: a plugin's install path is **version-scoped**
     (`…/plugins/cache/<marketplace>/fleet/<version>/`) and moves on every update,
     so nothing with a stable absolute path — a launchd/systemd unit, a tmux bind,
     a hook command — can point into it. The hook table therefore keeps naming
     `~/.claude/fleet/...` on **both** install paths.

   **Copy install (fallback).** Without the plugin — no `claude plugin` CLI, an
   air-gapped machine, or a fleet that predates it — the historic path still works
   and is still supported: copy `commands/*.md` → `~/.claude/commands/` and each
   skill **directory** `skills/<name>/` → `~/.claude/skills/<name>/`. Follow
   **steps 5 and 5b of `commands/fleet-sync-install.md`** rather than a second
   copy of the rules here — they are the same passes (append-never-clobber, the
   `<!-- fleet skill -->` marker gate, whole dirs with `cp -p` so
   `skills/doc-preview/`'s scripts land beside its SKILL.md), and every later
   update runs them anyway.

   `fleet-doctor.sh` reports which path is in use (or warns if neither — they're
   optional). See `commands/README.md` for the skill contract.

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
   `docs-truth`, `scout`, `priority:p0|p1|p2`, `blocked`,
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

   Then run the code's own gate — **it is safe to run from the live install**:
   `sh ~/.claude/fleet/bin/run-selftests.sh </dev/null`, expect `all green`.
   (Redirect stdin: backgrounded without it, `auto-handoff-selftest` blocks
   forever on a hook that `cat`s an open stdin.) It re-runs itself from a
   throwaway **shadow install root** — your `bin/` mirrored by symlink, with no
   `fleet.conf` beside it, an empty `logs/`, an empty `FLEET_CONF_DIR`, and every
   `FLEET_*`/`CCQUOTA_*` variable stripped from the environment — so the verdict
   is about the code, never about this machine's config, and a run cannot read or
   clobber a running fleet's state (issue #660: before that, six tests went red on
   a live install while the same commit was all-green from a checkout, which made
   the answer to "does the code on this machine run?" worthless). Chasing one red
   test goes through the same prelude: `run-selftests.sh fleet-context`, or a glob
   (`run-selftests.sh 'dash-*'`).

   Expect ~9 minutes, and a **slowest-tests** table at the end — the number to
   watch if the gate ever starts creeping toward its CI budget again (issue
   #681). CI gets that time back by splitting the suite across six runners
   (`--shard K/N`), one runner per slice; locally there is nothing to split
   across, and running the slices side by side on one machine would *cost* you
   reliability rather than time: several of these tests assert on real-time
   windows that only hold while nothing else is competing for the box.

## Uninstall

Remove the LaunchAgents (`launchctl bootout gui/$(id -u)/com.claude-fleet.*`,
delete the plists), delete the `source-file …tmux-attention.conf` line from
`~/.tmux.conf`, remove the five `set-claude-state.sh` hook entries (and the
`handoff-latch-reset-hook.sh` entry on `SessionStart`) from `~/.claude/settings.json`, remove the `statusLine` block from
`~/.claude/settings.json` **only if** it points at `conf/statusline.sh` (leave a
personal one), delete `~/.claude/fleet/`, remove any fleet commands
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
`com.claude-fleet.cleanup`, `com.claude-fleet.ledger-watch`,
`com.claude-fleet.base-sync`, `com.claude-fleet.dispatch`, and `com.claude-fleet.webhook`; on Linux
`systemctl --user disable --now claude-fleet-pr-refresh.timer` +
`claude-fleet-issue-bridge.timer` +
`claude-fleet-cleanup.timer` + `claude-fleet-ledger-watch.timer` +
`claude-fleet-base-sync.timer` + `claude-fleet-dispatch.timer` + `claude-fleet-webhook.service`.) If you ran the
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
