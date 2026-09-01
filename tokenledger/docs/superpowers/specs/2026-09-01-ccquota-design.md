# ccquota — design

**Date:** 2026-09-01
**Status:** approved design, pre-implementation
**Approach:** single Go binary, two roles (`agent` / `hub`), embedded dashboard, read-only MCP

---

## 1. Problem

A Claude subscription is consumed by *many endpoints* — Linux servers, Windows
boxes, laptops — but every existing tool reports from one machine's local logs.
When the 5-hour window hits the wall, you cannot tell which endpoint spent it.

Anthropic closed the official request for cross-machine usage stats as
*not planned* ([claude-code#15434]). The tooling ecosystem has three shapes and
none of them covers this one:

| Project | multi-endpoint | GUI dashboard | MCP |
|---|---|---|---|
| ccusage (18.3k★) | ✗ | ✗ | ✓ |
| Claude-Code-Usage-Monitor (8.7k★) | ✗ | ✗ | ✗ |
| phuryn/claude-usage (2.2k★) | ✗ | ✓ | ✗ |
| jimdawdy/claude-usage-tracker (1★) | ✓ | ✓ | ✗ |
| claude-code-otel | ✓ | ✓ (Grafana) | ✗ |

`ccquota` is the intersection: **collect from every endpoint, show one
dashboard, expose it to agents over MCP** — for **several subscriptions at
once**, not just one.

[claude-code#15434]: https://github.com/anthropics/claude-code/issues/15434

## 2. Goals

1. One binary, deployable to Linux/Windows/macOS with no runtime dependency.
2. Aggregate token spend from N endpoints across M subscriptions into one store.
3. Report **real** subscription utilization (5-hour and 7-day), not an estimate,
   and attribute it back to endpoints and projects.
4. A graphical dashboard answering four questions: am I about to hit the wall,
   which endpoint is burning it, which project/session is burning it, and what
   is the trend.
5. Expose the same data read-only over MCP so any Claude session can ask.
6. Self-hostable by a stranger in one command.

### Non-goals (v1)

- No fleet control (no pause/resume/kill of endpoints, no write tools).
- No alert routing (no webhooks, no push). Deliberately deferred.
- No Claude.ai / Desktop / API-console usage — Claude Code endpoints only.
- No enforcement of per-endpoint quotas.
- No team billing reconciliation.

## 3. Key insight: two different numbers

The design rests on a fact confirmed by probe on 2026-08-31:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <claudeAiOauth.accessToken>
→ 200
{
  "five_hour": {"utilization": 4.0,  "resets_at": "2026-09-01T08:29:59Z", ...},
  "seven_day": {"utilization": 8.0,  "resets_at": "2026-09-06T05:59:59Z", ...},
  "limits": [{"kind":"session",...},{"kind":"weekly_all",...},
             {"kind":"weekly_scoped","scope":{"model":{...}},...}],
  "extra_usage": {...}, "spend": {...}
}
```

Anthropic **already aggregates across every device on the account**. That splits
the problem cleanly:

- **Truth** — "am I about to hit the wall" — is one HTTP call, account-wide.
  No agents required.
- **Attribution** — "which endpoint / project spent it" — is *not* in that
  payload and requires reading each endpoint's local transcripts.

Every existing tool conflates these, and so reports estimated token spend as if
it were quota. `ccquota` keeps them separate and reconciles them (§7).

> ⚠️ `/api/oauth/usage` is **undocumented**. It will change or disappear.
> §9 specifies the degrade path; it is a first-class requirement, not a
> nice-to-have.

## 4. Architecture

```
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│ endpoint A   │   │ endpoint B   │   │ endpoint C   │
│ (linux)      │   │ (windows)    │   │ (macos)      │
│ ccquota agent│   │ ccquota agent│   │ ccquota agent│
└──────┬───────┘   └──────┬───────┘   └──────┬───────┘
       │ HTTPS POST /v1/ingest (bearer)      │
       └──────────────────┼──────────────────┘
                          ▼
                 ┌────────────────────┐
                 │   ccquota hub      │
                 │  SQLite (pure Go)  │
                 ├────────────────────┤
                 │  /      SPA        │  ← embed.FS
                 │  /v1/*  query API  │
                 │  /mcp   MCP (HTTP) │
                 └────────────────────┘
```

One binary, selected by subcommand: `ccquota agent` (with `agent install` to
generate the platform service unit), `ccquota hub`, `ccquota enroll`, and
`ccquota report` (local one-shot, no hub).

### 4.1 Agent

Runs on every endpoint. Four jobs:

**a. Identity.** Reads `~/.claude.json`:
`oauthAccount.accountUuid`, `.emailAddress`, `.organizationUuid`,
`.organizationName`, and top-level `machineID`. Adds hostname, OS, arch,
Claude Code version. This is how a row learns which *subscription* it belongs
to — the transcripts themselves do not record it (§10.2).

**b. Transcript scan.** Walks `~/.claude/projects/**/*.jsonl` incrementally.
Per file it keeps `{path, inode/fileID, size, offset, mtime}` in a local cursor
DB; on each pass it reads only from `offset`. If size < offset or the inode
changed, the file was rotated or replaced — rescan from zero.

Entries of interest are `type == "assistant"` with `message.usage`. Confirmed
schema (probed 2026-08-31, Claude Code 2.1.252):

```
entry: cwd, effort, entrypoint, gitBranch, isSidechain, message, parentUuid,
       requestId, sessionId, timestamp, type, userType, uuid, version
message: id, model, role, stop_reason, usage, ...
usage: input_tokens, output_tokens, cache_creation_input_tokens,
       cache_read_input_tokens,
       output_tokens_details.thinking_tokens,
       cache_creation.{ephemeral_5m_input_tokens, ephemeral_1h_input_tokens},
       server_tool_use.{web_search_requests, web_fetch_requests},
       service_tier, iterations[]
```

> **`usage.iterations[]` is a breakdown, not additional spend.** The top-level
> counters are already the total. Summing iterations double-counts. This is the
> single easiest way to get every number in this project wrong, and it gets a
> dedicated test.

**c. Limits poll.** Calls `/api/oauth/usage` with the endpoint's own OAuth
access token and pushes the parsed snapshot. Token sources:

| OS | location |
|---|---|
| macOS | Keychain generic password, service `Claude Code-credentials` |
| Linux | `~/.claude/.credentials.json` |
| Windows | `%USERPROFILE%\.claude\.credentials.json` |

The agent **reads the token and never refreshes it.** If `expiresAt` is in the
past it skips the poll and reports `limits_unavailable: token_expired`.
Attempting a refresh would race Claude Code's own refresh and could invalidate
the user's live session — a monitoring tool must not be able to log you out.

Default interval 120s ±20% jitter. The ingest response may carry
`limits_poll_interval_s` so the hub can back a noisy fleet off centrally.
Snapshots are idempotent; the hub keeps the freshest per account.

**d. Ship.** Batches to `POST /v1/ingest` over HTTPS with a bearer enrollment
token. A bounded on-disk spool (default 64 MB, oldest-dropped) absorbs hub
outages. `--once` mode does a single scan+push and exits, for cron.

Packaging: systemd unit, launchd plist, Windows service via
`golang.org/x/sys/windows/svc`. All three generated by `ccquota agent install`.

### 4.2 Hub

- `POST /v1/ingest` — authenticated per endpoint; validates, dedups, stores.
- `GET /v1/...` — query API backing the SPA.
- `GET /` — the dashboard, compiled into the binary via `embed.FS`.
- `POST /mcp` — MCP over streamable HTTP.
- Background rollup job materializing hourly aggregates.

Storage is SQLite through `modernc.org/sqlite` (pure Go, **no cgo**, so
cross-compilation stays trivial). Single-writer is acceptable: dozens of
endpoints pushing every 30–60s is far inside its envelope. Postgres is a
post-v1 option behind the same `store` interface if anyone runs hundreds.

## 5. Data model

```sql
accounts(
  account_uuid TEXT PRIMARY KEY,
  email, org_uuid, org_name,
  subscription_type,        -- 'max', 'pro', ...
  rate_limit_tier,          -- 'default_claude_max_20x', ...
  display_name, first_seen, last_seen
)

endpoints(
  endpoint_id TEXT PRIMARY KEY,   -- assigned at enrollment
  account_uuid REFERENCES accounts,
  hostname, os, arch, machine_id,
  cc_version, agent_version,
  enrolled_at, last_seen
)

usage_events(
  id INTEGER PRIMARY KEY,
  account_uuid, endpoint_id, session_id,
  message_uuid,               -- entry.uuid
  request_id,                 -- entry.requestId
  ts, model,
  input_tokens, output_tokens,
  cache_create_5m_tokens, cache_create_1h_tokens, cache_read_tokens,
  thinking_tokens,
  web_search_requests, web_fetch_requests,
  cost_usd,                   -- notional, see §6
  cwd, git_branch, entrypoint, effort, is_sidechain,
  UNIQUE(account_uuid, message_uuid)
)

limit_snapshots(
  id INTEGER PRIMARY KEY,
  account_uuid, endpoint_id, observed_at,
  five_hour_pct, five_hour_resets_at,
  seven_day_pct, seven_day_resets_at,
  scoped_json, extra_usage_json, spend_json, raw_json
)

account_switches(endpoint_id, from_account, to_account, observed_at)

rollup_hourly(account_uuid, endpoint_id, hour, model,
              tokens_in, tokens_out, cache_create, cache_read, cost_usd,
              PRIMARY KEY(account_uuid, endpoint_id, hour, model))
```

**Dedup key is `(account_uuid, message_uuid)`.** `entry.uuid` is present on
every entry; `requestId` is present on assistant messages but is kept only as a
secondary/diagnostic field. This key survives rescans, resumed sessions, and
forked conversations that copy entries into a new file — a fork replays the same
API call, so collapsing it is correct.

Retention: raw `usage_events` 90 days (configurable), rollups indefinitely.

## 6. Cost

Costs are computed from an embedded model-pricing table with five rates per
model: input, output, cache-write-5m, cache-write-1h, cache-read. The 1h cache
write is priced separately because it is materially more expensive than the 5m
one and the split is available in the payload.

For subscription users this figure is **notional** — "what this would have cost
at API rates". The UI and the MCP tool descriptions both say so. It is useful
for comparing endpoints and projects against each other, and misleading if read
as a bill.

The table refreshes from a LiteLLM-format JSON when online, with the embedded
copy as offline default. Unknown model ids record tokens with `cost_usd = NULL`
and surface in the UI as "unpriced", never as zero.

## 7. Reconciliation — the thing nobody else does

Truth and attribution meet here:

```
window       = [five_hour.resets_at - 5h, five_hour.resets_at)
total        = Σ weighted_tokens(usage_events) over window, all endpoints
endpoint_pct ≈ (weighted_tokens(endpoint) / total) × five_hour.utilization
```

`weighted_tokens` applies the pricing weights, since Anthropic's utilization
tracks something closer to cost than to raw token count.

The **total is exact** — it comes from Anthropic. The **split is proportional**,
and therefore an estimate that assumes utilization is roughly proportional to
weighted spend. The UI labels split figures as estimates and shows the exact
total unqualified. Same for `seven_day`.

Where an account has *no* reachable limits snapshot, no percentages are shown at
all — see §9.

## 8. Interfaces

### 8.1 Dashboard (embedded SPA)

Vite + React + TypeScript, built to `web/dist`, embedded. All four approved
views, with a subscription switcher plus an all-subscriptions overview:

1. **Wall** — 5h and 7d gauges per account, countdown to reset, burn rate,
   projected time-to-limit at current rate.
2. **By endpoint** — share of window per host, last-seen, offline agents.
3. **By project / session** — drill through `cwd`, `git_branch`, `model`,
   `session_id`; sidechain (subagent) spend broken out.
4. **History** — daily/weekly trend, per-model split, week-over-week.

> Implementation note: load the `dataviz` skill before writing any chart code.

### 8.2 MCP (read-only, streamable HTTP at `/mcp`)

| tool | returns |
|---|---|
| `list_accounts` | subscriptions known to this hub, with tier |
| `get_limits` | current 5h/7d %, reset times, scoped model limits, projection |
| `list_endpoints` | hosts per account, last_seen, window share |
| `usage_by_endpoint` | tokens/cost by host over a range |
| `usage_by_project` | tokens/cost by cwd/branch over a range |
| `usage_by_session` | session-level detail, incl. sidechain split |
| `usage_history` | time series at a given granularity |

Every tool takes an optional `account` and a time range. Tool descriptions state
explicitly that split percentages are estimates and costs are notional, so an
agent reading them does not over-claim to the user.

## 9. Failure behavior

**This is a requirement, not error handling.**

| failure | behavior |
|---|---|
| `/api/oauth/usage` 404 / schema change | gauges are **removed** and a banner explains the endpoint is unavailable; dashboard drops to token-estimate mode |
| OAuth token expired | that account shows `limits stale as of <ts>`; token spend keeps flowing |
| hub unreachable | agent spools to disk, retries with backoff; nothing is lost until the spool cap |
| unknown model id | tokens recorded, cost `NULL`, shown as "unpriced" |
| unknown JSONL field | ignored; parser is tolerant of additions |
| required JSONL field missing | contract test fails loudly in CI; agent logs and skips the entry |

The one thing the system must never do is render a stale or inferred percentage
styled the same as a live one.

## 10. Known limits — state these in the README

**10.1 Undocumented endpoint.** `/api/oauth/usage` is not a public API. It can
change without notice. §9 is the mitigation; a contract test pinned to the
observed shape is the tripwire.

**10.2 Account attribution has a seam.** Transcript JSONL records no account
identity. The agent stamps `account_uuid` from `~/.claude.json` *at scan time*.
If a machine logs out and into a different account, rows already ingested keep
the old attribution and cannot be retroactively corrected. `account_switches`
records the transition so the seam is **visible** in the UI rather than silent.

**10.3 The per-endpoint split is an estimate.** See §7.

**10.4 Costs are notional for subscription users.** See §6.

## 11. Security

- **The hub never holds OAuth tokens.** Agents poll Anthropic locally and push
  only the resulting numbers. A compromised hub leaks usage statistics, never
  account access.
- Enrollment tokens are stored hashed; the plaintext is shown once, at `enroll`.
- Dashboard and MCP require a bearer token. README recommends binding to a
  tailnet or sitting behind a TLS reverse proxy; the hub refuses to start bound
  to `0.0.0.0` without an explicit `--insecure-public` acknowledgement.
- Tokens are never logged. `limit_snapshots.raw_json` was verified to contain no
  credentials.
- Reading your own account's usage with your own credentials is the intended
  use; the project ships no mechanism for reading anyone else's.

## 12. Repo layout

```
cmd/ccquota/         agent | hub | enroll | report | version
internal/scan/       JSONL parsing, incremental cursor
internal/identity/   account + machine identification, credential loading
internal/limits/     /api/oauth/usage client, degrade logic
internal/spool/      bounded on-disk queue
internal/store/      SQLite schema, migrations, queries
internal/pricing/    model pricing table + refresh
internal/api/        ingest + query HTTP handlers
internal/mcp/        MCP tool implementations
internal/recon/      §7 reconciliation math
web/                 SPA source; web/dist embedded
docs/                this spec, README, deployment guides
```

## 13. Testing

- **Parser:** golden JSONL fixtures (real schema, redacted) → expected totals.
  Explicit case asserting `usage.iterations[]` is **not** summed.
- **Cursor:** rescan is a no-op; append picks up only new bytes; rotation and
  truncation trigger full rescan; fork with duplicated uuids dedups to one row.
- **Pricing:** 5m vs 1h cache writes priced differently; unknown model yields
  `NULL` not `0`.
- **Reconciliation:** synthetic windows with known splits; boundary cases at
  reset time; zero-total window does not divide by zero.
- **Isolation:** two accounts × two endpoints; assert no query path leaks
  account A's rows into account B's response. This is the test that matters most
  for multi-subscription.
- **Contract:** pinned fixture of the `/api/oauth/usage` payload; fails when a
  consumed field disappears.
- **Degrade:** endpoint returning 404/500/garbage → gauges absent, banner
  present, token spend still reported.

## 14. Milestones

| # | deliverable |
|---|---|
| M1 | `ccquota report` — local scan + accurate totals, no hub. Proves the parser. |
| M2 | hub + ingest + store + enrollment; two endpoints landing rows |
| M3 | limits poll + reconciliation + degrade path |
| M4 | dashboard, all four views, multi-subscription switcher |
| M5 | MCP server, seven read-only tools |
| M6 | service packaging (systemd/launchd/Windows), README, release binaries |

M1 is deliberately first and standalone: if the parser is wrong, everything
downstream is confidently wrong.
