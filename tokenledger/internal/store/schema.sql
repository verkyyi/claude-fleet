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

  -- This login's claude-fleet install, as reported by the agent from
  -- fleet-install-version.sh (issue #157). An endpoint is the right row for it
  -- for the same reason os_user is: the install lives in that login's
  -- ~/.claude/fleet, and the machine you never log into is precisely the one
  -- whose install falls behind unnoticed.
  --
  -- fleet_behind is NULLABLE ON PURPOSE. The script emits null when the count
  -- could not be read (no upstream, fetch refused, not a checkout) and NULL is
  -- the only honest storage for it: a 0 here would say "current" about an
  -- install nobody could measure, which is claude-fleet#635 all over again.
  -- fleet_fetched says whether that count was read against a freshly fetched
  -- remote or the remote-tracking ref the install already had. fleet_seen_at
  -- is when the AGENT ran the script, so a login that stopped reporting the
  -- install (Claude logged out; agent downgraded) shows as stale rather than
  -- presenting the last reading as current. Every column keeps its last value
  -- across batches that do not carry the reading; see Store.TouchEndpoint.
  fleet_head        TEXT NOT NULL DEFAULT '',
  fleet_behind      INTEGER,
  fleet_verdict     TEXT NOT NULL DEFAULT '',
  fleet_follow      TEXT NOT NULL DEFAULT '',
  fleet_follow_text TEXT NOT NULL DEFAULT '',
  fleet_error       TEXT NOT NULL DEFAULT '',
  fleet_fetched     INTEGER NOT NULL DEFAULT 0,
  fleet_seen_at     TEXT,

  -- What this enrollment is FOR. 'agent' is a machine collecting usage. The
  -- shipper kinds ('repo_shipper', 'growth_shipper', 'growth_reader') pushed
  -- data this hub no longer takes; migration 1 retired every one of them.
  --
  -- The distinction is not cosmetic. Every fleet surface reads "enrolled but
  -- silent" as a collection failure -- the roster, and the stale-agent
  -- finding, which fires "<label> has never reported ... its share of every
  -- total is under-counted until it returns". A shipper never reported usage
  -- BY DESIGN, so without this column it was a permanent false alarm.
  kind          TEXT NOT NULL DEFAULT 'agent',

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
  backfill_limit          TEXT NOT NULL DEFAULT '',

  -- When this endpoint was retired. NULL = active; a timestamp means the
  -- operator is done with it.
  --
  -- Retiring KEEPS the row and every usage row pointing at it. That is the
  -- whole point: an endpoint's spend is already in the ledger, and deleting it
  -- would silently change historical totals -- last month's report would come
  -- back smaller with no record of why. So retire is the default and the only
  -- thing offered for an endpoint that has ever reported; DeleteEndpoint
  -- exists for the mint-then-abandon case and refuses everything else.
  --
  -- It is also a real revocation, not a label: EndpointByTokenHash filters on
  -- it, and that is the one query every enrollment-token path goes through, so
  -- the token stops being accepted everywhere at once. There is deliberately
  -- no un-retire -- the token hash is still on this row, so restoring the row
  -- would restore the credential the operator just killed. Re-enroll instead:
  -- a new id, a new token, and the old spend stays where it was.
  retired_at              TEXT
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
  -- The upstream that actually served the request. Empty means the reporting
  -- side declared none, which is the honest state for a Claude transcript --
  -- never a vendor called "unknown".
  provider               TEXT NOT NULL DEFAULT '',

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
  -- The issue this turn was worked under, read from git_branch by one anchored
  -- rule (store.IssueFromBranch). NULL means the branch did not say -- never 0,
  -- which would be a real issue number, and never a guess: on 420k measured
  -- events a looser rule would file 15.6% of them under a scratch-session
  -- ordinal that collides with real issues. It carries NO repository, on
  -- purpose: binding a number to a repository is the reader's job, through
  -- git_repo below.
  -- docs/superpowers/specs/2026-09-19-cost-per-issue-seam-design.md
  issue_number           INTEGER,
  -- The repository the turn was spent in, as `owner/name`. DECLARED by the
  -- endpoint, which runs inside the checkout and resolved it once per cwd from
  -- `git remote get-url origin` — never derived here: the hub still shells out
  -- to nothing and stores only what the reporter recorded.
  --
  -- '' means NOT DECLARED (an older agent, a cwd that is not a checkout, a
  -- remote that names no host). It is the third state beside "this repo" and
  -- "another repo", and a read has to disclose it rather than fold it into
  -- either — see §6 of the design above, and internal/agent/gitrepo.go.
  git_repo               TEXT NOT NULL DEFAULT '',
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

-- The latest reading of each per-model cap (the weekly Fable cap: claim
-- "7d_oi"), per account. A table of its own, not a column on the snapshot, and
-- latest-only: most snapshots come from a session's statusLine, which never sees
-- these, so "the freshest snapshot" would hide a cap read five minutes earlier
-- behind one that could not have seen it.
CREATE TABLE IF NOT EXISTS model_claims (
  account_uuid        TEXT NOT NULL,
  model               TEXT NOT NULL,
  claim               TEXT NOT NULL,
  utilization         REAL NOT NULL DEFAULT 0,
  status              TEXT NOT NULL DEFAULT '',
  resets_at           TEXT,
  surpassed_threshold REAL,
  observed_at         TEXT NOT NULL,
  PRIMARY KEY (account_uuid, model, claim)
);

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
  provider      TEXT NOT NULL DEFAULT '',
  git_branch    TEXT NOT NULL DEFAULT '',
  -- Derived from git_branch, exactly as on usage_events above, and NOT part of
  -- the key below: it is a pure function of a column that already is, so it
  -- adds no grain -- and it can be re-derived in place when the rule changes,
  -- without the rebuild from usage_events that pruned history would refuse.
  issue_number  INTEGER,
  -- Declared by the endpoint, exactly as on usage_events above, and NOT part of
  -- the key below: it is a function of cwd, which already is, so it adds no
  -- grain. Unlike issue_number it CANNOT be re-derived here -- the hub does not
  -- read git -- so the write paths never let '' overwrite a declared value: an
  -- endpoint upgrading mid-hour would otherwise erase its own declaration.
  git_repo      TEXT NOT NULL DEFAULT '',
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
  cache_write_tokens       INTEGER NOT NULL DEFAULT 0,
  cache_write_known_events INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (hour, account_uuid, endpoint_id, session_id, os_user, cwd,
               model, provider, git_branch, effort, entrypoint, is_sidechain, source)
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

-- The one piece of state a PERSON creates about a finding: "I know, be quiet
-- until X".
--
-- Findings themselves are not stored. They are recomputed by internal/findings
-- on every read, from the rollups, and that is deliberate -- a findings table
-- would be a second copy of numbers that already exist and would go stale the
-- moment a rule or a threshold changed. What cannot be recomputed is the
-- operator's judgement, so that is the only thing here: a row per silenced
-- finding, keyed by the stable id internal/findings/identity.go derives.
--
-- expires_at is NOT NULL, and there is no sentinel for "never". A permanently
-- muted alert is a deleted alert that nobody remembers deleting: the condition
-- stays true, the card stays quiet, and months later no one can say why that
-- rule never fires. Forcing every silence to end makes it self-correcting --
-- the worst case is being told again about something already handled.
--
-- Rows outlive their expiry until something writes: reads filter on the clock
-- (store.ActiveFindingMutes) so an unpruned row can never silence anything,
-- and the pruning rides along on the next mute/unmute rather than needing a
-- daemon of its own.
CREATE TABLE IF NOT EXISTS finding_mutes (
  finding_id TEXT PRIMARY KEY,
  -- The finding's kind at mute time, for the roster view only: an id is a
  -- hash and says nothing a human can read. Never matched on -- the id is the
  -- identity -- so a rule renaming its kind cannot orphan a live mute.
  kind       TEXT NOT NULL DEFAULT '',
  -- Why, in the operator's own words. Optional; a mute with no note is still
  -- a decision, just an undocumented one.
  note       TEXT NOT NULL DEFAULT '',
  -- Who silenced it, when the hub knows (a tailnet or SSO identity). Empty
  -- for a request carrying the shared viewer token, which names nobody --
  -- and empty is the honest answer there rather than a guess at who holds it.
  muted_by   TEXT NOT NULL DEFAULT '',
  muted_at   TEXT NOT NULL,
  expires_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_finding_mutes_expiry ON finding_mutes(expires_at);

-- Who may sign in with GitHub (claude-fleet#1984). A person is their GitHub
-- numeric ID, never their username: a username can be freed and taken by
-- someone else, an ID cannot. role is 'admin' (copied from the deploy's
-- CCQUOTA_GITHUB_ADMINS -- the row records them, the deploy decides) or
-- 'user' (added on the web). machine_login is the OS login that is theirs on
-- every machine, '' when none yet. Removing a row signs them out on their
-- next request: the gate reads this table on every request.
CREATE TABLE IF NOT EXISTS hub_users (
  github_id     INTEGER PRIMARY KEY,
  login         TEXT NOT NULL,
  role          TEXT NOT NULL,
  machine_login TEXT NOT NULL DEFAULT '',
  added_by      TEXT NOT NULL DEFAULT '',
  added_at      TEXT NOT NULL,
  last_seen     TEXT
);

-- The pin (claude-fleet#1984): the first time the hub learns which GitHub ID
-- holds a username, it keeps the pair, and from then on the name means that ID
-- only. A sign-in under a pinned name with another ID is refused and audited.
-- login is stored lower-cased: GitHub usernames are case-insensitive.
CREATE TABLE IF NOT EXISTS hub_user_names (
  login     TEXT PRIMARY KEY,
  github_id INTEGER NOT NULL,
  pinned_at TEXT NOT NULL
);

-- The hub's own audit trail for sign-in and the people list
-- (claude-fleet#1984): every refusal, every pin, every change. actor is a
-- principal (gh:<id>), 'deploy' or 'operator'; target names who it was about.
CREATE TABLE IF NOT EXISTS hub_audit (
  id      INTEGER PRIMARY KEY,
  created TEXT NOT NULL,
  actor   TEXT NOT NULL DEFAULT '',
  action  TEXT NOT NULL,
  target  TEXT NOT NULL DEFAULT '',
  outcome TEXT NOT NULL,
  detail  TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_hub_audit_created ON hub_audit(created);
