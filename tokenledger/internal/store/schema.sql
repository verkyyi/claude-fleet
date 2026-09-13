-- ccquota schema.
-- Provider-specific observations are additive: old raw and rollup history is
-- retained, and account-wide observations never enter usage_events.

CREATE TABLE IF NOT EXISTS quota_snapshots (
  account_uuid TEXT NOT NULL,
  source TEXT NOT NULL,
  profile_id TEXT NOT NULL,
  endpoint_id TEXT NOT NULL,
  observed_at TEXT NOT NULL,
  observation TEXT NOT NULL,
  data_json TEXT NOT NULL,
  PRIMARY KEY(account_uuid, source, profile_id, endpoint_id, observed_at, observation)
);
CREATE INDEX IF NOT EXISTS idx_quotas_time ON quota_snapshots(account_uuid, observed_at);

CREATE TABLE IF NOT EXISTS source_collectors (
  endpoint_id TEXT NOT NULL,
  source TEXT NOT NULL,
  profile_id TEXT NOT NULL,
  account_uuid TEXT NOT NULL,
  observed_at TEXT NOT NULL,
  data_json TEXT NOT NULL,
  PRIMARY KEY(endpoint_id, source, profile_id)
);

CREATE TABLE IF NOT EXISTS source_account_switches (
  endpoint_id TEXT NOT NULL,
  source TEXT NOT NULL,
  profile_id TEXT NOT NULL,
  from_account TEXT NOT NULL,
  to_account TEXT NOT NULL,
  observed_at TEXT NOT NULL,
  PRIMARY KEY(endpoint_id, source, profile_id, observed_at)
);

-- Which subscription a source's UNASSIGNED pool belongs to.
--
-- Codex transcripts do not attest to an OpenAI account, so usage whose session
-- no logged-in profile can claim is parked under "<source>:local" rather than
-- guessed at. On a hub that holds exactly one subscription for that source,
-- the guess is not a guess and the pool is just that account under another
-- name -- but only the operator can say so, which is what this records.
-- Keyed by source: one pool per source, and re-binding replaces it.
CREATE TABLE IF NOT EXISTS source_pool_bindings (
  source       TEXT PRIMARY KEY,
  account_uuid TEXT NOT NULL,
  bound_at     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS account_usage_observations (
  account_uuid TEXT NOT NULL,
  source TEXT NOT NULL,
  endpoint_id TEXT NOT NULL,
  observed_at TEXT NOT NULL,
  data_json TEXT NOT NULL,
  PRIMARY KEY(account_uuid, source, endpoint_id, observed_at)
);
--
-- One hub may hold several subscriptions. account_uuid is therefore on every
-- fact table and on every index, and every query path filters by it: an
-- isolation bug here would show one team's spend to another.

CREATE TABLE IF NOT EXISTS accounts (
  account_uuid      TEXT PRIMARY KEY,
  source            TEXT NOT NULL DEFAULT 'claude',
  email             TEXT NOT NULL DEFAULT '',
  org_uuid          TEXT NOT NULL DEFAULT '',
  org_name          TEXT NOT NULL DEFAULT '',
  subscription_type TEXT NOT NULL DEFAULT '',
  rate_limit_tier   TEXT NOT NULL DEFAULT '',
  display_name      TEXT NOT NULL DEFAULT '',
  -- Turns older than this cannot belong to this subscription. The agent uses
  -- it as a hard attribution floor; the UI uses it to explain a gap.
  account_created_at TEXT,
  first_seen        TEXT NOT NULL,
  last_seen         TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS endpoints (
  endpoint_id   TEXT PRIMARY KEY,
  -- Nullable on purpose: an enrollment token is minted before the agent ever
  -- runs, so an endpoint exists for a while before it can say which
  -- subscription it belongs to. NULL means "enrolled, never reported".
  account_uuid  TEXT REFERENCES accounts(account_uuid),
  hostname      TEXT NOT NULL DEFAULT '',
  os            TEXT NOT NULL DEFAULT '',
  arch          TEXT NOT NULL DEFAULT '',
  machine_id    TEXT NOT NULL DEFAULT '',
  cc_version    TEXT NOT NULL DEFAULT '',
  agent_version TEXT NOT NULL DEFAULT '',
  token_hash    TEXT NOT NULL,          -- enrollment token, hashed; never the plaintext
  label         TEXT NOT NULL DEFAULT '',

  -- The OS login the agent runs as. An endpoint is a (machine, user) pair:
  -- every OS account has its own ~/.claude, its own transcripts and its own
  -- credentials, and on a shared box the other homes are unreadable.
  os_user       TEXT NOT NULL DEFAULT '',

  -- The team this endpoint's spend is allocated to.
  --
  -- Assigned by the operator, never reported by the endpoint. An endpoint that
  -- could name its own team could move its spend onto another team's budget,
  -- for the same reason a public submission may not name its own handle.
  team          TEXT NOT NULL DEFAULT '',
  enrolled_at   TEXT NOT NULL,
  last_seen     TEXT,

  -- Why this endpoint could not read its account's limits, in its own words
  -- ("the local OAuth token has expired", "no readable credentials", ...).
  -- Without this the UI can only say "nobody managed to read them", which
  -- tells an operator nothing about which machine to go fix.
  limits_unavailable TEXT NOT NULL DEFAULT '',
  limits_checked_at  TEXT,

  -- What this endpoint refused to attribute, and why. Excluded history is
  -- reported rather than silently missing from the totals.
  dropped_pre_account     INTEGER NOT NULL DEFAULT 0,
  earliest_dropped        TEXT,
  dropped_beyond_backfill INTEGER NOT NULL DEFAULT 0,
  backfill_limit          TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_endpoints_account ON endpoints(account_uuid);
CREATE UNIQUE INDEX IF NOT EXISTS idx_endpoints_token ON endpoints(token_hash);

CREATE TABLE IF NOT EXISTS usage_events (
  id                     INTEGER PRIMARY KEY AUTOINCREMENT,
  source                 TEXT NOT NULL DEFAULT 'claude',
  account_uuid           TEXT NOT NULL,
  endpoint_id            TEXT NOT NULL,
  session_id             TEXT NOT NULL DEFAULT '',
  message_uuid           TEXT NOT NULL,
  request_id             TEXT NOT NULL DEFAULT '',
  ts                     TEXT NOT NULL,          -- RFC3339 UTC
  model                  TEXT NOT NULL DEFAULT '',

  input_tokens           INTEGER NOT NULL DEFAULT 0,
  output_tokens          INTEGER NOT NULL DEFAULT 0,
  cache_create_5m_tokens INTEGER NOT NULL DEFAULT 0,
  cache_create_1h_tokens INTEGER NOT NULL DEFAULT 0,
  cache_read_tokens      INTEGER NOT NULL DEFAULT 0,
  thinking_tokens        INTEGER NOT NULL DEFAULT 0,
  web_search_requests    INTEGER NOT NULL DEFAULT 0,
  web_fetch_requests     INTEGER NOT NULL DEFAULT 0,

  -- NULL means the model is not in the pricing table. Never 0 — that would
  -- claim the work was free.
  cost_usd               REAL,

  cwd                    TEXT NOT NULL DEFAULT '',
  os_user                TEXT NOT NULL DEFAULT '',
  git_branch             TEXT NOT NULL DEFAULT '',
  entrypoint             TEXT NOT NULL DEFAULT '',
  effort                 TEXT NOT NULL DEFAULT '',
  is_sidechain           INTEGER NOT NULL DEFAULT 0
);

-- The dedup key. A resumed session re-reads lines it already shipped and a
-- forked conversation copies entries into a new file; both replay the same
-- uuid for the same API call, so collapsing them is correct.
-- The source-aware dedup index is created by migrateSources, after older
-- databases have acquired their source column.

CREATE INDEX IF NOT EXISTS idx_events_account_ts ON usage_events(account_uuid, ts);
CREATE INDEX IF NOT EXISTS idx_events_endpoint_ts ON usage_events(account_uuid, endpoint_id, ts);
CREATE INDEX IF NOT EXISTS idx_events_session ON usage_events(account_uuid, session_id);

CREATE TABLE IF NOT EXISTS limit_snapshots (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  account_uuid        TEXT NOT NULL,
  endpoint_id         TEXT NOT NULL DEFAULT '',
  observed_at         TEXT NOT NULL,
  five_hour_pct       REAL NOT NULL DEFAULT 0,
  five_hour_resets_at TEXT,
  seven_day_pct       REAL NOT NULL DEFAULT 0,
  seven_day_resets_at TEXT,
  scoped_json         TEXT NOT NULL DEFAULT '[]',
  extra_usage_json    TEXT NOT NULL DEFAULT '',
  spend_json          TEXT NOT NULL DEFAULT '',
  raw_json            TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_snapshots_account_time
  ON limit_snapshots(account_uuid, observed_at DESC);

-- Which subscriptions an endpoint has been seen running, and when.
--
-- This is many-to-many on purpose. Claude Code takes its account from the
-- environment per process, so one machine+user runs several subscriptions AT
-- THE SAME TIME -- measured here: three. endpoints.account_uuid holds only the
-- machine's own login; every subscription observed in a session lands here
-- instead, and neither displaces the other.
CREATE TABLE IF NOT EXISTS endpoint_accounts (
  endpoint_id  TEXT NOT NULL,
  account_uuid TEXT NOT NULL,
  origin       TEXT NOT NULL DEFAULT 'session',  -- 'login' | 'session'
  first_seen   TEXT NOT NULL,
  last_seen    TEXT NOT NULL,
  PRIMARY KEY (endpoint_id, account_uuid)
);

CREATE INDEX IF NOT EXISTS idx_endpoint_accounts_account
  ON endpoint_accounts(account_uuid, last_seen DESC);

-- A machine that logs out and into a different account creates a seam: rows
-- already ingested keep the old attribution and cannot be corrected. Recording
-- the transition makes the seam visible in the UI instead of silent.
--
-- Only a change of the endpoint's OWN login is a switch. Writing a row every
-- time the reported account differed from the last one turned concurrency into
-- history: 83 "switches" in four hours on one laptop, in exactly balanced
-- A->B/B->A pairs 0.003s apart, none of which happened.
CREATE TABLE IF NOT EXISTS account_switches (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  endpoint_id  TEXT NOT NULL,
  from_account TEXT NOT NULL,
  to_account   TEXT NOT NULL,
  observed_at  TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_switches_endpoint ON account_switches(endpoint_id, observed_at DESC);

-- Revocable links for showing usage to someone who must NOT see the fleet.
--
-- A separate credential from the viewer token on purpose. The viewer token
-- opens the dashboard AND the MCP server — every project path, machine name,
-- OS login and account email. There is no way to hand that to a third party
-- "just for the charts", and no way to take it back afterwards without
-- rotating it for everyone.
CREATE TABLE IF NOT EXISTS share_links (
  id           TEXT PRIMARY KEY,       -- short, printable; what you revoke by
  token_hash   TEXT NOT NULL UNIQUE,   -- never the token itself
  label        TEXT NOT NULL DEFAULT '',
  -- Notional costs are OFF unless deliberately enabled: an API-equivalent
  -- dollar figure shown to someone who does not know it is notional reads as
  -- a bill.
  show_costs   INTEGER NOT NULL DEFAULT 0,
  created_at   TEXT NOT NULL,
  expires_at   TEXT,                   -- NULL = no expiry
  revoked_at   TEXT,
  last_used_at TEXT,
  uses         INTEGER NOT NULL DEFAULT 0
);

-- Hourly rollup of usage_events, keyed by every dimension the dashboard can
-- drill down on plus the session. One row here stands for every turn in that
-- hour with the same (account, endpoint, session, login, project, model,
-- branch, effort, entrypoint, sidechain). The mini's 290k events collapse to a
-- few thousand rows, which is what makes brushing a 90-day timeline cheap.
--
-- Maintained in the same transaction as the event insert, so it can never
-- drift from usage_events. Pruning raw events leaves it alone on purpose:
-- totals and sessions keep working past the retention window, only per-turn
-- detail is lost -- which is exactly why a version bump does NOT rebuild it
-- from scratch: RebuildRollup only ever touches hours at or after the
-- earliest surviving raw event, since those are the only ones usage_events
-- can still attest to. Once anything has been pruned, the rows below that
-- line are the sole surviving record of that history, and RebuildRollup
-- refuses to run over them unless told --rebuild-rollup-force, rather than
-- silently truncating the rollup to the retention window with no way back.
CREATE TABLE IF NOT EXISTS usage_hourly (
  hour          TEXT NOT NULL,   -- 'YYYY-MM-DDTHH:00:00Z', the bucket start
  account_uuid  TEXT NOT NULL,
  endpoint_id   TEXT NOT NULL,
  session_id    TEXT NOT NULL DEFAULT '',
  os_user       TEXT NOT NULL DEFAULT '',
  cwd           TEXT NOT NULL DEFAULT '',
  model         TEXT NOT NULL DEFAULT '',
  git_branch    TEXT NOT NULL DEFAULT '',
  effort        TEXT NOT NULL DEFAULT '',
  entrypoint    TEXT NOT NULL DEFAULT '',
  is_sidechain  INTEGER NOT NULL DEFAULT 0,

  events                 INTEGER NOT NULL DEFAULT 0,
  input_tokens           INTEGER NOT NULL DEFAULT 0,
  output_tokens          INTEGER NOT NULL DEFAULT 0,
  cache_create_5m_tokens INTEGER NOT NULL DEFAULT 0,
  cache_create_1h_tokens INTEGER NOT NULL DEFAULT 0,
  cache_read_tokens      INTEGER NOT NULL DEFAULT 0,
  thinking_tokens        INTEGER NOT NULL DEFAULT 0,
  cost_usd               REAL    NOT NULL DEFAULT 0,   -- priced turns only
  unpriced_events        INTEGER NOT NULL DEFAULT 0,   -- turns with NULL cost
  min_ts                 TEXT NOT NULL,
  max_ts                 TEXT NOT NULL,
  source                 TEXT NOT NULL DEFAULT 'claude',
  PRIMARY KEY (hour, account_uuid, endpoint_id, session_id, os_user, cwd,
               model, git_branch, effort, entrypoint, is_sidechain, source)
);
CREATE INDEX IF NOT EXISTS idx_hourly_account_hour ON usage_hourly(account_uuid, hour);
CREATE INDEX IF NOT EXISTS idx_hourly_session ON usage_hourly(account_uuid, session_id);

CREATE TABLE IF NOT EXISTS rollup_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- What the subscriptions ACTUALLY cost.
--
-- A table rather than a column on accounts, because prices change. One column
-- would rewrite history on every price change: last month's figures would
-- silently be recomputed at this month's price. Effective-dated rows keep each
-- period priced at what it actually cost then.
--
-- Seats are deliberately NOT stored. How many accounts were on a plan in a
-- period is derivable from accounts; a stored count drifts out of date the
-- moment somebody is added or removed, and a drifted count is worse than no
-- count because it still looks authoritative.
--
-- THIS IS REAL MONEY, and it is a different kind of money from
-- usage_events.cost_usd. A subscription is billed whether or not a single
-- token is spent; cost_usd is notional -- "what this would have cost at API
-- rates" -- and is not an invoice. Subscription spend may be added to a
-- metered gateway bill. It must NEVER be added to the notional figure.
--
-- An unpriced plan is ABSENT here rather than present at 0, for the same
-- reason usage_events.cost_usd is NULL rather than 0: zero is a claim that the
-- plan was free, absent is an admission that nobody has said what it costs.
CREATE TABLE IF NOT EXISTS subscription_plans (
  plan           TEXT NOT NULL,           -- matches accounts.subscription_type
  source         TEXT NOT NULL,           -- 'claude' | 'codex' | ... — same plan name, different vendors
  monthly_cost   REAL NOT NULL,
  currency       TEXT NOT NULL DEFAULT 'USD',
  effective_from TEXT NOT NULL,           -- RFC3339 UTC, inclusive
  effective_to   TEXT,                    -- RFC3339 UTC, exclusive; NULL = still current
  PRIMARY KEY (plan, source, effective_from)
);

CREATE INDEX IF NOT EXISTS idx_plans_period
  ON subscription_plans(source, plan, effective_from DESC);
