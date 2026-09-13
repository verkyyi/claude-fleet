# TokenLedger

> 命令、模块路径、数据库路径与环境变量**仍然是 `ccquota`** —— 这一版只换对外的产品名。
> 改标识符是另一件事（跨两个仓的 cutover），没做。

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
go install github.com/verkyyi/ccquota/cmd/ccquota@latest   # needs Go 1.25+
```

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
with a single source selector; accounts follow that selection. Usage, quota history, findings,
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
ccquota codex list                                     # email, plan, login state
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
every query is scoped to one account. With more than one on the hub, a query
that names none is **refused** rather than answered for whichever came first:

```
GET /v1/usage?by=endpoint
→ 400  this hub holds several subscriptions; pass ?account=<uuid> (see /v1/accounts)
```

The MCP tools behave the same way, returning an error that lists the available
accounts so the model can retry correctly instead of guessing.

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
`list_endpoint_accounts` and the "what each machine is running" card show. The
endpoint's own login (from `~/.claude.json`) is tracked separately, and only a
change of *that* is a switch.

If someone logs out and into a *different* account on a machine, ccquota records
the switch and shows it in the UI. Rows already ingested keep their old
attribution and cannot be corrected — see the known limits below. Two plans
running side by side is **not** a switch, and is not recorded as one.

## The dashboard

One page, no tabs. It reads top to bottom: what this actually cost, what is
running right now, every model that ran and what it cost, then the analysis
and the fleet.

The top-level axis is the **billing relationship**, not the product name.
There are two ways a deployment is charged — a subscription that bills monthly
whether or not a token is spent, and metered spend that bills per call — and
the headline figure is the sum of those two, with the API-equivalent
("notional") figure printed beside it and explicitly outside it.

`gateway` is not on that axis. It is the channel one of the metered sources
reports through, so it appears as a per-row attribute and in collection
health, not as a peer of the subscriptions. The consumption table is keyed on
**(provider, model)**: a gateway that fails over between vendors reaches one
model id through several upstreams at several contracted prices, and a row
keyed on the model alone would add two invoices together. Rows sort within a
billing kind, never across one — a metered charge and an API-equivalent
estimate are not comparable amounts.

## Showing it to someone else

The dashboard is not shareable. It carries account emails, project paths (which
are client names), machine names, OS logins, session ids and branches, and its
viewer token also opens the MCP server. There is no safe way to hand that to a
third party "just for the charts", and no way to take it back afterwards without
rotating it for everyone.

So a share link is a **separate, revocable credential onto a separate page**:

```bash
ccquota share --name "conference talk"      # prints the link once
ccquota share --list                        # what has been handed out, and its use count
ccquota share --revoke <id>                 # dead immediately
```

The public page shows tokens and turns over time, the model mix, live plan
utilization under pseudonyms ("Subscription A"), and **counts** of machines,
logins and projects — never their names. What it omits is the point:

| Shown | Never shown |
|---|---|
| tokens, turns, trend | account emails and uuids |
| model mix | project paths |
| plan utilization % | machine names, OS logins |
| how many machines/logins/projects | session ids, git branches |

This is enforced structurally rather than by filtering. The share token is
accepted **only** on the share routes, and those routes build their own object
from scratch — a field cannot leak in by being forgotten, only by being written
there on purpose. A test asserts the share token is rejected on every other
route, and another seeds a client name, a colleague's login and an unreleased
branch and asserts none of them appear.

**Notional costs are off by default** (`--with-costs` to include them). A dollar
figure shown to someone who does not know it is API-equivalent reads as a bill.
And `--with-costs` publishes the *notional* figure only: metered gateway
charges and subscription invoices — the hub's real spend — are never on a
public link at any setting. A recipient of a share link cannot ask what a
number means, so the strong promise is worth more than the caveat.

Add `--expires 720h` for a link that dies on its own.

## Tokenless on your own tailnet

```bash
ccquota hub --tailnet-viewers you@example.com,colleague@example.com
```

Named tailnet logins open the dashboard with **no token**. The hub asks the
local tailscaled (`tailscale whois`) who owns the peer a connection came from —
nothing in the request is trusted, so there is nothing to forge. Three rules
keep it honest:

- **An allowlist, not "anyone on the tailnet."** A tailnet routinely has shared
  users and tagged servers on it.
- **Tagged nodes are never people.** A tag means a server.
- **The hub's own tailnet address is never trusted.** It resolves to the
  machine's *owner*, so on a shared box every other OS login could be them.
  Connections from the hub's machine to itself, and over loopback, still need
  the token.

Everything else — the LAN, unknown peers, a whois error — is a 401, exactly as
if the feature were off. Lookups are cached for five minutes. The viewer token
keeps working everywhere (MCP clients, scripts), and identity-authenticated
requests show `viewer=<login>` in the access log.

macOS note: the application firewall silently blocks incoming connections to an
ad-hoc-signed hub when nobody is at the screen to click *Allow*, and an ad-hoc
signature changes with every build. After each upgrade:
`sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add <path> && sudo … --unblockapp <path>`.

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
`--public-badges` gate as everything else here.

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

`ccquota hub --public-badges` serves `/badge/u/<login>.svg` and
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
person, not a link to a page; `/u/<login>` still exists and still renders a
per-person view, but is now a direct-URL surface only — reachable by typing
it or an old bookmark, not by clicking anything in the dashboard. Both are
deliberately unnumbered. Read as a per-person performance ranking, an internal usage board
fails by Goodhart — people avoid the tool or pad their usage — and either
outcome destroys the cost data it exists to provide.

## What the subscriptions actually cost

The hub can observe everything except the one number on the invoice. No
transcript attests to what a plan costs, so an operator has to say:

```bash
ccquota plan --set max --monthly 200                    # from now on
ccquota plan --set max --monthly 250 --from 2026-10-01  # a price change
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

**It is real money.** Together with metered gateway charges it is the only real
money the hub holds — see [Three kinds of money](#three-kinds-of-money-never-one-number).
The `cost_usd` figure on `claude` and `codex` is *notional* — what the tokens
would have cost at API rates — and is explicitly not an invoice. Subscription
spend may be added to a metered gateway bill; it must **never** be added to the
notional figure, and there is a test that fails if recording a price moves any
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

Twenty-one read-only tools: `list_accounts`, `get_limits`, `list_endpoints`, `usage_by_source`,
`usage_by_provider`, `usage_by_account`, `list_account_switches`, `list_endpoint_accounts`,
`usage_by_endpoint`, `usage_by_user`, `usage_by_project`, `usage_by_session`,
`usage_history`, `usage_summary`, `list_sessions`, `get_session`,
`get_findings`, `get_collectors`, `get_account_usage`, `get_live`, `quota_history`.

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

**Except on the `gateway` source, where the cost is real.** That source is an
OpenAI-compatible gateway fronting non-Anthropic vendors on a pay-per-call
contract, so its `cost_usd` is an actual charge rather than an estimate. Two
consequences: **never add a gateway total to a Claude or Codex one** — same
column, different kinds of money — and gateway rates ship with no built-in
values at all, because a price is a contract term this build cannot know. State
them in the `--pricing` file, in the currency the vendors publish:

```json
{
  "gateway": {
    "rates_as_of": "2026-09-12",
    "cny_per_usd": 7.09,
    "cny_per_usd_as_of": "2026-09-12",
    "price_source": "https://internal.example/gateway/pricing",
    "models": { "vendor-large": { "input": 7.0, "output": 70.0 } },
    "providers": {
      "dashscope.aliyuncs.com": {
        "label": "阿里云百炼",
        "models": { "qwen-plus": { "input": 0.8, "output": 2.0 } }
      },
      "ark.cn-beijing.volces.com": {
        "label": "火山方舟",
        "models": { "deepseek-v4-flash": { "input": 0.5, "output": 1.5 } }
      }
    }
  }
}
```

A gateway that fans out to several upstreams reaches the same model id at more
than one contracted price, and failover decides which one served any given
call — so a rate keyed on the model alone prices some calls at another
vendor’s number. State each contract under `providers`, keyed by the provider
string the reporting side sends (this deployment sends the upstream hostname).

`models` at the top level still means **this price holds whoever serves it**,
and answers only what a provider left unsaid: a provider block is authoritative
for the models it names. `label` is display only and never affects a rate.
Every priced event’s `price_basis` names the contract it used.

Rates are **CNY per million tokens**, input and output only — the source
carries no cache breakdown. They are converted to USD at `cny_per_usd`, a
pinned constant rather than a live feed: a rate that moves on its own restates
every historical figure each morning, which is worse than being slightly stale.
Nothing here is dateless — an undated rate or conversion is rejected at load,
and every priced event's `price_basis` names the rate, the conversion and both
dates. A model with no configured rate stays unpriced and says so. Correcting
one entry never drops the others.

### Three kinds of money, never one number

Because `cost_usd` means two different things depending on source, and a third
kind of money is not in that column at all, **no surface in this hub reports a
single blended cost figure.** There are three:

| | what it is | billed? | where it lives |
|---|---|---|---|
| **subscription spend** | what the plans cost per month | **real** | `subscription_plans`, `ccquota plan --spend`, `subscription_spend` in the API |
| **notional token cost** | "what this would have cost at API rates" (`claude`, `codex`) | no | the `notional` entries of `cost` |
| **gateway cost** | metered per call | **real** | the `billed` entries of `cost` |

Provider is a grouping axis *inside* the billed kind, never a fourth kind of
money. `usage_by_provider` (and `?by=provider`) returns the same per-source
`cost` split as every other breakdown. An empty provider is the reporting side
declaring none — Claude transcripts carry no upstream, and rollup rows
aggregated before the hub gained the dimension were not re-attributed — not a
vendor called "unknown"; responses containing one carry `provider_note`.

Real spend is **subscription + gateway**. The notional figure is not a term in
it, and adding it in invents spending that never happened.

Every aggregate therefore returns cost as a *list*, one entry per source, each
carrying the kind of money it is:

```json
"cost": [
  {"source": "claude",  "kind": "notional", "events": 812, "cost_usd": 41.20, "unpriced_events": 0},
  {"source": "codex",   "kind": "notional", "events":  93, "cost_usd":  6.05, "unpriced_events": 4},
  {"source": "gateway", "kind": "billed",   "events":  57, "cost_usd": 12.80, "unpriced_events": 0}
],
"cost_notional": 47.25,
"cost_billed": 12.80,
"real_spend": {"currency": "USD", "subscription": 200, "gateway": 12.80, "total": 212.80, "complete": true}
```

`GET /v1/summary` adds `pricing` — one entry per source with its own
`rates_as_of` and the note saying what that source's figure is — and
`subscription_spend` for the same period. The dashboard renders one cost column
per source, labelled with its kind, plus a single **real spend** tile. The MCP
tools do the same, and their descriptions say which figures are notional and
which are billed.

The one aggregate that carries a plain `cost_usd` is a **session row**: sessions
are grouped by source, so each row is a single kind of money and says so in
`source` / `cost_kind`. Ranking by cost still works; nothing sums the column.

Two tests keep this true rather than conventional, because a blended aggregate
returns a plausible number and fails silently:
`TestNoCostAggregateCrossesSources` checks every read path against per-source
arithmetic, and `TestEveryRawCostSumDeclaresItself` fails the build if a new
`SUM(cost_usd)` appears in the store without either going through the source
split or stating in the SQL why its `GROUP BY` already covers it.

## Upgrading to the provider dimension

This release adds `provider` — the upstream that actually served a request — to
`usage_events` and to `usage_hourly`'s primary key. It matters because a gateway
that fails over between vendors reaches one model id through several upstreams
at several contracted prices, so a rate keyed on the model alone prices some
calls at another vendor's number.

**Back up the database before the first start.** The `usage_hourly` change
rebuilds the table (SQLite cannot alter a primary key); `~/.ccquota/backups/` is
the conventional place.

Existing raw events are backfilled from `details.model_provider`, which the
reporting side has been sending all along, so no collector has to change.

**Then rebuild the rollup, or the dimension reports nothing:**

```bash
ccquota hub --rebuild-rollup --rebuild-rollup-force
```

Every breakdown reads `usage_hourly`, and the migration carries pre-existing
hour-rows across with an *empty* provider rather than guessing one — so until
they are re-derived, the dimension answers "not declared" for all history and
looks broken rather than empty. The rebuild re-derives whatever raw events
retention still covers and leaves pre-retention hours untouched.
`--rebuild-rollup` on its own **refuses**, precisely because it would otherwise
erase hours whose raw rows have already been pruned; the `--force` variant is
the one that skips them instead. The startup log names the affected row count
and repeats this command.

Rehearsed against a 394 MB production snapshot: 41,462 rows rebuilt in under ten
seconds, every event count and token total unchanged, the only movement being
the last bit of a float64 cost sum as the addition order changed.

Gateway rates keyed on a bare model id keep working and now mean "this price
holds whoever serves it". State per-contract rates under `gateway.providers`
when two upstreams serve one model id at different prices.

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

`main` is the trunk. It is the default branch, it is what
`go install github.com/verkyyi/ccquota/cmd/ccquota@latest` resolves to (there
are no tags, so `@latest` follows the default branch), and it is what release
images are cut from. `dashboard-redesign` is the *historical* trunk -- for two
weeks production was built from it while `main` sat still -- and it is being
retired; don't branch from it.

Both the trunk and every pull request run `test`, `web`, and the four
`cross-compile` legs. Those six are required checks on the trunk, so a pull
request that is red cannot be merged. There is deliberately no required
*review*: a solo maintainer cannot approve their own pull request, so requiring
one would leave every pull request unmergeable.

## License

MIT
