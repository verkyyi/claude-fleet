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
`bin/fleet-credsep-selftest.sh`.
