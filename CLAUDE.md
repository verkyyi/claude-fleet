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
- **A fleet hosts one or more GitHub repos** (issue #788, switched on in #795).
  The fleet conf's `FLEET_REPO` is the first; `bin/fleet-repo.sh add` registers
  more as `fleets/<sess>/repos/<slug>.conf`. **There is no main repo.** A window's
  repo is `@repo` (`@norepo 1` = deliberately none), resolved ONLY through
  `fleet_repos` / `fleet_window_repo` / `fleet_load_repo_conf` — never an
  ad-hoc `git remote` parse — and every join is
  on (repo, issue) or (repo, branch), never a bare number or branch name. A
  window whose repo is unknown is skipped, never guessed. In a 2+ repo fleet the
  hub opens in `$HOME`. **Degenerate case is sacred:** a fleet with no `repos/`
  overlay must behave byte for byte as a one-repo fleet always has, and any
  change here ships a selftest leg that asserts it. `bin/multirepo-e2e-selftest.sh`
  is the end-to-end check (`leaks: 0/9`).
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
    `macos-latest`, nightly (18:17 UTC = 02:17 CST), plus `workflow_dispatch`.
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
- Claude Code re-reads `settings.json` hooks per turn, so running sessions pick
  up hook changes without a restart.
