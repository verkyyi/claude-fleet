package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// Session account bindings — which subscription account a session on an
// untrusted machine is using (claude-fleet#1973, EPIC #1967 C6).
//
// On a trusted machine the login's own credential proxy keeps the binding
// (bind.json: sid → account label; `fleet-cred-proxy.py rebind`). A session
// on an untrusted machine has no credential there to bind: the cluster
// credential proxy swaps its pass for the real credential, so the hub keeps
// the same binding for it, keyed by the session's worker_id. The semantics
// are the local proxy's: one account per (session, provider), picked once
// and kept, changed only by a rebind, effective on the session's next
// request.
const fleetSessionBindsSchema = `
CREATE TABLE IF NOT EXISTS fleet_session_binds (
  worker_id  TEXT NOT NULL,
  provider   TEXT NOT NULL,
  owner      TEXT NOT NULL,
  account    TEXT NOT NULL,
  set_by     TEXT NOT NULL DEFAULT '',
  rev        INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (worker_id, provider)
);`

// SessionBind is one session's account for one provider. Owner is the
// principal the credential row belongs to — the person, or PoolPrincipal for
// a shared-pool account. Rev counts the binding's changes (1 = first pick).
type SessionBind struct {
	WorkerID  string    `json:"worker_id"`
	Provider  string    `json:"provider"`
	Owner     string    `json:"owner"`
	Account   string    `json:"account"`
	SetBy     string    `json:"set_by,omitempty"`
	Rev       int64     `json:"rev"`
	UpdatedAt time.Time `json:"updated_at"`
}

// ErrNoSessionBind is returned when a session has no binding yet.
var ErrNoSessionBind = errors.New("no account binding for this session")

func (s *Store) ensureFleetSessionBinds() error {
	if _, err := s.write.Exec(fleetSessionBindsSchema); err != nil {
		return fmt.Errorf("create fleet session bind table: %w", err)
	}
	return nil
}

// SessionBindFor is a session's binding for one provider.
func (s *Store) SessionBindFor(workerID, provider string) (SessionBind, error) {
	b := SessionBind{WorkerID: workerID, Provider: provider}
	var at string
	err := s.write.QueryRow(`SELECT owner, account, set_by, rev, updated_at FROM fleet_session_binds
		WHERE worker_id = ? AND provider = ?`, workerID, provider).Scan(&b.Owner, &b.Account, &b.SetBy, &b.Rev, &at)
	if errors.Is(err, sql.ErrNoRows) {
		return b, ErrNoSessionBind
	}
	if err != nil {
		return b, err
	}
	b.UpdatedAt, _ = time.Parse(time.RFC3339, at)
	return b, nil
}

// PickSessionBind records a session's first binding unless it already has
// one, and returns whichever binding stands — so two replicas picking at once
// agree on the first writer's.
func (s *Store) PickSessionBind(b SessionBind, at time.Time) (SessionBind, error) {
	if _, err := s.write.Exec(`INSERT INTO fleet_session_binds (worker_id, provider, owner, account, set_by, rev, updated_at)
		VALUES (?, ?, ?, ?, ?, 1, ?) ON CONFLICT (worker_id, provider) DO NOTHING`,
		b.WorkerID, b.Provider, b.Owner, b.Account, b.SetBy, at.UTC().Format(sessRFC)); err != nil {
		return b, err
	}
	return s.SessionBindFor(b.WorkerID, b.Provider)
}

// SetSessionBind rebinds a session (or binds it for the first time).
func (s *Store) SetSessionBind(b SessionBind, at time.Time) (SessionBind, error) {
	if _, err := s.write.Exec(`INSERT INTO fleet_session_binds (worker_id, provider, owner, account, set_by, rev, updated_at)
		VALUES (?, ?, ?, ?, ?, 1, ?) ON CONFLICT (worker_id, provider) DO UPDATE SET
		owner = excluded.owner, account = excluded.account, set_by = excluded.set_by,
		rev = fleet_session_binds.rev + 1, updated_at = excluded.updated_at`,
		b.WorkerID, b.Provider, b.Owner, b.Account, b.SetBy, at.UTC().Format(sessRFC)); err != nil {
		return b, err
	}
	return s.SessionBindFor(b.WorkerID, b.Provider)
}

// SessionBinds lists a session's bindings, every provider.
func (s *Store) SessionBinds(workerID string) ([]SessionBind, error) {
	rows, err := s.write.Query(`SELECT provider, owner, account, set_by, rev, updated_at FROM fleet_session_binds
		WHERE worker_id = ? ORDER BY provider`, workerID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []SessionBind{}
	for rows.Next() {
		b := SessionBind{WorkerID: workerID}
		var at string
		if err := rows.Scan(&b.Provider, &b.Owner, &b.Account, &b.SetBy, &b.Rev, &at); err != nil {
			return nil, err
		}
		b.UpdatedAt, _ = time.Parse(time.RFC3339, at)
		out = append(out, b)
	}
	return out, rows.Err()
}
