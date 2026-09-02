-- ccquota schema.
--
-- One hub may hold several subscriptions. account_uuid is therefore on every
-- fact table and on every index, and every query path filters by it: an
-- isolation bug here would show one team's spend to another.

CREATE TABLE IF NOT EXISTS accounts (
  account_uuid      TEXT PRIMARY KEY,
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
CREATE UNIQUE INDEX IF NOT EXISTS idx_events_dedup
  ON usage_events(account_uuid, message_uuid);

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
