package store

import (
	"fmt"
	"strings"
	"time"
)

// One progress stream per parent (claude-fleet#1648, EPIC #1645 C5).
//
// A worker the hub placed on ANOTHER machine has two kinds of news for the
// session that spawned it: the hub's own view of the start (the worker_start
// operation: accepted → running → done | failed) and the child's reports
// (a child_report relay: WAITING with a PR, MERGED, REAPED, …). Both are
// appended HERE, keyed by the parent's worker_id, and the parent's machine
// pulls the stream (GET /v1/node/progress) into its own children ledger —
// so the hub's copy is the one both machines agree on, and the parent's
// book catches up whatever the push path missed.
//
// rid is the event's global id: a report's is its relay id
// (`<child worker_id>#<suffix>`), an operation's `op:<id>:<status>`. It is
// unique here, and the node dedups on it too, so the same event arriving by
// the relay push and by the pull is one row.
const fleetProgressSchema = `
CREATE TABLE IF NOT EXISTS fleet_progress (
  seq       INTEGER PRIMARY KEY AUTOINCREMENT,
  rid       TEXT NOT NULL UNIQUE,
  parent    TEXT NOT NULL,
  fleet_id  TEXT NOT NULL,
  kind      TEXT NOT NULL,
  state     TEXT NOT NULL,
  body      TEXT NOT NULL,
  created   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS fleet_progress_fleet ON fleet_progress(fleet_id, seq);`

// FleetProgressTTL is how long an event is kept: a parent's machine that was
// off for longer reads its ledger as it was.
const FleetProgressTTL = 30 * 24 * time.Hour

// Progress event kinds.
const (
	ProgressReport   = "report"
	ProgressDispatch = "dispatch"
)

// FleetProgress is one event of a parent's stream.
type FleetProgress struct {
	Seq     int64
	RID     string
	Parent  string // the parent's worker_id
	FleetID string // the parent's fleet UUID — what a pull is scoped by
	Kind    string
	State   string
	Body    string // the event, as JSON
	Created time.Time
}

func (s *Store) ensureFleetProgress() error {
	if _, err := s.write.Exec(s.d.ddl(fleetProgressSchema)); err != nil {
		return fmt.Errorf("create fleet_progress: %w", err)
	}
	return nil
}

// AppendFleetProgress stores e unless its rid is already there; inserted
// reports which.
func (s *Store) AppendFleetProgress(e FleetProgress) (inserted bool, err error) {
	res, err := s.write.Exec(`INSERT INTO fleet_progress (rid, parent, fleet_id, kind, state, body, created)
		VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(rid) DO NOTHING`,
		e.RID, e.Parent, e.FleetID, e.Kind, e.State, e.Body, e.Created.UTC().Format(rfc))
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// FleetProgressSince lists the events after seq whose parent is in one of
// fleetIDs, oldest first, at most limit.
func (s *Store) FleetProgressSince(fleetIDs []string, since int64, limit int) ([]FleetProgress, error) {
	if len(fleetIDs) == 0 {
		return nil, nil
	}
	if limit <= 0 || limit > 1000 {
		limit = 1000
	}
	args := make([]any, 0, len(fleetIDs)+2)
	args = append(args, since)
	for _, f := range fleetIDs {
		args = append(args, f)
	}
	args = append(args, limit)
	rows, err := s.write.Query(`SELECT seq, rid, parent, fleet_id, kind, state, body, created FROM fleet_progress
		WHERE seq > ? AND fleet_id IN (?`+strings.Repeat(", ?", len(fleetIDs)-1)+`) ORDER BY seq LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []FleetProgress
	for rows.Next() {
		var e FleetProgress
		var created string
		if err := rows.Scan(&e.Seq, &e.RID, &e.Parent, &e.FleetID, &e.Kind, &e.State, &e.Body, &created); err != nil {
			return nil, err
		}
		e.Created, _ = time.Parse(rfc, created)
		out = append(out, e)
	}
	return out, rows.Err()
}

// ExpireFleetProgress drops events older than ttl.
func (s *Store) ExpireFleetProgress(ttl time.Duration, now time.Time) (int64, error) {
	res, err := s.write.Exec(`DELETE FROM fleet_progress WHERE created < ?`, now.Add(-ttl).UTC().Format(rfc))
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}
