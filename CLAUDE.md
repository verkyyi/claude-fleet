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
  `fleet_member_ref` / `fleet_sub_issues`, never a sub-issue's `.number` alone. In a 2+ repo fleet the
  hub opens in `$HOME`. **Degenerate case is sacred:** a fleet with no `repos/`
  overlay must behave byte for byte as a one-repo fleet always has, and any
  change here ships a selftest leg that asserts it. `bin/multirepo-e2e-selftest.sh`
  is the end-to-end check (`leaks: 0/9`).
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
  operator / scratch / a person's shell are never touched. The mod registers no
  tool (0.4.0). Spec: `docs/FLEET-MCP.md` «The old road».
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
- **A new way to break the fleet gets its row and its drill BEFORE its fix**
  (issue #1786). `docs/BREAK-IT.md` lists every known way (方式 · 后果 · 自愈方式 ·
  演练); `bin/fleet-break-it-selftest.sh` does each one for real on isolated
  sockets and a sandbox HOME and prints `PASS <id> <secs>s ≤<cap>s`. One row ⇔
  one `drill_<id>` (the test reds on either side missing); a way fixed in another
  repo is `登记：<ticket>`, listed, never drilled. Found a new one: add the row
  + drill, watch it go red, then fix.
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
  the PR run); `selftests-macos.yml` runs it on every PR too (2 shards max — 5 macOS jobs per free account) — the pre-merge BSD /
  bash 3.2 check — and stays FULL nightly as the backstop. So **don't run the
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
    `macos-latest`, nightly (18:17 UTC = 02:17 CST), plus `workflow_dispatch`;
    on every PR it runs `--changed` (the related tests only, issue #1374).
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
  (1777 dir, 0666 files, never under a `$HOME`), held by a python3 parent that
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
- **The measurement bus has ONE writer, `conf/statusline.sh`, and two feeders**
  (issues #1452, #1459). Every `@ctx_pct/@ctx_limit/@ctx_band/@model/@effort/@rl*`
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
  Never add a second place that computes a band or rounds a percent. Claude Code
  keeps one blank bottom row for ANY `statusLine`, so the key is removable once
  every Claude window on the login runs mod ≥ 0.2.0: `bin/fleet-statusline.sh
  off` is the only thing that removes it, it refuses while a window would go
  blind, and `/fleet-sync-install` never touches the key.
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
