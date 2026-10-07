# TokenLedger

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/img/badge-dark.svg">
  <img alt="tokens counted by this hub" src="docs/img/badge-light.svg">
</picture>

**Books for a team account pool.** A small team buys N Claude subscriptions
centrally and schedules its work against whichever of them still has headroom.
That is markedly cheaper per unit of quota than buying a seat per person — and
it leaves the team with no reporting at all, because every first-party number is
scoped either to one machine or to one seat.

TokenLedger is the missing ledger. One hub that knows how much headroom each
subscription has left, where the spend went (machine, OS login, project, team),
what the subscriptions actually cost in real money, and a gate a scheduler can
branch on before it starts more work.

One Go binary: an agent on every endpoint, a hub with a dashboard and an API,
and a read-only MCP server so any Claude session can ask. Usage covers **Codex**
alongside Claude Code, with a source dimension for comparing or filtering them;
both support subscription-limit monitoring when a usable local login is present.

![what it cost, and every model that ran](docs/img/dashboard.png)

<sub>The headline is the subscriptions — what bills monthly whether or not a
token is spent; the API-equivalent token cost is never added to it.
Screenshots on this page come from a throwaway hub with invented data —
<code>docs/img/seed-demo.sh</code> stands that hub up again so the pictures can be
re-shot when the UI moves. Endpoint ids and dates differ every run, so it
reproduces the <em>state</em>, not the bytes.</sub>

```
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│ linux server │  │ windows box  │  │ your laptop  │
│ ccquota agent│  │ ccquota agent│  │ ccquota agent│
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       └──────── HTTPS ──┼──────────────────┘
                         ▼
                ┌──────────────────┐
                │   ccquota hub    │  SQLite
                │  dashboard · API │
                │  MCP at /mcp     │
                └──────────────────┘
```

## Why a pool rather than seats

At list price, pooled capacity is **2.5× the quota per dollar** — and unlike a
seat allowance it can go to whoever needs it that week:

| monthly plan | cost / mo | total quota (× Pro) | quota per $ | poolable |
|---|---:|---:|---:|:--:|
| 5 × Team Standard seats | $125 | ~5× | 0.040 | ✗ each seat capped on its own |
| 5 × Team Premium seats | $625 | ~25× | 0.040 | ✗ each seat capped on its own |
| **2 × Max 20× pooled** | **$400** | **40×** | **0.100** | ✓ the whole pool draws on it |

$400 of pooled Max buys 40×; $625 of Premium seats buys 25×, and that 25× cannot
be lent between people. The gap is *before* idle capacity: on Teams and
Enterprise, [each member's usage draws from a per-seat
allowance](https://code.claude.com/docs/en/costs#claude-for-teams-and-enterprise),
so the quota of anyone on holiday is quota nobody can spend, while a pool
re-absorbs it.

> Prices from [claude.com/pricing](https://claude.com/pricing), monthly billing,
> **snapshot 2026-09-13**. Quota multipliers are approximate and relative to Pro.
> Both drift — re-check before quoting them.

## What the first party cannot show you

Anthropic tells you *how much* of the plan is left — that figure is
account-wide and exact. What no first-party surface tells you is *where it
went*: the breakdown is scoped to the machine it was computed on, by
construction. From [Anthropic's own
documentation](https://code.claude.com/docs/en/costs):

> `/usage` — "The figures are approximate and computed from local session
> history on this machine, so usage from other devices or claude.ai is not
> included."
>
> `/insights` — "Sessions from other devices and claude.ai aren't included."

Per-user reporting does exist — but only where billing is already per user:
Teams and Enterprise (the spend-report CSV, the Enterprise Analytics API) and
the Console (the API dashboard). A team on pooled subscriptions is in neither
bucket, so **no first-party surface merges several machines onto one set of
books.**

That is not a feature someone forgot to ship. Attribution follows billing, and a
pooled subscription is not billed per person, so the merged cross-machine view
stays missing for structural reasons rather than temporary ones. It is the one
thing here worth building on.

## Who this is for

**A 3–8 person team that buys its subscriptions centrally and pools them.** The
subscriptions belong to the team rather than to individuals, and the questions
that matter are *how much headroom is left*, *which project ate the week*, and
*whose budget does this machine's spend belong to*.

It is **not** for:

- **One person on one machine.** There is nothing to merge;
  [ccusage](https://github.com/ccusage/ccusage) is a smaller tool and does that
  job well.
- **A company on Team or Enterprise seats.** There the first party already gives
  you per-user spend and admin spend limits, and what is left here shrinks to
  the Codex column and the cross-tool view. (Read the table above before
  concluding that seats are the cheaper purchase.)

**It is also not a scoreboard** — a constraint in the design, not a promise in
the README. A pool's ledger can name people, so this one is careful where it
does: teams are assigned on the hub and are never self-reported by a machine,
and the per-person view is an unnumbered filter you reach by URL, never
something the dashboard ranks or leads with. Read as a per-person performance
ranking, an internal usage board fails by Goodhart — people avoid the tool or
pad their usage — and either outcome destroys the cost data it exists to
produce. [Teams](#teams) has the mechanics.

## Why not one of the existing tools

| | multi-endpoint | dashboard | MCP |
|---|---|---|---|
| [ccusage](https://github.com/ccusage/ccusage) | ✗ | ✗ | ✓ |
| [Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor) | ✗ | ✗ | ✗ |
| [phuryn/claude-usage](https://github.com/phuryn/claude-usage) | ✗ | ✓ | ✗ |
| **TokenLedger** | ✓ | ✓ | ✓ |

They are good tools; none of them answers "which of my six servers ate my
week", and Anthropic [closed the request for it as not planned](https://github.com/anthropics/claude-code/issues/15434).

## Install

Download a binary from Releases, or:

```bash
go install github.com/verkyyi/claude-fleet/tokenledger/cmd/ccquota@latest   # needs Go 1.25+
```

> TokenLedger now lives in the [claude-fleet](https://github.com/verkyyi/claude-fleet)
> monorepo, under `tokenledger/` (claude-fleet issue #1391), with its full
> history. The old `go install github.com/verkyyi/ccquota/...` /
> `github.com/verkyyi/tokenledger` paths are retired; the command is still
> `ccquota` and every `CCQUOTA_*` variable is unchanged.

**The product is TokenLedger; the binary is `ccquota`.** The rename is cosmetic
so far — the command, the default database path and every `CCQUOTA_*`
environment variable still read `ccquota`, and this release changes none of
them. (Only the Go module path moved, with the code, to
`github.com/verkyyi/claude-fleet/tokenledger`.) Renaming the identifiers is a separate cutover across two repos,
and it has not been done. So wherever this README says TokenLedger, what you
type is `ccquota`.

No runtime, no database to provision, no Node. `CGO_ENABLED=0` cross-compiles to
linux/amd64, linux/arm64, darwin, and windows.

> **Windows is best-effort and unverified.** It cross-compiles and the tests are
> platform-independent, but the agent has never been run on a real Windows
> machine — path handling around Claude Code's transcript directory and the
> scheduled-task installer are the likely rough edges. Reports welcome.

## Run it

**On the hub** (a VPS, a NAS, a spare Mac):

```bash
export CCQUOTA_VIEWER_TOKEN=$(openssl rand -hex 24)
ccquota hub --addr 127.0.0.1:8787 --db /var/lib/ccquota/ccquota.db
```

Put TLS in front of it, or bind it to a tailnet. The hub refuses to serve a
public address with no token unless you pass `--insecure-public`.

The database defaults to `~/.ccquota/ccquota.db`, or `$CCQUOTA_DB`. If you point
`--db` somewhere else, set `CCQUOTA_DB` to the same path for the shell you run
`enroll` and `name` from — they act on that same file.

**Postgres instead of the file** (claude-fleet#2120): set `CCQUOTA_DB_URL` to a
`postgres://user:pass@host:5432/db?sslmode=require` connection string and the
hub (and every `ccquota` command run with the same environment) uses that
database; `--db` / `CCQUOTA_DB` are then not read. Unset — the default — it is
the SQLite file above, exactly as before. The tables are created on first open,
in the connection's current schema; text compares byte for byte (`COLLATE "C"`)
whatever locale the database was created with.

**Moving an existing file across** (claude-fleet#2122): `ccquota db migrate
--from <file> --to <url> [--dry-run] [--verify]` copies every table in one
Postgres transaction (killed half way = nothing written; `--dry-run` rolls it
back after the copy and the verify), aligns the id sequences, and with
`--verify` compares each table's row count and a hash of its rows in key order;
`ccquota db verify` runs the comparison on its own. `--to` defaults to
`CCQUOTA_DB_URL`. `CCQUOTA_READONLY=1` holds the hub still meanwhile: writes
answer `503` + `Retry-After`, reads work. The cut-over and the way back are in
deploy/k8s/RUNBOOK.md.

**Two hub replicas — 两份入口** (claude-fleet#2124): with the fleet module on, a
node's control channel ends in whichever replica the load balancer handed it
to, and only that process can write down it. Give each replica
`CCQUOTA_REPLICA` (its own name — the pod name), `CCQUOTA_REPLICA_URL` (where
the OTHER replicas reach it in-cluster, e.g. `http://$(POD_IP):8787`) and
`CCQUOTA_REPLICA_TOKEN` / `CCQUOTA_REPLICA_TOKEN_FILE` (one secret all replicas
share, from a k8s Secret — never the database); all three or none, a half set
refuses to start. Each replica then records the links it holds in
`fleet_node_conns` and hands a call for a node it does not hold to the one that
does, over `POST /internal/v1/node-write` (never route it through the public
ingress). Unset — the default — the hub is a single process exactly as before:
no table, no route, nothing forwarded.

What each replica keeps in its own memory, and why that is acceptable:

| State | Where | With two replicas |
|---|---|---|
| node links (`nodes`), replies in flight (`pending`) | `nodes.go` | the reason for `fleet_node_conns`: a call for another replica's link is forwarded — session start/resume/move, live reads, relays, the SSH CA, a relayed token refresh; the roster, placement and `move plan` count those links as connected |
| beat-driven pushes: worker map, team version, queued account ops, waiting relays | `pushWorkers` / `pushTeam` / `dispatchAccounts` / `dispatchRelays` | run by the holder on the node's next beat (≤ one heartbeat late); a relay accepted elsewhere also kicks the holder at once |
| SSH relays (`sshRelays`) | `ssh_relay.go`, `ssh_relay_replica.go` | a byte stream on the link — not forwardable per call, so a replica that holds no link able to relay to the machine reverse-proxies the client's whole websocket to the one that does (claude-fleet#2151), and an agent's data half that lands on the wrong replica is proxied to its link's holder the same way; the holder checks, audits and caps it as its own. The connect page counts the other replica's `ssh_relay` links as relayable |
| starts just sent (`recent`, #2077) | `fleet_recent.go` | each replica counts its own: a burst split across both is spread a little less well until the beats show it (≤ 90 s); never a lost write |
| session-pass verify cache (`sessCred`) | `fleet_session_cred.go` | ≤ 30 s: a revocation made through the other replica is seen within the TTL (one made here at once) |
| load history (`loadHist`) | `nodes.go` | each replica charts the beats it receives; display only, empty after a restart anyway |
| SSH CA answers (`sshCAStatus`) | `fleet_certs.go` | the holder's; the other replica's roster leaves it blank |
| device logins in progress (`devices`), client leases and their queued actions (`clientLeases`) | `fleet_certs.go`, `fleet_client*.go`, `replica_state.go` | kept by ONE replica, the state holder — the one up the longest in `fleet_replicas` (each replica beats its row every 5 s). A `fleet login` start / poll / QR confirmation, a client's lease, actions and place that land on the other replica are reverse-proxied there whole, and `ClientLeaseOf` asks it over `/internal/v1/client-lease` (claude-fleet#2190). Nothing credential-shaped enters the database. A holder silent for 15 s hands over with an empty table — what a restart always cost: a login in progress is scanned again, a live client re-adopts its lease on its next renewal |
| live sessions (`LiveStore`) | `live.go`, `replica_state.go` | every replica holds the whole picture: a report is applied where it lands and handed to the other replicas up (`/internal/v1/live-report`), so `/v1/live`, its stream and `/mcp` read every session on either (claude-fleet#2190) |
| the hero counter's cache (`counter`) | `counter.go` | each replica's own: an ingest invalidates only the replica that took it, the other recomputes within 30 s (`counterTTL`); display only |
| a revoked node token | `fleet_node_revoke.go` | the holder closes the link at the node's next message (every message re-checks the token) |

**Two hubs on one Postgres** (claude-fleet#2123): each background loop — the
daily prune, node alerts, the SPOT controller — runs only on the replica holding
its Postgres advisory lock (`internal/leader`); the lock goes with that
replica's connection, and the other takes it within 5 s. A credential refresh
takes a per-account lock across replicas, so one account is never refreshed
twice at once. Log lines and refresh audit rows carry `replica=<name>`
(`CCQUOTA_REPLICA`, else `HOSTNAME`). On SQLite the one hub leads everything.

**Enroll each endpoint** (on the hub — the token is shown once):

```bash
ccquota enroll --name web-01
```

`enroll` and `name` change the hub's own database and will **not** create one:
against a database that does not exist they fail rather than mint a token that
no hub has ever heard of. (Only `ccquota hub` creates a database, and it logs
when it does.)

**On that endpoint:**

```bash
export CCQUOTA_HUB_URL=https://ccquota.example.com
export CCQUOTA_TOKEN=ccq_...
ccquota agent
```

`ccquota agent --install` prints a systemd unit, launchd plist, or Windows
scheduled-task command for the platform it runs on. Review it before using it —
it carries a token.

> **Minimal Linux images need CA certificates.** The agent talks to
> `api.anthropic.com` over HTTPS, and a slim container or a stripped base image
> often ships without root certificates. Token usage still flows, but the limits
> lookup fails and the dashboard reports a TLS error against that endpoint.
> `apt-get install -y ca-certificates` (or your distro's equivalent) fixes it.

**Retiring one** (also on the hub, same database, same access assumption):

```bash
ccquota endpoint list                  # every enrollment, whatever its kind
ccquota endpoint list --all            # retired ones too
ccquota endpoint retire <endpoint_id>  # stop accepting its token, keep its history
```

`endpoint list` is the operator's inventory, so unlike the dashboard's Endpoints
roster it shows **every kind** of enrollment with a `KIND` column — the roster
filters to agents, and an enrollment you cannot see is one whose id you cannot
look up.

`retire` is the one you want. It keeps the endpoint's row and every usage row
pointing at it — **past totals do not move** — and its enrollment token stops
being accepted immediately: usage pushes, the live report and the quota lease
all reject it from that moment. The dashboard's
roster hides it, with a toggle on the Endpoints card to show retired ones
again, and its spend keeps its name everywhere history is drawn.

There is **no un-retire**. The token hash is still on the row, so restoring it
would put the credential you just killed back in service. Re-enroll instead:
that mints a new id and a new token, and the retired endpoint keeps its history
exactly as it stands.

```bash
ccquota endpoint delete <endpoint_id>  # remove it entirely
```

`delete` is only for an endpoint that **never reported anything** — a token
minted for a one-off experiment, or for a machine that was replaced before it
ever pushed. It refuses the moment the endpoint has reported, and names what it
found:

```
ep_1789872512194365000 has reported usage, so deleting it would change historical totals:

  usage_events                 1 rows
  usage_hourly                 1 rows
  endpoint_accounts            1 rows

Retire it instead — same effect on the roster and the token, and the
numbers stay true:

  ccquota endpoint retire ep_1789872512194365000
```

The distinction is the point: one is safe, the other rewrites the past.
Deleting an endpoint whose spend is already in the ledger would make last
month's report come back smaller with nothing left to say why — and nothing in
the schema references `endpoints(endpoint_id)`, so it would not be a clean
removal either: the row would go and nine tables would keep rows pointing at an
id that no longer names anything.

There is deliberately **no DELETE over HTTP**. `enroll` is already a hub-local
operation that requires access to the database; retiring lives in exactly the
same place, so the attack surface is unchanged. `GET /v1/endpoints` grows only
a read-only `?include=retired`.

**Just want a local report?** No hub, no network:

```bash
ccquota report --days 7 --no-limits
```

### Claude Code and Codex sources

```bash
ccquota report --sources codex --days 7 --no-limits
ccquota report --sources all --json --no-limits
ccquota agent --sources codex
ccquota agent --sources claude                # collect Claude Code only
ccquota agent --codex-home /data/codex        # a custom Codex data directory
```

`--sources` accepts `all` (the default), `claude`, `codex`, or a comma-separated
list. `CCQUOTA_SOURCES` sets its default. `--home` selects the user's home;
`--codex-home` overrides `CODEX_HOME`, which otherwise defaults to
`<home>/.codex`. Both commands read Codex `sessions/**/*.jsonl` and
`archived_sessions/**/*.jsonl`. No Claude login is needed to collect Codex.

Codex collection supports per-request `token_usage_record` entries and older
`event_msg` / `token_count` entries. Notification echoes are ignored when
per-request records exist; older cumulative counters are differenced instead
of summed. Cached input is separated from total input, and reasoning remains
a subset of output, so neither is counted twice. Cache writes remain in
non-read input because these logs do not provide Claude's cache TTL split.
See [OpenAI's token accounting example](https://developers.openai.com/api/docs/guides/prompt-caching).
The dashboard's "turns" count represents model requests, including tool-use
iterations, rather than user messages.

The local report includes **By source**. The dashboard is one continuous page
with a single source selector; accounts follow that selection. (The top nav
bar anchors within that one page — see [The dashboard](#the-dashboard).) Usage, quota history, findings,
Live/SSE, machine lists and MCP accept `source=codex`. The all-time headline
follows the selected account/source; project and machine chips narrow details.

The agent reads file-backed Codex account metadata and invokes the official
[App Server read APIs](https://learn.chatgpt.com/docs/app-server) for quota and
account activity. A disposable, restricted credential snapshot contains an
empty refresh token for quota reads. A separate maintenance step asks official
Codex to renew the original file login before access expires; no model turn is
started. The hub receives measurements, never credentials. Queries have a
25-second timeout; a short hub lease and jitter avoid duplicate polling of the
same account on multiple machines. Each credential profile renews independently
of that quota lease. Keychain-only and unsupported login modes report an
explicit reason while log collection continues. CLI 0.149.0 and 0.153.4 have
been checked with real account reads.

### Codex login renewal and multiple accounts

```bash
ccquota codex add personal --codex-home "$HOME/.codex"  # name the existing login
ccquota codex add work                                 # new independent home
ccquota codex login work                               # official browser login
ccquota codex login work --device-auth                 # alternative for a headless host
ccquota codex list                                     # email, plan, login state, who refreshes it (local | hub)
ccquota codex use personal                             # default for new managed launches
ccquota codex run                                      # use that default
ccquota codex run work -- exec "review this change"     # choose one explicitly
ccquota codex refresh personal                         # explicit renewal, no model turn
```

Login starts in the selected account directory, including when invoked through
`sudo -H -u USER`; `ccquota codex run` keeps the current project directory.

The registry is `~/.ccquota/codex-profiles.json`; it contains names and paths,
never tokens. New directories live in `~/.codex-accounts/NAME`. Agents reload
registrations on each scan, deduplicate canonical paths, and preserve existing
cursors when a directory gets a name. Explicit add/login commands record a
credential-matched observation time, so a session launched immediately after
login is attributed even before the next agent scan; older sessions stay under
their existing attribution. `use` affects `ccquota codex run`; the
plain `codex` command and already-running sessions keep their existing login.
Managed launches explicitly use file credentials and remove ambient API/access
token overrides so they cannot silently select another identity. They lock the
profile for their lifetime; Codex itself renews while the launch is active.

Automatic renewal is enabled by default for ChatGPT file logins. Disable it
with `ccquota agent --codex-auto-refresh=false`. Within 24 hours of access-token
expiry, maintenance asks official App Server `account/read` to refresh and
persist the original credentials. ccquota does not implement an OAuth exchange,
copy refresh tokens into other homes, send credentials to the hub, or promise a
permanent login. ccquota-managed login/run/refresh commands share an OS file
lock. Direct Codex clients do not participate in that lock; official Codex still
owns credential persistence. Independent logins per home/machine avoid relying
on copied refresh credentials. Transient failures back off; a recognized
revoked/expired/reused refresh credential stops retries until a new login is
observed. Expired access alone is reported as pending renewal.

A **hub-managed** home — `auth.json`'s `refresh_token` is the `hub-managed`
placeholder the node agent writes when it leases the account from the hub
(claude-fleet#1415, #1666) — is never refreshed here. The hub is that account's
one refresher and the node agent rewrites the access token before it expires,
so `ccquota codex list` reports `login.source: hub` with `auto_refresh: false`,
its login is `valid` until the lease itself lapses (`access_expired`, naming the
node agent — never `reauth_required`) or the upstream refuses it
(`access_rejected`, below), its local renewal record is not read,
and `ccquota codex refresh` / the agent's auto-refresh refuse it before the
official CLI is started. A self-managed home reports `login.source: local` and
behaves exactly as above. Two refreshers of one Codex refresh token lock each
other out — a refresh token is single-use — which is what the split exists for.

The clock is not the only judge (claude-fleet#1920). An access token can be
refused by the upstream long before its `exp` — a logout, a revocation, or a
reused refresh token taking its whole grant down — so whatever actually spoke
to the upstream with a home's token leaves the verdict in
`<home>/.ccquota-upstream.json`: the agent's quota poll, and the fleet
credential proxy on a session's request. It is keyed by the credential's
fingerprint and holds the upstream's code only (never a token or a message).
While it stands, a login the clock calls usable reads `access_rejected` with
`upstream_error` (`token_revoked`, …) and `upstream_rejected_at`; a later
accepted read of the same credential, or a new `auth.json`, clears it.

**Now → Collection by source** shows the account email, plan, profile/default,
login state, access expiry, last credential refresh, retry time, and per-machine
management commands. Quota delegation is separate from login health. **Review →
KPIs** explains request pricing coverage as priced requests / collected requests
and lists unpriced reasons. Pruned details get an explicit historical-detail
label; their tokens and requests remain in totals.

Renewal requires a writable Codex home and the official CLI. Keyring-only,
API-key, and workspace PAT logins are not automatically renewed by this adapter.
On a hardened systemd service, separately registered homes must also be included
in `ReadWritePaths`; the generated service includes the standard account root
and explicitly configured homes. See [official authentication](https://learn.chatgpt.com/docs/auth)
and [App Server authentication](https://learn.chatgpt.com/docs/app-server#authentication-modes).

Accounts use a hash of the stable account and member IDs, rather than email or
reset time. A profile's first observed login is a conservative boundary: only
new OpenAI sessions started after that observation are associated with it.
Existing/running and historical sessions remain **Codex (local usage)**
(`codex:local`). Current login changes do not rewrite old history. Codex does
not change the endpoint's Claude login. Request IDs survive account changes,
parser upgrades and raw retention; metadata/price enrichment changes no token
or request total.

```bash
ccquota agent --codex-homes /data/codex-work,/data/codex-personal
ccquota agent --codex-bin /opt/homebrew/bin/codex
ccquota budget --source codex --json
ccquota budget --source codex --account all --gate
```

Additional directories are separate profiles (`CCQUOTA_CODEX_HOMES`); the CLI
path can also be set with `CCQUOTA_CODEX_BINARY`. File credentials are required
only for account queries. No quota is inferred from an API key or third-party
model provider. A missing quota/expired window is unknown; the budget gate
retains its existing fail-open behavior. Credits alone do not prove headroom.

**Now** displays the actual provider windows (a primary window can be 7 days),
credits, observation time, recent Codex activity and per-source collector health.
Completed/interrupted sessions leave the live list; old replays cannot appear
as live. Missing context, live cost or edited-line counters remain unknown.
**Review** adds quota series, cache-write coverage and request provenance.
Service account totals appear alongside locally attributed details, never
added to them. Their dates, scope and update delay are not yet proven comparable,
so no difference is labelled as missing data or cloud usage.

Codex costs are **API equivalents at the 2026-09-07 public rate schedule**,
including historical revaluation, not subscription invoices. Built-in coverage
includes GPT-6 Astra, GPT-5.6 Sol/Terra/Luna, GPT-5.5, GPT-5.4, GPT-5.3 Codex and
GPT-5.2 Codex. New models use explicit cache writes and request context tiers;
known Fast/Flex/Batch rates are applied when recorded, otherwise Standard is
an explicit assumption. GPT-5.4/5.5 use per-request equivalents; session-wide
adjustments are unavailable. Legacy Fast rates, Spark, unknown providers/models
and missing required cache breakdowns remain unpriced. Review shows the
coverage and per-request basis. Rates: [OpenAI pricing](https://developers.openai.com/api/docs/pricing),
[GPT-5.5](https://developers.openai.com/api/docs/models/gpt-5.5),
[GPT-5.4](https://developers.openai.com/api/docs/models/gpt-5.4),
[GPT-5.2 Codex](https://developers.openai.com/api/docs/models/gpt-5.2-codex).

Upgrade the hub before upgrading agents. Existing events and historical hourly
totals migrate to source `claude`, including history whose raw events have
already been pruned. Each collector has its own durable scan position.

## Several subscriptions, several people

One hub holds any number of subscriptions. You do not configure which account an
endpoint belongs to — the agent reads it from that machine's `~/.claude.json`
every cycle and reports it. Enrollment is per *machine*; the hub learns the
pairing from the first push.

```
me@personal.example    pro   default_claude_pro       1 endpoint
team@acme.example      max   default_claude_max_20x   2 endpoints
```

The dashboard grows a subscription switcher as soon as a second one reports, and
every query carries an account scope: a uuid for one subscription, or `all` to
span every one. The switcher's first entry is *All N accounts / usage pools*.

A query that names none is **answered, and told what it spans** — one
subscription is inferred when the hub holds only one, and with several the
answer is every one of them, labelled:

```
GET /v1/usage?by=endpoint          # no ?account=, hub holds three
→ 200  "account_uuid": "*",
       "all_accounts": true,
       "scope_note": "Totals span every subscription on this hub. Tokens and
                      notional costs are additive; rate-limit utilization is not
                      and is reported per subscription."
```

Refusing was the older answer, and it was the wrong one: it made the
subscription a *mode* the whole page was stuck in rather than an axis you pick
up and put down. The label is what makes spanning safe — a cross-subscription
total is never mistaken for one subscription's, because it says so in the
response. `?account=<uuid>` still scopes to exactly one, and `/v1/accounts`
still lists them.

The MCP tools take the same default and carry the same `all_accounts` /
`scope_note` pair, so a model reading a spanned total knows it spanned.
`list_accounts` is there when it needs the uuids.

**What is not additive says so.** Tokens add across subscriptions, and so does
each *source's* cost. Two things never do, and each says so in the response —
the first in `scope_note`, the second in the `disclaimer` that travels with the
totals:

- **Rate-limit utilization** — a percentage of one subscription's window.
  Averaging three of them describes no window that exists, so it is reported
  per subscription and the dashboard's limits banner switches off entirely
  while the scope is `all`.
- **Cost across sources** — `claude` and `codex` figures are notional (what the
  tokens would have cost at API rates; nobody is billed them, the plan is),
  each at its own published rates. Each row carries its own kind; see the
  per-source breakdown.

### Several users on one machine

An endpoint is a **(machine, user) pair**, not a machine: every OS login has its
own `~/.claude`, its own transcripts and its own credentials, and on a shared box
they cannot read each other's. So for a shared box, run one agent per user — each
with its own enrollment token and its own state directory:

```bash
# On the hub, once per person:
ccquota enroll --name build-server-alice
ccquota enroll --name build-server-bob

# On the box, as each user (or as root with --home pointed at theirs):
ccquota agent --home /home/alice --state /home/alice/.ccquota
ccquota agent --home /home/bob   --state /home/bob/.ccquota
```

They can be on the same subscription or different ones; the hub does not care.
Do not try to cover two users with one agent process — it reads one home
directory, and on most systems it could not read the others anyway.

Spend is then queryable **by OS login** (`usage_by_user`, and a card on the
dashboard), which on a shared machine is usually the question actually being
asked. "Which machine" and "who" are different axes.

### Several subscriptions at the same time

One login can run several subscriptions **concurrently**: Claude Code reads
`CLAUDE_CODE_OAUTH_TOKEN` per process, so two sessions side by side on one
machine can be on two different plans. Measured on the development machine:
three at once.

So an endpoint has a *list* of subscriptions, not a current one — that is what
`list_endpoint_accounts` returns, and what the **Subscription** column of the
Endpoints table expands to when you open its ⊞. The endpoint's own login (from
`~/.claude.json`) is what that column shows closed, it is tracked separately,
and only a change of *that* is a switch.

If someone logs out and into a *different* account on a machine, ccquota records
the switch and shows it in the UI — in that same table's **Last switch** column,
on the row of the machine the switch happened to. The column appears only when a
switch has actually happened in the current scope. Rows already ingested keep
their old attribution and cannot be corrected — see the known limits below. Two
plans running side by side is **not** a switch, and is not recorded as one.

## Ways in — one process is not one entrance

The hub is one binary on one port. That is a fact about *deployment*, and it
gets read as a fact about *access*, which it is not: these surfaces share a
process, and they do not share a credential.

| Door | What you need | What it gives you |
|---|---|---|
| The app (`/`, `/sessions`, `/connect`, `/config`) | a GitHub sign-in on this hub's list, or the viewer token | what the viewer's role lets them see (a user: their own) |
| The admin pages (`/subscriptions`, `/nodes`, `/admin/users`, `/admin/settings`, `/admin/audit`) | an admin's sign-in, or the viewer token | the pool, machines, people, settings and the merged audit (`/v1/admin/audit`, CSV with `?format=csv`); a user gets 403 (claude-fleet#1990) |
| `/signin`, `/auth/github/*` | a GitHub account whose numeric ID is on the list | exchanges a GitHub sign-in for this hub's session cookie, nothing else |
| `POST /logout` | a same-origin form (the page header's 退出) | clears the cookies this hub minted and shows the signed-out page; GitHub's own session stays |
| `/v1/...` | the viewer token, as a bearer header | the same figures as JSON |
| `POST /mcp` | the same viewer token again | the read tools, for an agent |
| `/v1/ingest`, `/v1/live/report`, … | each agent's own enrollment token | write: push Claude and Codex usage |
| `/badge/…`, `/embed/…` | nothing while the setting `hub.public_badges` is on, an admin's sign-in otherwise | one number, for a README |
| `ccquota enroll / team / plan / name` | a shell on the hub machine | the only door that can change who gets in |

That table is the software. The half it cannot tell you is *your* hub — whether
GitHub sign-in is wired up, how many admins the deploy names, whether badges are
public, how many agents are enrolled. The hub answers that itself:

    https://<your hub>/access          # the page
    https://<your hub>/v1/access       # the same thing as JSON

Both sit behind the viewer gate, like every other human surface. That is
deliberate rather than incidental: `/signin` is mounted unconditionally and
404s when GitHub sign-in is unconfigured *precisely* so the route cannot tell an
uncredentialled prober whether the feature is on, and a page that reports the
configuration must not undo it. You read it because you already came
through a door. (Its page retired with claude-fleet#1990; Settings reads
`/v1/access` for the deploy-set facts.)

It is a description, not a control plane. Nothing on it mints, revokes or
widens a credential, and no command has been moved from the hub's shell onto
HTTP. `enroll`, `team` and `plan` stay local because a machine that could name
its own team could move its spend onto another team's budget.

### The page header — who is signed in, and the way out (claude-fleet#1467)

Every human page — the dashboard, 连接, 我的会话, 机器节点, 凭据发放 — carries
the same header, top right: the signed-in person's GitHub username with their
role · GitHub under it, or 管理员 · 令牌 for the operator's own door. It is
drawn by `web/dist/whoami.js` from **one** answer, `/v1/me` (`via`:
`open | token | github`, `person`, `name`, `role`, `can_logout`), recorded by the
gate as it admits the request — never inferred per page. Clicking it opens
姓名 / 登录方式 and, when a cookie of this hub's is behind the request, **退出**:
a plain same-origin `POST /logout` that clears the session and the parked viewer
token, then shows a signed-out page whose only link is 重新登录 → `/signin` (or
`/` without GitHub sign-in). No destination parameter, so no open redirect.
GitHub's own session is not this host's to end.

## Fleet nodes — every machine reports in (`CCQUOTA_FLEET=1`)

Off by default; with the switch off the hub and the agent are exactly what
they were before it existed (no route, no table, no extra connection).

Set `CCQUOTA_FLEET=1` on the **hub** and it creates a `nodes` table, accepts
node control channels at `/v1/node/connect` (enrollment-token auth, like
ingest) and serves the roster at `/nodes` (page) and `/v1/nodes` (JSON), both
behind the viewer gate.

Set it on an **agent** and the agent dials OUT to the hub — a WebSocket over
the hub URL you already gave it (`wss://` for `https://`), so a machine behind
NAT needs no inbound port — and sends a heartbeat every `--live-interval`
(5s): this login's fleets and their window counts (read through claude-fleet's
`~/.claude/fleet/bin/fleet-control.py rpc`, never by parsing tmux; a fleet the
read fails on is sent as `state: unknown`, not as 0 windows, and the agent logs
the reason once per distinct failure — claude-fleet#1460), the
machine's 1-minute load and core count, available memory, and the fleet
install's version. A dropped link is redialled on a 5, 10, 20, 30, 30 … s
ladder (jitter only shortens a rung, so the wait never exceeds 30 s), and a
change in the machine's network — a new Wi-Fi, a wake from sleep, read off the
PF_ROUTE socket on macOS and rtnetlink on Linux — redials at once from the
bottom of the ladder (claude-fleet#1630). The first beat after a reconnect is
the full picture.

The hub marks a node **lost** after three heartbeat intervals with nothing
received. Lost is only a label: the row stays, its sessions are not read as
idle, and nothing on the machine is touched. Every control message carries a
`proto` version; a node whose version the hub does not accept stays listed
(with its version) but is never sent a write.

The hub also **records** what it saw go wrong (claude-fleet#1630), in
`fleet_alerts` — read it with `GET /v1/fleet/fleet_alerts`: `node_lost` when a
node has been silent for `FLEET_NODE_LOST_ALERT_SECS` (120; counted from the
hub's own start, and never for a machine in maintenance), cleared by its next
beat; `lease_conflict` when a node's first beat after reconnecting shows a
session on an issue whose live lease another worker holds, naming both sides,
cleared once they agree again. Nothing changes hands because of either.

### A new machine in one command — `fleet node join` (claude-fleet#1627)

On the new machine, as the login that will run the fleet (after the client
install line, `curl -fsSL <hub>/install | sh`):

```bash
fleet node join
```

It is `fleet login`'s device flow with `purpose=node`: `POST
/v1/fleet/login/start {public_key, device_name, purpose:"node", os_user}`, the
same QR and `/fleet/login` page — titled 「把 <机器名> 加为节点」 — and the same
poll. Confirming needs what a certificate needs (an active login); the hub then
mints a fixed-kind join code for that confirmation and redeems it at once
(`enrollNode` → `redeemJoin`, the code row kept as the audit trail), so the
poll's `CertResponse` carries `node` — the same `NodeJoinResponse` as
`/v1/node/join` below. A plain login never carries it. The client hands the
pass to `fleet-node-join.sh --joined <file> --ui`, which runs the steps below
on their defaults. The `/nodes` panel shows this command to anyone signed in;
the join-code button below stays, for the operator, one more version.

### A new machine — join codes (claude-fleet#1418, kept one version)

The `/nodes` page (Machines, an admin's — a user gets 403) has an **加机器**
button: one click mints a **join code** and prints the line to paste on the
new machine, as the login that will run the fleet:

```bash
curl -fsSL https://raw.githubusercontent.com/verkyyi/claude-fleet/stable/bin/fleet-node-join.sh \
  | bash -s -- --hub https://hub.example.com --token fj_…
```

**The code.** `fj_` + 26 lowercase base32 characters (130 random bits); only
its SHA-256 is stored. It redeems **once**, within **10 minutes**, into one
`agent` enrollment — the same thing `ccquota enroll` mints, so nothing the
code buys is new: the admin role still needs the login in
`CCQUOTA_FLEET_ADMIN_USERS`. Unknown, used and expired all answer the same 401.

| Route | Auth | What |
|---|---|---|
| `POST /v1/fleet/join-codes` (`{label?}`) | operator (viewer token / tailnet; same-origin) | mint a code → `{code, expires_at, command}`; the code is shown this once |
| `GET /v1/fleet/join-codes` | operator | the last 20: label, created, expiry, who redeemed into which endpoint — never a code |
| `POST /v1/node/join` (`{code, hostname, os_user}`) | the code | redeem + enroll in one transaction → `{endpoint_id, label, token, hub, admin, ssh_ca, dist}` |
| `GET /v1/node/dist/<darwin\|linux>-<amd64\|arm64>` | the new token | the agent binary, `X-Ccquota-Sha256` header |
| `GET /v1/node/self` | the new token | this endpoint's roster row (`status: online\|lost`), or `never` |

The join records the reported hostname / login on the endpoint, so the admin
gate recognises the agent's very first connection (otherwise `os_user` stays
empty until its first usage report, and the SSH CA would wait for a reconnect).

**The binaries.** The Docker image cross-compiles darwin/linux × amd64/arm64
into `/usr/share/ccquota/dist` and sets `CCQUOTA_FLEET_DIST_DIR` to it
(`--build-arg DIST_TARGETS=` skips them). With no dist dir the script falls
back to `--ccquota <file>`, a `ccquota` on PATH, or `go install`.

**The script** (`bin/fleet-node-join.sh`, in the claude-fleet repo) redeems the
code first — before anything slow can outlive it — then installs git / tmux /
gh / python3 / zsh (apt / dnf / yum / apk as root or passwordless sudo;
Homebrew on macOS), the agent (`~/.local/bin/ccquota`, settings and token in
`~/.config/claude-fleet/node.env`, 0600), and runs it under launchd (a gui
LaunchAgent, or a LaunchDaemon with `UserName` for an SSH-only login) or systemd
(user unit + linger, or a system unit with `User=`) — detached, with a warning,
where there is neither. `CCQUOTA_FLEET=1`, plus `CCQUOTA_FLEET_ADMIN=1` unless
`--no-admin`: the admin agent then installs the hub's SSH user CA itself
(see *Connection certificates* below). It waits until `/v1/node/self` reads
online, then clones claude-fleet at `stable` and runs
`fleet-login-bootstrap.sh`. A rerun reuses the saved registration and leaves a
new code unspent. `CCQUOTA_FLEET_JOIN_SCRIPT_URL` changes the URL the printed
command fetches.

**Coordinate only — the default for a new node** (claude-fleet#1719). A FIRST
join writes `CCQUOTA_FLEET_COMPUTE=0` into `node.env`: the agent says
`"compute":false` in its hello and every heartbeat, and the hub then never
places a session on that login (auto or named — the candidate reads
`compute off (只协调 …)`) and refuses its credential lease (`403 compute_off`,
audited like any deny; the agent does not even ask). It keeps everything else:
the roster row (the /nodes page tags it 「只协调」, `compute_off` in /v1/nodes),
its certificates, peer certificates, the relay. `--compute 1` on the join opens
it; a rerun keeps what `node.env` says — and a node joined before #1719 has no
line, which reads as compute ON, so nothing that ran sessions stops. The
install line (`/install`) joins every computer this way (`fleet node join
--no-fleet --no-deps --no-admin`), and the same scan writes the ssh snippet
with a peer-certificate `Match` per other machine: the hub's answer carries
`machines` (`[{hostname, alias}]`), which `fleet login` keeps in
`peer/machines` so `fleet-peer-cert.sh` turns `m4`, `m4-lan` and `mini2` into
one machine and one certificate.

**Can it run? The probe and the team policy** (claude-fleet#1720).
`bin/fleet-node-probe.sh` — run at `fleet node join` and daily by the agent —
writes `node-probe.json` (`{loc, anthropic, openai, laptop, ts, verdict}`,
verdict `ok | unsupported_region | unreachable`: the egress region from
Cloudflare's trace crossed with ipinfo, and one credential-less request to each
provider's API), and the agent carries it in its hello and every heartbeat with
`node.env`'s compute word, both re-read live — `fleet node compute on|off`
needs no restart. The hub decides in one place (`internal/api/fleet_compute.go`):
`unsupported_region` closes a login that asked to run (placement skips it, its
lease is refused) and raises the `compute_region` finding, unless the person
forced it on (`fleet node compute on --force`, written to `fleet_audit`
as `compute_force`); the fleet setting `fleet.compute_auto=on` (default off,
`PUT /v1/fleet/settings`, audited) opens a coordinate-only login whose probe is
`ok` and under two days old. `unreachable` only refuses `compute on` and the
auto-open — it never closes a running login. No probe and no setting =
#1719 exactly.

**A person's own computer** (claude-fleet#1721). `fleet node compute on
--personal` — a laptop's default, `--shared` to say no — writes
`CCQUOTA_FLEET_PERSONAL=1`; the agent carries `personal` in its hello and every
beat, and `/v1/nodes` shows it. Placement (`internal/api/fleet_personal.go`)
takes a personal login only for a start asked FROM it: its own fleet's
`/v1/node/place` / `/v1/node/move`, or a person's door while that person's
client lease (claude-fleet#1715) says the client runs on it. Anything else —
another machine's auto, a start named at it, a `worker_start` naming its
fleet — is excluded as `personal`. The node's own spawns default to `local`
(`fleet_spawn_node_default`). Before the machine sleeps,
`bin/fleet-node-sleepwatch.sh` (NSWorkspace's will-sleep / did-wake) tells the
agent, which flags it 维护中 with reason `sleep` (`POST /v1/node/maintenance`)
and notifies the person's client how many sessions still run; on waking — or
when its wall clock jumped past its monotonic one, or at start — it sends
`leave` with `if_reason: sleep`, which never ends an operator's maintenance.
No personal login = nothing changes (`TestPersonalUnsetAddsNothing`).

### Who may sign in, and the hub's settings — no redeploy (claude-fleet#1986)

The deploy names the **admins** (`CCQUOTA_GITHUB_ADMINS`) and nothing else
about people. An admin adds and removes **users** on the hub, and they apply
on the next request — no deploy file changes:

    fleet users list
    fleet users add alice [--machine-login alice]   # asks GitHub for alice's ID now and pins it
    fleet users remove alice                        # next request refused; her devices revoked

(`GET` / `POST {login, machine_login?}` / `DELETE ?login=` on `/v1/fleet/users`,
admin only.) A name GitHub does not know is refused, never added; a deploy
admin is listed but read-only — it cannot be added as a user or removed. Every
add, remove and refusal is a `hub_audit` row.

The settings that used to be variables are in the database too, read through
`Server.setting(key)` (the stored value, else the default) and changed with `fleet hub set <key> <value>`
(`PUT /v1/fleet/settings`); `fleet hub settings` lists what applies and where
it comes from, `fleet hub unset <key>` goes back to the default. Every change
is one `hub_audit` row: who, when, old → new.

| key | default | replaces |
|---|---|---|
| `hub.public_meter` | on | — |
| `hub.public_badges` | off | `--public-badges` (no longer read, claude-fleet#2087) |
| `pool.skip_pct` | 85 | a node's `FLEET_ACCOUNT_CEILING` (served at `/v1/fleet/client-settings` → `pool`) |
| `pool.move_when_full` | off | a node's `FLEET_FAILOVER` (same) |
| `fleet.auto_assign` | — | `CCQUOTA_FLEET_AUTO_ASSIGN`, no longer read (`none` = no machines) |
| `fleet.spot` | off | a set `CCQUOTA_FLEET_SPOT_IMAGE` meaning on (the image is still the deploy's) |
| `fleet.routes_extra` | — | more machines / routes on top of `CCQUOTA_FLEET_ROUTES`, the same JSON |
| `user.<id>.machine_login` | — | `CCQUOTA_FLEET_PRINCIPAL_LOGINS`, no longer read (`<id>` = a GitHub ID, `583231` or `gh:583231`; `none` = no login) |
| `user.<GitHub ID>.lang` | — | the account's page language (claude-fleet#2033): `zh-CN` \| `en` |

The old flag and variables were copied into the database by the version
that introduced the settings (claude-fleet#1986) and are **no longer read**
(claude-fleet#2087): a deploy that still sets one changes nothing, and a
machine login is someone's only while their hub_users row or a
`user.<id>.machine_login` says so. The one old value still honoured is a set
`CCQUOTA_FLEET_SPOT_IMAGE` meaning `fleet.spot` on, copied into the database
once at start (audited as `deploy`, marked `hub.legacy_migrated.fleet.spot` so
an admin's later clear is not copied back). The CLI authenticates with
`CCQUOTA_VIEWER_TOKEN`, or `FLEET_HUB_SESSION` set to a signed-in admin's
`ccq_sess` cookie — both read from the environment, never written down.

### People and their logins — GitHub sign-in opens the account (claude-fleet#1411)

With the fleet module on, a person signing in with GitHub (`/signin`) becomes
a **principal**, keyed `gh:<their GitHub ID>`, and has ONE login name used on
every machine — either the one the operator mapped them to (below) or one the
hub mints once (lowercase letters + digits, ≤16, de-duplicated). The hub
keeps, per (principal, machine), whether that login exists there:
`fleet_principals` + `fleet_accounts`, created only when the switch is on.
`/v1/fleet/me` says who it saw: `signed_in` (a person, not an operator door),
`person` (`gh:<id>`, even before the hub has a row for them), `principal` (the
row, or null) and `accounts`.

**Whose login is whose — the explicit map.** The setting
`user.<GitHub ID>.machine_login` (claude-fleet#1986 — `fleet users add
<name> --machine-login <login>`, or `fleet hub set`) names the OS login that
belongs to each person. At a mapped person's sign-in the hub records them under
that login and **adopts** it (state `active`, op `adopt`) on every roster
machine whose agent runs as that login — the roster is the evidence the login
exists there — and again at any later node hello, so the order of "person signs
in" and "machine joins" does not matter. Nothing is ever created for a mapped
person, and no op is sent. A person **not** in the map leaves no row at all (no
minted login name, no op) unless `fleet.auto_assign` below applies to
them; the operator's `adopt` records them when there is somewhere to record them
on. A login outside `[a-z0-9]{2,16}` or one already someone else's is refused
(400) when it is set. A mapped login may start with a digit; a
login the hub *creates* still starts with a letter.

**The placement runs at every door that needs the row, not only at sign-in**
(claude-fleet#1472). The session cookie lives on, and a person mapped *after*
they signed in would otherwise reach the `fleet login` confirmation,
`/connect` and the certificate with no principal and be told `no active login
on any machine yet`. `/fleet/login` (the page and the confirm), `/connect`,
`/v1/fleet/connect` and `/v1/fleet/cert` run the same idempotent placement
first; an unmapped person is still recorded nowhere by it.

Opening a login is an op sent down the machine's control channel to its
**admin agent** — the operator's own login there, which already has
password-less sudo. Two rails, both required:

| where | setting | effect |
|---|---|---|
| hub | `CCQUOTA_FLEET_ADMIN_USERS=verkyyi` | only nodes running as one of these OS logins are ever sent an op |
| agent | `CCQUOTA_FLEET_ADMIN=1` (operator's login only) | the agent says so in its hello and runs ops; any other agent refuses every op (`NOT_ADMIN`) |

The node accepts exactly two ops, each with argv fixed on the node — the hub
only picks the login and display name, both re-validated there:

    create  ~/.claude/fleet/bin/fleet-login-new.sh <login> --full-name <name> --share-pool --apply
    remove  ~/.claude/fleet/bin/fleet-login-remove.sh <login> --keep-home --apply

`fleet hub set fleet.auto_assign m4[,m5]` (roster hostnames) queues an *unmapped*
person's login on those machines at their first sign-in; anything else is the
operator's `POST /v1/fleet/accounts` (`{"action":"assign|retry|remove|adopt|forget",
"principal_id":…, "hostname":…, "login":… for adopt}`) — `adopt` records a
login that already existed (a colleague onboarded by hand) without running
anything; `forget` drops the hub's record of a row that never reached a
machine (`pending` / `failed` / `removed`), or — with no `hostname` — of the
person and every such row of theirs, and refuses (409) while any row is
active, in flight or unknown: an active login is `remove`d, not forgotten.
`rekey` (`"to_principal_id": gh:<id> | <GitHub ID>`, `fleet hub accounts rekey
<from> <to>`) hands a person's row — every account, credential, certificate,
device, usage and budget row with it — to another id in one transaction,
logins and states unchanged, nothing run (claude-fleet#2094). The same move
happens on its own when a GitHub person is mapped (`user.<id>.machine_login`,
`fleet users add … --machine-login`) to a login the hub still has under an
identity from before GitHub sign-in (an enterprise-WeChat id): at the map and
at their next sign-in, idempotent, audited in `hub_audit` as
`principal.rekey`. A login that is another GitHub person's is never taken
over — the map is refused and names them. That route, and its `GET`, refuse a user's session (403): only the viewer
token or an admin can change accounts.

An op is recorded before it is sent; a link that drops with one in flight
leaves the account `unknown` and it is **never re-sent on its own**. The node
keeps its result until the hub acks it and re-sends it on reconnect, so the
late answer settles it; otherwise the operator `retry`s. Exit 3 ("login
already exists") is `failed`, never `active` — the name may be someone else's.

**Only see your own (hub side).** A user's `/v1/nodes` lists only the
(machine, login) pairs that are its own ACTIVE accounts; `/v1/fleet/me` says
who the hub thinks you are and where your login exists. Every later fleet view
filters through the same `Server.FleetScope`. The token door still sees
everything. The home page reads `/v1/fleet/me` once and shows the
way to `/connect` and `/sessions` for a person with an active login (and
`/nodes` too for an operator door), or 「未分配机器，联系管理员」 for a person
the hub has placed nowhere yet (`web/dist/lib/fleetnav.js`).

### Sessions on every machine — the Fleet Hub reads (claude-fleet#1409)

The same switch moves the read half of claude-fleet's Fleet Hub into the hub,
fed by those heartbeats instead of an SSH round trip per machine. Each beat
registers its machine (by claude-fleet's own control `machine_id`) and its
fleets in four new tables — `fleet_machines`, `fleet_fleets`,
`fleet_operations` (the journal C3 writes into) and `fleet_audit` (one row per
fleet tool call, refusals included). Identity is claude-fleet's scheme byte for
byte (`internal/fleetid`, checked value for value against
`bin/fleet_hub_common.py`): fleet UUID = `uuid5(machine_id, [session, repo,
checkout])`, worker_id = `<fleet UUID>/[<repo slug>:]issue-N | scratch-N`. So a
fleet UUID or worker_id issued by the SSH-era `fleet-hub.py` is the same one
here, and a session keeps its id whichever machine you read it from. The hub
re-derives every fleet UUID from the reporting machine and refuses one that
does not add up, or one already registered to another machine; a window whose
worker_id does not belong to its fleet is listed without an id, never routable.

Five read tools, on MCP (listed only when the module is on) and at
`/v1/fleet/<tool>`:

| tool | answers | from |
|---|---|---|
| `fleet_list` | every fleet on every machine, with machine, login, window count, `availability` (online / lost) and age; `refresh=true` re-reads each connected machine first | heartbeat registry |
| `fleet_sessions` | "my sessions": every window of every visible fleet, one list, with its worker_id and machine | heartbeat registry |
| `fleet_status` | one fleet's windows | live over the control channel (`source: live`), else the last heartbeat (`source: heartbeat`, with its age) |
| `config_get` | the fleet's managed settings and revision | live only (`UNAVAILABLE` when its machine is not connected) |
| `operation_get` | one journalled operation; a non-final one is reconciled with its machine, else reads `unknown` — never retried | journal + live |

A live read is a `request` message down the node's control channel, answered by
the agent running the same `fleet-control.py rpc` method (only `discover`,
`fleet_status`, `config_get`, `operation_get` — anything else is refused on the
node, whatever the hub asks), with the node's OWN `machine_id`. An agent older
than this never advertises the `read` capability in its hello, so the hub never
asks it and answers from its heartbeat instead.

Every answer is scoped to the caller: the operator's door (viewer token) and an
admin see every machine; a person signed in with GitHub sees only
the logins assigned to them (claude-fleet#1411) and gets `NOT_FOUND` — the same
answer as for a fleet that does not exist — for anyone else's. The `/nodes` page
shows the same "my sessions" table under the roster.

`/sessions` (claude-fleet#1429) is that list laid out for a phone, read-only:
sessions grouped by machine, the ones waiting for an answer or blocked first,
and a machine whose node is lost marked 失联 with how long ago it last reported
(its rows keep their last known state, never shown as idle). The page filters
again by the signed-in person's ACTIVE accounts from `/v1/fleet/me`, so a
server-side scope regression still cannot put a colleague's session on it.
Each `fleet_sessions` row carries `observed_at` / `age_sec` for that.

### Start, message, stop, resume — the Fleet Hub writes (claude-fleet#1410)

The rest of the Fleet Hub moves in on the same switch: `worker_start`,
`worker_message`, `worker_stop`, `worker_resume`, `config_set` and `gh_comment`
(journalled writes), plus `gh_issue_view` / `gh_pr_view` / `gh_pr_checks`
(live reads through the node's `fleet-gh.sh`). Same MCP endpoint, same
arguments and codes as `bin/fleet_hub.py` (`docs/FLEET-HUB.md`); over HTTP a
write is `POST /v1/fleet/<tool>` with a JSON body (`Content-Type:
application/json` — a GET, or any other type, is refused).

The semantics are the Python hub's, unchanged:

- **Journal first.** The hub writes the operation (`pending`) before it sends
  it; the node's own `fleet-control.py submit` journals it again under the same
  operation id before its detached executor runs. Read the outcome with
  `operation_get`.
- **Idempotency.** `(caller, idempotency_key)` is unique: the same request again
  returns the first operation (concurrent repeats too — exactly one reaches a
  node); the same key with different arguments is `IDEMPOTENCY_CONFLICT`.
- **Unknown is never replayed.** A write the node did not acknowledge, or whose
  controller ran and did not say, is `unknown` — and stays that way until
  `operation_get` can reconcile it.
- **No queue.** A machine that is not connected (or whose agent predates the
  `write` capability, or speaks an incompatible protocol) is refused at once —
  `UNAVAILABLE`, nothing journalled, the key still free — and nothing fires when
  it comes back.

A write travels as a `write` message (`method: submit`, nothing else) down the
control channel; the agent runs it as its own login, so a mis-addressed fleet is
refused on the node as `NOT_FOUND` — the node half of "only your own".

**Where a start lands.** `worker_start` may omit `fleet_id` and give `repo`
instead; `node` defaults to `auto` (or names one roster machine). The hub then
calls `PickNode(person, repo)` — the placement EPIC B's dispatcher uses — over
the caller's own logins with a fleet hosting that repo (for the operator's
doors: the `CCQUOTA_FLEET_ADMIN_USERS` logins, when set). It excludes a machine
that is offline, above **0.8 load per core**, under **max(2 GiB, 10% of its
memory) free**, under **memory pressure** (darwin's
`kern.memorystatus_vm_pressure_level` at warn or above; a node that does not
report it is never excluded for it), or where the person is already at their
**per-person cap** or the login at **its own cap** (below); scores the rest on
load alone — `min(cpu_idle, mem_idle)` with `cpu_idle = 1 − load_per_core / 0.8`
and `mem_idle = free / total`, so whichever resource is tighter decides, and a
tie goes to fewer sessions; and journals the choice with every candidate's
verdict as the operation's `placement`. Account quota is shown in each
candidate (`quota_used_pct`) but never scored: every machine spends the same
shared subscription (claude-fleet#1994).

```json
"placement": {"machine": "m4", "reason": "chose m4 (score 0.500, load 0.10/core, 8.0/16 GiB free, 1 sessions); m5 excluded: load 1.00/core > 0.8", "candidates": [...]}
```

The per-person cap is the hub setting `fleet.node_cap.<machine>` (no default
since claude-fleet#1994 — load decides; a machine with none is uncapped; `0`
closes it). It holds for a named
fleet too — a start or resume past it is `AT_CAPACITY`. The operator sets it:

```sh
curl -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"key":"fleet.node_cap.m4","value":"8"}' https://hub/v1/fleet/settings   # "" = uncapped again
```

**A login at its own cap is never a candidate** (claude-fleet#1587). Every
heartbeat carries `max_sessions` — the login's `FLEET_GLOBAL_MAX_SESSIONS`, the
cap its spawn gate refuses at (default 8, `0` = unlimited) — and `cap_sessions`,
the count that gate reads (awake session windows; a sleeper holds no slot), both
from `fleet-control.py discover`'s `capacity` (`fleet-control-read.sh
capacity`). `cap_sessions >= max_sessions` excludes the candidate as `full
(N/M sessions, the login's own cap)`, auto or named — its own gate would refuse
the start anyway. When every candidate is out for want of a slot (its own cap or
the per-person cap), placement refuses `AT_CAPACITY` with `all-full: …` naming
each machine, and `dash-issue-session.sh` says 「都满了」 (exit 2) — unless this
machine freed a slot since its last beat, in which case it opens here. A beat
without the two fields (an agent or claude-fleet older than #1587) filters
nothing, as before. Both show on `/v1/nodes` and on each `placement` candidate.

**A login whose own gate is holding is never a candidate either**
(claude-fleet#1836). The count cap defaults to 0 since claude-fleet#1831, so
`max_sessions:0` never says full — while the machine's real gate,
`fleet_machine_admit` (memory pressure, the room for one more session above the
kept-back floor, CPU load), refused each placed start on arrival. `capacity`
therefore also carries `admit` (false = holding), `admit_why` (the gate's own
tag: `内存紧张` / `负载过高`) and `room` (`fleet_machine_headroom`'s count of
how many more fit; absent with `FLEET_ADMIT=0`, the gate off). `admit=false` or
`room<1` excludes the candidate as `机器暂停接新：<原因>`, auto or named, and
counts as full: with every machine out that way the refusal is `AT_CAPACITY`
`all-full: every machine is at its session cap or pausing new sessions — …`. A
beat without the fields filters nothing on them, as before.

**A burst is spread, not stacked** (claude-fleet#2077). A new session takes
10–30 s to show in its node's beat — load, memory, session count — and in that
window every pick of a burst chose the same machine. The hub keeps its own
memory of what it just sent where (`recentTable`, in memory only): every
`worker_start` / `worker_resume` / `worker_move_in` is noted against the target,
with the session count its beat showed then, for **90 s** or until that count
has grown past it (one beat is credited once; a count that fell credits
nothing; a start the node refused outright is forgotten at once). `judge` folds
the count in as `recent` on the candidate: the score is taken as if those
sessions were already running — one core of load (`1/ncpu` per core) and
1.5 GiB of memory each, a default share of a reading the beat did not give —
so the next pick of the burst sees the first one's weight; a tie goes to fewer
sessions *plus* in flight; and a reported `room` is spoken for by them
(`room − recent < 1` holds the candidate as `机器暂停接新：内存余量不够再开一个
（room R，刚派出 N 个还没算进去）`). The reason says `…, 3 sessions, 1 just
placed)`; the candidate carries `recent` only when it is non-zero, so with
nothing in flight every placement is byte for byte what it was. A hub restart
forgets the table — the worst case is the old pick.

**Grants.** Each tool has the Python hub's scope (`worker:start`,
`worker:message`, `worker:stop`, `worker:resume`, `config:write` plus the key,
`gh:read`, `gh:comment`; every call needs `fleet:read`). The operator's doors
hold every scope. A person signed in with GitHub holds
`CCQUOTA_FLEET_PERSON_SCOPES` (default: everything except `config:write`) on
their own logins only, and `config_set` only for the keys in
`CCQUOTA_FLEET_PERSON_CONFIG_KEYS` (default none).
### Credentials live at the entrance — machines lease the short-lived half (claude-fleet#1415)

Every person's long-lived Claude / Codex credential (the refresh token) is
stored ONLY in the hub, sealed with AES-256-GCM under a key that is never in the
database the blobs are in — its own k8s Secret, or (better) a data key only
Aliyun KMS can unwrap (below). The hub alone refreshes them,
one writer per account, saving the rotated refresh token before anyone gets the
result; so however many machines use an account, it is refreshed about once per
token lifetime and no machine ever logs another out. A machine leases only the
access token and its expiry, renews it ~2h before it runs out, and never holds
anything that can mint more: revoke it at the hub and what it has runs out.

What a machine can do with only the short-lived half was **measured first**
(issue #1415, first comment, Claude Code 2.1.289 / codex-cli 0.160.0):

| CLI | where the agent writes it | a RUNNING session picks up a replacement |
|---|---|---|
| Claude | `<accounts>/<label>.hub/.credentials.json`, used via `CLAUDE_SECURESTORAGE_CONFIG_DIR`; the pool file `<accounts>/<label>` holds `hub:<label>` | on its next request (no refresh token needed). The `CLAUDE_CODE_OAUTH_TOKEN` env var is read once at launch and would die at expiry, so `bin/fleet-claude.sh` exports the directory instead |
| Codex | `<codex-homes>/<label>/auth.json` (`default` = `~/.codex`), `refresh_token` = the placeholder `hub-managed`, and `cli_auth_credentials_store = "file"` in its `config.toml` | on its first 401 (it re-reads auth.json and retries). A *missing* `refresh_token` makes Codex drop ChatGPT auth entirely, hence the placeholder |
| GitHub | `~/.config/gh/hosts.yml` (phase one: the person's existing token, no expiry — R1 replaces it) | — |

| where | setting | effect |
|---|---|---|
| hub | `CCQUOTA_FLEET_CRED_KEY_FILE=/secrets/cred-key` (or `CCQUOTA_FLEET_CRED_KEY`) | 32 bytes, base64 (`openssl rand -base64 32`). Unset = vault off: credential routes answer 503, the rest of the fleet module is unaffected |
| hub | `CCQUOTA_FLEET_CRED_MIN_TTL=3h` (default) | a cached access token with less left is refreshed before it is issued |
| agent | `CCQUOTA_FLEET_CREDS=1` | lease this login's credentials (its own + the shared pool's) and keep them written (with `CCQUOTA_FLEET=1`) |
| agent | `CCQUOTA_FLEET_COMPUTE=0` | this login only coordinates (claude-fleet#1719): the hub refuses its lease (`compute_off`) and placement skips it. Unset = on. Re-read from `node.env` every beat (claude-fleet#1720) |
| agent | `CCQUOTA_FLEET_PERSONAL=1` | a person's own computer (claude-fleet#1721, `fleet node compute on --personal`, a laptop's default): placed on only from itself; flags itself 维护中 while asleep. Re-read from `node.env` every beat |
| agent | `CCQUOTA_FLEET_COMPUTE_FORCE=1` | `fleet node compute on --force` (claude-fleet#1720): open over a probe that says the region is unsupported; the hub audits it |
| agent | `CCQUOTA_ACCOUNTS_DIR` (default `~/.config/claude-fleet/accounts`), `CCQUOTA_FLEET_CODEX_HOMES` (default `~/.codex-accounts`) | where the Claude / Codex files go |
| hub | `CCQUOTA_FLEET_OAUTH_REFRESH_VIA=node` | refresh through an online admin node instead of the hub's own network (claude-fleet#1490, below). Unset / `direct` = the hub posts itself |
| agent | `CCQUOTA_FLEET_OAUTH_REFRESH=0` | an admin agent stops offering to carry the hub's refreshes (on by default with `CCQUOTA_FLEET_ADMIN=1`) |

A lease (`POST /v1/node/credentials`, the node's enrollment token) is answered
only for the person whose ACTIVE fleet account is that (machine, login) — there
is no principal parameter to forge — and only on a machine the operator marked
**trusted** (claude-fleet#1968): the setting `fleet.node_trust.<machine>`
(`PUT /v1/fleet/settings`, operator only; `bin/fleet-node-trust.sh set <m>
trusted|untrusted`). No key = untrusted → `403 untrusted_node` + a deny audit
row, checked after the principal and the revocation. Every machine with an
active account when it shipped was marked trusted once
(`fleet.node_trust_migrated`), so their leases are unchanged. A session on an
untrusted machine borrows a revocable `fcp-h1.` session pass instead
(claude-fleet#1969, `/v1/fleet/session-cred` — issue / renew / verify / revoke;
key `CCQUOTA_FLEET_SESSION_CRED_KEY[_FILE]`, verifiers
`CCQUOTA_FLEET_SESSION_CRED_VERIFY_TOKEN[_FILE]`; docs/FLEET-HUB.md), which the
cluster credential proxy — `ccquota credproxy`, its own Deployment
(deploy/k8s/credproxy, claude-fleet#1973) — swaps for the bound account's
credential via `/v1/fleet/credproxy/resolve`
(`CCQUOTA_FLEET_CREDPROXY_TOKEN[_FILE]`). The operator
stores, lists and revokes:

    # store (or replace) — the secret never comes back out of the hub
    curl -H "Authorization: Bearer $VIEWER" -d '{"action":"put","principal_id":"gh:<GitHub ID>",
      "provider":"claude","account":"main","secret":{"refresh_token":"sk-ant-ort01-…","subscription_type":"max"}}' \
      $HUB/v1/fleet/credentials
    #   codex:  "secret":{"refresh_token":"…","account_id":"…"}   (from ~/.codex/auth.json)
    #   github: "secret":{"token":"gho_…","user":"<login>"}
    curl -H "Authorization: Bearer $VIEWER" $HUB/v1/fleet/credentials          # metadata only
    curl -H "Authorization: Bearer $VIEWER" -d '{"hostname":"m4","reason":"lost"}' $HUB/v1/fleet/credentials/revoke
    #   {"principal_id":…} revokes a person everywhere; both = that person on that machine; "lift":true undoes

Every issue, refusal, refresh, store and revocation is an audit row:
`/v1/fleet/credentials/audit`, merged with every other audit on the admin
page **`/admin/audit`** (claude-fleet#1990). All of these
refuse a user's session. A Claude refresh token comes from an interactive
`claude` login (`claudeAiOauth.refreshToken`); once it is in the hub, log that
machine out — two holders of one refresh token rotate each other out.
A Codex home the hub writes is registered once with
`fleet-codex-account.sh register <label> <home>` like any other.

#### The refresh runs on a node when the hub's country is refused (claude-fleet#1490)

The production hub sits in Shenzhen, and `auth.openai.com/oauth/token` answers a
mainland IP with `403 unsupported_country_region_territory` — so a Codex
refresh token in the vault (and, in time, a person's Claude refresh token) is
one the hub itself can never refresh. With `CCQUOTA_FLEET_OAUTH_REFRESH_VIA=node`
the hub keeps everything that matters — it alone holds the refresh token, one
writer per account, the rotated token saved before anyone receives the result —
and hands only the **one outbound POST** to an admin node whose network the
provider serves:

    hub  ──oauth_refresh {provider, form}──▶ admin node ──POST──▶ auth.openai.com
    hub  ◀──oauth_refresh_result {status, body}── admin node ◀───────┘

- **Which node.** A connected **admin** agent (on `CCQUOTA_FLEET_ADMIN_USERS`,
  started with `CCQUOTA_FLEET_ADMIN=1`) whose hello offered `oauth_refresh`,
  online by its heartbeat, not a SPOT pod (its egress is the cluster's own),
  lowest load per core first — m5 or m4, whichever is idler. The node picks the
  token endpoint itself, by provider: the hub cannot name a host or send a body
  anywhere else, so a node is never a general forwarder.
- **Nothing stays on the node.** The form and the provider's answer live in one
  goroutine's memory; `agent.log` gets one line — provider, HTTP status, how
  long — never a byte of either body.
- **The audit says where.** The vault's `refresh` row carries
  `refresh_via=<login>@<host>` (`ok · refresh_via=verkyyi@m5`, or
  `failed: token endpoint answered 403 … · refresh_via=…` when the provider
  refused through that node).
- **No node online → `refresh_unavailable`.** The lease row's error (and the
  leasing agent's log) says `credential refresh failed: refresh_unavailable: no
  admin node is online to relay the refresh` — never a 403 page — and a cached
  access token that is still valid is issued meanwhile. A node is asked
  **once** per refresh, never a second: a refresh token is single-use, so a
  form re-sent after a lost answer would get `invalid_grant` and strand the
  account — the same reason the direct path never retries.

Three outcomes are pinned in `internal/api/fleet_oauth_refresh_test.go` with a
real agent against a fake provider: the node relays and the vault saves the
rotated token; no node is online; the provider refuses. Importing a Codex
account is `fleet-creds-import.sh --codex` (below). The hub half needs the
image redeployed with the variable set; the agent half, `ccquota` upgraded on
the admin logins.

#### Setup tokens and the shared pool (claude-fleet#1463)

A Claude **setup token** — what `claude setup-token` prints, `sk-ant-oat01-…`,
about a year, no refresh token — is the other kind the vault takes:

    "secret":{"setup_token":"sk-ant-oat01-…","expires_at":"2027-10-03T00:00:00Z"}

It cannot be refreshed and does not rotate, so the hub stores it as kind
`setup_token`, **issues it as is** (no refresh, nothing cached, no row lock —
any number of machines hold the same token without logging each other out),
refuses to store or issue one past `expires_at`, and reminds the operator:
a `cred_setup_token` finding on the hub page from **30 days** before the date
(critical in the last week, and once it has passed), and its card on
`/subscriptions` says 「到期」. The only remedy is a person minting a new one and importing it
again — there is nothing the hub can renew. `expires_at` is the operator's
word: the token endpoint does not say.

**Pool accounts.** `"principal_id":"pool"` stores a credential that belongs to
the machines' shared pool (docs/SHARED-MACHINE.md 2b), not to a person. Every
node whose login IS some active principal gets the pool rows in its lease
beside its own — after the same no-principal and revocation checks, so a
revoked person or machine loses the pool too; the audit row names the person
who leased it, with `pool` in its detail. There is no per-principal allow-list
in this phase: the pool is for everyone the hub has let in, which is what the
pool meant before the vault (every login got a copy of the same files). `pool`
is a sentinel, never a row in `fleet_principals`.

**Importing this machine's pool.** The operator's one command:

    ~/.claude/fleet/bin/fleet-creds-import.sh [--dry-run] [--expires-at <RFC3339>] [--principal <id>] [label …]

reads each plain `<accounts>/<label>` setup-token file, POSTs it as a pool
`setup_token` over the viewer token, and prints what it did — the token goes to
curl in a 0600 file and is never printed or put on a command line. Default
expiry is the file's mtime + 365 days (shown per label; `--expires-at` to
state it). Nothing on the importing machine changes: its files are left as they
are until THAT login's agent runs with `CCQUOTA_FLEET_CREDS=1`, leases them
back and writes `<label>.hub/.credentials.json` + the `hub:<label>` marker
exactly as for any lease — a session already running on the token in its env
is untouched (the env is read once), and the dash still attributes it to its
label (`fleet-account-truth.py` indexes the hub file's token too).

**Importing a Codex account** (claude-fleet#1490) is the same command in its
other mode:

    ~/.claude/fleet/bin/fleet-creds-import.sh --codex [--dry-run] [--principal <id>] [profile …]

reads each profile's `auth.json` (`default` = `~/.codex/auth.json`; any other
profile is `<codex-homes>/<profile>/auth.json`) for `tokens.refresh_token`,
`account_id` and `id_token`, and POSTs them as a pool `codex` account whose
label is the profile. A name ccquota has registered (`ccquota codex add`) is
resolved through `ccquota codex list --json` first (claude-fleet#1666): the
hub label follows the HOME, because the node agent leases a label back into a
fixed place — a profile living in `~/.codex` (a one-account machine's
`personal`) imports as `default`, and the mapping is printed. A home already
holding the `hub-managed` placeholder is skipped. Nothing on the importing
machine changes — but a Codex refresh token is single-use, so once it is in
the hub that machine's own Codex must stop refreshing it (the command says so
after every Codex import): let the lease replace the home
(`CCQUOTA_FLEET_CREDS=1` in `node.env`, restart the agent), or log it out. On
2026-10-04 the hub rotated an imported token 23 s after the import and the
importing machine's own ccquota auto-refresh, 10 h later, was refused with its
stale copy — that login read `reauth_required` until a re-login. From then on
the hub refreshes it — through an admin node when its own country is refused
(above) — and the home reads `login.source: hub` in `ccquota codex list`.

#### The vault key in Aliyun KMS (claude-fleet#1417)

A key in a k8s Secret means the database and that Secret, stolen together, open
every credential. With `CCQUOTA_FLEET_CRED_KMS_KEY_ID` set, the vault uses
**envelope encryption**: its data key is stored in the database only as KMS
ciphertext (`fleet_cred_key`), and opening it is a KMS `Decrypt` call made with
the hub's own cloud identity. The database and every Secret together open
nothing, and every unwrap is a line in KMS's log — ActionTrail / the KMS
console's call records; the hub's credential audit carries an `unlock` row
with the same KMS request id.

| where | setting | effect |
|---|---|---|
| hub | `CCQUOTA_FLEET_CRED_KMS_KEY_ID=alias/ccquota-fleet` | the master key (id or alias). Set = KMS mode |
| hub | `CCQUOTA_FLEET_CRED_KMS_REGION=cn-shenzhen` (or `CCQUOTA_FLEET_CRED_KMS_ENDPOINT=kms-vpc.cn-shenzhen.aliyuncs.com`) | where KMS answers |
| hub | RRSA: `ALIBABA_CLOUD_ROLE_ARN` + `ALIBABA_CLOUD_OIDC_PROVIDER_ARN` + `ALIBABA_CLOUD_OIDC_TOKEN_FILE` (ACK injects them); else `ALIBABA_CLOUD_ECS_METADATA=<role>`; else `ALIBABA_CLOUD_ACCESS_KEY_ID` / `_SECRET` | the hub's identity. **Use RRSA or an instance role**: a static AccessKey in a Secret puts KMS one Secret away again (the hub logs a warning) |

The RAM role needs `kms:GenerateDataKey`, `kms:Decrypt` and `kms:Encrypt` on
that key only. Every call carries the EncryptionContext
`{"purpose":"ccquota-fleet-credential-vault"}`, so a wrapped blob cannot be
decrypted for anything else.

- **First KMS start** generates the data key. If `CCQUOTA_FLEET_CRED_KEY(_FILE)`
  is still set, every stored credential is re-sealed from it under the new data
  key in the same transaction — then **delete that Secret**: it opens nothing
  any more, and the hub ignores (and warns about) it from then on. Rows sealed
  under a key the hub was not given refuse the install rather than be stranded.
- **Rotating the master key** needs nothing from the data: KMS's automatic
  rotation keeps old versions decryptable, and pointing the hub at a different
  key re-wraps the one data key on the next start (`rewrapped_at`) — no row is
  touched.
- **KMS unreachable = vault LOCKED, never a fallback.** The hub starts locked and
  stays so until a `Decrypt` succeeds (retrying 15s → 5min): leases and stores
  answer `503 vault_locked` (each lease refusal an audit row), and the live
  findings carry a **critical** `cred_vault_locked` at the top. Revocation and
  the audit keep working. Machines keep the access tokens they already have, so
  a short KMS outage costs nothing until those run out.

### One line to install, then just `fleet` (claude-fleet#1470)

A colleague's whole setup is one line in their own terminal (macOS or Linux;
Windows inside WSL), copied from the top of the 连接 page:

```sh
curl -fsSL https://<hub>/install | sh
```

`GET /install` is `bin/fleet-install.sh` with this hub's URL filled in; it
downloads `fleet`, `fleet-login.py` and `fleet-connect.py` from
`/install/<name>` (the copies this image was built from — embedded from
`internal/api/fleetclient/pack/`, packed from the repo's `bin/` at build time
by `bin/fleet-client-pack.sh`, claude-fleet#1803; the list pinned by
`TestFleetClientMatchesBin` and `bin/fleet-install-selftest.sh`; each file's
SHA-256 rides in `X-Ccquota-Sha256` and a mismatch is refused) into
`~/.local/bin`, writes the URL to `~/.config/claude-fleet/hub.json` (a token
already there is kept), appends one PATH line to the shell's rc file once, and
runs `fleet` with stdin from `/dev/tty`. Only stock tools: sh, curl, python3
(macOS's own 3.9 is enough), ssh. These routes are public like the CA's public
key — a script and three programs carrying no credential — and answer 404
until the hub has both a CA and GitHub sign-in, because that is what the first
`fleet` needs.

**`fleet`** with nothing after it (`bin/fleet` → `fleet-connect.py --enter`):

1. **Certificate.** None, expired, or under 6 hours left
   (`FLEET_RENEW_BELOW_SECS`): `fleet login renew` signs `fleet-renew <ts>`
   with the device key under `fleet-renew@claude-fleet` and POSTs
   `/v1/fleet/login/renew {public_key, ts, sig, device_name}`. The hub checks
   the signature against the key it **registered** (so an expired certificate
   is no obstacle), that the device is not revoked and was used inside the
   last **7 days** (`DeviceIdle`), and signs again — recorded as `via=renew`.
   The hub says scan (`unknown_device`, `device_revoked`, `device_idle`, exit
   3): the QR appears right there, and confirming it registers the device
   (`fleet_devices`: key fingerprint → person, name, last use, last machine,
   renewals, revocation). A scan after a revocation re-registers — the scan is
   the proof, the revocation only forces it.
2. **Machine.** `POST /v1/fleet/home` (certificate-signed under
   `fleet-home@claude-fleet`, or a session/token GET, `?last=`): the hub
   picks, in order, the machine this **device** used last if online; an online
   machine with the person's **sessions** (most of them); the least loaded
   online machine they have an account on (the placement `judge` of #1425,
   online-ness only — a login needs no writable control channel or cap room).
   None online → `503 {"code":"no_machine_online","error":"你的机器都不在线",
   "home":{candidates…}}`, which `fleet` prints as is and exits 1. The answer
   carries the whole route list, so no second fetch; `fleet m4` names the
   machine and never asks.
3. **Route**, as `fleet connect` below, then **ssh**. The hub unreachable at
   step 2 falls back to the remembered machine.

Every registration, renewal, refusal, revocation and pick is a row of
`fleet_device_audit`. `GET /v1/fleet/devices` lists a signed-in person's own
devices + audit (the operator's door: everyone's); `POST
/v1/fleet/devices/revoke {fingerprint}` — the owner or the operator. A revoked
device's renewal fails at once, and `verifySSHRelayCert` refuses its
still-valid certificate at the relay, the route list and the pick from that
moment. The 连接 page shows the install line (copy button), the devices with a
吊销 button, and the audit.

### Connection certificates — scan once, 12 hours in (claude-fleet#1412)

With a CA configured, the hub signs short-lived SSH **user certificates**, and
every machine's sshd trusts that CA. Nobody's key is copied to any machine; an
expired certificate is simply refused — scan again for the next one.

| setting | where | what |
|---|---|---|
| `CCQUOTA_FLEET_SSH_CA_KEY=/secrets/ssh-ca/ca` | hub | the CA private key (OpenSSH, unencrypted), mounted from its **own** k8s Secret — never the database. Unset: no certificates. Set but unreadable: the hub refuses to start |
| `CCQUOTA_FLEET_ROUTES='[{"hostname":"macmini","alias":"m5","routes":[{"name":"public","host":"…","port":22022},{"name":"tailnet","host":"…"}]}]'` | hub | the machines and the ways in, for the 连接 page and the ssh config; the first route is the default |
| `CCQUOTA_FLEET_PUBLIC_URL=https://…` | hub | the address the QR points at (default: as the request reached the hub) |

Make the CA once: `ssh-keygen -t ed25519 -N '' -C fleet-user-ca -f ca`, then
`kubectl create secret generic ccquota-ssh-ca --from-file=ca`.

**What a certificate says** (`internal/sshca`): principals = the person's
login (C4's one name, active somewhere — no active login, no certificate),
valid 12 hours (a minute back-dated for clock skew), key id
`person:<principal>` (`person:gh:<GitHub ID>`; the hub relay, C6, reads the
principal after the `person:` prefix) —
sshd logs it on every login, and the
hub's `fleet_certs` table turns it back into a person, a key and a moment. The
issuance is recorded before the certificate is handed out.

**Getting one.**

- `fleet login --hub https://…` (`bin/fleet-login.py`; the URL is kept in
  `~/.config/claude-fleet/hub.json` `{"url":…}`, which C6's client reads too): makes
  `~/.ssh/fleet-cert` if needed, POSTs its public half to
  `/v1/fleet/login/start`, draws the QR, and polls `/v1/fleet/login/poll`.
  Scanning it opens `/fleet/login`, which signs the person in with GitHub (the
  code survives the trip through `/signin` in a short cookie) and asks them to
  confirm the code their terminal shows; the next poll carries the
  certificate, exactly once. start/poll carry no credential and grant nothing
  until a signed-in person confirms; the form only accepts a same-origin POST.
- the **连接** page (`/connect`): the hub address, every route, the ssh config
  snippet, and paste-a-public-key → download the certificate
  (`POST /v1/fleet/cert`, a GitHub session only — the operator's token is not a
  person and gets 403).

The client paths are a contract (`fleet connect`, C7, reads them):
`~/.ssh/fleet-cert` (key), `~/.ssh/fleet-cert-cert.pub` (certificate),
`~/.ssh/fleet-ssh-config` (`# fleet-ssh-config v1`, one `Host <alias>
fleet-<alias> fleet-<alias>-<route>` block per route). `fleet login` appends
`Match all` + `Include ~/.ssh/fleet-ssh-config` to the END of `~/.ssh/config`
once, so a person's own entries keep winning.

**The machine side.** On every admin connect the hub sends `ssh_ca` with the
CA public key; the admin agent (`internal/agent/node_sshca.go`) writes
`/etc/ssh/fleet_user_ca.pub` and the one-line drop-in
`/etc/ssh/sshd_config.d/100-fleet-user-ca.conf` (`TrustedUserCAKeys …`) via
`sudo -n`, runs `sshd -t`, and checks `sshd -T` really uses that file; any
failure puts the previous files back (or removes the new ones) and sshd never
reads the bad configuration. It never edits `sshd_config`, any
`authorized_keys`, or a running sshd: on macOS sshd starts per connection, so
the change applies to the next one; elsewhere the listener gets a reload
(SIGHUP), which leaves established sessions alone. An unchanged key is a
no-op. `/v1/nodes` shows each admin node's answer as `ssh_ca`;
`/v1/fleet/ssh-ca.pub` serves the public key to anyone.
### One issue, one machine — issue leases (claude-fleet#1422)

Before claude-fleet's `dash-issue-session.sh` opens a session on an issue it
takes the hub's lease on `(repo, issue)`; the hub grants it to exactly one node
(one transaction on its single writer), and the other is refused with the
holder's name — `已被 m5 认领`, exit 3. GitHub's assignee check still runs
after it as the second guard.

```sh
ccquota lease acquire [--force] <owner/repo> <issue> <worker_id>   # GRANTED m4 · HELD m5 <wid> <expires> (exit 3)
ccquota lease release <owner/repo> <issue> <worker_id>             # RELEASED · NOT_HELD
```

It posts to `POST /v1/node/lease` with the node's own enrollment token
(`CCQUOTA_HUB_URL` / `CCQUOTA_TOKEN`, as the agent runs); the hub only grants a
lease for a fleet that endpoint's heartbeats registered. Exit 1 means the hub
could not be asked, and the fleet carries on as it does without a hub.

No renewal call exists: the agent's heartbeat already lists every session, so a
beat that shows the session pushes its lease out by 30 minutes, and a beat that
read the fleet but no longer shows a session it once showed releases the lease
(the session ended or was reaped). A fresh lease waits 5 minutes for its first
sighting. A node that goes silent renews nothing — its leases lapse 30 minutes
after the last beat that saw them, and are released, never re-dispatched.
`--force` takes a live lease and is recorded in `fleet_audit` as `lease_force`,
naming whom it displaced. The `fleet_leases` table exists only under
`CCQUOTA_FLEET=1`.

### Across machines — reports, messages, the worker map (claude-fleet#1421)

A worker's parent, or the worker a message is for, can live on another machine.
Neither machine can reach the other; both reach the hub. So the channel carries
node-to-node **relays**, on a `relay` capability an agent lists only when its
claude-fleet has `bin/fleet-hub-node.sh`:

- **Outbox.** claude-fleet drops a relay (`{id, kind, from, to, payload}`; kinds
  `child_report` and `message`) as a JSON file in the directory
  `fleet-hub-node.sh paths` names. The agent sends it (`relay`, op_id = the relay
  id) and deletes it when the hub acks; a refusal moves it to `refused/` with the
  reason beside it; anything unanswered is resent after 30 s or on reconnect.
- **Hub.** Checks the sender's worker_id belongs to a fleet THAT node reports
  (`FORBIDDEN` otherwise), that the id is `<from>#<1-64 safe chars>`, and that the
  target fleet has the same owner — the operator's logins with each other
  (`CCQUOTA_FLEET_ADMIN_USERS`; every login when none are named), a person's
  logins with each other, never across — then stores it in `fleet_relays`
  (primary key = the id, so a resend is one row) and acks. It pushes pending
  relays down the target's channel at once, after every heartbeat (a push left
  unanswered for 60 s goes again) and on its reconnect; they expire after 7 days.
- **Target.** The agent runs `fleet-hub-node.sh deliver` with the relay on stdin
  and answers `relay_result`: exit 0 = delivered, 75 = pending (pushed again
  later), anything else = failed, with stderr's last line as the reason.
- **Worker map.** After heartbeats (at most every 10 s) the hub pushes a
  `workers` message — every worker of the node owner's fleets on every machine,
  `{worker_id, node, origin_wid}`, `node` suffixed `:lost` for a lost machine —
  and the agent writes it where `paths` says, as a TSV claude-fleet reads
  without asking the network.

Every stored, delivered or failed relay is a `fleet_audit` row
(`relay:<kind>`, actor `node:<endpoint>`).

### A spawn picks its machine — node placement (claude-fleet#1425)

With `CCQUOTA_FLEET=1`, claude-fleet's `dash-issue-session.sh` (the dash, the
backlog, autofill and `/fleet-epic-run` all spawn through it) defaults to
`--node auto`: right after it took the issue's lease it asks the hub where the
session should run.

```sh
ccquota place [--node auto|<machine>] [--origin-wid <wid>] [--agent a] <owner/repo> <issue> <worker_id>
#  LOCAL m5<TAB><reason>                      exit 0 — open it here, as today
#  REMOTE m4 <operation_id> <status><TAB><reason>  exit 0 — the hub sent it there
#  HELD m4<TAB><msg>                          exit 3 — leased elsewhere
#  REFUSED <code><TAB><msg>                   exit 4 — no machine can take it
#  (exit 1: the hub could not be asked; the spawn opens it here)
```

`POST /v1/node/place` authenticates with the node's enrollment token, for a
fleet that endpoint's heartbeats registered, like the lease. It runs the same
`pickNode` as a placed `worker_start` (offline, 维护中, >0.8 load/core, short of
memory or under memory pressure, and at-cap machines are out; scored on the
tighter of CPU and memory idle), for the person whose
active fleet account is that (machine, login) — a login nobody owns places among
the logins of the same name. The asker's own fleet ⇒ `LOCAL`, nothing journalled
but an audit row. Another machine ⇒ the hub hands that fleet the lease (the spawn
arriving there takes it up: within one fleet, `(repo, issue)` is one worker) and
journals a `worker_start` on it with the asker's parent as `origin_wid`, the
placement kept on the operation; a refusal from that node gives the lease back,
so the asker can still open it itself. `auto` falls back to opening locally; a
machine named with `--node` is honoured or refused, never swapped.

### A session moves between machines — through the hub (claude-fleet#1426)

`fleet-move.sh <window> --via hub --to m4` (and `--rebalance`) moves an idle
session without the two machines ever reaching each other:

```sh
ccquota move plan [--node auto|<machine>] <owner/repo> <worker_id>
#  LOCAL m5<TAB><reason> · REMOTE m4 movable|old<TAB><reason> · REFUSED <code><TAB><msg> (exit 4)
ccquota move send --node m4 --bundle <tar> --branch <b> --sid <uuid> --name <n> [--pushed]
                  [--raw 0|1] [--state s] [--origin o] [--origin-wid w] [--handle h] <owner/repo> <worker_id>
#  MOVED m4 <window> <pid><TAB><new worker_id>  exit 0   HELD m4<TAB><msg>      exit 3
#  REFUSED <code><TAB><msg>                     exit 4   FAILED <code><TAB><msg> exit 5
#  UNKNOWN <operation><TAB><msg>                exit 6 — no outcome yet: never close the source
```

`send` uploads the transcript tar (`POST /v1/node/move/bundle`, ≤256 MiB), then
`POST /v1/node/move` — the hub runs `pickNode` restricted to that machine, hands
the issue's lease to the target fleet's worker, and journals a `worker_move_in`
there — then polls `{"action":"status"}` (reconciled with the target) until the
operation settles. The target's agent (it says `move` in its hello) downloads the
bundle (`GET /v1/node/move/bundle/<id>`, served to the move's target only,
checked against its sha256) before it hands the write to claude-fleet, which
lands the branch, unpacks the transcript and resumes the session. A `working`
session is refused (`INVALID_STATE`); a failed move gives the lease back to the
source; a settled move's bundle is dropped, and every bundle expires after a day.

### SPOT nodes — the hub starts a machine when every fixed one is busy (claude-fleet#1428)

Off by default. Set `CCQUOTA_FLEET_SPOT_IMAGE` (with `CCQUOTA_FLEET=1`, in a
hub that runs in a Kubernetes cluster) and the hub starts **ephemeral
execution nodes** of its own — a pod of that image on the cluster's SPOT
machines — when placement finds no fixed machine with room, lets placement use
them at a reduced weight, and deletes them again after they have sat idle for
`CCQUOTA_FLEET_SPOT_IDLE_MINUTES` (30). The image is `extras/spot-node/` in
the claude-fleet repo (fleet + agent + tmux + Claude Code + Codex CLI, one
unprivileged login), built from the repo root; the hub needs create / get /
list / delete on pods in its namespace (`extras/spot-node/k8s.yaml`).

| setting | what |
|---|---|
| `CCQUOTA_FLEET_SPOT_IMAGE` | the node image; set = SPOT on |
| `CCQUOTA_FLEET_SPOT_HUB_URL` | how a pod reaches the hub (default `CCQUOTA_FLEET_PUBLIC_URL`; one of the two is required) |
| `CCQUOTA_FLEET_SPOT_NAMESPACE` | where pods go (default: the hub's own) |
| `CCQUOTA_FLEET_SPOT_MAX` | nodes at once (1; 0 = never) |
| `CCQUOTA_FLEET_SPOT_IDLE_MINUTES` | release after this long with no session (30) |
| `CCQUOTA_FLEET_SPOT_BOOT_MINUTES` | give up on a pod that has not joined (10; also the join code's life) |
| `CCQUOTA_FLEET_SPOT_WEIGHT` | an ephemeral node's placement score multiplier (0.5); the `fleet.spot_weight` setting (`PUT /v1/fleet/settings`, 0–2) overrides it at runtime |
| `CCQUOTA_FLEET_SPOT_GRACE_SECONDS` | the pod's terminationGracePeriodSeconds: time to move sessions off on a reclaim (300) |
| `CCQUOTA_FLEET_SPOT_NODE_SELECTOR` / `_TOLERATIONS` | the SPOT pool: `k=v,k=v` and `key[=value][:effect],…` (or a JSON array) |
| `CCQUOTA_FLEET_SPOT_CPU` / `_MEMORY` / `_SERVICE_ACCOUNT` / `_PULL_SECRET` / `_POD_JSON` | the pod's requests, service account, pull secret, and a JSON file merged over the generated Pod for anything else |
| `CCQUOTA_FLEET_SPOT_KUBE_URL` / `_KUBE_TOKEN` / `_KUBE_CA` / `_KUBE_INSECURE=1` | outside a cluster (a dev hub against kind); in-cluster discovery otherwise |

**Kind.** A node is `fixed` (a machine someone owns) or `ephemeral` (one the
hub started). The kind is stamped on the endpoint **from the join code** the
hub minted — never from the joining side — so a SPOT pod cannot claim to be
m5 and m5 cannot talk itself into the SPOT weight. `POST /v1/fleet/join-codes`
takes `{kind: "ephemeral"}` for a SPOT box the operator runs by hand; the
join answer carries `kind`, and the join script writes
`CCQUOTA_FLEET_NODE_KIND=ephemeral` into `node.env`, which is what makes the
agent treat SIGTERM as a reclaim. `/v1/nodes` carries `kind` on every node and
machine, `spot` (the ledger state) on an ephemeral one, and a `spot` block —
the configuration, the nodes under way (a pod is listed from the moment it is
created, before it joins) and the newest released records.

**Life.** `fleet_spot_nodes` is the ledger: one row per node the hub started,
`provisioning` → `online` → `releasing` | `reclaiming` → `released`, with
when it was created, joined and released, the most sessions it ever ran, and
what it still held when it went. A placement that finds no eligible fixed
machine (`NO_ELIGIBLE_NODE`) asks for one — the refusal says so — and the
controller's next tick (`CCQUOTA_FLEET_SPOT_TICK_SECONDS`, 30) mints a join
code good for the boot window and creates the pod with it in its environment.
A pod that has not joined by the boot window, or a node whose heartbeats
stop for that long, is deleted. Only an `online` node is a placement
candidate; its score is multiplied by the weight, so a fixed machine with room
always wins. When a node is gone — released, failed, or simply not there any
more — the roster row is dropped, the endpoint retired (its token stops
working) and the record closed; it never lingers as 失联.

**Reclaim.** The cloud taking the machine reaches the pod as the kubelet's
SIGTERM. An ephemeral agent then `POST /v1/node/reclaim` (its own token) —
placement avoids the node from that moment — and runs claude-fleet's
`bin/fleet-spot-evacuate.sh` (`CCQUOTA_FLEET_RECLAIM_CMD` overrides;
`CCQUOTA_FLEET_RECLAIM_SECS`, 240, bounds it): `fleet-move.sh --rebalance
--max all` per fleet, the ordinary hub move, so every idle session lands on
another machine; a session mid-turn is never cut. When the pod is gone the
hub lets every lease the node still held go **at once** — the 30-minute lost
TTL is for a machine that may come back, and this one will not — records the
sessions that were still on it (意外下线), and re-dispatches nothing, as for
any lost node.

| Route | Auth | What |
|---|---|---|
| `GET /v1/fleet/spot` | operator | the `spot` block on its own |
| `POST /v1/fleet/spot {action: start\|release, id?, reason?}` | operator (same-origin) | start a node now (the `/nodes` page's button), or release one |
| `POST /v1/node/reclaim` | the node's token | "the cloud is taking me": `{id, state, grace_seconds}` |

Every step is a `fleet_audit` row (`hub:spot`, `spot_start` /
`spot_online` / `spot_release` / `spot_reclaim` / `spot_lease_release` /
`spot_released`), and the `/nodes` page's **SPOT 节点** block shows the live
nodes and the last few records as a timeline — 起 → 报到 → 释放.

### A machine is going down — 维护中 (claude-fleet#1427)

A fixed machine's status was `online` or `lost`, both read off its heartbeats.
A planned outage needs a third word the heartbeat cannot say — up, staying up
for a while, and **nothing new should start here** — so that `fleet-move.sh
--rebalance` on it finds every idle session a better home and the sessions
still working there finish on their own. `maintenance` is that word, and it is
the operator's: the fleet setting `fleet.node_maintenance.<machine>` (the same
table as the node caps and the SPOT weight), holding `{since, reason, by}`, so
it survives the outage and a hub restart and the machine comes back 维护中 until
someone ends it — never a placement target the moment its agent reconnects.

| Route | Auth | What |
|---|---|---|
| `GET /v1/node/maintenance` | the node's token | `{machine, status, maintenance: record\|null}` for its own machine |
| `POST /v1/node/maintenance {action: enter\|leave, reason?}` | the node's token | flag / clear its own machine (`bin/fleet-node-maintenance.sh`) |
| `PUT /v1/fleet/settings {key: fleet.node_maintenance.<m>, value: reason\|""}` | operator | flag / clear any machine (the `/nodes` card's button) |

Where it is read: the roster (`/v1/nodes`: node and machine `status`
`maintenance`, with the record), `fleet_sessions` (`availability`, which the
sidebar's machine line draws as `◐ m5 维护中`), placement (`judge` excludes it,
for `auto` and for a start that names it — unlike not-ready, this is a decision
about the machine, not a report from it), `move plan` (so rebalance moves
everything off), and `/v1/fleet/home` (`fleet connect` lands elsewhere; a 维护中
machine is picked only when no other is online, and the reason says so). Lost
still wins: a flagged machine whose heartbeats stop is `lost`, and its leases
lapse on the 30-minute TTL as for any lost node. Every change is a `fleet_audit`
row (`node_maintenance`, actor `operator` or `node:<user>@<machine>`, outcome
`ENTER: <reason>` / `LEAVE` / `ALREADY: …` / `NOT_FLAGGED`). No setting ⇒ two
words, as before (`TestMaintenanceOffAddsNothing`). The runbook is
claude-fleet's `docs/MULTI-MACHINE-OPS.md`.

### The SSH relay — SSH through the hub when nothing else reaches (claude-fleet#1413)

(Not the node-to-node message relays of claude-fleet#1421 above: everything
here is named `ssh_relay` / `fleet_ssh_relays` to keep the two apart.)

When the direct routes to a machine fail (the home LAN is out of reach, the
tailnet is down, the gateway port is closed), the hub is still reachable and
every machine already holds a link open to it. The relay carries an SSH
connection over that path:

```sh
ssh -o ProxyCommand='fleet connect --proxy m4' m4
```

`fleet connect` (`bin/fleet` → `bin/fleet-connect.py`, standard-library
Python, nothing else to install) opens a WebSocket to `/v1/ssh-relay/connect?node=m4`;
the hub sends a `ssh_relay_open` down one of m4's control channels; that agent dials
a second WebSocket back to `/v1/node/ssh-relay` and splices it onto m4's own sshd at
`127.0.0.1:22`. The hub copies bytes between the two and never decrypts them —
SSH runs end to end, and m4's sshd still decides who logs in. The agent opens no
listener: both its connections are outbound, and the local one is loopback only.
An agent offers this with the `ssh_relay` hello capability, on by default with the
fleet module; `CCQUOTA_FLEET_SSH_RELAY=0` on the agent turns it off.

Who may ask (checked by the hub; sshd checks again):

| credential | how the client sends it | reaches |
|---|---|---|
| viewer token, an admin's GitHub session | `FLEET_HUB_TOKEN` (bearer) / the cookie | any machine (the operator) |
| a user's GitHub session | the session token as `FLEET_HUB_TOKEN`, or the cookie | only machines where the hub opened them an **active** login |
| connection certificate (C5, #1412) | `~/.ssh/fleet-cert` + `-cert.pub`, proven by signing the hub's nonce with `ssh-keygen -Y sign -n fleet-relay@claude-fleet` | same as a session |

A certificate must be a user certificate signed by the hub's own CA
(`CCQUOTA_FLEET_SSH_CA_KEY`, claude-fleet#1412) or a key listed in
`CCQUOTA_FLEET_SSH_CA_PUB` (a file of CA public keys — e.g. one being rotated
out), valid now, with key id = `person:<principal>` (as `fleet login` gets it;
everything after the prefix is read, `gh:<id>` and all) and the hub-minted
login among its principals. The hub URL comes from `--hub`, `FLEET_HUB_URL`, or
`{"url": …, "token": …}` in `~/.config/claude-fleet/hub.json`.

Limits are per person, across all their relays: `CCQUOTA_FLEET_SSH_RELAY_MAX`
concurrent (default 8) and `CCQUOTA_FLEET_SSH_RELAY_RATE_BPS` bytes/second both ways
(default 4 MiB/s; `-1` unlimited). Every relay is a row in `fleet_ssh_relays` —
who, which machine, through which login's agent, start, end, bytes each way,
and why it ended — written when it is admitted and again when it closes;
`GET /v1/fleet/ssh-relays` (operator only) lists the newest 200. When an agent's
control channel drops, every relay it carried is closed at once: the client
sees its SSH session end instead of a stream that silently stops.

### `fleet connect` picks its own route (claude-fleet#1414)

`fleet connect` with no `--proxy` needs no address at all:

```sh
fleet connect            # the machine you used last, else the hub's first
fleet connect m4 -v      # print the measurement table and the choice
```

It asks the hub `GET|POST /v1/fleet/routes` for the machines the caller may
reach and every way into each, measures each route with 3 TCP connects that
must read an `SSH-` banner (the relay counts too, up to the far sshd's banner),
and ssh's in over the winner — most handshakes answered first, lowest median
latency next — with `HostKeyAlias=fleet-<alias>` so every route checks the same
host key. The interactive login on the far side attaches the fleet. The choice
is cached for 10 minutes in `~/.cache/claude-fleet/connect.json`; within that
window one handshake re-checks it, and a route that has gone dark makes the
next run measure everything again. Knobs (client env): `FLEET_CONNECT_PROBES`
(3), `FLEET_CONNECT_TIMEOUT` (4s), `FLEET_CONNECT_CACHE_SECS` (600). If the hub
cannot be asked, the routes come from `~/.ssh/fleet-ssh-config` (`fleet login`'s
snippet), without the relay.

The route list is the hub's `CCQUOTA_FLEET_ROUTES` merged with what each node's
heartbeat advertises (`routes`); the static list comes first and wins by route
name. Each machine also carries `relay: true` while an agent there can carry a
relay. The list admits the same credentials as the relay — a certificate proves
itself by signing `fleet-routes <unix-seconds>` with `ssh-keygen -Y sign -n
fleet-routes@claude-fleet` (POST `{"cert","sig","ts"}`, accepted within 5
minutes of the hub's clock) — and filters to the caller's machines. The same
merged list feeds `fleet login`'s ssh config and the 连接 page.

| env | where | what |
|---|---|---|
| `CCQUOTA_FLEET_NODE_ROUTES=public=gw.example.com:22023,lan=192.168.1.20` | agent | this machine's ways in, advertised in every heartbeat (a gateway's public port lives on the gateway, so the operator writes it here) |
| `CCQUOTA_FLEET_NODE_TAILNET=0` | agent | stop advertising the local tailscaled's name for this machine as the `tailnet` route (on by default; skipped when `NODE_ROUTES` already names a `tailnet`) |

## The dashboard

One page, no tabs — with a nav bar across the top of it. Those are not in
tension, and the distinction is the whole design: the bar scrolls you to a
place on this page, it does not switch you between pages. Tabs used to split
the dashboard into regions that fetched and refreshed on their own rhythms,
and that split was wrong — "what is burning right now" and "what did this
period cost" are one question at two time scales, so picking a tab meant
picking half an answer. One surface, one refresh loop, labelled bands:
**Ledger** (what was paid) · **Usage** (what drove it) · **Operations**
(machines, collection health, sessions — folded by default). The nav names
them, and highlights the one you are reading.

It still reads top to bottom: what this actually cost, what is running right
now, every model that ran and what it cost, then the analysis and the fleet.

![the usage half: timeline and selection totals](docs/img/usage.png)

<sub>Drag the timeline selection and every card below it re-reports on that
span. Each tile is compared with the equal-length period right before it.</sub>

The headline figure is the **subscriptions** — what bills monthly whether or
not a token is spent — with the API-equivalent ("notional") token figure
printed beside it and explicitly outside it.

## HTTPS, with a name you can remember

```bash
ccquota hub --https-addr :443
```

The hub gets a real certificate for this node's MagicDNS name from
`tailscale cert` (Let's Encrypt, via Tailscale's DNS challenge), serves it
directly, and renews it every 12 hours. The dashboard becomes
`https://<node>.<tailnet>.ts.net/` — no port, no proxy, and the tailnet-identity
gate above still sees the real peer.

`:443` is the wildcard on purpose: macOS lets an unprivileged process take a
privileged port on `0.0.0.0` but not on a specific address (measured). The
listener stays tailnet-only regardless — any peer that is not a tailnet address
or loopback is closed at accept, before TLS begins. HTTPS must be enabled on the
tailnet (admin console → DNS → HTTPS Certificates); the hub says so and refuses
to start otherwise.

## Badges

Render your totals as a badge. Entirely local — no server, no account, nothing
submitted anywhere:

```bash
ccquota badge --out ccquota.svg --theme dark --period all
ccquota badge --size compact --out ccquota-sm.svg   # 20px, sits beside shields badges
ccquota badge --style flat --out ccquota-flat.svg   # static, shields-shaped
ccquota badge --json --out ccquota.json             # shields.io endpoint schema
```

The default badge is **tokenman**: a character eats a stream of dots, and an
odometer rolls up to the **exact** count — every digit, not "69.8B". The dots
*are* tokens, so the animation carries the meaning rather than decorating it.

**It animates inside a README.** An `<img>`-loaded SVG cannot run scripts, but
it does run CSS keyframes and SMIL — measured, not assumed. Everything here is
CSS inside the SVG's own `<style>`: no script, no font, no fetch. Readers with
`prefers-reduced-motion` get the finished figure statically — the resting state
*is* the final value, and the roll animates *from* zero, so nothing is ever
wrong with animation off.

The compact size is 20px tall and sits in a row of shields badges without
looking like a visitor. `--style flat` is the plain two-tone badge for anyone
who wants no motion at all.

### Fitting the host

- **`theme=auto`** — one SVG carrying both palettes, switched by
  `prefers-color-scheme`. An `<img>`-loaded SVG *does* evaluate it (measured),
  and follows the reader's OS/browser scheme. The one place that is not
  enough is GitHub, whose own dark/light toggle can disagree with the OS —
  there, keep the `<picture>` pattern above.
- **`bg=transparent`** — no ground; the host's own background shows through.
  With `theme=auto`, the badge sits on anything.
- **Colours** — `pac=`, `dot=`, `fg=`, `bg=` take a hex value without `#`.
  A bad value is ignored, never an error badge.

### Is it live?

Depends on the embed, and the reason is structural:

| Embed | You get |
|---|---|
| `<img>` — README, Markdown, anywhere that only allows images | **Current at fetch time**, refreshed by the cache TTL (`max-age=300`, the same as shields.io; GitHub's camo re-pulls within minutes). It does **not** tick while you watch: an image is a snapshot and cannot re-fetch itself. |
| `<iframe>` — your site, a docs page, a wiki, a wallboard | **Truly live.** `/embed/u/<login>` polls the raw figure (every 30s; `?every=`) and, only when it has actually *changed*, swaps in a badge rendered `?from=<the previous value>` — so the wheels roll the real difference, position by position, as many turns as each one carried. |

```html
<iframe src="https://hub.example/embed/u/verkyyi?theme=auto&bg=transparent"
        width="400" height="60" frameborder="0" title="Claude Code tokens"></iframe>
```

Nothing is extrapolated. If the hub has not measured a new number, nothing
moves except the character. `?from=` works on the plain SVG too — a wallboard
that re-fetches the badge every minute can pass the last value it showed.

`/badge/u/<login>.json?format=raw` is the figure the embed polls:
`{"tokens":…,"turns":…,"period":"30d"}`, never cached, behind the same
`hub.public_badges` gate as everything else here.

**Publishing is up to you, and every route is serverless.** Which one works is
decided by the content-type the host serves, so these were measured rather than
assumed:

| URL | Content-Type | Usable as a README image |
|---|---|---|
| `raw.githubusercontent.com/<you>/<you>/main/ccquota.svg` | `image/svg+xml` | yes |
| `gist.githubusercontent.com/.../raw` | `text/plain` | no — fine as shields *data*, not as the image |
| `img.shields.io/endpoint?url=<your json>` | `image/svg+xml` | yes, from a URL you supply |

So: commit the SVG to your profile repo and link it, or write the JSON to a gist
and point shields at that.

**Light and dark take two URLs**, not one adaptive badge. An SVG loaded through
`<img>` is a sandboxed context — no scripts, no external fonts, no CSS, no
network — `prefers-color-scheme` inside one is inconsistently supported, and
GitHub's camo proxy caches a single copy for every reader. So the theme is an
explicit flag and READMEs use the `<picture>` pattern:

```html
<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".../ccquota-dark.svg">
  <img alt="ccquota" src=".../ccquota-light.svg">
</picture>
```

**A badge is not live.** camo caches it, so it carries a period label (`all`,
`30d`) and never a timestamp — a timestamp would sit on your profile being
wrong for a week.

### Serving badges from your own hub

`fleet hub set hub.public_badges on` makes the hub serve `/badge/u/<login>.svg` and
`/badge/team/<team>.svg` (`?theme=dark|light|auto`, `?period=all|30d|7d`,
`?size=full|compact`, `?style=tokenman|flat`, `?bg=transparent`, `?from=`,
colour overrides; `.json` for shields data, `.json?format=raw` for the bare
figure) and the live `/embed/u/<login>` page without a viewer token, which is what makes them usable
in an internal README: a README image sends no credential, and camo strips
cookies.

It is **off by default**, and it exposes the badge routes only. `/v1/user`, the
dashboard, the query API and MCP all stay behind the viewer token — turning this
on does not publish per-person cost data, only the two figures a badge shows.

An unknown handle returns 404 with a badge that says so, never a zeroed one:
"0 tokens" reads as "this person spent nothing", which is a different claim
from "there is no such person here", and a false one.

## Teams

Allocate a machine's spend to a team:

```bash
ccquota team --list
ccquota team --endpoint <endpoint-id> --set platform
ccquota team --endpoint <endpoint-id> --set ""     # un-assign
```

![ccquota team --list and ccquota plan --list](docs/img/cli.svg)

Teams are assigned **here, on the hub**, and are never reported by an endpoint:
a machine that could name its own team could move its spend onto another team's
budget. Team is resolved when a query runs rather than stamped on each turn, so
re-assigning a machine moves its **whole history**, not just what it does next.

The dashboard's hero — the all-time count that only ever grows — is the
tokenman odometer, live: the character eats the dot stream while the fleet is
reporting and stops when it goes quiet, and the wheels follow the projected
count between measurements (a wheel that changes faster than it can roll
simply spins).

Once any team is assigned, team becomes a choice for the two breakdown
cards' group-by (`g1`/`g2` in the URL), alongside project, login, machine,
model and branch — not something the dashboard leads with. An OS login in
the sessions table is a chip link that filters the current view to that
person, not a link to a page; the old `/u/<login>` page is gone
(claude-fleet#1989) — a user's own figures are the app's Overview. Both are
deliberately unnumbered. Read as a per-person performance ranking, an internal usage board
fails by Goodhart — people avoid the tool or pad their usage — and either
outcome destroys the cost data it exists to provide.

## What the subscriptions actually cost

The hub can observe everything except the one number on the invoice. No
transcript attests to what a plan costs, so an operator has to say:

```bash
ccquota plan --set max --monthly 200                    # from now on
ccquota plan --set max --monthly 250 --from 2026-10-01T00:00:00Z   # a price change
ccquota plan --list                                     # every price, current and superseded
ccquota plan --spend --days 30                          # real, billed spend
```

Prices can also be declared in the `--pricing` overrides file that `ccquota
hub` already takes, under a `plans` key — the same place the per-token rate
overrides live, recorded into the database on every start:

```json
{"plans": [{"plan": "max", "source": "claude", "monthly_cost": 200,
            "currency": "USD", "effective_from": "2026-01-01T00:00:00Z"}]}
```

**No amounts ship in this repo.** A subscription price varies by region, seat
count and negotiation, so a built-in table would be wrong for most hubs while
looking authoritative on all of them. The per-token rates have defaults because
they are published; these cannot.

Three things this is careful about:

**It is real money.** It is the only real money the hub holds — see
[Two kinds of money](#two-kinds-of-money-never-one-number). The `cost_usd`
figure on `claude` and `codex` is *notional* — what the tokens would have cost
at API rates — and is explicitly not an invoice. Subscription spend must
**never** be added to the notional figure, and there is a test that fails if recording a price moves any
notional aggregate by a cent.

**Prices are effective-dated and appended, never overwritten.** A single column
on the account would rewrite history on every price change: last month's
figures would silently be recomputed at this month's price. Recording a change
closes the old period and opens a new one, so each period stays priced at what
it actually cost. Re-recording an existing start date corrects that period's
figure; a date *behind* an existing one is refused rather than producing
overlapping periods that double-count.

**Seats are counted, not stored.** How many accounts were on a plan comes from
the accounts themselves at query time. A stored count drifts the moment
somebody is added and still looks authoritative.

A plan nobody has priced is reported as **unpriced**, never as free — same rule
as an unpriced model's `cost_usd`. `--spend` lists it with its seat count and
says the total is low by however much it costs, rather than quietly handing
back a number that is wrong in the one direction nobody checks.

## Scheduling against your own quota

A dispatcher that spawns Claude sessions on a timer needs a verdict it can
branch on, not a page to read. `ccquota budget` is that verdict:

```bash
ccquota budget                 # headroom on the subscription this machine uses
ccquota budget --account all   # every subscription the hub knows about
ccquota budget --json          # the whole report, for a program
ccquota budget --gate          # exit 0 to proceed, 3 to hold; reason on stderr
```

The default scope is **the account this machine is logged into**, because that
is what work started here will spend — headroom on a subscription this machine
cannot reach is not headroom. The tighter of the two windows governs: a calm
five-hour window means nothing if the weekly one is nearly spent, and the weekly
one is the expensive mistake.

**Unknown is never a hold.** If the hub is unreachable, or no endpoint could read
the limits, the gate OPENS and says why on stderr. A monitor that silently halts
the work it exists to observe is worse than one that admits it cannot see.

ccquota stays **read-only** here too: it reports whether there is room, and the
caller decides what to do. Giving a monitor a control channel back to every
machine it watches is a much larger security surface than "tell me what my fleet
spent", and the scheduler knows its own priorities better anyway.

**Per-model caps are reported, not judged.** Some models carry a weekly cap of
their own on top of the account's windows — the Fable limit, which the rate-limit
headers call `7d_oi`. `budget --json` lists every such cap per account, keyed by
the model it was read for, plus a ready-made gate:

```json
"models": {
  "claude-fable-5-1": {"claim": "7d_oi", "utilization": 100, "status": "rejected",
                       "resets_at": "2026-09-28T18:00:00Z", "observed_at": "…"}
},
"model_available": {"claude-fable-5-1": false}
```

A model cap never moves `headroom_pct` or the verdict: the subscription still
works, just not on that model. A model missing from `models` is **unknown**, not
uncapped — the cap is only visible to an agent probing that model (see
`--probe-model` below).

[claude-fleet](https://github.com/verkyyi/claude-fleet) consumes exactly this,
through its own `fleet-quotaguard.sh --gate`; it runs fine without ccquota
installed.

## MCP

Point any MCP client at `https://your-hub/mcp` with the viewer token as a bearer.

```json
{ "mcpServers": { "ccquota": {
  "type": "http",
  "url": "https://ccquota.example.com/mcp",
  "headers": { "Authorization": "Bearer <viewer token>" }
}}}
```

Twenty-seven read-only tools: `list_accounts`, `get_limits`, `get_limits_history`,
`list_endpoints`, `usage_by_source`,
`usage_by_account`, `list_account_switches`, `list_endpoint_accounts`,
`usage_by_endpoint`, `usage_by_user`, `usage_by_project`, `usage_by_session`,
`usage_by_model`, `usage_by_team`, `usage_by_branch`, `usage_by_effort`, `usage_by_entrypoint`,
`usage_history`, `usage_summary`, `list_sessions`, `get_session`, `get_user`,
`get_findings`, `get_collectors`, `get_account_usage`, `get_live`, `quota_history`.

**Every axis the HTTP API can group by, MCP can group by too.** They went out of
step once: `team`, `branch`, `model`, `effort` and `entrypoint` were reachable as
*filters* over MCP but had no `usage_by_*` tool, so an agent asked "what did each
team spend this week" — one of the questions an agent most ought to be able to
answer — could only narrow to a team it already knew the name of. `usage_summary`
carries the effort and entrypoint splits that `GET /v1/summary` has always
returned, for the same reason: those two are the only axes with no chip to filter
on, so a missing split left them unreachable rather than merely inconvenient.

The asymmetry ran the other way too, and `GET /v1/quota/history` closes it: the
provider-defined quota windows were reachable from the dashboard and from MCP,
but over HTTP only as the `quota_series` key folded inside `/v1/limits/history`
— so an API caller who wanted the windows had to fetch every subscription's
utilization series to get at them. `/v1/limits/history` keeps its folded copy:
the dashboard draws both on one axis, and splitting that into two round-trips
would let the halves straddle a refresh.

What stays deliberately one-sided: `/badge/*` and `/embed/*` are public-facing
renderings and have no MCP tools; and `/v1/live/stream` is a stream,
which this server does not open (see the GET handler). MCP is read-only
throughout — the hub's two viewer-facing writes, `POST /v1/accounts/label` and
`POST /v1/findings/mutes`, have no tools and will not grow any. The second one
is why that matters more than it used to: an agent that could silence the
fleet's alerts on its own initiative is not a capability anyone asked for.
`get_findings` reports a finding's `id` and its `muted` state, so an agent can
*see* what a person silenced and say it should be lifted — the lifting is a
person's click.

### Saying "I know" about an alert

A `critical` finding used to come back on every page load, for as long as the
window contained it, with no way to acknowledge it. It could not be otherwise:
findings are recomputed on every read and had no names, so there was nothing to
attach an acknowledgement to.

Every finding now carries a stable `id` — the same problem computes the same id
on every request — and `POST /v1/findings/mutes` records the one thing that
cannot be recomputed: the operator's judgement.

```sh
curl -s https://your-hub/v1/findings/mutes \
  -H "Authorization: Bearer $VIEWER_TOKEN" \
  -d '{"id":"3f9a1c04be21","kind":"stale_agent","hours":24,"note":"box is in the shop"}'
```

Three rules make the silence safe to give out:

**It expires.** There is no permanent mute, and `hours` is clamped to 30 days.
A permanently muted alert is a deleted alert nobody remembers deleting: the
condition stays true, the card stays quiet, and months later no one can say why
that rule never fires. The worst case of an expiry is being told again about
something already handled, which costs one click.

**It is still visible.** Muted findings are not dropped from the response or
from the page — they are ranked after the live ones and folded, with the time
remaining and who silenced them. An alert that vanished when silenced would be
indistinguishable from one that cleared.

**An escalation breaks through it.** Severity is part of the identity, so a
5-hour window silenced at 78% speaks up again when it crosses 90%, and a mute
on the "80% of the free allowance" warning does not cover the "allowance is
gone" critical. "I know it is warm" is not consent to be surprised by it
running out.

The `maxFindings = 8` cap now applies per tier: the live findings are capped as
before — a muted finding gives up its slot, which is what silencing it was for
— and the muted ones follow under their own cap. So muting makes room without
deleting anything.

Read-only is deliberate. A monitor that could also pause endpoints or change
quotas needs a control channel back to every machine — a far larger security
surface than "tell me what my fleet spent".

## How it works, and what that costs you

**Two numbers, kept apart.** The agent reads
`https://api.anthropic.com/api/oauth/usage` with the endpoint's own credentials.
That figure is exact and already covers every device on the account. Separately,
it parses `~/.claude/projects/**/*.jsonl` for per-machine, per-project spend. The
hub combines them:

```
endpoint_share ≈ (endpoint_weighted_spend / total_weighted_spend) × exact_utilization
```

The total is exact. **The split is an estimate** and every surface says so.

**The hub never holds an OAuth token.** Agents call Anthropic themselves and push
only the resulting numbers, so a compromised hub leaks usage statistics — never
account access.

**The agent never refreshes your Claude token.** If it has expired the agent says so and
keeps reporting token counts. Refreshing would race Claude Code's own refresh and
could log you out of the thing being monitored.

## Known limits — read these

**The usage endpoint is undocumented.** `/api/oauth/usage` is not a public API. It
will change or disappear. When it does, the gauges *vanish and say why*; they
never keep showing a stale percentage. A contract test pinned to a recorded
response is the tripwire.

**Account attribution has a seam that cannot be repaired.** Transcripts record no
account. The agent stamps the account at scan time from `~/.claude.json`. If a
machine logs out and into a different account, rows already ingested keep the old
attribution. ccquota records the switch so the seam is visible in the UI rather
than silently wrong — but it cannot retroactively fix history.

### Watching a subscription nothing is using

Utilization has two free sources and both have gaps. The credentials API needs a
token with the `user:profile` scope — only an interactive login has one, and it
expires on a machine nobody uses. A session's statusLine reports its own
account, which covers a subscription only while someone is working on it.

A token from `claude setup-token` cannot call the usage endpoint at all:

```
403  OAuth token does not meet scope requirement user:profile
```

but the same token receives full rate-limit headers from an ordinary inference
call. The scope gate is on the endpoint, not on the numbers. So point one agent
at a directory of tokens:

```bash
ccquota agent --accounts-dir ~/.config/claude-fleet/accounts   # label -> token, one file each
```

A per-model cap only shows up on a response to a request **for that model** —
ask for Opus and the Fable window is simply absent. To keep one fresh when no
session happens to be using it, name the model:

```bash
ccquota agent --accounts-dir ~/.config/claude-fleet/accounts --probe-model claude-fable-5-1
```

Each account is then probed with that model instead of the default one. A capped
account answers with a 429, which costs nothing; an uncapped one costs a single
output token of that model. Every `anthropic-ratelimit-unified-<claim>-*` window
beyond the account's own 5h/7d is recorded, whatever its name, because the header
is undocumented and a renamed claim must not make the cap invisible.

Those headers are **account-wide**, not per-connection: read one account through
two different credentials at the same moment and the endpoint says 18.0% / 4.0%
while the headers say 0.17 / 0.04 for the same reset instants — the same numbers,
in different units (the endpoint is a percentage, the header a fraction).

**A reading costs an inference call**, so measuring the meter moves it. It is
opt-in, runs only for a subscription nothing cheaper observed this cycle, and at
most once per five minutes. Run it on ONE always-on agent: the cost is per agent,
and six agents probing the same three accounts is six times the price of the same
answer.

**Utilization is only known where a session runs.** Anthropic reports current
utilization, never past utilization, so there is no history to fetch — ccquota
knows only what it sampled. It reads that two ways: from the credentials API on
a machine logged into the account, and from the rate limits Claude Code puts in
every session's statusLine. The second needs no credentials and works when a
machine's stored token has expired, which on an idle machine it eventually has.
Neither can observe a subscription that nobody is currently using.

**A subscription with no login is identified by a guess.** A session's own
statusLine reports its rate-limit windows, so a subscription that has never been
logged in on a monitored machine is identified by the phase of its **seven-day**
reset. Only that window: the five-hour one is *rolling* — its reset moves as old
usage ages out, measured here going 18:40 → 22:49 in one step — so its phase is
not a property of the account and using it split one subscription into three
within a day. Two subscriptions collide if their weekly resets land in the same
minute (~1 in 10,000 per pair); such accounts are marked inferred, never
overriding a reported uuid, and `ccquota name --dedupe` folds any duplicates
that a past version created.

**Collection reacts to writes, and falls back to a timer.** The agent watches
the transcript directory and scans within a second of a write; the scan interval
(15s) is the fallback for events a watch can miss — an overflowed queue, a
network filesystem, a directory created before the watch covered it. A missed
event under a watch-only design would not degrade collection, it would end it
silently for that file.

**The hero counter is projected between measurements.** Nothing emits usage per
token: a transcript records a turn when it ENDS, and a statusLine reports a
session's running totals when it redraws, so the finest real granularity is a
turn arriving up to a minute late. The big number counts forward at the measured
growth rate and re-anchors on each measurement — hence the `~`. It never
decreases, and it stops entirely (and dims) once nothing has been recorded for
90 seconds, because a counter still climbing over a dead fleet is the one way
this could genuinely mislead.

**Per-endpoint shares are proportional estimates.** They assume Anthropic's
utilization tracks weighted spend. Good enough to find the machine eating your
week; not a settlement.

**Costs are notional.** On a Pro or Max plan nobody is billed per token. The
dollar figures answer "what would this have cost at API rates" — useful for
ranking endpoints against each other, misleading read as a bill. Rates live in
`internal/pricing` and are overridable with `--pricing`.

### Two kinds of money, never one number

`cost_usd` is the notional figure, and the one kind of real money is not in that
column at all, so **no surface in this hub reports a single blended cost
figure.** There are two:

| | what it is | billed? | where it lives |
|---|---|---|---|
| **subscription spend** | what the plans cost per month | **real** | `subscription_plans`, `ccquota plan --spend`, `subscription_spend` in the API |
| **notional token cost** | "what this would have cost at API rates" (`claude`, `codex`) | no | the `notional` entries of `cost` |

Real spend is the **subscriptions**. The notional figure is not a term in it,
and adding it in invents spending that never happened.

Every aggregate returns cost as a *list*, one entry per source, each carrying
the kind of money it is:

```json
"cost": [
  {"source": "claude",  "kind": "notional", "events": 812, "cost_usd": 41.20, "unpriced_events": 0},
  {"source": "codex",   "kind": "notional", "events":  93, "cost_usd":  6.05, "unpriced_events": 4}
],
"cost_notional": 47.25,
"real_spend": {"currency": "USD", "subscription": 200, "total": 200, "complete": true}
```

`GET /v1/summary` adds `pricing` — one entry per source with its own
`rates_as_of` and the note saying what that source's figure is — and
`subscription_spend` for the same period. The MCP tools say the same in their
descriptions.

The one aggregate that carries a plain `cost_usd` is a **session row**: sessions
are grouped by source, so each row is a single kind of money and says so in
`source` / `cost_kind`. Ranking by cost still works; nothing sums the column.

Two tests keep this true rather than conventional, because a blended aggregate
returns a plausible number and fails silently:
`TestNoCostAggregateCrossesSources` checks every read path against per-source
arithmetic, and `TestEveryRawCostSumDeclaresItself` fails the build if a new
`SUM(cost_usd)` appears in the store without either going through the source
split or stating in the SQL why its `GROUP BY` already covers it.

## A rate you add today does not reach yesterday's events

Pricing happens at **ingest**: an event's `cost_usd` is computed when it arrives
and stored on the row. So filling in a contract you could not state last month
prices only the events that arrive from now on — the month you already have stays
`unpriced`, and in every total that skips it, unpriced is indistinguishable from
free. `--rebuild-rollup` does not help: it refolds the per-event figures already
stored, so it faithfully rebuilds the same stale money.

To apply the table as it stands now to events already in the database:

```bash
ccquota hub --reprice                                  # every event
ccquota hub --reprice --reprice-since 2026-09-01T00:00:00Z   # just this month
```

It recomputes each event's cost and price basis, then refolds the rollup in the
**same transaction** — between rewriting an event and refolding its hour there is
a state where the raw rows and every dashboard disagree about money, and one
commit means that state is never observable. The flag is off by default: a hub
started without it reprices nothing.

Read the log line before trusting the run:

```
reprice: scanned 443452 event(s), changed 24926 (38 newly priced, 0 back to unpriced),
         net +0.007194 USD, largest single change 0.000589 USD, refolded 42248 hourly row(s)
```

`changed` is a row count and cannot tell a correction from a catastrophe, which
is why the net and the largest single move are printed beside it. In that run —
a real production snapshot — only 38 events gained a figure; the other 24,888
were rows stored by an older build whose arithmetic rounds a hair differently,
which is why the net is under a cent. A large `changed` with a near-zero net is
that; a large net is a rate that moved.

## Development

```bash
make test     # every package
make build    # ./bin/ccquota
make dist     # all five platforms
```

The dashboard is hand-written HTML/CSS/JS in `web/dist`, embedded via
`embed.FS`. There is no npm pipeline on purpose: a Go toolchain alone produces
the complete artifact.

Design notes are in `docs/superpowers/specs/`.

### Trunk and CI

TokenLedger lives in [claude-fleet](https://github.com/verkyyi/claude-fleet)
under `tokenledger/`; claude-fleet's `master` is the trunk, and it is what
`go install github.com/verkyyi/claude-fleet/tokenledger/cmd/ccquota@latest`
resolves to (there are no `tokenledger/v*` tags, so `@latest` follows the
default branch). Every Go / npm command in this README runs from inside
`tokenledger/` — it is its own Go module (`go.mod` is here, not at the repo
root).

`.github/workflows/tokenledger.yml` runs `test`, `web` and the four
`cross-compile` legs on a pull request or a `master` push **only when it
touches `tokenledger/**`** — the fleet's shell selftests, in turn, do not run
for a change confined to this directory.

### Docker image

The image builds from this directory — the Dockerfile's context is
`tokenledger/`, exactly as it was the old repo's root — after packing the client
`/install` serves (claude-fleet#1803: the repo keeps one copy of each client
file in `bin/` `conf/` …; `bin/fleet-client-pack.sh` copies the manifest's into
the gitignored `internal/api/fleetclient/pack/`, and the build refuses an empty
pack). Always pack in the same command, so an image never carries a stale one:

```bash
bin/fleet-client-pack.sh && docker build -t ccquota tokenledger/      # from the claude-fleet root
bin/fleet-client-pack.sh && docker build --build-arg VERSION=prod-$(git rev-parse --short HEAD) \
  --platform linux/amd64 -t <registry>/ccquota:<tag> tokenledger/
```

`go test ./...` here wants the pack too (CI runs the script first); a plain
`go build` without it compiles a hub that answers 503 on `/install`.

The production hub image is built and pushed by hand (the deployment manifest
lives in the operator's infra repo); nothing here pushes an image.

## License

MIT
