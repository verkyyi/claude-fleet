package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Session passes — 会话通行证 (claude-fleet#1969, EPIC #1967 C2).
//
// An untrusted machine never leases a subscription credential (C1); a session
// on it borrows a pass instead: a hub-signed token good for one person, one
// session, a day at most, and revocable at any moment. The token itself is
// the api package's (fcp-h1.<claims>.<HMAC>); the store keeps one row per
// pass so that a revocation is a row, every verify can see it, and the
// operator can list what is out. No secret is stored here: the row is the
// pass's metadata, the signature key lives only in the hub's environment.
const fleetSessionCredsSchema = `
CREATE TABLE IF NOT EXISTS fleet_session_creds (
  id           TEXT PRIMARY KEY,
  principal_id TEXT NOT NULL,
  worker_id    TEXT NOT NULL,
  worker_key   TEXT NOT NULL DEFAULT '',
  fleet_id     TEXT NOT NULL DEFAULT '',
  machine      TEXT NOT NULL,
  os_user      TEXT NOT NULL DEFAULT '',
  endpoint_id  TEXT NOT NULL,
  providers    TEXT NOT NULL,
  issued_at    TEXT NOT NULL,
  expires_at   TEXT NOT NULL,
  renewed_at   TEXT,
  revoked_at   TEXT,
  revoked_by   TEXT NOT NULL DEFAULT '',
  reason       TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS fleet_session_creds_worker ON fleet_session_creds(worker_id);`

// SessionCred is one pass's row.
type SessionCred struct {
	ID          string     `json:"id"`
	PrincipalID string     `json:"principal_id"`
	WorkerID    string     `json:"worker_id"`
	WorkerKey   string     `json:"worker_key,omitempty"`
	FleetID     string     `json:"fleet_id,omitempty"`
	Machine     string     `json:"machine"`
	OSUser      string     `json:"os_user,omitempty"`
	EndpointID  string     `json:"endpoint_id"`
	Providers   []string   `json:"providers"`
	IssuedAt    time.Time  `json:"issued_at"`
	ExpiresAt   time.Time  `json:"expires_at"`
	RenewedAt   *time.Time `json:"renewed_at,omitempty"`
	RevokedAt   *time.Time `json:"revoked_at,omitempty"`
	RevokedBy   string     `json:"revoked_by,omitempty"`
	Reason      string     `json:"reason,omitempty"`
}

// sessRFC is fixed-width in UTC, so the SQL's expires_at > now compares as
// time does (RFC3339Nano trims trailing zeros and would not). Passes live
// for hours; a second is precision enough.
const sessRFC = "2006-01-02T15:04:05Z"

// ErrNoSessionCred is returned for an unknown pass id.
var ErrNoSessionCred = errors.New("no such session pass")

func (s *Store) ensureFleetSessionCreds() error {
	if _, err := s.write.Exec(fleetSessionCredsSchema); err != nil {
		return fmt.Errorf("create fleet session pass table: %w", err)
	}
	return nil
}

// AddSessionCred records a newly issued pass.
func (s *Store) AddSessionCred(c SessionCred) error {
	_, err := s.write.Exec(`INSERT INTO fleet_session_creds (id, principal_id, worker_id, worker_key, fleet_id,
		machine, os_user, endpoint_id, providers, issued_at, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, c.ID, c.PrincipalID, c.WorkerID, c.WorkerKey, c.FleetID,
		c.Machine, c.OSUser, c.EndpointID, strings.Join(c.Providers, ","),
		c.IssuedAt.UTC().Format(sessRFC), c.ExpiresAt.UTC().Format(sessRFC))
	return err
}

const sessionCredCols = `id, principal_id, worker_id, worker_key, fleet_id, machine, os_user, endpoint_id,
	providers, issued_at, expires_at, renewed_at, revoked_at, revoked_by, reason`

func scanSessionCred(sc interface{ Scan(...any) error }) (SessionCred, error) {
	var c SessionCred
	var providers, issued, expires string
	var renewed, revoked sql.NullString
	if err := sc.Scan(&c.ID, &c.PrincipalID, &c.WorkerID, &c.WorkerKey, &c.FleetID, &c.Machine, &c.OSUser,
		&c.EndpointID, &providers, &issued, &expires, &renewed, &revoked, &c.RevokedBy, &c.Reason); err != nil {
		return c, err
	}
	if providers != "" {
		c.Providers = strings.Split(providers, ",")
	}
	c.IssuedAt, _ = time.Parse(time.RFC3339, issued)
	c.ExpiresAt, _ = time.Parse(time.RFC3339, expires)
	if renewed.Valid {
		t, _ := time.Parse(time.RFC3339, renewed.String)
		c.RenewedAt = &t
	}
	if revoked.Valid {
		t, _ := time.Parse(time.RFC3339, revoked.String)
		c.RevokedAt = &t
	}
	return c, nil
}

// SessionCredByID is one pass, ErrNoSessionCred when there is none.
func (s *Store) SessionCredByID(id string) (SessionCred, error) {
	c, err := scanSessionCred(s.write.QueryRow(`SELECT `+sessionCredCols+` FROM fleet_session_creds WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return c, ErrNoSessionCred
	}
	return c, err
}

// SessionCreds lists the newest passes first; activeOnly leaves out revoked
// and expired ones (as of now).
func (s *Store) SessionCreds(activeOnly bool, now time.Time, limit int) ([]SessionCred, error) {
	if limit <= 0 || limit > 1000 {
		limit = 200
	}
	q := `SELECT ` + sessionCredCols + ` FROM fleet_session_creds`
	args := []any{}
	if activeOnly {
		q += ` WHERE revoked_at IS NULL AND expires_at > ?`
		args = append(args, now.UTC().Format(sessRFC))
	}
	q += ` ORDER BY issued_at DESC, id LIMIT ?`
	args = append(args, limit)
	rows, err := s.write.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []SessionCred{}
	for rows.Next() {
		c, err := scanSessionCred(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// RenewSessionCred moves a live pass's expiry; false when the pass is gone,
// revoked or already expired (nothing changes).
func (s *Store) RenewSessionCred(id string, exp, at time.Time) (bool, error) {
	ts := at.UTC().Format(sessRFC)
	res, err := s.write.Exec(`UPDATE fleet_session_creds SET expires_at = ?, renewed_at = ?
		WHERE id = ? AND revoked_at IS NULL AND expires_at > ?`, exp.UTC().Format(sessRFC), ts, id, ts)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n == 1, nil
}

// RevokeSessionCred revokes a pass; false when it was unknown or already
// revoked (the first revocation's time and actor stand).
func (s *Store) RevokeSessionCred(id, by, reason string, at time.Time) (bool, error) {
	res, err := s.write.Exec(`UPDATE fleet_session_creds SET revoked_at = ?, revoked_by = ?, reason = ?
		WHERE id = ? AND revoked_at IS NULL`, at.UTC().Format(sessRFC), by, reason, id)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n == 1, nil
}
