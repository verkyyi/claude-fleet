package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// A drill trier (claude-fleet#4215) is a stand-in stranger an admin mints so
// an isolated drill (claude-fleet#4061) can walk the trial exactly as a real
// person does — take a spare, talk on the web, give it back, have it washed,
// let another take the same machine, come back and go on — with no real
// WeChat account and no scan. It signs in by kind "drill" + subject
// "trial-<random>", is never on the list, and lives as long as a drill
// (expires_at). A sign-in is one exchange of a one-time code
// (hub_drill_trial_codes: spent once, worthless after its own short life); a
// drill trier that comes back for its conversation is minted another code
// for the same subject. principal_id is the person its first exchange made
// (empty until then). When it expires the sweep gives its machine back and
// deletes it — its conversation's ciphertext, its identity, its trial, the rows.
const drillTrialsSchema = `
CREATE TABLE IF NOT EXISTS hub_drill_trials (
  subject      TEXT PRIMARY KEY,
  principal_id TEXT NOT NULL DEFAULT '',
  created_by   TEXT NOT NULL DEFAULT '',
  created_at   INTEGER NOT NULL,
  expires_at   INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS hub_drill_trial_codes (
  code_hash  TEXT PRIMARY KEY,
  subject    TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  used_at    INTEGER NOT NULL DEFAULT 0
);`

// ErrDrillTrialCode: the exchange code is unknown, already spent, past its
// life, or its drill trier's.
var ErrDrillTrialCode = errors.New("exchange code unknown, used or expired")

// ErrDrillTrialBusy: the drill trier still holds a login on a machine.
var ErrDrillTrialBusy = errors.New("the drill trier still holds a login")

// DrillTrial is one drill trier.
type DrillTrial struct {
	Subject     string    `json:"subject"`
	PrincipalID string    `json:"person_id,omitempty"`
	CreatedBy   string    `json:"created_by,omitempty"`
	CreatedAt   time.Time `json:"created_at"`
	ExpiresAt   time.Time `json:"expires_at"`
}

func (s *Store) ensureDrillTrials() error {
	if _, err := s.write.Exec(s.d.ddl(drillTrialsSchema)); err != nil {
		return fmt.Errorf("create drill trial tables: %w", err)
	}
	return nil
}

const drillTrialCols = `subject, principal_id, created_by, created_at, expires_at`

func scanDrillTrial(row interface{ Scan(...any) error }) (*DrillTrial, error) {
	var d DrillTrial
	var c, e int64
	if err := row.Scan(&d.Subject, &d.PrincipalID, &d.CreatedBy, &c, &e); err != nil {
		return nil, err
	}
	d.CreatedAt, d.ExpiresAt = unixOrZero(c), unixOrZero(e)
	return &d, nil
}

// CreateDrillTrial records a new drill trier.
func (s *Store) CreateDrillTrial(d DrillTrial) error {
	if d.Subject == "" || d.ExpiresAt.IsZero() {
		return errors.New("drill trier: empty field")
	}
	_, err := s.write.Exec(`INSERT INTO hub_drill_trials (subject, principal_id, created_by, created_at, expires_at)
		VALUES (?, '', ?, ?, ?)`, d.Subject, d.CreatedBy, d.CreatedAt.Unix(), d.ExpiresAt.Unix())
	return err
}

// DrillTrialBySubject is the drill trier subject names, alive or not; nil,
// nil for none.
func (s *Store) DrillTrialBySubject(subject string) (*DrillTrial, error) {
	d, err := scanDrillTrial(s.write.QueryRow(`SELECT `+drillTrialCols+` FROM hub_drill_trials WHERE subject = ?`, subject))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return d, err
}

// DrillTrialOf is the drill trier pid is; nil, nil when pid is not one.
func (s *Store) DrillTrialOf(pid string) (*DrillTrial, error) {
	if pid == "" {
		return nil, nil
	}
	d, err := scanDrillTrial(s.write.QueryRow(`SELECT `+drillTrialCols+` FROM hub_drill_trials WHERE principal_id = ?`, pid))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return d, err
}

// AddDrillTrialCode keeps codeHash as a one-time exchange code for subject,
// good until expires — only while the drill trier is alive at now
// (ErrNoPrincipal otherwise).
func (s *Store) AddDrillTrialCode(subject, codeHash string, expires, now time.Time) error {
	res, err := s.write.Exec(`INSERT INTO hub_drill_trial_codes (code_hash, subject, expires_at)
		SELECT ?, subject, ? FROM hub_drill_trials WHERE subject = ? AND expires_at > ?`,
		codeHash, expires.Unix(), subject, now.Unix())
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNoPrincipal
	}
	return nil
}

// UseDrillTrialCode spends an exchange code: once, before it expires, and
// only while its drill trier is alive.
func (s *Store) UseDrillTrialCode(codeHash string, now time.Time) (*DrillTrial, error) {
	res, err := s.write.Exec(`UPDATE hub_drill_trial_codes SET used_at = ?
		WHERE code_hash = ? AND used_at = 0 AND expires_at > ?
		AND subject IN (SELECT subject FROM hub_drill_trials WHERE expires_at > ?)`,
		now.Unix(), codeHash, now.Unix(), now.Unix())
	if err != nil {
		return nil, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil, ErrDrillTrialCode
	}
	d, err := scanDrillTrial(s.write.QueryRow(`SELECT `+drillTrialCols+` FROM hub_drill_trials
		WHERE subject = (SELECT subject FROM hub_drill_trial_codes WHERE code_hash = ?)`, codeHash))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrDrillTrialCode
	}
	return d, err
}

// SetDrillTrialPrincipal records the person subject's first exchange made.
func (s *Store) SetDrillTrialPrincipal(subject, pid string) error {
	_, err := s.write.Exec(`UPDATE hub_drill_trials SET principal_id = ? WHERE subject = ? AND principal_id = ''`, pid, subject)
	return err
}

// ExpiredDrillTrials are the drill triers whose life is over at now.
func (s *Store) ExpiredDrillTrials(now time.Time) ([]DrillTrial, error) {
	rows, err := s.write.Query(`SELECT `+drillTrialCols+` FROM hub_drill_trials WHERE expires_at <= ?
		ORDER BY expires_at, subject`, now.Unix())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []DrillTrial
	for rows.Next() {
		d, err := scanDrillTrial(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *d)
	}
	return out, rows.Err()
}

// DeleteDrillTrial takes the drill trier subject off the hub: its kept
// conversation (the ciphertext), its identity, its trial, its given-back
// login rows, its person and its codes. One that still holds a login on a
// machine (an account row not removed) is ErrDrillTrialBusy and nothing
// changes — give it back first.
func (s *Store) DeleteDrillTrial(subject string) error {
	d, err := s.DrillTrialBySubject(subject)
	if err != nil {
		return err
	}
	if d == nil {
		return ErrNoPrincipal
	}
	tx, err := s.write.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if pid := d.PrincipalID; pid != "" {
		var live int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM fleet_accounts WHERE principal_id = ? AND state <> ?`,
			pid, AccountRemoved).Scan(&live); err != nil {
			return err
		}
		if live > 0 {
			return ErrDrillTrialBusy
		}
		for _, q := range []string{
			`DELETE FROM hub_trial_convos WHERE principal = ?`,
			`DELETE FROM fleet_trials WHERE principal = ?`,
			`DELETE FROM hub_identities WHERE principal_id = ?`,
			`DELETE FROM fleet_accounts WHERE principal_id = ?`,
			`DELETE FROM fleet_principals WHERE principal_id = ?`,
		} {
			if _, err := tx.Exec(q, pid); err != nil {
				return err
			}
		}
	}
	for _, q := range []string{
		`DELETE FROM hub_identities WHERE kind = '` + DrillKind + `' AND subject = ?`,
		`DELETE FROM fleet_trials WHERE kind = '` + DrillKind + `' AND subject = ?`,
		`DELETE FROM hub_drill_trial_codes WHERE subject = ?`,
		`DELETE FROM hub_drill_trials WHERE subject = ?`,
	} {
		if _, err := tx.Exec(q, subject); err != nil {
			return err
		}
	}
	return tx.Commit()
}
