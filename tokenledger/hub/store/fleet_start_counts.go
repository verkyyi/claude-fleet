package store

import "time"

// FleetStartCounts is how many worker_starts the hub placed on each fleet
// since `since` (claude-fleet T673): the doctor's «近 24 小时各台分到的会话数»
// line. Every start counts, whatever became of it — it is where the hub sent
// the session, not whether it lived. Keyed by fleet_id; a fleet with none is
// absent.
func (s *Store) FleetStartCounts(since time.Time) (map[string]int, error) {
	rows, err := s.read.Query(`SELECT fleet_id, created FROM fleet_operations
		 WHERE action = 'worker_start' AND fleet_id <> ''`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]int{}
	for rows.Next() {
		var fid, created string
		if err := rows.Scan(&fid, &created); err != nil {
			return nil, err
		}
		// created is RFC3339Nano, whose fraction is not fixed-width: compare
		// as times, never as strings.
		if at, err := time.Parse(rfc, created); err == nil && !at.Before(since) {
			out[fid]++
		}
	}
	return out, rows.Err()
}
