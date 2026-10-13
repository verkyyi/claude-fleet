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
);
CREATE TABLE IF NOT EXISTS fleet_release_runs (
  run_id      TEXT PRIMARY KEY,
  sha         TEXT NOT NULL,
  conclusion  TEXT NOT NULL,
  started_at  TEXT NOT NULL,
  ended_at    TEXT NOT NULL,
  run_json    TEXT NOT NULL,
  mac_json    TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS fleet_release_runs_started ON fleet_release_runs(started_at);`

// ReleaseRun is one run of the release train, whatever it came to
// (claude-fleet#3870, EPIC #3863 C7): green, red, cancelled or superseded — the
// train's `ledger` job writes it at its end, and mac-follow adds its stage
// (Mac) after. Run is the run as the hub normalized it, Mac the mac-follow
// stage ("" until one reports).
type ReleaseRun struct {
	RunID      string
	SHA        string
	Conclusion string
	StartedAt  time.Time
	EndedAt    time.Time
	Run        string
	Mac        string
}

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

// RecordReleaseRun writes a run, or rewrites it — the ledger job re-run on the
// same run is the newer word — keeping a Mac stage already reported.
func (s *Store) RecordReleaseRun(r ReleaseRun) error {
	_, err := s.write.Exec(`INSERT INTO fleet_release_runs (run_id, sha, conclusion, started_at, ended_at, run_json, mac_json)
		VALUES (?, ?, ?, ?, ?, ?, '') ON CONFLICT(run_id) DO UPDATE SET sha = excluded.sha,
		conclusion = excluded.conclusion, started_at = excluded.started_at, ended_at = excluded.ended_at,
		run_json = excluded.run_json`,
		r.RunID, r.SHA, r.Conclusion, r.StartedAt.UTC().Format(rfc), r.EndedAt.UTC().Format(rfc), r.Run)
	return err
}

// RecordReleaseRunMac writes a run's Mac stage; ok is false when no such run
// was recorded (a train whose ledger never came: nothing to hang it on).
func (s *Store) RecordReleaseRunMac(runID, mac string) (bool, error) {
	res, err := s.write.Exec(`UPDATE fleet_release_runs SET mac_json = ? WHERE run_id = ?`, mac, runID)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// ReleaseRunsSince lists the runs started at or after since, oldest first.
func (s *Store) ReleaseRunsSince(since time.Time) ([]ReleaseRun, error) {
	rows, err := s.read.Query(`SELECT run_id, sha, conclusion, started_at, ended_at, run_json, mac_json
		FROM fleet_release_runs WHERE started_at >= ?`, since.Add(-24*time.Hour).UTC().Format(rfc))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ReleaseRun{}
	for rows.Next() {
		var r ReleaseRun
		var a, b string
		if err := rows.Scan(&r.RunID, &r.SHA, &r.Conclusion, &a, &b, &r.Run, &r.Mac); err != nil {
			return nil, err
		}
		r.StartedAt, _ = time.Parse(rfc, a)
		r.EndedAt, _ = time.Parse(rfc, b)
		if r.StartedAt.Before(since) {
			continue
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].StartedAt.Before(out[j].StartedAt) })
	return out, nil
}
