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
}

func (s *Store) ensureFleetTermSessions() error {
	if _, err := s.write.Exec(s.d.ddl(fleetTermSessionsSchema)); err != nil {
		return fmt.Errorf("create fleet_term_sessions table: %w", err)
	}
	return nil
}

// RecordTermOpen writes a terminal's row as it opens.
func (s *Store) RecordTermOpen(t FleetTermSession) error {
	_, err := s.write.Exec(`INSERT INTO fleet_term_sessions (id, person, machine, login, target, mode,
		opened_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		t.ID, t.Person, t.Machine, t.Login, t.Target, t.Mode, t.OpenedAt.UTC().Format(rfc))
	return err
}

// RecordTermClose finishes a terminal's row.
func (s *Store) RecordTermClose(id, outcome string, up, down int64, at time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_term_sessions SET closed_at = ?, outcome = ?, bytes_up = ?,
		bytes_down = ? WHERE id = ?`, at.UTC().Format(rfc), outcome, up, down, id)
	return err
}

// FleetTermSessions lists terminals, newest first; person "" is everyone's.
func (s *Store) FleetTermSessions(person string, limit int) ([]FleetTermSession, error) {
	if limit <= 0 {
		limit = 50
	}
	q := `SELECT id, person, machine, login, target, mode, opened_at, closed_at, outcome, bytes_up,
		bytes_down FROM fleet_term_sessions`
	var args []any
	if person != "" {
		q += ` WHERE person = ?`
		args = append(args, person)
	}
	rows, err := s.read.Query(q+` ORDER BY opened_at DESC, id LIMIT `+strconv.Itoa(limit), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []FleetTermSession{}
	for rows.Next() {
		var t FleetTermSession
		var opened, closed string
		if err := rows.Scan(&t.ID, &t.Person, &t.Machine, &t.Login, &t.Target, &t.Mode, &opened, &closed,
			&t.Outcome, &t.BytesUp, &t.BytesDown); err != nil {
			return nil, err
		}
		t.OpenedAt, _ = time.Parse(rfc, opened)
		t.ClosedAt, _ = time.Parse(rfc, closed)
		out = append(out, t)
	}
	return out, rows.Err()
}
