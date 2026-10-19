# claude-fleet — architecture

New to the vocabulary? Read [TERMS.md](TERMS.md) first.

## Today: one fleet, machine-global

claude-fleet as shipped is **single-fleet**: one tmux session, one repo, config
in a single global `fleet.conf`, one collector on launchd, one flat cache dir
`$TMPDIR/.claude-dash/`. Every script reads the global `FLEET_REPO` / `FLEET_MAIN`.

That's the whole single-repo assumption — it lives in exactly one place (the
global `fleet.conf`), consumed by ~7 scripts.

## Target: one fleet per login, every repo in it

**Use case:** one login runs exactly one fleet, and that fleet hosts every repo the
login works on, each with its own local checkout (existing or freshly cloned) — you
pick a repo, you never switch fleets (EPIC #977; the switching UI went in #980).
Several fleets on one machine means several logins, each with its own, and they
must coexist without clobbering each other: each fleet keeps its own tmux socket,
conf and caches.

### The model: a fleet ≡ a tmux session, hosting one or more repos

A fleet starts with one repo (its conf's `FLEET_REPO`) and can host more — see
[A fleet can host several repos](#a-fleet-can-host-several-repos-issue-788).
Each fleet has an identity **`FLEET_ID` = its tmux session name** (e.g.
`webapp`, `infra`, `docs-site`). Every fleet script derives `FLEET_ID` from
`#{session_name}` and scopes itself to that fleet.

### Window identity — the tmux options a fleet stamps, and `@wid` (issue #566)

Everything a fleet knows about a window lives in tmux **window options**, read
back through `#{@…}` formats. They are the substrate the dash, the reapers, the
bridge and the migrator all agree on:

| option | meaning |
|---|---|
| `@wid` | **the window's handle** — `a1`…`z9`, unique among this fleet's live windows |
| `@issue` | the GitHub issue this worker is bound to (absent ⇒ not a worker) |
| `@raw` | `1` ⇒ a scratch session: no issue, its own `scratch-<N>` worktree |
| `@worktree` | the git worktree the window owns (survives the pane `cd`-ing away) |
| `@repo` | the hosted repo (`owner/name`) the window belongs to — stamped at spawn, derived once from `@worktree` for an older window (#789) |
| `@norepo` | `1` ⇒ a session that deliberately belongs to no repo: runs in `$HOME`, no worktree, never reaped automatically (#789) |
| `@origin` | spawn provenance — `issue-<N>` / `scratch-<N>` / `autofill` / … — and, since #574, an **address**: `fleet_win_for_key` resolves it back to the parent's live window. The parent's key also names its children ledger (`$FLEET_STATE/children/<key>.ndjson`, #937), which `bin/fleet-children.sh` reads — the one command a parent uses to check its children (#940) |
| `@reported` | `1` ⇒ this window already pushed its outcome to its `@origin` parent (the reap-time backstop skips it) |
| `@expand` | `1` ⇒ this window's `@origin` children are UNFOLDED on the dash. Absent ⇒ folded, which is the default: the dash shows one line per parent and `←`/`→` open and shut the block. Inverted against `@pin` on purpose — a window nobody has touched must start collapsed |
| `@repo_fold` | the one **session** option in this table (issue #1037): the space-separated slugs of the repo groups FOLDED on the dash (`o-tokenledger none`), set by `←` on a repo heading and unset once `→` opens the last one. Absent ⇒ every group open, the list as it always was. A session option so it is per-fleet for free, dies with the fleet, and — because tmux resolves `#{@repo_fold}` through a window's session — rides the renderer's one `list-windows` call with no extra fork |
| `@claude_state`, `@claude_state_ts` | the state glyph + when it last changed |
| `@cc_account`, `@cc_agent` | which subscription account / which agent it runs |

**`@wid` is an internal handle and optional CLI target.** A window's tmux `window_id`
(`@382`) is re-minted every time the window is re-created, and that happens
constantly — `fleet-migrate.sh` re-created 21 windows in one night, and every
`dash-restore-session.sh` mints another — so it can never be the name for "reap
that one". `@wid` is a **letter + digit** (234 of them, lowercase, digits 1-up so
nothing reads as `0`/`O` or `1`/`l` on a soft keyboard), accepted
**wherever a window target is** —
`fleet-migrate.sh b3`, `dash-reap.sh a1` — via `fleet_wid_target`, which passes
any non-handle (`@382`, an index, a name) straight through. The destructive
`dash-reap.sh` entry instead requires an explicit identity and refuses indexes
and names; see [reap safety](REAP-SAFETY.md).
The sidebar and full hub list identify tasks by their user-supplied descriptions
and hide these handles. The full list gives the reclaimed four columns to names.

- **Scope: this fleet's live windows.** A handle is **reused** once its window is
  gone, which is what keeps it two characters forever. Durable identity for
  history/the ledger stays the session/transcript id; `@wid` never appears there.
  The landed (`⌃t`) view shares the live list's layout without an `id` column.
- **Allocation is stateless** — no counter file. `fleet_wid_stamp` reads `@wid`
  off every window on the fleet's socket and takes the lowest unused one, under a
  short mkdir-lock in `fleets/<session>/wid.lock`. Nothing to corrupt, self-healing
  after a crash, correct across `fleet-up`/`fleet-down`. On lock timeout it fails
  **open** (no handle) and the dash's render-time **backfill** assigns one on the
  next repaint — which is also how every window that predates #566 gets one.
- **It survives re-creation.** `fleet-migrate.sh` re-stamps the same handle onto
  the replacement window (taking the next free one if something claimed it in the
  gap); a `/fleet-handoff` cycle reuses the same pane, so there is nothing to do
  there. A *restored* landed session is a genuinely new window and gets a fresh
  handle — the old one was released when the original closed.

### Four ways to move a session (issue #1067)

"Move this session" means four different things depending on what changes —
the agent, the subscription account, the machine, or nothing at all:

| Script | What moves | Stays fixed | Mechanism |
|---|---|---|---|
| `fleet-migrate.sh` | subscription **account** | machine, agent, window's cwd | close (`/exit`, wait) + a NEW window running `claude --resume <sid>` under the target account's token — an account bakes into the process at launch, so it can only ever be a close+resume, never an in-place swap |
| `fleet-transfer.sh` | **agent** (Claude ↔ Codex) | machine, pane, worktree | one pane, one worktree: package the source's provenance, `/exit` it, launch the other agent in the SAME pane |
| `/fleet-handoff` (cycle mode) | nothing runs anywhere else — the context window empties | machine, agent, process (same pid) | `/clear`, not `/exit`: the process never stops, only the conversation does; a doc (issue comment or local file) carries the pickup prompt |
| `fleet-move.sh` | **login/machine** | agent, account choice on the target (it re-resolves its own) | close the source, tar-pipe the transcript to the target's `~/.claude/projects/`, then a NEW window there running `claude --resume <sid>` — the only one of the four that crosses a machine, so it is the only one that needs ssh, and the only one where "resume" runs on a fleet this script does not itself control (see `bin/fleet-move-remote.sh`, the half that runs there) |

`fleet-move.sh` is the newest and structurally the odd one out: the other
three complete inside ONE fleet's own tmux socket, so a failure at any step
just leaves that fleet's own state to inspect. A cross-machine move cannot
assume that — see [the rotation gap](CLEANUP.md#the-rotation-gap--a-window-that-is-deliberately-missing-issue-550)
for the single-machine version of "a worktree with no window is briefly
indistinguishable from abandoned", which `fleet-move.sh` guards with the same
lease while its own gap is open, and see its own header for the fork hazard
that is unique to crossing a machine boundary: two live agents can end up
resuming the same session id, one on each side, unless the source is verified
stopped before the target is verified alive (and closed only after).

### What is shared vs. per-fleet

The key insight: the collector's work is **~80% machine-global** and only the
GitHub fetch is per-repo. So the collector is **shared**, while the stateful,
repo-specific pieces are **per-fleet**.

| Component | Scope | Why |
|---|---|---|
| **Collector** | **shared (one, machine-global)** | usage + rate-limit are account-wide; git + ctx already iterate every window machine-wide; only the PR/issue fetch is per-repo, and that's a cheap fan-out |
| `usage`, `ratelimit` cache | shared | account-wide — computing per-fleet would just duplicate the same number |
| `git_<key>`, `ctx_<key>` cache | shared (`global/`) | per-worktree / per-Claude-session, already machine-wide |
| `prmap` / `issues` cache | **per-repo** | the only per-repo data → written under `fleets/<slug>/` (issue #181) |
| **Config (`fleet.conf`)** | **per-fleet** | each fleet = a different repo + checkout → `fleets/<session>/conf` |
| **Dash / status / backlog** | **per-fleet view** | reads shared globals **+** its own repo's `fleets/<slug>/` files |
| **Hub** | **per-fleet** | triage / ledger are stateful per repo; "one writer per ledger" |

*Collector shared, hub not* is the right split — remember it that way.

The git phase also reclaims path-keyed `git_<key>` / `ctx_<key>` files whose
worktrees have left the live inventory (#647). It requires successful, nonempty
window listings from every discovered fleet and at least one absolute path;
failed, empty or malformed inventories preserve existing caches. Cleanup uses
the entire inventory before git work starts, so a budget that stops the rotation
early cannot evict an unvisited live worktree. Native `ctx_codex_*` session keys,
per-fleet caches, directories and symlinks are outside this sweep.

### Session panel

`fleet-thin.py` runs one foreground connection to the home machine. The home's
`fleet_view.py` draws the session panel and `fleet-topbar.py --node` draws the
current session. `conf/tmux-view.conf` adds keys only to grouped view sessions;
a direct node attach keeps its normal tmux keys. Every switch goes through
`fleet-view-go.sh`, with worker identity resolved by the shared fleet resolvers.
Across machines the home owns one peerlink connection per (machine, login).

The two-pane client, local stage server and sidebar were retired in #3008.
The panel's actions retain the shared node helpers. See [CLIENT.md](CLIENT.md)
for the keys and the completed sidebar migration checklist.

### Why the collector is shared (not one-per-session)

A per-session collector would run the account-global work (usage, rate-limit,
ctx over all windows) N times — pure duplication, and N launchd agents to
manage. One shared collector does the global work once, then fans the GitHub
fetch out over the repo set. Fewer processes, less redundant work, no
launchd-per-fleet plumbing.

### Every collector phase is budgeted, and so is the whole tick (issue #653)

The collector's tick is a serial chain of phases — quota watch, sockets, sessmap,
issues, git, ctx, usage, scrape, banner, escalate, snapshot. launchd never overlaps
a `StartInterval` job, so **tick duration IS the collector's real cadence**: a tick
that runs 454s against a 60s interval means every cache on the dash is minutes old,
which is not an empty dash but a frozen one.

Budgeting the phases one at a time turned out to be a losing game. #552 boxed the
`git` phase (571s → 56s) and the very next tick measured
`dur=454 … git=126 usage=226` — the bottleneck had simply moved to `usage`, which
had no budget, and `runs` advanced once in 514s. So the rule is now general:

- **Per-phase budget.** Every phase runs under `fleet_timebox` with its own knob.
  A phase that blows it is killed; the tick runs on and stderr names the phase and
  the knob to change.
- **Whole-tick budget** (`FLEET_COLLECT_TICK_BUDGET`, 2× the interval). Each
  phase's budget is *clamped* to the time left in the tick, so ten phases each
  inside their own budget cannot still sum past the interval.
- **Rotation, not starvation.** The phase a tick truncated at is parked in
  `global/collect.phase.cursor`; the next tick starts there and wraps round, so a
  deferred phase waits one round. A tick that completes clears the cursor, so a
  healthy machine always runs the historical order.

Two things make this work. The phases are **independent within a tick** — the one
real handoff, sessmap → issues, travels through `global/collect.repoqueue` on disk,
both because a budgeted phase runs in a subshell and because rotation can reach
`issues` in a tick that skipped `sessmap`. And `fleet_timebox` measures **wall
clock**: it used to count `sleep 1` iterations, which under this daemon's
`ProcessType=Background` tier (lowest CPU + I/O) inflated a 30s budget to 126s at
load 40+ — the budget loosening by exactly the factor that made the work slow. Ten
phases holding an elastic budget would have been ten copies of one bug.

Normal completion now wakes the waiting shell through a private FIFO (#701),
removing the one-second return floor. The FIFO is opened and immediately unlinked;
its setup costs a fixed mkfifo/rm pair per call. Waiting uses builtin
`read -t 1` and `SECONDS`, so it adds no fork per poll and also works on bash 3.2.
The existing process-group kill and status-preserving `wait` still enforce the
deadline. A job that replaces its EXIT trap or execs is noticed by the one-second
liveness check. Failed FIFO setup or an fd 9 already in use by the caller falls
back to the old bounded sleep loop, preserving the caller's file descriptors.

The heartbeat already timed every phase, so *which* phase ate the tick was free
information nobody printed; `over=` and `skipped=` now carry it and `fleet-doctor`
reports it, so the next time the bottleneck moves it does not cost an investigation.

### The quota watch budgets itself the same way (issue #698)

`bin/fleet-quotawatch.sh` had budgets for its *pieces* — a cap probe
(`FLEET_QUOTAWATCH_PROBE_BUDGET`), the sweep phase
(`FLEET_QUOTAWATCH_SWEEP_BUDGET`) — and none for itself.
`FLEET_QUOTAWATCH_DEADLINE` (120s) reads like a budget and is not one: it lives in
the overlap guard, where it tells a **successor** that the lock holder is stuck and
may be superseded. That successor is exactly what a slow tick prevents — launchd
does not overlap a `StartInterval` job, and #671 gates the collector's in-tick
fallback off while the unit is running — so the one thing that could have enforced
the 120s was structurally absent whenever it was needed. Measured live on
2026-09-15, on a host that already had #688: a **5m45s** tick against that 120s,
not wedged, simply unbounded.

So the tick now bounds itself, on the collector's model:

- **`FLEET_QUOTAWATCH_TICK_BUDGET`** (100s) is checked before every phase *and*
  before every iteration of the two loops (the per-fleet sweep, the per-account
  policy), and each phase's budget is clamped to what the tick has left.
- **The calls inside a loop iteration are budgeted too** — the ccquota fetch
  (`FLEET_QUOTAWATCH_FETCH_BUDGET`), the collector self-heal errand
  (`…_KICK_BUDGET`), and each fleet's share of a policy episode
  (`…_TMUX_BUDGET`). Without this the per-iteration check is theatre: one
  `tmux display-message` that never returns (57s observed, #582) defeats any
  number of checks *between* iterations. The granularity is per **socket**, not
  per call, to avoid repeating timebox setup and job creation for every window.
- **Wind down, never self-kill.** At the budget the tick stops *starting* work,
  writes its heartbeat, releases the lock and exits 0. A `kill $$` would be the
  #582 regression: the process holds the lock and only its `EXIT` trap frees it.
  Deferring is safe because the sweep has its fairness cursor and a policy episode's
  once-per-window marker is written only for an account that was actually handled —
  so a deferred account has no marker and the next tick does the whole episode.

Two invariants are **enforced in code** rather than left to four defaults agreeing,
which is #686's lesson: the budget plus a wind-down margin must stay under the
deadline (otherwise a tick is tree-killed mid-wind-down), and the sweep must leave
the ccquota fetch its budget (that is what #582 gave the sweep a budget *for* — the
fetch is ~1s and its stamp is the liveness signal every staleness alarm reads).
Either one violated clamps the offending knob **down**, loudly.

`bin/fleet-timebox-kill-selftest.sh` §5 is the soak that goes with this: twenty
rounds, most of them over budget, asserting zero residue at the end *and* that the
live count never ratchets — the accumulation a single-shot check cannot see. It
also fixed a marker that never worked: `bash -c "sleep 120 # $MARK"` is one
command, so bash **execs** it and the comment leaves with the old argv, which made
every `pgrep -f "$MARK"` answer 0 whether or not anything leaked. The marker now
goes in `argv[0]` via `exec -a`, and the test self-checks that a marked process is
visible before trusting any count.

### Repo-set source — how the shared collector knows which repos to fetch

The collector needs the list of repos to fetch PRs/issues for. It's **emergent,
not a hand-maintained list**:

> repo set = enumerate the live tmux **sessions** → each session's `fleet.conf`
> names its `FLEET_REPO` → union them.

Open a fleet (session) → its repo enters the fetch loop automatically. Close it
→ it drops out. Every configured fleet conf — and each repo it hosts through its
`repos/` overlays — is pinned too, which covers a repo fetched with **no** session
open (e.g. a repo you're watching but not actively working). The old `FLEET_REPOS`
pin list is superseded by those overlays and undocumented (#1101).

### Config + durable-state layout — one directory per fleet (issue #181)

Every fleet's **durable** state is a single directory keyed by its tmux session
name, so a fleet is a self-contained, equal unit (`ls .../fleets/` = the fleets):

```
~/.config/claude-fleet/
  fleets/<session>/
    conf              # per-fleet overlay — same keys as fleet.conf.example
    repos/<slug>.conf # a further repo this fleet hosts (issue #788) — see below
    restore.map       # crash-recovery snapshot (fleet-restore.sh)
    bridge/{seen,since}   # issue-bridge dedup set + watermark (per repo)
    sweep.due         # /sweep scheduling ledger
  accounts/           # GLOBAL — multi-account tokens (unchanged)
  diskguard/          # GLOBAL — disk-guard + runaway forensics; orphan-seen /
                      #   orphan-current are the #697 watchdog's cross-tick state
  transcript-archive/ # GLOBAL — idle, unreferenced ~/.claude/projects transcripts
                      #   (<project>/<id>.tar.gz + archive.log), daily (#1299);
                      #   `fleet-transcript-archive.sh --restore <id>` puts one back
  restore/            # GLOBAL — auto-restore ARM flag + restore.log
```

The single source of this layout is `bin/fleet-lib.sh` (`fleet_state_dir`,
`fleet_conf_file`, `fleet_each_conf`, `fleet_sess_for_repo`) — no call site
hand-builds a session-suffixed path. Any fleet script resolves its session from
`#{session_name}` and sources its conf via `fleet_conf_file`; the shared daemons
enumerate every fleet with `fleet_each_conf`. A one-time migrator
(`bin/fleet-migrate-layout.sh`, run by `/fleet-sync-install`) moves an old flat
estate (`<session>.conf`, `restore/<session>.map`, `issue-bridge/bridge_<slug>.*`,
…) into this layout **idempotently**, and every reader **dual-reads** both layouts
so a fleet keeps working across the land→migrate window.

**Config layers, as the `prefix+c` modal sees them (issue #1102).** Read order is
install `fleet.conf` < `~/.config/claude-fleet/fleet.settings` (the login's one
settings file, #979) < the fleet `conf` < a hosted repo's `repos/<slug>.conf`.
One login runs one fleet (#977), so `fleet.settings` and the fleet `conf` are one
layer to the user — **this fleet** — and the modal's ⌃s picks only *this fleet ⇄ a
repo*. A key's `@scope=global` tag still picks the FILE (such keys go to
`fleet.settings`, because `fleet_load_conf` strips them from a fleet `conf`), but
it is never a scope to switch to nor a reason to refuse an edit. The install's
`fleet.conf` is a read-only legacy layer: read, so an old install loads unchanged,
never written. A repo edit writes that repo's overlay (`repos/<slug>.conf`) however
many repos the fleet hosts (issue #1943).

### A fleet can host several repos (issue #788)

The fleet conf's own `FLEET_REPO`/`FLEET_MAIN`/`FLEET_BASE_BRANCH` are **one
registry entry** — no migration. Each further repo is an overlay at
`fleets/<session>/repos/<slug>.conf` with the same three keys plus any per-repo
override (`FLEET_MODEL`, `FLEET_AGENT`, `FLEET_MCP_CONFIG`, `FLEET_DEPLOY_*`); the
fleet conf keeps the fleet-wide defaults. All hosted repos are equal — there is no
main repo. `bin/fleet-repo.sh add|remove|list` manages them (`remove` takes an
overlay; the conf's own repo only when it is the login's seed, issue #1172 — then
another hosted repo is promoted into the conf's slot); from inside the fleet,
the dash's ⌃z (`repo-add` in `dash-keymap.sh`) and the task sidebar's row menu `g`
open the same popup, `bin/dash-repo-add.sh` (issue #1103): it asks only
`owner/name`, runs `fleet-repo.sh add --session <sess>` with the checkout defaulted
to `~/projects/<name>`, reads the result token off its stdout and holds the verdict
until dismissed. The two entries are a UI over the one registration — nothing is
gated on the fleet already hosting two, since the popup is how the second gets in.

`add` is `fleet_repo_register` in `bin/fleet-lib.sh` (issue #1104) — the one
implementation of "add a repo", and the checkout step (`fleet_repo_checkout`) and
trust warning (`fleet_repo_trust_warn`) are shared with `fleet-up.sh`'s first repo,
so a repo added later gets the same follow-through: clone-or-reuse, the base branch
resolved as in #603, the overlay written atomically, then the trust warning, a
daemon wake (#1077) and a collector kick — the collector walks `fleet_repos`, so
that tick already fetches the new repo instead of waiting out an idle cycle. Its
stdout is ONE result token, the shape `dash-reap.sh` uses, which the add-repo
popup (#1103) reads: `added:<slug>` (exit 0), `refused:hosted`,
`refused:origin-mismatch`, `refused:not-a-checkout`, `refused:invalid-repo`,
`failed:clone`, `failed:write` (exit 1; nothing written). `fleet-doctor.sh` prints
a `repos` row per fleet — every hosted repo with ✓, or ✗ naming the failing item
(`main`: checkout missing or origin mismatch · `base`: unset or absent ·
`trust`) — a one-repo fleet included, after that fleet's per-repo blocks.

`fleet-repo.sh fold <from> --into <sess> [--dry-run] [--wait]` (#796) retires a
one-repo fleet into another. It is the hand fold of tokenledger done as one
plan/execute pair: `add` the repo, carrying every per-repo key `<from>` sets
differently (a differing fleet-level key is WARNED, not carried); move each
`issue-N`/`scratch-N` window by `fleet-worker-stop.sh` then
`dash-restore-session.sh --repo` (waking a hibernating one first; busy ones stay,
or wait under `--wait`); and only when nothing is left, `fleet-down` (no `--purge`)
and move `fleets/<from>/` to `archive/<from>-folded-into-<sess minus fleet->-<date>`. Panels and
pool windows retire with the server. `bin/fleet-fold-selftest.sh` pins it.

A window names its repo with `@repo=<owner/name>`; `@norepo 1` marks a session
that deliberately belongs to none. Resolution goes through `bin/fleet-lib.sh`
only — `fleet_repos`, `fleet_window_repo`, `fleet_load_repo_conf` — never an
ad-hoc `git remote` parse.
A no-repo session has no key, so it is stopped by its identity:
`fleet-worker-stop.sh <sess> fid:<@fleet_id>` (#1873) — the fid is the 4th column of
`dash-raw-session.sh --print` — and dash ⌃x on a done/exited no-repo row runs the
same graceful stop (a busy one is `skip:live`).
`fleet_window_repo` reads `@repo`, else derives it once from `@worktree`'s git
origin and stamps it, else takes the fleet's only repo, else answers **nothing**
— and the consumer skips the window rather than guess.

`fleet_load_conf` is window-aware: inside a pane of the fleet it loads, whose
window resolves to a hosted repo, that repo's overlay is applied on top (any
other repo's identity + deploy keys are dropped first, so they never leak across).
That one change moves every in-pane consumer — hooks, `commands/*.md`, the
launcher's trust/model/MCP, the claim brief. A fleet conf that still names a repo
(the old layout) is not read (issue #4806); `fleet-conf.sh migrate` moves it into
`repos/`. A fleet with no `repos/` dir returns before any tmux call. The collector and pr-refresh fetch
`issues`/`prmap` for every hosted repo, and `hooks/base-readonly-guard.py`
protects every hosted repo's `FLEET_MAIN`.

PR status joins on **(repo, branch)**, never the branch alone (issue #792) — two
hosted repos can each have an `issue-3`. In every fleet (issues #1940, #1941),
pr-refresh matches each window against
its own repo's `fleets/<slug>/prmap` (stamping `@repo` through `fleet_window_repo`
for a window that has none), and the dash's row producer reads `@repo`/`@norepo`
off its one `list-windows` and keys the frame's narrowed haystack
`<slug>\t<branch>` — still one awk per frame, so #662's bound holds. `deploy_<sha>`
is read from the window repo's dir. A window with no repo, or an unknown one in a
2+ repo fleet, gets no PR cell. A second repo arriving changes no row of the first
(`bin/dash-rows-multirepo-pr-selftest.sh`).

**Cleanup stays inside its own repo (issue #791).** A reaper acts on a window,
so it takes its repo FROM that window (`fleet_load_window_conf`), never from the
fleet conf, and joins windows on **(repo, issue)** (`fleet_issue_windows`), never
a bare number: repo A's merged #12 cannot reach repo B's #12 window or worktree.
The cleanup daemon runs one pass per hosted repo (that repo's MAIN, its own
`fleets/<slug>/prmap`, its own lease, one shared per-tick cap) and hands the
janitor `fleet-cleanup.sh <pr> --repo <r>`; idle close runs one pass per repo;
SessionEnd, dash ⌃x and `fleet-worker-stop.sh` use the target window's repo; the
worktree janitor sweeps every hosted MAIN; transfer/migrate accept a worktree
registered to ANY hosted repo (`fleet_worktree_repo`). A window whose repo is
unknown, or `@norepo 1`, is **never reaped automatically** — its worktree is left
alone. ⌃x still closes a `@norepo` session (there is no worktree to drop); ⌃x on
an issue window whose repo cannot be told is refused until its `@repo` is set,
and a SessionEnd there closes the window without touching any worktree.
One road (issue #1943): a one-repo fleet joins on (repo, issue) too —
`bin/fleet-cleanup-multirepo-selftest.sh` pins both.

**Every session is born knowing its repo (issue #789).** Each spawner takes
`--repo owner/name` and loads that repo's overlay (`fleet_load_repo_conf`), so the
worktree comes off that repo's checkout: `dash-issue-session.sh` takes `--repo`,
else the fleet's only repo, and refuses (asks) when there are several
(`fleet_target_repo` asked with no pane, issue #1943);
`dash-raw-session.sh` takes the highlighted row's or heading's repo, else makes
a **no-repo** session; `dash-restore-session.sh` takes the row's repo.
Every worker window is stamped `@repo` + `@worktree`, and stamps them on ITSELF as
the first thing its command runs (`fleet_win_stamp_cmd`),
because the launcher's window-aware `fleet_load_conf` would otherwise race a
set-option from the spawner and pick up the wrong repo's trust, model and MCP.
Spawn dedup is keyed on (repo, N); a window whose repo is unknown still blocks.

A **no-repo** session (`dash-raw-session.sh --no-repo`) runs in `$HOME` with no
worktree and is stamped `@norepo 1` — never `@raw`/`@worktree`, so no reaper can
resolve a worktree to remove, and no ledger row is written. A Claude one launches
with `--session-id <uuid>` (`@norepo_sid`), so restore resumes exactly that
conversation rather than whatever else ran last in `$HOME`.

`restore.map` WIN rows gain column 16, the repo (`-` = no-repo), in every fleet
(issue #1943); an old row without it gets `@worktree` stamped, and
`fleet_window_repo` derives the repo from that. Provenance keys are
repo-qualified in every fleet (issue #1939): `<slug>:issue-N` / `<slug>:scratch-N`
(slug = `fleet_slug owner/name`). `fleet_origin_key` mints them, `fleet_origin_canon`
keeps them and `fleet_win_for_key` resolves them only to a window of that repo; a
bare `issue-N` is read in a one-repo fleet for one version.
`bin/fleet-repo-session-selftest.sh` pins all of it.

**Identity is (repo, issue), never a bare number (issue #790).** Two hosted repos
can both have an issue #12, so every join that finds a session by its issue
number keys on the pair, however many repos the fleet hosts (issue #1939):
`fleet_issue_key` / `fleet_window_key` spell it `<owner/name>#<N>`, and
`fleet_bound_windows` lists a fleet's bound windows by that key. A window whose
repo is unknown gets `#<N>` — equal to no real key, so no join picks it by
guesswork. The joins: the backlog's bound map,
the issue bridge's target window, ledger-watch (snapshot keyed by the pair, the
row written to its own repo's ledger), the destructive reap target (a bare `#12`
that matches two windows is refused; `<repo>#12` names one), the dash's grouping
keys (`<slug>:issue-<N>`, the spelling a multi-repo spawn stamps into `@origin`),
the landed view (a ledger is one repo's, so it drops its own `<slug>:` from the
origin column, and keeps one fold file per repo), and the Fleet Hub adapter
(message/resume use the window's or the ledger's repo, refusing an ambiguous bare
key). A one-repo fleet keeps the bare keys everywhere —
`bin/multirepo-identity-selftest.sh` pins both halves.

**One view: `all` (issues #793, #980, #1034).** Every hosted repo shows at once,
grouped under a heading per repo; a heading (or the highlighted row) picks where a
new session goes. #793 added a footer repo picker (`fleet-pick.sh`, behind a tap on
the fleet name and the dash's ⌃z) that narrowed the view to one repo; #1034 removed
it, since everything since #977/#997 assumes `all` (⌃z is the add-a-repo popup
since #1103). #1038 then pruned every "a single repo is picked" branch its readers
(new session, restore, history, issue-file, backlog, raw-session, the dash rows
and fold toggle) still carried, and `fleet_current_repo` with them — there is no
current repo, only `all`; a stale `current-repo` file on disk is read by nothing,
and `fleet-up.sh` deletes it. The footer's
middle chip is not a tap target, and since #1099 it names the login (`@login`,
stamped by `fleet-up.sh` / `tmux-conf-reload.sh`; tmux 3.3's `#{user}` as the
fallback), not the fleet — one fleet per login makes `#S` redundant.

**No fleet switching (issue #980).** One fleet per login holds every repo (EPIC
#977), so nothing detaches and reattaches to another
socket, and the orange other-fleet `● N` and its one-tap jump are gone (the spinner
still publishes `@attn_other_windows` from its per-socket loop; nothing renders
it). `fleet-attach.sh` lands a leftover second fleet on the most recently active
one instead of offering a picker, and `dash-raw-session.sh` refuses to spawn into
another fleet from a fleet pane (a headless caller still names its fleet). Several
fleets on one machine means several logins, each with its own — the per-fleet
sockets (#159) remain the blast-radius rail between them.

The dash renderers (`tmux-dashboard-rows.sh`, and with it the sidebar, plus
`dash-fold-toggle.sh`) read one `fleet_dash_repo_frame` per frame:
- `all` groups the rows by repo (issue #974): one inert heading row per hosted
  repo — idle ones too, as `tokenledger (0)` (issue #998) — `tokenledger (1)`,
  the repo's bare name (`fleet_repo_name`; owner/name
  only for two hosted repos sharing one), which is the only repo mark a row gets
  under `all` (issue #995: the sidebar is 30 columns) — in `fleet_repos` order, then a `?` group for
  a repo the fleet does not host, and the no-repo group at the foot (those two only
  while a window is in them). Both surfaces draw it bare, no `── ` rule (issue
  #998, operator call: its purple / dim-bold paint already sets it apart), and the
  sidebar's carries its owner/name in the row's state field, the one field the
  new-session path may read. A heading's
  key fields read `hdr`, so every dash bind target no-ops on it and the sidebar's
  cursor steps over it; its count includes children a collapsed parent hides;
- **a heading folds its group** (issue #1037) — the per-repo focus now that the
  picker is gone (#1034): `←` on a heading hides every row under it and leaves
  `▸ tokenledger (2)`, its count still the rows it hides; `→` brings them back.
  The same helper as the parent fold, `dash-fold-toggle.sh` — the hub hands it
  `hdr` + the heading's 4th-field spawn target, the sidebar its `hdr:<target>`
  cursor key (`folds()`) — and the same two rails: a `needs` row shows through,
  and the sidebar keeps its current window. The bit is the `@repo_fold` session
  option (window-identity table above); a parent's own `@expand` is untouched
  underneath, so unfolding the group restores it as it was left. A one-repo
  fleet has no heading and writes nothing: `bin/dash-repo-fold-selftest.sh`
  pins both frames byte-identical with the option set by hand;
- grouping keeps #790's repo-qualified keys, so a child folds under its parent
  across repos.

The short tag (`fleet_repo_short`: `FLEET_REPO_SHORT` in the repo's conf, else its
initials or first two letters, full name on a collision) is the dash badge only.
Window names stay bare in a 2+ repo fleet too (`issue-12`, issue #1023 — #793
used to prefix them `tl·issue-12`); identity is `@repo`/`@issue`, never the name,
so a bare `issue-12` of repo A never blocks repo B's #12.
`bin/repo-view-all-selftest.sh` pins the one view: the picker gone, the footer
byte-identical in a one-repo fleet, a stale `current-repo` ignored, the dash
grouping, and the per-spawn ask.

**Backlog for any repo (issue #794).** The backlog lists every hosted repo
(`fleet_backlog_repos`, in `fleet_repos` order) and `tmux-issues-rows.sh` reads each one's own
`fleets/<slug>/issues|labels|parents` (`fleet_backlog_cache`), one sorted block per
repo, each title led by its short tag under `all`. A row gains a 4th field, its
repo; only that repo's windows mark it bound, so repo A's #12 never hides repo B's.
Every row action passes the row's repo on as `--repo=` (`{4}` in the fzf binds):
the preview, ⌃x close, ⌃y priority, comment, ⌃o open, and Enter/⌃g spawn
(`dash-issue-session.sh --repo`). `fleet_backlog_repo` resolves an action's repo:
the row's (it must be hosted), else `CF_REPO` through a popup, else nothing — the
caller refuses. A new task has no row: the hub's ⌃n takes
the highlighted row's or heading's repo, and with neither asks first with
`fleet-repo-ask.sh` (repo rows only, in the same popup). A one-repo
fleet takes none of these branches: three-field rows, the per-session cache, and
binds with no `--repo`. `bin/backlog-repo-selftest.sh` pins both halves.

**Proven end to end, then switched on (issue #795).** `bin/multirepo-e2e-selftest.sh`
runs the whole path on one throwaway fleet hosting two repos — `fleet-repo.sh add`
(no gate), issue #12 and a scratch in both repos plus a no-repo session, a real
collector + pr-refresh tick, A's PR merging, one cleanup tick, the dash and backlog
under `all` (a stale `current-repo` file changing nothing), and a snapshot → kill → restore round-trip —
with a one-repo fleet beside it on the same road, and (issue #1943) a one-repo
fleet that gains a second repo and loses it again while its sessions' keys, rows,
working directories, restore rows and child ledger stay byte for byte. It gives each of the nine
leak classes EPIC #787 counted (PR/CI by branch, cleanup by bare number, issue-number
collisions, scratch/origin keys, one MAIN per reaper, worktree-name clash,
guard/trust, collector/backlog/hub, restore) at least one assertion, and prints
`leaks: <n>/9`. Its first run found a real one: two hosted checkouts that share a
basename (`…/a/app`, `…/b/app`) under one `FLEET_WORKTREE_ROOT` both map to
`<root>/app-issue-12`, and the spawner reuses an existing dir, so B's worker opened
in A's worktree. `fleet_worktree_dir` now diverts a clashing checkout to
`<basename>-r<cksum of main>-<slug>` (the `-issue-N`/`-scratch-N` suffix every
reader parses is kept) and keeps using that dir while it exists; a free path, or
one that is already this checkout's, is unchanged. The same fix covers two FLEETS
that share a root. In a 2+ repo fleet the hub (`hub-session.sh`) opens in `$HOME`,
because there is no main repo; a one-repo fleet's hub stays in its checkout.

### The launcher pre-trusts the fleet's checkout (issue #563)

Claude Code asks "Quick safety check: Is this a project you created or one you
trust?" once per project root and keys the answer in `~/.claude.json` as
`projects[<root>].hasTrustDialogAccepted` — an **exact** lookup on the resolved
root, where a linked git worktree resolves to its **main checkout** (that is why a
machine with only `FLEET_MAIN` trusted spawns workers straight into their first turn
with no `…-issue-<N>` entries at all). A fleet pane has nobody to press Enter, so
an untrusted `FLEET_MAIN` parks every dispatched worker on that dialog — slot
counted, nothing running, nothing logged (mac-c, 2026-09-12). `bin/fleet-claude.sh`,
the one door every spawn/restore/migrate walks through, therefore calls
`bin/fleet-trust.sh grant --main $FLEET_MAIN $PWD` before `exec claude`. The helper
is the rail: it writes **only** the base checkout and directories whose git common
dir is that checkout's (`.git`), refusing anything else; it edits atomically
(temp + rename, compare-and-swap on the file's identity between read and rename,
so a claude process saving its own state at the same instant loses nothing); it
leaves an unparseable file alone and creates a missing one `0600`. It is
per-directory trust kept per-directory — never a `--dangerously-*` blanket.
`fleet-doctor.sh` (`trust` line) and `fleet-up.sh` warn on an untrusted base for
installs that predate this (the autofill dispatcher's sweep for a pane parked on
the dialog left with it, #3120). `FLEET_PRETRUST=0` opts a
fleet out. Selftests: `bin/fleet-trust-selftest.sh` (scope, losslessness under a
concurrent writer, atomicity), plus the call contract in `fleet-claude-selftest.sh`.

### Hooks read the conf; the launcher does not export (issue #561)

A Claude Code hook runs with the **pane's environment**, and the fleet never
exports `FLEET_*` into it: `fleet.conf` is assignments-only, `fleet-claude.sh`
does not `set -a` it, and the only keys fleet-lib exports on load are the
global-only caps (issue #399) — for its *own* children. So a hook that reads
`${FLEET_X:-default}` from its environment sees the default, always. That is how
`FLEET_AUTO_HANDOFF_PCT=60` sat inert in the global conf for weeks while every
logged handoff cycle was worker-initiated (#561), the same class as #472
(`FLEET_MODEL` visible only to the launcher). A selftest that injects the knob via
the env stays green through exactly that failure — it must drive the conf.

**The rule: a hook (or anything it spawns) that needs a `FLEET_*` knob loads the
conf — global `fleet.conf`, then this fleet's overlay — and never assumes the
launcher exported it.** Three shapes, one resolution:

| Hook shell | How it resolves | Example |
|---|---|---|
| bash | source `fleet-lib.sh` (auto-sources the global conf) then `fleet_load_conf "$(fleet_current_session)"` | `session-end-hook.sh`, `fleet-context.sh` |
| `sh` (cannot source the bash-only lib) | `bash bin/fleet-hook-conf.sh KEY…` — the same two steps in a ≈20 ms bash hop | `set-claude-state.sh` (the auto-handoff threshold) |
| python | `bash -c 'source lib; fleet_load_conf "$(fleet_current_session)"; printf "$KEY"'` | `base-readonly-guard.py` (`FLEET_MAIN`), `bash-guard.py` (`FLEET_BASE_BRANCH`) |

The environment is still honoured as an **explicit override** (a selftest seam,
or an operator who exports by hand): a conf assignment overrides an inherited
value, and a key no conf sets is left as the env had it. Operator escape hatches
(`FLEET_ALLOW_SENDKEYS`, `FLEET_ALLOW_ARTIFACT`, `FLEET_ALLOW_SUBAGENT`, …) are
env-only *by design* —
they are per-command switches, not fleet configuration. `fleet-doctor.sh`
evaluates the auto-handoff threshold through the hook's own resolver
(`handoff  … (hook sees N)`) and WARNs `hook sees 0 — nudge inert` when the conf
says otherwise, so this cannot silently regress again.

**A hook must also know whose session it is.** A `claude -p` helper launched from
inside a pane — the Stop-hook classifier, any headless claude a worker's Bash tool
spawns — inherits `$TMUX`/`$TMUX_PANE` *and* the global hooks, so its own
SessionStart/Stop fire against the pane: the classifier's SessionStart cleared the
pane's auto-handoff latch on every classification, and its Stop read the pane's
`@ctx_pct`, received the block decision meant for the TUI, ran `/fleet-handoff` on
itself and `/clear`-ed the operator's pane — 16 cycles in a day, one every ~70 s on
a pane the operator was typing into (#571). Claude Code marks the entrypoint in the
environment its hooks inherit (`CLAUDE_CODE_ENTRYPOINT`: `cli` for the TUI,
`sdk-cli` for `-p`), so `set-claude-state.sh` and `handoff-latch-reset-hook.sh`
exit before touching a window option unless it is `cli`; and the fleet's own helper
is launched `env -u TMUX -u TMUX_PANE`, so every hook no-ops inside it whatever the
marker says. **The rule: a headless helper spawned from a pane runs without
`$TMUX`, and a pane-writing hook checks the session is the TUI's.** The same
incident is why `SessionStart(source=clear)` unsets `@ctx_pct` (the stale
percentage of the session that just ended re-triggered the nudge before the fresh
TUI re-stamped it) and why the nudge is *held* while an attached client is typing
at that window (`FLEET_HANDOFF_DEFER_SECS`).

### Runtime cache layout

The **runtime** cache is ephemeral (regenerated each collector/pr-refresh tick),
split the same way — one directory per fleet (keyed by repo `slug`) plus a
`global/` bucket for machine-wide state:

```
$TMPDIR/.claude-dash/
  fleets/<slug>/       # per repo (slug = owner-name)
    issues  issues.ts  #   backlog cache (+ fetch-complete marker)
    prmap   prmap.ts   #   PR/CI map
    deploy_<sha>       #   deploy verdict per merge sha (live/deploying/failed/unknown, #541)
    labels             #   #num → labels (fleet watcher)
    issue_<n>.json     #   per-issue preview cache
    task_issue-<n>.txt #   spawn seed handoff
  global/              # machine-wide — NOT per-fleet-collidable
    sessmap            #   session<TAB>slug<TAB>repo (collector)
    git_<key>          #   per worktree (globally-unique path key)
    collect.git.cursor #   git-phase round-robin cursor (#552)
    collect.repoqueue  #   repo<TAB>slug: sessmap → issues handoff (#653)
    collect.phase.cursor #  the phase the tick was truncated at; next tick resumes there (#653)
    ctx_<key>          #   per Claude session
    usage · ratelimit  #   account-global usage proxies
    account.* · collapsed · dash_view_* · …   # dash + account UI state
    collect.pid · collect.heartbeat           # collector overlap guard + per-phase heartbeat (#551)
    <unit>.tick                               # each interval daemon's SCHEDULING stamp (#639)
    <unit>.kick.ts · <unit>.kick.lock/        # per-unit self-heal: rate limit + dash trace (#636, #639)
    <unit>.kick.fails · <unit>.reload.ts      # …and its escalation ladder (#639)
    launchd-probe.verdict · launchd-probe.lock/ # is the DOMAIN still spawning at all? (#711)
    quotawatch.lock/ · quotawatch.heartbeat   # quota watch (bin/fleet-quotawatch.sh) lock + heartbeat
    quota.warn.<acct> · quota.ceiling.<acct>  # once-per-reset-window rotation markers (#513)
    account.phase · quota.phase              # 5h-window phase stagger + its re-plan marker (#598)
```

The collector resolves each live tmux session → its repo and records it in
`global/sessmap`. Read-side producers map their session → slug via `sessmap`
(fork-free) and read the slug'd cache through `fleet_cache` / `fleet_cache_dir` —
the SINGLE slug-resolution truth. **All fleets are equal (issue #180): no fleet is
"primary."** A cold-start / unresolved session returns a non-existent path so the
reader shows "loading" until the fetch lands. The `git_`/`ctx_` caches
are keyed by a globally-unique worktree path (so they cannot
collide across fleets) and live under `global/`, keeping the fork-free dashboard
hot path a single slug lookup per repaint.

#### Daemon liveness lives in that bucket too (issue #639)

Every fleet daemon except two is a `StartInterval` unit, and launchd has been
observed to simply stop scheduling *all* of them in a user domain at once — no
error, no exit code, every log freezing inside the same two minutes. Nothing
breaks loudly: the dash serves a two-hour-old world, workers stop being reaped,
autofill stops, the base stops fast-forwarding, `--to-worker` comments reach
nobody. So each daemon stamps `global/<unit>.tick` at the top of its script
(before any early exit — "launchd never spawned me" must stay distinguishable
from "I ran and had nothing to do"), and `bin/fleet-daemon-watch.sh` judges each
against **multiples of that unit's own `StartInterval`** rather than one absolute
number, because the usual shape is degradation: a 60s collector running once per
7–14 minutes never looked stale against the old 600s threshold. A tighter
threshold is only safe because an **in-flight** tick counts as evidence of life
on its own (`global/collect.pid`, while younger than the supersede deadline) — the
collector's heartbeat advances at phase *boundaries*, and one phase can
legitimately run for minutes.

Two asymmetries make the design work:

- **Only a KeepAlive unit may do the healing.** The spinner
  (`com.claude-fleet.spinner`) carries the watch, because an interval unit is
  pended right alongside its patient. That is the same reason the stuck-`working`
  sweep lives there.
- **A `kickstart` buys one execution, not a restored schedule** — measured: six
  units logged zero runs across 27.8 minutes *after* being hand-kicked. So
  ineffective kicks are counted per unit and escalate to a real
  `bootout`+`bootstrap`, verified afterwards, since a unit left *unloaded* is the
  one outcome worse than a pended one.

#### …and sometimes the unit is not the patient (issue #711)

Every rung of that ladder assumes the fault is **one unit's**. On 2026-09-15 it
was not: nine of nine interval units stopped inside the same minute, `launchctl
print` showed `runs` frozen on all of them, and a brand-new throwaway agent —
different label, `ProcessType=Standard`, a one-line `/bin/sh`, bootstrapped
alongside them — **never ran once, not even its `RunAtLoad`**. The whole `gui/501`
domain had stopped spawning jobs. The same install at the same commit was ticking
normally on the other machine.

The fleet-visible cost of that is a **misdiagnosis**, and it is expensive:
`fleet-doctor` printed nine lines each saying "nothing is scheduling
com.claude-fleet.`<x>`" — nine true statements that add up to "the fleet's daemons
are broken", sending the operator to read plists, `ProcessType` and load, none of
which is the fault and none of which they can fix. So the doctor now asks the
question one level up before printing any of them. `bin/fleet-launchd-probe.sh`
bootstraps that same throwaway agent and counts how often launchd runs it:

| ticks in the window | verdict | means |
|---|---|---|
| ≥ 2 | `ok` | the domain schedules — a stale unit is that unit's problem |
| 1 | `no-interval` | `RunAtLoad` fired, the interval never did |
| 0 | `no-spawn` | the domain spawns nothing automatically |
| — | `unknown` | nothing was measured; **never** reported as a verdict |

On `no-spawn`/`no-interval` the N unit lines collapse into one that says *machine,
not fleet — log out or reboot*. The verdict is cached for
`FLEET_LAUNCHD_PROBE_TTL`, and the probe's own deadline lives **inside the job**,
not in the parent's trap, for the reason #697 taught: what leaks here is a
registered LaunchAgent that would tick for ever.

Two details are the difference between this working and not:

- **The trigger cannot be "how many are overdue right now."** That signal dies the
  moment the self-heal is any good: a kick buys one execution, so the unit reads
  fresh again for a whole interval. Measured on the wedged host *with kicks
  running*: **1** unit overdue, **9** units kicked in the previous two minutes. So
  "N units kicked inside the last hour" is the second, load-bearing signature —
  and it is the one that catches the quieter, worse state, where nothing looks
  stale because every daemon is running at its self-heal cooldown.
- **The cooldown therefore is the period.** `launchctl kickstart` is an *explicit*
  command, so it keeps working when nothing is being scheduled — which makes the
  self-heal's cooldown every daemon's real cadence. A flat 600s (sized for the 60s
  units) turned `issue-bridge` and `pr-refresh`, both `StartInterval=15`, into
  ten-minute daemons: a `--to-worker` relay that should land in 15s took up to ten
  minutes. It now scales — `max(3 × interval, 60s)` — which keeps it at or below
  every unit's staleness threshold, handing the rate-limiting back to that
  already-per-unit number.

Recovering the domain itself is **not** automated and should not be: it is a log
out or a reboot, and that is the operator's call.

Stamps are scoped to the **install root**: the live install writes the shared
`global/` bucket above, and any other checkout writes a `dev-<hash>/` sibling — a
worker testing the self-heal inside its own worktree must not put a `↻ dash` trace
on the operator's status bar.

### Bootstrap: `fleet-up.sh [<owner/repo>] [<dir>]`

Where "existing or newly-created checkout" is handled:

0. If no `<owner/repo>` is given, infer it from `$PWD`'s git checkout (`origin`)
   and default `<dir>` to that worktree. (`cf`, from `shell/cw.zsh`, wraps this
   no-arg, from-inside-a-checkout path — but *first* tries `bin/fleet-attach.sh`,
   the fast-path reattach to an already-running fleet: it only walks the fleet-up
   path below when nothing is live. See issue #212.)
1. **One fleet per login** (issue #979). `session` = the login's one configured
   fleet (it keeps its name), else `fleet` for a brand-new one — never derived
   from a repo. When that fleet is configured and `<owner/repo>` is not its own
   repo, the fleet comes up on its OWN repo (if down) and the named repo is added
   (`fleet_repo_register`, what `fleet-repo.sh add` runs). A `--name` that is not the login's
   fleet is refused: a second fleet means a second login. Already up on its own
   repo → attach, no rewrite.
2. Checkout: if `<dir>` exists and is that repo → use it; else clone it. This
   becomes `FLEET_MAIN`.
3. Write `$FLEET_CONF_DIR/fleets/<session>/conf` (`FLEET_REPO`, `FLEET_MAIN`,
   `FLEET_BASE_BRANCH`).
4. `tmux new-session -d -s <session> -c <dir>`; open the standard windows (a
   `work` shell + the `plan` hub, which holds the dash and nothing else — a
   fresh fleet no longer comes up with a hub Claude session).
5. Kick the collector so the dash has data on first paint.

#### The base branch is the repo's TRUNK, never "the branch you're standing on" (issue #603)

`FLEET_BASE_BRANCH` is what every worker branches from and opens its PR against,
so getting it wrong fails in the worst possible way: **nothing looks broken**.
Workers claim, branch, push, CI goes green, PRs merge — onto a branch nobody ships
from, and the trunk silently never moves. (2026-09-12: `fleet-ccquota` sat on
`dashboard-redesign` while the repo's default was `main`; a full round of correct
work landed five commits behind `main`.)

So the only answer taken **quietly** is the repo's authoritative GitHub default.
`fleet_resolve_base_branch()` (`bin/fleet-lib.sh`) is the one place that decides
it, and it reports both the answer and *where it came from*:

| source | how it was found | fleet-up's reaction |
|---|---|---|
| `flag` | an explicit `--base` | silent if it equals the repo default; otherwise warn in full, and **confirm on a tty** (a non-tty — e.g. `fleet-restore.sh` — warns into the log and proceeds) |
| `default` | `gh repo view --json defaultBranchRef` | silent — authoritative |
| `origin-head` | `refs/remotes/origin/HEAD` | warn: gh could not confirm the trunk |
| `checkout` | the branch `<dir>` is on | warn — this is a real guess, and the one that bit us, so it is last-but-one |
| `fallback` | `main` | warn |

The gh lookup runs **even when `--base` was passed**: knowing the authoritative
answer is what lets fleet-up say an explicit base disagrees with the repo instead
of obeying it in silence. `fleet-doctor.sh` carries the matching `base` line — it
re-checks every fleet's conf against its repo's default branch, so a conf written
before this (or one that drifted when a repo re-pointed its default) shows up as a
WARN with the one-line fix. `bin/fleet-base-branch-selftest.sh` pins the order.

Teardown: `fleet-down.sh <session>` kills the session (checkout always left on
disk); `--purge` also removes exactly `fleets/<session>/` (its whole durable
state) + this fleet's `fleets/<slug>/` runtime cache. It asks first (issue
#1846): it lists the sessions that would stop and wants the fleet's name typed on
a terminal, `--yes` from a script (no terminal and no `--yes` = exit 2, nothing
closed). Before the kill it keeps `fleets/<session>/restore.map.down-<UTC>`, and
`fleet-up.sh --undo [<session>]` (`fleet up --undo`) brings every session on it
back on its own conversation and re-arms the auto-restore that down turned off.

## The fleet CLI

| Command | What it does |
|---|---|
| `fleet-up.sh [<owner/repo>] [<dir>] [--name <s>] [--base <b>]` | bring up a fleet: reuse-or-clone the checkout, write the per-fleet conf, open `work`+`dash` windows, kick the collector. No `<owner/repo>` → infer from the current checkout (see `cf`) |
| `fleet-attach.sh` | fast-path (re)attach to an already-running fleet — the no-arg `cf` tries this first (single → straight in, a leftover second → the most recently active, never a picker #980); exits 10 when nothing is live so `cf` falls through to `fleet-up.sh` (issue #212) |
| `fleet-down.sh <session> [--yes] [--purge]` | kill the session after a typed confirmation (`--yes` for a script); `--purge` also drops the conf + slug'd cache; `fleet-up.sh --undo` takes the last down back |
| `fleet-list.sh` | list fleets — `●` live / `○` down · name · repo · checkout, then `↳` each further repo the fleet hosts |

`FLEET_CONF_DIR` (default `~/.config/claude-fleet`) is the knob.

## Migration phases — all shipped ✅

**Phase 1 ✅ — multi-repo data (the load-bearing change).** Collector writes
`sessmap` + `prmap_<slug>`/`issues_<slug>` (repo set enumerated from live tmux
sessions); `fleet-lib.sh` resolves session→repo→slug; dash/status/backlog read
the slug'd files via `fleet_cache`. Every fleet is equal — no "primary" flat
mirror (issue #180); the un-slug'd name is only `fleet_cache`'s cold-start
fallback and is never written.

**Phase 2 ✅ — per-fleet config + bootstrap.** `$FLEET_CONF_DIR/<id>.conf`
overlay (`fleet_load_conf`); `fleet-up.sh` / `fleet-down.sh` / `fleet-list.sh`;
session-spawn (`dash-new-session`/`dash-issue-session`) targets the current
fleet's repo+checkout.

**Phase 3 ✅ — reach + robustness.** Configured-conf **pin**
(fetch repos with no live session); the janitor loops every fleet's checkout;
collector temp files are PID-unique (safe if two collectors overlap).

**Phase 4 ✅ — one directory per fleet (issue #181).** The flat, slug/session-
suffixed namespace becomes `fleets/<session>/` (durable) + `fleets/<slug>/`
(runtime) + `global/`, so each fleet is a self-contained equal and it's no longer
possible to read the wrong fleet's file. `bin/fleet-lib.sh` path helpers are the
single source of the layout; `bin/fleet-migrate-layout.sh` migrates an existing
estate idempotently; every reader dual-reads the old + new layout across the
land→migrate window.

Back-compat rule throughout: with a single fleet and no per-fleet conf,
everything falls back to the global `fleet.conf` + flat cache names, so existing
installs keep working untouched — verified on macOS `/bin/bash` 3.2.57.
