# Separated credentials — 可信机器上，凭据放在会话碰不到的地方

Issue #1971 · EPIC #1967 C4. **Not opt-in** (issue #4607) and **no way out**
(issue #4675): every login is separated — every one there is, and every one opened
from now on, a self-hosted one-person box too (it has its one machine proxy, like
any). A subscription credential is held only by the machine's proxy and the hub's
central proxy; nothing writes one into a home. `FLEET_CREDSEP_OPTIONAL`,
`FLEET_CRED_SEPARATE=0`, `CCQUOTA_FLEET_CREDSEP_OPTIONAL`, root's `credsep.optional`,
`fleet-login-new.sh --no-credsep` and `fleet-credsep.sh uninstall` are gone (the
daemon says so once; `FLEET_CRED_SEPARATE=1` stays a mark the install
pass converges on).

## Every login, by the machine itself (issue #4607)

Separation used to wait for a person to type one sudo per login, so on
2026-10-17 four fleet logins on two machines had never been separated — the node
program had written the pool's real Claude `.credentials.json`, Codex `auth.json`
(refresh token included) and `node.env`'s node token into their homes. Four
rails now:

1. **A new login is separated before its first session** — `fleet-login-new.sh`
   7b (below); there is no `--no-credsep` (#4675: an unknown option, exit 2).
   `account adopt` separates the login it takes over
   at once (`machine enforce --logins <it>`), not at the next tick.
2. **An existing one is taken in by root's daemon** — the node supervisor's
   `credsep-enforce` task (every 5 minutes, `FLEET_CREDSEP_ENFORCE_EVERY`) runs
   `fleet-credsep.py machine enforce`: every human fleet login here (a login shell,
   a home under `/Users` · `/home`, a person's uid, and a fleet install / conf dir
   in it, a node token the daemon holds for it, or taken over by it — a CI runner
   or a plain account is none of these and is left alone) that is not separated
   becomes a tenant of the shared proxy (`machine install --logins <it>`); one on
   its own proxy joins. A login with nothing running as it, or nothing a session
   reads to move (no lease, no `node.env`, no proxy key), skips the preflight. A
   missing `~/.config/claude-fleet` is made 0700 as the login's, a missing
   `fleet.conf` written with `FLEET_CRED_PROXY=1` + `FLEET_CRED_SEPARATE=1`.
   Each attempt is one JSON line of `/var/log/fleet-cred/enforce.log` (the audit);
   the verdicts are `/var/db/fleet-node/credsep-enforce.json` (0644, no secret).
   A preflight refusal (live sessions still reading the files) is tried again each
   tick and, past `FLEET_CREDSEP_ENFORCE_GRACE` (24 h — the hub has been refusing
   the login every lease meanwhile), with `--force`; a failed install rolls itself
   back and is tried again after `FLEET_CREDSEP_ENFORCE_RETRY` (1 h). There is no
   way out (#4675): root's old `/var/db/fleet-node/credsep.optional` is said and
   ignored.
3. **The hub leases an unseparated login nothing** — every login, an admin's and
   the operator's own included (below, «The hub's backstop»).
4. **It is red until it holds** — the login's `credsep` row is FAIL for a node
   login not separated (a login with no `node.env` is leased nothing: no row); the
   machine's `credsep-logins` row (`fleet-credsep.sh machine enforced`, anyone)
   FAILs naming every one with the daemon's last word; the hub's `cred-ttl` gate item counts every
   login that leases, not only managed ones.

BREAK-IT rows `cred-new-login-unseparated`, `cred-existing-unseparated`,
`cred-enforce-fails-no-lease`.

## What it does

On a trusted machine the node agent leases the team's subscription credentials
and writes them where Claude Code / Codex re-read them — files the login owns.
Every session of that login (the model, its tools, a plugin) can read them, and
`node.env` with them: the node token that leases the whole pool again.

Separated, a **role account** owns all of it:

| | unseparated (before #4607) | separated (`1`) |
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

## Turning it on (there is no off — issue #4675)

```sh
# a managed machine: nothing to type — the daemon's credsep-enforce does it
sudo bash ~/.claude/fleet/bin/fleet-credsep.sh machine enforce --dry-run   # what it would do
bash ~/.claude/fleet/bin/fleet-credsep.sh machine enforced                 # the doctor's credsep-logins row
# elsewhere (a self-hosted box too) — the doctor is red until it is done; the next
# sync does it (install pass `credsep`, password-less sudo) — or by hand:
bash ~/.claude/fleet/bin/fleet-credsep.sh install     # needs password-less sudo ONCE
bash ~/.claude/fleet/bin/fleet-credsep.sh status
bash ~/.claude/fleet/bin/fleet-credsep.sh check       # the doctor's `credsep` row
```

`check` exits **1** only when the login is not separated — no store, or the
store / a credential / node.env readable by it — which the heartbeat reports as
`credsep=not` and the hub answers by leasing nothing. A separated login whose row
warns for any other reason (the proxy ignored a line of the login's own
`fleet.conf`, root's settings not written yet, the proxy not running, …) exits
**4** and stays `separated` (issue #4623: on 2026-10-17 such a warning cut a
separated login off every credential). When the proxy has no road it says why:
the deny line and the 403 carry its trust word and reason.

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
   store's file; a session names the label. A failed fresh install deletes them;
   nothing ever puts a pool token at the login's path (#4675); `check` WARNs if a
   pool label's file holds a token again.
3. the verdict, read **as the login** with its own clone: `status` not `separated`
   fails the open (exit 1 — the login must not be handed out); then `check` (waited
   for up to `FLEET_LOGIN_CREDSEP_WAIT`, 15 s, while the proxy starts). The run's
   LAST line is the one the hub reads: `credsep: separated` · `credsep: pending — <why>`.

From then on the login never needs sudo.

### The hub's backstop: no token to a user's login that is not separated (issue #2295, EPIC #2293 C2)

Should step 7b not have happened — an old script, a by-hand override, a login put
back — the hub still holds the line. Since #4607 it holds it for **every** login —
an admin's and the operator's own too — and since #4675 no hub may declare
otherwise (`CCQUOTA_FLEET_CREDSEP_OPTIONAL` is gone). Every heartbeat carries `credsep`
(`separated` · `not` · `unknown`), the agent's reading of `fleet-credsep.sh status`
**and** `check` (exit 0 both ⇒ `separated`; asked at most every 5 minutes).
`/v1/node/credentials` issues real tokens only while that word is `separated`; otherwise it answers 403 `not_separated` and the
credential audit records 「拒发：未隔离」. An agent too old to send the field counts
as not separated. `/v1/node/self` then carries `credsep_gate: not_separated`, and the
login's proxy reads it as an untrusted machine: every session goes **central**
(the hub's proxy, no credential file read) — slower, but it works, and nothing ever
lands in `accounts/*.hub/`. And should a lease reach an agent with no credential
store at all, it writes no Claude / Codex credential anywhere — `no_store` in its
log (#4675; #4643 was such an agent, writing into a separated home for a week).

### Rolling it out on a machine (issue #2135, EPIC #2133 C5)

One login at a time, the operator types the only `sudo`; nothing else needs root.

```sh
bash ~/.claude/fleet/bin/fleet-credsep.sh plan                 # every login here: state + its commands
bash ~/.claude/fleet/bin/fleet-credsep.sh install --dry-run    # no sudo: every move it would make
sudo bash ~/.claude/fleet/bin/fleet-credsep.sh install         # THE sudo (the login is SUDO_USER's)
bash ~/.claude/fleet/bin/fleet-credsep.sh status               # separated · /var/db/fleet-cred/<login> · …
bash ~/.claude/fleet/bin/fleet-credsep.sh check                # credsep: OK — … Permission denied …
```

Then, in a real session of that login (its Bash tool),
`python3 -I ~/.claude/fleet/bin/fleet-cred-scan.py scan` tries ①②④ and prints
counts only: ① `readable=0`, ② `readable=0`, ④ `readable=0` (or the hub refuses).

- Under `sudo`, `id` says root: the script takes the login from `SUDO_USER` (or
  `--login <login>`, which is how `plan` spells another login's line) and that
  login's own conf dir. Root with neither is refused — before #2135 the hint
  separated a `root` store and left the login's agent unable to read `node.env`
  (BREAK-IT `cred-sep-sudo-root`).
- The dry run runs as the login.
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

Nothing reverses it (issue #4675): `fleet-credsep.sh uninstall` and `machine
uninstall` exit 2, and `FLEET_CRED_SEPARATE=0` does nothing. Only an install that
fails halfway puts back what it moved (its own rollback, #2273). A login that goes
away is `fleet-login-remove.sh` — its store is deleted, nothing moved back (`purge`).

## One proxy for the whole machine (issue #2217)

On a **managed node** (mac-a mac-d, mac-b mac-c) the per-login wiring above meant one
LaunchDaemon and one sudo per login, credentials separated login by login, and
every login on its own proxy version. Every machine now runs **one** shared
proxy (issue #4674: no login runs a proxy of its own — not the separated
`com.claude-fleet.credsep.<login>`, not the unseparated `com.claude-fleet.cred-proxy`;
a person's pod runs the same `serve --shared` as its login). Only a client-only
computer starts `fleet run`'s central proxy on demand.

```sh
fleet cred-proxy status  --machine        # shared · _fleetcred · on k/N logins · sessions a/b
fleet cred-proxy enable  --machine        # every login with ~/.claude/fleet (or --logins a,b)
# (no disable: issue #4675 — credentials never go back into a home)
```

`enable --machine` is `fleet-credsep.sh machine install`: ONE sudo for the whole
machine (with password-less sudo it runs; otherwise it prints the line an admin
types). For each login it does what `install` above does — the store, the
credentials and `node.env` moved, the agent through the launcher — and then:

| | per login (today) | shared (`machine install`) |
|---|---|---|
| proxy process | one per login (its own or `com.claude-fleet.credsep.<login>`) | ONE, `com.claude-fleet.cred-proxy-shared` / `claude-fleet-cred-proxy-shared.service`, as `_fleetcred` — on a managed machine the node daemon's child `cred-proxy-shared` instead (its sweep retires the definition, issue #2981) |
| port | one per login | one fixed `127.0.0.1:18923` (`FLEET_CRED_SHARED_PORT`) — plus each login's OLD port, answering that login only |
| control socket | per login | `/var/run/fleet-cred/.shared/ctl.sock` (0666): the kernel's peer uid (`getpeereid` / `SO_PEERCRED`) names the login |
| the login's proxy state (signing key, held passes, relay pass) | `~/.config/claude-fleet/cred-proxy/` | MOVED to `/var/db/fleet-cred/<login>/cred-proxy/` (binds / revocations / live sessions / trust copied) |
| the leased credentials (Claude `.credentials.json`, Codex `auth.json`) | in the login's store | ONE copy for the machine, `/var/db/fleet-cred/.shared/pool/<kind>/<hash of the access token>/`; the login's store keeps only its index, `cred-proxy/pool.json` (issue #2311) |
| `FLEET_CRED_PROXY` | as the login set it | `1` (the line it had is remembered; nothing puts it back since #4675) |
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
an own copy left after that (`accounts/<label>.hub` beside the pool's — what a
join's `pool_hold` left before T600 took the hold out, issue #2849) moves in at
the tenant's next lease or the first read of that label, so a label resolves to
the pool's copy only; `fleet-credsep.py machine pooldup` (root; the machine
doctor's `credpool` row) WARNs on a token held twice, by `<login>:<label>` and
fingerprint, never the token; a file no index names any more is removed. Nothing
puts a tenant's copies back as its own files (issue #4675). A session credential minted on the shared proxy carries its
login (`lg`) and is verified with **that** login's key, so a credential relabelled
to another login only fails the signature. A hub pass (the central route) is
filed under the login whose session registered it (`fleet-cred-proxy.sh pass`,
done by `fleet-session-cred.sh`). The control socket answers a login's uid with
its own tenant and nothing else; root names one (`FLEET_CRED_AS`).

**The old port is gone.** The signing key moves with the login; the login's own
proxy and its port went with #4674, and since T600 the shared proxy no longer
answers that port either — every session's base URL is the shared port (checked
on every machine before the removal), and a credential minted on a login's own
proxy (no `lg`) is refused there. Nothing reverses it (`disable --machine` is
gone, issue #4675).

A login on the shared proxy ignores its own `FLEET_CRED_SEPARATE` (a mark, no
switch): `fleet-credsep.sh apply` says `shared`. The shared proxy dying is BREAK-IT `cred-shared-down`.
`bin/fleet-cred-shared-selftest.sh` runs two logins through one proxy in a
sandbox.

### A login once separated on its own proxy (issue #2432)

Before the machine had the shared proxy a login could run its own one; `machine
join` moved those over with no gap. None is left (issue #4790 checked every
login on both machines), so `join`, the launcher's `proxy` mode and the node
daemon's join sweep are gone: a store that is no tenant of the shared proxy is
what `machine install --logins <it>` is for.

## A step fails halfway (issue #2273)

Before it moves anything, `install` / `machine install` checks each login it
is about to take from nothing, as that login: `fleet cred-proxy status` must be
`on`, its route not `down`, and `sessions n/n` — every live session already on
the proxy — and no fresh EPIC batch mark (`fleet_epic_running_fresh`). Any miss
is listed, nothing moves, exit 6; `--force` goes on anyway. (Password-less sudo
on an admin login is meant for the agent — #2197; mac-a broke on the ORDER: the
files moved before the proxy was on.)

`install` and `machine install` are all-or-nothing for a login that had
nothing in the store: when a step fails — on 2026-10-07 mac-a's agent bootstrap
came 4 ms after `bootout` while the old agent was still exiting, and launchd
refused it (`37: Operation already in progress`, printed `Bootstrap failed: 5`)
— every such login is put back from the store's `meta.json` (credentials,
node.env, fleet.conf, the agent's definition, the proxy's key) and the
command exits 1. `load_daemon` now waits for `bootout` to finish and retries
the bootstrap (`FLEET_CREDSEP_BOOT_TRIES`, 3). If a step of the way back fails
too, the exit is 5, the store is kept as `<login>.rolledback-<UTC>`, and the
steps to finish by hand are printed (`uninstall` is gone, issue #4675: this
rollback is the only way a credential leaves the store). BREAK-IT rows `cred-sep-by-agent`,
`cred-sep-bootstrap-fails`.

## Writing node.env once it is separated (issue #2316)

Separated, `~/.config/claude-fleet/node.env` is a link the login cannot read.
Everything that writes it — `fleet node join` / `fleet host on` (the token the
hub hands back), `fleet node compute on|off` / `fleet host off` — goes through
`bin/fleet-credsep.sh setenv`: `KEY=VALUE` lines on stdin (the token never on an
argv; `KEY=` drops a line; only the node's own `CCQUOTA_*` keys), root edits the
store's copy in place (owner and mode kept), `node.pub.env` follows, the link
stays, and an agent already started through the launcher is restarted (it read
node.env at its start). A join on a separated login with no agent yet writes the
agent's definition without starting it and runs `credsep install`, which starts
it through the launcher. Readers fall back to `node.pub.env`.

It needs root once per write: as the login through password-less sudo. A login
without it is refused BEFORE a join code is spent or a probe runs (`setenv
--check`, exit 4) — an admin gives it sudo, or for a compute switch runs the
printed `printf 'KEY=value\n' | sudo bash …/fleet-credsep.sh setenv --login <X>`.
BREAK-IT rows `cred-sep-rejoin-plain`, `cred-sep-compute-unlinks`.

**A plain node.env back in the home** (issue #2649): a writer from before #2316
(mac-c's `fleet host on --shared` on 2026-10-08) replaced the link with a plain
file. The agent then takes its token from the store (read at its start) but its
compute / personal switches live from that plain file, the store's copy is the
older one, and every later `setenv` refuses the home (exit 5, `--check` too —
before a probe or a join code). The doctor's `credsep` row says so and prints the
fix, root once:

    sudo bash ~/.claude/fleet/bin/fleet-credsep-reconcile.sh --login <X> [--prefer home|store] [--dry-run]

It folds the home copy into the store (a key both have takes the NEWER copy's
value, `--prefer` overrides; a key only one has is kept), sets the plain file
aside in the store's `backup/node.env.home-<UTC>`, puts the link back, rewrites
`node.pub.env` and restarts the agent through the launcher. On a managed machine
an adopted login's `/var/db/fleet-node/logins/<X>.env` takes the same `CCQUOTA_`
lines (the node daemon reloads it); a login not adopted there is only named —
writing one would start a second agent on the same token. No value is printed;
a rerun is a no-op. BREAK-IT row `cred-sep-plain-node-env`.

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
`chatgpt.com`, `api.openai.com`, `auth.openai.com`, `relay.example.com`,
`ccquota.example.com` or `hub.example.com` (+ root's
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

`bin/fleet-credsep.sh` (front) · `bin/fleet-credsep.py` (install / status /
check) · `bin/fleet-credsep-launch.py` (root launcher: `proxy` |
`agent`) · `bin/fleet-cred-proxy.py` (separated mode: `store`, `probe`,
`node-token`, `node-hash`, `/hub/` broker, peer-uid gate) ·
`tokenledger/agent/node_credstore.go` (the agent's `store` client) ·
`bin/fleet-credsep-selftest.sh` · `bin/fleet-cred-shared-selftest.sh` (the
machine's shared proxy, `machine install|refresh|join|status`,
`fleet-credsep-launch.py shared`, `fleet-cred-proxy.py serve --shared`).

### Codex 会话重开后的续接

重开同一个 Worker 会产生新的代理凭据 SID。代理通过请求里的历史引用，
在同一租户、同一 Worker 的已记录响应中找回原订阅；撤销旧凭据不会删除这份历史归属。
只有精确记录且来源一致的引用能跨 SID 接续，不继承旧 SID 的引用淘汰兜底。
未知引用、来源冲突、订阅不再授权或来源身份变化仍会拒绝。已有的卡住会话在代理更新后
可在原会话重试，无须更换订阅或清空历史。

共享代理重启交接时，旧进程还在把最后几个回答的引用记进 `codex-routing.json`，
新进程不会再把它们盖掉：保存在文件锁下进行，文件被别的进程写过（inode / mtime / size 变了）
才重读并合并，引用取并集、来源不一记为冲突；选路前也先合并。另外，一个从没换过订阅、
来源身份没变、记下的引用都只指向那一个来源、也没被别的路由答过的会话，请求里查不到的引用
按它唯一的来源接续（`sole_origin_unseen_ref`），仍在上游前核验订阅身份；换过订阅、来源变过、
有冲突或请求带无法解析的字段时照旧 409。每个 Codex 409 都在代理日志里记一行 `ev=deny`
（sid 与原因，不含引用值）。
