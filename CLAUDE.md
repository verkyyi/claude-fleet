# claude-fleet

A tmux + Claude Code setup for running many parallel Claude sessions in one
tmux session — one window per task, each in its own git worktree, with GitHub
issues as the backlog. See `README.md` for the pitch and `docs/ARCHITECTURE.md`
for the design.

## Installing / uninstalling this repo

**If the user asks you to "install", "set up", or "uninstall" claude-fleet:
Read [`docs/INSTALL.md`](docs/INSTALL.md) and follow it.** That playbook is the
full procedure — component table, install steps, daemon templating, uninstall.
Do not install from memory: read the doc and work from it.

## Conventions the code assumes

- **One fleet ≡ one tmux session ≡ one tmux server on its OWN named socket**
  (`tmux -L <session>`, issue #159). The socket LABEL is the session name (unique
  + sanitized per fleet). This is the **blast-radius rail**: a fatal signal from
  any worker — a stray `tmux kill-server`, an OOM-kill, resource exhaustion —
  takes down only *that* fleet's server, never the others sharing the machine.
  - Scripts run INSIDE a pane (Claude hooks, dash producers, the zoom/F9 binds,
    `commands/*.md`, every spawn) inherit the right socket via `$TMUX` — bare
    `tmux` is correct; new windows they open land on the same fleet's socket.
  - Scripts run OUTSIDE any session (the launchd/systemd daemons; `fleet-up`,
    `fleet-down`, `fleet-restore`) have no `$TMUX`, so they pass
    `-L "$(fleet_socket "$sess")"` on every call, and daemons fan out over
    `fleet_sockets`. See `bin/fleet-lib.sh`
    (`fleet_socket`/`fleet_sockets`/`fleet_list_windows_all`).
  - **No shared `tmux ls`.** Cross-fleet views iterate the sockets; the dash is
    per-fleet (scoped by `FLEET_SESSION`).
    **Ad-hoc sessions on the `default` socket are NOT fleets** — a fleet is created
    by `fleet-up` (which writes its conf + spins its socket).
  - **One fleet per login; there is no fleet switching** (EPIC #977, issue #980).
    Every repo a login works on lives in its one fleet, so moving between repos is
    the grouped `all` list; a heading picks where a new session goes (issue #1034
    removed the footer repo picker) — never a detach-and-reattach. Several fleets
    on one machine means several logins — the per-fleet sockets are what keeps
    them apart. Don't add a fleet picker, an other-fleet cue, or a spawn into
    another fleet: `dash-raw-session.sh` refuses one from a fleet pane.
- **The base checkout is edit-read-only** (hook-enforced): a worker edits inside
  its `issue-<N>` git worktree and lands via PR; the operator files/triages from
  the hub and hands implementation to a worker. Never commit to the base checkout.
- **Code-writing work is a fleet WORKER, never a subagent** (issue #811,
  hook-enforced by `hooks/agent-guard.py` on every fleet pane — hub, scratch,
  worker). A `general-purpose` / `claude` / `fork` subagent runs outside every
  rail above: the dash cannot see it, it has no `@claude_state`, the quota
  migration moves *windows* so a subagent that hits the limit dies mid-edit,
  several can write one worktree, and there is no one-worker-one-PR, no
  `/fleet-history` row, no handoff. Hand implementation to a worker
  (`dash-issue-session.sh <N>`, `fleet-issue-file.sh --spawn`,
  `dash-raw-session.sh`) — and when you need its result BACK the way a subagent
  returns one, `fleet-await.sh <N>` spawns it and blocks on the outcome off the
  child-report ledger (issue #812); a subagent is for READ-ONLY fan-out only —
  `Explore` / `Plan` / `claude-code-guide`, and never `isolation: worktree`
  (a fork worktree is edit-blocked by the base guard). `FLEET_ALLOW_SUBAGENT=1`
  is the operator's escape hatch.
- **A fleet hosts zero or more GitHub repos** (issue #788, switched on in #795),
  **every one put the same way** (issue #1937): `fleets/<sess>/repos/<slug>.conf`,
  ordered by `repos/.order` — `fleet-up.sh` and `bin/fleet-repo.sh add` both go
  through `fleet_repo_register`, `remove` is one road for any repo (the last too),
  and the fleet conf holds fleet-wide settings only. An old conf that still names
  `FLEET_REPO` is read for one version (that repo first) until
  `fleet_conf_repo_migrate` (`fleet-conf.sh migrate`) moves it; a caller with no
  window reads the first repo. **There is no main repo.** A window's
  repo is `@repo` (`@norepo 1` = deliberately none), resolved ONLY through
  `fleet_repos` / `fleet_window_repo` / `fleet_load_repo_conf` — never an
  ad-hoc `git remote` parse — and every join is
  on (repo, issue) or (repo, branch), never a bare number or branch name. A
  window whose repo is unknown is skipped, never guessed. **An EPIC's parent is
  in one repo, its members may be in any hosted repo** (issue #1942): a member is
  (repo, issue) — `owner/name#N` in the charter's list, read through
  `fleet_member_ref` / `fleet_sub_issues`, never a sub-issue's `.number` alone. The
  hub opens in `$HOME`. **One repo is not a mode** (issue #1943, EPIC #1935): it
  is `fleet_repos` counting 1, so there is no "is this a multi-repo fleet?" test —
  the repo comes from `--repo`, else the window's own, else the fleet's only one,
  else the caller ASKS (`fleet_target_repo`, rc 4). **The rule that replaced the
  degenerate case: adding or removing a repo changes NOTHING for the sessions of
  the other repos** — their keys, dash rows, working directories, restore rows
  and ledgers stay byte for byte; any change here ships a selftest leg that adds
  a repo and asserts it. Code that still reads an old format carries
  `# compat-1v: 下一批删`. `bin/multirepo-e2e-selftest.sh` is the end-to-end check
  (`leaks: 0/9`, and its `(n)` leg is the rule).
- **Cross-session addressing has ONE resolver, and it refuses rather than
  guesses** (issue #1537, EPIC #1529 E8). A key (`issue-<N>` / `scratch-<N>` /
  `<slug>:issue-<N>`) becomes a window only through `fleet_win_for_key`
  (`bin/fleet-lib.sh`; `fleet_worker_locate` layers the cross-machine answer on
  it): rc 0 + the id, rc 1 NOTFOUND, rc 2 AMBIGUOUS with one stderr line — two
  windows answer, or a bare `issue-<N>` in a 2+ repo fleet (the key must carry
  the repo slug). A warm-pool window (`@pool`, or parked in `<sess>-pool`) never
  answers — a closed scratch's number is recycled there, and before this a
  child's report "found" its gone parent in the pool; a stamped `@worktree` is
  never second-guessed by the pane cwd. `fleet-await.sh`, `fleet-peer-send.sh`,
  `fleet-mcp.py`, the children digest, the hub relay and report-parent all
  go through it; never add a bare `@issue` / window-name scan beside it. A
  `<sess>:<idx>` position and a bare window NAME are not addresses:
  `fleet-peer-send.sh`, `fleet-answer.sh`, `fleet-permission.sh` refuse them
  (exit 2) — a closing window renumbers the index, tmux prefix-matches the name
  (`scratch-1` → `scratch-12`); the dash pins a row to its `@id` at the
  keypress (`dash-answer.sh`). A pane reads ITS OWN binding through
  `fleet_pane_fmt`, never `-t "${TMUX_PANE:-}"`: an empty target is "the pane
  the operator is looking at", so inside tmux with no `TMUX_PANE` the read is
  nothing (and `fleet-comment.sh` refuses to post) — a popup has `$TMUX` but no
  `TMUX_PANE`, which is why `dash-popup.sh` hands it ours. An `@wid` handle no
  live window carries is refused by `fleet_wid_target` (nothing, rc 1) and every
  caller checks the rc. `bin/worker-locate-selftest.sh` F pins all of it.
- **A session's address is its lifelong IDENTITY, a key is only its name**
  (issue #1646, EPIC #1645 C1). Every spawned window carries `@fleet_id` (a UUID,
  minted once — `fleet_window_fid` mints lazily for an older window) and every
  road to another window carries it verbatim: fleet-restore (a `FID` row before
  the `WIN` row), fleet-migrate, fleet-move (the bundle's `<sid>.fleet-id`). A
  spawn stamps the parent's as `@origin_fid` beside `@origin`; resolve a parent
  through `fleet_origin_win` / `fleet_win_for_addr` (identity first, key second),
  never a bare `@origin` scan. `fleet_origin_heal` re-points `@origin` when a
  parent's key moves (`fleet-bind.sh`, dash rebind, the cleanup tick), so
  key-joined readers need no change. worker_id is `<fleet UUID>/<fleet_id>`
  (`fleet_worker_id`); `<fleet UUID>/<key>` stays a readable alias for one
  version (`fleet_worker_id_key` — a relay's `from`, a lease). `worker-identity-selftest.sh`
  pins it.
- **A session calls the fleet tools AS ITSELF: its credential** (issue #1809,
  EPIC #1813 C7). `fleet-session-wrap.sh` mints `FLEET_WORKER_CRED` per launch
  (`fleet-mcp.py --cred mint`, HMAC with `$FLEET_CONF_DIR/worker-cred/key`) and
  revokes it on exit; `fleet-mcp.py` verifies it on every call and refuses one that
  is expired, forged, revoked, from another fleet or from a pane that is not its
  session. It travels in the environment only — never an argv, file, config, log
  or tmux option; Codex forwards it by name (`env_vars`). No credential = the old
  marker path, logged `via=marker` in `logs/mcp-calls.log`. Spec:
  `docs/FLEET-MCP.md` «Identity»; `fleet-mcp-selftest.sh` J pins it. **With the hub on**
  (issue #1810, C8), a credentialed `spawn`/`await`/`send` also hands its script a
  node-signed worker assertion (`FLEET_WORKER_ASSERT`, HMAC keyed with the node
  token's hash) that `ccquota place` / the relay carry; the hub verifies it (401),
  keeps it to that session (404) and writes `worker_id` into `fleet_audit` and the
  journal. No hub ⇒ nothing minted, no request (`fleet-mcp-selftest.sh` K).
  **The old road closes on the worker seat** (issue #1812, C10): `hooks/bash-guard.py`'s
  `_DIRECT_TOOLS` table maps each script a tool wraps to its tool, and a worker
  that runs one (or calls the mod's retired `mcp__fleet__fleet_*`) is logged to
  `logs/mcp-bypass.log` (`FLEET_DIRECT_SCRIPTS=log`, the default) or refused with
  the tool's name (`block`); `FLEET_ALLOW_DIRECT_SCRIPTS=1` is the hatch, the
  operator / scratch / a person's shell are never touched. **With the service
  mounted the mod registers no tool** (0.4.0); **a session launched without it**
  (`--plugin-dir` only, before #1828 — no `FLEET_MCP_SERVER=1`) keeps the mod's
  `fleet_status` / `fleet_spawn` / `fleet_await` as the FALLBACK (issue #2057,
  mod 0.4.1): registered from `fleet-mcp.py --spec`, every call forwarded to
  `fleet-mcp.py --call <tool> <json>` — the one implementation; the guard logs
  those `fallback`, never blocks them; a forward that cannot run answers «reopen
  the session (/fleet-handoff · claude --resume), or run the script by hand».
  Never write a second copy of a tool's schema or logic in the mod. Spec:
  `docs/FLEET-MCP.md` «How a session gets it» / «The old road».
- **A spawn's parent is a LIVE session, or the spawn refuses** (issue #1355,
  EPIC #1645 C2). `fleet_origin_gate` (`bin/fleet-lib.sh`) runs in both spawners
  after `fleet_origin_canon`, before any window: a key no window answers to
  (`fleet_worker_locate` → `unknown`) or a caller inside tmux with no
  `$TMUX_PANE` and no `--origin` exits **4** with one stderr line, no window —
  an empty `@origin` there is "unknown", not "the hub". `--origin hub` is the
  operator; a backgrounded pass (`fleet_bg` / run-shell -b has no pane) states
  its origin explicitly. `fleet_epic_parent_key` has no EPIC-key fallback: no
  pane key ⇒ rc 1. `spawn-origin-gate-selftest.sh` pins it.
- **A recycled scratch number is a new GENERATION, not the old session** (issue
  #1538). `fleet_scratch_alloc <main> <base> <sess>` mints one per allocation
  (`children/.gen`, `fleet_key_gen`): the last holder's child ledger retires to
  `<key>.ndjson.<gen>` (no reader globs it), a child still running under the old
  holder has `@origin` moved to `@origin_retired <key>#<gen>`, a spawn stamps
  `@origin_gen`, and `fleet-report-parent.sh` files a report from an earlier
  generation to that retired book — never delivered, never relayed. Ledger rows
  carry `gen`/`child_gen`/`child_key` and `fleet_origin_map` skips a link filed
  by a previous holder. Issue keys are never minted; no `.gen` ⇒ byte for byte as
  before. The mod inbox is per server lifetime too (`fleet_mod_inbox_reset`).
  `fleet-children-selftest.sh` §3 and `origin-selftest.sh` D pin it.
- **Panel windows, not sessions.** Windows named `dash`, `plan`, `backlog`,
  `home` are treated as panels and excluded from the dash session list, the
  session counts, snapshots and restore. **The full-screen list retired**
  (issue #1533): by default no `plan` window is built — a fleet's resting window
  is `home`, a plain shell the task list draws beside (the ⌂ / F9 / prefix g keys
  that ended on it left the node with #1714; `fleet-sidebar.sh home` retires in #1739). `FLEET_DASH_WINDOW=1`
  brings the old dash hub back for one batch; adding a panel name means adding
  it everywhere `dash|plan|backlog` is spelled. **A window is told by its
  `@fleet_role` (home | panel | worker), never its name** (issue #1844): the
  person may rename any window, so home's heal, "is this a fleet" and the
  session caps read `FLEET_ROLE_FMT` + `FLEET_ROLE_AWK` / `fleet_win_role` (an
  unstamped window prints its name and falls back to the name rule), every opener stamps through
  `fleet_win_role_stamp`, restore reconciles by `@fleet_id` first, and a
  broken-out agent pane (`prefix !`) takes its window's `@` options along
  (`fleet-window-carry.sh`, the node conf's `window-linked[74]` hook). **The task list is the CLIENT's
  only** (issue #1713): `fleet-sidebar.sh` draws it on the shell's server
  (`FLEET_SHELL=1`), never in a node's fleet session — so there is no make-way
  rule, and a viewer arriving or leaving changes no pane on the node.
  `FLEET_SIDEBAR_NODE=1` is the drawer's selftest seam, never a setting.
  **So are the bar, the popups and every key** (issue #1714): a node's
  `conf/tmux-attention.conf` binds tmux's stock keys only (its "stock restores"
  block re-spells the ones an older version overrode, so a conf reload converges)
  and its status line is one static `请用 fleet` hint (`conf/tmux-bar.conf`); the
  person's keys live in `conf/tmux-shell.conf`. `fleet-keys-selftest.sh` leg 8
  pins both sides on isolated sockets — never add a `bind` to the node conf.
  The one exception only TAKES AWAY (issue #1840): `conf/tmux-node-human.conf`
  (fleet-human), loaded at the end of the node conf and again AFTER the person's
  `~/.tmux.conf`, unbinds prefix x & $ < > and swaps the pane's right-click for a
  read-only menu (`fleet-human-menu.sh`) — no key on a node deletes or respawns a
  session. One deleted anyway (`:kill-window`) comes back on the next tick:
  `fleet-restore.sh --auto` reopens an unfinished `@fleet_id` that vanished
  unmarked, and every closer the fleet runs on purpose (reap, ⌃x, q, move, stop,
  pool) marks it first with `fleet_win_retire` — a new one must too.
- **A view session shares the fleet's windows; never scan or name them bare**
  (issue #1489). A shell or proxy client of this machine (`fleet-remote-view.sh
  attach --shell` / a view id) attaches to a GROUPED session of its own,
  `<fleet>@view-<id>` — same windows, its own current window — so two people
  looking at one machine each see the row they picked. tmux then holds every
  window under two session names: `list-windows -a` lists it twice, and a bare
  `#{session_name}` resolved from a window / pane / `$TMUX_PANE` names whichever
  session was active last — a shell typing on m4 would make every hook in every
  worker pane resolve to its view. So every scan goes through `fleet_lw`
  (`bin/fleet-lib.sh`; `fleet_lw_fmt`/`fleet_lw_filter` for a command sequence,
  inline copies in `tmux-spinner.sh` and `fleet-alerts.sh` KEPT IN SYNC), and
  every window→session read uses `$FLEET_SESSION_FMT`
  (`#{?#{session_group},#{session_group},#{session_name}}` — a group is named
  after the fleet session it was grouped onto), in conf hooks too.
  `fleet-view-session-selftest.sh` lints both and pins the degenerate case: with
  no view session every output is byte for byte what it was. A view session is
  never a fleet (`fleet_is_view_session`): restore and the collector skip it, and
  `fleet-window-reap.sh --hook` ignores the unlinks its going fires.
- **Every session opens through `bin/fleet-session-wrap.sh`, and the fleet never
  stays down** (issue #1784). Spawners, restore, migrate, move, transfer, the warm
  pool and a sleeper's wake all launch the wrapper (never `fleet-claude.sh`
  directly — `session-wrap-selftest.sh` A lints it; `# wrap-ok: <why>` excepts a
  line). When the agent exits the window stays on a recovery page
  (`@claude_state=exited`: ↵ resume the same id · r new · q recycle); a fleet-made
  exit stamps `@wrap_quiet` before its `/exit`. A node server runs `exit-empty off`
  with a resident `home` window, and the diskguard tick's `fleet-restore.sh --auto`
  rebuilds a fleet whose session vanished — admit-gated, unfinished sessions only,
  never one `fleet-down` took down (`restore.down`). claude / tmux are found off a
  bare PATH by `fleet_find_tool` / `fleet_path_fill`; `fleet-doctor`'s `tools` row.
- **A running EPIC batch holds the live install still — one mark PER BATCH, any
  fresh one is true** (issues #953, #2062; EPIC #2074 C1). `/fleet-epic-run`
  stamps `$FLEET_CONF_DIR/global/epic-running.d/<repo slug>-<N>` every tick
  (`bin/fleet-epic-heartbeat.sh`) and at its end clears ONLY its own
  (`--clear <N>`; a bare `--clear` refuses while several batches are marked).
  `fleet_epic_running_fresh` (`bin/fleet-lib.sh`) is the ONE reader — every
  fresh mark, `; `-joined — and `fleet-install-sync.sh` defers the whole tick on
  it BEFORE the switch (a fresh mark ⇒ `deferred`, never `switched`; #1894 had
  left only the node-agent half behind the gate, and EPIC #1935's last member
  ran on a new floor). Busy windows still never defer. The pre-#2062 single
  file `global/epic-running` is read for one version, never written
  (`# compat-1v: 下一批删`). `install-sync-selftest.sh` O, `fleet-update-selftest.sh`
  E and the `epic-mark-overwritten` / `epic-fresh-switched` BREAK-IT drills pin it.
  **Only a batch WITH WORK holds, and never past the cap** (issue #2247): the
  stamp carries `--live` / `--inflight`, `fleet_epic_holding` reads `live 0` +
  `inflight 0` as idle (switched under) and a mark with no reading as active;
  one active mark holds one stable at most `FLEET_EPIC_HOLD_CAP_SECS` (2h), then
  install-sync switches and notes it on the EPIC. `install-sync-selftest.sh` O2,
  BREAK-IT `epic-idle-held` / `epic-hold-uncapped`.
- **A new way to break the fleet gets its row and its drill BEFORE its fix**
  (issue #1786). `docs/BREAK-IT.md` lists every known way (方式 · 后果 · 自愈方式 ·
  演练); `bin/fleet-break-it-selftest.sh` does each one for real on isolated
  sockets and a sandbox HOME and prints `PASS <id> <secs>s ≤<cap>s`. One row ⇔
  one `drill_<id>` (the test reds on either side missing); a way fixed in another
  repo is `登记：<ticket>`, listed, never drilled. Found a new one: add the row
  + drill, watch it go red, then fix.
- **A red base branch is ONE issue, filed through `--breakage`** (issue #2078,
  EPIC #2074 C7). `fleet-issue-file.sh --breakage` (the `file_issue` tool's
  `breakage: true`) fingerprints the breakage first — `fleet_breakage_probe`
  (`bin/fleet-lib.sh`): red per workflow on its last FINISHED run (never the
  head's check-runs — issue #2175), the commit that red streak started at, that
  run's first failed job, its first error line sans `:<digits>` — REST only, so it
  answers under a spent GraphQL budget. One issue per fingerprint: a `<key>/`
  lock under `$FLEET_CONF_DIR/global/breakage` (2 min) holds the same-second
  filers on one machine, the `<!-- fleet:breakage key=… -->` marker in the body
  is what another machine finds (`fleet_breakage_find`, the REST open-issue list,
  never `gh search` — its index lags). A later sighting gets a record-only
  「同一故障，来自 …」 comment on the first issue, its URL on stdout and **exit 5**;
  the caller waits for that issue (`await`), never files or spawns a second.
  **The flag is not the caller's to remember** (issue #2175): with neither flag, a
  title/body with a red word probes the base, and a red base the text names (the
  branch, or a red workflow / job / Go test — `fleet_breakage_pick`) is filed as
  `--breakage` all the same; `--no-breakage` (`breakage: false`) files plain. An
  ordinary filing with no red word runs none of it, byte for byte. `docs/BREAK-IT.md`
  `breakage-three-filers` / `breakage-no-flag` + `fleet-issue-file-selftest.sh` O–T pin it.
- **Stable moves only past the old-session replay** (issue #2075, EPIC #2074 C2).
  A session launched before a release keeps what it read at its start — the hook
  table, the mod's tool list, the MCP servers' tool lists — and runs everything
  they name from the NEW `~/.claude/fleet`; a looping scheduler is never reopened.
  `bin/fleet-oldcfg-replay.py` replays `stable`'s three files against the target
  tree in a sandbox (every hook command once per event with a minimal event JSON,
  every mod tool through the new `tools.ts`'s `TOOL_RE` + `fleet-mcp.py --call`,
  `tools/list` of every server old against new), and `fleet-stable.sh move`
  refuses on a finding (reason `oldcfg:`; `--force` moves anyway and logs one line
  in `logs/stable-move.log`) — a replay that cannot run refuses too. So a change
  to any «fixed at start» part keeps #2068's four rules for at least one version
  (CONTRIBUTING «老会话兼容», the PR template's line): a deleted / renamed tool
  keeps a handler (forward it, or say how to reopen), a deleted / renamed hook
  script keeps a forwarding shell or exits 0 quietly, a new guard also works
  through an entry the old table already calls, an MCP change as a tool.
  `fleet-oldcfg-replay-selftest.sh` J replays the repo's own table against its
  live tree on every PR, so a hook that cannot run in the sandbox is red there,
  not at the operator's release; old == new is GREEN at once. docs/BREAK-IT.md
  row `oldcfg-deleted-hook`.
- **An old session is either 会坏 or merely 旧, and the fleet can tell which**
  (issue #2076, EPIC #2074 C3). Every launch writes its START down — the hook
  table it was handed, the mod tools it registered, its MCP servers —
  content-addressed as `$FLEET_CONF_DIR/agentcfg/<sha>.json` (`@agent_cfg_manifest`,
  written by `fleet-agent-team.py session` beside the `@agent_cfg` fingerprint).
  `bin/fleet-oldcfg-check.sh <manifest>` judges it against the live install with
  the release gate's OWN functions (`fleet-oldcfg-replay.py --manifest`:
  `hook_paths_missing` / `tool_handler` / `mcp_scripts_missing`, static): gone ⇒
  `broken` (exit 2), merely new ⇒ `stale` (1), identical ⇒ `ok` (0); no manifest ⇒
  `stale`, never broken. `--sweep` (the collector's `agentcfg` phase, install-apply's
  `oldcfg:` step) writes `global/agent-cfg.broken`, the ONE list `fleet_cfg_state`
  consults (`fleet_cfg_broken_load`; a 4th/5th arg `<session> <window id>`): a
  stale/renew window on it reads `broken` — red 会坏·需重开 on the sidebar and the
  hub list, the doctor's `agentcfg` row counts it apart and WARNs, the idle reopen
  treats it as stale. Never compute broken anywhere else, and never from an `ok` /
  `unknown` window. The `oldcfg:` step NAMES the broken and the looping stale
  sessions (window · repo · issue · state) and reopens none (#2068 B). BREAK-IT
  row `oldcfg-broken-unmarked`; `fleet-oldcfg-check-selftest.sh`.
- **A session says when it may be closed: `@reap_policy`** (issue #1902). Chosen
  at spawn (`--reap` on both spawners, the `spawn` tool, the client's new-session
  question 「什么时候回收？」 → hub `reap` → the node's `worker_start`), changed by
  `bin/fleet-reap-policy.sh` (the `set_reap` tool, the sidebar's 改回收方式…):
  `merged[:<dur>]` · `done[:<dur>]` · `loop-end` · `at:<time>` · `keep`.
  `bin/fleet_reap_policy.py` is the ONE grammar. `fleet-cleanup.sh` honours
  keep / merged:<dur> and leaves the rest to `fleet-cleanup-idle.py`, which closes
  them through the same gates (history first, worktree kept, never while working,
  looping or holding a background job) — with `FLEET_SLEEP=on` too. The map
  carries it as a `REAP<TAB><fleet_id><TAB><policy>` row, the inventory as
  `reap=`. **No @reap_policy = the kind's old rule, byte for byte** —
  `fleet-cleanup-idle-selftest.py` (`ReapPolicy`, `PolicyGrammar`) pins both.
- **The fleet has ONE orchestrating session, and it is no row** (issue #1957).
  `bin/fleet-orchestrator.sh ensure` opens it (fleet-up, and the diskguard tick's
  `home_watch` reopens it — the same conversation when it can): `@fleet_role
  orchestrator`, `@norepo 1`, in `$HOME`, the login's agent at its strongest model
  and high effort, seeded `/fleet-orchestrate` — its ROLE rides the system prompt, not that seed
  (issue #2582): `--append-system-prompt-file skills/fleet-orchestrate/role.md`
  (≤ 60 lines; kept by the wrapper's ↵ resume) plus the mod's
  `fleet:orchestrator-role` section from the same file, so a `/clear` or a
  compaction leaves it the orchestrator (Codex: the seed alone). Its WORKING STATE rides a
  compaction too (issue #2583): `bin/fleet-orchestrator-state.py` writes
  `global/orchestrator.state.json` (batches · waiting · unread reports · loop) on
  PreCompact / SessionEnd / ScheduleWakeup / a `[child-report]`, and SessionStart
  (compact · resume · startup) hands back ≤ 40 lines ending in «re-arm the Loop»;
  a typed `/compact` gets its next turn from `fleet-compact-resume.sh`. And it comes back AS IT WAS (issue #2585): a Claude orchestrator on the wrapper's recovery page past `FLEET_ORCH_REVIVE_SECS` (30 s) is respawned in place by the next `ensure` on the same conversation, and every resumed one gets a first turn (the resume seed) — SessionStart resume/startup re-reads the batches and the Loop first, since a killed process ran no SessionEnd. BREAK-IT `orchestrator-exited`. A hand-typed /exit or /clear there
  first answers a hint (⌃D 放后台; the same command within 60 s, or `/exit!`, runs it —
  `mod/fleet/hooks/exit-guard.ts`, issue #2584); a plugin's run (the inbox) passes. While it is busy, `/qd` (mod `hooks/qd.tsx`, `immediate`, its window only — issue #2618) opens a title + repo dialog that files through `fleet-mcp.py --call file_issue {spawn: true}` past the model and the queue (`派：` prefix: `FLEET_ORCH_QD_PREFIX=1`). What waits behind its turn is counted (mod `hooks/queue.ts`, issue #2617): a prompt typed by hand over a running turn is +1, back to 0 at the next main-loop `turn.step` — a yellow 「排队 N 条 · 在忙 X」 line in its prompt band, `@orch_queue` → the inventory's `orchq=` (column 31) → `orch_<sess>`'s 7th column → 「排队 N」 at 「新任务」's end; no count (Codex) ⇒ the bar's 「编排在忙」, no 7th column ⇒ byte for byte as before. Restore / migrate / move read it
  as `home` (the role-aware formats map it there — never snapshotted, never moved);
  the session caps never count it (only `worker` does); `fleet_win_for_key
  orchestrator` addresses it. The inventory's column 20 `role=orchestrator` carries
  it to the client: `fleet-hub-sessions.sh` writes `orch_<sess>`, the rows skip
  it, 「新任务」 wears its state, ⌘N lands in its input (issue #2616 — none running: the hub's `orch_ensure` opens it on the holder, the bar says 「正在叫起…」; the client's `FLEET_COMPOSE=1` brings back the writing area, which hands it a draft with ⇧⇥). Off
  unless `FLEET_ORCHESTRATOR` (default: `FLEET_HOST`) — no orchestrator ⇒ byte
  for byte as before. **One per PERSON, not per machine** (issue #2117): with the
  hub on, `ensure` asks `/v1/node/orchestrator` (`fleet_orchestrator.go`: the
  holder sticks while online and not 维护中) and a machine not named closes its
  own (rc 5); `home_watch` asks every tick. `orch_<sess>` is one line,
  `orch_multi_<sess>` feeds the doctor's `orch` WARN; no hub / an old hub ⇒
  each machine decides alone. BREAK-IT `orchestrator-two`,
  `fleet-orchestrator-selftest.sh`.
- **The orchestrator has a STEWARD, and a calm beat calls no model** (issue #2670,
  EPIC #2668 C2). `bin/fleet-steward.sh ensure` opens it like the orchestrator
  (`@fleet_role steward`, `@norepo 1`, `$HOME`, `skills/fleet-steward/role.md` in
  the system prompt, one tier cheaper: `FLEET_STEWARD_MODEL` opus), home_watch
  reopens it on the same conversation (`steward.sid`); caps never count it, restore /
  migrate / move read it as `home`, `fleet_win_for_key steward` addresses it, the
  client draws no row for it (`steward_all_<sess>`). Its beat is
  `fleet-steward-tick.sh beat` (`bin/fleet_steward.py`) on the same tick, NO model:
  every `FLEET_STEWARD_EVERY` it reads the orchestrator's and the drivers' children
  ledgers, the epic marks and C1's ask rows (`fleet_decision.py`), answers due rows
  by their default, asks the backstop about a driverless batch's PRs, writes
  `global/steward.{state,delta}.json` — and hands the window one `[steward]` turn only
  when there is a new question, a BLOCKED/FAILED report or a driverless batch. Every
  answer (the steward's own, the person's from the orchestrator) goes through
  `fleet-steward-tick.sh answer`; the open rest becomes ONE `[decision]` to the
  orchestrator (`sheet`), and its open rows ride `@orch_decide` → the inventory's
  `orchdec=` (column 32, only when set) → `orch_<sess>`'s `decide=N` → a red
  「新任务」. GitHub writes ≤ `FLEET_STEWARD_WRITES` (20) a beat, the rest deferred.
  The beat also watches the fleet's OWN health (issue #2674, C6;
  `bin/fleet_steward_health.py`): `fleet-doctor.sh --json` against the last run (a
  new WARN/FAIL by row + first-line fingerprint, on 2 runs in a row; the first run is
  the baseline), idle sessions past `FLEET_STEWARD_IDLE_SECS` (2h) while the sleep
  scan accepted none, and `done:` ones the idle reaper closed none of (judged
  apart — a merged cleanup is no idle reap) ⇒ ONE issue per `<!-- fleet:health key=… -->` in the
  fleet's repo (`FLEET_STEWARD_HEALTH_REPO`, else the hosted `*/claude-fleet`), a
  recurrence a 「又出现」 comment; a red base stays `--breakage`'s. BREAK-IT
  `health-silent-pass`.
  `FLEET_STEWARD`: `0` byte for byte · `count` (default where an orchestrator runs:
  only the attention count, the node conf's [76] hooks → `logs/attention.ndjson`,
  `fleet-steward-stats.sh`) · `1` the window too. `fleet-steward-selftest.sh`;
  BREAK-IT `steward-exited`, `steward-write-storm`.
- **A stuck session gives its place back, and comes back as it was** (issue #2671,
  EPIC #2668 C3). The steward's beat runs `bin/fleet_park.py` (`fleet-park.sh`): a
  worker blocked `FLEET_PARK_BLOCKED_SECS` (900) or with no progress (state stamp,
  transcript, branch head) for `FLEET_PARK_STALL_SECS` (2700) — never one with a
  pending /loop or a background job — is asked over the peer channel to write its
  handoff, then (written, or `FLEET_PARK_GRACE` 300 s on) its screen is kept, its
  branch pushed, its window retired + stopped through `fleet-worker-stop.sh`
  (worktree kept), its issue labelled `blocked` with ONE 「停放：等 …」 comment
  carrying `<!-- fleet:park wait=<cond> sid=<sid> -->`. Parked = no window +
  `blocked` + the mark — there is no `@park`; the book is `global/park.json`,
  `global/park.idx` is what `fleet_parked` (fleet-restore.sh's skip) reads. When its
  condition (`answer:` · `pr:…:merged` · `issue:…:closed` · `time:` · `reply:`)
  holds, `dash-issue-session.sh --resume <same sid> --seed-file` reopens it on the
  same conversation. `@orch_park` → `orchpark=` (the last tag) → `park=N` on the
  client. `FLEET_STEWARD_PARK=0` (or a steward in `count`) parks nothing — `count`
  still measures (`fleet-steward-stats.sh stuck`). `fleet-park-selftest.sh`;
  BREAK-IT `park-lost-progress`, `park-restored-by-restore`.
- **Navigate by name, not index.** The hub/dashboard is placed at the lowest
  index once, at spawn; numbers still shift when a window closes
  (`renumber-windows on`).
- **A dash key is never a literal ctrl chord.** tmux swallows its prefix before
  any pane sees it, so every dash `--bind` goes through `bin/dash-keymap.sh`
  (issue #556): add the action to its table, bind `$DASH_KEY_<ACTION>` in
  `tmux-dashboard.sh`, list it in `fleet-keys.sh` via `dg`. Pick a default that
  is unbound in fzf and no one's prefix; `fleet-keys-selftest.sh` holds the three
  in lockstep.
- **Never run destructive tmux on the live server**, and test tmux tooling on an
  **isolated socket** — `tmux -L scratch …`, or the `-S <sock>` PATH-shim pattern
  the selftests use (`bin/dash-marker-selftest.sh`). A delete aimed at a FLEET's
  server (kill-server / kill-session / a session's kill-window, on `-L <fleet>`
  or the ambient one) is refused by ONE rule, `bin/tmux-shim/tmux` (issue #1841):
  `fleet-session-wrap.sh` puts it first on every agent's PATH, `shell/cw.zsh`'s
  `tmux()` hands it any `-L`/`-S` call, and `hooks/bash-guard.py` asks it
  (`FLEET_TMUX_SHIM_CHECK=1`) before a Bash statement runs — a login shell's
  path_helper reorders PATH. A test server and the fleet's own scripts pass;
  `FLEET_ALLOW_TMUX_DESTROY=1` passes a deliberate destroy through.
- **Load experiments go through `bin/fleet-loadgen.sh` — never a hand-written
  `trap`** (issue #697). Putting the box under CPU pressure is legitimate work
  (#691/#693 exist to ask whether a real-time assertion survives a busy machine);
  the hand-written `(while :; do :; done) & … trap 'kill $BURN' EXIT` form is
  what is not. On 2026-09-15 that snippet leaked 8 spinning zsh processes — the
  trap never fired, the trailing `kill` was never reached, and they lived 3h20m
  at ~70% CPU each as `PPID=1` orphans, took the machine to load 108 until `ps`
  itself timed out, wedged both daemons, and poisoned the evidence in an
  unrelated issue (#682). A trap lives in the PARENT, so anything that kills the
  parent outright takes the cleanup with it. `fleet-loadgen.sh` moves the
  deadline into each BURNER instead — a kernel `alarm(2)` armed before the exec
  (preserved across `execve`), with a `$SECONDS` bound under it — so a SIGKILLed
  parent or a closed pane still cannot leak one. `fleet-loadgen.sh 4 120 -- <cmd>`
  runs the experiment under the load and stops it when `<cmd>` exits;
  `--status`/`--stop` manage a detached batch. It also **refuses (exit 3) on a
  host already above 1 load/core and clamps to half the cores** unless `--force`
  (issue #922): a bounded `8 900` beside three fleets still took load to 152 and
  stalled every fleet daemon — the burners' deadlines bound a leak, not a size.
  The backstop is the **orphaned-runaway watchdog** on the diskguard tick
  (`--watch`, 60s): `PPID=1` + sustained CPU + a Claude/fleet argv fingerprint,
  **ON by default and report-only**. It is the only defense here that is NOT keyed
  on a worktree or a pane — which is exactly why it is the only one that saw the
  leak. `bin/fleet-diskguard.sh --orphans` on demand; `fleet-doctor`'s `machine`
  line carries load-per-core + any live orphan.
- **An array that can be empty is NEVER expanded bare** (issue #703). macOS ships
  bash 3.2, where `"${a[@]}"` / `"${a[*]}"` on an EMPTY array is a fatal `unbound
  variable` under `set -u`; bash 4+ expands it to nothing, so CI (bash 5) and every
  `bash -n` see a clean script and the mine goes off only on the operator's machine,
  only on the path where the array happens to be empty. Write `${a[@]+"${a[@]}"}`,
  or `"${a[*]-}"` inside a string — both are exact no-ops when populated, and both
  were already the idiom here. `bin/bash32-array-selftest.sh` enforces it across
  `bin/`, with NO credit for a nearby `[ "${#a[@]}" -gt 0 ]` guard (a guard is a
  non-local invariant the next edit can break without touching the expansion);
  a deliberate exception marks its line `# bash32-ok: <why>`. Where a bash 3.x
  exists it also `bash -n`s every script, which nets the SYNTAX half of the same
  family — a `case` inside `$(…)` must write its pattern `(pat)`, or 3.2's
  command-substitution scanner dies on the `;;`.
- **A `local` never takes a zsh special parameter's name** (issue #1633). Claude
  Code's Bash tool runs the login shell — zsh on the operator's Mac — so a skill's
  `source fleet-lib.sh` runs every function IN ZSH, where `path` is tied to
  `$PATH`: `local … path …` emptied PATH, `tmux` vanished, and `fleet_origin_key`
  came back empty. Same for `argv`, `status`, `pipestatus`, `options`, `fpath`,
  `commands`, `aliases`, …: write `pth` / `cmdline` / `stfile`.
  `bin/zsh-local-selftest.sh` lints every `local`/`typeset`/`declare` in `bin/`
  (`# zsh-ok: <why>` excepts a line; bash32-array-selftest runs it on every PR);
  origin-selftest A runs the key under zsh.
- **The selftest gate isolates at the ROOT, not per test** (issue #660).
  `bin/run-selftests.sh` re-runs the suite from a throwaway **shadow install
  root** (`bin/selftest-shadow-root.sh`): `bin/` mirrored file-by-file as
  symlinks inside a REAL dir so `$BIN/..` stays inside the shadow, no
  `fleet.conf` beside it, an empty `logs/` and `FLEET_CONF_DIR`, and every
  `FLEET_*`/`CCQUOTA_*` variable stripped from the environment. So a new selftest
  needs no "unset the operator's config" preamble of its own — and must not add
  one; and a test that builds its OWN sandbox `bin/` + `fleet.conf` keeps working,
  because the isolation is a root swap, not an env override.
  `bin/selftest-isolation-selftest.sh` pins all of it. Run one test through the
  same prelude with `run-selftests.sh <name>` (globs work). ⚠️ The shadow's `bin/`
  is symlinks to the LIVE files, so **don't edit `bin/` while the gate is
  running** — a test (or the runner itself) re-reads a half-written script and
  dies on a syntax error that has nothing to do with your change.
- **CI runs only the RELATED tests, once per commit — and the worker's box runs
  none** (issue #1374). `run-selftests.sh --changed <base>` selects the tests
  whose source names a changed file's basename, or — for a `bin/*lib.sh` — a
  function (or top-level variable) the diff touched, plus a lint group that
  always runs (`SELFTEST_ALWAYS` in the runner); each pick prints as
  `select: <test> ← <reason>`. A change to the harness (`run-selftests.sh`,
  `selftest-shadow-root.sh`, `.github/workflows/selftests*.yml`) or an
  unresolvable base falls back to the full suite. `selftests.yml` runs it on
  `pull_request` and on `push` to **master only** (the branch push duplicated
  the PR run). **The BSD half is not on the PR** (issue #2286): `selftests-macos.yml`
  runs `--changed <the previous master>` on every `push` to master (2 shards — 5
  macOS jobs per free account; a newer push cancels the older run) and stays FULL
  nightly; the merge gate is the ubuntu checks alone (`fleet-pr-verdict.sh` drops
  any `macOS shard *` an older PR still carries). It gates RELEASING instead:
  `fleet-stable.sh move` refuses (`macos:`) a target whose newest macOS run is not
  green and dispatches the full suite on a target with none, and a red master run
  is filed once as a breakage by `bin/fleet-macos-watch.sh` (dispatch tick →
  `fleet-issue-file.sh --breakage`) with its fixer spawned. So **don't run the
  suite locally**: push, open the PR, read the gate. Locally run only the one
  test that reproduces a CI failure (`run-selftests.sh <name>`), never the full
  gate or `--changed`. A new selftest is selected when its own file changes or
  a file it NAMES does — name the scripts you drive.
- **CI SHARDS the gate; the tests themselves still run one at a time**
  (issue #681). `run-selftests.sh --shard K/N` packs the N slices by each
  test's recorded cost — `bin/selftest-durations.txt`, longest first into the
  lightest slice (issue #1390: a stride once stacked the six slowest tests into
  one shard); no row ⇒ the table's median, no table ⇒ exactly the old stride —
  and `.github/workflows/selftests.yml` fans that over an 8-job matrix, each
  shard printing its predicted load (WARN past 400s of the 480s step bound).
  Refresh the table with `bin/selftest-durations.sh --run <run id>`. Edit the `shard:` list to change the width and nothing else:
  the split reads `strategy.job-total`. The width is set by measured runner
  VARIANCE, not suite size — at 4 the same shard ran 2m36s and 4m2s on the same
  commit in sibling runs. In-runner concurrency was built, measured
  (196s vs 1428s of summed test time, 8-wide) and **rejected** — ~9 tests carry a
  real-time budget that only holds on an idle box (needs-reconcile drove the
  spinner at `FLEET_NEEDS_RECONCILE_SECS=1`, whose strike table went stale after
  3× that — fixed in #691 by making the TTL its own knob, but the other ~8 keep
  their window), and two went red under load while passing alone. Widening those
  windows would loosen the assertions worth having, to buy speed a second runner
  gives away.
- **Every run prints each test's duration and the slowest few.** Same reasoning
  as `over=` in #653: without the number, the next approach to the ceiling is a
  manual hunt across the whole suite. `FLEET_SELFTEST_SLOWEST` sets how many
  (default 10). The matrix jobs each append theirs to the run's summary page, so
  a test getting slower surfaces on the run that made it slower — not on the run
  that went red.
- **The gate has a BSD half now — CI is no longer ubuntu-only** (issue #696).
  Every workflow used to be `runs-on: ubuntu-latest`, while every place the
  operator actually runs the gate (a worker pane, the live install) is macOS, so
  a GNU-only idiom was green in CI and broken on the only machine that matters.
  #689 was that: a GNU-only `\|` alternation in a sed BRE, which BSD sed matches
  LITERALLY and says nothing about — so `run-selftests.sh`'s env scrub was a
  SILENT no-op on a Mac from #660 to #681. Two defenses, because they catch
  different halves:
  - `bin/portability-selftest.sh` — a lint, free on the existing ubuntu shards.
    Flags `sed`'s GNU-only BRE metachars (`\|` `\+` `\?` `\d`), a `sed -i` with
    no ATTACHED suffix, and `readlink -f` / `date -d` / `stat -c` / `base64 -w` /
    `mktemp -p`. ⚠️ It is COMMAND-SCOPED, not line-scoped, and that is the whole
    craft of it: BSD **grep** *does* support `\|`, and awk's `/^\|---\|/` and a
    `\|` inside `grep -E` are escaped literal pipes — all 18 of this repo's `\|`
    sites are correct, so a naive `grep -rn '\\|'` would red on every one and get
    muted in a week. A GNU-only option is exempt inside a both-ways fallback
    (`stat -f … || stat -c …`) — but only when spelled on ONE logical line, so the
    exemption stays local; a fallback split across two lines marks itself
    `# portable-ok: <why>` (see `fleet_epoch_from_iso`).
  - `.github/workflows/selftests-macos.yml` — the full 6-shard suite on
    `macos-latest`, nightly (18:17 UTC = 02:17 CST), plus `workflow_dispatch`
    (input `sha`: the full suite on that commit, named `… @ <sha>`); on every
    push to master it runs `--changed` against the previous master. **Since
    #2286 it runs AFTER the merge, not on the PR**: the queue for 5 macOS slots
    had made the merge gate wait a median 21 minutes (worst 56) on a check that
    guards releasing, not merging — master reaches a machine only when `stable`
    moves. So the BSD half's verdict lands in two places: `fleet-stable.sh move`
    (gate 5, `macos:`; no run on the target ⇒ dispatch + wait; `--force` logs) and
    `bin/fleet-macos-watch.sh` (a red master run ⇒ ONE breakage issue + its fixer,
    on the dispatch daemon's tick, only for a repo carrying this workflow and
    `bin/fleet-stable.sh`). BREAK-IT row `macos-red-to-stable`.
    This is the half a lint structurally cannot do: **behaviour** differences.
    #703 (a bare `${a[@]}` on an empty array is fatal on bash 3.2, a no-op on
    bash 5) is not an enumerable idiom, only an observable outcome. The lint nets
    the next #689; only a real BSD run nets the next #703. It asserts `sed` on
    PATH is genuinely BSD before running anything — if a runner image ever puts
    GNU coreutils first, the job fails loudly rather than testing nothing.
    ⚠️ It runs on the FULL matrix because GitHub-hosted runners are **free for
    public repos**; the 10× macOS multiplier applies to private ones. **Make this
    repo private and this workflow starts billing ~150 min/night** — cut `shard:`
    to one entry or drop the schedule.
- **Heavy jobs queue machine-wide** (issue #1295). `bin/fleet-heavy.sh -- <cmd>`
  is a counting semaphore shared by EVERY login on the box (`FLEET_HEAVY_SLOTS`,
  default 3): slots are `fcntl.flock`s on `/Users/Shared/claude-fleet/heavy/slot-K`
  (1777 dir, never under a `$HOME`; each login writes only its OWN 0644 files —
  slots opened read-only, `hold.` / `wait.<login>.<pid>`, `events.<login>.log` —
  and root's `shared-dirs` supervisor task, `bin/fleet-shared-dirs.py`, owns the
  dirs and slots and sweeps a file planted under another login's name, issue
  #2299; `sessions/` likewise), held by a python3 parent that
  runs the command as its child — so a SIGKILLed holder frees its slot at once
  and a daemon the command leaves behind cannot keep it. `hooks/bash-guard.py`
  PREFIXES the wrapper onto any Bash statement whose command matches
  `FLEET_HEAVY_RE` (git push, pytest, npm test, run-selftests.sh, …) — a pure
  prefix, quotes and heredocs untouched; business repos change nothing. A queue
  never blocks forever (`FLEET_HEAVY_WAIT`, and a foreground call caps at half its
  tool timeout); `FLEET_HEAVY=0` turns the rewrite off; `fleet-heavy.sh --status`
  lists holders, waiters and the last 24h's wait median/max. **Light runs never
  queue** (issue #1313): `FLEET_HEAVY_LIGHT_RE` is matched first — a pytest aimed
  at a file / `::` node / `-k` (no xdist `-n`), `npm test -- <file|-t>`,
  `run-selftests.sh <name>` (no glob, no option) pass through untouched.
- **A fleet temp server binds `127.0.0.1`, never `*`** (issue #1154). An agent's
  `python3 -m http.server` / dev server defaults to every interface and outlives
  its window as a `PPID=1` orphan — the 2026-09-24 audit found one serving the
  whole scratchpad root (`/private/tmp/claude-<uid>`) to the LAN. Three rails,
  all in `bin/fleet-lib.sh` (`fleet_listen_rows` / `fleet_orphan_listeners`):
  teardown kills a kept worktree's listeners (`fleet_reap_worktree_listeners`),
  the diskguard tick reaps orphaned fleet-anchored listeners older than
  `FLEET_ORPHAN_LISTEN_SECS` (6h; kill by default), and `fleet-doctor`'s `listen`
  line WARNs on any fleet process on the LAN. "Fleet-anchored" = cwd in a Claude
  scratchpad root, a `*-issue-N`/`*-scratch-N` worktree (even a removed one) or
  `~/.claude` — never a machine-wide hunt. Claude Code names a session dir by
  turning EVERY non-alphanumeric into `-` (`fleet_mangle_path`), not just `/`.
- **A closed window takes its process trees with it** (issue #1298). tmux's
  `window-unlinked` / `pane-exited` / `after-kill-pane` hooks run
  `bin/fleet-window-reap.sh --hook`, which kills every PPID=1 tree of ours whose
  top's cwd is a worktree / session-scratchpad anchor that NO live pane or
  `claude` still works in (`fleet_orphan_trees`) — a disowned job, a Bash-tool
  `&`, an MCP server's headless browser die seconds after the close, not days
  later. tmux cannot say which worktree the closed window had and macOS has no
  session id, so the liveness of the anchor is the whole rail: another window in
  the same worktree spares everything there. Exempt argv (doc-preview, the
  fleet's own detached scripts) anywhere in the tree spares it; a rotation lease
  spares the worktree; `FLEET_WINDOW_REAP=0` turns it off; reaps are logged in
  `diskguard/window-reap.log`.
- **The operator's screen is THEIR computer, not this one** (issues #1367, #1379).
  They SSH in from iTerm2, so `open <url|file>` here shows it to nobody.
  `bin/fleet-open.sh <url | :port[/path] | file>` (skill `skills/fleet-open/`)
  writes an `OSC 1337 ; Custom=id=<secret>:<base64 JSON>` escape to the client
  they are using — a page on this machine travels as `kind=forward` + its
  loopback port, which their side (#1380) port-forwards over its ssh; the secret
  is `~/.config/claude-fleet/open.secret` (0600). Files go through
  `bin/fleet-show.sh`. Both share ONE client picker + `lock-client` writer,
  `bin/fleet-client-lib.sh` — never a second copy. No iTerm2 → `open-url.sh`
  (2226 tunnel, else popup + OSC 52).
- **A SPOT node is the hub's machine, not anyone's** (issue #1428). With
  `CCQUOTA_FLEET_SPOT_IMAGE` set, the hub (`tokenledger/internal/api/fleet_spot.go`)
  starts a pod of `extras/spot-node/` on the cluster's SPOT machines when
  placement finds no fixed machine with room, and deletes it after 30 idle
  minutes. Its kind (`ephemeral`) comes from the join code the hub minted,
  never from the node; placement multiplies its score by the SPOT weight so a
  fixed machine with room always wins; a reclaim (the kubelet's SIGTERM) makes
  the agent tell the hub and run `bin/fleet-spot-evacuate.sh` (`fleet-move.sh
  --rebalance --max all`), and whatever is still on it when the pod is gone is
  意外下线: leases released at once, nothing re-dispatched, the record kept in
  `fleet_spot_nodes`. Off (no image) adds nothing — `TestSpotOffAddsNothing`
  and `fleet-spot-evacuate-selftest.sh` case A pin the degenerate case.
- **A managed machine has ONE root daemon for its machine-level work** (issue
  #2331, EPIC #2329 C3). `bin/fleet-node-supervisor.py` (`com.claude-fleet.node`,
  root, KeepAlive, written by its own `install` — never a `launchd/*.tmpl`, which
  every login would install) keeps its children up (the shared credential proxy,
  C5's node program; backoff 1 s doubling to 60 s) and runs the machine task table
  once — each task one copy, under `locks/<task>.lock`; account tasks are the
  account half below. It runs only root-owned code from the root runtime, moves
  fleet plist leftovers to `/var/db/fleet-node/attic/` (7 days, `attic restore`),
  only REPORTS an unexpected live plist, and adopts a live child after a restart
  (`state.json`). A child whose old LaunchDaemon is still installed stays
  launchd's (`legacy`). `status` is one line per item; the doctor's `node` row
  reads `status --check` (not installed ⇒ no row). BREAK-IT `node-supervisor-dead`.
  **The account half is the same daemon** (issue #2332, C4): ONE account table —
  every `launchd/*.plist.tmpl` of the runtime but the machine's (memguard), each
  with its own interval / environment / log paths, a KeepAlive one (spinner,
  webhook, cred-proxy) as a child — run for every login `account adopt <login>`
  took over, DEMOTED to it (initgroups/setgid/setuid, its HOME / USER / PATH /
  `FLEET_CONF_DIR` / TMPDIR; the log opened by the demoted process, never root).
  adopt boots the login's own LaunchAgents / LaunchDaemons out into the attic
  (kept, never purged) and puts every one back if one will not unload;
  `account release <login>` is the one-command way back. `accounts.json` is the
  one list: `fleet_node_manages` (`fleet-daemon-lib.sh`) reads it, and a managed
  login's `fleet-install-apply.sh` renders no plist, its probe asks the daemon.
  expected.json's `accounts` narrows who runs. No accounts.json ⇒ byte for byte
  as before. BREAK-IT `account-adopt-stuck`.
- **A managed machine has ONE node program, `ccquota agent --machine`** (issue
  #2333, EPIC #2329 C5). Root, started by the supervisor's `node-agent` child once
  `/var/db/fleet-node/machine.env` + `logins/<login>.env` exist; one control link
  with the machine's token, each login a tenant that says its own hello on it
  (`Message.login`, its own token in `Hello.login_token`) and stays its own
  endpoint. A login is proven ONLY by `loginEndpoint` (`internal/api/node_machine.go`)
  — anything else is `WRONG_LOGIN`, on both halves — and every command a tenant
  starts goes through `prepCmd` (`internal/agent/runas.go`): dropped to the login,
  refused rather than run as root. `docs/MANAGED-NODE.md` §6; BREAK-IT
  `machine-agent-wrong-login`.
- **A managed machine has ONE updater, and every part moves with the release or
  none does** (issue #2334, EPIC #2329 C6). `bin/fleet-node-update.py` is the
  supervisor's `update` task (root): `release.json` (repo root, signed with the
  tree by C7) pins ccquota · Claude Code · Codex · tmux by artifact; each lands
  under ONE link — `<root>/current` → `<sha>/` (runtime, `bin/ccquota`,
  `tools/bin/<tool>` → the content-addressed root cache) — so a switch is one
  rename and `.prev` the way back. The bootstrap cache's Claude and every managed
  account's `~/.local/bin/{claude,codex}` follow (linked demoted, never over a
  regular file); the shared credential proxy's root code copy follows too
  (`<current>/bin/fleet-credsep.py machine refresh` on switch, rollback, before the
  verify and every tick; the proxy restarts on new bytes — launchd's, or the
  daemon's child by its `reload` on the copy's dir; the doctor's `credsep` row FAILs
  on a stale copy or a proxy still on old code — issue #2435); the daemon restarts
  last (`update-restart.json`). The machine
  doctor (`fleet doctor --machine`) after the switch: a FAIL the old version did
  not have rolls EVERYTHING back and skips that sha. `update.json`'s phase makes
  a killed tick resume or roll back. A managed login's install-sync follows the
  MACHINE, not stable (issue #2688): its target is the commit the runtime's
  `current` names, through its own apply + doctor gate (no `current` yet ⇒
  `off`; BREAK-IT `managed-login-install-stale`); `fleet doctor --installs`
  (`bin/fleet-installs.sh`, issue #2692) lists the runtime, every login install
  and every client shell against stable. `fleet-stable.sh move` refuses an updater tree without a valid
  release.json (`release:`), or one pinning an artifact the hub's
  `/v1/fleet/release/artifacts` lacks (`artifacts:`; the hub never builds such a
  release either — issue #2631, BREAK-IT `release-artifact-missing`). The pinned
  Claude Code is the hub's to fetch (npm, sha512 integrity), never a person's upload. `docs/MANAGED-NODE.md` §7; BREAK-IT `node-update-half`,
  `credsep-stale-after-switch`.
- **A Mac becomes a managed machine by ONE command, and the same command repairs
  it** (issue #2330, EPIC #2329 C1). `sudo fleet node install --join <码>`
  (`bin/fleet-node-install.sh`; a 托管 join code's line pipes the copy the hub serves
  at `/install/bin/fleet-node-install.sh`) converges 检查 · 加入 · 发布公钥 · 期望状态 ·
  ccquota · 运行时 · 角色用户 · ssh CA · 守护, each looked at before it is done
  (`跳过` when it already holds — a token the hub still accepts spends no code),
  each file by one rename, a failing step putting back what it replaced. The
  runtime is the updater's own tick (C6), the daemon the supervisor's `install`
  (`install --check` = nothing to do), the role account `fleet-credsep.py role` —
  never a second copy of any of them. `docs/MANAGED-NODE.md` §8; BREAK-IT
  `node-install-half`; `fleet-node-install-selftest.sh`.
- **A machine has three words — online, 维护中, lost — and only the middle one is
  the operator's** (issue #1427). `maintenance` is the fleet setting
  `fleet.node_maintenance.<machine>` on the hub (`bin/fleet-node-maintenance.sh
  enter|leave|status` from the machine with its node token; the `/nodes` card's
  button or `PUT /v1/fleet/settings` for any machine), read wherever a status is
  surfaced — roster, `fleet_sessions` (sidebar `◐`), placement (excluded, auto
  AND named), `move plan`, `fleet connect` home — and never computed from a
  heartbeat; lost still wins, so leases lapse on the 30-minute TTL as always.
  `docs/MULTI-MACHINE-OPS.md` is the runbook (planned outage = flag, evacuate,
  wait, power off BY HAND; unexpected = nothing is re-dispatched). **No step
  that takes a machine down or restarts an agent is ever automated**, and the
  drill runs only at a time the operator confirmed. No setting ⇒ two words,
  byte for byte: `TestMaintenanceOffAddsNothing`, `fleet-node-maintenance-selftest.sh`
  leg A, `dash-remote-rows-selftest.sh` pin it.
- **The measurement bus has ONE writer, `conf/statusline.sh`, and its feeders**
  (issues #1452, #1459, #2431). Every `@ctx_pct/@ctx_limit/@ctx_band/@model/@effort/@rl*`
  stamp goes through that script — Claude Code's `statusLine` feeds it the JSON on
  stdin; the fleet mod (`mod/fleet/hooks/usage.ts`) feeds it `--from mod key=value …`
  from inside the session (context + rate limits off `session.measure`, model +
  effort off `turn.step`, a `/model` off a 2 s poll) and marks `@ctx_src mod`.
  A third feeder carries QUOTA only (issue #1978): with `FLEET_CRED_PROXY=1` the
  credential proxy keeps each session's last rate-limit headers (Claude and
  Codex alike) and `bin/fleet-proxy-quota.sh` hands them to `--from proxy` on
  the window whose `@cred_sid` it is (`@rl_src proxy`, `@rl_ts` = the reading's
  time); while that stamp is fresh (`FLEET_RL_PROXY_FRESH`, 300 s) the other two
  leave `@rl*` alone. No proxy ⇒ no such stamp ⇒ byte for byte as before.
  A Codex session feeds it too (issue #2431): `bin/fleet-codex-session.py`'s hook
  runs `--from codex pct= limit= model= effort=` (effort off the rollout's
  `turn_context`, else `config.toml`) and stamps nothing itself (`@ctx_src codex`).
  The script also stamps `@ctx_left` (% left) and `@ctx_ts` (the reading's time,
  re-stamped at most once a minute when nothing changed) — the node
  inventory's columns 24-28 and `fleet ls` read those stamps, and the CLIENT's
  top line (`bin/fleet-topbar.py`, the sidebar's field 19) is the one place that
  draws `剩余 62% · Opus 5.5 · high` (grey past 5 minutes) — the node's pane
  header no longer does (issue #2717).
  Never add a second place that computes a band or rounds a percent. Claude Code
  keeps one blank bottom row for ANY `statusLine`, so the key is removable once
  every Claude window on the login runs mod ≥ 0.2.0: `bin/fleet-statusline.sh
  off` is the only thing that removes it, it refuses while a window would go
  blind, and `/fleet-sync-install` never touches the key.
- **The agent says its own state: OSC 7501, read by a relay** (issue #2536, EPIC
  #2535 C1). Claude Code ≥ 2.1.295 reports working / blocked (permission ·
  question · auth + its words) / done / idle / error as `ESC ] 7501 ; state=…:kind=…:msg=<b64>`,
  but only to a terminal that answers its `OSC 7501 ; ?` probe before the DA1
  reply — no env or setting forces it, and inside tmux nobody answers (tmux answers
  DA1 itself, so a `pipe-pane -IO` responder is always late). So `fleet-claude.sh`
  runs the agent under `bin/fleet-status-7501.py relay` in a tmux pane with a
  terminal: a pty that answers the probe IN the stream, passes every byte through
  untouched, keeps the wrapper's Ctrl+Z rule (a guard in the agent's process group)
  and stamps `@agent_status` (JSON: state, kind, msg ≤200, app, ts) +
  `@agent_status_ts`, and `@claude_state` through `set-claude-state.sh --via 7501`
  (working→working · blocked→needs perm|ask + `@claude_needs_detail` · done/idle→done ·
  error→exited · clear and a sub-task's `id=` entry keep it; no bell, no Stop
  logic). The inventory's column 29 `agentstatus=` carries it to the hub as the
  worker's `status_kind` / `status_msg`. `FLEET_STATUS_7501=0` (or no tty, no tmux)
  runs the agent bare, byte for byte as before. `fleet-status-7501-selftest.sh`.
  **And on the person's own terminal** (issue #2539, C4): tmux drops an OSC it does
  not know, so the relay splices each report back in as tmux passthrough right after
  the agent's own, once per depth 1..`FLEET_STATUS_REPLAY_DEPTH` (3: shell → stage →
  node; exactly one copy arrives bare — nothing on the node can see how deep its
  client is), and the node's `session-window-changed` / `client-session-changed`
  [75] hooks run `fleet-status-7501.py replay` — each terminal client's current
  window's state, or `state=clear`, onto its tty (never a control-mode client),
  only once a relay set `@agent_replay`. All three confs say `allow-passthrough on`
  (only a pane on screen passes). Ghostty shows it on the tab; iTerm2 has no OSC
  7501 and ignores it. `0` keeps it on the machine. `fleet-status-replay-selftest.sh`.
  **It is the PRIMARY source** (issue #2537, C2): every `@claude_state` write labels
  `@claude_state_src` (7501 · hook · classifier · carried · wrapper), and while
  `@agent_status_ts` is fresh (`fleet_primary_fresh`, `FLEET_STATE_PRIMARY_SECS` 120;
  the relay re-stamps a repeated report every 30 s) a hook leaves the state alone —
  except a worker's `blocked` and the prompt that clears it — and the classifier, the
  spinner's demotes and the native reconcile stay out. A carried state (migrate /
  move / restore) goes through `fleet_state_carry`, only before the agent's first
  report; the wrapper clears `@agent_status` before each launch. The reconcile writes
  each window's source to `reconcile.sources` and `primary=a/b` to its heartbeat
  (doctor `state` row: 主来源覆盖率). `state-primary-selftest.sh`; BREAK-IT `status-*`.
  **The reapers judge by it too** (issue #2540, C5): `fleet_reap_state` (one reader,
  `fleet-reap-live.py --state`) — the agent's last 7501 word (done/idle → done,
  error → exited, working/blocked kept), else `@claude_state`; no word and no stamp,
  or a working/blocked word, with no agent process under the pane → exited.
  `fleet-reap-live.py`, dash-reap's no-repo row, `fleet-cleanup.sh` and
  `fleet-epic-backstop.sh` read it; a 7501 done/error waives the young-agent gate
  (`idle` does not — a fresh agent says it before its seed lands).
  **What it asks travels with it** (issue #2538, C3): `kind=auth` is its own
  `@claude_needs` subtype; a needs row carries its kind + words (≤200, the current
  question only) as the sidebar's fields 17-18 (the row shows the start, the bar
  all of it), the hub cache's fields 27-28, `fleet ls`'s 在问 column / `fleet show`
  / `fleet answer`'s 题干, and the hub page's row + drawer — the agent's own
  status_kind / status_msg first, else the hooks' subtype + `@claude_needs_detail`
  (`inventory_row` fills the pair). Nothing asked ⇒ byte for byte as before.
  `ask-words-selftest.sh`.
- **The hub ships the `fleet` client, and `bin/` + `conf/` stay canonical**
  (issues #1470, #1486). `curl -fsSL <hub>/install | sh` serves
  `bin/fleet-install.sh` (hub URL filled in), which fetches `/install/manifest`
  and then `/install/<path>` for every file on it — `bin/fleet`, what it
  dispatches to, and the SHELL (#1484: `fleet-shell.sh`, the sidebar, the bar,
  the hub loop, `fleet-lib.sh` whole, `conf/tmux-shell.conf`) — into
  `~/.local/share/claude-fleet/<path>` (the repo's own layout, so `$BIN/../conf`
  resolves), with a two-line `~/.local/bin/fleet` that runs the real one (a
  script, not a symlink: `fleet` finds its siblings in its own `$0` directory,
  which every dir-of-symlinks shadow relies on). **The repo keeps ONE copy of
  each client file** (issue #1803): `//go:embed` cannot reach `..`, so a hub
  build first runs `bin/fleet-client-pack.sh`, which copies the manifest's files
  into the gitignored `tokenledger/internal/api/fleetclient/pack/` (only
  `pack/doc.go` is committed) — `bin/fleet-client-pack.sh && docker build -t
  ccquota tokenledger/`; the Dockerfile refuses an empty pack, and a plain `go
  build` without one serves no client (`fleetclient.Packed`, 503 on `/install`).
  **The list is `fleetclient/manifest`, maintained there only**: `embed.go`
  parses it, the installer walks the served copy, and a node-only script
  (spawning, reaping, gh) stays off it. Never commit a copy back under
  `fleetclient/`; `bin/fleet-client-mirror.sh` now only rewrites the manifest's
  generated block (`--check`: every path in the repo, no copy committed), and
  `TestFleetClientMatchesBin` (Go) + `bin/fleet-install-selftest.sh` leg A
  (shell, a sandbox pack) pin it from both sides. **The client follows
  STABLE, not the hub image** (issue #1805): the hub's `/version` names
  `refs/tags/stable`'s commit as `client_version` (+ `client_url`, its files
  proxied at `/install/stable/<sha>/`, `CCQUOTA_FLEET_STABLE_REPO`; `off` / GitHub
  never answered = the image's pack, byte for byte), `/install` serves stable's
  own installer when it carries `fleet-install: stable-aware`, and a client with
  no hub asks GitHub (`FLEET_STABLE_API` / `FLEET_STABLE_RAW`). So moving stable
  is the whole release for both layers — `fleet-client-update.sh` (基础) and
  `fleet-install-sync.sh` (承载), dispatched by `bin/fleet-update.sh`
  (`fleet update`) — and the hub image is redeployed only for the hub's own
  changes. `fleet-update-selftest.sh` pins it.
- **The node token never enters a pane's environment** (issue #1491).
  `ccquota lease|place|move` act as this machine's agent and need its token;
  `fleet_hub_lease` / `fleet_hub_place` / `fleet_hub_move` (`bin/fleet-lib.sh`)
  read it from `$FLEET_CONF_DIR/node.env` **inside the subshell that runs the
  command** (`_fleet_hub_env`) — never `export` it in a conf, a hook or a
  launcher, or every worker spawned from that pane inherits a node credential.
  No token anywhere → the default command is not run and the note says
  「no node token (… node.env missing)」, not 「hub unreachable」; a
  `FLEET_HUB_*_CMD` seam is never held to the token. A login whose agent predates
  `node.env` writes it once with `bin/fleet-hub-node.sh env --write` (from its
  launchd plist); `fleet-sync-logins.sh` does that for the other logins, and
  `fleet-doctor`'s `node` line WARNs on a login without one. **A worker_id's
  fleet UUID is the FLEET's**: `fleet_uuid` loads the conf with `TMUX` unset so
  the window's repo overlay (#788) never enters the hash — the hub only knows
  the UUID the inventory minted from the fleet conf's own repo + checkout.
- **A managed login's default agent configuration has ONE source each, and the
  sync only FILLS it** (issues #1558, #1559). `conf/claude-settings.default.json`
  is the default Claude Code settings (`fleet-hooks-merge.py defaults`);
  `conf/agent-defaults/` is the default package for BOTH agents — the user-scope
  MCP servers `context7` / `playwright` / `github` / `fetch`, Codex's
  `approval_policy` / `sandbox_mode` / `model_reasoning_effort`, one marker block
  for `~/.claude/CLAUDE.md` / `$CODEX_HOME/AGENTS.md` (`fleet-agent-defaults.py
  apply`), the repo's `skills/` for both homes. Fill only: a key / server the
  login already has — whatever its value — is never rewritten, `model` is never
  shipped, and the login's `config.toml` is edited as TEXT (its lines stay byte
  for byte; macOS python 3.9 has no tomllib, so never re-serialize it).
  `~/.claude/settings.fleet-override.json` / `~/.config/claude-fleet/agent-overrides.json`
  name what is never written. **Credentials never enter a config**: the `github`
  server's token is read by `bin/mcp-github.sh` from `gh auth token` at start;
  `fleet-agent-defaults-selftest.sh` leg 11 greps every shipped and merged file
  for one. Both run on every `fleet-install-apply.sh` move (`settings`, `agents`
  passes) — never add a second place that writes these files; `fleet-doctor`'s
  `settings` / `agents` rows count what a login still lacks. **A client-only
  computer gets the same package** (issue #1725): `conf/agent-bundle.manifest`
  lists it (hooks · skills · commands · MCP · the mod, and what applies them);
  `fleet-client-mirror.sh` writes its expansion into the hub client manifest's
  generated block, the installer lands it beside `bin/` and runs
  `fleet-install-apply.sh --bundle` — the same passes, fill only, hooks wired
  through `bin/fleet-hook-run.sh` (no `~/.claude/fleet` there; a later node
  sync replaces them in place). A new file the package needs goes in that
  manifest, never in the generated block; `fleet doctor` on a client is
  `fleet-agent-bundle.py doctor`. `fleet-agent-bundle-selftest.sh` pins it. **The hub hands ONE team layer on
  top, and local still wins** (issue #1726): `GET/PUT /v1/fleet/team-bundle`
  (PUT is the operator's; every PUT a version, a rollback a PUT of an older
  body — `fleet-agent-team.py put|restore|history`) holds an allow-listed
  bundle (mcp · hooks · skills · claude_settings · codex_config) that the hub
  AND the computer refuse when it carries anything credential-shaped.
  `bin/fleet-agent-team.py sync` composes fleet default < team < local after the
  agents pass, on install-sync's tick and at the client shell's start: an item
  is the team's only while it still holds what the team wrote, so a hand edit
  wins and a rollback undoes exactly the team's writes; `"team": "off"` in
  agent-overrides.json leaves the layer. Every item's source lands in
  `$FLEET_CONF_DIR/agent-effective.json`; the doctor's `agents` row prints the
  version. No hub ⇒ nothing fetched, nothing written (`fleet-agent-team-selftest.sh` A).
  **A new team version is pushed, not waited for** (issue #1899): the hub sends
  `team` {team_version} to every node whose hello listed `CapTeam` — on a PUT, and
  on each connection's first beat — and the agent runs `fleet-agent-team.py sync
  --hub-version N` (retried every beat until it succeeds; `team-push.json` feeds
  the doctor's `team` row 入口 vN · 本机 vM · 拉到 …). No team layer ⇒ nothing sent.
- **A machine has ONE fleet config file, `$FLEET_CONF_DIR/fleet.conf`** (issue
  #1623). `FLEET_HOST=1` (承载: this computer runs sessions — issue #1806; the old
  `FLEET_ROLE` is rewritten by `migrate` and read one more version) and
  `FLEET_HUB_URL` (the hub's address — written nowhere else) sit in `[common]`; `[client]` (only the shell,
  `FLEET_SHELL=1`) and `[node]` (everything but the shell) are `if` guards, so
  every reader that sources the file gets its own sections with no mirror and no
  parser. Credentials never enter it: `bin/fleet-conf.sh migrate` (run by
  `fleet-install-apply.sh`'s `conf` pass and by the shell's start, `fleet-shell.sh`) moves any
  `*TOKEN/*SECRET/*PASSWORD` line to `secrets.env` (0600, sourced from
  `[common]`), and node.env / hub.json's token / `~/.ssh/fleet-cert` stay apart.
  It folds the install `fleet.conf`, `fleet.settings`, the one fleet's conf (down
  to its identity), `shell.conf` and hub.json's url, keeping each as `.bak`; every
  reader still reads the old paths for ONE version (EPIC #1615 decision 11) — the
  next batch deletes them, and the shell's conf-free mirror with them. The legacy
  flat-conf scans skip `fleet.conf` / `shell.conf` (not fleets). `fleet-doctor`'s
  `能力` row (the `role` row before #1806); `bin/fleet-conf-selftest.sh` pins all
  three kinds of computer + the degenerate. **A person reads two words, fleet and
  承载** (issue #1806): `fleet host on|off|status` is the switch, the doctor's first
  rows are `fleet` / `能力` / `承载`, and the hub's protocol keeps `node`
  (docs/TERMS.md).
- **Machine-to-machine ssh rides a five-minute hub certificate, never a
  standing key** (issue #1626). `fleet-remote-view.sh`, `fleet-node-upgrade.sh
  --host` and `fleet-move.sh` get their ssh options from `bin/fleet-peer-cert.sh
  <machine> view|upgrade|move` (the node token asks `POST /v1/node/peer-cert`; the
  hub checks the target login is the same owner's, signs `~/.ssh/fleet-peer` for
  `sshca.PeerTTL`, audits it in `fleet_peer_certs`). Exit 1 = the hub said no or is
  down: pause and say so — never fall back to authorized_keys; exit 3 = no hub
  here: plain ssh, byte for byte. Any new cross-machine ssh goes through it
  (`fleet-peer-cert-selftest.sh` I lints it); `fleet-doctor`'s `sshtrust` row
  WARNs on another fleet machine's key in `~/.ssh/authorized_keys`.
- Claude Code re-reads `settings.json` hooks per turn, so running sessions pick
  up hook changes without a restart.
