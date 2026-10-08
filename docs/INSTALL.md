# claude-fleet — install playbook

You (Claude Code) are the installer for this repo. When the user asks you to
"install", "set up", or "uninstall" claude-fleet, follow this playbook. Adapt
intelligently to their machine — that is the point of a Claude-orchestrated
install — but keep every change **reversible and announced**: show the user
what you are about to modify (`~/.tmux.conf`, `~/.claude/settings.json`,
LaunchAgents/systemd units) before you do it.

Read `CLAUDE.md` (repo root) for what the repo is and the conventions the code
assumes — this doc is only the install/uninstall procedure.

**Several people on one machine?** Give each person their own OS login and run
this playbook once per login — see [SHARED-MACHINE.md](SHARED-MACHINE.md). One
login is one fleet; a shared login gives everyone one quota record.

## Components

| Piece | What | Requires |
|---|---|---|
| Attention layer | hooks → window colors/spinner/urgency-sort; the spinner daemon also demotes stuck-`working` windows (missed Stop hook) via a marker-agnostic `window_activity`-staleness check (`FLEET_STUCK_WORKING_SECS`) | tmux ≥ 3.2 |
| Bypass-permissions guards (issue #355) | `PreToolUse` hooks — the last line of defense once workers run `bypassPermissions` (CC never prompts). `hooks/bash-guard.py` (matcher `Bash`): a GENERIC deny-list (`rm -rf` on `/` `~` `.git`; force-push onto the base branch) with statement-segment splitting + git-subcommand matching for near-zero false positives, plus a never-shipped local overlay (`~/.claude/hooks/bash-guard-local.py`) for operator-specific rails. `hooks/base-readonly-guard.py` (matcher `Edit\|Write\|MultiEdit\|NotebookEdit`): makes the base checkout edit-read-only for **every** seat by denying writes inside `FLEET_MAIN` (worktree siblings stay writable) — closes the gap for the worker seat, which had no base-checkout protection at all. `hooks/artifact-guard.py` (matcher `Artifact`, #526): a fleet session never *publishes* an Artifact (account-scoped; use doc-preview). `hooks/agent-guard.py` (matcher `Agent`, #811): in a fleet pane only the read-only `Explore` / `Plan` / `claude-code-guide` subagents may start — code-writing work is a fleet WORKER (`dash-issue-session.sh` / `fleet-issue-file.sh --spawn`), since a subagent gets none of the fleet's rails; `FLEET_ALLOW_SUBAGENT=1` overrides. All **fail OPEN** (a guard bug or a non-fleet session → allow) | python3 |
| Dashboard (`prefix+g` on a node until #1714) | fzf mission control — an embedded pane in the `plan` hub, which holds the dash and nothing else (no hub Claude session — that pane is retired because it rebuilt itself on every ⌂ tap / F9 / fresh fleet / crash recovery); `prefix+g` focuses it and toggles it fullscreen (`dash-zoom.sh`), as does F9. No standalone dash window | fzf ≥ 0.45 (0.60+ best); its binds use `transform` |
| Backlog (`prefix+b` on a node until #1714) | GitHub issues panel, Enter = spawn issue-bound session. Each row tags its `priority:pN` (from `labels_<slug>`, no extra gh call) and issues sort by priority within a milestone; `⌃y` cycles a row's priority label (none→p2→p1→p0, `bin/dash-issue-priority.sh`, no popup). `⌃n` files a one-line issue | gh (authed) |
| Config modal (`prefix+c` on a node until #1714) | fzf popup to view/edit `FLEET_*` config in two layers — this fleet (the login's `fleet.settings` + the fleet `conf`, one layer to you) ▸ a hosted repo's overlay — over the code default; the install's `fleet.conf` is still read as a read-only legacy layer, never written (#1102); internal pacing knobs stay under a collapsed INTERNAL "show all" header; ⌃s toggles the write scope (this fleet ⇄ repo), enter edits a key (typed validation, backup-first) | fzf ≥ 0.45 |
| Label taxonomy (`bin/fleet-labels-seed.sh`) | the fleet's **fixed** canonical label set (`bug`, `enhancement`, `cleanup`, `robustness`, `portability`, `ci`, `docs-truth`, `scout`, `priority:p0\|p1\|p2`, `blocked`, `autoland`, `autofill`, `epic` — issues #333, #421, #678). ONE source of truth, `fleet_labels_canonical`/`fleet_labels_allowed` in `bin/fleet-lib.sh`. The install seed step (`gh label create --force`, **idempotent**) installs it into a fresh repo; the issue-filer channel (`bin/fleet-issue-file.sh`) validates every requested label against `fleet_labels_allowed` — the FIXED set, not the live `gh label list` — so no filer can file against an off-taxonomy label even if one is minted out of band (**fixed seed, no minting**). A fleet can also opt into a **default milestone** so nothing lands unsorted: set `FLEET_DEFAULT_MILESTONE` (e.g. `Triage`) and every filing that passes no `--milestone` auto-lands there for you to re-bucket — the milestone is **auto-created if absent** (idempotent) and it's best-effort, so a milestone hiccup never blocks a filing (issue #433). `autoland` is stale (daemon retired #277) but kept for now; `autofill` opts an issue into hands-off auto-spawn by the dispatcher (issue #421); `epic` marks the tracking parent of a batch planned and run together (issue #678). **The descriptions are written for strangers** — this set is seeded into TEAM repos too, where these labels show up in the picker of people who have never heard of claude-fleet, so each one names what it means and who acts on it. Check a repo before planning a batch with `bash bin/fleet-epic-preflight.sh` (next row) rather than seeding blind | gh (authed, label-admin) |
| Cross-machine pre-spawn dedup | every spawn (`bin/dash-issue-session.sh`, the one choke point) consults the shared GitHub issue as a claim ledger before spawning, so two fleets on **different machines / same repo** don't both spawn `issue-<N>` (duplicate worktrees + push race + competing PRs) — the local tmux dedup only sees one machine. **The assignee IS the claim** (issue #283): taken (assignee · non-open state · open PR) ⇒ **refuse**; free ⇒ **claim AT SPAWN** by assigning `@me` (not on the worker's first `/fleet-claim` turn — that gap was the race) so a peer sees the assignee within ~1s. **NOT a mutex** (GitHub has no CAS on an issue) — it shrinks the race window, doesn't eliminate it; the old sub-second REST-comment-id tie-break was retired with the `▶ claiming` marker (workers share one gh account, so no per-attempt tie token exists). `--force`/`--reclaim` spawns past a stale claim. **ON by default** — the cost is a few gh reads/spawn (claim-at-spawn just moves `/fleet-claim`'s assign earlier; a gh outage degrades to spawn-anyway) and it self-disables when gh is absent; a single-machine fleet wanting the zero-gh fast path sets `FLEET_PRESPAWN_DEDUP=0`. `/fleet-claim` stays but no-ops when it finds the pre-claim | gh (authed) |
| EPIC preflight (`bin/fleet-epic-preflight.sh`) | **can this repo run a batch?** (issue #678) — the check `/fleet-epic plan` opens with, in `fleet-doctor.sh`'s `TAG STATE detail` shape: `gh` authed · `viewerPermission` ≥ WRITE · the **sub-issues API** answers for this repo · the `epic` / `autofill` / `blocked` labels exist · `FLEET_BASE_BRANCH` is the repo's real trunk (#603) · what *done* means here (`FLEET_DEPLOY_REF` / `FLEET_DEPLOY_CHECK`, #541, neither ⇒ merged ≡ done) · the effective concurrent-session cap, stated only — it is the operator's setting, never warned about or advised on (#881) · how many pool accounts sit under `FLEET_ACCOUNT_CEILING`. Three-way verdict so the caller can branch: **0 READY · 1 FIXABLE · 3 BLOCKED** (2 = usage). It exists to put "this repo can't do that" in front of the operator during planning, while they are awake — not at 03:00 when the batch is half-spawned. **Read-only by default**: `--fix` is the only writing path and it writes exactly one thing, `fleet-labels-seed.sh` against this repo — opt-in because seeding is not surgical (it reconciles the WHOLE canonical set, and a team repo sprouting a dozen unexplained labels overnight is how you lose the room). `--session <fleet>` preflights ANOTHER fleet — repo **and** conf knobs together, so the screen never describes two fleets at once; a bare `--repo` that disagrees with the loaded conf says so on its own line. `bin/fleet-epic-preflight-selftest.sh` pins all three verdicts on a faked `gh` | gh (authed) |
| Collector daemon | git/gh/usage/issues caches every ~60s. Since issue #551: **one tick at a time** (`global/collect.pid`; a previous tick older than `FLEET_COLLECT_DEADLINE`, 600s, is killed + superseded — a tick wedged on an un-timeboxed `gh` used to block every later phase for hours) and a **per-phase heartbeat** (`global/collect.heartbeat`: phase, per-phase seconds, end/dur — `fleet-doctor.sh` prints the last tick's age, duration and slowest phase). It runs the quota watch (next row) first thing, before any gh work. Since issue #636 its heartbeat is also an **alarm + self-heal**: launchd can PEND this unit indefinitely (103 min observed on 2026-09-14 — `state = not running`, `pended nondemand spawn = interval`, `last exit code = 0`), which does not empty the dash, it FREEZES it. A stale heartbeat raises `✖ dash · stale · 47m` (counted on the status bar, listed by `prefix !`) and self-heals; since issue #639 that threshold is **relative to this unit's own 60s interval** (`FLEET_DAEMON_STALE_MULT` × 60 = 300s, `FLEET_COLLECT_STALE` overrides absolutely) because the absolute 600s default read `fresh` through a collector that was running once per 7–14 min. The kick itself moved to the next row | gh, python3 |
| Interval-daemon watch + self-heal (issue #639) | **Every** `StartInterval` unit, not just the collector: launchd was observed to stop scheduling the whole user domain at once (all seven logs freezing inside the same two minutes; over 27.8 min `collect` got 3 runs of ~28 due and `cleanup`/`dispatch`/`base-sync`/`issue-bridge`/`ledger-watch`/`quotawatch` got **zero**, while the two KeepAlive units never missed a frame). Nothing errors, so nothing shows: workers stop being reaped, autofill stops, the base stops fast-forwarding, `fleet-comment.sh --to-worker` silently reaches nobody. Each daemon now stamps `global/<unit>.tick` at the top of its script, `bin/fleet-daemon-watch.sh` judges it against **`FLEET_DAEMON_STALE_MULT` × that unit's own `StartInterval`** (floored at `FLEET_DAEMON_STALE_FLOOR`), and `✖ daemon · stale · 4 units` is raised (counted on the status bar, the unit names in its `prefix !` row) + a per-unit `WARN daemons` in `fleet-doctor.sh`. Self-heal runs from the **KeepAlive spinner** — an interval unit is pended right alongside its patient — one `kickstart -k` per unit per cooldown (which SCALES with that unit's own interval since #711 — a flat 600s made the 15s units ten-minute daemons whenever kicking was the only execution path left), never against a unit whose tick is `running` (that would abort working work), escalating to a real `bootout`+`bootstrap` after `FLEET_DAEMON_RELOAD_AFTER` ineffective kicks, because **a kickstart buys one execution, not restored scheduling**. A unit found not loaded at all but with its plist on disk is bootstrapped back. History in `logs/daemon-kick.log`; `bin/fleet-daemon-watch.sh --status` prints the whole table | launchctl / systemctl |
| launchd **domain** probe (issue #711) | The rung above the per-unit ladder. On 2026-09-15 the whole `gui/501` domain stopped spawning jobs on one machine: nine of nine interval units frozen, and a throwaway agent bootstrapped beside them (different label, `ProcessType=Standard`, a one-line `/bin/sh`) never ran once — not even its `RunAtLoad`. The same install at the same commit ticked normally on the other host, so the fault is the MACHINE, and the remedy is a log out or a reboot. What the fleet owes the operator there is not nine "nothing is scheduling com.claude-fleet.`<x>`" lines — nine true statements that add up to "your daemons are broken" and send them to read plists. `bin/fleet-launchd-probe.sh` settles it in ~40s by counting how often launchd runs that throwaway agent (`ok` ≥2 · `no-interval` =1 · `no-spawn` =0 · `unknown` = not measured, never a verdict), and `fleet-doctor.sh` collapses the N unit lines into ONE that names the machine. It probes only on the domain signature — several units stalled at once, **or** several kicked inside the last hour, which is the signal that survives a working self-heal (measured on the wedged host: 1 overdue, 9 kicked in two minutes). The probe's deadline lives inside the job, not the parent's trap (#697): what leaks here is a registered LaunchAgent. Verdict cached for `FLEET_LAUNCHD_PROBE_TTL`; `--cached` reads it without re-probing | launchctl |
| Quota-watch daemon (recommended with a ccquota hub) | `com.claude-fleet.quotawatch` (`bin/fleet-quotawatch.sh`, 60s; issue #551): the ccquota-driven **pre-emptive account rotation** (warn every session on an account at `FLEET_ACCOUNT_WARN_PCT`, bench + `migrate --account` at `FLEET_ACCOUNT_CEILING` — issue #513) on its **own** tick, decoupled from the collector's gh/git/python phases. It used to be the LAST block of the collector tick, so a slow or wedged tick starved it: on 2026-09-11 the cache went 2.5h stale, neither branch fired, and 21 sessions rode a 5h window to 100%. Now: own 60s unit + a CONDITIONAL fallback at the TOP of the collector tick (issue #671) — the collector runs it only while this unit is not demonstrably ticking (`global/<root>/quotawatch.tick`, the #639 scheduling stamp, older than `FLEET_DAEMON_STALE_MULT × 60s` floored at 180s, or absent), so an install whose daemon set predates #551 still watches at the collector's cadence while a healthy one pays ~0 instead of the measured 3-57s a tick the unconditional call cost; it cannot flap because `--caller collect` is the one caller that does not write that stamp, and `FLEET_COLLECT_QUOTAWATCH=always|never` forces the old behaviour or switches the fallback off; `mkdir` lock against overlap; `global/quotawatch.heartbeat`; and a **staleness alarm** — `account.quota.ts` older than `FLEET_ACCOUNT_QUOTA_STALE` (600s) with a pool + hub configured shows `✖ quota · stale · 47m` (counted as `✖ N` on the status bar, listed by `prefix !`) on the status bar, FAILs in `fleet-doctor.sh`, and the next tick that runs notifies once (`FLEET_NOTIFY_CMD`) how long the watch was blind — plus, since issue #684, its twin: a cache that is FRESH but EMPTY (the fetch restamps even when it brought nothing back, so zero rows read as healthy) raises `✖ quota · unreadable · 6m` (counted as `✖ N`, listed by `prefix !`) / a `qwatch` FAIL / one notify after `FLEET_ACCOUNT_QUOTA_BLIND_STREAK` (3) consecutive empty reads. `--status` / `--dry-run` for scripts and rehearsal. No-op without `FLEET_ACCOUNTS_DIR` tokens + `CCQUOTA_HUB_URL` — **and equally a no-op without the `ccquota` binary**, which nothing here ships and no package manager carries: get it in step 6 | ccquota (see step 6), python3 |
| PR-status refresher (recommended) | `com.claude-fleet.pr-refresh` (~15s): owns PR/CI state (`prmap` + window `@prci`/`@pfg`) on a fast tick so CI-green/merged shows within ~15s instead of riding the 60s collector; single writer, no collector race (`FLEET_PR_REFRESH_INTERVAL`). Also probes whether a MERGED PR is actually **live** (issue #541) for a fleet that sets `FLEET_DEPLOY_REF` (a local checkout that is the deployment — zero network) or `FLEET_DEPLOY_CHECK=actions` (post-merge runs); the dash PR cell then reads `live` / `deploy…` / `deploy✗` instead of `merged` | gh |
| Disk guard daemon (recommended) | disk circuit-breaker + runaway-writer forensics; stops a full disk from crashing a fleet's tmux server (each fleet has its OWN socket now — issue #159 — but a full volume still ENOSPCs every server on it). Its `--watch` tick also runs a **runaway-CPU watchdog** (issue #151): our-user, no-controlling-tty processes held ≥`FLEET_RUNAWAY_CPU_PCT`% for ≥`FLEET_RUNAWAY_CPU_SECS`s → forensic incident + notify, optionally SIGTERM/KILL (`FLEET_RUNAWAY_CPU_ACTION`). Protects each tmux server from a detached orphan spinning a core; the server + launchd/systemd are excluded, live worker panes have a tty so are never touched. OFF by default (`PCT=0`) | — |
| Memory guard daemon (recommended) | `com.claude-fleet.memguard` (`bin/fleet-memguard.sh --daemon`, KeepAlive like the spinner, `ProcessType=Standard`; issue #1292, EPIC #1291): **a session's command whose memory explodes is stopped within seconds; a long-lived orphan holding memory is reported the same day.** 2026-10-03 a `git` went from nothing to ~40 GB in two seconds and froze + rebooted the Mac mini with every session on it, beside three headless-browser orphans holding ~50 GB for five days — the diskguard tick (60s) cannot see a 2-second spike, so this samples every 2s with ONE `ps` (`fleet_proc_mem_rows`, ~40ms). Only OUR processes (a command an agent or a named-socket fleet pane started, or a `PPID=1` orphan whose cwd is a fleet anchor). **A spike** — RSS +`FLEET_MEM_SPIKE_GROW_MB` (4096) within `FLEET_MEM_SPIKE_WINDOW` (10s) **and** `fleet_mem_probe` at warn/critical **and** not claude/codex nor `FLEET_MEM_EXEMPT_RE` — is SIGKILLed (that one pid; its shell sees exit 137; `FLEET_MEM_SPIKE_ACTION=report` only reports). **A hard ceiling**: a fleet non-agent process at ≥`FLEET_MEM_PROC_HARD_PCT` (50) % of RAM is killed whatever the pressure. A claude/codex session is never killed — only recorded. **Orphans**: `PPID=1` + fleet cwd + >`FLEET_MEM_ORPHAN_MB` (2048) + >`FLEET_MEM_ORPHAN_SECS` (6h) → `FLEET_MEM_ORPHAN_ACTION` (default `report`). **A fat session** (issue #1297): a claude/codex session at ≥`FLEET_CLAUDE_RSS_WARN_MB` (4096) RSS gets `@claude_mem_warn` on its window (dash row `⚠ mem 4.3G`, cleared under 90% of the line) and one notification naming it with the `fleet-peer-send.sh … /fleet-handoff` line — never an automatic restart. A kill stamps the pane's window `@mem_killed` (dash row `⚠ mem·137`, cleared after an hour), sends one `FLEET_NOTIFY_CMD` per process, and writes `diskguard/incident-mem-*.log`. `bin/fleet-memguard.sh --once --dry-run` prints today's candidates and the action each would get (plus diskguard's CPU orphans, whose `--orphans` list now carries RSS). It stamps `memguard.tick`, so `fleet-daemon-watch.sh` heals a wedged loop; it re-execs itself when install-sync rewrites the script. `FLEET_MEMGUARD=0` idles it | none (bash, ps, lsof) |
| Credential proxy daemon (off until `FLEET_CRED_PROXY=1`) | `com.claude-fleet.cred-proxy` (`bin/fleet-cred-proxy.sh run`, KeepAlive, `ProcessType=Standard`; issue #1970, EPIC #1967 C3): **this login's one credential proxy — a session holds a session credential (`fcp1.` / the hub's `fcp-h1.`) and talks to `127.0.0.1:<port>`, the proxy puts the subscription credential in on the way out.** It picks the route from the hub's record of this machine's trust (`GET /v1/node/self`, refreshed every `FLEET_CRED_PROXY_TRUST_SECS`=300, cached in `trust.json`; no hub = trusted, no answer and nothing cached = untrusted) × the last `fleet-node-probe.sh` result: `direct` (trusted + reachable), `relay` (trusted + unreachable: `FLEET_CRED_RELAY_URL` + `X-Fleet-Relay` — the pass `fleet-relay-cred.sh` mints for this login and the launcher keeps alive, issue #1974, [`docs/CRED-RELAY.md`](CRED-RELAY.md); a `FLEET_CRED_RELAY_TOKEN` in secrets.env overrides it), `central` (untrusted: no credential file is read; the session's hub credential goes to `FLEET_CRED_CENTRAL_URL`, default the hub). A region 403 or a connection that never opens moves that session to the next route and retries the request (`route_switch` in `logs/cred-proxy.log`, every credential `<redacted:len>`). State in `$FLEET_CONF_DIR/cred-proxy/` — `port` (kept across restarts), `ctl.sock` (0600: `fleet-cred-proxy.sh route|mint|rebind|revoke|attach|status --ctl`). With the switch off (the default) the launcher runs no proxy — it re-reads the config once a minute (USR1 makes it re-read now); a client-only computer starts it with `fleet-cred-proxy.sh ensure`. **The switch is one command** (issue #2134): `fleet cred-proxy enable [--relay-url <url>] [--all-logins]` writes `FLEET_CRED_PROXY=1` into fleet.conf `[common]`, makes sure this daemon is installed and running, refreshes the relay pass and prints the doctor's `cred` row; `fleet cred-proxy disable [--all-logins]` puts each line back byte for byte; `fleet cred-proxy status [--all-logins]` is one line, `on|off · <route> · sessions n/m` (`bin/fleet-cred-rollout.sh`; other logins via `fleet-sync-logins.sh --cred-proxy <verb>`; sessions already running keep their wiring). `bin/fleet-cred-proxy-selftest.sh` drives all three routes on loopback | none (python3) |
| Autofill dispatcher (optional) | `com.claude-fleet.dispatch` (`bin/fleet-dispatch.sh`, ~60s; issues #70, #421): auto-spawns the highest-priority eligible backlog issue whenever both caps have headroom — automating the "file → hold for cap → spawn when a slot frees" loop. **Opt-in per issue**: only issues carrying the canonical `autofill` label are eligible (you tag exactly which issues may fill idle slots hands-off, like `autoland` for landing), so it never touches the whole backlog. Eligible = open, unassigned, `autofill`-labelled, no live `issue-<N>` window bound, not `blocked`. Priority = the `priority:pN` tier (p0 first), then FIFO by issue number. Single-writer per repo (lease) + disk-gated + rate-limited (`FLEET_AUTOFILL_MAX_PER_TICK`). OFF by default — a two-key gate: the fleet armed (`FLEET_AUTOFILL=1`) **and** the issue labelled; spends LLM tokens (one real Claude session + PR per spawn). `--dry-run` prints intended spawns without spawning | gh |
| Seed repo (new logins) | `fleet-up.sh --seed` (issue #1167): a new login's fleet comes up on a starter repo so it works from minute one, and that repo only LOOKS — the conf gets `FLEET_SEED=1` + `FLEET_AUTOFILL=0` + `FLEET_ISSUE_BRIDGE=0`, and the dispatcher + issue-bridge skip a `FLEET_SEED=1` repo whatever its switches say, so the new login never claims or relays work on a repo it can't write to (and another fleet watches). Marks the fleet conf's OWN repo only (repo-scoped; a repo added later is the login's own); `fleet-doctor` prints a `seed` INFO line. **Taking the starter out** (issue #1172): once the login hosts a repo of its own, `fleet-repo.sh remove <seed>` promotes another hosted repo (`--promote <owner/repo>`, else the first) into the conf's own slot, drops the seed keys, and — when that was the last overlay — folds it in and removes `repos/`, so the conf is byte for byte what `fleet-up <repo>` writes (`bin/fleet-seed-selftest.sh` asserts it); the `guide` scratch that prompts it keeps running (a scratch of the seed never blocks; an issue-bound window does, without `--force`). A non-seed conf repo stays non-removable. Default: unset = an ordinary repo, and a fleet-up without `--seed` writes the conf byte for byte as before | — |
| Issue-bridge (optional) | `com.claude-fleet.issue-bridge` (~15s poll, or a webhook via `--deliver`+HMAC): relays a trusted issue comment INTO the bound worker as its next turn — the issue thread becomes the operator↔worker↔collaborator channel (replaces flaky send-keys). Single shared instance. Loop-safe via the `<!-- fleet:no-relay -->` marker (`bin/fleet-comment.sh`); gated by `author_association` (relayed comment = RCE on a bypass-perms worker); idle-gated; deduped. OFF by default (`FLEET_ISSUE_BRIDGE=1` per fleet); spends LLM tokens. See docs/ISSUE-BRIDGE.md | gh (+ python3 for `--deliver`) |
| Cleanup (recommended) | **CLEANUP NEVER MERGES — it cleans up after merges** (issue #277, closes #260), whoever made them. The worker's `/fleet-claim` ship+land step opens the PR, polls `bin/fleet-pr-verdict.sh <PR>` and squash-merges it itself on `READY` (`FLEET_MERGE_METHOD`, default `squash`; issues #283, #441) — branch protection still decides what's mergeable, and a `BLOCKED` verdict stops the worker. A human on the web or a collaborator merging instead changes nothing downstream. `com.claude-fleet.cleanup` (`bin/fleet-cleanup-daemon.sh`, ~60s) then scans the `prmap` cache pr-refresh already writes (`--state all` ⇒ MERGED/CLOSED rows, ZERO extra `gh`) for a final PR whose `issue-<N>` still has a live worktree/window and drives `bin/fleet-cleanup.sh <PR>` — the mechanical, **no-merge** janitor (`fleet-land.sh` MINUS the merge): record the resume ledger FIRST, `git pull --ff-only` the base under the shared land-lease (`bin/fleet-land-lease.sh`, base-ff serialization), then ordered teardown window → worktree → branch — where the worktree is **dropped**, not deleted: `fleet_worktree_drop` renames it into a sibling `.fleet-trash/` and prunes the registry (O(1)), and the daemon deletes the bytes at tick start under `FLEET_TRASH_SWEEP_BUDGET` seconds (default 20), before the disk gate (issue #586 — a 308k-file `node_modules` worktree once held one teardown, and every fleet's reaping behind it, for 67 minutes). Merge-source-agnostic, idempotent (`skip:nothing` on an already-reaped PR). Single-writer per repo + disk-gated. **ON by default** (opt out `FLEET_CLEANUP=0`; merges nothing, relaxes no gate). Manual now: `/fleet-cleanup <n>`. See docs/CLEANUP.md | gh |
| Ledger-watch (recommended) | `com.claude-fleet.ledger-watch` (`bin/fleet-ledger-watch.sh`, ~60s; issue #320): records EVERY closed worker session into the history ledger, not just landed ones. The cleanup daemon records a session only when it LANDS, so a worker window closed by hand / crashed / abandoned left its transcript UNINDEXED (invisible to `/fleet-history`, not resumable). It can't inspect a window after it's gone, so it **snapshot-diffs**: each tick it snapshots the live issue-bound worker windows (keyed by ISSUE — `/fleet-handoff` cycles the session-id in place, so keying on the issue avoids a spurious row per handoff; `@raw` scratch + panels excluded) and diffs vs the durable prior snapshot; a worker whose window VANISHED and isn't already in the ledger gets one `closed-unlanded` row (`bin/fleet-history.sh record-closed`, **idempotent** — dedups on session-id so a landed session is never double-recorded). Its worktree usually still exists (worktree-autoclean keeps unmerged), so resume just reuses it. Pure tmux snapshot + a local ledger append (no `gh`, no LLM), **records only** (never reaps), single-writer per repo + disk-gated. **ON by default** (opt out `FLEET_LEDGER_WATCH=0`); spends no tokens. `--dry-run` prints intent. A whole-fleet crash is handled by fleet-restore (`--if-down`), so this targets a single window vanishing while its fleet stays up. See docs/CLEANUP.md | — |
| Close-on-exit hook | `bin/session-end-hook.sh` wired to the Claude Code **`SessionEnd`** hook (issue #403): the **event-driven twin of ledger-watch**. On a MANUAL worker exit (Ctrl-D / `/exit` / logout) it reacts AT EXIT instead of waiting the ~60s poll — closes the tmux window, applies the SHARED reap gate (`fleet_reap_ok`) and acts on the worktree by verdict (merged-pr → reap wt+branch + close issue + `landed` row; ancestor → reap wt+branch + `closed-unlanded` row, issue kept open; committed-but-unmerged / dirty → KEEP the worktree + issue + `closed-unlanded` row), and records the `/fleet-history` row NOW via the shared `fleet_reap_record` so the session is indexed + resumable at once. SessionEnd runs INSIDE the dying pane, so the gate+reap+close run in a DETACHED `tmux run-shell -b` job (server-side) that survives the pane vanishing (mirrors `dash-reap.sh`'s `--exec`). `/clear` + every `/fleet-handoff` cycle (`reason=clear`/`resume`) is a NO-OP — only `prompt_input_exit`/`logout` act (the `matcher` pre-filters). Scoped to issue-bound workers (+ `@raw` scratch → window-close only); panels + the hub pane are never touched. Reacts, never blocks; idempotent vs the cleanup daemon / ledger-watch (one row, one close). **ON by default, globally** — the `SessionEnd` wiring below is merged at install, so it works out of the box; set `FLEET_CLOSE_ON_EXIT=0` in the **global** `fleet.conf` to disable machine-wide (global-authoritative — a per-fleet value is ignored). Spends no tokens. See docs/CLEANUP.md | — |
| Base-sync (recommended) | `com.claude-fleet.base-sync` (`bin/fleet-base-sync.sh`, ~60s; issue #327): keeps the LOCAL base checkout (`$FLEET_MAIN`) fast-forwarded to the remote default branch, **independent of merges**. Today the base only advances as a side-effect of the cleanup daemon reaping a merged PR (`bin/fleet-cleanup.sh` does the `git pull --ff-only`), so a merge with **no local reap** — a PR merged on the web, a commit from another machine/contributor, a **direct push** to the default branch — never triggers a base pull and the local base **silently lags** the remote until the next merge that does have a worktree; fresh worktrees + `cw` then branch off a **stale** base. This daemon runs the EXACT same ff-only pull the cleaner does, just on the clock: each tick, one base-mover **per repo** (deduped on the resolved base path, not per fleet) takes the **shared land lease** (`bin/fleet-land-lease.sh`, `land-<slug>.lock` — the SAME lock every base-mover holds, so **no new race** with the cleaner) **non-blocking** (busy ⇒ another base-mover has it ⇒ skip) and runs `git fetch` + `git pull --ff-only` on `$FLEET_MAIN`. `--ff-only` is the whole safety story: a diverged base (a stray local commit) makes the pull refuse — surfaced once (*"base checkout would not fast-forward — resolve by hand"*), never merged/rebased/forced. **Base only** — never touches worktrees/windows/branches/issues/PRs; needs no tmux (just `git` + the lease). An already-current base is a cheap no-op, so a quiet repo costs one `fetch`/tick, no `gh`, no LLM. Single-writer per repo + disk-gated. **ON by default** (opt out `FLEET_BASE_SYNC=0`); spends no tokens. `--dry-run` prints `would ff $MAIN <old>..<new>` without moving. See docs/CLEANUP.md | — |
| Install-sync (recommended) | `com.claude-fleet.install-sync` (`bin/fleet-install-sync.sh`, every 30 min; issue #1120, EPIC #1117): **each login follows `refs/tags/stable` by itself.** Merging to master never reached any machine — someone had to remember `/fleet-sync-install` as EACH login, and on 2026-09-24 four of the Mac mini's five logins sat 60–265 commits behind with every daemon green. Each tick fetches the tag over https (no credentials, bounded by `FLEET_INSTALL_SYNC_TIMEOUT`, 30s — a failed fetch is *not seen*, never a refusal or an alarm), then: HEAD == stable → `current`; stable not a **descendant** of HEAD (a backward move, or a hand sync pushed HEAD past it) → `refused`, it only ever fast-forwards; **tracked** local changes → `refused`, an edited install is never touched; the disk gate closed → `deferred`, with `deferred_since` kept so the doctor can say how long; else **a whole-version switch** (issue #1894): `~/.claude/fleet` is a LINK to `~/.claude/fleet.versions/<sha>/` (a git worktree per version, on branch `fleet-live/<sha>` tracking the trunk), the new version is checked out beside the old one, checked (every `bin/*.sh` parses, every `bin/` + `hooks/` `*.py` compiles — a broken one is `rolled-back` with nothing switched), and the link moved in ONE rename(2) — a script already running keeps the files it opened, the next call reads the new version, so **busy windows and a running EPIC batch no longer hold it back** (on 2026-10-06 the busiest machine sat 9h+ behind waiting for idle) — → the NEW version's `bin/fleet-install-apply.sh` (C2, #1119 — the one implementation of "sync once") → the NEW version's `bin/fleet-doctor.sh`; result `switched`. `logs/`, `epic-pages/` and whatever else is untracked at the top level live once in `fleet.versions/.shared/`, linked into each version; `fleet.versions/.prev` names the version before the last switch; a retired version is kept `FLEET_INSTALL_VERSIONS_KEEP_SECS` (7 days) for sessions still running from it; the checkout that was the install before the first switch holds the repository and is never removed. **Migration** is the first switch itself: a plain-directory install is moved to `fleet.versions/<its HEAD>/` and the link put in its place. A **FAIL line the pre-update doctor did not print** (WARNs never count; a FAIL the login already had is not the new version's) → the link back to the previous version (`.prev` then names the rejected one) + the OLD version's apply, and `skip: <sha>` so that version is **not retried until stable moves** — no flapping. A tick that turns **stuck** — `refused`, `rolled-back`, or `deferred` (the disk gate) longer than `FLEET_INSTALL_FOLLOW_STUCK_SECS` (24h; the doctor's own STUCK) — sends **one** `FLEET_NOTIFY_CMD` message (R4, #1125; the channel quotawatch / diskguard use), deduped on login + reason + stable (`notified:` in the state) and re-armed once the login follows again, so a login that sticks on the days nobody runs the doctor is heard on the first day and not every 30 min; a failed fetch never alarms, `FLEET_INSTALL_SYNC=0` silences it. State for the doctor (C7, #1123): `$FLEET_CONF_DIR/global/install-sync.state` (`result` · `head` · `stable` · `from` · `to` · `reason` · `deferred_since` · `skip` · `apply` · `notified` · `notified_at`); log `logs/install-sync.log`, one line per tick plus a `notified` line per message sent. It is installed by the very apply step it drives (an added template is installed + loaded), in the shape this login's daemons already have (gui LaunchAgent, or system LaunchDaemon + `UserName`). **ON by default per login** (opt out `FLEET_INSTALL_SYNC=0` — tell a colleague whose login you share the machine with); spends no tokens. **The node agent follows too** (issue #1723): a tick that ends `current` or `switched` asks `bin/fleet-node-upgrade.sh <stable> --dry-run` which logins' ccquota agent is not `prod-<stable short>` (on disk, or as the hub sees it) and upgrades them with `--dist --rollback` — the hub's `/v1/node/dist` binary first (SHA-256 + version checked), a local build else; one login at a time, each confirmed on the hub, a login that never comes back restored to its `.prev`. A LaunchDaemon login needs `sudo -n`, so the admin login's tick upgrades every behind login (its own first) and the others record `delegated`; the agent half still waits for idle (no busy window, no EPIC batch) — an agent restart is felt by every session. A failure is `node_upgrade_failed`: one `FLEET_NOTIFY_CMD` per (login, stable), no retry of that stable for `FLEET_NODE_FOLLOW_RETRY_SECS` (6h). State keys `node` · `node_reason` · `node_failed_at` · `node_fail_stable` · `node_notified`; opt out `FLEET_NODE_FOLLOW=0`. `--dry-run` prints the move without making it; `--status` prints the state | — |
| Webhook daemon (optional) | `com.claude-fleet.webhook` (`bin/fleet-webhook.sh`, KeepAlive supervisor like the spinner): **fresh (~1s) PR/issue/CI status via `gh webhook forward`, with NO public endpoint** (issue #315). GitHub's only real-time push is webhooks (normally need a public URL); `gh webhook forward` (the `cli/gh-webhook` extension) registers the repo webhook against **GitHub's own hosted relay**, PULLS deliveries over the authenticated `gh` token, and re-POSTs each to a **localhost** handler — no ngrok/tunnel, no exposed port. The daemon runs one python3 handler on `127.0.0.1:<port>` + one `gh webhook forward` per opted-in **live** fleet repo (fanned out like the watcher, deduped per repo, dead forwards auto-restarted). Each delivery only **TRIGGERS a targeted refresh** — it never writes a cache: `pull_request`/`check_*`/`status` → `tmux-pr-refresh.sh --repo <repo>` (the single writer of `prmap`/`@prci`), `issues` → `tmux-dash-collect.sh --issues <repo>` (the collector owns `issues_<slug>`), routed by the repo in the payload. **Polling stays the backstop** (pr-refresh ~15s + collector ~60s), so a missed delivery/dead forward only costs freshness, never correctness. Storm-coalesced (per-`(event,repo)` debounce). Optional HMAC (`FLEET_WEBHOOK_SECRET` → `--secret` + verify) is defense-in-depth only (handler binds localhost). OFF by default (`FLEET_WEBHOOK=1` per fleet); spends no LLM tokens. See docs/WEBHOOK.md | gh + python3 + `gh extension install cli/gh-webhook` |
| Lifecycle emitter (optional, issue #625) | `bin/fleet-emit.sh` — an **off-by-default** outbound channel that POSTs four session lifecycle facts to `FLEET_EMIT_URL` (bearer `FLEET_EMIT_TOKEN`; both per-fleet, so two fleets can report to different endpoints). It exists because the fleet is the ONLY component that knows what a session was **for** — it binds a session to an issue, gives it a worktree, and watches the PR — while a usage ledger downstream knows only what each session **cost**, keyed by session id. The join is one field. `session.start` (SessionStart hook — every source, so a `/fleet-handoff` cycle's new session id still maps to the issue), `session.bind` (`bin/fleet-bind.sh` — without it every scratch that turned into real work is attributed to nothing), `session.pr` (a **diff** of the prmap `bin/tmux-pr-refresh.sh` already rewrites — no second poller; a cold prmap seeds silently), `session.end` (twice over, discriminated by `via`: the SessionEnd hook knows the Claude session id + `reason`, `fleet_reap_record` knows the outcome — `landed`/`closed-unlanded` — and is the one choke point EVERY reaper funnels through). Hangs off the EXISTING hook paths, never a second source of truth for session state. **Unset ⇒ nothing happens at all**: no spool dir, no file, no socket, no behaviour change. What is sent is an enforced allowlist — event, timestamp, fleet session name, Claude session id, repo, issue, PR, branch, outcome words — and **nothing else**: no prompt or transcript content, no file paths, no issue/window titles, no hostname or username (identity rides the token). Every value passes a per-field charset filter, which is the privacy rail and the JSON-injection rail at once (`bin/fleet-emit-selftest.sh` asserts both, plus that the delivered object has only allowlisted keys). Fire-and-forget: one file per event into a bounded spool (`FLEET_EMIT_QUEUE_MAX`, default 500, drops the OLDEST on overflow), then a DETACHED drain with a hard curl timeout — a dead endpoint is a silent no-op, never a stalled worker, and nothing retries in the foreground; a 4xx is permanent so one bad event can't wedge the queue. `fleet-doctor.sh` prints an `emit` line (and flags a spool that stopped draining — otherwise invisible). Spends no LLM tokens. See docs/EMIT.md | curl |
| Fleet Hub (optional) | `bin/fleet-hub.py` — an **off-by-default** MCP endpoint that drives Fleets on SEVERAL machines through one connection, for an authorized Agent rather than a human at a dash. Nodes answer a fixed JSON control entry point (`bin/fleet-control.py rpc`) over the administrator's own SSH config; they open no new listener and need no MCP package. The Hub keeps the registry (persistent machine UUID + UUID5 Fleet ids, so a name collision across machines is not one), expiring per-caller grants (ONE per Agent and purpose, #833 — `grant` defaults to read-only for 24h, `principals` lists every grant with its scopes and last call, `revoke` takes one principal), an operation journal and an audit trail in `~/.config/claude-fleet/hub`. Thirteen tools — `fleet_list` / `fleet_status` / `config_get` / `worker_start` / `worker_message` / `worker_stop` / `worker_resume` / `config_set` / `operation_get`, plus `gh_issue_view` / `gh_pr_view` / `gh_pr_checks` / `gh_comment` (#1274: GitHub through the node's local copy + write queue, behind `gh:read` / `gh:comment`); the three lifecycle tools address a worker by its durable `worker_id` (`<fleet UUID>/issue-<N>`, issue #834), re-resolved on the fleet at action time, each behind its own scope — and no shell, no raw tmux, no arbitrary path, no `--force`, no registration or granting: those stay administrator CLI. Every call re-checks the live grant, so a visible tool is not an authorization decision. Writes are recorded before they are sent, deduped per caller by idempotency key, and an unconfirmed one stays `unknown` rather than replaying. Config writes are three integer keys (`FLEET_MAX_SESSIONS`, `FLEET_AUTOFILL`, `FLEET_AUTOFILL_MAX_PER_TICK`) behind a compare-and-set on the Fleet overlay, through the SAME kernel-held lock + atomic writer the dash `prefix+c` modal uses. `worker_start` reuses `dash-issue-session.sh`, so capacity/claim/disk/quota gates all still apply. Nodes keep running their workers if the Hub goes down. `bin/fleet-hub-service.py install` adds a KeepAlive `com.claude-fleet.hub` LaunchAgent on loopback behind an HTTPS proxy (Tailscale Serve, no Funnel) with `--auth grant-token`; an OAuth JWT resource-server mode exists but advertises no authorization server. Spends no LLM tokens by itself — `worker_start` spawns a real session. See docs/FLEET-HUB.md | python3 + `pip install -r requirements-mcp.txt` (Hub only) |
| Classifier (optional) | Stop-hook does real-time single-window state fix (detects `looping`), plus the spinner's stuck-`working` demote kicks it for a window a Stop missed. It only refines `done`/`needs`/`looping` (trusts the hook for `working`) — so a window stuck at `working` from a missed Stop is handled upstream by the spinner's demote check, which flips it to `done` and then kicks the classifier to refine it | `claude` CLI |
| Worktree janitor (optional) | prunes merged+clean+idle worktrees. Before each removal it **reaps any process still anchored to the worktree** (`fleet_reap_worktree_procs` — argv match + cwd match, SIGTERM→SIGKILL; issue #151) so a detached orphan can't outlive its dir and drain a core against the shared tmux server. The dash's `⌃x` reap (`dash-reap.sh`) does the same. It never kills a process running under a **live tmux pane**, and it skips a worktree that is mid **account rotation** or still running a pane's processes — the close→resume gap makes every tmux-metadata gate momentarily read a live worker as finished (issue #550; see docs/CLEANUP.md) | gh |
| Raw scratch session (dash `⌃s`) | opens a plain, **non-issue-bound** `claude` window in the fleet — no GitHub issue, but in its **own writable `scratch-N` git worktree** off the base branch (`bin/dash-raw-session.sh`, issues #214/#290). The counterpart to the issue-bound spawns (dash `⌃n` / backlog Enter / `dash-issue-session.sh`), for ad-hoc exploration or experiments that may need to WRITE code (the base checkout is hook-enforced read-only). A scratch that turns real just pushes its branch + opens a PR — the prmap is repo-wide, so the janitor reaps a merged `scratch-N` like any worker (zero new machinery), and the unique cwd makes its transcript resolvable. Spawns on the keystroke — **no name popup, no confirm** — with the slow half (fetch + worktree add + window launch) backgrounded so the dash never freezes; a name is still available off the dash via `--name`. The dash's always-visible **prompt line** is the NAMED variant (#534): **type a name, Enter** → the same scratch spawn with the text as the window name (`--name-file`, staged through a file — never interpolated; capped at 24 display columns, so Chinese and spaces are fine), with the full text prefilled at `❯` as an editable, **unsent draft** (the draft is not clipped to the window title). Cold spawns wait for the input to settle; warm-pool spawns prefill the ready input. A prefill never presses Enter or overwrites existing input. A SEEDED scratch is still available off the dash via `--prompt <text>` (e.g. a script seeding a `/fleet-handoff pickup`) — the text rides as `claude`'s launch argument, so a seeded scratch skips the warm pool. Marked `@raw=1` + `@worktree=<path>`, named `scratch-N` (or a custom name); **listed in the dash as a real session** (counts toward the session cap) but excluded from the issue machinery — no `@issue`, so the watcher (`@raw` skipped) leaves it alone, while the classifier still shows its state. The **window** is ephemeral (not snapshotted/restored across a crash); its **worktree** survives on disk and is reaped by the janitor's scratch rules — clean + no unmerged work → removed silently; dirty or unmerged → kept + surfaced once (never silently delete an experiment; `dash ⌃x` disposes it) | claude |
| Codex workers (optional, issue #547) | `FLEET_AGENT=codex` in a fleet's conf — or `--agent codex` on one `dash-issue-session.sh` / `dash-raw-session.sh` spawn (scripts; the dash prompt line has no agent prefix, issue #559) — makes the spawn launcher `bin/fleet-claude.sh` hand the session to **`bin/fleet-codex.sh`**, which execs **OpenAI Codex CLI** in the same `issue-<N>` worktree, claimed at spawn like any worker. Modern Codex reads native skills from `$CODEX_HOME/skills`, so `/fleet-sync-install` generates `$CODEX_HOME/skills/fleet-claim/SKILL.md` from `commands/fleet-claim.md` and the bare `/fleet-claim` seed is launched as `$fleet-claim`; older Codex builds, or a home not synced yet, still get the historic prose expansion from `conf/codex-preamble.md` + `commands/<name>.md`. The fleet's hooks ride inline as `-c hooks.<Event>=[…]` — Codex's hook system is Claude Code's schema (verified on 0.154: same events, same stdin JSON, exit 2 blocks, env inherited): PreToolUse `busy` + `bash-guard.py` (`Bash`) + `base-readonly-guard.py` (`apply_patch` — it parses the patch's `*** Add/Update/Delete File:` / `Move to:` targets), PostToolUse / UserPromptSubmit `working`, Stop `done` — so the dash colours a Codex window like a Claude one, and the two bypass-permissions rails hold. `CLAUDE.md` is read as the project doc (`project_doc_fallback_filenames`). Posture: `--dangerously-bypass-approvals-and-sandbox` (a bypassPermissions worker's footing; hooks are the rails) + `--dangerously-bypass-hook-trust` (the fleet vets its own hooks). Claude-only and skipped: `--model`/`FLEET_MODEL` (Codex uses `FLEET_CODEX_MODEL` → `-m`, else your `$CODEX_HOME/config.toml`) and Claude OAuth tokens; Codex has native user-input, MCP policy, subagent knobs, context reads, handoff transfer, account homes/quota selection, warm scratch support and close-on-exit via the launcher. `--resume`-shaped launches (restore, migrate) are always Claude unless the caller explicitly requests Codex. The window is stamped `@cc_agent codex` (dash tag `codex`). The dash prompt line shows the fleet's default for a NEW session (`claude ▸` / `codex ▸`, codex in the row-tag colour) and **⌃v** flips it — `FLEET_AGENT` written to the fleet's conf through the config-modal path, so every spawn path follows (`bin/dash-agent-toggle.sh` + `bin/dash-agent-prompt.sh`, issue #554; `bin/dash-agent-toggle-selftest.sh`). Every dash ⌃-key is resolved against your tmux `prefix`/`prefix2` at launch by **`bin/dash-keymap.sh`** (issue #556 — ⌃a was the operator's prefix, so tmux ate it): a colliding key moves to its ⌥ twin, the `?` sheet shows the key actually bound, and `fleet-doctor.sh` warns (`bin/dash-keymap-selftest.sh`). **One-time:** trust the base checkout in Codex (`codex` in `$FLEET_MAIN` → Yes) — a worktree inherits its main repo's trust; the launcher flags an untrusted base as `needs` instead of letting the pane stall on the prompt. Default fleets are byte-for-byte unchanged (`bin/fleet-codex-selftest.sh`) | `codex` 0.154+ (native skill detection is verified on 0.157; the rollout format fleet reads is verified for 0.154 — `fleet-doctor` `codex` row, issue #1079), logged in, base checkout trusted |
| `cw`/`cwrm`/`cwclean` | zsh worktree helpers | zsh |
| Login banner (optional) | `shell/fleet-intro.sh` — the SSH login intro (issues #1068, #1255): a phone-width (≤ 40 columns) header with this login's fleet and its repo count, the one `fleet` line to get in, any machine-local lines from `intro.d` hooks, and the hide hint. Conf files only — no tmux calls, no repo names, no running/stopped status (`fleet` opens the client either way), so one script serves every login. Called from `shell/fleet-login.zsh`, which `~/.zshrc` sources (step 7) | — |
| First-login bootstrap (new logins) | `bin/fleet-login-bootstrap.sh` (issue #1165) — a login opened by `fleet-login-new.sh` sets itself up: the one-time `~/.zshrc` block that script writes (`--print-zshrc`) runs it on the first interactive login until it has passed once. Steps, each skipped when done: clone at `refs/tags/stable` onto a `master` branch (or the clone `fleet-login-new.sh` already made as that login, #1192) → Claude Code when no `claude` is on PATH (the official native installer → `~/.local/bin/claude`, run as the login; `FLEET_CLAUDE_INSTALL_CMD` overrides it — issue #1191; `~/.local/bin` goes on the run's PATH first, so the tmux server `fleet-up` starts inherits it) → `reapply-tmux-attention.sh` → `fleet-install-apply.sh --from <empty tree> --to HEAD` (everything is an addition, so the one apply path installs it all; a login whose system LaunchDaemons `fleet-login-new.sh --apply` installed applies at once, any other macOS login waits for its first GUI sign-in) → the zshrc block, with the `~/.local/bin` PATH line (`--print-path-line`) before it → `fleet-up.sh <FLEET_SEED_REPO> --seed --no-attach` (default `verkyyi/claude-fleet`, the look-only starter, #1167) → `fleet-doctor.sh`. Done ⇔ `$FLEET_CONF_DIR/global/bootstrapped`; a login that already has a fleet it did not start is left byte-for-byte alone. No ccquota enroll (a hub admin's). `bin/fleet-login-bootstrap-selftest.sh` | git, zsh |
| 承载 — this computer also runs sessions | **`fleet host on`** (issue #1806, `bin/fleet-host.sh`) — the person's one switch: asks first, then (with a hub) `fleet node join` when this login is no node yet or has no fleet here, then `fleet node compute on`; without a hub, the fleet on this computer runs the sessions. Writes `FLEET_HOST=1` in `fleet.conf` (the old `FLEET_ROLE` is rewritten by `fleet-conf.sh migrate`, read one more version). `fleet host off` takes it back — and when `on` was what joined, the agent it started stops and `node.env` is put aside. `fleet doctor`'s `能力` row says which (`bin/fleet-host-selftest.sh`) | — |
| New machine in one command (hub-driven) | **`fleet node join`** (issue #1627) — no argument: the same scan as `fleet login` (hub from `fleet.conf`, the device key, the same page titled 「把 <机器名> 加为节点」), whose confirmation returns the node pass; then the steps below on their defaults, one `✓ …` line each, a failure one `✗ …` line — rerun the same command; `fleet node status` reads it back (`bin/fleet-node.sh`, `bin/fleet-node-selftest.sh`). The old form, kept one version: `bin/fleet-node-join.sh --hub <url> --token <fj_code>` (issue #1418) — run on a NEW machine as the login that will run the fleet; the hub's `/nodes` page mints the one-time, 10-minute join code and prints the whole `curl … \| bash -s --` line. Redeems the code into this login's own ccquota enrollment first, then installs git/tmux/gh/python3/zsh (apt/dnf/yum/apk via root or `sudo -n`; Homebrew on macOS), the agent from the hub's dist dir (SHA-256 checked) into `~/.local/bin/ccquota` with `~/.config/claude-fleet/node.env` (0600), supervises it (gui LaunchAgent / LaunchDaemon with UserName / systemd user or system unit / detached with a WARN), waits for `/v1/node/self` = online, then clones at `stable` and runs `fleet-login-bootstrap.sh` (above). The admin agent (`CCQUOTA_FLEET_ADMIN=1`, default; `--no-admin`) installs the hub's SSH user CA itself. See `tokenledger/README.md` → *A new machine in one command*. `bin/fleet-node-join-selftest.sh`; `.github/workflows/node-join.yml` proves it on a clean debian container | curl (the rest it installs) |
| Welcome letter (new logins) | `bin/fleet-login-new.sh` (issue #1195, EPIC #1212) ends by writing `~/<login>-onboard/welcome.txt` in the **admin's** home (mode 600; `--no-welcome` skips it; `--lang zh` — the default — or `en`): how to connect (`ssh -p <port> <login>@<host>`), an ssh-config snippet, the swap-the-key steps, that `ssh <machine>` opens `fleet` and what the guide does (`fleet guide`; no `cf`, issue #1711), and the steps still theirs (the Codex device code, `gh auth login`) — **never the password**. With no `--pubkey` it generates a **temporary** ed25519 pair into the same dir (comment `<login>-onboard-temp`), installs the public half and puts the private half in the letter — inline, because an attachment does not leave this machine's mail — so the person can connect before they ever sent a key and swaps it for their own on first login (the letter says how; `--no-welcome` without `--pubkey` is refused). The host and port are the two machine-wide conf keys **`FLEET_SSH_PUBLIC_HOST`** / **`FLEET_SSH_PUBLIC_PORT`** (`fleet.conf.example` → 身份/identity, `@scope=global`; resolved through `fleet-hook-conf.sh` — env → the install's `fleet.conf` → `~/.config/claude-fleet/fleet.settings` — so what `prefix+c` shows is what the letter says): unset host ⇒ a visible `<HOST>` placeholder in the letter and a WARN on the run; unset port ⇒ 22. Set them once per machine — your public SSH entry, e.g. `ssh.example.com` / `22022`. The admin sends the letter; the script mails nothing and never prints the key. `bin/fleet-login-new-selftest.sh` leg J. **Is that entry really open, and really this machine?** (issue #1196) — with a third key, **`FLEET_SSH_PROBE_HOST`** (an ssh alias on the far side of the internet, key auth, host key known), `fleet-doctor`'s `ingress` line asks the probe to `ssh-keyscan -p <port> <host>` and compares the ed25519 key with sshd's on 127.0.0.1: PASS = open and this host; WARN names a closed entry, one forwarded to another machine, or an unreachable probe (never FAIL); bounded per step (`FLEET_INGRESS_TIMEOUT`) and cached (`FLEET_INGRESS_TTL`, `global/ingress.probe`); unset ⇒ no line. docs/HOST.md#ingress; `bin/fleet-doctor-ingress-selftest.sh` | ssh-keygen, ssh + ssh-keyscan (ingress) |
| SSH opens the client (optional) | `shell/fleet-login.zsh` — the one `~/.zshrc` line for the login (issues #1166, #1711): shows the banner, then an interactive SSH login runs `bin/fleet` — the client, here reading this machine, never a direct attach to the node's session; detaching returns to the shell. Never in a non-interactive shell (scp / rsync / `ssh host cmd`), never inside tmux, never without `$SSH_TTY`. `~/.hushfleet` = no banner + no client; `~/.hushfleet-attach` = banner only. Opt-in: an existing `~/.zshrc` is never rewritten | zsh |
| Several repos per fleet (`bin/fleet-repo.sh`, issue #788/#795) | `fleet-repo.sh add <owner/repo> [<checkout>] [--base <b>]` registers another repo with a fleet (clone-or-reuse, overlay at `fleets/<sess>/repos/<slug>.conf`); from inside the fleet the dash's ⌃z / the sidebar menu's `g` open `dash-repo-add.sh`, a popup over the same `add` that asks only `owner/name` (#1103); `list` / `remove [--force]`; `fold <old-fleet> --into <fleet> [--dry-run] [--wait]` moves a whole one-repo fleet in and archives its conf (#796). Nothing to install and no switch to set — a fleet with no overlay behaves exactly as before. Once 2+ repos are hosted, the fleet picker gains repo rows, sessions carry `@repo` (the dash badges it; window names stay bare), and the hub opens in `$HOME`. Proven by `bin/multirepo-e2e-selftest.sh` | git (+ gh to clone) |
| Fleet commands (optional) | repo-shipped `/skill`s (`commands/`) — fleet-aware slash commands, appended to `~/.claude/commands/` | claude |
| Fleet skills (optional) | repo-shipped base **skills** (`skills/<name>/` dirs — SKILL.md plus any supporting files) a fleet command or the agent delegates to — e.g. `/fleet-handoff` runs the base `handoff` skill verbatim; `doc-preview` ships `share.sh`/`server.py`/`render.mjs` beside its SKILL.md (issues #311, #354) and serves in one of two modes — `https` (loopback server behind `tailscale serve`) or, for a login that is not the machine's one tailscale operator, `http-direct` (server bound on the tailscale IPv4, plain http, tailnet-only; issue #1093) — `fleet-doctor`'s `docprev` row says which this login gets and the one-time `sudo tailscale serve …` for HTTPS, `epic-page` ships the `template.html` both EPIC pages render into (issue #809); installed into `~/.claude/skills/` and mirrored into each known `$CODEX_HOME/skills/` whole-dir, marker-gated (`<!-- fleet skill -->` in the SKILL.md) so a personal skill is never clobbered | claude / codex |
| Status line (optional) | `conf/statusline.sh` — the Claude Code status line as the fleet's measurement bus (issue #1452): it prints nothing, and stamps the context % + window size (`@ctx_pct` / `@ctx_limit` / `@ctx_band` — the auto-handoff nudge, `fleet-context.sh`), the model + effort level (`@model` / `@effort`) and the account's rate limits (`@rl*`) onto the pane's tmux window on every render; the pane header shows `62% · Opus 5.5 · high` on its right from those stamps (`conf/tmux-attention.conf`). Wired **install-time only** by pointing `settings.json`'s `statusLine` at the **live-install** path `~/.claude/fleet/conf/statusline.sh`, so improvements flow through `land → /fleet-sync-install` with no copy step. jq-gated — inert without `jq`. NOT auto-wired on sync; opt-in per install (see step 8b). The fleet mod feeds the same script from inside the session (`--from mod`, issue #1459), so once every window carries the mod the key can be dropped — `bin/fleet-statusline.sh off`, step 8c — and the blank bottom row goes with it | jq (soft) |

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
   must not touch the network). On a machine shared by several logins, each
   with its own `~/.claude/fleet`, a `logins:` line reports the others' drift
   against this install, and `bin/fleet-sync-logins.sh` (`--dry-run` to preview)
   brings them to this commit, as each login, and restarts their daemons —
   `/fleet-sync-install` runs it as the apply's `--sync-logins` step (issues
   #1069, #1122), skipping a login that set `FLEET_INSTALL_SYNC=0` in its own
   settings unless it is named (`--logins <login>` / `--include-off`). Beside the
   sync it writes each reached login's `~/.config/claude-fleet/node.env` when a
   ccquota agent plist holds the token the file lacks (`bin/fleet-hub-node.sh env
   --write`, issue #1491) — without it that login's `ccquota lease|place|move`
   fall back silently; `fleet-doctor`'s `node` line says so. A login whose
   `~/.claude/fleet` is a file COPY (step 2's shape) cannot say which version it
   holds or update itself; `fleet-sync-logins.sh --to-git` turns it into a git
   clone at the commit it holds — origin = the public repo over https, no
   credentials — carrying `fleet.conf`, `logs/` and every local file across and
   keeping the old dir whole as `~/.claude/fleet.copy-<date>` (issue #1121).
   Since each login follows `refs/tags/stable` on its own (install-sync, #1120),
   the doctor's next two `install` rows say whether that is still happening
   (issue #1123): **this login** — `PASS … install-sync on — at stable <sha>`,
   or a `WARN` naming why it stopped (`refused` with the daemon's reason,
   `rolled-back` / `skipped` until stable moves, `deferred` for over a day, no
   tick yet, or a state older than a day) and the opt-out
   (`FLEET_INSTALL_SYNC=0` in `fleet.settings`, which also silences the row) —
   and **the other logins**, one `login on/result age` token each read as its
   owner (`?` without passwordless sudo; `off` is never warned about), a `WARN`
   when any is stuck. `bin/fleet-install-follow.sh` is the reader behind both
   (a table by default, `--self`, `--others --summary`, `--json`), and
   `fleet-install-version.sh` carries the same as its `follow:` line plus the
   tokens on `logins:`.
   Notes: standalone `jq` is **not** needed
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
   `chmod +x ~/.claude/fleet/bin/*.sh`. Prefer a **git clone** of the public repo
   at that path over a copy when `git` is available: a clone knows its commit
   and can follow the repo on its own; a copy can be turned into one later with
   `bin/fleet-sync-logins.sh --to-git` from any login that is a checkout
   (issue #1121). If the user wants a different dir,
   also rewrite the `~/.claude/fleet` paths inside `conf/tmux-attention.conf`
   and `hooks/settings-hooks.json` to match.

3. **Write `~/.claude/fleet/fleet.conf`.** Ask the user (or infer from their
   current repo) the values in `fleet.conf.example`: `FLEET_REPO`
   (owner/name of the backlog repo), `FLEET_MAIN` (its main checkout path),
   `FLEET_BASE_BRANCH`, and whether their plan runs 1M-context models
   (`FLEET_CTX_WINDOW`).
   **Recommend** `FLEET_MCP_CONFIG="$HOME/.claude/fleet/conf/mcp-worker.json"`
   too — the minimal MCP set the fleet ships for worker sessions (issue #1078).
   Without it every session boots every MCP server on the machine. Offer it, say
   what it drops, and leave it unset only if the user declines — see
   [MCP servers on demand](#mcp-servers-on-demand).

4. **Hook up tmux.** Run `sh ~/.claude/fleet/bin/reapply-tmux-attention.sh`
   (idempotently appends one `source-file` line to `~/.tmux.conf`, for a plain
   tmux; a FLEET server does not depend on it — `fleet-up.sh` starts it with
   `-f conf/tmux-fleet-server.conf`, which loads the fleet layer first and then
   the person's `~/.tmux.conf` with `-q`, so an error there skips only theirs;
   `fleet doctor`'s `tmuxconf` row checks `@fleet_conf_loaded` on every fleet
   server — issue #1845). Warn the
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
   remap, personal binds) are intentionally NOT shipped. **No key is bound on a
   node** (issue #1714, EPIC #1710 C4): the node's fleet session carries the
   execution sessions only, and every key, popup and the status bar a person uses
   are the CLIENT's (`fleet`, `conf/tmux-shell.conf`). The node conf's only binds
   are its "stock restores" — tmux's own defaults for the keys an older version
   overrode (`prefix z [ Space E c ! ? n r`, the mouse clicks), so a conf reload on
   a live server converges on stock tmux — and its status line is one static hint
   at the top saying to use `fleet`, for someone who attaches directly.

5. **Wire the Claude Code hooks.** Two ways, and **the plugin in step 8 does
   this for you** — if you install it, skip the merge below and read this section
   only for what the hooks are.

   By hand: `python3 bin/fleet-hooks-merge.py merge` merges
   `hooks/settings-hooks.json` into `~/.claude/settings.json` — it keeps every
   existing hook that isn't the fleet's, wires each fleet hook exactly once by
   identity `(event, matcher, script basename)` (issue #818 — never a jq `+=`,
   which stacks a second copy the first time a command string changes), and
   backs settings.json up first. `fleet-doctor`'s `hooks` line checks the result. The same script's `defaults`
   action (issue #1558) fills `conf/claude-settings.default.json` — the ONE
   default Claude configuration for every login on a managed machine — into
   `~/.claude/settings.json` (its `settings` section: `permissions.defaultMode:
   bypassPermissions`, `skipDangerousModePermissionPrompt`, `effortLevel`,
   `outputStyle`, `theme`, `tui`, `precomputeCompactionEnabled`,
   `agentPushNotifEnabled`; never `model` or `enabledPlugins`, those stay the
   login's) and into Claude Code's GLOBAL config `~/.claude.json` (its
   `globalConfig` section: `leftArrowOpensAgents: false`, issue #1528 — the only
   place that key is read, so a stray ← in a pane never strands it in the agents
   view). It is **fill only**: a key the login lacks is set, a key the login has
   — whatever the value — is never overwritten, and `permissions.defaultMode`
   lands beside the login's own `permissions.allow`. A key the login wants left
   alone entirely goes in `~/.claude/settings.fleet-override.json` — a JSON
   array of dotted key paths (`["effortLevel", "permissions.defaultMode"]`;
   `"permissions"` shields the whole object), or an object keyed by them — and
   `FLEET_KEEP_AGENTS_KEY=1` is the same for `leftArrowOpensAgents`. The
   `.claude.json` write takes Claude Code's own `.claude.json.lock`. The plugin
   cannot set a settings key, so run `python3 bin/fleet-hooks-merge.py defaults`
   either way; every sync re-applies it (a second run writes nothing).
   `fleet-doctor`'s `settings` line counts the keys that differ from the
   defaults (`settings: N key(s) differ …` — a key the login set deliberately
   stops counting once it is listed in the override file). Its sibling for
   BOTH agents is `conf/agent-defaults/` (issue #1559, EPIC #1524 C12), applied by
   `python3 bin/fleet-agent-defaults.py apply` on every sync (the `agents`
   pass): `claude/mcp.default.json` fills the user-scope MCP servers
   `context7` / `playwright` / `github` / `fetch` into `~/.claude.json`,
   `codex/config.default.toml` fills `approval_policy = "never"`,
   `sandbox_mode = "danger-full-access"`, `model_reasoning_effort` and the same
   four `[mcp_servers.*]` into every known `$CODEX_HOME/config.toml` (never
   `model`), and `claude/CLAUDE.default.md` / `codex/AGENTS.default.md` put ONE
   marker-delimited fleet block (`<!-- fleet:agent-defaults begin/end -->`) into
   `~/.claude/CLAUDE.md` / `$CODEX_HOME/AGENTS.md` — appended when absent,
   replaced in place when the text moved on, everything outside it the login's.
   Same fill-only rule: a server the login already has under that name, or a
   Codex key it set, is never rewritten; the login's `config.toml` is edited as
   text (new keys before the first `[table]`, new servers appended as their own
   tables), so its lines stay byte for byte. `~/.config/claude-fleet/agent-overrides.json`
   names what is never written — a JSON array (or an object keyed by) `claude` /
   `codex` (that agent), `claude.mcp.<name>` / `codex.mcp.<name>`, a bare
   `<name>` (that server on both agents), `codex.<key>`, `claude.doc` /
   `codex.doc`. The `github` server runs through `bin/mcp-github.sh`, which takes
   the token from `gh auth token` when the server starts — no config carries one;
   `fetch` runs through `bin/mcp-fetch.sh` on `uvx` (`brew install uv`). The
   repo's `skills/` are the same package for both agents (installed by the
   `skills` / `codex-skills` passes into `~/.claude/skills` and
   `$CODEX_HOME/skills`); `fleet-doctor`'s `agents` line reads
   `claude N missing · codex M missing · skills K missing` (2026-10-04: 15 across
   m5 + m4), `codex n/a` on a login with no `$CODEX_HOME`. These hooks are no-ops outside
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
   `FLEET_AUTO_HANDOFF_PCT>0` (default 80, issue #1571; 0 = off) and a worker/scratch session's
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

   A second `SessionStart` group, matcher `compact`, fires `refocus-hook.sh`
   (issue #1266): right after a context compaction it hands a **worker** its task
   charter back as `additionalContext` — a ≤1.5 KB block opening
   `[fleet charter] #<N>` (issue, repo, branch, PR, one-issue-one-PR, how to
   land), so a long auto-compacted worker doesn't drift out of scope. Zero gh
   calls; silent for the hub, headless children and any other source (a scratch
   gets only its recovery map back, after a fleet compaction — issue #1318).
   `FLEET_REFOCUS=0` turns it off. When the fleet itself ran that `/compact`
   (issue #1269 — a worker or scratch (#1318) in `[FLEET_COMPACT_PREP_PCT` (default 55)`,
   FLEET_AUTO_HANDOFF_PCT)` is asked at a clean Stop for a recovery map, then
   compacted in place at the next idle Stop instead of handed off), the same hook
   adds a "check the map against git and the PR" line and stamps
   `@compact_stage=restored` and bumps `@compact_count`; after
   `FLEET_COMPACT_MAX` (default 3) compactions the next one is a `/fleet-handoff`
   instead (issue #1316). `FLEET_COMPACT_PREP_PCT=0` turns that off.

   A `PreCompact` group, matcher `auto`, fires `precompact-hook.sh` (issue #1321):
   when Claude Code's OWN auto-compaction beats the fleet's ladder, the hook writes
   the recovery map itself just before it — window `@issue`/`@raw`, branch, HEAD,
   `git status`, the PR from the dash's prmap, the issue's latest comment link
   (one `fleet-gh.sh` read, bounded by `FLEET_PRECOMPACT_GH_SECS`, default 8) and
   the operator's last prompts — to the same `fleet_recovery_map_path`, stamps
   `@compact_native`, and logs a `native-precompact` row (`auto saved`) on the
   context ladder; `refocus-hook.sh` reads that map back after the compaction.
   The fleet's own `/compact` is never double-written. `FLEET_PRECOMPACT=0` turns
   it off.
   Either line can be set in tokens used instead — `FLEET_AUTO_HANDOFF_TOKENS` /
   `FLEET_COMPACT_PREP_TOKENS` (issue #1317) — converted per Stop against the
   pane's `@ctx_limit` and winning over the `%` key, so a model with a different
   window size needs no re-tuning; `fleet-doctor.sh`'s `handoff` row shows the
   conversion and checks compact-prep < handoff < Claude's own auto-compaction.
   The hub itself is never blocked or cleared (issue #1319): at the handoff line
   it gets `@ctx_warn` (dash `⚠ ctx`) and one `FLEET_NOTIFY_CMD` pointing at
   `/fleet-handoff`; `FLEET_HUB_CTX_ACTION=off` silences it.

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
     (<https://github.com/verkyyi/claude-fleet/tree/master/tokenledger>), which has no tagged releases
     yet, so build it:

     ```sh
     go install github.com/verkyyi/claude-fleet/tokenledger/cmd/ccquota@latest   # needs Go 1.25+
     ```

     Because there is no tagged release, the binary on each machine is whatever
     `@latest` was the day you ran that — so the builds drift per machine. The
     doctor's `quota` line prints the version it got from `ccquota version`
     (issue #668), which is the first thing to compare when one machine's quota
     line is red and another's is green.

     TokenLedger lives in this repo under `tokenledger/` (its own Go module,
     merged with full history in issue #1391; the old `github.com/verkyyi/ccquota`
     / `verkyyi/tokenledger` install paths are retired). Installing the fleet
     never builds it — `go install` above is the only way it gets onto `PATH`.
     The product was renamed to TokenLedger on 2026-09-14 but **the identifiers
     were deliberately not**: the command, the `CCQUOTA_*` variables and
     `~/.ccquota/` are all still spelled `ccquota`, and this fleet reads them
     under those names. See [`tokenledger/README.md`](../tokenledger/README.md)
     for standing up the hub and pointing `CCQUOTA_HUB_URL` at it.

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
     `bin/fleet-doctor.sh`. The same tick also notifies (`FLEET_NOTIFY_CMD`, once
     per edge, ≤1 per kind per `FLEET_MEM_NOTIFY_COOLDOWN` = 30 min) when memory
     pressure leaves normal or the open-file / pty table crosses
     `FLEET_FILES_WARN_PCT` / `FLEET_PTY_WARN_PCT` (80%) — issue #1293; the
     doctor's `memory` / `files` / `pty` lines show the same readings.
     Beside it, the **memguard** daemon (`com.claude-fleet.memguard`, KeepAlive,
     issue #1292) is recommended: it samples every 2s and SIGKILLs a fleet
     command whose memory spikes ≥4 GB in 10s while the machine is under
     pressure (or that holds ≥50% of RAM), never a claude/codex session, and
     reports a fleet orphan holding >2 GB for >6h. Check what it would do right
     now with `bin/fleet-memguard.sh --once --dry-run`.
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
     install-sync (`com.claude-fleet.install-sync`, 30 min) is the **install-sync
     daemon** (issue #1120) — **recommended** for every login. It is what makes
     `fleet-stable.sh move` reach this login without anyone running
     `/fleet-sync-install` here: each tick fetches `refs/tags/stable` (https, no
     credentials) and, when HEAD is behind it and the tree is clean, checks the
     new version out beside the old one (`~/.claude/fleet.versions/<sha>/`),
     switches the `~/.claude/fleet` link to it in one rename — busy sessions or
     not (issue #1894) — and runs `bin/fleet-install-apply.sh` + `bin/fleet-doctor.sh`;
     a NEW doctor FAIL switches it back and that version is not retried until stable
     moves. Never backward, never onto an edited install. A login whose daemons
     are system LaunchDaemons gets it in that shape (apply renders `UserName`).
     ON by default per login (opt out with `FLEET_INSTALL_SYNC=0`); it spends no
     tokens. `--dry-run` / `--status` for rehearsal and inspection.
   - Linux: use the ready-made units in `systemd/` (parity with the plists,
     `__HOME__`-templated). Substitute `__HOME__` and copy into
     `~/.config/systemd/user/`, then `systemctl --user daemon-reload` and
     `systemctl --user enable --now claude-fleet-spinner.service` +
     `claude-fleet-collect.timer` (the required two) + the recommended
     `claude-fleet-diskguard.timer` (crash-guard) and the always-on
     `claude-fleet-memguard.service` (memory-spike guard, issue #1292) and
     `claude-fleet-pr-refresh.timer` (fast ~15s PR/CI status) +
     `claude-fleet-quotawatch.timer` when a ccquota hub is configured (the
     pre-emptive rotation's own 60s tick, issue #551 — install the `ccquota`
     binary first, as in the macOS step above, or the timer no-ops silently)
     + the recommended
     `claude-fleet-cleanup.timer` and `claude-fleet-ledger-watch.timer` (index
     every closed session for resume) and `claude-fleet-base-sync.timer`
     (keep the local base fast-forwarded to the remote, merge-independent) and
     `claude-fleet-install-sync.timer` (follow `refs/tags/stable`, one link switch per version); the
     optional
     dispatch/issue-bridge/watch/worktree-autoclean are `.timer`s too, and the
     optional **webhook** daemon is an always-on `.service`
     (`claude-fleet-webhook.service`, parity with the KeepAlive plist — needs
     `FLEET_WEBHOOK=1` + `gh extension install cli/gh-webhook`).
     Run `loginctl enable-linger "$USER"` so they run detached. Full recipe in
     `systemd/README.md`.

   **Ship the units as written — the scheduling class is load-bearing** (issue
   #588). Nine plists deliberately carry `ProcessType=Standard` rather than the
   `Background` the other six use: **cleanup**, **worktree-autoclean**,
   **diskguard**, **base-sync**, **dispatch**, **sleep**, **install-sync**, **collect**
   and **memguard** (a 2s sampler that must act WHILE the machine is under memory
   pressure — exactly when a Background job is starved first). `ProcessType=Background` puts
   the job's whole process TREE at QoS BACKGROUND, and that class carries
   **throttled disk I/O** — measured on macOS 26, two identical LaunchAgents
   deleting two identical 20k-file trees ran at **104 files/s (Background) vs
   10967 files/s (Standard)**, ~100x, and the gap widens as the machine gets
   busier: in the field a `git worktree remove` of a 308k-file worktree crawled
   at **~0.4 files/s** — 67 minutes of wall clock for 54 seconds of CPU. The
   first seven do bulk filesystem work (worktree reclaim, `du` tree walks, a
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
   It also wraps `brew` in `umask 022` (issue #2283): Homebrew pours kegs with
   the caller's umask, and an owner on 077 leaves kegs no other login can read.
   The shell's own umask is not changed — only brew's run is.

   **Optional — login banner + SSH opens the client** (issues #1068, #1166, #1711). Offer
   to add this line to `~/.zshrc`, after the `cw.zsh` line above:

   ```zsh
   # claude-fleet login: banner, then an SSH login opens the fleet client
   source ~/.claude/fleet/shell/fleet-login.zsh
   ```

   It prints `shell/fleet-intro.sh` — a three-line, phone-width banner: the
   fleet and its repo count, the `fleet` line, the hide hint — and then, for an **interactive SSH login**, runs `bin/fleet`: the
   client, exactly as on your own computer, reading this machine (its bar says
   `客户端在 <机器> 上运行`). Detaching (`⌃b d`) drops you back at the shell. The gating lives in the snippet, not the scripts:
   interactive shells only (scp, rsync and `ssh host cmd` never see it), never
   inside tmux (worker and client panes source `.zshrc` too), and the client only with
   `$SSH_TTY` set (a local terminal gets the banner alone). Two opt-outs:
   `touch ~/.hushfleet` turns off both, `touch ~/.hushfleet-attach` keeps the
   banner and leaves `fleet` for you to type. `cf` is folded into `fleet`: for
   one version it says so and runs `bin/fleet`. It replaces any hand-written
   per-account `~/.config/claude-fleet/intro.sh` — delete that copy.

   **The `fleet` client is the only way in** (issue #1628). From a computer of
   your own run `fleet` (`curl -fsSL <hub>/install | sh` installs it, tmux
   included): the hub's list, its bar and the machine's sessions in one tmux of
   your own. That line is THE install line (issue #1804): it asks whether this
   computer only looks and dispatches (the default) or also hosts sessions
   (承载), and whether it joins the hub; everything lands in `~/.claude/fleet`.
   **No hub** (one computer, only the tools — issue #1712): the same file from
   GitHub's `stable`, answer 「2 不接」 — no hub address is written, and `fleet`
   then opens the same client reading this machine — see
   [LOCAL-AND-HUB.md](LOCAL-AND-HUB.md#一条安装命令issue-1804). There is no fallback to ssh-ing into a machine and using its own
   list: with no tmux (or one older than 3.2) `fleet` says how to install it and
   exits non-zero; a client that cannot start says why and exits non-zero. An
   iPad / iPhone ssh's into any machine with the fleet installed and runs the
   same `fleet` there — the client then runs on that machine (its own
   `-L fleet-shell` server, not that machine's fleet session) and its bar says
   `客户端在 m5 上运行` — which is exactly what the SSH login above opens (issue
   #1711): there is one way in. A direct `tmux attach` to a machine's fleet
   session is not blocked, but it is not a way in to document or rely on.

   **Machine-local banner lines** (issue #1255) go in `intro.d` hooks, never in
   the repo: every executable in `/usr/local/etc/claude-fleet/intro.d/*` (all
   logins on the machine), then `~/.config/claude-fleet/intro.d/*` (this login),
   runs in file order and its stdout prints verbatim between the `fleet` line and
   the hide hint — e.g. a `vnc  远程桌面` row on a box with screen sharing. A
   hook that fails or prints nothing adds nothing; each hook does its own gating
   (`[ -n "$SSH_CONNECTION" ] || exit 0` for SSH-only) and keeps its lines
   ≤ 40 columns.

   A `~/.zshrc` still carrying the older inline banner block (issue #1068) keeps
   working exactly as before, banner only — nothing rewrites it. To opt that
   login into opening the client, replace the block with the `source` line above.

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
   **Pin the Codex version:** `npm i -g @openai/codex@0.154.0`. Fleet reads a
   Codex worker's context % from Codex's session (rollout) file, an internal
   format verified only on 0.154 (`SUPPORTED_ROLLOUT_VERSIONS` in
   `bin/fleet-codex-runtime.py`). Another version still launches, but
   `fleet-doctor` shows a `codex` WARN and each launch prints one warning;
   `FLEET_CODEX_VERSION_CHECK=0` silences both (issue #1079).
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
   line (`conf/statusline.sh` — the measurement bus behind the pane header's
   `62% · Opus 5.5 · high`, the auto-handoff nudge and the quota watch; it draws
   no visible line of its own since issue #1452).
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
   - **jq is a soft dep** here: `conf/statusline.sh` exits silently (no stamps,
     so no `%` in the header) without `jq`, so offer `brew install jq` if it's missing — but it is
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

8c. **Give the pane its bottom row back (optional, later).** Claude Code keeps
   one blank row at the bottom of every pane for as long as `settings.json` has
   a `statusLine` at all — there is no hidden option (issue #1459). The fleet mod
   (`mod/fleet`, v0.2.0+) feeds the SAME `conf/statusline.sh` from inside the
   session (`--from mod`: context + rate limits off `session.measure`, model +
   effort off `turn.step`, a `/model` off a 2 s poll), so a login whose every
   Claude window carries that mod can drop the key and lose nothing. The switch
   is `bin/fleet-statusline.sh`:

   ```sh
   ~/.claude/fleet/bin/fleet-statusline.sh status   # what is wired + a census: fed by the mod / not, and why
   ~/.claude/fleet/bin/fleet-statusline.sh off      # removes the key — ONLY when every live Claude window is fed
   ~/.claude/fleet/bin/fleet-statusline.sh on       # puts it back (this install's conf/statusline.sh)
   ```

   Rails: `off` refuses (exit 1, the windows named) while any Claude window has
   no fresh `@mod_alive` or an older `@mod_ver` — a session launched before the
   mod is blind the moment the key goes, since nothing restarts it; cycle those
   first (`/fleet-handoff` in the pane, or close + `fleet-restore`) and re-run,
   or `off --force` knowingly. It never touches a personal `statusLine` (one not
   ending in `conf/statusline.sh`), refuses under `FLEET_MOD=0` (no second
   reporter), backs `settings.json` up to `.bak.<epoch>` first, and
   `/fleet-sync-install` never runs it — the row is the operator's to take.
   Running sessions keep their row until restarted; new ones have it back.
   `fleet-doctor`'s `statusln` row says where the login stands.

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

### Host setup (unattended machine)

   If this machine runs unattended, walk **[HOST.md](HOST.md)** with the user —
   [turning off Spotlight](HOST.md#spotlight), then the
   [unattended-Mac checklist](HOST.md#headless) (auto-login + never sleep, Siri
   off, iCloud sync off, no GUI apps on the console) and the
   [container VM's share of the machine](HOST.md#containers). Every item there
   is a system setting the user decides on: show the command, never run a `sudo`
   change without an explicit yes. `fleet-doctor`'s `host` section (macOS only)
   reports each one — [HOST.md → Verify](HOST.md#verify) lists the lines.
   `bash ~/.claude/fleet/bin/fleet-host-tune.sh` prints the whole checklist as
   now → target → command ([HOST.md → All at once](HOST.md#tune)); show the user
   that plan, and run `--apply` (it asks per item) only on their yes.

## 新同事第一次（issue #1901）

A colleague gets ONE line from the operator — `curl -fsSL https://<入口>/install | sh` — and
nothing else. What they then see, press and wait for, as
`bin/fleet-onboard-drill.sh` recorded it on a throwaway login on m4 — final run
2026-10-07, stable `644641e`, hub `prod-56a4d57`, a DRILL PERSON confirming the scan
(`fleet drill invite`), the client on the test identity; paste → list in 137 s
(「要人帮」 = a step they would have had to ask someone about):

| # | 看到什么 | 按了什么 | 用时 | 要人帮 |
|---|---|---|---|---|
| 1 | 终端提示符 | 粘贴 `curl -fsSL https://<入口>/install \| sh`，回车 | — | 否 |
| 2 | 「这台电脑要做什么？ 1 只看、只派（推荐）· 2 也跑会话（承载）」 | 回车（1） | 2s | 否 |
| 3 | 「接入口吗？ 1 接（推荐）· 2 不接」 | 回车（1） | 2s | 否 |
| 4 | 下载、装 tmux、登记这台电脑（屏上没有一行 curl 报错） | 等 | 99s | 否（#1901 前：每个文件一行 `curl: (56) … 502`，装不完 — 是） |
| 5 | 企业微信二维码 + 验证码，600 秒有效 | 用企业微信扫码、点确认 | 本人 | 本人的一步 |
| 6 | ✓ 证书 · ✓ 已登记到入口 · 「能力: 基础 · 承载 未开 · 入口 接」，客户端：左边任务列表、右边主页 | —（装完自己打开） | 16s | 否（#1901 前：`open terminal failed: can't use /dev/tty` — 是） |
| 7 | 空列表 `No sessions — type a name` | prefix 空格 到列表，敲名字，回车 | 7s | **是** — 4 秒提示「你还没有能开会话的机器：请入口管理员给你分一台」：新人名下还没有任何一台机器，只有管理员能分（见下） |

So the reading is **1**, and it is a step the operator takes BEFORE sending the line, not one the
colleague can take: give the new person a machine (a login on a host) on the hub first. With one
given, row 7 goes on to 「选仓库 / 开在哪」 (each Enter = the default) and the new row.

What the drill found and where it went:

- **The hub could not serve stable from China.** `raw.githubusercontent.com` is reset from the
  hub's cluster while `api.github.com` and `codeload.github.com` answer, so every
  `/install/stable/<sha>/<path>` waited 15 s and answered 502. The hub now loads a commit's
  client files from ONE codeload tarball (raw per file only as the fallback,
  `tokenledger/internal/api/fleet_stable.go`), and the installer stops asking the hub after its
  first failed file and takes the rest from GitHub quietly (`bin/fleet-install.sh` `fetch`).
- **The install's last step never opened the client.** `exec fleet </dev/tty` hands tmux a stdin
  whose `ttyname()` is `/dev/tty`, which tmux refuses; the installer now hands it the terminal's
  own device (stderr's).
- **An empty list cannot open its first session** — #1927.
- **A joined computer could not be taken off the hub** except by `ccquota endpoint retire` on the
  hub's own database (#1928). Now `fleet node leave` takes it off from the computer itself (the
  hub retires its token and drops it from the machines page, then the agent stops and `node.env`
  goes), the machines page's 「移除」 does it from the hub, and `fleet-login-remove.sh` runs the
  leave as the login it deletes.

**The person's own steps** (never counted as 要人帮): the WeCom scan, and — when the hub has not
yet given them a login on any machine — the hub's page says so; that one IS the operator's
(`fleet_accounts.go`: only the operator assigns logins), so give the colleague a login BEFORE
sending the line.

**Re-run the drill after any change to the install path** (on a machine meant for drills — it
opens a real OS login and runs sudo, so never from a fleet worker on that same machine):

```sh
sudo -v
~/.claude/fleet/bin/fleet drill invite              # a DRILL PERSON: prints its login + approve code
~/.claude/fleet/bin/fleet-onboard-drill.sh --login <login> --invite <code>   # the line it printed
~/.claude/fleet/bin/fleet-onboard-drill.sh --teardown <login> --invite <code>   # a run left up with --keep
```

**Confirm as a drill person, never as yourself** (issue #2010). Without `--invite`, whoever
opens the QR's page confirms it — on 2026-10-06 that was the operator's own browser, so the
run signed the drill's login as him and walked "his second computer", not a new colleague's
first time. `fleet drill invite [--ttl 2h] [--login drill<x>] [--host <machine>]` (an admin,
signed with your own connection certificate; else `CCQUOTA_VIEWER_TOKEN`) has the hub mint a
`kind=drill` person — its one login is the drill's throwaway OS login on this machine, it
borrows no credential, gets no session pass, sees only its own sessions — and a one-time
approve code. The drill's scan step then confirms with that code (`fleet drill approve`,
`POST /fleet/login/approve`: the code is the only credential sent), and its teardown has the
drill person delete itself with its device and node (`DELETE /v1/self`, signed by the login's
own certificate) — no operator token needed. The hub deletes it anyway when its life ends.

It opens a bare login (no fleet clone, no daemons — a colleague's computer), types the line,
answers every question with Enter, waits for the scan, opens a scratch session from the list,
then revokes the device, retires the node (`FLEET_DRILL_RETIRE_CMD <ep_id>`, until #1928) — or,
with `--invite`, has the drill person delete itself — and deletes the login; one PASS/FAIL line a step, `steps.md` (the table above) and one
`screen-NN-<step>.txt` per screen in its log dir. Its selftest
(`fleet-onboard-drill-selftest.sh`) drives only the refusals and the `--invite` teardown's hub
half, against PATH shims; `fleet-drill-selftest.sh` pins `fleet drill`.

### The 60-second standard (60 秒上手，EPIC #2259)

`fleet-onboard-drill.sh --hub prod --runs 3` (= `bin/fleet-onboard-clock.sh`, issue #2267)
times the NEW road — no OS login is made: each run is a sandbox HOME on this computer (no
`~/.config/claude-fleet`, no `~/.local`, no Homebrew on PATH, its own TMPDIR / TMUX_TMPDIR),
driven in a terminal of its own. It pastes `curl -fsSL <hub>/i/<invite> | sh`, lets the
installer run `fleet`, takes the authorize page with a stand-in browser and — after a fixed
10-second hand — confirms it with a drill person's code, waits for the first HOME session, and
types one letter until the agent keeps it. Per run it mints the drill person (`fleet drill
invite`) and an invite (`fleet hub invite`) as you, and deletes the person at the end.

The table it prints (also `report.md`, `clock.tsv` and every screen in its out dir, codes
blanked) is EPIC #2259's five readings — paste → first key (the max of the runs, ≤ 60 s), the
person's own steps (2), admin on the spot (0), fleet words on the screen before the first key
(0) — and the eight known pits, PASS/FAIL each; the segments (安装 · 浏览器授权 · 拿到电脑 · 进会话 ·
第一键) use `t_enter … t_key`, EPIC #2230's naming. Exit 0 only when all five are on target.

A real hub places that session on a real machine **as the drill person's login**, so the login
must exist there — a spare (#2263); preparing one is the operator's call (EPIC #2259 共同约定 6).
CI runs it on every PR inside `bin/newcomer-e2e.sh` (the `clock` step, a hub built from the
checkout, a fake node and a stand-in agent that drops keys while it mounts) with `--gate pits`:
there the eight pits and the first key are held, the seconds and words only printed.
`fleet-onboard-clock-selftest.sh` pins the refusals, the concept scan and the scrub.

## Publishing to installs — the `stable` tag (发布到各安装)

Merging to `master` does not, by itself, reach any machine. What installs follow
is `refs/tags/stable` on `verkyyi/claude-fleet` (issue #1118, EPIC #1117): a
lightweight tag the operator moves forward, one command at a time, to the
version they vouch for.

```sh
bash ~/.claude/fleet/bin/fleet-stable.sh show              # where stable points, how far it trails origin/master
bash ~/.claude/fleet/bin/fleet-stable.sh move --dry-run    # every check, no push
bash ~/.claude/fleet/bin/fleet-stable.sh move [<sha>]      # default: origin/master
```

`move` refuses (exit 3) unless the target is a commit on `origin/master`, it
descends from the current `stable` (forward only — never back, never sideways),
and every CI check run on it is green. A commit with zero check runs (push CI is
path-filtered, so a docs-only commit has none) is refused too unless you pass
`--allow-no-checks`. The push uses `--force-with-lease` pinned to the value it
read, so two concurrent moves cannot both win (the loser exits 4).

It also replays an **old session** of the current `stable` against the target
(issue #2075): `bin/fleet-oldcfg-replay.py` runs stable's hook table, the mod's
tool list and the MCP servers against the target's tree in a sandbox, and a
script gone, a hook erroring or hanging, or a tool left without a handler refuses
the move with a reason prefixed `oldcfg:` — the findings name what an old session
would hit; fix them per CONTRIBUTING «老会话兼容». `--force` moves anyway and
appends one line to `logs/stable-move.log`. Same target as stable ⇒ nothing to
replay, green at once.

`fleet-doctor.sh`'s `install` row carries an INFO line with how many commits
`stable` trails master — the cue to move it. The first placement was `0164208`,
the version every login on the Mac mini was synced to on 2026-09-24.

## MCP servers on demand

Without `FLEET_MCP_CONFIG`, every spawned session starts **every** MCP server
configured on the machine — the operator's own `~/.claude.json` servers, every
enabled plugin's servers, and the claude.ai remote connectors. On the machine this
was measured on that was ~2s of startup and 4-5 resident `node` children per
session, for servers most worker tasks never call (issue #473's census: all MCP use
in 30 days came from three servers, in one fleet). A host that runs 36 sessions
pays that 36 times.

The fleet ships a minimal worker set, **`conf/mcp-worker.json`**, installed with
`conf/` and kept current by `/fleet-sync-install` like every other tracked file.
It contains only the fleet's own tool service, `fleet` (`bin/fleet-mcp.py`,
issue #1807 — spec in [`FLEET-MCP.md`](FLEET-MCP.md)), which every Claude and Codex
session mounts whatever this key says (`FLEET_MCP=0` is the off switch):

```json
{
  "mcpServers": {
    "fleet": {
      "command": "bash",
      "args": [
        "-c",
        "exec python3 \"${FLEET_MCP_BIN:-$HOME/.claude/fleet/bin}/fleet-mcp.py\""
      ]
    }
  }
}
```

Point a fleet at it (in `fleet.conf`, or per fleet in
`~/.config/claude-fleet/fleets/<session>/conf` — the key is `@scope=fleet`):

```sh
FLEET_MCP_CONFIG="$HOME/.claude/fleet/conf/mcp-worker.json"
```

`bin/fleet-claude.sh` then launches with `--strict-mcp-config
--mcp-config=<file>`: only the `fleet` server loads, and the remote connectors are dropped
too. Codex workers inherit the same value unless `FLEET_CODEX_MCP_CONFIG` is set;
the Codex launcher disables every other configured server plus apps/connectors
(`bin/fleet-codex-policy.py`).

**A repo that needs more** — don't edit the shipped file (the next sync would
overwrite it). Copy it next to that fleet's conf, add only what that repo's
workers use, and point that fleet's `FLEET_MCP_CONFIG` at the copy. Common
add-backs:

```json
{"mcpServers":{
  "playwright": {"command": "npx", "args": ["@playwright/mcp@latest"]},
  "mcp-image":  {"command": "npx", "args": ["-y", "mcp-image"]}
}}
```

A browser-driven UI repo wants `playwright`; an image-generating one wants its
image server. HTTP servers use `{"type": "http", "url": "…"}`. The other values:
`none` is the same empty set without a file, and unset/empty keeps the old
everything-loads behaviour. It takes effect on the next spawned session; a plain
`claude` outside the fleet is untouched, so the full set stays one ordinary
session away. A caller's explicit `--mcp-config` / `--strict-mcp-config` wins.

`fleet-doctor`'s `mcp` lines show it for every fleet at once (issue #891): the
allowlist and its server count, a WARN for a fleet with none, and — while the
fleet is up — how many MCP processes its live sessions carry and their RSS, plus
one total row. `FLEET_DOCTOR_MCP=0` drops them.

To see the saving for a single worker, count its children before and after:

```sh
pgrep -lP "$(pgrep -P "$(tmux display -p -t <pane> '#{pane_pid}')" | head -1)"
```

## Uninstall

Remove the LaunchAgents (`launchctl bootout gui/$(id -u)/com.claude-fleet.*`,
delete the plists), delete the `source-file …tmux-attention.conf` line from
`~/.tmux.conf`, remove the five `set-claude-state.sh` hook entries (and the
`handoff-latch-reset-hook.sh` + `refocus-hook.sh` entries on `SessionStart`, and `precompact-hook.sh` on `PreCompact`) from `~/.claude/settings.json`, remove the `statusLine` block from
`~/.claude/settings.json` **only if** it points at `conf/statusline.sh` (leave a
personal one — `bin/fleet-statusline.sh off --force` does exactly this, backup
included), delete `~/.claude/fleet/`, remove any fleet commands
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
`com.claude-fleet.base-sync`, `com.claude-fleet.install-sync`, `com.claude-fleet.dispatch`, `com.claude-fleet.memguard`, `com.claude-fleet.cred-proxy`, and `com.claude-fleet.webhook`; on Linux
`systemctl --user disable --now claude-fleet-pr-refresh.timer` +
`claude-fleet-issue-bridge.timer` +
`claude-fleet-cleanup.timer` + `claude-fleet-ledger-watch.timer` +
`claude-fleet-base-sync.timer` + `claude-fleet-install-sync.timer` + `claude-fleet-dispatch.timer` + `claude-fleet-memguard.service` + `claude-fleet-cred-proxy.service` + `claude-fleet-webhook.service`.) If you ran the
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
