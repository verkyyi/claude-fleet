package store

import (
	"database/sql"
	"sort"
	"time"
)

// FailedStart is one worker_start the hub saw end failed (claude-fleet QSSW):
// the operation, its fleet, when it ended and what the node said.
type FailedStart struct {
	ID      string
	FleetID string
	Updated time.Time
	Result  string
}

// FailedStartsSince lists the worker_starts that ended failed at or after
// since, oldest first — every one, whoever asked; the caller tells a start
// that could not be opened from one a machine declined (at capacity, claimed).
func (s *Store) FailedStartsSince(since time.Time) ([]FailedStart, error) {
	// updated is RFC3339Nano, whose fraction is not fixed-width: the text
	// bound below (second precision, no zone) only narrows the scan — a
	// stamp at since's second sorts after it — and the exact cut is a time
	// compare.
	rows, err := s.read.Query(`SELECT id, fleet_id, updated, result FROM fleet_operations
		WHERE action = 'worker_start' AND status = 'failed' AND updated >= ?`,
		since.UTC().Format("2006-01-02T15:04:05"))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []FailedStart
	for rows.Next() {
		var f FailedStart
		var updated string
		var result sql.NullString
		if err := rows.Scan(&f.ID, &f.FleetID, &updated, &result); err != nil {
			return nil, err
		}
		at, err := time.Parse(rfc, updated)
		if err != nil || at.Before(since) {
			continue
		}
		f.Updated, f.Result = at.UTC(), result.String
		out = append(out, f)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Updated.Before(out[j].Updated) })
	return out, nil
}
