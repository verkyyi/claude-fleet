package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// The 60-second trial (claude-fleet#3590, EPIC #3569 C20): a person who came
// in through /app/try is a trial person — one row here, from their sign-in.
// It is the waitlist (waiting, in waiting_since order), the record of which
// machine handed them a spare (placed), the last time they used it
// (last_seen, the 7-day reclaim reads it) and whether their one timing was
// recorded. The timings themselves are anonymous: fleet_trial_timings keeps
// when and how long, never who.
const fleetTrialsSchema = `
CREATE TABLE IF NOT EXISTS fleet_trials (
  principal     TEXT PRIMARY KEY,
  state         TEXT NOT NULL DEFAULT 'waiting',
  started_at    INTEGER NOT NULL,
  waiting_since INTEGER NOT NULL DEFAULT 0,
  placed_at     INTEGER NOT NULL DEFAULT 0,
  host          TEXT NOT NULL DEFAULT '',
  last_seen     INTEGER NOT NULL DEFAULT 0,
  timed_at      INTEGER NOT NULL DEFAULT 0,
  reclaimed_at  INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS fleet_trial_timings (
  at INTEGER NOT NULL,
  ms INTEGER NOT NULL
);`

// The states of a trial.
const (
	TrialWaiting   = "waiting"
	TrialPlaced    = "placed"
	TrialReclaimed = "reclaimed"
)

// Trial is one trial person's row.
type Trial struct {
	Principal    string
	State        string
	StartedAt    time.Time
	WaitingSince time.Time
	PlacedAt     time.Time
	Host         string
	LastSeen     time.Time
	TimedAt      time.Time
	ReclaimedAt  time.Time
}

func (s *Store) ensureFleetTrials() error {
	if _, err := s.write.Exec(s.d.ddl(fleetTrialsSchema)); err != nil {
		return fmt.Errorf("create fleet trials tables: %w", err)
	}
	return nil
}

func unixOrZero(v int64) time.Time {
	if v <= 0 {
		return time.Time{}
	}
	return time.Unix(v, 0).UTC()
}

const trialCols = `principal, state, started_at, waiting_since, placed_at, host, last_seen, timed_at, reclaimed_at`

func scanTrial(row interface{ Scan(...any) error }) (*Trial, error) {
	var t Trial
	var st, ws, pa, ls, ta, ra int64
	if err := row.Scan(&t.Principal, &t.State, &st, &ws, &pa, &t.Host, &ls, &ta, &ra); err != nil {
		return nil, err
	}
	t.StartedAt, t.WaitingSince, t.PlacedAt = unixOrZero(st), unixOrZero(ws), unixOrZero(pa)
	t.LastSeen, t.TimedAt, t.ReclaimedAt = unixOrZero(ls), unixOrZero(ta), unixOrZero(ra)
	return &t, nil
}

// StartTrial records pid as a trial person, waiting from now. A person who
// already has a row keeps it as it is.
func (s *Store) StartTrial(pid string, now time.Time) error {
	_, err := s.write.Exec(s.d.insertIgnore(`INSERT OR IGNORE INTO fleet_trials
		(principal, state, started_at, waiting_since, last_seen) VALUES (?, ?, ?, ?, ?)`),
		pid, TrialWaiting, now.Unix(), now.Unix(), now.Unix())
	return err
}

// Trial is pid's trial row; nil, nil when pid is not a trial person.
func (s *Store) Trial(pid string) (*Trial, error) {
	t, err := scanTrial(s.write.QueryRow(`SELECT `+trialCols+` FROM fleet_trials WHERE principal = ?`, pid))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return t, err
}

// TouchTrial marks pid as seen now; nothing for a person with no trial row.
func (s *Store) TouchTrial(pid string, now time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_trials SET last_seen = ? WHERE principal = ? AND last_seen < ?`,
		now.Unix(), pid, now.Unix())
	return err
}

// RejoinTrial puts a reclaimed trial person back at the end of the waitlist.
func (s *Store) RejoinTrial(pid string, now time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_trials SET state = ?, waiting_since = ?, placed_at = 0, host = '',
		reclaimed_at = 0, last_seen = ? WHERE principal = ? AND state = ?`,
		TrialWaiting, now.Unix(), now.Unix(), pid, TrialReclaimed)
	return err
}

// TrialsAhead is how many waiting trial people are ahead of t in the line:
// waiting since before them (the principal breaks a tie), and seen at or
// after fresh — one who walked away from the page holds no one up.
func (s *Store) TrialsAhead(t *Trial, fresh time.Time) (int, error) {
	var n int
	err := s.write.QueryRow(`SELECT COUNT(*) FROM fleet_trials
		WHERE state = ? AND principal <> ? AND last_seen >= ?
		  AND (waiting_since < ? OR (waiting_since = ? AND principal < ?))`,
		TrialWaiting, t.Principal, fresh.Unix(), t.WaitingSince.Unix(), t.WaitingSince.Unix(), t.Principal).Scan(&n)
	return n, err
}

// TrialsWaiting is how many trial people are waiting and were seen at or
// after fresh.
func (s *Store) TrialsWaiting(fresh time.Time) (int, error) {
	var n int
	err := s.write.QueryRow(`SELECT COUNT(*) FROM fleet_trials WHERE state = ? AND last_seen >= ?`,
		TrialWaiting, fresh.Unix()).Scan(&n)
	return n, err
}

// PlaceTrial records that pid was handed a login on host.
func (s *Store) PlaceTrial(pid, host string, now time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_trials SET state = ?, placed_at = ?, host = ?, last_seen = ?
		WHERE principal = ?`, TrialPlaced, now.Unix(), host, now.Unix(), pid)
	return err
}

// IdleTrials are the placed trial people last seen before cutoff.
func (s *Store) IdleTrials(cutoff time.Time) ([]Trial, error) {
	rows, err := s.write.Query(`SELECT `+trialCols+` FROM fleet_trials
		WHERE state = ? AND last_seen < ? ORDER BY last_seen, principal`, TrialPlaced, cutoff.Unix())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Trial
	for rows.Next() {
		t, err := scanTrial(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *t)
	}
	return out, rows.Err()
}

// ReclaimTrial records that pid's login was given back.
func (s *Store) ReclaimTrial(pid string, now time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_trials SET state = ?, reclaimed_at = ? WHERE principal = ? AND state = ?`,
		TrialReclaimed, now.Unix(), pid, TrialPlaced)
	return err
}

// RecordTrialTiming keeps ms as one anonymous timing, once per trial person:
// false when pid has no trial row or theirs was already recorded.
func (s *Store) RecordTrialTiming(pid string, ms int64, now time.Time) (bool, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	res, err := tx.Exec(`UPDATE fleet_trials SET timed_at = ? WHERE principal = ? AND timed_at = 0`, now.Unix(), pid)
	if err != nil {
		return false, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return false, nil
	}
	if _, err := tx.Exec(`INSERT INTO fleet_trial_timings (at, ms) VALUES (?, ?)`, now.Unix(), ms); err != nil {
		return false, err
	}
	return true, tx.Commit()
}

// TrialTimings are the timings recorded at or after since, in milliseconds.
func (s *Store) TrialTimings(since time.Time) ([]int64, error) {
	rows, err := s.write.Query(`SELECT ms FROM fleet_trial_timings WHERE at >= ? ORDER BY at`, since.Unix())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var ms int64
		if err := rows.Scan(&ms); err != nil {
			return nil, err
		}
		out = append(out, ms)
	}
	return out, rows.Err()
}

// TrialCounts is how many trial people are in each state.
func (s *Store) TrialCounts() (map[string]int, error) {
	rows, err := s.write.Query(`SELECT state, COUNT(*) FROM fleet_trials GROUP BY state`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]int{}
	for rows.Next() {
		var st string
		var n int
		if err := rows.Scan(&st, &n); err != nil {
			return nil, err
		}
		out[st] = n
	}
	return out, rows.Err()
}
