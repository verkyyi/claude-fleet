package store

import (
	"fmt"
	"strconv"
	"time"
)

// Browser terminals (claude-fleet#3838, EPIC #3836 C1): one row per terminal a
// person's browser opened through the hub — who, which home login, which
// target, how it travelled, when it opened and ended, how and how many bytes
// each way. Never a byte of the terminal itself, never a grant or a secret:
// the row is metadata, written when the relay opens and finished when it ends.
//
// Created only with the fleet module on (EnsureNodes), like every fleet table.
const fleetTermSessionsSchema = `
CREATE TABLE IF NOT EXISTS fleet_term_sessions (
  id          TEXT PRIMARY KEY,
  person      TEXT NOT NULL,
  machine     TEXT NOT NULL,
  login       TEXT NOT NULL,
  target      TEXT NOT NULL,
  mode        TEXT NOT NULL,
  opened_at   TEXT NOT NULL,
  closed_at   TEXT NOT NULL DEFAULT '',
  outcome     TEXT NOT NULL DEFAULT '',
  bytes_up    INTEGER NOT NULL DEFAULT 0,
  bytes_down  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS fleet_term_sessions_person ON fleet_term_sessions(person, opened_at);`

// FleetTermSession is one browser terminal's record.
type FleetTermSession struct {
	ID        string    `json:"id"`
	Person    string    `json:"person"`
	Machine   string    `json:"machine"`
	Login     string    `json:"login"`
	Target    string    `json:"target"`
	Mode      string    `json:"mode"`
	OpenedAt  time.Time `json:"opened_at"`
	ClosedAt  time.Time `json:"closed_at,omitempty"`
	Outcome   string    `json:"outcome,omitempty"`
	BytesUp   int64     `json:"bytes_up"`
	BytesDown int64     `json:"bytes_down"`
	EchoP50   int       `json:"echo_p50_ms,omitempty"`
	EchoP95   int       `json:"echo_p95_ms,omitempty"`
	EchoN     int       `json:"echo_n,omitempty"`
	// RMVE: why the browser connected (first · auto · manual · take · renew),
	// the connection it follows, and when a path was selected — how often a
	// drop came back by itself, and how fast, are read off these.
	Cause      string    `json:"cause,omitempty"`
	Previous   string    `json:"previous,omitempty"`
	SelectedAt time.Time `json:"selected_at,omitempty"`
}

func (s *Store) ensureFleetTermSessions() error {
	if _, err := s.write.Exec(s.d.ddl(fleetTermSessionsSchema)); err != nil {
		return fmt.Errorf("create fleet_term_sessions table: %w", err)
	}
	// the browser's own echo measure (XX79): key → next output, ms
	for _, c := range []string{"echo_p50_ms", "echo_p95_ms", "echo_n"} {
		if err := s.addColumn("fleet_term_sessions", c, "INTEGER NOT NULL DEFAULT 0"); err != nil {
			return err
		}
	}
	// RMVE: how a connection came about and when it got a path
	for _, c := range []string{"cause", "previous", "selected_at"} {
		if err := s.addColumn("fleet_term_sessions", c, "TEXT NOT NULL DEFAULT ''"); err != nil {
			return err
		}
	}
	// A row that never selected a path is not still negotiating: closed ones
	// say so, and one a replica never closed (it went away) is lost after a day.
	if _, err := s.write.Exec(`UPDATE fleet_term_sessions SET mode = 'unselected' WHERE mode = 'negotiating' AND closed_at <> ''`); err != nil {
		return fmt.Errorf("fleet_term_sessions: %w", err)
	}
	if _, err := s.write.Exec(`UPDATE fleet_term_sessions SET mode = 'unselected', closed_at = opened_at, outcome = 'lost'
		WHERE mode = 'negotiating' AND closed_at = '' AND opened_at < ?`, time.Now().Add(-24*time.Hour).UTC().Format(rfc)); err != nil {
		return fmt.Errorf("fleet_term_sessions: %w", err)
	}
	return nil
}

// RecordTermEcho keeps a terminal's latest echo measure from its browser.
func (s *Store) RecordTermEcho(id string, p50, p95, n int) error {
	_, err := s.write.Exec(`UPDATE fleet_term_sessions SET echo_p50_ms = ?, echo_p95_ms = ?, echo_n = ? WHERE id = ?`, p50, p95, n, id)
	return err
}

// RecordTermOpen writes a terminal's row as it opens.
func (s *Store) RecordTermOpen(t FleetTermSession) error {
	_, err := s.write.Exec(`INSERT INTO fleet_term_sessions (id, person, machine, login, target, mode,
		opened_at, cause, previous) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		t.ID, t.Person, t.Machine, t.Login, t.Target, t.Mode, t.OpenedAt.UTC().Format(rfc), t.Cause, t.Previous)
	return err
}

// RecordTermClose finishes a terminal's row.
func (s *Store) RecordTermClose(id, outcome string, up, down int64, at time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_term_sessions SET closed_at = ?, outcome = ?, bytes_up = ?,
		bytes_down = ?, mode = CASE WHEN mode = 'negotiating' THEN 'unselected' ELSE mode END WHERE id = ?`,
		at.UTC().Format(rfc), outcome, up, down, id)
	return err
}

// RecordTermMode commits the selected path without putting payload in the audit.
func (s *Store) RecordTermMode(id, mode string) error {
	_, err := s.write.Exec(`UPDATE fleet_term_sessions SET mode = ?, selected_at = ? WHERE id = ?`, mode, time.Now().UTC().Format(rfc), id)
	return err
}

// FleetTermSessions lists terminals, newest first; person "" is everyone's.
func (s *Store) FleetTermSessions(person string, limit int) ([]FleetTermSession, error) {
	if limit <= 0 {
		limit = 50
	}
	var args []any
	where := ""
	if person != "" {
		where = ` WHERE person = ?`
		args = append(args, person)
	}
	return s.termSessions(where+` ORDER BY opened_at DESC, id LIMIT `+strconv.Itoa(limit), args...)
}

// FleetTermSessionsSince is every terminal opened at or after since, oldest
// first — the window the terminal health numbers are read from (RMVE).
func (s *Store) FleetTermSessionsSince(since time.Time) ([]FleetTermSession, error) {
	return s.termSessions(` WHERE opened_at >= ? ORDER BY opened_at, id`, since.UTC().Format(rfc))
}

func (s *Store) termSessions(tail string, args ...any) ([]FleetTermSession, error) {
	q := `SELECT id, person, machine, login, target, mode, opened_at, closed_at, outcome, bytes_up,
		bytes_down, echo_p50_ms, echo_p95_ms, echo_n, cause, previous, selected_at FROM fleet_term_sessions`
	rows, err := s.read.Query(q+tail, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []FleetTermSession{}
	for rows.Next() {
		var t FleetTermSession
		var opened, closed, selected string
		if err := rows.Scan(&t.ID, &t.Person, &t.Machine, &t.Login, &t.Target, &t.Mode, &opened, &closed,
			&t.Outcome, &t.BytesUp, &t.BytesDown, &t.EchoP50, &t.EchoP95, &t.EchoN, &t.Cause, &t.Previous, &selected); err != nil {
			return nil, err
		}
		t.OpenedAt, _ = time.Parse(rfc, opened)
		t.ClosedAt, _ = time.Parse(rfc, closed)
		t.SelectedAt, _ = time.Parse(rfc, selected)
		out = append(out, t)
	}
	return out, rows.Err()
}
