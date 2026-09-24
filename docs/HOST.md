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
bash ~/.claude/fleet/bin/fleet-doctor.sh 2>&1 | grep -E '^\s*\S+\s+(spotlight|wtroot|nofile|sleep|siri|icloud)'
```

## Contents

- [Turn off Spotlight](#spotlight)
- [MCP servers on demand](#mcp)
- [File limits for daemons](#nofile)
- [An unattended Mac](#headless) — auto-login, never sleep, Siri, iCloud, no GUI apps on the console
- [Container VMs](#containers) — how much of the machine Colima / Docker Desktop may take
- [Verify](#verify)

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
<a id="headless"></a>
## An unattended Mac

A Mac that runs unattended is set up like a server that happens to run macOS:
it comes back on its own after a power cut, never sleeps, and runs nothing for
a person who is not there. Each item below was found on the fleet's Mac mini on
2026-09-24, measured, and costs a session something — memory, CPU, or the
machine itself. The doctor's `sleep`, `siri` and `icloud` lines read the first
three; the rest is a checklist.

### Come back on its own: auto-login, never sleep, restart on failure

**Why.** After a power cut or a kernel panic the fleet's daemons, its tmux
servers and every session are gone until someone logs in. A machine that sleeps
drops its SSH connections and stops every session mid-turn, and there is nobody
at the keyboard to wake it.

**Check.** The doctor's `sleep` line reads `pmset -g`: a non-zero `sleep` →
WARN; `0` → PASS, with `autorestart` and `womp` shown beside it (and named
when either is `0`).

```sh
pmset -g | grep -E '^\s*(sleep|autorestart|womp)'
```

**Set it, host-wide** (survives reboots):

```sh
sudo pmset -a sleep 0 autorestart 1 womp 1   # never sleep · restart after a power cut · wake on LAN
sudo systemsetup -setrestartfreeze on         # restart after a kernel freeze (needs admin)
```

`displaysleep` can stay whatever it is — a dark display costs a session nothing.
Then *System Settings → Users & Groups → Automatic login* → the fleet's login,
so a restart lands in a logged-in session where launchd's user agents run.

**The FileVault trade-off.** With FileVault on, automatic login is not
available: the disk is locked until a password is typed at the pre-boot screen,
so after a restart the machine sits there — no SSH, no fleet — until someone
comes by. An unattended box that must come back on its own runs with FileVault
**off**, and relies on the room it is in for physical security; a laptop that
leaves the room keeps FileVault on and accepts that a restart needs a hand.
`fdesetup status` says which you have.

**Undo:** `sudo pmset -a sleep <minutes>` (the WARN names the value it read),
`sudo pmset -a autorestart 0 womp 0`, `sudo systemsetup -setrestartfreeze off`,
and turn automatic login off in the same Settings pane.

**Silence the doctor line** on a host that is meant to sleep (a laptop you
carry): `FLEET_DOCTOR_SLEEP=0`.

### Turn off Siri

**Why.** With Siri on, macOS keeps its helpers resident for the console user
whether or not anyone ever speaks to it. On 2026-09-24 this host had `sirittsd`
(the speech service) at ~470 MB, `siriactionsd` ~290 MB, `Siri AI` ~190 MB,
plus `assistantd` and `siriknowledged` — close to 1 GB of memory that could
hold a session, on a machine nobody talks to.

**Check.** The doctor's `siri` line reads the per-user setting:

```sh
defaults read com.apple.assistant.support "Assistant Enabled"   # 1 = on → INFO · 0 or no key → PASS
```

**Turn it off:** *System Settings → Apple Intelligence & Siri → Siri* off. It is
a per-user toggle, so do it for the login the fleet runs under (the one at the
console). The helpers exit within a minute.

**Undo:** the same toggle. **Silence the line** on a host where you use Siri:
`FLEET_DOCTOR_SIRI=0`.

### Sign out of iCloud, or at least iCloud Drive and Contacts

**Why.** Signed into iCloud, the host syncs an account no session uses: `bird`
(iCloud Drive), `cloudd` (CloudKit) and `fileproviderd` stay resident, and the
sync work is real — on 2026-09-24 `contactsd` had spent 4.5 CPU-minutes over
6 hours keeping a server's Contacts in step with a phone. Every worktree the
fleet writes inside a synced folder would be uploaded too.

**Check.** The doctor's `icloud` line names which of the three daemons are
alive:

```sh
pgrep -lx bird cloudd fileproviderd
```

**Sign out:** *System Settings → Apple Account → Sign Out*. Cost: Find My for
this Mac, and iCloud Keychain / Photos / Messages on it — none of which a fleet
host uses. Remote Login (SSH) and Screen Sharing do not need iCloud.

**Lighter alternative — keep the account, stop the sync.** *System Settings →
Apple Account → iCloud*: turn off **iCloud Drive** (this is what `bird` serves)
and **Contacts**, **Calendars**, **Reminders**, **Notes**, **Photos**. The
account stays (Find My keeps working); the daemons for the services you turned
off exit, and the doctor's line lists only what is left.

**Undo:** sign back in, or turn the services back on. **Silence the line** on a
host that keeps its account deliberately: `FLEET_DOCTOR_ICLOUD=0`.

### No GUI programs on the console

**Why.** A browser or an Electron app (Chrome, Slack, VS Code, Discord) left
open on the console session polls, auto-updates, renders and holds a power
assertion — `pmset -g` on this host listed `Google Chrome` among the processes
*preventing sleep*, i.e. it was awake and working with nobody in front of it.
Each one is hundreds of MB and a share of a core, for nothing a session asked
for.

**Rule.** The console session runs the fleet's tmux and nothing with a window.
A session that needs a browser drives a headless one (the playwright MCP
server, see [INSTALL.md → MCP servers on demand](INSTALL.md#mcp-servers-on-demand))
and quits it when done. Screen Sharing stays on — some tasks need a display —
but what it shows is an empty desktop.

**Check.** No doctor line (what counts as a GUI program is a judgment); look
at what is holding the machine awake and what is largest:

```sh
pmset -g assertions | grep -E 'PreventUserIdleSystemSleep|pid'
ps -axo rss,comm | sort -rn | head -15
```

Also trim *System Settings → General → Login Items* — anything that starts at
login and opens a window runs on every restart.

<a id="containers"></a>
## Container VMs (Colima / Docker Desktop)

**Why.** A container VM takes its CPU and memory slice the moment it starts and
holds it whether a container runs or not; sessions get what is left. Sized too
small, a worker's `docker build` swaps inside the VM and its tests time out;
sized too large, the sessions themselves swap. On 2026-09-24 this host ran
Colima at 4 CPUs / 2 GiB while 25 GB of its memory sat unused.

**The principle: leave half the machine's memory for sessions.** A session is
a `claude` process plus its `node` children (and whatever MCP servers it
starts — see [MCP servers on demand](#mcp)), roughly 0.5–1 GB each at the
concurrency this fleet runs. So:

- **Memory for the VM** ≤ half of physical RAM, minus what the OS keeps
  (a few GB). Most of the time a VM needs far less than that cap; give it
  what the heaviest build on this host needs, not the cap.
- **CPUs for the VM** ≤ half the cores. Cores are shared, not reserved, so
  over-committing here costs less than over-committing memory — but a VM that
  owns most cores starves the `FLEET_GLOBAL_MAX_SESSIONS` calculation the
  doctor's `machine` line makes (issue #889).

**Check** what it has now:

```sh
colima list                                    # CPUS / MEMORY / DISK per profile
docker info | grep -E 'CPUs|Total Memory'      # what the daemon inside sees
sysctl -n hw.ncpu hw.memsize                   # the machine (bytes)
```

**Set it** (Colima re-applies CPU and memory at start; the disk is kept):

```sh
colima stop && colima start --cpu <cores> --memory <GiB>
```

Docker Desktop: *Settings → Resources → Advanced*, then *Apply & restart*.

**Undo:** the same command with the previous numbers (`colima list` showed
them).

<a id="verify"></a>
## Verify

Every item above with a measurable state is one line of `fleet-doctor`'s `host`
section (macOS only — on Linux the section is skipped silently):

```sh
bash ~/.claude/fleet/bin/fleet-doctor.sh 2>&1 | grep -E '^\s*\S+\s+(spotlight|wtroot|nofile|sleep|siri|icloud)'
```

| line | reads | verdicts |
|---|---|---|
| `spotlight` | `mdutil -s /System/Volumes/Data` | enabled → WARN · disabled → PASS · unreadable → INFO |
| `wtroot` | `FLEET_WORKTREE_ROOT` per fleet | `*.noindex` → PASS · else INFO |
| `nofile` | `launchctl limit maxfiles` | < 4096 → INFO · else PASS · unreadable → no row |
| `sleep` | `pmset -g` | `sleep` ≠ 0 → WARN · 0 → PASS (+ `autorestart`, `womp`) · unreadable → INFO |
| `siri` | `defaults read com.apple.assistant.support "Assistant Enabled"` | 1 → INFO · 0 / no key → PASS |
| `icloud` | `pgrep -x bird cloudd fileproviderd` | any alive → INFO (named) · none → PASS |

WARN counts toward the doctor's summary; INFO is advice and never counted. Each
line says how to silence itself (`FLEET_DOCTOR_<LINE>=0`, in the environment or
in `~/.config/claude-fleet/fleet.settings`) so a deliberate choice does not
become a standing warning. The doctor never changes a setting: every command on
this page is yours to run, and the line goes green on the next run.
