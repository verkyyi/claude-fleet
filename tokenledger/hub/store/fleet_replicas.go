package store

import (
	"fmt"
	"sort"
	"time"
)

// Which hub replicas are up right now (claude-fleet#2190, EPIC #2119).
//
// Some of the hub's state lives in one process's memory on purpose — a
// `fleet login` in progress, the client leases and the actions queued for
// them, the live sessions — and two replicas behind one address must still
// answer as one hub. Each replica writes its row here every few seconds; the
// rows say who the other replicas are (where to send a live report) and which
// one holds the in-memory state (the oldest one up — api/replica_state.go).
//
// Like fleet_node_conns, the table exists only on a hub started as a replica
// (CCQUOTA_REPLICA): a single hub never creates, writes or reads it. Its rows
// are live state, not history: a replica that stops beating is simply not
// "up" any more, and its row is replaced when it comes back.
const fleetReplicasSchema = `
CREATE TABLE IF NOT EXISTS fleet_replicas (
  name       TEXT PRIMARY KEY,
  url        TEXT NOT NULL,
  started_at TEXT NOT NULL,
  seen_at    TEXT NOT NULL
);`

// ReplicaRow is one replica: up since StartedAt, reachable at URL, last heard
// from at SeenAt.
type ReplicaRow struct {
	Name      string
	URL       string
	StartedAt time.Time
	SeenAt    time.Time
}

// EnsureFleetReplicas creates the table. Only a replica calls it.
func (s *Store) EnsureFleetReplicas() error {
	if _, err := s.write.Exec(s.d.ddl(fleetReplicasSchema)); err != nil {
		return fmt.Errorf("create fleet_replicas table: %w", err)
	}
	return nil
}

// BeatReplica records that r is up (its row replaced whole: a restarted
// replica of the same name starts over with its new StartedAt).
func (s *Store) BeatReplica(r ReplicaRow) error {
	_, err := s.write.Exec(`
		INSERT INTO fleet_replicas (name, url, started_at, seen_at) VALUES (?, ?, ?, ?)
		ON CONFLICT(name) DO UPDATE SET
		  url = excluded.url, started_at = excluded.started_at, seen_at = excluded.seen_at`,
		r.Name, r.URL, r.StartedAt.UTC().Format(rfc), r.SeenAt.UTC().Format(rfc))
	return err
}

// Replicas is every replica heard from since since, oldest start first (then
// by name), so the first row is the one that has been up the longest. The
// filter and the order are Go's: an RFC 3339 time with its trailing zeros
// trimmed does not sort as text (".1Z" after ".12Z"), and there are only ever
// a handful of rows.
func (s *Store) Replicas(since time.Time) ([]ReplicaRow, error) {
	rows, err := s.read.Query(`SELECT name, url, started_at, seen_at FROM fleet_replicas`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ReplicaRow
	for rows.Next() {
		var r ReplicaRow
		var started, seen string
		if err := rows.Scan(&r.Name, &r.URL, &started, &seen); err != nil {
			return nil, err
		}
		r.StartedAt, _ = time.Parse(rfc, started)
		r.SeenAt, _ = time.Parse(rfc, seen)
		if !r.SeenAt.Before(since) {
			out = append(out, r)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].StartedAt.Equal(out[j].StartedAt) {
			return out[i].StartedAt.Before(out[j].StartedAt)
		}
		return out[i].Name < out[j].Name
	})
	return out, nil
}
