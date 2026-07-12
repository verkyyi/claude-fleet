# claude-fleet — the fleet watcher (zero-token steward wake)

> Answers issue #147: *"a bash watcher sleeps on the fleet and wakes the first
> mate only when something needs you."*

The **watcher** (`com.claude-fleet.watch`, `bin/fleet-watch.sh`) is an always-on
daemon that watches the whole fleet and pings the **steward** only on a
**decision-worthy edge** — a worker getting stuck, the needs-attention count
rising, a `prod-alert` issue appearing. It replaces the steward hand-running
attention pollers: instead of a human staring at the dash, the watcher stares at
the state the other daemons already maintain and taps the steward on the shoulder
when a decision is actually needed.

> **Trimmed in #279.** Once landing was retired (#277), the PR-green→`/land`,
> worker-opened-PR and free-slot edges stopped being decision-worthy — nothing
> triggers a land, the dash already shows an opened PR, and a free slot is
> surfaced by the dash/backlog directly — so they were removed, leaving the
> three attention edges below.

It is **opt-in and OFF by default** (`FLEET_WATCH=1` per fleet). The watcher
process spends **no tokens** — but each wake makes the *steward* take an LLM turn,
so, like the issue-bridge, it is enabled per fleet rather than on
by default.

## Why it is zero-token

Every tick reads **only local state** that `tmux-dash-collect.sh` already
wrote — it calls no LLM and issues **no per-tick `gh` reads**:

| Signal | Source (already maintained) |
|---|---|
| worker state (`working`/`done`/`needs`/`looping`) | window `@claude_state` |
| bound issue | window `@issue` |
| open issue labels | `labels_<slug>` (collector) |

The only outbound work is a single `gh issue comment` **when — and only when — a
new edge fires**. An idle fleet costs a handful of cache reads per tick.

> The collector writes a companion `labels_<slug>` cache (issue→labels), split
> from the **same** `gh issue list` it already runs (no extra call), so the
> watcher can spot `prod-alert` issues without polling.

## Edge-triggered + deduped

The watcher wakes on **transitions, not levels**. Each tick it computes the set of
currently-firing event **keys** (e.g. `stuck:<slug>:<iss>`); a per-repo persisted
keyset records what was already firing. The **new** keys (now − seen) are the
edges → **one batched wake comment**. A condition that persists stays in the set
and never re-fires; if it clears and later recurs, it fires again.

The **first run** for a repo **seeds the keyset silently** — enabling the watcher
on a fleet that already has three stuck workers does **not** flood the steward with
backfill (mirrors the issue-bridge watermark seed).

## The events

| Event | Detected from | Wake message |
|---|---|---|
| **stuck** — a worker looks stuck | `@claude_state == looping` | `#<iss> looks stuck (looping) — investigate?` |
| **needs** — needs-attention count rose | count of `@claude_state == needs` windows | `<k> window(s) need attention` |
| **prodalert** — a `prod-alert` issue appeared | `labels_<slug>` | `prod-alert #<n> filed — first-response?` |

> The PR-green→`/land`, worker-opened-PR and free-slot edges were removed in
> **#279** once landing was retired (#277): nothing triggers a land, the dash
> already surfaces an opened PR, and a free slot is surfaced by the dash/backlog.

## Delivery = the steward control issue (#146)

On an edge the watcher posts one compact comment to this fleet's
`FLEET_STEWARD_ISSUE` via `bin/fleet-comment.sh --to-worker` (left **unmarked** so
the issue-bridge relays it into the `@steward` hub pane). The comment ends with a
trailing `<!-- fleet:wake <slug>:<num> … -->` marker (issue #198) — one coalescing
**subject** per `- ` edge line, in order — so if a burst of wakes queues behind a
briefly-busy steward, the bridge can collapse superseded/duplicate ones to the
current state on drain instead of replaying them (see docs/ISSUE-BRIDGE.md). The
marker is an HTML comment, invisible in the rendered issue. The watcher never talks
to the steward pane directly — the bridge is its **only** channel. So a fleet is
watched only if it has:

- `FLEET_WATCH=1`, **and**
- `FLEET_STEWARD_ISSUE=<n>` set (its wake channel), **and**
- in practice `FLEET_ISSUE_BRIDGE=1` — what actually relays the wake comment into
  the steward. Without a running bridge the wake comment still lands on the issue
  thread (durable), it just won't drive the steward pane.

## Safety / single-writer / disk gate

- **Single-writer per repo.** A `mkdir` lease (`watch-<slug>.lock`, steal-if-stale)
  means two sessions serving one repo can't double-wake — the lease holder scans
  the whole repo, the others skip that tick.
- **Disk-gated.** A tick answers `fleet-diskguard.sh --gate` once; below the disk
  floor it skips entirely (a full volume is the crash trigger — don't add load).
  The diskguard daemon separately notifies the operator about low disk, so a
  skipped tick loses nothing.
- **Idempotent dedup state** lives per fleet at
  `~/.config/claude-fleet/fleets/<session>/watch/{keys,needs}` (issue #181):
  `keys` (the firing keyset) and `needs` (the needs-attention level for the
  rise-compare). The legacy flat `~/.config/claude-fleet/watch/watch_<slug>.*`
  (`FLEET_WATCH_STATE_DIR`) is dual-read until `bin/fleet-migrate-layout.sh`
  moves it.

## Enable it

Per fleet, in `~/.config/claude-fleet/<session>.conf` (or the global
`fleet.conf`):

```sh
FLEET_WATCH=1
FLEET_STEWARD_ISSUE=146     # this fleet's steward control issue (#146)
FLEET_ISSUE_BRIDGE=1        # what relays the wake into the @steward pane
```

Then install the daemon (macOS launchd shown; Linux systemd is the
`claude-fleet-watch.timer` — see `systemd/README.md`):

```sh
# substitute __HOME__ + __BREW_PREFIX__ like the other plists, then:
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude-fleet.watch.plist
```

## Try it without waking anyone

`--dry-run` prints the edges it *would* fire and posts nothing (and does not
persist dedup state, so it is repeatable):

```sh
bash ~/.claude/fleet/bin/fleet-watch.sh --dry-run           # all fleets
bash ~/.claude/fleet/bin/fleet-watch.sh --dry-run <session> # one fleet
```

## Tunables

| Env (per-fleet conf / global `fleet.conf`) | Default | Meaning |
|---|---|---|
| `FLEET_WATCH` | `0` (off) | `1` to watch this fleet |
| `FLEET_STEWARD_ISSUE` | — | control-issue number = the wake channel (required) |
| `FLEET_WATCH_STATE_DIR` | `~/.config/claude-fleet/watch` | dedup keyset + needs-level state |
| `FLEET_WATCH_LEASE_TTL` | `120` | single-writer lease lifetime (seconds) |
