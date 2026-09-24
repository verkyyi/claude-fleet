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
bash ~/.claude/fleet/bin/fleet-doctor.sh 2>&1 | grep -E '^\s*\S+\s+(spotlight|wtroot)'
```

## Contents

- [Turn off Spotlight](#spotlight)

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
