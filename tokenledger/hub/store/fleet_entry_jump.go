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
