package store

import (
	"database/sql"
	"fmt"
	"time"
)

// A home's link to the hub, measured from the hub (task PNWW): what a
// cross-border line would be judged against. Two tables, both small:
//
//   - fleet_link_events: one row each time a node's link comes up — how long
//     it was gone (gap_ms, from its last beat) and why it went (cause:
//     hub_restart · network · first) — and each time this hub sees it end.
//   - fleet_link_rtt: the hub's own ping to every link, once a minute, folded
//     per hour per (host, login): count, failures, sum, max and a histogram.
//
// Hostnames and logins only, never a person.
const linkStatsSchema = `
CREATE TABLE IF NOT EXISTS fleet_link_events (
  at       INTEGER NOT NULL,
  host     TEXT NOT NULL,
  login    TEXT NOT NULL,
  event    TEXT NOT NULL,
  cause    TEXT NOT NULL DEFAULT '',
  gap_ms   INTEGER NOT NULL DEFAULT 0,
  replica  TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS fleet_link_rtt (
  hour     INTEGER NOT NULL,
  host     TEXT NOT NULL,
  login    TEXT NOT NULL,
  n        INTEGER NOT NULL DEFAULT 0,
  fails    INTEGER NOT NULL DEFAULT 0,
  sum_ms   INTEGER NOT NULL DEFAULT 0,
  max_ms   INTEGER NOT NULL DEFAULT 0,
  b150     INTEGER NOT NULL DEFAULT 0,
  b200     INTEGER NOT NULL DEFAULT 0,
  b300     INTEGER NOT NULL DEFAULT 0,
  b500     INTEGER NOT NULL DEFAULT 0,
  b1000    INTEGER NOT NULL DEFAULT 0,
  bmore    INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (hour, host, login)
);`

// LinkRTTBounds are the histogram's upper bounds in ms; the last bucket is
// everything above the last bound.
var LinkRTTBounds = []int64{150, 200, 300, 500, 1000}

// LinkEvent is one row of fleet_link_events.
type LinkEvent struct {
	At      time.Time
	Host    string
	Login   string
	Event   string // up · down
	Cause   string
	GapMS   int64
	Replica string
}

// LinkRTT is one hour of one link's pings.
type LinkRTT struct {
	Hour    int64 // unix seconds / 3600
	Host    string
	Login   string
	N       int64
	Fails   int64
	SumMS   int64
	MaxMS   int64
	Buckets [6]int64
}

func (s *Store) ensureLinkStats() error {
	if _, err := s.write.Exec(s.d.ddl(linkStatsSchema)); err != nil {
		return fmt.Errorf("create link stats tables: %w", err)
	}
	return nil
}

// RecordLinkEvent keeps one up or down.
func (s *Store) RecordLinkEvent(e LinkEvent) error {
	_, err := s.write.Exec(`INSERT INTO fleet_link_events (at, host, login, event, cause, gap_ms, replica) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		e.At.UnixMilli(), e.Host, e.Login, e.Event, e.Cause, e.GapMS, e.Replica)
	return err
}

// RecordLinkPing folds one ping into its hour: ok false is a failure.
func (s *Store) RecordLinkPing(host, login string, at time.Time, ms int64, ok bool) error {
	var b [6]int64
	var n, fails, sum, max int64 = 1, 0, 0, 0
	if ok {
		sum, max = ms, ms
		i := len(LinkRTTBounds)
		for k, ub := range LinkRTTBounds {
			if ms < ub {
				i = k
				break
			}
		}
		b[i] = 1
	} else {
		fails = 1
	}
	_, err := s.write.Exec(`INSERT INTO fleet_link_rtt (hour, host, login, n, fails, sum_ms, max_ms, b150, b200, b300, b500, b1000, bmore)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(hour, host, login) DO UPDATE SET
		  n = fleet_link_rtt.n + excluded.n, fails = fleet_link_rtt.fails + excluded.fails,
		  sum_ms = fleet_link_rtt.sum_ms + excluded.sum_ms,
		  max_ms = CASE WHEN excluded.max_ms > fleet_link_rtt.max_ms THEN excluded.max_ms ELSE fleet_link_rtt.max_ms END,
		  b150 = fleet_link_rtt.b150 + excluded.b150, b200 = fleet_link_rtt.b200 + excluded.b200,
		  b300 = fleet_link_rtt.b300 + excluded.b300, b500 = fleet_link_rtt.b500 + excluded.b500,
		  b1000 = fleet_link_rtt.b1000 + excluded.b1000, bmore = fleet_link_rtt.bmore + excluded.bmore`,
		at.Unix()/3600, host, login, n, fails, sum, max, b[0], b[1], b[2], b[3], b[4], b[5])
	return err
}

// LinkEvents are the events at or after since, oldest first.
func (s *Store) LinkEvents(since time.Time) ([]LinkEvent, error) {
	rows, err := s.read.Query(`SELECT at, host, login, event, cause, gap_ms, replica FROM fleet_link_events WHERE at >= ? ORDER BY at`, since.UnixMilli())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []LinkEvent
	for rows.Next() {
		var e LinkEvent
		var at int64
		if err := rows.Scan(&at, &e.Host, &e.Login, &e.Event, &e.Cause, &e.GapMS, &e.Replica); err != nil {
			return nil, err
		}
		e.At = time.UnixMilli(at)
		out = append(out, e)
	}
	return out, rows.Err()
}

// LinkRTTs are the hours at or after since.
func (s *Store) LinkRTTs(since time.Time) ([]LinkRTT, error) {
	rows, err := s.read.Query(`SELECT hour, host, login, n, fails, sum_ms, max_ms, b150, b200, b300, b500, b1000, bmore
		FROM fleet_link_rtt WHERE hour >= ? ORDER BY hour`, since.Unix()/3600)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []LinkRTT
	for rows.Next() {
		var r LinkRTT
		b := &r.Buckets
		if err := rows.Scan(&r.Hour, &r.Host, &r.Login, &r.N, &r.Fails, &r.SumMS, &r.MaxMS, &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// PruneLinkStats drops rows older than before.
func (s *Store) PruneLinkStats(before time.Time) error {
	if _, err := s.write.Exec(`DELETE FROM fleet_link_events WHERE at < ?`, before.UnixMilli()); err != nil {
		return err
	}
	_, err := s.write.Exec(`DELETE FROM fleet_link_rtt WHERE hour < ?`, before.Unix()/3600)
	return err
}

// NodeLastBeat is an endpoint's last heartbeat, if the roster has one.
func (s *Store) NodeLastBeat(endpointID string) (*time.Time, bool, error) {
	var last sql.NullString
	err := s.read.QueryRow(`SELECT last_heartbeat FROM nodes WHERE endpoint_id = ?`, endpointID).Scan(&last)
	if err == sql.ErrNoRows {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	return parseNullTime(last), true, nil
}
