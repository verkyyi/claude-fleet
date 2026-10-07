package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Issue leases (claude-fleet#1422, EPIC #1419 C3): before a node opens a
// session on (repo, issue) it takes that pair's lease here, and only the holder
// may open it. GitHub's assignee check stays behind it as the second guard —
// GitHub has no compare-and-swap, this table does: Acquire is one transaction
// that holds the row it judges (claimWrites / forUpdate, dialect.go), so two
// hubs on one database still grant a lease once (TestLeaseRaceTwoWriters).
//
// A lease lives as long as its holder keeps reporting the session:
//
//   - Acquire grants it for a start grace — the window does not exist yet, so
//     no heartbeat can show it.
//   - Every heartbeat from the holder that lists the session (RenewLeases)
//     pushes its expiry out by the lost TTL and marks it seen.
//   - A heartbeat that read the holder's fleet fine but no longer lists a seen
//     session releases the lease: the session ended or was reaped.
//   - A holder that stops reporting renews nothing, so the lease runs out one
//     lost TTL after its last renewal. It is only released — nothing is
//     re-dispatched (EPIC #1419 发起人拍板 2).
//
// Like every fleet table, this one exists only under CCQUOTA_FLEET=1 (created by
// EnsureNodes).
const fleetLeasesSchema = `
CREATE TABLE IF NOT EXISTS fleet_leases (
  repo        TEXT NOT NULL,
  issue       INTEGER NOT NULL,
  worker_id   TEXT NOT NULL,
  fleet_id    TEXT NOT NULL,
  endpoint_id TEXT NOT NULL,
  hostname    TEXT NOT NULL DEFAULT '',
  os_user     TEXT NOT NULL DEFAULT '',
  acquired_at TEXT NOT NULL,
  renewed_at  TEXT NOT NULL,
  expires_at  TEXT NOT NULL,
  seen        INTEGER NOT NULL DEFAULT 0,
  forced      INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (repo, issue)
);
CREATE INDEX IF NOT EXISTS fleet_leases_endpoint ON fleet_leases(endpoint_id);`

// Lease is one held (repo, issue).
type Lease struct {
	Repo       string    `json:"repo"`
	Issue      int       `json:"issue"`
	WorkerID   string    `json:"worker_id"`
	FleetID    string    `json:"fleet_id"`
	EndpointID string    `json:"endpoint_id"`
	Hostname   string    `json:"hostname"`
	OSUser     string    `json:"os_user"`
	AcquiredAt time.Time `json:"acquired_at"`
	RenewedAt  time.Time `json:"renewed_at"`
	ExpiresAt  time.Time `json:"expires_at"`
	Seen       bool      `json:"seen"`
	Forced     bool      `json:"forced"`
}

// LeaseClaim is one node's request for (Repo, Issue).
type LeaseClaim struct {
	Repo       string
	Issue      int
	WorkerID   string
	FleetID    string
	EndpointID string
	Hostname   string
	OSUser     string
	// Force takes the lease from a live holder (dash-issue-session.sh
	// --force). The caller records the takeover; Acquire reports whom it
	// displaced.
	Force bool
}

// NormRepo is the lease table's spelling of a repo: owner/name, lower case.
func NormRepo(repo string) string {
	return strings.ToLower(strings.TrimSpace(repo))
}

func (s *Store) ensureFleetLeases() error {
	if _, err := s.write.Exec(s.d.ddl(fleetLeasesSchema)); err != nil {
		return fmt.Errorf("create fleet_leases table: %w", err)
	}
	return nil
}

const leaseCols = `repo, issue, worker_id, fleet_id, endpoint_id, hostname, os_user,
	acquired_at, renewed_at, expires_at, seen, forced`

func scanLease(sc interface{ Scan(...any) error }) (Lease, error) {
	var l Lease
	var acq, ren, exp string
	var seen, forced int
	if err := sc.Scan(&l.Repo, &l.Issue, &l.WorkerID, &l.FleetID, &l.EndpointID, &l.Hostname, &l.OSUser,
		&acq, &ren, &exp, &seen, &forced); err != nil {
		return Lease{}, err
	}
	l.AcquiredAt, _ = time.Parse(rfc, acq)
	l.RenewedAt, _ = time.Parse(rfc, ren)
	l.ExpiresAt, _ = time.Parse(rfc, exp)
	l.Seen, l.Forced = seen != 0, forced != 0
	return l, nil
}

// AcquireLease grants c's (repo, issue) to c when it is free, expired, already
// c's own worker's, or c.Force is set. granted false means someone else holds
// it: holder is that lease. When a forced grant displaced a live holder,
// displaced is the lease it replaced. The new lease expires at at+grace.
func (s *Store) AcquireLease(c LeaseClaim, grace time.Duration, at time.Time) (granted bool, holder Lease, displaced *Lease, err error) {
	c.Repo = NormRepo(c.Repo)
	tx, err := s.write.Begin()
	if err != nil {
		return false, Lease{}, nil, err
	}
	defer tx.Rollback()
	if err := s.d.claimWrites(tx, "fleet_leases"); err != nil {
		return false, Lease{}, nil, err
	}

	ts := at.UTC().Format(rfc)
	l := Lease{Repo: c.Repo, Issue: c.Issue, WorkerID: c.WorkerID, FleetID: c.FleetID, EndpointID: c.EndpointID,
		Hostname: c.Hostname, OSUser: c.OSUser, AcquiredAt: at.UTC(), RenewedAt: at.UTC(),
		ExpiresAt: at.Add(grace).UTC()}
	cur, err := scanLease(tx.QueryRow(`SELECT `+leaseCols+` FROM fleet_leases WHERE repo = ? AND issue = ?`+s.d.forUpdate(), c.Repo, c.Issue))
	if errors.Is(err, sql.ErrNoRows) {
		// Free: one statement takes it. Losing it here means another hub's
		// claim inserted the row since the read (Postgres; SQLite's claim
		// already waited for it) — read that one, now committed, and judge it.
		res, ierr := tx.Exec(`INSERT INTO fleet_leases (`+leaseCols+`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0)
			ON CONFLICT(repo, issue) DO NOTHING`,
			l.Repo, l.Issue, l.WorkerID, l.FleetID, l.EndpointID, l.Hostname, l.OSUser, ts, ts, l.ExpiresAt.Format(rfc))
		if ierr != nil {
			return false, Lease{}, nil, ierr
		}
		if n, _ := res.RowsAffected(); n == 1 {
			return true, l, nil, tx.Commit()
		}
		cur, err = scanLease(tx.QueryRow(`SELECT `+leaseCols+` FROM fleet_leases WHERE repo = ? AND issue = ?`+s.d.forUpdate(), c.Repo, c.Issue))
	}
	if err != nil {
		return false, Lease{}, nil, err
	}
	live := cur.ExpiresAt.After(at)
	// The same fleet asking is the same worker: within one fleet (repo,
	// issue) names exactly one window, whatever key prefix the asker's
	// repo layout gives it. That is how a lease handed to the fleet a
	// start was placed on (HandOverLease, claude-fleet#1425) is taken up
	// by the spawn that arrives there.
	mine := cur.WorkerID == c.WorkerID || (cur.FleetID != "" && cur.FleetID == c.FleetID)
	if live && !mine {
		if !c.Force {
			return false, cur, nil, nil
		}
		d := cur
		displaced = &d
	}
	if live && mine {
		// The same worker asking again (a retried spawn, a resume on
		// the same machine) keeps its lease and its history; only the
		// grace is refreshed, never shortened.
		exp := at.Add(grace)
		if cur.ExpiresAt.After(exp) {
			exp = cur.ExpiresAt
		}
		if _, err := tx.Exec(`UPDATE fleet_leases SET worker_id = ?, endpoint_id = ?, hostname = ?, os_user = ?,
			renewed_at = ?, expires_at = ? WHERE repo = ? AND issue = ?`,
			c.WorkerID, c.EndpointID, c.Hostname, c.OSUser, at.UTC().Format(rfc), exp.UTC().Format(rfc), c.Repo, c.Issue); err != nil {
			return false, Lease{}, nil, err
		}
		cur.WorkerID, cur.ExpiresAt = c.WorkerID, exp
		return true, cur, nil, tx.Commit()
	}
	forced := 0
	if displaced != nil {
		forced = 1
	}
	l.Forced = forced == 1
	if _, err := tx.Exec(`INSERT INTO fleet_leases (`+leaseCols+`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
		ON CONFLICT(repo, issue) DO UPDATE SET worker_id = excluded.worker_id, fleet_id = excluded.fleet_id,
		  endpoint_id = excluded.endpoint_id, hostname = excluded.hostname, os_user = excluded.os_user,
		  acquired_at = excluded.acquired_at, renewed_at = excluded.renewed_at,
		  expires_at = excluded.expires_at, seen = 0, forced = excluded.forced`,
		l.Repo, l.Issue, l.WorkerID, l.FleetID, l.EndpointID, l.Hostname, l.OSUser,
		ts, ts, l.ExpiresAt.Format(rfc), forced); err != nil {
		return false, Lease{}, nil, err
	}
	return true, l, displaced, tx.Commit()
}

// ReleaseLease drops (repo, issue) if workerID holds it. released false means
// it was not held by that worker (free already, or someone else's).
func (s *Store) ReleaseLease(repo string, issue int, workerID string) (released bool, err error) {
	res, err := s.write.Exec(`DELETE FROM fleet_leases WHERE repo = ? AND issue = ? AND worker_id = ?`,
		NormRepo(repo), issue, workerID)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// LeaseSession is one session a heartbeat lists, as a lease is matched to it.
type LeaseSession struct {
	WorkerID string
	FleetID  string
	Repo     string
	Issue    int
}

// RenewLeases applies one heartbeat from endpointID to the leases it holds.
// readFleets is every fleet that beat read successfully: only a lease whose
// fleet is in it can be judged — a fleet the beat could not read says nothing
// about its sessions. A lease matches a session by worker_id, or by (fleet,
// repo, issue) when the worker_id spellings differ. Matched leases are renewed
// to at+ttl and marked seen; a seen lease with no match is released (the
// session ended). An unseen one is left to its start grace.
func (s *Store) RenewLeases(endpointID string, readFleets map[string]bool, sessions []LeaseSession, ttl time.Duration, at time.Time) (renewed, released int, err error) {
	tx, err := s.write.Begin()
	if err != nil {
		return 0, 0, err
	}
	defer tx.Rollback()
	if err := s.d.claimWrites(tx, "fleet_leases"); err != nil {
		return 0, 0, err
	}
	rows, err := tx.Query(`SELECT `+leaseCols+` FROM fleet_leases WHERE endpoint_id = ?`+s.d.forUpdate(), endpointID)
	if err != nil {
		return 0, 0, err
	}
	var held []Lease
	for rows.Next() {
		l, err := scanLease(rows)
		if err != nil {
			rows.Close()
			return 0, 0, err
		}
		held = append(held, l)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, 0, err
	}
	ts, exp := at.UTC().Format(rfc), at.Add(ttl).UTC().Format(rfc)
	for _, l := range held {
		if !readFleets[l.FleetID] {
			continue
		}
		found := false
		for _, ss := range sessions {
			if ss.WorkerID == l.WorkerID ||
				(ss.FleetID == l.FleetID && ss.Issue == l.Issue && NormRepo(ss.Repo) == l.Repo) {
				found = true
				break
			}
		}
		switch {
		case found:
			if _, err := tx.Exec(`UPDATE fleet_leases SET renewed_at = ?, expires_at = ?, seen = 1
				WHERE repo = ? AND issue = ? AND worker_id = ?`, ts, exp, l.Repo, l.Issue, l.WorkerID); err != nil {
				return 0, 0, err
			}
			renewed++
		case l.Seen:
			if _, err := tx.Exec(`DELETE FROM fleet_leases WHERE repo = ? AND issue = ? AND worker_id = ?`,
				l.Repo, l.Issue, l.WorkerID); err != nil {
				return 0, 0, err
			}
			released++
		}
	}
	return renewed, released, tx.Commit()
}

// Leases lists every lease still live at at, by repo then issue. Expired rows
// are left in the table (the next Acquire overwrites them) but never listed.
func (s *Store) Leases(at time.Time) ([]Lease, error) {
	// Filtered here, not in SQL: RFC3339Nano drops trailing zeros, so the
	// stored text does not sort as time.
	rows, err := s.read.Query(`SELECT ` + leaseCols + ` FROM fleet_leases ORDER BY repo, issue`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Lease{}
	for rows.Next() {
		l, err := scanLease(rows)
		if err != nil {
			return nil, err
		}
		if l.ExpiresAt.After(at) {
			out = append(out, l)
		}
	}
	return out, rows.Err()
}

// HandOverLease moves a live lease from the worker that holds it to another
// fleet's worker — the start a node placed on another machine
// (claude-fleet#1425). Only the holder can hand it over: false when from no
// longer holds it (expired, released, or taken). The new holder gets a fresh
// start grace and is unseen, exactly as a fresh acquire would be, so the
// remote spawn has the same five minutes to show up in a heartbeat.
func (s *Store) HandOverLease(repo string, issue int, from string, to LeaseClaim, grace time.Duration, at time.Time) (bool, error) {
	repo = NormRepo(repo)
	tx, err := s.write.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	if err := s.d.claimWrites(tx, "fleet_leases"); err != nil {
		return false, err
	}
	cur, err := scanLease(tx.QueryRow(`SELECT `+leaseCols+` FROM fleet_leases WHERE repo = ? AND issue = ?`+s.d.forUpdate(), repo, issue))
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if cur.WorkerID != from || !cur.ExpiresAt.After(at) {
		return false, nil
	}
	ts := at.UTC().Format(rfc)
	if _, err := tx.Exec(`UPDATE fleet_leases SET worker_id = ?, fleet_id = ?, endpoint_id = ?, hostname = ?,
		os_user = ?, acquired_at = ?, renewed_at = ?, expires_at = ?, seen = 0, forced = 0
		WHERE repo = ? AND issue = ?`,
		to.WorkerID, to.FleetID, to.EndpointID, to.Hostname, to.OSUser, ts, ts, at.Add(grace).UTC().Format(rfc),
		repo, issue); err != nil {
		return false, err
	}
	return true, tx.Commit()
}
