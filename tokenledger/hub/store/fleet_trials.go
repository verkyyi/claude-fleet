package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// The 60-second trial (claude-fleet#3590, EPIC #3569 C20): a person who came
// in through /app/try is a trial person — one row here, from their sign-in.
// It is the waitlist (waiting, in waiting_since order), the record of which
// machine handed them a spare (placed), the last time they used it
// (last_seen, the 7-day reclaim reads it) and whether their one timing was
// recorded. Since claude-fleet#4058 a row also names the verified way the
// person signed in by (kind, subject — WeChat by unionid, else openid): one
// trial per way, unique, so a second sign-in by it finds the first trial
// instead of starting another. queue_reason is why they last waited (full ·
// busy · load · quota), kept so the audit records a change, not every poll.
// The timings themselves are anonymous: fleet_trial_timings keeps
// when and how long, never who. Since claude-fleet#4059 a row also holds the
// trial's budget spent: used_secs (time it held a machine, summed over each
// seat — added up when a seat goes back), msgs (lines it sent), capped_at
// (when the last line allowed was sent: the machine goes back once its reply
// had time to arrive) and ended_reason (why it ended: time · msgs, C12 adds
// its own; approved when it became a member). Since claude-fleet#4060 a placed
// row also carries the page's last heartbeat (beat_at) and the person's last
// input (input_at) — what the 15-second patrol gives the machine back on —
// and when the 「1 分钟后暂停」 warning went out (warned_at); C12's reasons are
// hidden · idle · pause, and the conversation is kept apart (hub_trial_convos).
// Since claude-fleet#4235 ready_at is when the seat became usable (its home
// set, the conversation in): idle counts from there, never while it opens.
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
  reclaimed_at  INTEGER NOT NULL DEFAULT 0,
  kind          TEXT NOT NULL DEFAULT '',
  subject       TEXT NOT NULL DEFAULT '',
  queue_reason  TEXT NOT NULL DEFAULT '',
  used_secs     INTEGER NOT NULL DEFAULT 0,
  msgs          INTEGER NOT NULL DEFAULT 0,
  capped_at     INTEGER NOT NULL DEFAULT 0,
  ended_reason  TEXT NOT NULL DEFAULT '',
  beat_at       INTEGER NOT NULL DEFAULT 0,
  input_at      INTEGER NOT NULL DEFAULT 0,
  warned_at     INTEGER NOT NULL DEFAULT 0,
  ready_at      INTEGER NOT NULL DEFAULT 0
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
	// TrialConverted: approved — a member now, the trial over
	// (claude-fleet#4059); the login it held, if any, stays theirs.
	TrialConverted = "converted"
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
	Kind         string
	Subject      string
	QueueReason  string
	UsedSecs     int64
	Msgs         int
	CappedAt     time.Time
	EndedReason  string
	BeatAt       time.Time
	InputAt      time.Time
	WarnedAt     time.Time
	ReadyAt      time.Time
}

// Used is how long t has held a machine by now: every seat before, and the
// one it holds.
func (t *Trial) Used(now time.Time) time.Duration {
	d := time.Duration(t.UsedSecs) * time.Second
	if t.State == TrialPlaced && !t.PlacedAt.IsZero() && now.After(t.PlacedAt) {
		d += now.Sub(t.PlacedAt)
	}
	return d
}

func (s *Store) ensureFleetTrials() error {
	if _, err := s.write.Exec(s.d.ddl(fleetTrialsSchema)); err != nil {
		return fmt.Errorf("create fleet trials tables: %w", err)
	}
	for _, col := range []string{"kind", "subject", "queue_reason"} {
		if err := s.addColumn("fleet_trials", col, "TEXT NOT NULL DEFAULT ''"); err != nil {
			return err
		}
	}
	for _, col := range []string{"used_secs", "msgs", "capped_at", "beat_at", "input_at", "warned_at", "ready_at"} {
		if err := s.addColumn("fleet_trials", col, "INTEGER NOT NULL DEFAULT 0"); err != nil {
			return err
		}
	}
	if err := s.addColumn("fleet_trials", "ended_reason", "TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if _, err := s.write.Exec(s.d.ddl(trialConvosSchema)); err != nil {
		return fmt.Errorf("create trial conversations table: %w", err)
	}
	if err := s.ensureChatMirrors(); err != nil {
		return err
	}
	if _, err := s.write.Exec(`CREATE UNIQUE INDEX IF NOT EXISTS idx_fleet_trials_way
		ON fleet_trials(kind, subject) WHERE kind <> ''`); err != nil {
		return fmt.Errorf("create fleet trials way index: %w", err)
	}
	return nil
}

func unixOrZero(v int64) time.Time {
	if v <= 0 {
		return time.Time{}
	}
	return time.Unix(v, 0).UTC()
}

const trialCols = `principal, state, started_at, waiting_since, placed_at, host, last_seen, timed_at, reclaimed_at, kind, subject, queue_reason, used_secs, msgs, capped_at, ended_reason,
	beat_at, input_at, warned_at, ready_at`

func scanTrial(row interface{ Scan(...any) error }) (*Trial, error) {
	var t Trial
	var st, ws, pa, ls, ta, ra, ca, ba, ia, wa, ya int64
	if err := row.Scan(&t.Principal, &t.State, &st, &ws, &pa, &t.Host, &ls, &ta, &ra, &t.Kind, &t.Subject, &t.QueueReason,
		&t.UsedSecs, &t.Msgs, &ca, &t.EndedReason, &ba, &ia, &wa, &ya); err != nil {
		return nil, err
	}
	t.CappedAt = unixOrZero(ca)
	t.BeatAt, t.InputAt, t.WarnedAt = unixOrZero(ba), unixOrZero(ia), unixOrZero(wa)
	t.ReadyAt = unixOrZero(ya)
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

// ErrTrialWayTaken: another person's trial already holds this way.
var ErrTrialWayTaken = errors.New("this way of signing in already has a trial")

// StartTrialAs records pid as a trial person who signed in by kind + subject,
// waiting from now. pid's own row, if any, is kept as it is; a way another
// person's trial holds is ErrTrialWayTaken.
func (s *Store) StartTrialAs(pid, kind, subject string, now time.Time) error {
	if t, err := s.TrialByWay(kind, subject); err != nil {
		return err
	} else if t != nil && t.Principal != pid {
		return ErrTrialWayTaken
	}
	_, err := s.write.Exec(s.d.insertIgnore(`INSERT OR IGNORE INTO fleet_trials
		(principal, state, started_at, waiting_since, last_seen, kind, subject) VALUES (?, ?, ?, ?, ?, ?, ?)`),
		pid, TrialWaiting, now.Unix(), now.Unix(), now.Unix(), kind, subject)
	return err
}

// TrialByWay is the trial the way kind + subject started; nil, nil for none.
func (s *Store) TrialByWay(kind, subject string) (*Trial, error) {
	if kind == "" {
		return nil, nil
	}
	t, err := scanTrial(s.write.QueryRow(`SELECT `+trialCols+` FROM fleet_trials WHERE kind = ? AND subject = ?`, kind, subject))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return t, err
}

// SetTrialQueueReason records why pid waits now; changed says it differs
// from the last one recorded.
func (s *Store) SetTrialQueueReason(pid, reason string) (changed bool, err error) {
	res, err := s.write.Exec(`UPDATE fleet_trials SET queue_reason = ? WHERE principal = ? AND queue_reason <> ?`,
		reason, pid, reason)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// TrialsHolding is how many trial people hold a machine now (placed).
func (s *Store) TrialsHolding() (int, error) {
	var n int
	err := s.write.QueryRow(`SELECT COUNT(*) FROM fleet_trials WHERE state = ?`, TrialPlaced).Scan(&n)
	return n, err
}

// TrialsStartedSince is how many trials were handed a machine at or after
// since — the day's total counts each person's start once.
func (s *Store) TrialsStartedSince(since time.Time) (int, error) {
	var n int
	err := s.write.QueryRow(`SELECT COUNT(*) FROM fleet_trials WHERE placed_at >= ?`, since.Unix()).Scan(&n)
	return n, err
}

// TrialReleases are the last n times a trial's machine went back, newest first.
func (s *Store) TrialReleases(n int) ([]time.Time, error) {
	rows, err := s.write.Query(`SELECT reclaimed_at FROM fleet_trials WHERE reclaimed_at > 0
		ORDER BY reclaimed_at DESC LIMIT ?`, n)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []time.Time
	for rows.Next() {
		var v int64
		if err := rows.Scan(&v); err != nil {
			return nil, err
		}
		out = append(out, unixOrZero(v))
	}
	return out, rows.Err()
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

// RejoinTrial puts a reclaimed trial person back at the end of the waitlist,
// with a whole budget again (fleet.trial.once off).
func (s *Store) RejoinTrial(pid string, now time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_trials SET state = ?, waiting_since = ?, placed_at = 0, host = '',
		reclaimed_at = 0, last_seen = ?, used_secs = 0, msgs = 0, capped_at = 0, ended_reason = '' WHERE principal = ? AND state = ?`,
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
	_, err := s.write.Exec(`UPDATE fleet_trials SET state = ?, placed_at = ?, host = ?, last_seen = ?, queue_reason = '',
		beat_at = ?, input_at = ?, warned_at = 0, ready_at = 0 WHERE principal = ?`, TrialPlaced, now.Unix(), host, now.Unix(), now.Unix(), now.Unix(), pid)
	return err
}

// PlacedTrials are every trial person holding a machine now.
func (s *Store) PlacedTrials() ([]Trial, error) {
	return s.trialsWhere(`state = ?`, TrialPlaced)
}

func (s *Store) trialsWhere(where string, args ...any) ([]Trial, error) {
	rows, err := s.write.Query(`SELECT `+trialCols+` FROM fleet_trials WHERE `+where+` ORDER BY principal`, args...)
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

// BeatTrial records the page's heartbeat at now and the person's last input
// at input (never later than now, never earlier than what is kept); a beat
// that carries input after the warning clears it. Nothing for a trial that
// holds no machine; false then.
func (s *Store) BeatTrial(pid string, now, input time.Time) (bool, error) {
	in := input.Unix()
	if input.IsZero() || in > now.Unix() {
		in = 0
	}
	res, err := s.write.Exec(`UPDATE fleet_trials SET beat_at = ?, last_seen = ?,
		input_at = CASE WHEN ? > input_at THEN ? ELSE input_at END,
		warned_at = CASE WHEN ? > warned_at THEN 0 ELSE warned_at END
		WHERE principal = ? AND state = ?`, now.Unix(), now.Unix(), in, in, in, pid, TrialPlaced)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// ReadyTrial records that pid's seat became usable at now — the first time
// only; the idle lines count from here (claude-fleet#4235). false: pid holds
// no machine, or it was ready already.
func (s *Store) ReadyTrial(pid string, now time.Time) (bool, error) {
	res, err := s.write.Exec(`UPDATE fleet_trials SET ready_at = ?, warned_at = 0
		WHERE principal = ? AND state = ? AND ready_at = 0`, now.Unix(), pid, TrialPlaced)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// RequeueTrial puts back a seat that never became usable (claude-fleet#4235):
// pid waits again in the place it had (waiting_since kept), the seat's time is
// not charged, and it is not a start of the day (placed_at cleared) — the
// trial is not spent by a machine that did not open. false: pid held none.
func (s *Store) RequeueTrial(pid, reason string, now time.Time) (bool, error) {
	res, err := s.write.Exec(`UPDATE fleet_trials SET state = ?, placed_at = 0, host = '', reclaimed_at = 0,
		ended_reason = '', queue_reason = ?, last_seen = ?, beat_at = 0, input_at = 0, warned_at = 0, ready_at = 0
		WHERE principal = ? AND state = ?`, TrialWaiting, reason, now.Unix(), pid, TrialPlaced)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// WarnTrial records that pid was told 「1 分钟后暂停」 at now.
func (s *Store) WarnTrial(pid string, now time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_trials SET warned_at = ? WHERE principal = ? AND state = ? AND warned_at = 0`,
		now.Unix(), pid, TrialPlaced)
	return err
}

// ReleaseTrial records that pid's machine went back at now, why — EndTrial
// that says whether it moved (false: pid held no machine; a second release of
// the same seat records nothing) and clears the seat's heartbeat.
func (s *Store) ReleaseTrial(pid, reason string, now time.Time) (bool, error) {
	res, err := s.write.Exec(`UPDATE fleet_trials SET state = ?, reclaimed_at = ?, ended_reason = ?,
		used_secs = used_secs + CASE WHEN placed_at > 0 AND ? > placed_at THEN ? - placed_at ELSE 0 END,
		beat_at = 0, input_at = 0, warned_at = 0, ready_at = 0
		WHERE principal = ? AND state = ?`,
		TrialReclaimed, now.Unix(), reason, now.Unix(), now.Unix(), pid, TrialPlaced)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// ResumeTrial puts a paused trial person back at the end of the waitlist with
// what is left of their budget — the same trial (claude-fleet#4060), unlike
// RejoinTrial's fresh one.
func (s *Store) ResumeTrial(pid string, now time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_trials SET state = ?, waiting_since = ?, placed_at = 0, host = '',
		reclaimed_at = 0, ended_reason = '', last_seen = ? WHERE principal = ? AND state = ?`,
		TrialWaiting, now.Unix(), now.Unix(), pid, TrialReclaimed)
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
func (s *Store) ReclaimTrial(pid string, now time.Time) error { return s.EndTrial(pid, "", now) }

// EndTrial records that pid's login was given back because of reason: the
// seat's time is added to used_secs.
func (s *Store) EndTrial(pid, reason string, now time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_trials SET state = ?, reclaimed_at = ?,
		used_secs = used_secs + CASE WHEN placed_at > 0 AND ? > placed_at THEN ? - placed_at ELSE 0 END,
		ended_reason = ? WHERE principal = ? AND state = ?`,
		TrialReclaimed, now.Unix(), now.Unix(), now.Unix(), reason, pid, TrialPlaced)
	return err
}

// ConvertTrial records that pid was approved: the trial is over, whatever
// state it was in (a seat's time is added to used_secs). changed=false when
// pid has no trial, or it was converted already.
func (s *Store) ConvertTrial(pid string, now time.Time) (changed bool, err error) {
	res, err := s.write.Exec(`UPDATE fleet_trials SET state = ?, ended_reason = 'approved',
		used_secs = used_secs + CASE WHEN state = ? AND placed_at > 0 AND ? > placed_at THEN ? - placed_at ELSE 0 END
		WHERE principal = ? AND state <> ?`,
		TrialConverted, TrialPlaced, now.Unix(), now.Unix(), pid, TrialConverted)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// CountTrialMsg counts one line pid sends from its seat, when fewer than max
// were sent: ok=false (nothing counted) for no seat or none left. n is the
// lines sent with this one; the last allowed one marks capped_at.
func (s *Store) CountTrialMsg(pid string, max int, now time.Time) (n int, ok bool, err error) {
	tx, err := s.write.Begin()
	if err != nil {
		return 0, false, err
	}
	defer tx.Rollback()
	res, err := tx.Exec(`UPDATE fleet_trials SET msgs = msgs + 1, last_seen = ?,
		capped_at = CASE WHEN msgs + 1 >= ? THEN ? ELSE capped_at END
		WHERE principal = ? AND state = ? AND msgs < ?`, now.Unix(), max, now.Unix(), pid, TrialPlaced, max)
	if err != nil {
		return 0, false, err
	}
	if c, _ := res.RowsAffected(); c == 0 {
		return 0, false, nil
	}
	if err := tx.QueryRow(`SELECT msgs FROM fleet_trials WHERE principal = ?`, pid).Scan(&n); err != nil {
		return 0, false, err
	}
	return n, true, tx.Commit()
}

// UncountTrialMsg gives back a line CountTrialMsg took for a turn that got no
// reply (claude-fleet#4248): the relay never reached the service, or it ended
// on an error frame. The line is no longer the last one, so capped_at goes too.
func (s *Store) UncountTrialMsg(pid string) error {
	_, err := s.write.Exec(`UPDATE fleet_trials SET msgs = msgs - 1, capped_at = 0
		WHERE principal = ? AND state = ? AND msgs > 0`, pid, TrialPlaced)
	return err
}

// SpentTrials are the placed trials whose budget is spent at now: maxSecs of
// a machine, or the last line sent at least grace ago.
func (s *Store) SpentTrials(now time.Time, maxSecs int64, grace time.Duration) ([]Trial, error) {
	rows, err := s.write.Query(`SELECT `+trialCols+` FROM fleet_trials
		WHERE state = ? AND ((placed_at > 0 AND used_secs + ? - placed_at >= ?) OR (capped_at > 0 AND capped_at <= ?))
		ORDER BY placed_at, principal`, TrialPlaced, now.Unix(), maxSecs, now.Add(-grace).Unix())
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

// HandOffWash gives pid's login on host, queued or being washed for the next
// person (reset_pending · resetting), to a spare holder of its own
// (claude-fleet#4060): the wash runs on as before — the same op, the same
// check, a clean answer recycled into a ready spare (RecycleAccount, which
// drops the holder), anything else failed and never handed out — while pid is
// free at once to be handed another login on the same machine. false: nothing
// of pid's there is being washed.
func (s *Store) HandOffWash(pid, host string, at time.Time) (bool, error) {
	nonce, err := randomLowerAlnum(8)
	if err != nil {
		return false, err
	}
	id := SparePrefix + strings.ToLower(host) + ":" + nonce
	tx, err := s.write.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(s.d.deferForeignKeys()); err != nil {
		return false, err
	}
	ts := at.UTC().Format(rfc)
	if _, err := tx.Exec(`INSERT INTO fleet_principals (principal_id, login, display_name, created_at)
		VALUES (?, ?, ?, ?)`, id, "spare."+nonce, SpareFullName, ts); err != nil {
		return false, err
	}
	res, err := tx.Exec(`UPDATE fleet_accounts SET principal_id = ?, detail = ?, updated_at = ?
		WHERE principal_id = ? AND hostname = ? AND state IN (?, ?)`,
		id, "washing for the next person: given back by trial "+pid, ts, pid, host, AccountResetPending, AccountResetting)
	if err != nil {
		return false, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return false, nil
	}
	return true, tx.Commit()
}

// ReclaimedTrialsHolding are the ended (reclaimed) trials that still hold a
// managed login in a state the operator's remove takes — active, failed or
// unknown (claude-fleet#4262): what the patrol washes after the fact.
func (s *Store) ReclaimedTrialsHolding() ([]string, error) {
	rows, err := s.write.Query(`SELECT DISTINCT t.principal FROM fleet_trials t
		JOIN fleet_accounts a ON a.principal_id = t.principal
		WHERE t.state = ? AND a.op <> ? AND a.state IN (?, ?, ?) ORDER BY t.principal`,
		TrialReclaimed, AccountOpLogin, AccountActive, AccountFailed, AccountUnknown)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}
