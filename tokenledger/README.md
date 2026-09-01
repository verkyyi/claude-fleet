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

**Enroll each endpoint** (on the hub — the token is shown once):

```bash
ccquota enroll --name web-01
```

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

An endpoint maps to **one account at a time**, because credentials and
transcripts are per-user. For a shared box, run one agent per user — each with
its own enrollment token and its own state directory:

```bash
# On the hub, once per person:
ccquota enroll --name build-server-alice
ccquota enroll --name build-server-bob

# On the box, as each user (or as root with --home pointed at theirs):
ccquota agent --home /home/alice --state /home/alice/.ccquota
ccquota agent --home /home/bob   --state /home/bob/.ccquota
```

They can be on the same subscription or different ones; the hub does not care.
Do not try to cover two accounts with one agent process — it has one
`~/.claude.json` to read, so it would simply report whichever account that file
names.

If someone logs out and into a *different* account on a machine, ccquota records
the switch and shows it in the UI. Rows already ingested keep their old
attribution and cannot be corrected — see the known limits below.

## MCP

Point any MCP client at `https://your-hub/mcp` with the viewer token as a bearer.

```json
{ "mcpServers": { "ccquota": {
  "type": "http",
  "url": "https://ccquota.example.com/mcp",
  "headers": { "Authorization": "Bearer <viewer token>" }
}}}
```

Seven read-only tools: `list_accounts`, `get_limits`, `list_endpoints`,
`usage_by_endpoint`, `usage_by_project`, `usage_by_session`, `usage_history`.

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
