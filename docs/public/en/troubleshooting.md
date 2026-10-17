# Troubleshooting

When something is wrong, run the check-up first, then look up the symptom. Every row the check-up prints has a section under "Every row of the check-up" on this page (its heading is the row's name): what it checks, and what to do when it reports WARN / FAIL.

## Run `fleet doctor` first

```sh
fleet doctor                              # this computer, this login: one row per item
fleet doctor | grep -E '^ *(WARN|FAIL) '  # only what needs action
sudo fleet doctor --machine               # the machine-wide half of a managed machine (a Mac with the machine daemon)
```

Each row is `<level>  <row name>  <explanation>`:

| Level | Meaning | Act on it? |
|---|---|---|
| **FAIL** | Broken: something about a session or the whole machine does not work | Fix it |
| **WARN** | Will go wrong, or has not caught up with the new version | Look at it; when the explanation says the next round fills it in by itself, wait one round and look again |
| **INFO** | A note, only telling you how things are | No |
| **PASS** | Fine | No |

The exit code is the number of FAILs. Nearly every row's explanation contains its fix (`fix: …` or a command) — **do what it says first**; it is more specific than this page.

What to fix first: **FAILs first, then WARNs**; with several rows at once, fix the lowest layer first — the programs on the machine (`tools` `python3` `tmux`) → daemons and runtime (`daemon` `node` `runtime`) → identity with the hub (`cert` `hubauth` `hub`) → the rest. When a lower layer is broken, the rows above it are usually red along with it.

On a computer with only the client installed (it watches sessions, runs none), `fleet doctor` prints only a few rows such as `fleet` (whether the client has caught up with stable) and `notify` (whether system notifications can pop up); each row's explanation is its fix.

## By symptom

### It will not install: `fleet` not found, the download does not move

- Installed but `fleet` is not found: the command is at `~/.local/bin/fleet`. Open a new terminal window; if that does not help, add `~/.local/bin` to `PATH`.
- The download stalls or reports a certificate error: make sure this computer can open the hub's address (GitHub, when self-hosting on one computer only). Behind a company proxy, get `curl -I <address>` working first.
- Installing on a managed machine: use `sudo fleet node install --join <join-code>`; the same command also repairs — if it fails halfway, run it again, and the steps already done are skipped.

### Cannot sign in: the QR code expired, the certificate was not issued

- The QR code or sign-in link is time-limited; when it has expired, run `fleet login` again for a new one.
- You chose **Confirm** in the browser but the terminal is still waiting: check that the terminal can reach the hub (`fleet doctor`'s `cert` and `hubauth` rows).
- A connection certificate lasts 12 hours and renews itself; when it cannot, the `cert` row says so — run `fleet login` to sign it again.

### Cannot reach a machine, cannot see other machines' sessions

- Read the `hub-sessions`, `hubauth` and `peerlink` rows: whether the hub is there, whether it accepts the token, whether the link between machines works.
- The machine shows "Maintenance" or "Lost" on the hub's machines page: maintenance is set by an admin by hand, and no sessions are sent to that machine; for a lost one, that machine has to come back online first.

### A session stopped, or does not respond

- First check whether it is waiting for you: the "Waiting on you" group in the ⌘P panel.
- The window shows the recovery page (the session exited): ↵ continues the same conversation, `r` starts a new one.
- New sessions will not open and stay queued: read the `admit`, `memory` and `machine` rows — most often this computer's memory or load is at its limit; existing sessions are not affected, and the new one opens once there is room.
- The session says its quota is used up: read the `quota`, `qwatch` and `failover` rows; when a subscription's 5-hour window runs out, it moves to the next subscription automatically (if there is one).

### Sending diagnostics to your admin

```sh
fleet debug report
```

It packs this computer's check-up and logs, sends them to the hub, and gives you a short link — send the link to your admin; no screenshots, no pasted logs. Without a hub, `fleet doctor --bundle <directory>` saves the same thing to a local directory.

## Every row of the check-up

Ordered by "which layer to fix first". Each section starts with whether it comes from `fleet doctor` or `fleet doctor --machine`. When the check-up gains a row this page does not have yet, the repository's self-test says so; `bin/docs-build.sh --troubleshooting-skeleton` prints a skeleton of the missing sections.

### Programs on the machine

#### `tools`

From `fleet doctor`.

- **What it is**: background services have only the most basic `PATH` (`/usr/bin:/bin`); this row checks whether they can find programs such as `tmux`, `claude` and `python3`.
- **On WARN / FAIL**: a FAIL names the ones it cannot find: install them, or write their path in the configuration as the explanation says.

#### `python3`

From `fleet doctor`.

- **What it is**: many of fleet's scripts need Python 3.
- **On WARN / FAIL**: FAIL = not installed. On macOS install the Xcode command line tools (`xcode-select --install`) or `brew install python`; on Linux use the system's package manager.

#### `tmux`

From `fleet doctor` and `fleet doctor --machine`.

- **What it is**: each session is a tmux window, and tmux must be 3.2 or later.
- **On WARN / FAIL**: FAIL = missing or too old: `brew install tmux` (on Linux the package manager). On a managed machine tmux is installed by the updater per the release; wait for its next round (about 5 minutes).

#### `fzf`

From `fleet doctor`.

- **What it is**: the old panel on a node needs fzf 0.45 or later.
- **On WARN / FAIL**: `brew install fzf` (or the package manager). If you only use the new client (⌘P), sessions themselves are not affected.

#### `perl`

From `fleet doctor`.

- **What it is**: the spinner animation uses Perl's Time::HiRes.
- **On WARN / FAIL**: a WARN only means the animation ticks in whole seconds; you can leave it. To fix it, install Time::HiRes.

#### `gh`

From `fleet doctor`.

- **What it is**: sessions read issues, open pull requests and read CI with the GitHub command line `gh`.
- **On WARN / FAIL**: FAIL = not installed: `brew install gh`; WARN = not signed in: `gh auth login`. If you touch no GitHub repository you can leave it.

#### `claude`

From `fleet doctor` and `fleet doctor --machine`.

- **What it is**: whether the Claude Code command line is there.
- **On WARN / FAIL**: install Claude Code and sign in once with a subscription. On a managed machine it is pinned by the release and installed by the updater; wait for the next round.

#### `codex`

From `fleet doctor` and `fleet doctor --machine`.

- **What it is**: whether the Codex command line is there and at the right version. Using only Claude, it is optional (INFO).
- **On WARN / FAIL**: upgrade or reinstall as the explanation says; on a managed machine the updater installs it.

#### `brew`

From `fleet doctor`.

- **What it is**: whether Homebrew's directories belong to this login and it can install things.
- **On WARN / FAIL**: fix the directory permissions with the command in the explanation.

#### `tls`

From `fleet doctor`.

- **What it is**: whether Python can verify the hub's HTTPS certificate.
- **On WARN / FAIL**: install CA certificates (`pip3 install certifi`, or use the system's own python3). On a company network that intercepts HTTPS, add the company's root certificate to the system.

#### `testtmux`

From `fleet doctor`.

- **What it is**: tmux servers left behind by self-tests and dead socket files.
- **On WARN / FAIL**: clear them with the command in the explanation; running sessions are not affected.

### Daemons and runtime

#### `node`

From `fleet doctor`.

- **What it is**: whether the machine daemon on a managed machine (`com.claude-fleet.node`) is running, and whether the hub accepts it.
- **On WARN / FAIL**: not running: the system brings it up within seconds; if it does not, run `sudo fleet node install` again. The hub refuses a login: join again as the explanation says. It says it lacks "Full Disk Access": tick it in System Settings → Privacy & Security → Full Disk Access.

#### `daemon`

From `fleet doctor --machine`.

- **What it is**: whether the machine daemon is installed and running, and whether it restarted onto the current version after a switch.
- **On WARN / FAIL**: run `sudo fleet node install` again (the same command also repairs).

#### `child`

From `fleet doctor --machine`.

- **What it is**: whether the services the machine daemon starts (the credential proxy, the node program and so on) are down.
- **On WARN / FAIL**: the daemon restarts them with a back-off by itself; if one never comes up, read `sudo fleet-node-supervisor.py status` and its log, then run `sudo fleet node install` again.

#### `runtime`

From `fleet doctor --machine`.

- **What it is**: whether a managed machine's runtime (the one copy of the programs every login shares) is a complete release.
- **On WARN / FAIL**: WARN "no runtime" = this is not a managed machine; leave it. FAIL: run `sudo fleet node install` again, or wait for the updater to roll back to the previous version.

#### `update`

From `fleet doctor`.

- **What it is**: the result of the machine updater's last round.
- **On WARN / FAIL**: read `/var/log/fleet-node/update.log` and `sudo fleet doctor --machine`. When a switch adds a FAIL, the updater goes back to the previous version by itself — no rollback by hand.

#### `channel`

From `fleet doctor`; it appears only when the hub has set up a Mac channel.

- **What it is**: which release channel this machine follows — Linux follows stable, Mac follows stable-macos (equal to or behind stable) — and how many versions and how long the Mac channel trails stable.
- **On WARN / FAIL**: the Mac channel more than 2 hours behind usually means the macOS half of the tests is red or has not run: once it is green, Macs catch up by themselves; while it is red, look at its breakage ticket.

#### `cnpath`

From `fleet doctor`; it appears only on the machine that walks the China real-user path.

- **What it is**: the verdict of the last walk of a real user's road from a client in China (connect to the test pod, open the view with a bare `fleet`, ask a new Codex session one sentence, file a task), and how long ago it ran.
- **On WARN / FAIL**: not through: the explanation names the layer it stopped at and the breakage ticket it filed; stable does not move until that ticket is closed or the next walk is green. Not walked for over 12 hours: check that this machine's diskguard daemon is still running.

#### `install`

From `fleet doctor` and `fleet doctor --machine`.

- **What it is**: whether this login's fleet is stable and has no local changes; on a managed machine it also checks that it is linked to the current release.
- **On WARN / FAIL**: behind: wait for the automatic sync, or `fleet update`. Local commits or a fork: the explanation lists which commits; move them away and the sync carries on. Never sync the install by hand from inside a session.

#### `config`

From `fleet doctor`.

- **What it is**: whether the install's table of configuration keys is there (the settings panel lists every key from it).
- **On WARN / FAIL**: missing = an incomplete install: wait for the next sync, or `fleet update`.

#### `login-tree`

From `fleet doctor --machine`.

- **What it is**: whether the release each login's `~/.claude/fleet` points at still exists.
- **On WARN / FAIL**: the updater rebuilds the links on its next round; if it is urgent, run `sudo fleet node install` again.

#### `account`

From `fleet doctor` and `fleet doctor --machine`.

- **What it is**: on this login, whether the subscription token files are all there and readable by their owner only. Machine-wide, whether each account's claude · codex · tmux are linked to the release.
- **On WARN / FAIL**: token file permissions: `chmod 600 <file>`; an empty token: `claude setup-token` to get a new one. The machine-wide half: the updater relinks on its next round.

#### `cache`

From `fleet doctor --machine`.

- **What it is**: whether the copy of Claude Code kept for new accounts is the version the release pins.
- **On WARN / FAIL**: the updater fills it in on its next round.

#### `helper`

From `fleet doctor --machine`.

- **What it is**: a part is missing its helper program.
- **On WARN / FAIL**: the updater fills it in on its next round.

#### `ccquota`

From `fleet doctor --machine`.

- **What it is**: whether the ccquota (the node program) in the release was built from that commit.
- **On WARN / FAIL**: FAIL = the release carries the wrong ccquota: redeploy the hub at stable, then publish the next version. A WARN is an old release that cannot be checked; the next version clears it.

#### `key`

From `fleet doctor --machine`.

- **What it is**: whether the release signing public key the machine pinned matches the current release's signature.
- **On WARN / FAIL**: WARN, not pinned: `sudo fleet node install` pins it. FAIL, no match: do not force this version — find out whether the signing key was changed, and if it was, `sudo fleet node install --release-key <public-key file>`.

#### `codesign`

From `fleet doctor --machine`.

- **What it is**: whether the node program has a fixed signing identity; with one, macOS's privacy permissions survive a version switch.
- **On WARN / FAIL**: the updater signs it on its next round; after that, grant it once in System Settings → Privacy & Security.

#### `admin-agent`

From `fleet doctor --machine`.

- **What it is**: whether the node program in the administrator login that creates accounts is the release's, and has restarted after a switch.
- **On WARN / FAIL**: the updater points it at the release and restarts it on its next round; if it does not restart, restart it by hand as the explanation says.

#### `shell`

From `fleet doctor --machine`.

- **What it is**: whether a taken-over login has a leftover client shell or login hook.
- **On WARN / FAIL**: clear it as the explanation says; the client shell belongs only on computers people use.

#### `drill`

From `fleet doctor --machine`.

- **What it is**: the current release carries a "fail on purpose" drill mark.
- **On WARN / FAIL**: it is a drill; the updater rolls back by itself, nothing to do.

#### `versions`

From `fleet doctor --machine`.

- **What it is**: how many releases the machine keeps and how much disk they take.
- **On WARN / FAIL**: WARN = more than usual: the updater clears the unneeded ones; read `update.log` for why it did not.

#### `credpool`

From `fleet doctor --machine`.

- **What it is**: whether the machine's shared pool of subscription credentials is healthy.
- **On WARN / FAIL**: fix it as the explanation says.

#### `seats`

From `fleet doctor`.

- **What it is**: whether the machine-wide and admin services run as root or as their dedicated role accounts, rather than in some person's login.
- **On WARN / FAIL**: FAIL: run `sudo fleet node install` again to take it back; `sudo fleet-node-supervisor.py seats --json` shows which one.

#### `tenants`

From `fleet doctor`.

- **What it is**: whether a taken-over login has administrator rights or sudo. They must not.
- **On WARN / FAIL**: FAIL: take that login out of the admin group and the sudoers.

#### `rootlog`

From `fleet doctor`.

- **What it is**: whether a root service's log is being written into some person's home directory.
- **On WARN / FAIL**: run `sudo fleet node install` again to move the log to the system log directory.

#### `services`

From `fleet doctor`.

- **What it is**: whether a registered resident service is down, or there is a hand-written start-up item.
- **On WARN / FAIL**: `fleet ls --services` shows which one; delete a hand-written start-up item and register it with fleet instead.

#### `daemons`

From `fleet doctor`.

- **What it is**: whether this login's scheduled services all run on time.
- **On WARN / FAIL**: the explanation names the one that did not run: run the install again, or read its log.

#### `basesync`

From `fleet doctor`.

- **What it is**: whether the service that keeps repositories' main checkouts up to date is installed.
- **On WARN / FAIL**: run the install again (on a managed machine: `sudo fleet node install`).

#### `cleanup`

From `fleet doctor`.

- **What it is**: whether the service that tidies up after a merge (closing the window, the working copy) is installed and can read PR state.
- **On WARN / FAIL**: run the install again; if it says `gh` is missing, install `gh` and run `gh auth login`.

#### `ledger`

From `fleet doctor`.

- **What it is**: whether the service that records every closed session, so it can be picked up later, is installed.
- **On WARN / FAIL**: run the install again.

#### `collect`

From `fleet doctor`.

- **What it is**: whether the collector (which feeds the list and the panel) finished its last round on time.
- **On WARN / FAIL**: stuck or timed out: the explanation names the slowest step; its next round replaces the stuck one by itself. If it stays stuck, read its log.

#### `state`

From `fleet doctor`.

- **What it is**: whether the reconciliation of session states (who is working, who is idle) is running, and how accurate it is.
- **On WARN / FAIL**: check that the sleep service (`com.claude-fleet.sleep`) is running, and read its log.

#### `metrics`

From `fleet doctor`.

- **What it is**: one line of machine metrics a minute (for looking back after an incident).
- **On WARN / FAIL**: no new line for 5 minutes = the disk guard service is not running: run the install again.

#### `ci-runner`

From `fleet doctor`.

- **What it is**: the self-hosted CI runner on this machine (the row exists only when one is configured).
- **On WARN / FAIL**: read the ci-runner line of `sudo fleet-node-supervisor.py status`, and its log.

### Identity and connection with the hub

#### `cert`

From `fleet doctor`.

- **What it is**: whether you have a connection certificate, whether it has expired, and whether the hub accepts it.
- **On WARN / FAIL**: `fleet login` to sign it again; on a machine, run `fleet node install --join <join-code>` again.

#### `hubauth`

From `fleet doctor`.

- **What it is**: whether the hub accepts this machine's token.
- **On WARN / FAIL**: check whether the token in `node.env` was replaced; `fleet login`, or get a new join code on the hub's machines page and join again.

#### `hub`

From `fleet doctor`.

- **What it is**: whether this computer's settings for the hub agree with one another, and which identity the list asks the hub with.
- **On WARN / FAIL**: two places disagree: `fleet-conf.sh migrate` merges them into one (a sync runs it too). It cannot ask the hub: `fleet login`.

#### `hub-sessions`

From `fleet doctor`.

- **What it is**: whether the list of sessions on other machines is being refreshed.
- **On WARN / FAIL**: fix it as the explanation says: is the hub there, is the token right.

#### `hub-image`

From `fleet doctor`.

- **What it is**: whether the version the hub runs and stable are the same commit.
- **On WARN / FAIL**: behind or forked: redeploy the hub at stable, or wait for the next release.

#### `personcert`

From `fleet doctor`.

- **What it is**: whether a service on the machine is using a person's sign-in certificate. A machine should use only its own token.
- **On WARN / FAIL**: check `node.env` and the credential proxy, and make the machine use its own token.

#### `compute`

From `fleet doctor`.

- **What it is**: whether the hub can send sessions to this machine. It only reports.
- **On WARN / FAIL**: to keep the hub from sending sessions here, write `CCQUOTA_FLEET_COMPUTE=0` in `node.env`.

#### `承载`

From `fleet doctor`. (The row's name means "host": this computer runs sessions.)

- **What it is**: whether this computer runs sessions itself, and whether its token is there.
- **On WARN / FAIL**: fix the token as the explanation says; to have it run sessions: `fleet host on`.

#### `可信`

From `fleet doctor`. (The row's name means "trusted".)

- **What it is**: whether the hub treats this machine as trusted. An untrusted machine gets no subscription credential, and its sessions go through the central proxy.
- **On WARN / FAIL**: WARN = sessions cannot use the subscriptions: the hub's admin marks this machine trusted.

#### `能力`

From `fleet doctor`. (The row's name means "capabilities".)

- **What it is**: what role this computer has (watch only / runs sessions too), and whether there is only one configuration.
- **On WARN / FAIL**: still reading an old configuration file: `fleet-conf.sh migrate` merges it into one.

#### `mode`

From `fleet doctor`.

- **What it is**: local mode (connected to no hub) or connected mode. It only reports.
- **On WARN / FAIL**: nothing to do.

#### `dist`

From `fleet doctor`.

- **What it is**: where this login gets new versions from. Connected to a hub, it should get them from the hub.
- **On WARN / FAIL**: switch it back to the hub as the explanation says.

#### `agent`

From `fleet doctor`.

- **What it is**: whether every login's node program on this machine is at stable.
- **On WARN / FAIL**: with the command in the explanation, look with `--dry-run` first, then restart them one by one.

#### `agentdup`

From `fleet doctor`.

- **What it is**: one login runs more than one node program, and they keep knocking each other's connection to the hub off.
- **On WARN / FAIL**: restart through the start-up item with the command in the explanation, keeping only one.

#### `peerlink`

From `fleet doctor`.

- **What it is**: whether the link between machines (used to see sessions on other machines) works.
- **On WARN / FAIL**: `fleet-peerlink.py status` shows the last few rebuilds and why.

#### `sshtrust`

From `fleet doctor`.

- **What it is**: whether `~/.ssh/authorized_keys` holds a permanent key of another fleet machine. Machines should use only the 5-minute certificates the hub signs.
- **On WARN / FAIL**: delete the key lines the explanation names.

#### `releasekey`

From `fleet doctor`.

- **What it is**: whether this computer holds a release signing private key (in the environment, the configuration directory, `~/.ssh` or `~/.config`). The private key belongs only in the release train; machines accept only the offline root key and the keys it vouches for.
- **On WARN / FAIL**: delete the private key the explanation names; if you suspect it leaked, ask your admin to sign a revocation with the root key (the operations docs, "release signing").

To inspect the pinned public key, run `~/.claude/fleet/bin/fleet-release-key.sh status`. When a different root is endorsed by the pinned key, status succeeds and says the next release fetch will automatically re-pin to that root; no manual trust change is needed. Unknown or revoked chains still fail. Managed logins and logins linked to the machine runtime use `/var/db/fleet-node/release.pub`; their login pin has no effect. Status does not change any key.

#### `entry`

From `fleet doctor`.

- **What it is**: whether this machine's entry port (the one members ssh straight into) has an up-to-date list, and whether the system accepted its configuration.
- **On WARN / FAIL**: fetch the list again as the explanation says; read the entry line of `sudo fleet-node-supervisor.py status`.

#### `public`

From `fleet doctor`.

- **What it is**: whether this machine's entry port can be reached from outside.
- **On WARN / FAIL**: check the router's port forwarding, the public address, and whether the host keys match; test again with `sudo fleet-node-supervisor.py entry reach`.

#### `ingress`

From `fleet doctor`.

- **What it is**: whether this machine's own system ssh can be reached from outside.
- **On WARN / FAIL**: check the router's forwarding and System Settings → General → Sharing → Remote Login.

#### `onboard`

From `fleet doctor`.

- **What it is**: whether this newly installed computer can open its first session (a readiness check).
- **On WARN / FAIL**: fix it as the explanation says.

#### `firstrun`

From `fleet doctor`.

- **What it is**: whether the few things a first run needs are all there.
- **On WARN / FAIL**: fix it as the explanation says.

#### `fleet`

From `fleet doctor`.

- **What it is**: whether the client is at stable, and whether a resident service still runs the programs from before a switch.
- **On WARN / FAIL**: the client is behind: `fleet update`. A service did not restart: restart it with the command in the explanation.

#### `team`

From `fleet doctor`.

- **What it is**: whether the team settings the hub hands out (shared MCP servers, skills, settings) have reached this computer.
- **On WARN / FAIL**: `fleet-agent-team.py sync`; the node program also retries on every beat.

#### `roles`

From `fleet doctor`.

- **What it is**: whether the role definitions can be fetched from the hub.
- **On WARN / FAIL**: `fleet-agent-team.py sync`; when they cannot be fetched, sessions use this computer's copy, and opening sessions is not affected.

### Subscriptions and quota

#### `quota`

From `fleet doctor`.

- **What it is**: whether the quota readings of each subscription account can be fetched and are recognized. Without them, fleet can only switch accounts once a session runs into the quota banner.
- **On WARN / FAIL**: check that the hub is there and the account names match; `fleet-account.sh quota --refresh` reads them again.

#### `qwatch`

From `fleet doctor`.

- **What it is**: whether the quota cache is being refreshed and has anything in it.
- **On WARN / FAIL**: fix the credentials first (read the `cert` and `node` rows, `fleet login`), then `fleet-account.sh quota --refresh`.

#### `account-pick`

From `fleet doctor`.

- **What it is**: whether picking an account for a new session is "blind" (no account's quota can be read).
- **On WARN / FAIL**: fix the `qwatch` and `quota` rows first.

#### `failover`

From `fleet doctor`.

- **What it is**: whether a subscription switch is under way.
- **On WARN / FAIL**: `fleet-account.sh failover-status` shows its progress; usually just wait for it to finish.

#### `failover-stuck`

From `fleet doctor`.

- **What it is**: a session's subscription switch keeps failing and is stuck.
- **On WARN / FAIL**: handle it with the `fleet-account.sh migrate --stuck` command in the explanation.

#### `modelcap`

From `fleet doctor`.

- **What it is**: whether the quota readings have per-model windows. It only reports.
- **On WARN / FAIL**: nothing to do.

#### `cred`

From `fleet doctor`.

- **What it is**: which road sessions' subscription credentials take (the central proxy or this machine), and whether it works.
- **On WARN / FAIL**: fix the relay or the credential proxy as the explanation says.

#### `credsep`

From `fleet doctor` and `fleet doctor --machine`.

- **What it is**: credential separation: a session cannot read the subscription's secret; a proxy adds it for the session.
- **On WARN / FAIL**: the proxy is not up: start it as the explanation says, or run the install again. The machine's proxy is not running this version: `sudo fleet-credsep.py machine refresh` (the updater does it every round too).

#### `credsep-all`

From `fleet doctor`.

- **What it is**: whether every managed login on this machine has credential separation.
- **On WARN / FAIL**: a FAIL names the logins without it: an admin runs the explanation's `fleet-credsep.sh machine install --logins managed`.

#### `credproxy`

From `fleet doctor`.

- **What it is**: whether this machine has only one credential proxy (the shared proxy), with every login its tenant.
- **On WARN / FAIL**: a FAIL names proxies still running beside the shared one (login · pid): each keeps its own copy of the subscriptions, a subscription the hub deleted stays there, and sessions get 401. An admin runs the explanation's `fleet-credsep.sh machine install --logins managed` to fold them into the shared proxy.

### Sessions

#### `admit`

From `fleet doctor`.

- **What it is**: admission for new sessions: how much memory this machine has left and how high its load is; when a new session does not fit, it queues.
- **On WARN / FAIL**: a WARN while it is holding sessions back: wait for memory to free up, or close a few sessions you do not need; existing sessions are not affected. It says "no gate at all": turn on at least one limit (the default memory admission is enough).

#### `machine`

From `fleet doctor`.

- **What it is**: the whole machine's load, any runaway orphan processes, the total number of sessions.
- **On WARN / FAIL**: load too high: `fleet-diskguard.sh --orphans` names the runaway processes; stop them.

#### `idle-cost`

From `fleet doctor` (machines hosting sessions).

- **What it is**: new processes per second, fleet CPU usage and the largest sources while the machine is idle. Sampling requires no working session or CI job, except the measuring session itself. Missing or stale state from another login means no measurement.
- **On WARN / FAIL**: WARN above 50 processes per second by default. Run `bash ~/.claude/fleet/bin/fleet-idle-cost.sh` for a 60-second reading; `--json` is for reports, `--idle` checks eligibility, and `--last` prints the saved reading. Source ranking uses 0.2-second snapshots; source rates are estimates and very short-lived processes can be missed. Wait for active work to finish naturally before measuring.
- **Once a day**: a hosting machine takes one reading a day while idle into `~/.config/claude-fleet/global/idle-cost.ndjson` (kept 30 days; a day that was never idle gets one "unmeasured" line) — the line's 「每日读数近 7 天 …」 tail reads it. Over the threshold, one issue a machine a day names the three biggest sources. `python3 ~/.claude/fleet/bin/fleet-idle-daily.py show` lists the last 7 days.

#### `memory`

From `fleet doctor`.

- **What it is**: memory pressure. Under high pressure the system is reclaiming memory, and a little longer may freeze the machine.
- **On WARN / FAIL**: `fleet-memguard.sh --once --dry-run` shows which sessions the memory guard would stop; close sessions you do not need.

#### `cpu`

From `fleet doctor`.

- **What it is**: whether the CPU in a Linux container is pinned at its limit (throttled).
- **On WARN / FAIL**: raise this Linux node's CPU limit, or run fewer sessions.

#### `files`

From `fleet doctor`.

- **What it is**: how many files are open machine-wide against the system limit. When it is full, nothing can open a file.
- **On WARN / FAIL**: find the processes with the most open files (`lsof | awk '{print $1}' | sort | uniq -c | sort -n | tail`); raise the system limit if needed.

#### `pty`

From `fleet doctor`.

- **What it is**: how many terminals are in use machine-wide against the system limit. When it is full, no new window opens.
- **On WARN / FAIL**: close terminals and sessions you do not need; raise the system limit if needed.

#### `nofile`

From `fleet doctor`.

- **What it is**: the system's default per-process open-file limit. It only reports.
- **On WARN / FAIL**: nothing to do: fleet's services raise it themselves.

#### `last-crash`

From `fleet doctor`.

- **What it is**: whether this machine crashed and restarted within the last day.
- **On WARN / FAIL**: read the crash summary in the explanation; check memory, temperature and what was installed recently.

#### `reap`

From `fleet doctor`.

- **What it is**: whether there are sessions that should have been reaped and were not (PR merged, idle for a long time).
- **On WARN / FAIL**: with the command in the explanation, see why each one is still there; a session that is working or has a background job is never reaped.

#### `context`

From `fleet doctor`.

- **What it is**: whether a session carried on after its context filled up and was compacted automatically.
- **On WARN / FAIL**: it says a session did not resume after compaction: go to that session and say "continue"; if it keeps happening, send the record in the explanation to your admin.

#### `handoff`

From `fleet doctor`.

- **What it is**: whether the mechanism that reminds a session to hand off when its context is nearly full is working.
- **On WARN / FAIL**: fix it as the explanation says; most often an incomplete install, cured by one sync.

#### `statusln`

From `fleet doctor`.

- **What it is**: whether sessions' status readings (context left, model) are coming through.
- **On WARN / FAIL**: `jq` missing: `brew install jq`. A window with no reading: reopen those windows.

#### `mod`

From `fleet doctor`.

- **What it is**: whether fleet's extension for Claude Code is installed.
- **On WARN / FAIL**: the extension directory is missing: the next sync fills it in.

#### `hooks`

From `fleet doctor`.

- **What it is**: whether fleet's hooks in Claude Code's `settings.json` are all there.
- **On WARN / FAIL**: merge them once with the command in the explanation (a sync does it too).

#### `settings`

From `fleet doctor`.

- **What it is**: whether Claude Code's default settings are missing keys.
- **On WARN / FAIL**: the next sync fills them in; it adds only what is missing and never changes what you already have.

#### `agents`

From `fleet doctor`.

- **What it is**: whether the default MCP servers and skills are all there.
- **On WARN / FAIL**: the next sync fills them in; it adds only what is missing and never changes what you already have.

#### `agentcfg`

From `fleet doctor`.

- **What it is**: after a version switch, whether the hooks and tools old sessions read at their start are still there. An old session whose ones are gone will break.
- **On WARN / FAIL**: the command in the explanation names those sessions; reopen them one by one (↵ continues the same conversation).

#### `agentdef`

From `fleet doctor`.

- **What it is**: whether this version of Claude Code can start a session from an "agent file".
- **On WARN / FAIL**: `claude update`; on a managed machine wait for the updater to catch up with the release.

#### `commands`

From `fleet doctor`.

- **What it is**: whether fleet's slash commands are installed.
- **On WARN / FAIL**: the next sync fills them in, or `/plugin install fleet@claude-fleet` in Claude Code.

#### `skills`

From `fleet doctor`.

- **What it is**: whether what a few skills depend on is there (the base skill of handoff, the tailscale document preview needs).
- **On WARN / FAIL**: sync once; to use document preview, install tailscale.

#### `plugins`

From `fleet doctor`.

- **What it is**: whether fleet's Claude Code plugins are up to date.
- **On WARN / FAIL**: `claude plugin update <plugin>`, or wait for the next sync.

#### `mcp`

From `fleet doctor`.

- **What it is**: which MCP servers a session starts with. Without an allowlist every session starts all the ones you installed, which eats memory.
- **On WARN / FAIL**: write an MCP allowlist for this fleet (the explanation names the key).

#### `信任框`

From `fleet doctor`. (The row's name means "trust dialog".)

- **What it is**: whether a new session will stop at Claude Code's "do you trust this folder?" question. It only reports.
- **On WARN / FAIL**: nothing to do; when a new session stops there, choose to trust it.

#### `trust`

From `fleet doctor`.

- **What it is**: whether repository directories are trusted by Claude Code in advance. Without it, new sessions stop at the trust dialog.
- **On WARN / FAIL**: grant trust with the command in the explanation.

#### `seed`

From `fleet doctor`.

- **What it is**: where a new session's first message comes from. It only reports.
- **On WARN / FAIL**: nothing to do.

#### `feedback`

From `fleet doctor`.

- **What it is**: whether `/fleet-feedback` (telling the maintainers what you think) is on. It only reports.
- **On WARN / FAIL**: to use it, `fleet feedback on`.

#### `compose`

From `fleet doctor`.

- **What it is**: how long from pressing Enter on a task in ⌘P until you can start typing.
- **On WARN / FAIL**: over 3 seconds: `fleet-compose-latency.sh --last 20` shows which part is slow; send it to your admin.

#### `timing`

From `fleet doctor`.

- **What it is**: over the last 10 times, how long (median) from pressing ⌘P to the panel appearing, and from opening a new session to being able to type. The panel should take under 0.5 seconds, a new session under 3 seconds (when the warm pool has sessions).
- **On WARN / FAIL**: `fleet_timing.py table` shows which part is slow; send it to your admin. If it says "every new session was a cold start", the warm pool is empty: `scratch-pool.sh status` shows why it is not refilling.

#### `oldkeys`

From `fleet doctor`.

- **What it is**: whether retired shortcut keys have been pressed recently. It only reports.
- **On WARN / FAIL**: nothing to do; use ⌘P from now on.

#### `alerts`

From `fleet doctor`.

- **What it is**: the alerts fleet itself raised (alarms, warnings, waiting on you).
- **On WARN / FAIL**: go through what each alert says.

#### `epic`

From `fleet doctor`.

- **What it is**: whether someone is still driving a batch of tasks (an EPIC).
- **On WARN / FAIL**: the heartbeat stopped while the EPIC is still open: in a session bound to no ticket, run `/fleet-epic-run <number>` again.

#### `socket`

From `fleet doctor`.

- **What it is**: whether fleet's tmux server is stuck "half dead" (no window can be opened).
- **On WARN / FAIL**: FAIL: run `fleet-up.sh` as the explanation says; it clears the broken socket and brings the sessions back.

#### `tmuxconf`

From `fleet doctor`.

- **What it is**: whether the fleet configuration the tmux server loaded is the current version.
- **On WARN / FAIL**: reload it with the `fleet-ui-refresh.sh` command in the explanation; a sync reloads it too.

#### `keys`

From `fleet doctor`.

- **What it is**: whether the panel's keys collide with your tmux prefix key.
- **On WARN / FAIL**: change tmux's second prefix key, or that panel key.

#### `rview`

From `fleet doctor`.

- **What it is**: whether clients connected in remotely each use their own view.
- **On WARN / FAIL**: have them disconnect and reconnect as the explanation says; sessions themselves are not affected.

#### `open`

From `fleet doctor`.

- **What it is**: whether the key file used for "open a page on your computer" has the right permissions.
- **On WARN / FAIL**: `chmod 600` that file (the explanation gives the path).

#### `laptop`

From `fleet doctor`.

- **What it is**: whether the small plugin on the iTerm2 side of your laptop is installed and up to date.
- **On WARN / FAIL**: reinstall it once on that laptop as the explanation says.

#### `docprev`

From `fleet doctor`.

- **What it is**: the document preview service: old processes, leftover routes, expired public links.
- **On WARN / FAIL**: clean up with the `share.sh` command in the explanation.

#### `listen`

From `fleet doctor`.

- **What it is**: whether a fleet process has a port open on the local network (which shares a directory with everyone on that network).
- **On WARN / FAIL**: make it listen on `127.0.0.1` only, or stop it.

### Repositories

#### `repos`

From `fleet doctor`.

- **What it is**: which repositories this fleet hosts. It only reports.
- **On WARN / FAIL**: nothing to do; add a repository with ⌘P's **Add a repo…**.

#### `repo`

From `fleet doctor`.

- **What it is**: whether each repository's configuration says which repository it is.
- **On WARN / FAIL**: fill it in as the explanation says; or remove that repository and add it again.

#### `main`

From `fleet doctor`.

- **What it is**: whether the repository's main checkout is there, is a git repository, and has the right remote.
- **On WARN / FAIL**: fix it as the explanation says; the simplest is to remove the repository and add it once more with **Add a repo…**.

#### `base`

From `fleet doctor`.

- **What it is**: which branch sessions start from and merge into. It should be the repository's default branch.
- **On WARN / FAIL**: in the repository's configuration, set `FLEET_BASE_BRANCH` to the default branch.

#### `checkout`

From `fleet doctor`.

- **What it is**: whether the repository's main checkout is on the base branch.
- **On WARN / FAIL**: move away the working copy that is holding the base branch, as the explanation says.

#### `deploy`

From `fleet doctor`.

- **What it is**: whether the "does a merge count as live" setting is right.
- **On WARN / FAIL**: change `FLEET_DEPLOY_REF` / `FLEET_DEPLOY_CHECK` as the explanation says, or delete them (merged = done).

#### `deps`

From `fleet doctor`.

- **What it is**: whether the main checkout's dependencies (such as `node_modules`) are installed; new working copies link to them instead of installing from scratch.
- **On WARN / FAIL**: network problems retry by themselves; for a problem in the repository itself, fix it and reinstall with the command in the explanation.

#### `labels`

From `fleet doctor`.

- **What it is**: whether the repository has the issue labels fleet uses.
- **On WARN / FAIL**: add them with the explanation's `fleet-labels-seed.sh --repo <repo>`.

#### `tickets`

From `fleet doctor`.

- **What it is**: whether each repository's tickets (issues, comments, labels) live on the hub or on GitHub; code and pull requests are not affected. A newly added repository on a machine connected to a hub defaults to the hub; repositories that were already there stay on GitHub.
- **On WARN / FAIL**: it warns only on a wrong value (neither `hub` nor `github`): fix `FLEET_TICKETS` in that repository's settings.

#### `webhook`

From `fleet doctor`.

- **What it is**: for a repository with live forwarding of GitHub events turned on, whether the programs it needs are missing.
- **On WARN / FAIL**: install `gh`, `gh extension install cli/gh-webhook` or python3 as the explanation says.

#### `emit`

From `fleet doctor`.

- **What it is**: whether sending session events out (only when a receiver address is configured) gets through.
- **On WARN / FAIL**: install `curl`; when events pile up, check the receiving end.

#### `github`

From `fleet doctor`.

- **What it is**: whether the GitHub API rate limit is used up. When it is, fleet switches to the other API by itself.
- **On WARN / FAIL**: wait for the limit to reset (the explanation gives the time). It is not a permission problem; no need to sign in again.

#### `wtroot`

From `fleet doctor`.

- **What it is**: which directory working copies are kept in.
- **On WARN / FAIL**: when the directory name does not end in `.noindex`, Spotlight indexes them: rename it as the explanation says.

### This Mac's settings

#### `sleep`

From `fleet doctor`.

- **What it is**: whether a machine running sessions goes to sleep. Asleep, its sessions stop.
- **On WARN / FAIL**: `sudo pmset -a sleep 0 autorestart 1 womp 1` (to undo: the explanation says how).

#### `spotlight`

From `fleet doctor`.

- **What it is**: whether Spotlight is still indexing the disk. It competes with sessions for CPU and disk.
- **On WARN / FAIL**: `sudo mdutil -a -i off` (to undo: `sudo mdutil -a -i on`).

#### `siri`

From `fleet doctor`.

- **What it is**: with Siri on, a few of its background processes stay resident and use memory. It only reports.
- **On WARN / FAIL**: if nobody talks to this machine, turn Siri off in System Settings.

#### `icloud`

From `fleet doctor`.

- **What it is**: the iCloud sync processes stay resident. It only reports.
- **On WARN / FAIL**: if you do not need it, sign out of iCloud, or turn off iCloud Drive and Contacts sync.

#### `network`

From `fleet doctor`.

- **What it is**: whether two network interfaces are on the same subnet. Replies leave through the other one, and connections keep dropping.
- **On WARN / FAIL**: unplug one (wired or wireless, pick one), or change the routes.

#### `launchd`

From `fleet doctor`.

- **What it is**: whether macOS's management of this login's background services (launchd) is healthy. This is the system's state, not fleet's.
- **On WARN / FAIL**: sign out of this account and back in, or restart the computer.

### Reports only

#### `gate`

From `fleet doctor`.

- **What it is**: whether each of the seven security gates that must be met before a public release is done (for the maintainers).
- **On WARN / FAIL**: it only reports; nothing to do.
