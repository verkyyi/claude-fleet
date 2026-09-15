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
    per-fleet (scoped by `FLEET_SESSION`). Switching fleets is a detach-and-reattach
    to the other socket (`detach-client -E`), not `switch-client` (single-server).
    **Ad-hoc sessions on the `default` socket are NOT fleets** — a fleet is created
    by `fleet-up` (which writes its conf + spins its socket).
- **The base checkout is edit-read-only** (hook-enforced): a worker edits inside
  its `issue-<N>` git worktree and lands via PR; the operator files/triages from
  the hub and hands implementation to a worker. Never commit to the base checkout.
- **One tmux session ↔ one GitHub repo.** The PR map is one repo-wide
  `gh pr list`; multi-repo fleets need per-window repo detection (not built).
- **Panel windows, not sessions.** Windows named `dash`, `plan`, `backlog` are
  treated as panels and excluded from the dash session list.
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
  the selftests use (`bin/dash-marker-selftest.sh`). A `tmux()` guard in
  `shell/cw.zsh` refuses the common accidental forms; `FLEET_ALLOW_TMUX_DESTROY=1`
  passes a deliberate destroy through.
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
- **CI SHARDS the gate; the tests themselves still run one at a time**
  (issue #681). `run-selftests.sh --shard K/N` takes every N-th test of the
  sorted list, and `.github/workflows/selftests.yml` fans that over a 6-job
  matrix — ~1-2 min a shard, where the whole suite was 9 minutes against a
  10-minute bound. Edit the `shard:` list to change the width and nothing else:
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
- Claude Code re-reads `settings.json` hooks per turn, so running sessions pick
  up hook changes without a restart.
