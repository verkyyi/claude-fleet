# What a fleet login gets by default — audit (issue #3099)

Measured 2026-10-11 on **macmini** (login `verky`) and **mini2** (login `verky`), both on
release `6c7cfc7a`, plus a read of the code that installs each piece. This report changes
nothing. Each proposal becomes its own issue or EPIC member once the person has read it.

## The principles each proposal cites

| Tag | Principle |
|---|---|
| **P1** | A minimal core: sign in, open a session, reach it, credentials, update. |
| **P2** | Every ability outside the core is optional: not installed and not enabled by default. |
| **P3** | Each one can be removed on its own. |
| **P4** | Its failure must not affect the core. |
| **P5** | No roles, prompts, tools or workflows are injected by default. |
| **N** | Native first: don't override or block what Claude Code / Codex already do. |

Columns used below:

- **Needs:** `core` is the core path (P1), `ext` is an extension.
- **On:** on by default for a managed login. `idle` means installed and running, but its own knob is off, so it does nothing.
- **Alone?:** can it be removed on its own today?
- **Proposal:** **keep**, **opt-in** or **remove**.

## Totals per kind

"After" is the count still installed by default once every proposal in this report is done.

| Kind | Today (default) | After the proposal | Opt-in | Removed |
|---|---:|---:|---:|---:|
| Hook entries in `~/.claude/settings.json` (by script) | 28 entries · 17 scripts | 12 entries · 7 scripts | 8 scripts | 2 scripts |
| Mod `fleet` (one plugin), features inside it | 1 · 15 features | 1 · 4 features | 10 | 1 |
| MCP servers, Claude user scope + Codex | 4 + 4 (and `fleet`, per launch) | 0 + 0 (`fleet` stays) | 8 | 0 |
| Commands `~/.claude/commands` | 11 | 4 | 6 | 1 |
| Skills `~/.claude/skills` | 7 | 0 | 6 | 1 (merged into `/fleet-handoff`) |
| Codex skills generated from both | 18 | 4 | 12 | 2 |
| Agent / role definitions + rule table | 5 + 1 table | 1 | 5 | 0 |
| Injected prompts / preambles (ambient) | 7 | 0 (only the worker's own `/fleet-claim` seed) | 6 | 1 |
| Keys / lines written into the user's own config files | 19 | 5 | 1 | 13 (4 of them move to launch flags) |
| Machine supervisor: children + tasks | 2 + 5 | 2 + 5 (diskguard split) | 0 | 0 |
| Account units per managed login (launchd templates) | 16 | 8 | 7 | 1 |
| Other default-on session/daemon behaviours (knobs) | 9 | 5 | 4 | 0 |
| tmux confs (node + client) | 8 | 8 (one hook moves out) | 0 | 1 (`~/.tmux.conf` line, counted under user files) |
| Shell hooks / CLI wrappers | 0 shell hooks · 5 wrappers | 0 · 5 | 0 | 0 |

The rows below give the reason for every number.

## Measured live

| | macmini · verky | mini2 · verky |
|---|---|---|
| Runtime link | `~/.claude/fleet` → `fleet.versions/6c7cfc7a…` | same |
| Hook entries | 28 over 8 events | 28 over 8 events |
| User-scope MCP servers | context7 · playwright · github · fetch (fleet's) + 6 personal (mcp-image, doubao-tts, langfuse ×2, space, phone) | the fleet's 4 + browser, phone, space (personal) |
| `agent-effective.json` | default 12 items, local 8; team layer v0 (empty); personal v1 | — |
| Commands / skills / Codex skills | 11 / 7 fleet (+5 personal) / 18 | 11 / 7 fleet (+1 personal) / 18 |
| `CLAUDE.md` / `AGENTS.md` marker block | present (23 lines) | present |
| Codex keys | never · danger-full-access · high · no update check | same |
| `~/.zshrc` | one PATH line (`~/.local/bin`) | same |
| `~/.tmux.conf` | fleet source line | — |
| `~/.local/bin` | ccquota, claude → runtime, codex → runtime, codex-code-mode-host | same |
| Supervisor | ok · `cred-proxy-shared` running · `node-agent` waiting (no `logins/*.env`) · 5 tasks · 6 accounts × 16/16 units | **DOWN for 78 min while its process is alive** → filed **#3100** |
| Windows in the fleet | 13 worker · orchestrator · steward · home · panel | 9 worker · home · panel (no orchestrator here: one per person) |
| `fleet.conf` knobs set | HOST=1, ORCHESTRATOR=1, STEWARD=1, CRED_PROXY=1, CRED_SEPARATE=1 | HOST=1 |
| Per-session MCP processes (RSS) | context7 2.3 GB · playwright 2.4 GB · fetch 1.1 GB · github 0.7 GB · fleet-mcp 0.5 GB · 7501 relay 0.26 GB | context7 1.0 GB · playwright 1.1 GB · fetch 0.5 GB · github 0.4 GB · fleet-mcp 0.26 GB · relay 0.1 GB |
| Runtime dir `/Library/Application Support/claude-fleet` | 35 entries · 5.3 GB | 56 version dirs · **18 GB** (#3100) |

**The largest single cost of the defaults is the four default MCP servers.** Each Claude
session starts its own copy of each one. That is about **6.4 GB** of RSS for one login
on macmini (16 sessions) and 3 GB on mini2.

## 1. Hooks (`hooks/settings-hooks.json` → `~/.claude/settings.json`)

All fleet hooks are one locked item: `claude.hooks` in `conf/agent-locked.list`. So the
answer to **Alone?** is *no* for every row. They can only be turned off as one block.

| # | Script (events) | What it does | Needs | On | Alone? | If off / fails | Proposal — why |
|---|---|---|---|---|---|---|---|
| H1 | `set-claude-state.sh` (Pre/PostToolUse, UserPromptSubmit, Notification, Stop — 5 entries) | Stamps working / done / needs on the tmux window | core | yes | no | The list loses state where OSC 7501 isn't present (Codex, old Claude) | **keep** — the fallback state source under the 7501 relay (P1 "reach it") |
| H2 | `bash-guard.py` (Bash + 3 fallback tools) | One guard with many jobs: refuses tmux destroy, blocks `send-keys`, rewrites `gh issue comment`, prefixes the heavy queue, logs direct-script bypass | core + ext | yes | no | A Python error in one job affects every Bash call | **keep, split** — the tmux-destroy rail stays core; heavy queue, comment rewrite and bypass log become opt-in modules (P3, P4) |
| H3 | `base-readonly-guard.py` (Edit/Write/…) | Makes the base checkout read-only | core | yes | no | A worker can commit to the base checkout | **keep** — the worktree model is the core session shape |
| H4 | `artifact-guard.py` (Artifact) | Blocks Artifact publishing | ext | yes | no | — | **opt-in** — blocks a native feature (N, P2) |
| H5 | `agent-guard.py` (Agent) | Blocks writing subagents | ext | yes | no | — | **opt-in** — a workflow policy that overrides native subagents (N, P5) |
| H6 | `fleet_loop_mark.py` (PostToolUse loop tools) | Marks `@loop` so the reapers never close a looping session | core | yes | no | The reaper could close a /loop session | **keep** — protects the user's own session (P4) |
| H7 | `fleet-orchestrator-state.py` (6 entries) | Orchestrator's working state across compaction | ext | yes, in every session | no | Every session pays a Python start on 6 events | **opt-in** — with the orchestrator (P2, P5) |
| H8 | `fleet-whats-new.sh --hook` (UserPromptSubmit) | Injects a "fleet updated" note into the next prompt | ext | yes | no | — | **opt-in** — prompt injection (P5) |
| H9 | `fleet-codex-session.py hook` (Stop, SessionStart in the **Claude** table) | Codex identity / telemetry | ext | yes | no | No-op for Claude, but costs a Python start | **remove** from the Claude table — belongs to Codex's own hook map (P1) |
| H10 | `classify-hook.sh` (Stop) | Screen classifier for state | core (legacy) | yes | no | State falls back to hooks + 7501 | **remove** once 7501 coverage is measured — 7501 is primary (#2537) (P1) |
| H11 | `handoff-latch-reset-hook.sh` (SessionStart) | Resets the auto-handoff latch | ext | yes | no | — | **opt-in** — with auto-handoff (P2) |
| H12 | `fleet-where-hook.sh` (SessionStart) | Injects "where the operator is" into context | ext | yes | no | — | **opt-in** — prompt injection (P5) |
| H13 | `fleet-emit.sh session.start/end` (2 entries) | Session events to the hub | core | yes | no | The hub's session list is stale | **keep** — "reach it" from another machine (P1) |
| H14 | `refocus-hook.sh` (SessionStart compact) | Injects a re-focus note after compaction | ext | yes | no | — | **opt-in** — prompt injection (P5) |
| H15 | `fleet-history.sh resumed` (SessionStart resume) | Resume ledger | core | yes | no | `/fleet-history` misses a resume | **keep** — resuming is core (P1) |
| H16 | `precompact-hook.sh` (PreCompact auto) | Auto-handoff before compaction | ext | yes | no | Native compaction runs instead | **opt-in** — overrides native compaction (N, P2) |
| H17 | `session-end-hook.sh` (SessionEnd) | Writes the close row and ledger | core | yes | no | History misses a close | **keep** (P1) |

**After the proposal:** 7 scripts / 12 entries — H1 ×5, H2 (Bash only, once M15 is gone), H3, H6,
H13 ×2, H15, H17. 8 scripts become opt-in, 2 are removed. The `claude.hooks` lock becomes
per-hook (P3).

## 2. The mod `fleet` (`mod/fleet`, loaded with `--plugin-dir` on every launch; `FLEET_MOD=1`)

The mod is all or nothing today: `FLEET_MOD=0`, and `mod` is locked. Only the panels have
their own switch, `FLEET_MOD_PANELS`.

| # | Feature | What it does | Needs | On | Alone? | If off / fails | Proposal — why |
|---|---|---|---|---|---|---|---|
| M1 | `lifecycle.ts` · `gate.ts` · `version.ts` · `register.ts` · `tmux.ts` | Loader, version gate, heartbeat, helpers | core | yes | no | The mod registers nothing (it degrades off by version) | **keep** — the frame the rest hangs on |
| M2 | `state.ts` | State from inside the session | core | yes | no | Falls back to hooks | **keep** (P1) |
| M3 | `usage.ts` | Context % / quota / model → `statusline.sh --from mod` | core | yes | no | The top line shows no context / quota | **keep** — measurement bus (P1) |
| M4 | `inbox.ts` | Runs `/clear` `/compact` `/model` and handoff that the fleet posts | core | yes | no | Handoff / renew cannot drive the session | **keep** (P1 "update": renew after release) |
| M5 | `progress.tsx` | PR + checks band above the prompt | ext | yes | no | — | **opt-in** (P2) |
| M6 | `compose.ts` + `orchestrator.ts` | Appends the orchestrator role to the system prompt | ext | orchestrator only | no | — | **opt-in** — with the orchestrator (P5) |
| M7 | `where.ts` | Appends "where the operator is" to **every** session's system prompt | ext | yes | no | — | **opt-in** — prompt injection (P5) |
| M8 | `exit-guard.ts` | Intercepts `/exit` and `/clear` in the orchestrator | ext | orchestrator only | no | — | **opt-in** — overrides native commands (N) |
| M9 | `qd.tsx` | `/qd` quick dispatch | ext | orchestrator only | no | — | **opt-in** (P2) |
| M10 | `queue.ts` | Counts queued prompts | ext | orchestrator only | no | — | **opt-in** (P2) |
| M11 | `panels.ts` / `panels-model.ts` | Right-hand panels | ext | steward holder | `FLEET_MOD_PANELS` | — | **done** — fleet-steward plugin (#3115) |
| M12 | `sheet.tsx` | Decision sheet, `/sheet` | ext | steward holder | `FLEET_MOD_PANELS` | — | **done** — fleet-steward plugin (#3115) |
| M13 | `batches.tsx` | Batches pane | ext | steward holder | `FLEET_MOD_PANELS` | — | **done** — fleet-steward plugin (#3115) |
| M14 | `patrol.tsx` | Steward patrol pane | ext | steward holder | `FLEET_MOD_PANELS` | — | **done** — fleet-steward plugin (#3115) |
| M15 | `tools.ts` | Fallback `fleet_status/spawn/await` for sessions started without the MCP | ext | only without `FLEET_MCP_SERVER` | no | — | **remove** — compat for pre-#1828 sessions; one version has passed |

15 features. **After the proposal:** M1–M4 stay (4); M5–M14 become opt-in (10); M15 is removed.

## 3. MCP servers

| # | Server | What it does | Needs | On | Alone? | If off / fails | Proposal — why |
|---|---|---|---|---|---|---|---|
| X1 | `fleet` (`conf/mcp-worker.json` → `fleet-mcp.py`, per launch, `FLEET_MCP=1`) | The fleet tools: brief, report, spawn, comment… | core | yes | `FLEET_MCP=0` | A worker cannot report or land through the rails | **keep** — the session's interface to the fleet (P1) |
| X2 | `context7` (Claude + Codex) | Library docs | ext | yes | yes (`agent-overrides.json`) | — · costs ~1–2 GB per login | **opt-in** (P2) |
| X3 | `playwright` (Claude + Codex) | Headless browser | ext | yes | yes | — · ~1–2.4 GB per login | **opt-in** (P2) |
| X4 | `github` (Claude + Codex, `mcp-github.sh` reads `gh auth token`) | GitHub API | ext | yes | **no — locked** | — | **opt-in** — `gh` covers it, and the lock breaks P3 |
| X5 | `fetch` (Claude + Codex, `mcp-fetch.sh`) | URL fetch | ext | yes | **no — locked** | — | **opt-in** — native WebFetch exists (N, P3) |

Today: 4 + 4 defaults, all on, two of them locked. After: 0 defaults; X1 stays.

## 4. Commands and skills

Off switches today are **per category only** (`claude.commands`, `claude.skills`,
`codex.skills` in `agent-overrides.json`). No single command or skill can be turned off
(P3 fails).

| # | Item | What it does | Needs | Proposal — why |
|---|---|---|---|---|
| C1 | `/fleet-claim` | Worker lifecycle: claim → ship | core (issue sessions) | **keep** — the seed of every issue session |
| C2 | `/fleet-handoff` | Continue in a fresh context / other agent | core | **keep** (merge with S7) |
| C3 | `/fleet-history` | Browse and resume closed sessions | core | **keep** — resume (P1) |
| C4 | `/fleet-context` | How full is my context | core | **keep** — small, read-only |
| C5 | `/fleet-compact-resume` | Re-ground after compaction | ext | **opt-in** — with auto-handoff (P2) |
| C6 | `/fleet-epic-plan` | EPIC design page | ext | **opt-in** — a workflow (P5) |
| C7 | `/fleet-epic-run` | Drive an EPIC | ext | **opt-in** (P5) |
| C8 | `/fleet-epic-report` | EPIC report | ext | **opt-in** (P5) |
| C9 | `/fleet-move` | Move a session to another login / machine | ext | **opt-in** (P2) |
| C10 | `/fleet-onboard` | Newcomer walkthrough | ext | **opt-in** (P2) |
| C11 | `/fleet-sync-install` | Re-apply the install by hand | — | **remove** — managed logins follow the runtime (#2774), and the updater owns this |
| S1 | `doc-preview` | Host a doc on the tailnet | ext | **opt-in** (P2) |
| S2 | `epic-page` | EPIC page frame | ext | **opt-in** — with the EPIC commands |
| S3 | `fleet-config` | Change a role by one sentence | ext | **opt-in** — with the roles |
| S4 | `fleet-open` | Open a page on the operator's computer | ext | **opt-in** (P2) — the `open` tool in X1 stays |
| S5 | `fleet-orchestrate` | Orchestrator role | ext | **opt-in** — the next batch's subject (P5) |
| S6 | `fleet-steward` | Steward role | ext | **opt-in** (P5) |
| S7 | `handoff` | Generic handoff skill | core | **merge into C2** (one handoff, not two) |

Codex gets 18 generated skills: the 11 commands with `conf/codex-preamble.md` prepended,
plus the 7 skills. They follow the same proposals: **5** stay (C1–C4, merged handoff),
**11** become opt-in, and **2** go (C11, S7).

## 5. Agent / role definitions and the rule table

| # | Item | What it does | Needs | On | Proposal — why |
|---|---|---|---|---|---|
| A1 | `agents/worker.md` | Worker model / effort / disallowedTools (locked) | core | every `--role worker` launch | **keep**, slimmed — model and effort only; tool locks become the guards' job (N) |
| A2 | `agents/orchestrator.md` | Orchestrator role, body in the system prompt | ext | yes (`FLEET_ORCHESTRATOR` follows `FLEET_HOST`) | **opt-in** (P5) |
| A3 | `agents/steward.md` | Steward role | ext | `count` by default where the orchestrator runs (here `1`) | **opt-in** (P5) |
| A4 | `agents/epic-driver.md` | EPIC driver | ext | when an EPIC runs | **opt-in** — with the EPIC commands (now `plugins/fleet-epic/agents/`, #3116) |
| A5 | `agents/debugger.md` | Hub debug desk | ext | debug desk only | **opt-in** (P2) |
| A6 | `conf/role-rules.default.md` (21 rows) | How the orchestrator dispatches, what the steward may answer | ext | appended to the orch/steward prompt | **opt-in** — with A2/A3 (P5) |

## 6. Injected prompts and preambles

| # | Item | Where it lands | Needs | On | Alone? | Proposal — why |
|---|---|---|---|---|---|---|
| I1 | Marker block in `~/.claude/CLAUDE.md` (23 lines) | **every** Claude session, every project | ext | yes | `claude.doc` | **opt-in** — P5. Most of its rails are enforced by hooks / tools anyway; the rest belong in the tool descriptions |
| I2 | Same block in `$CODEX_HOME/AGENTS.md` | every Codex session | ext | yes | `codex.doc` | **opt-in** (P5) |
| I3 | `conf/codex-preamble.md` | prepended to each generated Codex skill | ext | with the skills | with the skills | **opt-in** — goes with the skills it heads |
| I4 | Orchestrator / steward / debugger body (`--append-system-prompt-file`) + rule rows | those roles' system prompts | ext | where the role runs | via role | **opt-in** (P5) |
| I5 | Mod `where.ts` line ("操作者此刻在哪") | every session's system prompt | ext | yes | no | **opt-in** (P5) — same as M7 |
| I6 | Hook notes: whats-new (H8), where (H12), refocus (H14) | next prompt / context | ext | yes | no | **opt-in** (P5) — counted once here |
| I7 | `/fleet-claim` seed for an issue worker | the worker's first turn | core | spawned issue sessions | — | **keep** — the user asked for that worker |
| I8 | `project_doc_fallback_filenames=["CLAUDE.md"]` passed to Codex | Codex reads CLAUDE.md | ext | yes | no | **remove** — Codex has its own AGENTS.md (N) |

7 ambient today (I1–I6, I8). After: none ambient — only I7, which the user asked for by
spawning the worker. 6 become opt-in, 1 (I8) is removed.

## 7. What is written into the user's own config files

| # | Key / line | File | Needs | Alone? | If off | Proposal — why |
|---|---|---|---|---|---|---|
| U1 | `permissions.defaultMode = bypassPermissions` + `skipDangerousModePermissionPrompt` | `~/.claude/settings.json` | core for unattended workers | `settings.fleet-override.json` | Workers stop on prompts | **remove from the user file; pass `--permission-mode` at fleet launch** — today the user's own `claude` in any terminal also runs bypassed (P4, N) |
| U2 | `permissions.allow` (18 fleet-script entries, from `fleet-up` / onboard) | settings.json | — | yes | none (redundant under bypass) | **remove** (P1) |
| U3 | `effortLevel = xhigh` | settings.json | — | yes | native default | **remove** (N) — role definitions carry effort |
| U4 | `outputStyle = Concise` | settings.json | — | yes | native default | **remove** (N) |
| U5 | `theme = auto` · `tui = fullscreen` | settings.json | — | yes | native default | **remove** (N) — 2 keys |
| U6 | `precomputeCompactionEnabled = false` | settings.json | — | yes | native default | **remove** (N) |
| U7 | `agentPushNotifEnabled = true` | settings.json | — | yes | native default | **remove** (N) |
| U8 | `hasCompletedOnboarding` · `hasSeenAutoDefaultNudge` | `~/.claude.json` | core — unattended first launch | yes | First launch stops on a dialog | **keep** (P1) |
| U9 | `leftArrowOpensAgents = false` | `~/.claude.json` | — | `FLEET_KEEP_AGENTS_KEY` | native key back | **remove** (N) |
| U10 | Trust pre-accept per worktree (`FLEET_PRETRUST`) | `~/.claude.json` | core | `FLEET_PRETRUST=0` | Trust dialog per worktree | **keep** (P1) |
| U11 | Codex `approval_policy=never` · `sandbox_mode=danger-full-access` | `config.toml` | core for workers | per key | — | **remove from the user file** — `fleet-codex.sh` already passes the bypass flag at launch (P4) |
| U12 | Codex `model_reasoning_effort=high` | `config.toml` | — | per key | native default | **opt-in** — part of a fleet Codex profile |
| U13 | Codex `check_for_update_on_startup=false` | `config.toml` | core — the updater owns versions | per key | Codex updates itself under the runtime | **keep** (P1 "update") |
| U14 | MCP servers (§3) | `~/.claude.json`, `config.toml` | — | — | — | counted in §3 |
| U15 | `~/.zshrc` PATH line for `~/.local/bin` | `~/.zshrc` | core | — | `claude` not found | **keep** (P1) |
| U16 | `~/.tmux.conf` source line for `tmux-attention.conf` (`reapply-tmux-attention.sh`) | `~/.tmux.conf` | — | — | none; fleet servers load it with `-f` | **remove** — it leaks fleet hooks into the person's own tmux (P4) |

19 keys or lines (U1, U5, U8 and U11 count 2 each; U14 is counted in §3). After: **5** —
U8 ×2, U10, U13, U15. U12 becomes opt-in. 13 leave the user's files: U2, U3, U4, U5 ×2, U6,
U7, U9, U16, and U1 ×2 + U11 ×2, which move to the fleet's own launch flags.

## 8. Services — the machine supervisor (`com.claude-fleet.node`, root)

| # | Item | What it does | Needs | On | Alone? | If off / fails | Proposal — why |
|---|---|---|---|---|---|---|---|
| D0 | Supervisor itself | Keeps children up, runs machine + account tables | core | yes | — | Everything below stops (mini2 now: #3100) | **keep** — and the doctor must catch a live-but-silent one |
| D1 | child `cred-proxy-shared` | Shared credential proxy | core | yes | — | Sessions lose credentials | **keep** (P1 credentials) |
| D2 | child `node-agent` (`ccquota agent --machine`) | Hub link for all logins | core | yes (waiting here) | — | Hub can't place / reach | **keep** (P1) |
| D3 | task `update` | One machine updater | core | yes | — | No updates | **keep** (P1 update) |
| D4 | task `memguard` | Kills runaway memory | core-safety | yes | `FLEET_MEMGUARD` | Machine can wedge | **keep** (P4) |
| D5 | task `orphans` | Orphan watchdog (report) | core-safety | yes | — | Leaks unseen | **keep** (P4) |
| D6 | task `shared-dirs` | Owns `/Users/Shared/claude-fleet` (heavy queue, sessions) | core | yes | — | Heavy queue / sessions dirs drift | **keep** |
| D7 | task `diskguard` (machine) | Disk / CPU / listener watchdogs | core-safety | yes | — | — | **keep, split** — see A5u below |

## 9. Services — the account table (16 launchd templates, run for each managed login)

| # | Unit | What it does | Needs | On | Alone? | If off / fails | Proposal — why |
|---|---|---|---|---|---|---|---|
| A1u | `base-sync` (60 s) | Fast-forwards each base checkout | core (fresh worktrees) | yes | own knob | New worktrees start from an old base | **keep** |
| A2u | `cleanup` (60 s) | Reaps merged worktree / window / branch | core | yes | `FLEET_CLEANUP` | Worktrees pile up | **keep** |
| A3u | `collect` (60 s) | Collector for list caches | core | yes | — | The list goes stale | **keep** (P1 reach) |
| A4u | `cred-proxy` (KeepAlive) | This login's credential proxy | core where `FLEET_CRED_PROXY=1` (every login made by `fleet-login-new.sh`) | yes | `FLEET_CRED_PROXY` | No credentials | **keep** (P1) |
| A5u | `diskguard` (60 s) | Disk / orphan / listener / mem watchdogs **and** pool top-up, `home_watch` (reopens orchestrator + steward), selftest, brew, restore `--auto` | core + ext | yes | no (all one tick) | One bad phase can stall the rest | **keep, split** — safety + restore stay; pool and orchestrator/steward watch move with their opt-ins (P3, P4) |
| A6u | `dispatch` (60 s) | Autofill: spawns from the backlog | ext | **idle** (`FLEET_AUTOFILL=0`) but ticks; also hosts the macOS-watch and breakage spawns | no | — | **opt-in** — and remove autofill as the next batch plans; the breakage spawn moves out first (P2) |
| A7u | `install-sync` (1800 s) | Follows stable | — on a managed login (it answers `off · managed`) | idle | `FLEET_INSTALL_SYNC` | none | **remove** from the managed account table — the runtime link is the update (P1) |
| A8u | `issue-bridge` (15 s) | Comment → worker turn | ext | **idle** (`FLEET_ISSUE_BRIDGE=0`), polls | own knob | — | **opt-in** — don't load the unit while off (P2) |
| A9u | `ledger-watch` (60 s) | Records closed sessions in history | core | yes | own knob | History misses closes | **keep** (P1 resume) |
| A10u | `peerlink` (KeepAlive) | Standing links to other machines | ext (multi-machine) | yes | `FLEET_PEERLINK` | Peer windows reconnect slower | **opt-in** — only with >1 machine (P2) |
| A11u | `pr-refresh` (15 s) | PR / CI state for the list | core for issue sessions | yes | — | PR state lags | **keep** |
| A12u | `quotawatch` (60 s) | Pre-emptive account rotation | ext (account pool) | idle without a pool | no | — | **opt-in** — load only with a registered pool (P2) |
| A13u | `sleep` (60 s) | Idle-session sleep (`observe` by default) | ext | yes, observing | `FLEET_SLEEP` | — | **opt-in** (P2) |
| A14u | `spinner` (KeepAlive) | Animates the status glyph | ext (cosmetic) | yes | no | — | **opt-in** (P2) |
| A15u | `webhook` (KeepAlive) | ~1 s PR state via `gh webhook forward` | ext | **idle** (`FLEET_WEBHOOK=0`), process alive | own knob | — | **opt-in** — don't run the process while off (P2) |
| A16u | `worktree-autoclean` (3600 s) | Prunes merged unattached worktrees | core | yes | — | Disk fills slowly | **keep** |

Today: 16 per login (6 logins on macmini, so 96 units). After: **8** kept (A1u–A5u, A9u,
A11u, A16u), **7** opt-in, **1** removed (A7u).

Seen on mini2: the admin login `verkyyi` still has its own 15
`com.claude-fleet.verkyyi.*` LaunchDaemons (not adopted). That is a second copy of this
table beside the supervisor's. It is outside this audit, but each proposal above must
cover both copies.

## 10. Other default-on behaviours (knobs in the session launch and daemons)

| # | Knob (default) | What it does | Needs | Proposal — why |
|---|---|---|---|---|
| K1 | `FLEET_ORCHESTRATOR` (follows `FLEET_HOST`, so on) | One orchestrator session per person | ext | **opt-in** — the next batch (P5) |
| K2 | `FLEET_STEWARD` (`count` where orch runs; `1` here) | Steward window / attention count | ext | **opt-in** (P5) |
| K3 | `FLEET_STEWARD_PARK` (1) | Parks stuck workers | ext | **opt-in** — with the steward |
| K4 | `FLEET_SCRATCH_POOL` (1 per repo) | Warm pool of pre-started sessions | ext | **opt-in** — costs a session per repo and caused #2502 (P2, P4) |
| K5 | `FLEET_STATUS_7501` (1) | Relay that reads the agent's own state | core | **keep** — primary state (P1) |
| K6 | `FLEET_WINDOW_REAP` (1) | Kills orphaned trees on window close | core-safety | **keep** (P4) |
| K7 | `fleet-session-wrap.sh` recovery page + `restore --auto` | A session never stays down | core | **keep** (P1) |
| K8 | `bin/tmux-shim` first on the agent's PATH | Refuses tmux destroy | core-safety | **keep** (P4) |
| K9 | `FLEET_AGENT_CFG` (1) + `FLEET_AGENT_LOCK=warn` | Composes default < team < local per launch | core | **keep**, with the lock list cut to the rails (P3) |

## 11. tmux configuration

| # | Conf | Where | Needs | Proposal — why |
|---|---|---|---|---|
| T1 | `tmux-fleet-server.conf` | every node fleet server (`-f`) | core | **keep** |
| T2 | `tmux-attention.conf` (+ hooks: window-reap, carry, sleep wake, 7501 replay, **steward-stats note**) | node | core | **keep**; the `fleet-steward-stats.sh note` hook moves with the steward (P5) |
| T3 | `tmux-bar.conf` | node | core | **keep** |
| T4 | `tmux-node-human.conf` (removes delete keys) | node | core-safety | **keep** (P4) |
| T5 | `tmux-view.conf` (看台 key tables) | node | core (reach) | **keep** |
| T6 | `tmux-shell.conf` | client shell | core (reach) | **keep** |
| T7 | `tmux-shell-stage.conf` | client stage | core | **keep** |
| T8 | `fleet-palette.conf` | both | core | **keep** |

The line added to `~/.tmux.conf` is counted as U16.

## 12. Shell hooks and CLI wrappers

| # | Item | Needs | Proposal |
|---|---|---|---|
| W1 | `~/.local/bin/claude` / `codex` → `<root>/current/tools/bin` | core | **keep** (P1 update) |
| W2 | `~/.local/bin/ccquota` | core | **keep** |
| W3 | Client `~/.local/bin/fleet` + PATH line (`fleet-install.sh`) | core (client) | **keep** |
| W4 | `fleet-session-wrap.sh` → `fleet-claude.sh` → `fleet-status-7501.py relay` | core | **keep** |
| W5 | Vendor tmux link `~/.local/share/claude-fleet-vendor/bin/tmux` | core | **keep** |
| — | `shell/cw.zsh`, `shell/fleet-login.zsh` | — | already retired from managed logins (#2702); the supervisor strips leftovers |

There are no shell hooks on a managed login today.

## Found on the way (not proposals)

- **#3100**: mini2's supervisor is alive but has not ticked for 78 minutes. The runtime
  directory holds 56 versions (18 GB) with no pruning.
- The four default MCP servers start **once per session**. That is ~6.4 GB on one
  macmini login. Making them opt-in (§3) is the largest single saving in this report.
- A user's own interactive `claude`, run from any terminal on a managed login, runs in
  bypass mode because U1 is written into user settings. That is why U1 should move to
  launch flags.
- `agent-overrides.json` turns off skills and commands only by whole category, and
  `conf/agent-locked.list` locks all hooks, the mod, and the github / fetch servers as
  single blocks. P3 ("removable one by one") needs per-item switches before any opt-in
  above is real.
