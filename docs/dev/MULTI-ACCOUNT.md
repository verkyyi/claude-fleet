# Subscriptions — the pool picks, behind the credential proxy

A fleet session does not choose its subscription. With the credential proxy on
(`FLEET_CRED_PROXY=1`), every session opens with a session credential from this
login's proxy and the **pool** — the hub's subscriptions, leased per request —
picks which subscription each request runs on. With no pool, the session runs on
the login's own login, exactly as a bare `claude` would. That is the whole
design; this page says where its parts are.

The old local design — token files rotated by a collector, limit banners
benching an account, a per-minute quota watch, pace / phase ranking, failover
moves and the sidebar's 「换账号…」 — is gone (EPIC T542: C1 – C8). Its history
is in git (`git log -- docs/dev/MULTI-ACCOUNT.md`).

## How a session gets its subscription

`fleet-session-wrap.sh` → `fleet-claude.sh` / `fleet-codex.sh` mints one session
credential per launch (`bin/fleet-session-cred.sh`) and revokes it at exit:

- **Claude** sees `ANTHROPIC_BASE_URL=http://127.0.0.1:<port>` and an `fcp1.`
  token; **Codex** a `fleet` custom provider and a `CODEX_HOME` with no
  `auth.json` (T560: a Codex launch pins no local profile either).
- The window carries `@cred_sid` and `@cred_route` (direct · relay · central).
- The proxy picks and meters per request; a full subscription is the pool's to
  change, so the session keeps running where it is. The proxy's log line names
  the account (`acct`).
- The proxy hands each session's last rate-limit reading to the window
  (`bin/fleet-proxy-quota.sh` → `conf/statusline.sh --from proxy`), so 剩余 % on
  the client's top line is that session's own subscription.

Where the credentials live and how a session is kept away from them:
[CRED-SEPARATE.md](CRED-SEPARATE.md); the relay and central routes:
[CRED-RELAY.md](CRED-RELAY.md); the pool on the hub:
[FLEET-HUB.md](FLEET-HUB.md).

## Adding a subscription

```sh
fleet account add --provider claude --label work     # or --provider codex
```

`bin/fleet-account-add.sh` signs the subscription in (`claude setup-token` /
`codex login`) into a private temp dir, imports it into the hub
(`fleet-creds-import.sh`) and deletes the local copy. The hub holds it from
there; a node that leases it gets its own short-lived copy. It needs the hub's
URL and the operator's viewer token.

The `accounts/` directory (`~/.config/claude-fleet/accounts/<label>`, a token or
the `hub:<label>` marker per file) keeps its format: the proxy
(`fleet-cred-proxy.py`), `fleet-credsep.py` and the hub's node credentials read
it. Nothing in the fleet rotates over it any more.

## Which subscription is this session on?

```sh
~/.claude/fleet/bin/fleet-account.sh whoami          # the pane you run it in
~/.claude/fleet/bin/fleet-account.sh whoami @12      # one window
```

Through the proxy the truth is the proxy log's `acct` for that `@cred_sid`.

## Per-model caps

`You've hit your Fable 5 limit` caps one model on one subscription, not the
subscription. The state-reconcile tick (`bin/fleet-reconcile-tick.sh`, phase
`modelcap`) runs `bin/fleet-model-switch.sh --capped`, which types `/model
<FLEET_MODEL_FALLBACK>` (default `opus`) at the walled session's own prompt and
verifies the flip off the window's `@model`; a window mid-turn waits for the
next tick, and an unverifiable flip falls back to
`fleet-migrate.sh --model <m> <window>` (close + `--resume`). The doctor's
`modelcap` row reports a sweep that keeps timing out.

```sh
bin/fleet-model-switch.sh --capped --dry-run       # what a sweep would do
bin/fleet-model-switch.sh --model opus @37         # one window, by hand
```

## Moving a live session by hand

`fleet-migrate.sh <window>` (also `fleet-account.sh migrate …`) moves a running
session: through the proxy a direct / relay Claude window is **rebound in
place** — the pane, its tools and `/loop` stay, the next request runs on the new
pick; a Codex window, a `--model` / `--cfg-stale` move and a central window take
the close + `--resume` road. `--force-bg` stops background commands and names
them in the resume nudge (#873). Moves by quota (`--limited` / `--idle` /
`--all` / `--stuck`) answer 「已不用」. Details: [SESSION-TRANSFER.md](SESSION-TRANSFER.md).

## Remote-start quota gate

Separate from all of the above and off by default: `FLEET_QUOTA_GATE=1`
(`bin/fleet-quotaguard.sh`) stops a start or resume the hub sends while the
selected subscription is past `FLEET_QUOTA_CEILING` (90). Missing ccquota or an
unreadable limit leaves the gate open.

## Security & terms

Which subscriptions go in the pool, and which logins share it, is the
operator's decision; the tooling neither checks nor enforces who holds them.
Tokens never enter the repo, a config, a commit or a pane's environment — the
session sees only its `fcp1.` credential.

## Troubleshooting

| Symptom | Check |
|---|---|
| A session runs on the login's own login, not the pool | Is the proxy on (`FLEET_CRED_PROXY=1`, the doctor's `credproxy` / `credsep` rows)? Does the window carry `@cred_sid`? A session opened before it was on keeps its start — reopen it. |
| A session hit its subscription's limit | Nothing to do on the machine: the pool changes the subscription on the next request. If every subscription is full, the session waits like a single-account one. |
| A model cap does not flip | `fleet-model-switch.sh --capped --dry-run`; the doctor's `modelcap` row. An empty `FLEET_MODEL_FALLBACK` turns the switch off. |
| `fleet-account.sh quota` / `use` / `rotate` / `active` answer 「已不用」 | Retired with the local pick; the pool reads quota itself and each session's own 剩余 % is on its window. |
