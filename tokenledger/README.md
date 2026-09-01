# ccquota

Your Claude subscription is consumed by many machines. Anthropic tells you *how
much* is left, and nothing about *where it went*. Every local tool tells you
where it went on **one** machine, and has to guess at the quota.

ccquota joins the two. One Go binary, an agent on every endpoint, a hub with a
dashboard, and a read-only MCP server so any Claude session can ask.

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

## Why not one of the existing tools

| | multi-endpoint | dashboard | MCP |
|---|---|---|---|
| [ccusage](https://github.com/ccusage/ccusage) | ✗ | ✗ | ✓ |
| [Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor) | ✗ | ✗ | ✗ |
| [phuryn/claude-usage](https://github.com/phuryn/claude-usage) | ✗ | ✓ | ✗ |
| **ccquota** | ✓ | ✓ | ✓ |

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

Add `--expires 720h` for a link that dies on its own.

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

Eleven read-only tools: `list_accounts`, `get_limits`, `list_endpoints`,
`usage_by_account`, `list_account_switches`, `list_endpoint_accounts`,
`usage_by_endpoint`, `usage_by_user`, `usage_by_project`, `usage_by_session`,
`usage_history`.

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

**The agent never refreshes your token.** If it has expired the agent says so and
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

## License

MIT
