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
| **Steward** | **per-fleet** | triage / ledger are stateful per repo; "one writer per ledger" |

*Collector shared, steward not* is the right split — remember it that way.

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
repo fetched with **no** session open (e.g. a steward watching a repo you're
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
    watch/{keys,needs}    # fleet-watcher edge-dedup keyset + needs level
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

### Runtime cache layout

The **runtime** cache is ephemeral (regenerated each collector/pr-refresh tick),
split the same way — one directory per fleet (keyed by repo `slug`) plus a
`global/` bucket for machine-wide state:

```
$TMPDIR/.claude-dash/
  fleets/<slug>/       # per repo (slug = owner-name)
    issues  issues.ts  #   backlog cache (+ fetch-complete marker)
    prmap   prmap.ts   #   PR/CI map
    labels             #   #num → labels (fleet watcher)
    issue_<n>.json     #   per-issue preview cache
    task_issue-<n>.txt #   spawn seed handoff
  global/              # machine-wide — NOT per-fleet-collidable
    sessmap            #   session<TAB>slug<TAB>repo (collector)
    git_<key>          #   per worktree (globally-unique path key)
    ctx_<key>          #   per Claude session
    summary_<winid>    #   per window (globally-unique tmux window id)
    usage · ratelimit  #   account-global usage proxies
    account.* · collapsed · dash_view_* · …   # dash + account UI state
```

The collector resolves each live tmux session → its repo and records it in
`global/sessmap`. Read-side producers map their session → slug via `sessmap`
(fork-free) and read the slug'd cache through `fleet_cache` / `fleet_cache_dir` —
the SINGLE slug-resolution truth. **All fleets are equal (issue #180): no fleet is
"primary."** A cold-start / unresolved session returns a non-existent path so the
reader shows "loading" until the fetch lands. The `git_`/`ctx_`/`summary_` caches
are keyed by a globally-unique worktree path / tmux window id (so they cannot
collide across fleets) and live under `global/`, keeping the fork-free dashboard
hot path a single slug lookup per repaint.

### Bootstrap: `fleet-up.sh [<owner/repo>] [<dir>]`

Where "existing or newly-created checkout" is handled:

0. If no `<owner/repo>` is given, infer it from `$PWD`'s git checkout (`origin`)
   and default `<dir>` to that worktree. (`cf`, from `shell/cw.zsh`, is a thin
   wrapper for this no-arg, from-inside-a-checkout path.)
1. `session = slug(repo)`; refuse if a tmux session by that name already exists
   (one fleet per repo).
2. Checkout: if `<dir>` exists and is that repo → use it; else clone it. This
   becomes `FLEET_MAIN`.
3. Write `$FLEET_CONF_DIR/fleets/<session>/conf` (`FLEET_REPO`, `FLEET_MAIN`,
   base branch from the repo's default branch).
4. `tmux new-session -d -s <session> -c <dir>`; open the standard windows (a
   `work` shell + the `plan` hub, whose steward pane runs `FLEET_STEWARD_CMD`
   or the built-in default).
5. Kick the collector so the dash has data on first paint.

Teardown: `fleet-down.sh <session>` kills the session (checkout always left on
disk); `--purge` also removes exactly `fleets/<session>/` (its whole durable
state) + this fleet's `fleets/<slug>/` runtime cache.

## The fleet CLI

| Command | What it does |
|---|---|
| `fleet-up.sh [<owner/repo>] [<dir>] [--name <s>] [--base <b>]` | bring up a fleet: reuse-or-clone the checkout, write the per-fleet conf, open `work`+`dash` windows, kick the collector. No `<owner/repo>` → infer from the current checkout (see `cf`) |
| `fleet-down.sh <session> [--purge]` | kill the session; `--purge` also drops the conf + slug'd cache |
| `fleet-list.sh` | list fleets — `●` live / `○` down · name · repo · checkout |

`FLEET_CONF_DIR` (default `~/.config/claude-fleet`) and `FLEET_STEWARD_CMD`
(optional override for the steward pane's command) are the two knobs.

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
fleet's repo+checkout; per-fleet steward-command override via `FLEET_STEWARD_CMD`.

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
