# Separated credentials — 可信机器上，凭据放在会话碰不到的地方

Issue #1971 · EPIC #1967 C4. Switch: `FLEET_CRED_SEPARATE` (fleet.conf `[common]`,
default `0`).

## What it does

On a trusted machine the node agent leases the team's subscription credentials
and writes them where Claude Code / Codex re-read them — files the login owns.
Every session of that login (the model, its tools, a plugin) can read them, and
`node.env` with them: the node token that leases the whole pool again.

Separated, a **role account** owns all of it:

| | today (`0`) | separated (`1`) |
|---|---|---|
| Claude lease | `~/.config/claude-fleet/accounts/<l>.hub/.credentials.json` | `/var/db/fleet-cred/<login>/accounts/<l>.hub/.credentials.json` |
| Codex lease (refresh token `hub-managed`) | `~/.codex/auth.json`, `~/.codex-accounts/<l>/auth.json` | `/var/db/fleet-cred/<login>/codex/{default,<l>}/auth.json` |
| `node.env` | `~/.config/claude-fleet/node.env` (0600) | a symlink into the store; token-less copy in `node.pub.env` |
| credential proxy | runs as the login (C3) | runs as `_fleetcred` (Linux: `fleetcred`) |
| node agent | runs as the login, token from `node.env` | started by root, token down a pipe (fd 3), runs as the login |
| node agent's log | `~/.ccquota/agent.log` | `/var/log/fleet-cred/<login>/agent.log` (dir `root:wheel 0700`) |

**The agent's log leaves the home** (issue #2296). Once the agent is started by
root, launchd opens its `StandardOutPath` (systemd its `StandardOutput=append:`)
*as root* and follows a symlink — a log left in `~/.ccquota/` would let the login
`ln -sf /etc/sudoers ~/.ccquota/agent.log` and have root append to any file. So
install points it at `/var/log/fleet-cred/<login>/agent.log`; reading it takes
`sudo` (`sudo tail /var/log/fleet-cred/<login>/agent.log`). A login separated
before #2296 is moved by the next `install` / `apply` / `machine refresh`, or by
an admin at once: `sudo bash ~/.claude/fleet/bin/fleet-credsep.sh check --fix
--login <login>`. The doctor's `rootlog` row (`fleet-credsep.sh rootlogs`) scans
`/Library/LaunchDaemons` (Linux `/etc/systemd/system`) and WARNs on any service
run as root whose log lies in a home — the fleet's own with that fix line, any
other as "not the fleet's".

`/var/db/fleet-cred/<login>/` is `0700 _fleetcred`. A session doing
`ls /var/db/fleet-cred/<login>` or `cat ~/.config/claude-fleet/node.env` gets
**Permission denied**. A personal Codex login (its own refresh token) and the
label markers (`accounts/<l>` = `hub:<l>`) stay where they are: they are not
the hub's credentials.

## How the pieces still talk

- **Sessions → subscription**: only through the proxy (`FLEET_CRED_PROXY=1`,
  C5's wiring), with a session credential `fcp1.`. The proxy reads the real one
  from the store. All three routes (direct / relay / central) are unchanged.
- **Agent → store**: the agent's lease goes to the proxy's control socket
  (`store`), not to a file (`CCQUOTA_FLEET_CRED_STORE`). The label marker and
  Codex's `config.toml` stay local.
- **Scripts → hub as this machine** (`ccquota lease|place|move`, peer-cert,
  maintenance, team sync, …): `_fleet_hub_env` / `_fleet_node_env_val` hand them
  the **hub broker** — `http://127.0.0.1:<port>/hub` plus a 10-minute `fcpn1.`
  credential — and the proxy puts the node token in on the way out. The broker
  never forwards `POST /v1/node/credentials` (in any spelling): a session can
  place and move, it cannot lease the pool (EPIC route ④). fleet-mcp's worker
  assertion asks the proxy for the token's hash (`node-hash`) instead.
- **Probe**: `fleet-node-probe.sh` hands each new verdict to the proxy (`probe`).
- **Control socket**: `/var/run/fleet-cred/<login>/ctl.sock`, mode 0666, and
  the proxy answers ONE peer uid (`LOCAL_PEERCRED` / `SO_PEERCRED`): the login's
  (and root). No group to create, no re-login.

## Turning it on / off

```sh
# fleet.conf [common]
FLEET_CRED_SEPARATE=1
# then the next sync (install pass `credsep`) — or by hand:
bash ~/.claude/fleet/bin/fleet-credsep.sh install     # needs password-less sudo ONCE
bash ~/.claude/fleet/bin/fleet-credsep.sh status
bash ~/.claude/fleet/bin/fleet-credsep.sh check       # the doctor's `credsep` row
```

### A new login: separated from its first moment (issue #2294, EPIC #2293 C1)

`bin/fleet-login-new.sh --apply` — the hub's account op, and the spare logins of
#2263, which take the same road — separates the login it opens, as step **7b**:
after the clone, **before** its background services and its first session (先代理、
后搬凭据、再开会话):

1. `~<X>/.config/claude-fleet/fleet.conf` is written with `FLEET_CRED_PROXY=1` and
   `FLEET_CRED_SEPARATE=1` in `[common]` (the login's, 0600);
2. as root: `fleet-credsep.sh install --login <X> --fresh --install-dir ~<X>/.claude/fleet
   [--pool-src <the admin's pool>]`. `--fresh` replaces the preflight with "nothing
   runs as this login yet" (exit 6 otherwise). `--pool-src` (only with `--fresh`)
   copies every token file of the pool into `/var/db/fleet-cred/<X>/accounts/<label>`
   — never the login's dir — and gives the login the marker `store:<label>` plus the
   label's `.conf` (a usable label to its account judge; the token itself is the
   store's); an admin marker (`hub:…`) travels as a marker. The proxy reads the
   store's file; a session names the label. `uninstall` puts each token at the login's
   path (the old share-pool layout); a failed fresh install deletes them instead;
   `check` WARNs if a pool label's file holds a token again.
3. the verdict, read **as the login** with its own clone: `status` not `separated`
   fails the open (exit 1 — the login must not be handed out); then `check` (waited
   for up to `FLEET_LOGIN_CREDSEP_WAIT`, 15 s, while the proxy starts). The run's
   LAST line is the one the hub reads: `credsep: separated` · `credsep: pending — <why>`
   · `credsep: off` (`--no-credsep`, the old layout: every pool token copied into the
   login, readable by its sessions — only for a machine whose fleet predates credsep).

From then on the login never needs sudo.

### The hub's backstop: no token to a user's login that is not separated (issue #2295, EPIC #2293 C2)

Should step 7b not have happened — an old script, a by-hand override, a login put
back — the hub still holds the line. Every heartbeat carries `credsep`
(`separated` · `not` · `unknown`), the agent's reading of `fleet-credsep.sh status`
**and** `check` (exit 0 both ⇒ `separated`; asked at most every 5 minutes). For a
GitHub person whose role is **user**, `/v1/node/credentials` issues real tokens only
while that word is `separated`; otherwise it answers 403 `not_separated` and the
credential audit records 「拒发：未隔离」. An agent too old to send the field counts
as not separated. `/v1/node/self` then carries `credsep_gate: not_separated`, and the
login's proxy reads it as an untrusted machine: every session goes **central**
(the hub's proxy, no credential file read) — slower, but it works, and nothing ever
lands in `accounts/*.hub/`. Admin and operator logins lease exactly as before.

### Rolling it out on a machine (issue #2135, EPIC #2133 C5)

One login at a time, the operator types the only `sudo`; nothing else needs root.

```sh
bash ~/.claude/fleet/bin/fleet-credsep.sh plan                 # every login here: state + its commands
bash ~/.claude/fleet/bin/fleet-credsep.sh install --dry-run    # no sudo: every move it would make
sudo bash ~/.claude/fleet/bin/fleet-credsep.sh install         # THE sudo (the login is SUDO_USER's)
bash ~/.claude/fleet/bin/fleet-credsep.sh status               # separated · /var/db/fleet-cred/<login> · …
bash ~/.claude/fleet/bin/fleet-credsep.sh check                # credsep: OK — … Permission denied …
bash ~/.claude/fleet/bin/fleet-credsep.sh uninstall --dry-run  # no sudo: the whole way back
# then FLEET_CRED_SEPARATE=1 in fleet.conf [common], so the sync keeps it
```

Then, in a real session of that login (its Bash tool),
`python3 -I ~/.claude/fleet/bin/fleet-cred-scan.py scan` tries ①②④ and prints
counts only: ① `readable=0`, ② `readable=0`, ④ `readable=0` (or the hub refuses).

- Under `sudo`, `id` says root: the script takes the login from `SUDO_USER` (or
  `--login <login>`, which is how `plan` spells another login's line) and that
  login's own conf dir. Root with neither is refused — before #2135 the hint
  separated a `root` store and left the login's agent unable to read `node.env`
  (BREAK-IT `cred-sep-sudo-root`).
- The dry runs run as the login. Separated, the login cannot read the store, so
  `uninstall --dry-run` reads the way back from `credsep.json`'s `back` — the
  paths each credential left, the agent's and the proxy's service (no secret).
- **A login with password-less sudo** is not separated from its own sessions:
  `sudo -n cat /var/db/fleet-cred/<login>/node.env` works from any session. The
  doctor's `credsep` row says so; on such a login the boundary only holds once
  its sudo asks for a password — the operator's decision (see «What it does not stop»).

Install creates the role account (macOS: UID/GID in 450–499, shell
`/usr/bin/false`, home `/var/empty`), the store, a **root-owned copy** of the
launcher + proxy (`/Library/Application Support/claude-fleet/credsep/`,
Linux `/usr/local/lib/claude-fleet/credsep/` — the role account never runs code
the login can edit), the proxy service (`com.claude-fleet.credsep.<login>` /
`claude-fleet-credsep-<login>.service`), and rewrites the agent's service to
start through the launcher (the original kept in the store's `backup/`). A
systemd `--user` agent is refused: move it to `ccquota-agent-<login>.service`
first.

`FLEET_CRED_SEPARATE=0` + a sync — or `fleet-credsep.sh uninstall` — reverses
it: every file under the store goes back to the login's own path (including
leases the agent renewed meanwhile), `node.env` is a file again, the services
are restored, and the store, the code copy and — with no other login left — the
role account are deleted. The sandbox selftest compares the tree byte for byte
before install and after uninstall.

## One proxy for the whole machine (issue #2217)

On a **managed node** (m4 mini2, m5 macmini) the per-login wiring above meant one
LaunchDaemon and one sudo per login, credentials separated login by login, and
every login on its own proxy version. There the machine runs **one** shared
proxy instead; laptops and client-only computers keep a proxy per login.

```sh
fleet cred-proxy status  --machine        # shared · _fleetcred · on k/N logins · sessions a/b
fleet cred-proxy enable  --machine        # every login with ~/.claude/fleet (or --logins a,b)
fleet cred-proxy disable --machine        # back to a proxy per login, byte for byte
```

`enable --machine` is `fleet-credsep.sh machine install`: ONE sudo for the whole
machine (with password-less sudo it runs; otherwise it prints the line an admin
types). For each login it does what `install` above does — the store, the
credentials and `node.env` moved, the agent through the launcher — and then:

| | per login (today) | shared (`machine install`) |
|---|---|---|
| proxy process | one per login (its own or `com.claude-fleet.credsep.<login>`) | ONE, `com.claude-fleet.cred-proxy-shared` / `claude-fleet-cred-proxy-shared.service`, as `_fleetcred` |
| port | one per login | one fixed `127.0.0.1:18923` (`FLEET_CRED_SHARED_PORT`) — plus each login's OLD port, answering that login only |
| control socket | per login | `/var/run/fleet-cred/.shared/ctl.sock` (0666): the kernel's peer uid (`getpeereid` / `SO_PEERCRED`) names the login |
| the login's proxy state (signing key, held passes, relay pass) | `~/.config/claude-fleet/cred-proxy/` | MOVED to `/var/db/fleet-cred/<login>/cred-proxy/` (binds / revocations / live sessions / trust copied) |
| the leased credentials (Claude `.credentials.json`, Codex `auth.json`) | in the login's store | ONE copy for the machine, `/var/db/fleet-cred/.shared/pool/<kind>/<hash of the access token>/`; the login's store keeps only its index, `cred-proxy/pool.json` (issue #2311) |
| `FLEET_CRED_PROXY` | as the login set it | `1` — the line it had is remembered and put back by `disable` |
| version | each login's install | the root-owned copy in `/Library/Application Support/claude-fleet/credsep/`; an admin login's sync runs `machine refresh` (`sudo -n`) to follow stable, else the doctor says to |

**Each login is a tenant, and stays one.** Everything that was per-login — the
signing key, binds, revocations, live sessions, hub passes, trust, the probe,
the node token, the person's budget, the relay pass, the credentials, the log
(`/var/log/fleet-cred/<login>.log`) — is that login's tenant's; nothing is
shared between two — except the leased credential FILE (issue #2311): a lease is
filed once, under a hash of its access token, and each tenant's index
(`cred-proxy/pool.json`, `<kind>:<label>` → hash) is the only way that tenant's
sessions reach it. Two logins share a file exactly when the hub handed both the
same token (the pool accounts); a token only one login leased is never served to
another, and two people's accounts that happen to share a label stay two files.
A tenant that joined before the pool moves its copies in when the proxy starts;
a file no index names any more is removed; `uninstall` puts each tenant's copies
back as its own files. A session credential minted on the shared proxy carries its
login (`lg`) and is verified with **that** login's key, so a credential relabelled
to another login only fails the signature. A hub pass (the central route) is
filed under the login whose session registered it (`fleet-cred-proxy.sh pass`,
done by `fleet-session-cred.sh`). The control socket answers a login's uid with
its own tenant and nothing else; root names one (`FLEET_CRED_AS`).

**Running sessions do not break.** The signing key moves with the login, and
the login's old port is served by the shared proxy for that login: the login's
own launcher sees `credsep.json` appear, lets go of the port within 2 s, the
shared proxy binds it, and a session minted before the switch goes on with its
next request. `disable --machine` reverses it: the shared service stops, every
login's key and state go back to `~/.config/claude-fleet/cred-proxy/`, its own
proxy takes its old port back with the same key, credentials and the
`FLEET_CRED_PROXY` line go back byte for byte. (A session started *under* the
shared proxy carries the shared port and needs `/fleet-handoff` or a reopen
after a disable.)

A login on the shared proxy ignores its own `FLEET_CRED_SEPARATE`: the machine
switch owns it (`fleet-credsep.sh apply` says `shared`). A login that was
separated per login before joins as it is; after `disable --machine` it is
per-login and unseparated, and `FLEET_CRED_SEPARATE=1` + a sync separates it
again. The shared proxy dying is BREAK-IT `cred-shared-down`.
`bin/fleet-cred-shared-selftest.sh` runs two logins through one proxy in a
sandbox.

## A step fails halfway (issue #2273)

Before it moves anything, `install` / `machine install` checks each login it
is about to take from nothing, as that login: `fleet cred-proxy status` must be
`on`, its route not `down`, and `sessions n/n` — every live session already on
the proxy — and no fresh EPIC batch mark (`fleet_epic_running_fresh`). Any miss
is listed, nothing moves, exit 6; `--force` goes on anyway. (Password-less sudo
on an admin login is meant for the agent — #2197; m4 broke on the ORDER: the
files moved before the proxy was on.)

`install` and `machine install` are all-or-nothing for a login that had
nothing in the store: when a step fails — on 2026-10-07 m4's agent bootstrap
came 4 ms after `bootout` while the old agent was still exiting, and launchd
refused it (`37: Operation already in progress`, printed `Bootstrap failed: 5`)
— every such login is put back from the store's `meta.json` (credentials,
node.env, fleet.conf, the agent's definition, the proxy's key) and the
command exits 1. `load_daemon` now waits for `bootout` to finish and retries
the bootstrap (`FLEET_CREDSEP_BOOT_TRIES`, 3). If a step of the way back fails
too, the exit is 5, the store is kept as `<login>.rolledback-<UTC>`, and the
steps to finish by hand are printed. A store with no `credsep.json` (an install
that stopped before its last step) is undone by `uninstall --login <login>`;
its `--dry-run` says HALF INSTALLED. BREAK-IT rows `cred-sep-by-agent`,
`cred-sep-bootstrap-fails`.

## Where the proxy's settings come from (issue #2290)

Root starts the proxy, but the login writes its own `fleet.conf` and
`secrets.env` — so nothing there may say where a credential goes. The launcher
splits the keys:

| key | read from |
|---|---|
| `FLEET_CRED_PROXY_PORT` / `_TTL` / `_SWITCH_SECS` / `_TIMEOUT` / `_TRUST_SECS` | the login's own files, as before |
| `FLEET_CRED_ANTHROPIC_URL` / `_CODEX_URL` / `_RELAY_URL` / `_CENTRAL_URL`, `FLEET_HUB_URL`, `FLEET_CRED_RELAY_TOKEN`, `FLEET_PROBE_FORCE_UNREACHABLE`, `FLEET_CRED_ALLOW_HOSTS` | root's `<LIB>/<login>.conf` ONLY (`/Library/Application Support/claude-fleet/credsep/<login>.conf`, Linux `/usr/local/lib/claude-fleet/credsep/`; root, 0600 — a relay pass may be in it) |

The same key in a login file with a different value is **ignored**: one stderr
line in the proxy's launch log (`ignored <KEY> from <file>`) and the key names
(never a value) in `<run>/ignored.<login>`, which `credsep check` turns into a
WARN. A file there that is not root's alone is not read.

`install` writes root's file the first time (a shared tenant's: `machine
refresh` / `machine install`), taking the login's current values — an upstream
or hub URL only when it is https to an allowed host; `FLEET_CRED_ALLOW_HOSTS`
never (root edits the file by hand). After that the file is kept as it is: a
later change in the login's files does nothing until root takes it with
`sudo bash …/fleet-credsep.sh install --adopt` (same validation; restarts the
proxy that reads it).

The proxy checks once more in separated mode: every upstream — the four URLs
and the hub the node token goes to — must be https to `api.anthropic.com`,
`chatgpt.com`, `api.openai.com`, `auth.openai.com`, `fleet-relay.24hw.cn`,
`ccquota.24haowan.com` or `claudefleet.24haowan.com` (+ root's
`FLEET_CRED_ALLOW_HOSTS`, space- or comma-separated); plain http on loopback only
in the selftest's sandbox (`FLEET_CREDSEP_TEST=1`). A login's own unseparated
proxy (its own credentials) keeps the old rule: any https host. BREAK-IT row
`cred-upstream-tenant-override`.

## What it does not stop

- **Root.** A login with password-less sudo can `sudo cat` anything; the
  doctor row notes it. The boundary is against the session's tools running as
  the login, not against the login's own root.
- **Debugging the agent.** The agent still holds the node token in memory as
  the login. On macOS a same-user debugger attach needs the `_developer` group /
  DevToolsSecurity; on Linux, `ptrace_scope`. Not this issue's.
- **Untrusted machines** never get a credential in the first place (C1) — this
  is about trusted ones.

## Files

`bin/fleet-credsep.sh` (front) · `bin/fleet-credsep.py` (install / uninstall /
status / check) · `bin/fleet-credsep-launch.py` (root launcher: `proxy` |
`agent`) · `bin/fleet-cred-proxy.py` (separated mode: `store`, `probe`,
`node-token`, `node-hash`, `/hub/` broker, peer-uid gate) ·
`tokenledger/internal/agent/node_credstore.go` (the agent's `store` client) ·
`bin/fleet-credsep-selftest.sh` · `bin/fleet-cred-shared-selftest.sh` (the
machine's shared proxy, `machine install|uninstall|refresh|status`,
`fleet-credsep-launch.py shared`, `fleet-cred-proxy.py serve --shared`).
