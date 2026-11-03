package store

import (
	"encoding/json"
	"fmt"
	"time"
)

// Reachability as the views see it (task FQAR): how often entering a session
// worked, how much of the time a wanted link to another machine was up, how
// long an enter took and how long a dropped link took to come back. The hub
// cannot see any of it — its own pings measure hub↔node only, and on
// 2026-11-02 the view→pod road through the peer relay was broken for hours
// while /status said failure_rate 0 — so each view machine folds its own
// ledgers (view-switch.ndjson, peerlink.ndjson) into hourly counts and sends
// them (bin/fleet-reach-report.py → POST /v1/fleet/reach-stats).
//
// One row per (hour, src, link, route). src is a hash the hub makes of the
// caller (never the caller's name); link is the client's own hash of the far
// machine and login ("" = a session on the view's own machine); route is the
// class: local · direct (tailnet / lan / entry) · relay (peer-relay /
// hub-relay) · unknown. A client re-sends its recent hours whole, so a row is
// REPLACED, never added to: a resend is idempotent. Counts and histograms
// only; kept 90 days (ReachKeep).
const reachStatsSchema = `
CREATE TABLE IF NOT EXISTS fleet_reach_stats (
  hour         INTEGER NOT NULL,
  src          TEXT NOT NULL,
  link         TEXT NOT NULL DEFAULT '',
  route        TEXT NOT NULL,
  attempts     INTEGER NOT NULL DEFAULT 0,
  ok           INTEGER NOT NULL DEFAULT 0,
  enter_hist   TEXT NOT NULL DEFAULT '[]',
  want_ms      INTEGER NOT NULL DEFAULT 0,
  up_ms        INTEGER NOT NULL DEFAULT 0,
  recover_hist TEXT NOT NULL DEFAULT '[]',
  at           INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (hour, src, link, route)
);`

// ReachKeep is how long a reach row is kept.
const ReachKeep = 90 * 24 * time.Hour

// ReachBounds are the reach histograms' upper bounds in ms — the hub's own
// link histogram's 150 · 200 · 300 · 500 · 1000, then on to 10 s (an enter
// slower than that is a failed one) and to half an hour (a link's recovery).
// One bucket more holds everything above the last bound.
var ReachBounds = []int64{150, 200, 300, 500, 1000, 2000, 5000, 10000, 30000, 60000, 300000, 1800000}

// ReachBuckets is the number of buckets: one per bound plus the open one.
const ReachBuckets = 13

// ReachRow is one row of fleet_reach_stats.
type ReachRow struct {
	Hour     int64 // unix seconds / 3600
	Src      string
	Link     string
	Route    string
	Attempts int64
	OK       int64
	Enter    [ReachBuckets]int64
	WantMS   int64
	UpMS     int64
	Recover  [ReachBuckets]int64
	At       time.Time
}

func (s *Store) ensureReachStats() error {
	if _, err := s.write.Exec(s.d.ddl(reachStatsSchema)); err != nil {
		return fmt.Errorf("create reach stats table: %w", err)
	}
	return nil
}

func reachHist(b [ReachBuckets]int64) string {
	j, _ := json.Marshal(b[:])
	return string(j)
}

func reachUnhist(s string) [ReachBuckets]int64 {
	var out [ReachBuckets]int64
	var xs []int64
	if json.Unmarshal([]byte(s), &xs) == nil {
		copy(out[:], xs)
	}
	return out
}

// PutReachRows replaces each row (by hour, src, link, route), in one transaction.
func (s *Store) PutReachRows(rows []ReachRow) error {
	if len(rows) == 0 {
		return nil
	}
	tx, err := s.write.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, r := range rows {
		if _, err := tx.Exec(`INSERT INTO fleet_reach_stats (hour, src, link, route, attempts, ok, enter_hist, want_ms, up_ms, recover_hist, at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(hour, src, link, route) DO UPDATE SET
			  attempts = excluded.attempts, ok = excluded.ok, enter_hist = excluded.enter_hist,
			  want_ms = excluded.want_ms, up_ms = excluded.up_ms, recover_hist = excluded.recover_hist, at = excluded.at`,
			r.Hour, r.Src, r.Link, r.Route, r.Attempts, r.OK, reachHist(r.Enter), r.WantMS, r.UpMS, reachHist(r.Recover), r.At.UnixMilli()); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// ReachRows are the rows whose hour is at or after since's hour.
func (s *Store) ReachRows(since time.Time) ([]ReachRow, error) {
	rows, err := s.read.Query(`SELECT hour, src, link, route, attempts, ok, enter_hist, want_ms, up_ms, recover_hist, at
		FROM fleet_reach_stats WHERE hour >= ? ORDER BY hour`, since.Unix()/3600)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ReachRow
	for rows.Next() {
		var r ReachRow
		var enter, recover string
		var at int64
		if err := rows.Scan(&r.Hour, &r.Src, &r.Link, &r.Route, &r.Attempts, &r.OK, &enter, &r.WantMS, &r.UpMS, &recover, &at); err != nil {
			return nil, err
		}
		r.Enter, r.Recover, r.At = reachUnhist(enter), reachUnhist(recover), time.UnixMilli(at)
		out = append(out, r)
	}
	return out, rows.Err()
}

// PruneReachStats drops rows whose hour is before before's.
func (s *Store) PruneReachStats(before time.Time) error {
	_, err := s.write.Exec(`DELETE FROM fleet_reach_stats WHERE hour < ?`, before.Unix()/3600)
	return err
}
