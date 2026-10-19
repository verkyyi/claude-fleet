package store

import (
	"database/sql"
	"errors"
	"time"
)

// CutSessions refuses every web session principal holds that was signed
// before at (claude-fleet#3701): «sign out everywhere», by an admin or the
// person. A repeat moves the cut-off to the later time.
func (s *Store) CutSessions(principal, by string, at time.Time) error {
	if principal == "" {
		return errors.New("a cut-off needs a person")
	}
	_, err := s.write.Exec(`INSERT INTO hub_session_cutoffs (principal_id, not_before, by_principal, at)
		VALUES (?, ?, ?, ?) ON CONFLICT(principal_id) DO UPDATE SET not_before = excluded.not_before,
		by_principal = excluded.by_principal, at = excluded.at`,
		principal, at.Unix(), by, fmtTime(at))
	return err
}

// SessionCutoff is principal's cut-off in Unix seconds, 0 when none.
func (s *Store) SessionCutoff(principal string) (int64, error) {
	var nb int64
	err := s.read.QueryRow(`SELECT not_before FROM hub_session_cutoffs WHERE principal_id = ?`, principal).Scan(&nb)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	return nb, err
}
