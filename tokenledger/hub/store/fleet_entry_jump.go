package store

import (
	"database/sql"
	"errors"
	"strings"
	"time"
)

func (s *Store) SetEntryJump(machine, namespace string, at time.Time) error {
	_, err := s.write.Exec(`INSERT INTO fleet_entry_jump (machine, namespace, seen_at) VALUES (?, ?, ?)
		ON CONFLICT(machine) DO UPDATE SET namespace = excluded.namespace, seen_at = excluded.seen_at`,
		strings.ToLower(machine), namespace, at.UTC().Format(rfc))
	return err
}

func (s *Store) EntryJump(machine string) (namespace string, at time.Time, err error) {
	var seen string
	err = s.read.QueryRow(`SELECT namespace, seen_at FROM fleet_entry_jump WHERE machine = ?`, strings.ToLower(machine)).Scan(&namespace, &seen)
	if errors.Is(err, sql.ErrNoRows) {
		return "", time.Time{}, nil
	}
	if err != nil {
		return "", time.Time{}, err
	}
	at, err = time.Parse(rfc, seen)
	return namespace, at, err
}

// DoorSessionKeep is how long a door session's identifier is remembered: far
// longer than a door-session certificate lives (A5SQ).
const DoorSessionKeep = 10 * time.Minute

// ClaimDoorSession records that session (a hash of an SSH session identifier)
// was presented for person; false when it was presented before — a
// signature the door hands in twice is refused the second time, on every
// replica. Rows older than DoorSessionKeep go first.
func (s *Store) ClaimDoorSession(session, person string, now time.Time) (bool, error) {
	if _, err := s.write.Exec(`DELETE FROM fleet_door_sessions WHERE seen_at < ?`,
		now.Add(-DoorSessionKeep).UTC().Format(rfc)); err != nil {
		return false, err
	}
	res, err := s.write.Exec(`INSERT INTO fleet_door_sessions (session, person, seen_at) VALUES (?, ?, ?)
		ON CONFLICT(session) DO NOTHING`, session, person, now.UTC().Format(rfc))
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n == 1, err
}
