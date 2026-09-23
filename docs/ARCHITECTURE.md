# claude-fleet — architecture

New to the vocabulary? Read [TERMS.md](TERMS.md) first.

## Today: one fleet, machine-global

claude-fleet as shipped is **single-fleet**: one tmux session, one repo, config
in a single global `fleet.conf`, one collector on launchd, one flat cache dir
`$TMPDIR/.claude-dash/`. Every script reads the global `FLEET_REPO` / `FLEET_MAIN`.

That's the whole single-repo assumption — it lives in exactly one place (the
global `fleet.conf`), consumed by ~7 scripts.

## Target: many fleets on one machine

**Use case:** on one machine, run several fleets at once. Each fleet is a
distinct tmux session pinned to one GitHub repo, with its own local checkout
(existing or freshly cloned). Fleets must coexist without clobbering each other.

### The model: a fleet ≡ a tmux session ≡ one repo

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
| `@origin` | spawn provenance — `issue-<N>` / `scratch-<N>` / `autofill` / … — and, since #574, an **address**: `fleet_win_for_key` resolves it back to the parent's live window |
| `@reported` | `1` ⇒ this window already pushed its outcome to its `@origin` parent (the reap-time backstop skips it) |
| `@expand` | `1` ⇒ this window's `@origin` children are UNFOLDED on the dash. Absent ⇒ folded, which is the default: the dash shows one line per parent and `←`/`→` open and shut the block. Inverted against `@pin` on purpose — a window nobody has touched must start collapsed |
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

### Worker task sidebar

`fleet-sidebar.sh` loads the fleet's preference; `fleet-sidebar.py` manages a
compact pane on the left of the visible worker. Indexed tmux hooks reconcile it
on attach, window changes, resize and exit. A kernel-held per-fleet lock serializes
those hooks. Only a session with a durable fleet conf on its own named socket is
eligible. Inactive windows lose their sidebar, so worker count does not multiply
the refresh loops. Narrow screens hide it without changing the saved preference.
Navigation moves the same populated pane before selecting the destination, in
one tmux command queue. The curses process, scroll position and rendered list
survive; the destination never first appears at full width and then splits. The
renderer runs from the install root so it cannot pin a departed worker's worktree.
tmux still controls terminal redraws when switching windows. A renderer version
marker replaces older live views once on upgrade.

The pane carries `@sidebar=1`, never `@dash`, and reads
`tmux-dashboard-rows.sh --sidebar`: the hub's live ordering, pinning, needs cues
and folds, with the current worker also exempt from folding. Rows target stable
window IDs. Mouse forwarding and the `fleet-sidebar` keyboard table keep the
agent pane active, so window-targeted messaging, capture and process discovery
still resolve the worker. `@sidebar_worker` records that pane while the view is
present and is cleared from the source window when the view moves. The UI follows
this binding after each move. Clicking the sidebar enters its key table, including
clicks on blank space; tmux 3.6+ also reports clicks on the top pane border.
Release/repeat events preserve navigation.
A row click switches workers but retains sidebar navigation. So do ↑↓/Home/End
(issue #822): a movement key moves the highlight at once and schedules one
follow for `FOLLOW_SECS` (0.25s) later; every further movement pushes the
deadline, so a held key on a slow link is one switch and a row passed over is
never selected. The follow is the same `jump()` a click makes, and touches no
key table — the movement binds re-enter `fleet-sidebar` before their key
arrives, which is what keeps browsing alive across the switch. The mouse wheel
only scrolls the highlight. Clicking the worker, Enter or Escape returns input
(Escape, Enter and ⌃n also drop a pending follow); auto-hiding the sidebar also
clears its key table. The wake hooks (`session-window-changed[72]`,
`client-attached[72]`) carry a two-second dwell — `fleet-sleep.sh wake … --dwell 2`
sleeps, then wakes only if the window is still the session's current one — so
scanning past a sleeping worker never resumes it; the dash is unchanged and
still never switches on highlight or preview.
A double-click on the worker while its sidebar is on screen is tmux's stock
select-word, not zoom (issue #820): the gate is `@sidebar_worker` set and the
window not zoomed, so a zoomed worker and a sidebar-less window keep
double-click-to-zoom; `DoubleClick1Border` is unchanged.
ONE input line closes the list (issue #896; the hints it replaced live in the
`?` sheet's "task sidebar" group). Away from the sidebar it is a bare `›`; with
the keyboard there (a tap anywhere on it, prefix E) it shows a dim `› 新会话名…`,
and typing fills it — no tap on the line first, no popup. Enter on a typed name
runs `dash-raw-session.sh --name <text> --origin hub` in the foreground with
`FLEET_SPAWN_FOCUS=1`: the hub's ⌃s, same script and same provenance (the view
sits in a worker's window, and `--origin hub` stops the spawn nesting under that
worker). The new window becomes current, the window-changed hook moves the view
there, the line empties and the view hands the keyboard to the new agent. A
refusal (the cap, a worktree failure) shows its reason on the line for four
seconds and keeps the name. Escape clears a typed name and keeps the keyboard;
Enter and Escape on an EMPTY line behave exactly as before. `@sidebar_input=1` on
the view pane marks a non-empty line.
The row menu (issue #898) is the hub list's per-row actions without the hub:
`.` on an EMPTY line (inside a name it types a dot), or a tap on the highlighted
row — the second tap on a row the first one switched to — opens a tmux
`display-menu` built by `fleet-sidebar.sh menu <session> <@id>`
(`bin/fleet-sidebar-menu.sh`; the Python never spells tmux syntax). Every item is
the hub's own script handed the row's `@id`: rename (the view's own input line
becomes the name editor, as the hub's ⌃e turns its query line into one — the menu
parks the `@id` on the view and wakes it with F12; Enter hands the name to
`dash-rename.sh --wid` as an argv word. Not tmux's `command-prompt`: its template
re-parses the reply, and tmux 3.4 and 3.7 unescape `%%%` differently), pin (`dash-pin-toggle.sh`), open PR (`dash-open-pr.sh --wid`,
the worktree's branch looked up in the prmap; greyed with none), answer
(`dash-popup.sh … dash-answer.sh <sess>:<@id>`; greyed unless the row is
`needs`), flip new sessions claude⇄codex (`dash-agent-toggle.sh`), reap
(`confirm-before`, then `fleet-sidebar.sh reap` → `dash-reap.sh <@id> --yes`,
whose result token — not its exit code — is toasted), and the row-less new task
(the ⌃n popup). A tap opens the menu on the button RELEASE: tmux closes a menu on
a release outside it, and opened on the press the tap's own release would close
it. `display-menu` holds its caller until the menu closes, so the view spawns it
and does not wait.

How keys reach it — the routing decision. The design keeps the worker the
active pane (above), so typed keys cannot simply land on the view. Two routes
were considered: (1) an `Any` bind in the `fleet-sidebar` table forwarding the
key to the view, or (2) `select-pane` onto the view while the line holds text.
(1) is what ships: `send-keys` with no key argument sends the key that fired the
bind, so `bind -T fleet-sidebar Any … send-keys -t '{top-left}'` delivers
letters, digits and multi-byte UTF-8 (CJK from an IME) whole, and the active
pane never changes. `{top-left}` is the view — it is always the full-height
leftmost pane — and a guard on `@sidebar` sends the key to the worker instead
when it is not there. The view reads raw bytes and decodes UTF-8 itself, so a
CJK name survives whatever locale tmux started the pane under. Verified on an
isolated socket, on tmux 3.7 locally and on CI's tmux 3.4, by
`fleet-sidebar-selftest.sh` — with one version limit: tmux 3.7 handles a BURST
of keys (one terminal write: an IME commit, a paste-speed typist) key by key in
the table, but 3.4 looks the later keys of a burst up before the bind's queued
`switch-client` re-enters it, so they reach the worker instead. Keys typed one
at a time work on both; the live installs run 3.7, and the selftest types a
burst only there. Its costs, each handled in the conf: tmux still
honours the prefix inside a custom table, so prefix binds (prefix e hides) keep
working; but `Any` also matches keys and mouse events the root table used to
pick up for an unbound key, so F9, the wheel and the status-bar tap are bound
in `fleet-sidebar` too (the tap is a verbatim copy of the root block, compared
by the selftest), and any other mouse event (`#{mouse_x}` is set only for one)
drops back to root and is forwarded to the pane under it. Enter and Escape
test `@sidebar_input` on `{top-left}` to keep the keyboard on a non-empty line.

Every letter types now — `q`, `n`, `j`, `k` included — so movement is ↑↓ only
and hiding is prefix e only: no click and no letter hides the sidebar or writes
the saved preference (a tap on the bottom row used to, and it is the easiest
target to mis-hit on a touch screen, issue #821). The hub's new-task popup
(file an issue and spawn its worker) moved from `n` to ⌃n, registered as
`new` in `dash-keymap.sh --panel sidebar` — the first row of that table, which
later sidebar keys join. The view reads ⌃n as the byte 0x0e; when ⌃n is the
operator's tmux prefix the ⌥n fallback applies, which the conf rewrites to ⌃n.
The popup opens from the sidebar pane (`dash-popup.sh`, which resolves the
client and holds `@popup_open` for its lifetime; the view pauses its repaint
meanwhile and leaves curses so an inline fallback has a tty); the spawned
window becomes current and the view follows, and a cap refusal leaves the issue
filed with a toast, as from the dash.
Focus cues use the client's key table, not just `pane_active`: an amber
**TASKS · INPUT** pane border means sidebar navigation, a blue **WORKER · INPUT**
badge means worker input, while the `▶` row always identifies the current task.
There is no title row inside the sidebar; task descriptions start at row zero.
The spinner samples the worker screen for stuck-working detection instead of
using window activity, which includes sidebar repaints. The view exits if its
worker disappears, including tmux versions where a manual kill emits no exit hook.

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
→ it drops out. An optional `FLEET_REPOS` pin covers the rare case of wanting a
repo fetched with **no** session open (e.g. a repo you're watching but
not actively working).

### Config + durable-state layout — one directory per fleet (issue #181)

Every fleet's **durable** state is a single directory keyed by its tmux session
name, so a fleet is a self-contained, equal unit (`ls .../fleets/` = the fleets):

```
~/.config/claude-fleet/
  fleets/<session>/
    conf              # per-fleet overlay — same keys as fleet.conf.example
    repos/<slug>.conf # a further repo this fleet hosts (issue #788) — see below
    current-repo      # the repo the dash/backlog is filtered to (`all` = none)
    restore.map       # crash-recovery snapshot (fleet-restore.sh)
    bridge/{seen,since}   # issue-bridge dedup set + watermark (per repo)
    sweep.due         # /sweep scheduling ledger
  accounts/           # GLOBAL — multi-account tokens (unchanged)
  diskguard/          # GLOBAL — disk-guard + runaway forensics; orphan-seen /
                      #   orphan-current are the #697 watchdog's cross-tick state
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

### A fleet can host several repos (issue #788)

The fleet conf's own `FLEET_REPO`/`FLEET_MAIN`/`FLEET_BASE_BRANCH` are **one
registry entry** — no migration. Each further repo is an overlay at
`fleets/<session>/repos/<slug>.conf` with the same three keys plus any per-repo
override (`FLEET_MODEL`, `FLEET_AGENT`, `FLEET_MCP_CONFIG`, `FLEET_DEPLOY_*`); the
fleet conf keeps the fleet-wide defaults. All hosted repos are equal — there is no
main repo. `bin/fleet-repo.sh add|remove|list` manages them; `add` refuses unless
`FLEET_MULTIREPO=1` (the gate the batch's end-to-end check, #795, lifts).

A window names its repo with `@repo=<owner/name>`; `@norepo 1` marks a session
that deliberately belongs to none. Resolution goes through `bin/fleet-lib.sh`
only — `fleet_repos`, `fleet_window_repo`, `fleet_load_repo_conf`,
`fleet_current_repo`/`_set` — never an ad-hoc `git remote` parse.
`fleet_window_repo` reads `@repo`, else derives it once from `@worktree`'s git
origin and stamps it, else takes the fleet's only repo, else answers **nothing**
— and the consumer skips the window rather than guess.

`fleet_load_conf` is window-aware: inside a pane of the fleet it loads, whose
window resolves to a hosted repo, that repo's overlay is applied on top (the conf
repo's identity + deploy keys are dropped first, so they never leak across). That
one change moves every in-pane consumer — hooks, `commands/*.md`, the launcher's
trust/model/MCP, the claim brief. **Degenerate case:** with no `repos/` dir it
returns before any tmux call, byte-for-byte what it did before
(`bin/fleet-repo-selftest.sh` pins it). The collector and pr-refresh fetch
`issues`/`prmap` for every hosted repo, and `hooks/base-readonly-guard.py`
protects every hosted repo's `FLEET_MAIN`.

PR status joins on **(repo, branch)**, never the branch alone (issue #792) — two
hosted repos can each have an `issue-3`. Once a fleet has a `repos/` overlay
(`fleet_has_repo_overlays`, builtins only), pr-refresh matches each window against
its own repo's `fleets/<slug>/prmap` (stamping `@repo` through `fleet_window_repo`
for a window that has none), and the dash's row producer reads `@repo`/`@norepo`
off its one `list-windows` and keys the frame's narrowed haystack
`<slug>\t<branch>` — still one awk per frame, so #662's bound holds. `deploy_<sha>`
is read from the window repo's dir. A window with no repo, or an unknown one in a
2+ repo fleet, gets no PR cell. No overlay → the per-session prmap exactly as
before (`bin/dash-rows-multirepo-pr-selftest.sh`).

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
Degenerate: every caller takes its historic path when the fleet has no overlay (`fleet_has_repo_overlays`);
`bin/fleet-cleanup-multirepo-selftest.sh` pins both.

### The launcher pre-trusts the fleet's checkout (issue #563)

Claude Code asks "Quick safety check: Is this a project you created or one you
trust?" once per project root and keys the answer in `~/.claude.json` as
`projects[<root>].hasTrustDialogAccepted` — an **exact** lookup on the resolved
root, where a linked git worktree resolves to its **main checkout** (that is why a
machine with only `FLEET_MAIN` trusted spawns workers straight into `/fleet-claim`
with no `…-issue-<N>` entries at all). A fleet pane has nobody to press Enter, so
an untrusted `FLEET_MAIN` parks every dispatched worker on that dialog — slot
counted, nothing running, nothing logged (macmini, 2026-09-12). `bin/fleet-claude.sh`,
the one door every spawn/restore/migrate walks through, therefore calls
`bin/fleet-trust.sh grant --main $FLEET_MAIN $PWD` before `exec claude`. The helper
is the rail: it writes **only** the base checkout and directories whose git common
dir is that checkout's (`.git`), refusing anything else; it edits atomically
(temp + rename, compare-and-swap on the file's identity between read and rename,
so a claude process saving its own state at the same instant loses nothing); it
leaves an unparseable file alone and creates a missing one `0600`. It is
per-directory trust kept per-directory — never a `--dangerously-*` blanket.
`fleet-doctor.sh` (`trust` line) and `fleet-up.sh` warn on an untrusted base for
installs that predate this; the autofill dispatcher sweeps its fleets for a pane
still showing the dialog (issue-bound, `@claude_state` empty — no hook ever fired)
and stamps it `needs` once, with the fix in its log. `FLEET_PRETRUST=0` opts a
fleet out. Selftests: `bin/fleet-trust-selftest.sh` (scope, losslessness under a
concurrent writer, atomicity), plus the call contract in `fleet-claude-selftest.sh`
and the sweep in `fleet-dispatch-selftest.sh`.

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
| bash | source `fleet-lib.sh` (auto-sources the global conf) then `fleet_load_conf "$(fleet_current_session)"` | `session-end-hook.sh`, `fleet-context.sh`, `classify-sessions.sh` |
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
worker testing the self-heal inside its own worktree must not put `↻ dash kicked`
on the operator's status bar.

### Bootstrap: `fleet-up.sh [<owner/repo>] [<dir>]`

Where "existing or newly-created checkout" is handled:

0. If no `<owner/repo>` is given, infer it from `$PWD`'s git checkout (`origin`)
   and default `<dir>` to that worktree. (`cf`, from `shell/cw.zsh`, wraps this
   no-arg, from-inside-a-checkout path — but *first* tries `bin/fleet-attach.sh`,
   the fast-path reattach to an already-running fleet: it only walks the fleet-up
   path below when nothing is live. See issue #212.)
1. `session = slug(repo)`; refuse if a tmux session by that name already exists
   (one fleet per repo).
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
state) + this fleet's `fleets/<slug>/` runtime cache.

## The fleet CLI

| Command | What it does |
|---|---|
| `fleet-up.sh [<owner/repo>] [<dir>] [--name <s>] [--base <b>]` | bring up a fleet: reuse-or-clone the checkout, write the per-fleet conf, open `work`+`dash` windows, kick the collector. No `<owner/repo>` → infer from the current checkout (see `cf`) |
| `fleet-attach.sh` | fast-path (re)attach to an already-running fleet — the no-arg `cf` tries this first (single → straight in, several → picker, cross-socket detach+attach); exits 10 when nothing is live so `cf` falls through to `fleet-up.sh` (issue #212) |
| `fleet-down.sh <session> [--purge]` | kill the session; `--purge` also drops the conf + slug'd cache |
| `fleet-list.sh` | list fleets — `●` live / `○` down · name · repo · checkout |

`FLEET_CONF_DIR` (default `~/.config/claude-fleet`) is the knob.
(`FLEET_HUB_CMD` is retired — the hub is dash-only and runs no command of yours.)

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
fleet's repo+checkout. (The `FLEET_HUB_CMD` hub-command override is retired.)

**Phase 3 ✅ — reach + robustness.** `FLEET_REPOS` + configured-conf **pin**
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
