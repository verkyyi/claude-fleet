# Machines

Machines ("service nodes" in the console) are the computers that actually run sessions: Mac or Linux. Sessions move between machines; members do not pick one.

> **Hosted customers**: we add, maintain and retire the machines; nothing on this page is yours to do. You can see each machine's state on the **Service nodes & clients** page; to know what happens when you see "Maintenance" or "Lost", the "States" section below is all you need. Running short of machines, or adding more people — tell us.

## States: online · in maintenance · lost

| State | What it is | How the hub treats it |
|---|---|---|
| **Online** | Reporting in as normal | Everything as usual |
| **In maintenance** | An admin marked it "going offline" | No new sessions are sent to it; the sessions already on it keep running |
| **Lost** | Has not reported in for about 15 seconds | Only marked: its sessions grey out in the list; the tasks they held are released after 30 minutes, and **are not reopened elsewhere automatically** |

"Lost" beats "in maintenance": a machine in maintenance that then drops off is lost.

Where to see it: the badges on the cards of the console's **Service nodes & clients** page; the top line of a member client's list, `● mac-a 22 · ◐ mac-b 3 维护中 · ○ linux-a 0` (● online · ◐ in maintenance · ○ lost); on the command line `fleet hub machines` — each machine's state, sessions, load and accounts (spare · used / cap).

## Memory saved by parking

Open a machine's details and look under **Load and memory** for total sessions, working, parked, memory saved and idle sessions still in memory. Zero parked sessions are hidden. Older nodes omit the whole line. Counts include the machine's reporting managed logins; a login without metrics makes the total unknown.

Saved memory sums `rss_mb` from the latest park action for each session identity currently reporting `@park_state=停放中`, including its wrapper and child processes. Resuming removes that saving. The older `@park_saved_mb` stamp is a fallback; a missing reading shows “savings unavailable”. Without a reported parking state, the parked count is zero.

Idle in memory uses the batch definition: the turn has ended (done / looping / waiting for you), a CPU sample of at least 60 seconds uses less than 0.5 CPU seconds per minute, nobody is viewing it and no background job is running. Idle RSS sums only those process trees, including wrappers; nonzero counts include reasons such as an older wrapper or waiting to park. Until a complete sample, idle, working and idle RSS remain unknown and the machine page hides the summary.

On a node, `fleet doctor --park` reads the same census. Read a UTC day's action ledger with `python3 ~/.claude/fleet/bin/fleet_park_metrics.py daily --day YYYY-MM-DD`: park, wake, failure and deferral counts, successful wake p50 / p95, and the share of scheduled wakes starting within 30 seconds. Timing without samples is unknown.

## Letting a person use only some machines

Their sign-ins on every machine stay; you only stop one person using some of them for now: an admin gives that person a **machine allowlist**.

```sh
fleet-machine-policy.sh set gh:2987262 linux-a   # only linux-a
fleet-machine-policy.sh show gh:2987262          # every machine: open / disabled + why
fleet-machine-policy.sh clear gh:2987262         # drop the list: all machines again
```

On a machine outside the list: they cannot connect (`fleet <machine>` says 「这台机器暂未对你开放，可用：…」 — this machine is not open to you for now, available: …), new sessions are not sent there (neither automatic placement nor naming it), sessions already open are disabled within half a minute and show 「已停用（管理员限制）」 (disabled by an admin) in the list. Their sign-in, home directory and records on that machine are not deleted, and come back as they were once the list is dropped. No list = every machine.

## Adding a machine (self-hosted)

1. Console **Service nodes & clients** → **Add service node**. The dialog gives a join code and one command, valid for 1 hour and usable once.
2. Run that command on the machine (it needs sudo). On a Mac it looks like:

   ```sh
   curl -fsSL https://hub.example.com/install/bin/fleet-node-install.sh | sudo bash -s -- --hub https://hub.example.com --join <join-code>
   ```

   A Mac that already has `fleet` can also run `sudo fleet node install --join <join-code>`. On Linux, run the command the dialog gives.
3. When it appears on the page with an "Online" badge, it is added.

Running the same command again repairs it: steps already done are skipped, broken ones redone. Never paste a join code into a chat, a ticket or a commit.

By default a machine holds accounts for 10 people: change it with `fleet hub set fleet.node_user_cap.mac-a 20`. With **Spare logins on every service node** on in Settings, each machine keeps a few empty accounts ready, usable the moment a newcomer signs in.

## Planned downtime: upgrades, moves, new hardware (self-hosted)

Every step is done by a person; no step powers anything off by itself.

1. **Put it in maintenance**: **Maintenance** on its card → give a reason (for example "OS upgrade, about 40 minutes"). Or on the command line `fleet hub set fleet.node_maintenance.mac-a "OS upgrade"`. From this moment no new sessions are sent to it.
2. **Move the idle sessions away**: on that machine, run once in each account

   ```sh
   ~/.claude/fleet/bin/fleet-evacuate.sh --dry-run   # see what would move, and where
   ~/.claude/fleet/bin/fleet-evacuate.sh             # move them
   ```

   Only idle sessions with no uncommitted changes move; nothing that is working is touched. A moved session carries on as it was on the other machine. The `left N` it prints is what stays; run it again once those finish.
3. **Check**: the card's session count falls to 0 (or only the ones you decided may drop with the machine are left).
4. **Shut down, upgrade.**
5. **Afterwards**: power it on; the machine reconnects to the hub by itself and its badge returns to "Maintenance". Run `fleet doctor` on it and check there is nothing red, then **End maintenance** on its card (or `fleet hub unset fleet.node_maintenance.mac-a`).

## Unplanned downtime: power cut, crash, network loss

- **Members**: nothing to do. `fleet` lands on another online machine by itself; sessions on the lost machine cannot be reached for now — start anything urgent again on another machine (task claims are released after 30 minutes).
- **Self-hosted admins**: first tell whether the network dropped or the machine really stopped. With only the network down the sessions are in fact still running, and everything recovers by itself when the network returns. If it really stopped: when it comes back, put it in maintenance **first** (or the hub starts sending it work at once), check it with `fleet doctor`; if the same task has already been reopened on another machine, keep the new one and close the old one, then end maintenance.
- **Hosted**: we handle it, and tell you once it is back.

## Removing a machine for good (self-hosted)

1. Empty it of sessions first, as in "Planned downtime".
2. Take back every person's account on it ([Creating and removing accounts](accounts.md)).
3. **Remove** on its card: the machine's credential is revoked at once and the card disappears. To connect it again later takes a new join code.
