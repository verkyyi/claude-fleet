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
  its `issue-<N>` git worktree and lands via PR; a steward files/triages and hands
  implementation to a worker. Never commit to the base checkout.
- **One tmux session ↔ one GitHub repo.** The PR map is one repo-wide
  `gh pr list`; multi-repo fleets need per-window repo detection (not built).
- **Panel windows, not sessions.** Windows named `dash`, `plan`, `backlog` are
  treated as panels and excluded from the dash session list.
- **Navigate by name, not index.** The hub/dashboard is placed at the lowest
  index once, at spawn; numbers still shift when a window closes
  (`renumber-windows on`).
- **Never run destructive tmux on the live server**, and test tmux tooling on an
  **isolated socket** — `tmux -L scratch …`, or the `-S <sock>` PATH-shim pattern
  the selftests use (`bin/dash-marker-selftest.sh`). A `tmux()` guard in
  `shell/cw.zsh` refuses the common accidental forms; `FLEET_ALLOW_TMUX_DESTROY=1`
  passes a deliberate destroy through.
- Claude Code re-reads `settings.json` hooks per turn, so running sessions pick
  up hook changes without a restart.
