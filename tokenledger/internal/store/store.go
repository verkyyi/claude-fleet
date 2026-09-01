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
	_, err := s.db.Exec(`
		INSERT INTO accounts (account_uuid, email, org_uuid, org_name,
		                      subscription_type, rate_limit_tier, display_name,
		                      first_seen, last_seen)
		VALUES (?,?,?,?,?,?,?,?,?)
		ON CONFLICT(account_uuid) DO UPDATE SET
		  email             = CASE WHEN excluded.email             <> '' THEN excluded.email             ELSE accounts.email             END,
		  org_uuid          = CASE WHEN excluded.org_uuid          <> '' THEN excluded.org_uuid          ELSE accounts.org_uuid          END,
		  org_name          = CASE WHEN excluded.org_name          <> '' THEN excluded.org_name          ELSE accounts.org_name          END,
		  subscription_type = CASE WHEN excluded.subscription_type <> '' THEN excluded.subscription_type ELSE accounts.subscription_type END,
		  rate_limit_tier   = CASE WHEN excluded.rate_limit_tier   <> '' THEN excluded.rate_limit_tier   ELSE accounts.rate_limit_tier   END,
		  display_name      = CASE WHEN excluded.display_name      <> '' THEN excluded.display_name      ELSE accounts.display_name      END,
		  last_seen         = excluded.last_seen`,
		id.AccountUUID, id.Email, id.OrgUUID, id.OrgName,
		subType, tier, id.DisplayName, now, now)
	if err != nil {
		return fmt.Errorf("upsert account: %w", err)
	}
	return nil
}

// Endpoint is a registered collector.
type Endpoint struct {
	ID           string     `json:"endpoint_id"`
	AccountUUID  string     `json:"account_uuid"`
	Label        string     `json:"label"`
	Hostname     string     `json:"hostname"`
	OS           string     `json:"os"`
	Arch         string     `json:"arch"`
	MachineID    string     `json:"machine_id"`
	CCVersion    string     `json:"cc_version"`
	AgentVersion string     `json:"agent_version"`
	EnrolledAt   time.Time  `json:"enrolled_at"`
	LastSeen     *time.Time `json:"last_seen"`
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
	row := s.db.QueryRow(`
		SELECT endpoint_id, account_uuid, label, hostname, os, arch, machine_id,
		       cc_version, agent_version, enrolled_at, last_seen
		FROM endpoints WHERE token_hash = ?`, hash)
	return scanEndpoint(row)
}

type rowScanner interface{ Scan(...any) error }

func scanEndpoint(row rowScanner) (*Endpoint, error) {
	var e Endpoint
	var enrolled string
	var lastSeen, account sql.NullString
	err := row.Scan(&e.ID, &account, &e.Label, &e.Hostname, &e.OS, &e.Arch,
		&e.MachineID, &e.CCVersion, &e.AgentVersion, &enrolled, &lastSeen)
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
	return &e, nil
}

// TouchEndpoint records what an endpoint reported about itself on this push.
//
// It returns the previous account uuid so the caller can detect and record a
// login switch.
func (s *Store) TouchEndpoint(endpointID string, id model.Identity, agentVersion string) (prevAccount string, err error) {
	var prev sql.NullString
	if err := s.db.QueryRow(`SELECT account_uuid FROM endpoints WHERE endpoint_id = ?`,
		endpointID).Scan(&prev); err != nil {
		return "", fmt.Errorf("look up endpoint: %w", err)
	}
	prevAccount = prev.String
	_, err = s.db.Exec(`
		UPDATE endpoints SET account_uuid = ?, hostname = ?, os = ?, arch = ?,
		       machine_id = ?, cc_version = ?, agent_version = ?, last_seen = ?
		WHERE endpoint_id = ?`,
		id.AccountUUID, id.Hostname, id.OS, id.Arch, id.MachineID,
		id.CCVersion, agentVersion, fmtTime(time.Now()), endpointID)
	if err != nil {
		return "", fmt.Errorf("touch endpoint: %w", err)
	}
	return prevAccount, nil
}

// RecordAccountSwitch notes that an endpoint changed subscription.
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
		  cost_usd, cwd, git_branch, entrypoint, effort, is_sidechain
		) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`)
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
			cost, e.CWD, e.GitBranch, e.Entrypoint, e.Effort, e.IsSidechain)
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
