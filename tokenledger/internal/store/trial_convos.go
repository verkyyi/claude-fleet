package store

import (
	"database/sql"
	"errors"
	"time"
)

// A trial person's conversation, kept apart from the machine
// (claude-fleet#4060, EPIC #4048 C12): when a trial's login goes back to be
// washed, the entry takes its web conversation out first and keeps it here,
// sealed to that one principal (the caller seals — internal/credvault), for
// 24 hours. A later seat on a clean login is seeded from it. One row per
// principal: the newest conversation replaces the last. There is no read by
// anything but the principal itself — TrialConvo takes the caller's own
// principal, never an id — and the hourly purge deletes a row, ciphertext
// and all, once it expires.
const trialConvosSchema = `
CREATE TABLE IF NOT EXISTS hub_trial_convos (
  principal  TEXT PRIMARY KEY,
  sealed     BLOB NOT NULL,
  expires_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  seeded_at  INTEGER NOT NULL DEFAULT 0
);`

// TrialConvo is one sealed conversation and when it goes.
type TrialConvo struct {
	Sealed    []byte
	ExpiresAt time.Time
	UpdatedAt time.Time
	// SeededAt is when it was last put back on a login; zero for never.
	SeededAt time.Time
}

// PutTrialConvo keeps sealed as pid's conversation until expires,
// replacing whatever was kept before (and when it was last seeded).
func (s *Store) PutTrialConvo(pid string, sealed []byte, expires, now time.Time) error {
	_, err := s.write.Exec(`INSERT INTO hub_trial_convos (principal, sealed, expires_at, updated_at, seeded_at)
		VALUES (?, ?, ?, ?, 0) ON CONFLICT(principal) DO UPDATE SET sealed = excluded.sealed,
		expires_at = excluded.expires_at, updated_at = excluded.updated_at, seeded_at = 0`,
		pid, sealed, expires.Unix(), now.Unix())
	return err
}

// TrialConvo is pid's own kept conversation when it has not expired at now;
// nil, nil for none.
func (s *Store) TrialConvo(pid string, now time.Time) (*TrialConvo, error) {
	var c TrialConvo
	var ex, up, se int64
	err := s.write.QueryRow(`SELECT sealed, expires_at, updated_at, seeded_at FROM hub_trial_convos
		WHERE principal = ? AND expires_at > ?`, pid, now.Unix()).Scan(&c.Sealed, &ex, &up, &se)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	c.ExpiresAt, c.UpdatedAt, c.SeededAt = unixOrZero(ex), unixOrZero(up), unixOrZero(se)
	return &c, nil
}

// SeededTrialConvo records that pid's conversation was put back at now.
func (s *Store) SeededTrialConvo(pid string, now time.Time) error {
	_, err := s.write.Exec(`UPDATE hub_trial_convos SET seeded_at = ? WHERE principal = ?`, now.Unix(), pid)
	return err
}

// DeleteTrialConvo forgets pid's conversation.
func (s *Store) DeleteTrialConvo(pid string) error {
	_, err := s.write.Exec(`DELETE FROM hub_trial_convos WHERE principal = ?`, pid)
	return err
}

// PurgeTrialConvos deletes every conversation expired at now; how many.
func (s *Store) PurgeTrialConvos(now time.Time) (int, error) {
	res, err := s.write.Exec(`DELETE FROM hub_trial_convos WHERE expires_at <= ?`, now.Unix())
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return int(n), nil
}
