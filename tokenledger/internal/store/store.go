// Package store persists accounts, endpoints, usage events and limit
// snapshots to SQLite.
//
// The driver is modernc.org/sqlite: a pure-Go translation, so CGO_ENABLED=0
// still cross-compiles to every platform an endpoint might run on. That
// constraint is what keeps "download one binary" true.
package store

import (
	"database/sql"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	_ "modernc.org/sqlite"

	"github.com/verkyyi/ccquota/internal/model"
)

//go:embed schema.sql
var schemaSQL string

// Store is a handle on the hub's database.
type Store struct {
	db *sql.DB
}

// Open opens (creating if needed) the database at path and applies the schema.
func Open(path string) (*Store, error) {
	// WAL lets the dashboard read while agents are pushing. busy_timeout turns
	// the single-writer contention into a short wait instead of an immediate
	// "database is locked" error under a fleet of agents.
	dsn := path + "?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open sqlite %s: %w", path, err)
	}
	// modernc's driver is not safe to hammer with many concurrent writers;
	// one connection plus WAL is both correct and fast enough here.
	db.SetMaxOpenConns(1)

	if _, err := db.Exec(schemaSQL); err != nil {
		db.Close()
		return nil, fmt.Errorf("apply schema: %w", err)
	}
	if err := migrate(db); err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
}

// migrate adds columns to databases created by an earlier version.
//
// The schema uses CREATE TABLE IF NOT EXISTS, which silently does nothing on an
// existing database — so a new column has to be added explicitly or an upgraded
// hub fails every query that mentions it.
func migrate(db *sql.DB) error {
	adds := []struct{ table, column, spec string }{
		{"endpoints", "limits_unavailable", "TEXT NOT NULL DEFAULT ''"},
		{"endpoints", "limits_checked_at", "TEXT"},
		{"accounts", "account_created_at", "TEXT"},
		{"endpoints", "dropped_pre_account", "INTEGER NOT NULL DEFAULT 0"},
		{"endpoints", "earliest_dropped", "TEXT"},
		{"endpoints", "dropped_beyond_backfill", "INTEGER NOT NULL DEFAULT 0"},
		{"endpoints", "backfill_limit", "TEXT NOT NULL DEFAULT ''"},
		{"accounts", "label_locked", "INTEGER NOT NULL DEFAULT 0"},
		{"endpoints", "os_user", "TEXT NOT NULL DEFAULT ''"},
		{"usage_events", "os_user", "TEXT NOT NULL DEFAULT ''"},
		{"endpoints", "team", "TEXT NOT NULL DEFAULT ''"},
	}
	for _, a := range adds {
		has, err := hasColumn(db, a.table, a.column)
		if err != nil {
			return err
		}
		if has {
			continue
		}
		if _, err := db.Exec(fmt.Sprintf("ALTER TABLE %s ADD COLUMN %s %s", a.table, a.column, a.spec)); err != nil {
			return fmt.Errorf("add %s.%s: %w", a.table, a.column, err)
		}
	}
	return nil
}

func hasColumn(db *sql.DB, table, column string) (bool, error) {
	rows, err := db.Query(fmt.Sprintf("PRAGMA table_info(%s)", table))
	if err != nil {
		return false, fmt.Errorf("inspect %s: %w", table, err)
	}
	defer rows.Close()
	for rows.Next() {
		var cid int
		var name, typ string
		var notnull, pk int
		var dflt sql.NullString
		if err := rows.Scan(&cid, &name, &typ, &notnull, &dflt, &pk); err != nil {
			return false, err
		}
		if name == column {
			return true, nil
		}
	}
	return false, rows.Err()
}

// RecordAttribution stores what an endpoint excluded and why.
//
// Zero is a meaningful value here: an endpoint that used to drop history and
// no longer does must stop being reported as lossy.
func (s *Store) RecordAttribution(endpointID string, a model.Attribution) error {
	var earliest any
	if a.EarliestDropped != nil {
		earliest = fmtTime(*a.EarliestDropped)
	}
	_, err := s.db.Exec(`
		UPDATE endpoints SET dropped_pre_account = ?, earliest_dropped = ?,
		       dropped_beyond_backfill = ?, backfill_limit = ?
		WHERE endpoint_id = ?`,
		a.DroppedPreAccount, earliest, a.DroppedBeyondBackfill, a.BackfillLimit, endpointID)
	if err != nil {
		return fmt.Errorf("record attribution: %w", err)
	}
	return nil
}

// RecordLimitsUnavailable stores an endpoint's own explanation of why it could
// not read its account's limits.
func (s *Store) RecordLimitsUnavailable(endpointID, reason string) error {
	_, err := s.db.Exec(
		`UPDATE endpoints SET limits_unavailable = ?, limits_checked_at = ? WHERE endpoint_id = ?`,
		reason, fmtTime(time.Now()), endpointID)
	if err != nil {
		return fmt.Errorf("record limits reason: %w", err)
	}
	return nil
}

// LimitsReason returns the most recent explanation from any endpoint on an
// account, so the UI can say which machine to go fix.
func (s *Store) LimitsReason(account string) (endpoint, reason string, err error) {
	row := s.db.QueryRow(`
		SELECT COALESCE(NULLIF(label,''), hostname, endpoint_id), limits_unavailable
		FROM endpoints
		WHERE account_uuid = ? AND limits_unavailable <> ''
		ORDER BY limits_checked_at DESC LIMIT 1`, account)
	switch err := row.Scan(&endpoint, &reason); {
	case err == sql.ErrNoRows:
		return "", "", nil
	case err != nil:
		return "", "", fmt.Errorf("limits reason: %w", err)
	}
	return endpoint, reason, nil
}

// DB exposes the handle for packages that need custom queries.
func (s *Store) DB() *sql.DB { return s.db }

// Close releases the database.
func (s *Store) Close() error { return s.db.Close() }

const rfc = time.RFC3339Nano

func fmtTime(t time.Time) string { return t.UTC().Format(rfc) }

func fmtTimePtr(t *time.Time) any {
	if t == nil {
		return nil
	}
	return fmtTime(*t)
}

// UpsertAccount records or refreshes a subscription.
//
// Fields are only overwritten when the incoming value is non-empty: an agent
// that cannot read the local credential file still reports the account, and
// must not blank out the tier another endpoint already established.
func (s *Store) UpsertAccount(id model.Identity, subType, tier string) error {
	now := fmtTime(time.Now())
	var created any
	if !id.AccountCreatedAt.IsZero() {
		created = fmtTime(id.AccountCreatedAt)
	}
	_, err := s.db.Exec(`
		INSERT INTO accounts (account_uuid, email, org_uuid, org_name,
		                      subscription_type, rate_limit_tier, display_name,
		                      account_created_at, first_seen, last_seen)
		VALUES (?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(account_uuid) DO UPDATE SET
		  -- A name set by hand is never overwritten by an automatic one. The
		  -- automatic sources (a tmux window option, an env var) are hints that
		  -- come and go; a deliberate name is the operator's answer and must
		  -- outlive them.
		  email             = CASE WHEN accounts.label_locked = 1 THEN accounts.email
		                          WHEN excluded.email <> '' THEN excluded.email
		                          ELSE accounts.email END,
		  org_uuid          = CASE WHEN excluded.org_uuid          <> '' THEN excluded.org_uuid          ELSE accounts.org_uuid          END,
		  org_name          = CASE WHEN excluded.org_name          <> '' THEN excluded.org_name          ELSE accounts.org_name          END,
		  subscription_type = CASE WHEN excluded.subscription_type <> '' THEN excluded.subscription_type ELSE accounts.subscription_type END,
		  rate_limit_tier   = CASE WHEN excluded.rate_limit_tier   <> '' THEN excluded.rate_limit_tier   ELSE accounts.rate_limit_tier   END,
		  display_name      = CASE WHEN accounts.label_locked = 1 THEN accounts.display_name
		                          WHEN excluded.display_name <> '' THEN excluded.display_name
		                          ELSE accounts.display_name END,
		  account_created_at = COALESCE(excluded.account_created_at, accounts.account_created_at),
		  last_seen         = excluded.last_seen`,
		id.AccountUUID, id.Email, id.OrgUUID, id.OrgName,
		subType, tier, id.DisplayName, created, now, now)
	if err != nil {
		return fmt.Errorf("upsert account: %w", err)
	}
	return nil
}

// SetAccountLabel names a subscription for good.
//
// Fingerprinted subscriptions have no email to discover — the reset schedule
// identifies them correctly but cannot say who they belong to. This records the
// operator's answer and locks it, so the next automatic report cannot quietly
// replace it with a hint or blank it out.
//
// Passing an empty label unlocks the account and lets automatic naming resume.
func (s *Store) SetAccountLabel(account, label string) error {
	if account == "" {
		return fmt.Errorf("account is required")
	}
	locked := 1
	if label == "" {
		locked = 0
	}
	res, err := s.db.Exec(
		`UPDATE accounts SET email = ?, label_locked = ? WHERE account_uuid = ?`,
		label, locked, account)
	if err != nil {
		return fmt.Errorf("set account label: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("no such subscription %q on this hub", account)
	}
	return nil
}

// Endpoint is a registered collector.
type Endpoint struct {
	ID           string `json:"endpoint_id"`
	AccountUUID  string `json:"account_uuid"`
	Label        string `json:"label"`
	Hostname     string `json:"hostname"`
	OS           string `json:"os"`
	Arch         string `json:"arch"`
	MachineID    string `json:"machine_id"`
	CCVersion    string `json:"cc_version"`
	AgentVersion string `json:"agent_version"`
	// OSUser is the OS login the agent runs as. An endpoint is a (machine,
	// user) pair, not a machine.
	OSUser string `json:"os_user"`
	// Team is the operator's allocation of this endpoint's spend. Empty means
	// unassigned, which the UI renders as "unassigned" rather than hiding.
	Team       string     `json:"team"`
	EnrolledAt time.Time  `json:"enrolled_at"`
	LastSeen   *time.Time `json:"last_seen"`

	// What this endpoint could not attribute. Surfaced so a total that
	// excludes history says so, instead of just looking smaller.
	DroppedPreAccount     int64      `json:"dropped_pre_account"`
	EarliestDropped       *time.Time `json:"earliest_dropped,omitempty"`
	DroppedBeyondBackfill int64      `json:"dropped_beyond_backfill"`
	BackfillLimit         string     `json:"backfill_limit,omitempty"`

	LimitsUnavailable string `json:"limits_unavailable,omitempty"`
}

// Enroll registers a new endpoint and stores only the hash of its token.
func (s *Store) Enroll(endpointID, label, tokenHash string) error {
	_, err := s.db.Exec(`
		INSERT INTO endpoints (endpoint_id, account_uuid, label, token_hash, enrolled_at)
		VALUES (?, NULL, ?, ?, ?)`,
		endpointID, label, tokenHash, fmtTime(time.Now()))
	if err != nil {
		return fmt.Errorf("enroll endpoint: %w", err)
	}
	return nil
}

// EndpointByTokenHash resolves an enrollment token to its endpoint.
func (s *Store) EndpointByTokenHash(hash string) (*Endpoint, error) {
	row := s.db.QueryRow(endpointColumns+` FROM endpoints WHERE token_hash = ?`, hash)
	return scanEndpoint(row)
}

// endpointColumns keeps the SELECT list and scanEndpoint in lockstep; they
// drifted apart once already when a column was added.
const endpointColumns = `
	SELECT endpoint_id, account_uuid, label, hostname, os, arch, machine_id,
	       cc_version, agent_version, os_user, team, enrolled_at, last_seen,
	       dropped_pre_account, earliest_dropped, dropped_beyond_backfill,
	       backfill_limit, limits_unavailable`

type rowScanner interface{ Scan(...any) error }

func scanEndpoint(row rowScanner) (*Endpoint, error) {
	var e Endpoint
	var enrolled string
	var lastSeen, account, earliest sql.NullString
	err := row.Scan(&e.ID, &account, &e.Label, &e.Hostname, &e.OS, &e.Arch,
		&e.MachineID, &e.CCVersion, &e.AgentVersion, &e.OSUser, &e.Team, &enrolled, &lastSeen,
		&e.DroppedPreAccount, &earliest, &e.DroppedBeyondBackfill,
		&e.BackfillLimit, &e.LimitsUnavailable)
	if err != nil {
		return nil, err
	}
	e.AccountUUID = account.String
	e.EnrolledAt, _ = time.Parse(rfc, enrolled)
	if lastSeen.Valid {
		if t, err := time.Parse(rfc, lastSeen.String); err == nil {
			e.LastSeen = &t
		}
	}
	e.EarliestDropped = parseNullTime(earliest)
	return &e, nil
}

// TouchEndpoint records what an endpoint reported about itself on this push.
//
// login says whether this batch carries the endpoint's OWN Claude Code login.
// Only such a batch may CHANGE endpoints.account_uuid: a batch for a
// subscription merely observed running on the machine says nothing about what
// the machine is logged into, and letting it write there is what manufactured a
// switch history out of ordinary concurrency.
//
// An endpoint that has never reported is the exception — it takes whatever
// arrives first, including from an agent too old to say. Refusing to fill an
// empty slot would leave the endpoint with no account at all, and every
// account-scoped query (limits above all) silently blind to it.
//
// prevWasLogin says whether the outgoing account had itself been established by
// a login batch. Only then is a change a real logout/login; otherwise it is a
// provisional guess being corrected, which is not a seam in the history.
func (s *Store) TouchEndpoint(endpointID string, id model.Identity, agentVersion string, login bool) (prevAccount string, prevWasLogin bool, err error) {
	var prev sql.NullString
	if err := s.db.QueryRow(`SELECT account_uuid FROM endpoints WHERE endpoint_id = ?`,
		endpointID).Scan(&prev); err != nil {
		return "", false, fmt.Errorf("look up endpoint: %w", err)
	}
	prevAccount = prev.String

	if prevAccount != "" {
		var origin string
		switch err := s.db.QueryRow(`
			SELECT origin FROM endpoint_accounts
			WHERE endpoint_id = ? AND account_uuid = ?`, endpointID, prevAccount).Scan(&origin); {
		case err == nil:
			prevWasLogin = origin == string(model.OriginLogin)
		case errors.Is(err, sql.ErrNoRows):
			// Recorded before this table existed. Treat it as a login: that is
			// what the old code meant by endpoints.account_uuid.
			prevWasLogin = true
		default:
			return "", false, fmt.Errorf("look up endpoint account origin: %w", err)
		}
	}

	if login || prevAccount == "" {
		_, err = s.db.Exec(`
			UPDATE endpoints SET account_uuid = ?, hostname = ?, os = ?, arch = ?,
			       machine_id = ?, cc_version = ?, agent_version = ?, os_user = ?,
			       last_seen = ?
			WHERE endpoint_id = ?`,
			id.AccountUUID, id.Hostname, id.OS, id.Arch, id.MachineID,
			id.CCVersion, agentVersion, id.OSUser, fmtTime(time.Now()), endpointID)
	} else {
		// Everything except the account: the machine is still reporting, and
		// its hardware facts are just as true on a secondary batch.
		_, err = s.db.Exec(`
			UPDATE endpoints SET hostname = ?, os = ?, arch = ?,
			       machine_id = ?, cc_version = ?, agent_version = ?, os_user = ?,
			       last_seen = ?
			WHERE endpoint_id = ?`,
			id.Hostname, id.OS, id.Arch, id.MachineID,
			id.CCVersion, agentVersion, id.OSUser, fmtTime(time.Now()), endpointID)
	}
	if err != nil {
		return "", false, fmt.Errorf("touch endpoint: %w", err)
	}
	return prevAccount, prevWasLogin, nil
}

// RecordEndpointAccount notes that this endpoint was seen running account,
// extending the window rather than replacing anything. Several accounts on one
// endpoint are normal and concurrent, so these rows accumulate; they never
// compete.
func (s *Store) RecordEndpointAccount(endpointID, account string, origin model.AccountOrigin) error {
	if account == "" {
		return nil
	}
	now := fmtTime(time.Now())
	if origin == "" {
		origin = model.OriginSession
	}
	_, err := s.db.Exec(`
		INSERT INTO endpoint_accounts (endpoint_id, account_uuid, origin, first_seen, last_seen)
		VALUES (?,?,?,?,?)
		ON CONFLICT(endpoint_id, account_uuid) DO UPDATE SET
		  last_seen = excluded.last_seen,
		  -- 'login' is the stronger claim: once an account has been seen as
		  -- this endpoint's own login, a later session sighting must not
		  -- demote it back to a guest.
		  origin = CASE WHEN endpoint_accounts.origin = 'login' THEN 'login'
		                ELSE excluded.origin END`,
		endpointID, account, string(origin), now, now)
	if err != nil {
		return fmt.Errorf("record endpoint account: %w", err)
	}
	return nil
}

// DemoteEndpointLogin marks any OTHER account on this endpoint as a guest.
//
// An endpoint has exactly one login at a time and any number of concurrent
// guests — the whole point of endpoint_accounts. But 'login' is sticky, so that
// a session sighting cannot demote a real login, and nothing ever un-stuck it:
// after a genuine logout/login the previous account kept claiming to be this
// machine's own login, and the dashboard showed one machine with two.
//
// The row is not deleted. Sessions started under the old account keep running
// and keep reporting, which is exactly what 'session' means.
func (s *Store) DemoteEndpointLogin(endpointID, keepLogin string) error {
	_, err := s.db.Exec(`
		UPDATE endpoint_accounts SET origin = 'session'
		WHERE endpoint_id = ? AND account_uuid <> ? AND origin = 'login'`,
		endpointID, keepLogin)
	if err != nil {
		return fmt.Errorf("demote endpoint login: %w", err)
	}
	return nil
}

// RecordAccountSwitch notes that an endpoint changed the account it is logged
// into. Call it only for a login-origin batch — see TouchEndpoint.
func (s *Store) RecordAccountSwitch(endpointID, from, to string) error {
	_, err := s.db.Exec(`
		INSERT INTO account_switches (endpoint_id, from_account, to_account, observed_at)
		VALUES (?,?,?,?)`, endpointID, from, to, fmtTime(time.Now()))
	if err != nil {
		return fmt.Errorf("record account switch: %w", err)
	}
	return nil
}

// InsertEvents stores events, ignoring ones already present.
//
// Returns how many were new and how many were duplicates, which the agent uses
// to confirm its cursor is behaving.
func (s *Store) InsertEvents(evs []model.UsageEvent) (inserted, deduped int, err error) {
	if len(evs) == 0 {
		return 0, 0, nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return 0, 0, fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback()

	stmt, err := tx.Prepare(`
		INSERT OR IGNORE INTO usage_events (
		  account_uuid, endpoint_id, session_id, message_uuid, request_id, ts, model,
		  input_tokens, output_tokens, cache_create_5m_tokens, cache_create_1h_tokens,
		  cache_read_tokens, thinking_tokens, web_search_requests, web_fetch_requests,
		  cost_usd, cwd, os_user, git_branch, entrypoint, effort, is_sidechain
		) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`)
	if err != nil {
		return 0, 0, fmt.Errorf("prepare insert: %w", err)
	}
	defer stmt.Close()

	for i := range evs {
		e := &evs[i]
		var cost any
		if e.CostUSD != nil {
			cost = *e.CostUSD
		}
		res, err := stmt.Exec(
			e.AccountUUID, e.EndpointID, e.SessionID, e.MessageUUID, e.RequestID,
			fmtTime(e.TS), e.Model,
			e.InputTokens, e.OutputTokens, e.CacheCreate5m, e.CacheCreate1h,
			e.CacheRead, e.Thinking, e.WebSearchRequests, e.WebFetchRequests,
			cost, e.CWD, e.OSUser, e.GitBranch, e.Entrypoint, e.Effort, e.IsSidechain)
		if err != nil {
			return 0, 0, fmt.Errorf("insert event %s: %w", e.MessageUUID, err)
		}
		if n, _ := res.RowsAffected(); n > 0 {
			inserted++
		} else {
			deduped++
		}
	}
	if err := tx.Commit(); err != nil {
		return 0, 0, fmt.Errorf("commit: %w", err)
	}
	return inserted, deduped, nil
}

// InsertLimits stores one limits observation.
func (s *Store) InsertLimits(snap *model.LimitsSnapshot) error {
	scoped, err := json.Marshal(snap.Scoped)
	if err != nil {
		return fmt.Errorf("encode scoped windows: %w", err)
	}
	_, err = s.db.Exec(`
		INSERT INTO limit_snapshots (
		  account_uuid, endpoint_id, observed_at,
		  five_hour_pct, five_hour_resets_at, seven_day_pct, seven_day_resets_at,
		  scoped_json, extra_usage_json, spend_json, raw_json
		) VALUES (?,?,?,?,?,?,?,?,?,?,?)`,
		snap.AccountUUID, snap.EndpointID, fmtTime(snap.ObservedAt),
		snap.FiveHour.Utilization, fmtTimePtr(snap.FiveHour.ResetsAt),
		snap.SevenDay.Utilization, fmtTimePtr(snap.SevenDay.ResetsAt),
		string(scoped), snap.ExtraUsageJSON, snap.SpendJSON, snap.RawJSON)
	if err != nil {
		return fmt.Errorf("insert limits snapshot: %w", err)
	}
	return nil
}

// PruneEvents deletes raw events older than the retention window. Rollups and
// limit snapshots are unaffected.
func (s *Store) PruneEvents(olderThan time.Time) (int64, error) {
	res, err := s.db.Exec(`DELETE FROM usage_events WHERE ts < ?`, fmtTime(olderThan))
	if err != nil {
		return 0, fmt.Errorf("prune events: %w", err)
	}
	n, _ := res.RowsAffected()
	return n, nil
}

// SetEndpointTeam allocates an endpoint's spend to a team.
//
// Operator-side on purpose: this is the only writer of endpoints.team, and the
// ingest path (TouchEndpoint) deliberately does not name the column. Passing an
// empty team un-assigns it.
func (s *Store) SetEndpointTeam(endpointID, team string) error {
	if endpointID == "" {
		return fmt.Errorf("endpoint id is required")
	}
	res, err := s.db.Exec(`UPDATE endpoints SET team = ? WHERE endpoint_id = ?`, team, endpointID)
	if err != nil {
		return fmt.Errorf("set endpoint team: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("no endpoint %q on this hub (run `ccquota team --list` to see them)", endpointID)
	}
	return nil
}
