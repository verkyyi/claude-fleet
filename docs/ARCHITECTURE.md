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
| `@origin` | spawn provenance — `issue-<N>` / `scratch-<N>` / `autofill` / … |
| `@claude_state`, `@claude_state_ts` | the state glyph + when it last changed |
| `@cc_account`, `@cc_agent` | which subscription account / which agent it runs |

**`@wid` is the one an operator says out loud.** A window's tmux `window_id`
(`@382`) is re-minted every time the window is re-created, and that happens
constantly — `fleet-migrate.sh` re-created 21 windows in one night, and every
`dash-restore-session.sh` mints another — so it can never be the name for "reap
that one". `@wid` is a **letter + digit** (234 of them, lowercase, digits 1-up so
nothing reads as `0`/`O` or `1`/`l` on a soft keyboard), rendered in the dash's
leftmost `id` column and accepted **wherever a window target is** —
`fleet-migrate.sh b3`, `dash-reap.sh a1` — via `fleet_wid_target`, which passes
any non-handle (`@382`, an index, a name) straight through.

- **Scope: this fleet's live windows.** A handle is **reused** once its window is
  gone, which is what keeps it two characters forever. Durable identity for
  history/the ledger stays the session/transcript id; `@wid` never appears there,
  and the landed (`⌃t`) view shows `·` in that column.
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

### Why the collector is shared (not one-per-session)

A per-session collector would run the account-global work (usage, rate-limit,
ctx over all windows) N times — pure duplication, and N launchd agents to
manage. One shared collector does the global work once, then fans the GitHub
fetch out over the repo set. Fewer processes, less redundant work, no
launchd-per-fleet plumbing.

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
    restore.map       # crash-recovery snapshot (fleet-restore.sh)
    bridge/{seen,since}   # issue-bridge dedup set + watermark (per repo)
    sweep.due         # /sweep scheduling ledger
  accounts/           # GLOBAL — multi-account tokens (unchanged)
  diskguard/          # GLOBAL — disk-guard forensics (unchanged)
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
(`FLEET_ALLOW_SENDKEYS`, `FLEET_ALLOW_ARTIFACT`, …) are env-only *by design* —
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
    ctx_<key>          #   per Claude session
    usage · ratelimit  #   account-global usage proxies
    account.* · collapsed · dash_view_* · …   # dash + account UI state
    collect.pid · collect.heartbeat           # collector overlap guard + per-phase heartbeat (#551)
    quotawatch.lock/ · quotawatch.heartbeat   # quota watch (bin/fleet-quotawatch.sh) lock + heartbeat
    quota.warn.<acct> · quota.ceiling.<acct>  # once-per-reset-window rotation markers (#513)
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
   base branch from the repo's default branch).
4. `tmux new-session -d -s <session> -c <dir>`; open the standard windows (a
   `work` shell + the `plan` hub, which holds the dash and nothing else — a
   fresh fleet no longer comes up with a hub Claude session).
5. Kick the collector so the dash has data on first paint.

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
