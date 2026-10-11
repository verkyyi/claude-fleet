package store

import (
	"errors"
	"fmt"
	"strings"
	"time"
)

// Pool usage — every request that rode the subscription pool, one row each,
// filed under the person who leased it (claude-fleet#3226, EPIC #3225 C1).
//
// The person is never a proxy's say-so: the cluster credential proxy reports
// with the session pass it forwarded, and the hub files the row under that
// pass's principal (a body naming anyone else is refused); a login's local
// proxy reports with its node token, and the row goes to the login's person.
// repo / issue are read from the session's lease (fleet_leases, by worker_id)
// when the row is written and frozen there — empty = 「没挂在任务上」.
//
// A person's budget (fleet.person_budget.<principal>) sums the same rows, so
// what a person reads and what they are held to cannot disagree. Tokens
// counted against a budget: input + cache writes + output (cache reads are
// kept, never counted). fleet_person_usage, the ten-minute buckets this
// replaced, is no longer written; its rows age out of every window in a week.
const poolUsageSchema = `
CREATE TABLE IF NOT EXISTS pool_usage (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  principal   TEXT NOT NULL,
  worker_id   TEXT NOT NULL DEFAULT '',
  account     TEXT NOT NULL DEFAULT '',
  provider    TEXT NOT NULL,
  model       TEXT NOT NULL DEFAULT '',
  tokens_in   INTEGER NOT NULL DEFAULT 0,
  cache_write INTEGER NOT NULL DEFAULT 0,
  cache_read  INTEGER NOT NULL DEFAULT 0,
  tokens_out  INTEGER NOT NULL DEFAULT 0,
  requests    INTEGER NOT NULL DEFAULT 1,
  at_unix     INTEGER NOT NULL,
  repo        TEXT NOT NULL DEFAULT '',
  issue       INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS pool_usage_principal_at ON pool_usage(principal, at_unix);
CREATE INDEX IF NOT EXISTS pool_usage_at ON pool_usage(at_unix);`

// PoolUsage is one request (or, from a login's local proxy, one report of
// several — Requests says how many) on the subscription pool.
type PoolUsage struct {
	Principal  string    `json:"principal"`
	WorkerID   string    `json:"worker_id,omitempty"`
	Account    string    `json:"account,omitempty"`
	Provider   string    `json:"provider"`
	Model      string    `json:"model,omitempty"`
	In         int64     `json:"in"`
	CacheWrite int64     `json:"cache_write"`
	CacheRead  int64     `json:"cache_read"`
	Out        int64     `json:"out"`
	Requests   int64     `json:"requests"`
	At         time.Time `json:"at"`
	Repo       string    `json:"repo,omitempty"`
	Issue      int       `json:"issue,omitempty"`
}

// Tokens is what a budget counts: input + cache writes + output.
func (u PoolUsage) Tokens() int64 { return u.In + u.CacheWrite + u.Out }

// ErrPoolUsageNoPrincipal refuses a row with no person: the pool has no
// ownerless usage, so one is a bug upstream, never a row.
var ErrPoolUsageNoPrincipal = errors.New("pool usage needs a principal")

func (s *Store) ensurePoolUsage() error {
	if _, err := s.write.Exec(s.d.ddl(poolUsageSchema)); err != nil {
		return fmt.Errorf("create pool usage table: %w", err)
	}
	return nil
}

// AddPoolUsage writes one row. A row with nothing in it is skipped.
func (s *Store) AddPoolUsage(u PoolUsage) error {
	if strings.TrimSpace(u.Principal) == "" {
		return ErrPoolUsageNoPrincipal
	}
	if u.Tokens() <= 0 && u.CacheRead <= 0 {
		return nil
	}
	if u.Requests <= 0 {
		u.Requests = 1
	}
	_, err := s.write.Exec(`INSERT INTO pool_usage (principal, worker_id, account, provider, model,
		tokens_in, cache_write, cache_read, tokens_out, requests, at_unix, repo, issue)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		u.Principal, u.WorkerID, u.Account, u.Provider, u.Model,
		u.In, u.CacheWrite, u.CacheRead, u.Out, u.Requests, u.At.Unix(), u.Repo, u.Issue)
	return err
}

// PoolUsageFor lists principal's rows with since ≤ at < until, oldest first;
// principal "" is everyone, a zero until is now and onward.
func (s *Store) PoolUsageFor(principal string, since, until time.Time) ([]PoolUsage, error) {
	q := `SELECT principal, worker_id, account, provider, model, tokens_in, cache_write, cache_read,
		tokens_out, requests, at_unix, repo, issue FROM pool_usage WHERE at_unix >= ?`
	args := []any{since.Unix()}
	if !until.IsZero() {
		q += ` AND at_unix < ?`
		args = append(args, until.Unix())
	}
	if principal != "" {
		q += ` AND principal = ?`
		args = append(args, principal)
	}
	rows, err := s.write.Query(q+` ORDER BY at_unix, id`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PoolUsage
	for rows.Next() {
		var u PoolUsage
		var at int64
		if err := rows.Scan(&u.Principal, &u.WorkerID, &u.Account, &u.Provider, &u.Model, &u.In, &u.CacheWrite,
			&u.CacheRead, &u.Out, &u.Requests, &at, &u.Repo, &u.Issue); err != nil {
			return nil, err
		}
		u.At = time.Unix(at, 0).UTC()
		out = append(out, u)
	}
	return out, rows.Err()
}

// LeaseForWorker is the (repo, issue) worker holds a live lease on at at —
// the task a pool request is filed under. ok false = it holds none (a scratch,
// the orchestrator, a session whose lease lapsed).
func (s *Store) LeaseForWorker(workerID string, at time.Time) (repo string, issue int, ok bool, err error) {
	if workerID == "" {
		return "", 0, false, nil
	}
	rows, err := s.read.Query(`SELECT `+leaseCols+` FROM fleet_leases WHERE worker_id = ?`, workerID)
	if err != nil {
		return "", 0, false, err
	}
	defer rows.Close()
	var best Lease
	for rows.Next() {
		l, err := scanLease(rows)
		if err != nil {
			return "", 0, false, err
		}
		// the newest live one, should a worker ever hold two
		if l.ExpiresAt.After(at) && (!ok || l.AcquiredAt.After(best.AcquiredAt)) {
			best, ok = l, true
		}
	}
	if err := rows.Err(); err != nil {
		return "", 0, false, err
	}
	return best.Repo, best.Issue, ok, nil
}
