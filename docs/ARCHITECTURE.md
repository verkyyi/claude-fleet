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
| `git_<key>`, `ctx_<key>` cache | shared | per-worktree / per-Claude-session, already machine-wide |
| `prmap` / `issues` cache | **per-repo** | the only per-repo data → written as `prmap_<slug>` / `issues_<slug>` |
| **Config (`fleet.conf`)** | **per-fleet** | each fleet = a different repo + checkout |
| **Dash / status / backlog** | **per-fleet view** | reads shared globals **+** its own repo's slug'd files |
| **Steward** | **per-fleet** | sweeping / triage / ledger are stateful per repo; "one writer per ledger" |

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
repo fetched with **no** session open (e.g. a steward that sweeps a repo you're
not actively working).

### Config layout

Per-fleet config keyed by session name:

```
~/.config/claude-fleet/<FLEET_ID>.conf     # same keys as fleet.conf.example
```

Any fleet script resolves `FLEET_ID` from `#{session_name}`, sources that conf.
The shared collector reads *all* of them to build the repo set.

### Cache layout

```
$TMPDIR/.claude-dash/
  usage              # shared (account-global)
  ratelimit          # shared
  git_<key>          # shared (per worktree)
  ctx_<key>          # shared (per Claude session)
  prmap_<slug>       # per repo   (slug = owner-name)
  issues_<slug>      # per repo
```

A fleet's dash/status/backlog reads the shared files plus its own
`prmap_<slug>` / `issues_<slug>` (slug derived from that session's `FLEET_REPO`).

### Bootstrap: `fleet-up.sh <owner/repo> [<dir>]`

Where "existing or newly-created checkout" is handled:

1. `session = slug(repo)`; refuse if a tmux session by that name already exists
   (one fleet per repo).
2. Checkout: if `<dir>` exists and is that repo → use it; else clone it. This
   becomes `FLEET_MAIN`.
3. Write `~/.config/claude-fleet/<session>.conf` (`FLEET_REPO`, `FLEET_MAIN`,
   base branch from the repo's default branch).
4. `tmux new-session -d -s <session> -c <dir>`; open the standard windows (dash,
   steward, a shell); apply the fleet's tmux bindings/status.
5. Steward window arms its own `/loop 45m /sweep` with its own ledger.

Teardown = `tmux kill-session -t <session>`; conf + slug'd cache can be reaped
or left.

## Migration phases

**Phase 1 — make the data multi-repo (this is the load-bearing change).**
- Slug the GitHub cache files: collector writes `prmap_<slug>` / `issues_<slug>`.
- Collector builds the repo set by enumerating tmux sessions → their confs.
- `FLEET_ID` resolution helper (`#{session_name}` → conf + slug).
- Dash/status/backlog read the current session's slug'd files (falling back to
  the flat `prmap`/`issues` names so a single-fleet install is unaffected).

**Phase 2 — per-fleet config + bootstrap.**
- `~/.config/claude-fleet/<id>.conf` resolution; `fleet-up.sh` / teardown.
- Per-fleet steward + ledger wiring.

**Phase 3 — polish.**
- Optional `FLEET_REPOS` pin; janitor loops the discovered mains; docs/screens.

Back-compat rule throughout: with a single fleet and no `FLEET_ID`, everything
falls back to today's global `fleet.conf` + flat cache names, so existing
installs keep working untouched.
