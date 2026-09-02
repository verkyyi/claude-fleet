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

Once any team is assigned, the dashboard leads with the team breakdown, and
every OS login links to its own page at `/u/<login>`. Both are deliberately
unnumbered. Read as a per-person performance ranking, an internal usage board
fails by Goodhart — people avoid the tool or pad their usage — and either
outcome destroys the cost data it exists to provide.

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
