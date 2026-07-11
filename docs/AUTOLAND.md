# claude-fleet — the auto-land daemon (hands-off landing)

> Answers issue #233: *"an opt-in daemon lands landable-green PRs by itself —
> no steward turn, no human."*

The **auto-land daemon** (`com.claude-fleet.land`, `bin/fleet-autoland.sh`) is
the last automation in the fleet lifecycle. The dispatcher (`FLEET_AUTOFILL`)
already automates the *spawn*; the watcher (`FLEET_WATCH`) already automates the
*wake*. Auto-land automates the *land*: instead of the steward watching for a
green PR and running `/fleet-land`, this daemon drives the **same mechanical
lander** (`bin/fleet-land.sh`, issue #231) the moment a PR shows up landable in
the `prmap` cache.

It is **opt-in and OFF by default** (`FLEET_AUTOLAND=1` per fleet).

## ⚠️ The relaxed rail (state it honestly)

Auto-land **removes the human approval gate.** Every other land path — `/fleet-land`,
the dash `⌃l`, `/fleet-land-train`, even worker `/fleet-land-self` — has a human
(or the steward) decide *"the work is complete, land it"* before the merge. This
daemon does **not**: `bin/fleet-land.sh` only ever asks *"is CI green and is the
branch mergeable?"* — it never judges whether the work is done. With auto-land on,
**CI-green + branch protection become the only gate.**

That is a deliberate relaxation, in the same family as `FLEET_SELF_LAND`
(workers may self-merge, re-gated by the steward's `/land` trigger) and
`FLEET_AUTOFILL` (auto-spawn backlog, which spends tokens). So, like those, it is:

- **OFF by default**, opt-in per fleet.
- **Bounded** by an optional label scope guard (`FLEET_AUTOLAND_LABEL`) so a fleet
  only auto-lands PRs it explicitly marked cleared-to-auto-land.

**Recommendation:** on any repo where CI-green does not fully imply "ready to
ship" — anything shared, public, or without strong branch protection — set
`FLEET_AUTOLAND_LABEL` so a human still puts a label on what may land itself.

## How a tick works

Every ~60s the daemon iterates each live fleet (or the sessions named on argv):

1. **Load the fleet's conf**; skip unless `FLEET_AUTOLAND=1`.
2. **Acquire a per-repo lease** (`autoland-<slug>.lock`, mkdir + steal-if-stale) —
   two autoland ticks never double-drive one repo. This is *separate* from the
   land-lease inside `fleet-land.sh`, which serializes across **all** landers.
3. **Honor the disk gate** (`fleet-diskguard.sh --gate`) once per tick — a land
   does a base-checkout pull + worktree teardown; don't add that I/O to a full
   volume (that is the crash-loop guard the other daemons share).
4. **Read `prmap_<slug>`** — the cache `tmux-pr-refresh.sh` already writes. **Zero
   extra `gh`.** A tick that lands nothing costs a few file reads.
5. **Select landable rows**: an OPEN PR whose `ready` column is exactly `ready`
   (CI-green **and** up-to-date **and** mergeable now). `behind` / `conflict` /
   `blocked` / unknown are **left to the steward** in v1.
6. *(optional)* keep only PRs whose bound issue (`issue-<N>` head) carries
   `FLEET_AUTOLAND_LABEL`, checked against the labels cache (zero `gh`,
   **fail-closed** — a PR we can't prove is in scope is not landed).
7. **Land up to `FLEET_AUTOLAND_MAX_PER_TICK`** of them by calling
   `bin/fleet-land.sh <pr>`. Its single stdout token (`landed:` / `eject:` /
   `error:`) is folded into the daemon log; its progress notes stream to stderr.
8. **Release the lease.**

## Detection is cache-only; the land is not blind

The daemon never fetches PR state itself — it trusts the `prmap` verdict for
*selection*. But `fleet-land.sh` **re-validates against live `gh`** before it
merges: it takes the shared per-repo land-lease, holds through green, and
`--match-head-commit`s the merge. So a PR that has drifted to
conflict/behind/failing/blocked/draft/merged/gone since the cache was written is
**ejected, never force-merged** — the daemon logs the eject and moves on, leaving
it for the steward. An already-merged PR short-circuits to the base-pull + teardown.

This split matters: a *stale* `ready` in the cache can only ever cause a wasted
`fleet-land` invocation that ejects — never a wrong merge.

## Serialization with the other landers

`fleet-land.sh` takes the **shared** per-repo land-lease
(`land-<slug>.lock`, `bin/fleet-land-lease.sh`) that `/fleet-land`,
`/fleet-land-train`, `/fleet-land-self` and the dash `⌃l` all take. So the
auto-lander and a human landing by hand can never collide on one repo — whoever
holds the land-lease lands; the other queues or the next tick retries. The
daemon's own `autoland-<slug>.lock` is a lighter guard, only against two
*autoland* ticks overlapping.

## Enable it

Per-fleet, in `$FLEET_CONF_DIR/fleets/<session>/conf` (or the modal, `prefix+c`):

```sh
FLEET_AUTOLAND=1                 # opt in — REMOVES the human approval gate
FLEET_AUTOLAND_LABEL="autoland"  # recommended: only issues labeled `autoland` auto-land
#FLEET_AUTOLAND_MAX_PER_TICK=1   # default 1 (paced; the 60s tick is the cooldown)
```

Then install the daemon:

```sh
# macOS — substitute __HOME__ + __BREW_PREFIX__ like the other plists, then:
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude-fleet.land.plist

# Linux
systemctl --user enable --now claude-fleet-land.timer
```

## Try it without landing anything

`--dry-run` prints what *would* land and mutates nothing — no lease, no `gh`, no
merge:

```sh
bash ~/.claude/fleet/bin/fleet-autoland.sh --dry-run          # every fleet
bash ~/.claude/fleet/bin/fleet-autoland.sh --dry-run mysess   # one fleet
```

Each line reads `would land PR #<n> (branch issue-<n>)  [slot k/cap]`.

## Tunables

| Env (per-fleet) | Default | Meaning |
|---|---|---|
| `FLEET_AUTOLAND` | `0` | `1` = auto-land this fleet (approval gate OFF) |
| `FLEET_AUTOLAND_MAX_PER_TICK` | `1` | max PRs landed per tick (rate-limit) |
| `FLEET_AUTOLAND_LABEL` | *(none)* | only land PRs whose issue carries this label (fail-closed scope guard) |
| `FLEET_AUTOLAND_LEASE_TTL` | `300` | autoland per-repo lease lifetime (seconds) |
| `FLEET_DISPATCH_LEASE_DIR` | `~/.claude/leases` | lease dir (shared with the dispatcher) |

## Files

| File | Role |
|---|---|
| `bin/fleet-autoland.sh` | the daemon (this doc) |
| `bin/fleet-land.sh` | the mechanical lander it drives (issue #231) |
| `bin/fleet-land-lease.sh` | the shared per-repo land-lease |
| `launchd/com.claude-fleet.land.plist.tmpl` | macOS unit (StartInterval 60) |
| `systemd/claude-fleet-land.{service,timer}` | Linux unit (60s) |
| `bin/fleet-autoland-selftest.sh` | hermetic contract test |
