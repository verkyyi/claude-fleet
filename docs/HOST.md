# Host setup — a Mac that works only for its sessions

An unattended host (the canonical one is a Mac mini reached over SSH / from an
iPad) should spend its CPU and IO on fleet sessions, nothing else. This page is
the one place the host recommendations live (EPIC #1074). Each section says
**why**, gives the **command**, the **lighter alternative** where there is one,
and **how to undo it**.

`fleet-doctor` has a matching `host` section (macOS only; skipped on Linux) with
one line per recommendation. The doctor only **reports** — it never changes a
system setting. Every change below is yours to run.

```sh
bash ~/.claude/fleet/bin/fleet-doctor.sh 2>&1 | grep -E '^\s*\S+\s+(spotlight|wtroot|nofile)'
```

## Contents

- [Turn off Spotlight](#spotlight)
- [MCP servers on demand](#mcp)
- [File limits for daemons](#nofile)

<a id="spotlight"></a>
## Turn off Spotlight

**Why.** Spotlight (`mds` / `mds_stores`) re-indexes every file the fleet
writes. A fleet creates and deletes git worktrees — each with its own dependency
tree — many times an hour, and nobody ever searches them. On 2026-09-23 the
busiest process on the fleet's Mac mini was not a session but `mds_stores`:
71 CPU-minutes in 4.5 hours of uptime (~16 min/hour), 74% at the instant. An
unattended host has nobody at its keyboard to use Spotlight, so the first host
recommendation is to turn indexing off.

**Check.** The doctor's `spotlight` line reads
`mdutil -s /System/Volumes/Data`: `Indexing enabled` → WARN, disabled → PASS.

```sh
mdutil -s /System/Volumes/Data
```

**Turn it off, host-wide:**

```sh
sudo mdutil -a -i off
```

Cost: Finder search and Spotlight (⌘-space) stop finding files on this machine.
App launching by name through Spotlight may also stop working.

**Lighter alternative — keep Spotlight, exclude only the worktrees.** Spotlight
skips any directory whose name ends in `.noindex`. Point the fleet's worktree
root at one (issue #886), and the churn stops even with indexing on:

```sh
# ~/.config/claude-fleet/fleet.settings (or a fleet's conf)
FLEET_WORKTREE_ROOT="$HOME/projects/.fleet-worktrees.noindex"
```

The doctor's `wtroot` line (same section) says whether each fleet's root has the
suffix. The base checkouts themselves, `~/.claude`, and `node_modules` caches
elsewhere are still indexed this way — which is why host-wide off is the
recommendation for an unattended box. You can also add folders by hand in
*System Settings → Spotlight → Search Privacy*.

**Undo:**

```sh
sudo mdutil -a -i on
```

Indexing restarts and rebuilds the index in the background (expect `mds_stores`
to be busy for a while).

**Silence the doctor line** on a host where you keep Spotlight on deliberately:
`FLEET_DOCTOR_SPOTLIGHT=0` in the environment or in
`~/.config/claude-fleet/fleet.settings`.

<a id="mcp"></a>
## MCP servers on demand

Unless a fleet sets `FLEET_MCP_CONFIG`, every session it spawns starts every MCP
server on the machine. Each one is a resident process per session: the measured
default here was 4 `node` processes under one `claude`. A host running 36 sessions
pays for that 36 times, whether or not a task ever calls those servers.

Point each fleet at the minimal worker set the fleet ships (issue #1078):

```sh
# ~/.config/claude-fleet/fleet.settings (or a fleet's conf)
FLEET_MCP_CONFIG="$HOME/.claude/fleet/conf/mcp-worker.json"
```

Today it is the empty set. A repo that needs a server gets its own copy of the
file with that server added. [INSTALL.md → MCP servers on demand](INSTALL.md#mcp-servers-on-demand)
has the common add-backs, and Codex workers inherit the same value.

**Undo:** unset the key. The next spawned session loads everything again.

<a id="nofile"></a>
## File limits for daemons

**Why.** launchd starts every job at the machine's default open-file limit, which
is 256 on macOS. A long-lived network daemon holds a socket per connected session
plus its pipes and state files. When it reaches the limit it does not crash. It
just stops receiving events, and no log says why.

**What the fleet already does.** Its three always-on daemons raise their own
limit to 65536 (issue #1080). The hub, the webhook supervisor and the spinner
carry `NumberOfFiles` in their launchd plists and `LimitNOFILE` in their systemd
units. Each prints one `nofile=<n>` line to its log at every start, so you can
check that the limit took:

```sh
grep -h 'nofile=' ~/.config/claude-fleet/hub/logs/hub.stderr.log \
  ~/.claude/fleet/logs/webhook.launchd.log ~/.claude/fleet/logs/spinner.launchd.log | tail -3
```

A plist change only applies after the daemon is reloaded. Re-run the install
step for it, or `/fleet-sync-install`, then look for the new line.

**Other LaunchAgents on the host.** The doctor's `nofile` row reads the system
default with `launchctl limit maxfiles` and shows INFO when it is below 4096.
Any other long-lived agent you run gets the same fix in its own plist:

```xml
<key>SoftResourceLimits</key><dict><key>NumberOfFiles</key><integer>65536</integer></dict>
<key>HardResourceLimits</key><dict><key>NumberOfFiles</key><integer>65536</integer></dict>
```

Raising the host-wide default instead (`sudo launchctl limit maxfiles …`) does
not survive a reboot without a LaunchDaemon of its own, and changes every
process on the machine. Per-job limits are the lighter alternative.

**Undo:** delete the two keys from a plist and reload it. The job falls back to
the system default.
