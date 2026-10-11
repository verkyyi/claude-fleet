package store

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

// The release ledger (claude-fleet#3140, EPIC #3139 C1): one row per release
// train the CI published with its `train` part — which merges it carried, how
// long each stage took, the macOS queue it waited in, and which machines were
// expected to take it — plus the moment each machine first ran it. A publish
// without the part writes nothing here.
//
// Created only with the fleet module on (EnsureNodes), like every fleet table.
const fleetReleaseTrainsSchema = `
CREATE TABLE IF NOT EXISTS fleet_release_trains (
  sha            TEXT PRIMARY KEY,
  prev_sha       TEXT NOT NULL,
  run_id         TEXT NOT NULL,
  published_at   TEXT NOT NULL,
  train_json     TEXT NOT NULL,
  machines_json  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS fleet_release_trains_published ON fleet_release_trains(published_at);
CREATE TABLE IF NOT EXISTS fleet_release_reach (
  sha         TEXT NOT NULL,
  machine     TEXT NOT NULL,
  reached_at  TEXT NOT NULL,
  PRIMARY KEY (sha, machine)
);`

// ReleaseTrain is one recorded train. Train is its `train` part as the hub
// normalized it; Machines the managed machines online and not 维护中 when it
// was published, as JSON (a list of hostnames).
type ReleaseTrain struct {
	SHA         string
	PrevSHA     string
	RunID       string
	PublishedAt time.Time
	Train       string
	Machines    string
}

// ReleaseReach is one machine's first beat on a train's sha.
type ReleaseReach struct {
	SHA       string
	Machine   string
	ReachedAt time.Time
}

func (s *Store) ensureFleetReleaseTrains() error {
	if _, err := s.write.Exec(s.d.ddl(fleetReleaseTrainsSchema)); err != nil {
		return fmt.Errorf("create fleet_release_trains tables: %w", err)
	}
	return nil
}

// RecordReleaseTrain writes a train once: a re-run of the same publish keeps
// the first row (its clock is when the release went out). ok reports a write.
func (s *Store) RecordReleaseTrain(t ReleaseTrain) (bool, error) {
	res, err := s.write.Exec(`INSERT INTO fleet_release_trains (sha, prev_sha, run_id, published_at,
		train_json, machines_json) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(sha) DO NOTHING`,
		t.SHA, t.PrevSHA, t.RunID, t.PublishedAt.UTC().Format(rfc), t.Train, t.Machines)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// RecordReleaseReach writes a machine's first beat on sha; a later one is a
// no-op, so the first time stands.
func (s *Store) RecordReleaseReach(sha, machine string, at time.Time) error {
	_, err := s.write.Exec(`INSERT INTO fleet_release_reach (sha, machine, reached_at)
		VALUES (?, ?, ?) ON CONFLICT(sha, machine) DO NOTHING`, sha, machine, at.UTC().Format(rfc))
	return err
}

// ReleaseTrainsSince lists the trains published at or after since, oldest first.
func (s *Store) ReleaseTrainsSince(since time.Time) ([]ReleaseTrain, error) {
	// the text column is compared loosely (RFC3339Nano does not sort exactly):
	// a day of slack here, the exact cut in Go
	rows, err := s.read.Query(`SELECT sha, prev_sha, run_id, published_at, train_json, machines_json
		FROM fleet_release_trains WHERE published_at >= ?`, since.Add(-24*time.Hour).UTC().Format(rfc))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ReleaseTrain{}
	for rows.Next() {
		var t ReleaseTrain
		var at string
		if err := rows.Scan(&t.SHA, &t.PrevSHA, &t.RunID, &at, &t.Train, &t.Machines); err != nil {
			return nil, err
		}
		t.PublishedAt, _ = time.Parse(rfc, at)
		if t.PublishedAt.Before(since) {
			continue
		}
		out = append(out, t)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].PublishedAt.Before(out[j].PublishedAt) })
	return out, nil
}

// ReleaseReachFor lists every recorded reach of the given shas.
func (s *Store) ReleaseReachFor(shas []string) ([]ReleaseReach, error) {
	out := []ReleaseReach{}
	for len(shas) > 0 {
		n := len(shas)
		if n > 200 {
			n = 200
		}
		q := `SELECT sha, machine, reached_at FROM fleet_release_reach WHERE sha IN (?` + strings.Repeat(",?", n-1) + `)`
		args := make([]any, n)
		for i, sha := range shas[:n] {
			args[i] = sha
		}
		rows, err := s.read.Query(q, args...)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var r ReleaseReach
			var at string
			if err := rows.Scan(&r.SHA, &r.Machine, &at); err != nil {
				rows.Close()
				return nil, err
			}
			r.ReachedAt, _ = time.Parse(rfc, at)
			out = append(out, r)
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return nil, err
		}
		shas = shas[n:]
	}
	return out, nil
}
