package store

import (
	"database/sql"
	"errors"
	"time"
)

// Sign-in by mail and the one-use values of a sign-in (claude-fleet#3604,
// EPIC #3570 C11). The hub runs as two replicas, so what a sign-in must
// remember between two requests — a mail's code, a WeChat state already
// used — is here, never in one replica's memory. Nothing secret is stored:
// every token, code and browser nonce is a hash.

// SigninCodeTTL is how long a sign-in mail's link and code live.
const SigninCodeTTL = 15 * time.Minute

// SigninCodeTries is how many wrong codes void a mail.
const SigninCodeTries = 5

// SigninCode is one sign-in mail asked for.
type SigninCode struct {
	ID          string
	Kind        string // IdentityEmail
	Subject     string // the address, normalised
	BrowserHash string // the starting browser's nonce, hashed
	LinkHash    string // the link's token, hashed
	CodeHash    string // the six-digit code, hashed with ID
	Tries       int
	CreatedAt   time.Time
	ExpiresAt   time.Time
	UsedAt      time.Time
}

// CreateSigninCode records a mail asked for.
func (s *Store) CreateSigninCode(c SigninCode) error {
	_, err := s.write.Exec(`INSERT INTO hub_signin_codes
		(id, kind, subject, browser_hash, link_hash, code_hash, tries, created_at, expires_at, used_at)
		VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, 0)`,
		c.ID, c.Kind, c.Subject, c.BrowserHash, c.LinkHash, c.CodeHash, c.CreatedAt.Unix(), c.ExpiresAt.Unix())
	if err == nil {
		// Rows past an hour count toward no limit and open nothing.
		_, _ = s.write.Exec(`DELETE FROM hub_signin_codes WHERE created_at < ?`, c.CreatedAt.Add(-2*time.Hour).Unix())
	}
	return err
}

// SigninCodeStats is what the limits read for kind+subject: when the last
// mail was asked for (zero for never) and how many since since.
func (s *Store) SigninCodeStats(kind, subject string, since time.Time) (last time.Time, n int, err error) {
	var lastAt sql.NullInt64
	err = s.read.QueryRow(`SELECT MAX(created_at), COUNT(*) FROM hub_signin_codes
		WHERE kind = ? AND subject = ? AND created_at >= ?`, kind, subject, since.Unix()).Scan(&lastAt, &n)
	if err != nil {
		return time.Time{}, 0, err
	}
	if lastAt.Valid && lastAt.Int64 > 0 {
		last = time.Unix(lastAt.Int64, 0)
	}
	return last, n, nil
}

const signinCodeCols = `id, kind, subject, browser_hash, link_hash, code_hash, tries, created_at, expires_at, used_at`

func scanSigninCode(row *sql.Row) (*SigninCode, error) {
	var c SigninCode
	var created, expires, used int64
	err := row.Scan(&c.ID, &c.Kind, &c.Subject, &c.BrowserHash, &c.LinkHash, &c.CodeHash, &c.Tries, &created, &expires, &used)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	c.CreatedAt, c.ExpiresAt = time.Unix(created, 0), time.Unix(expires, 0)
	if used > 0 {
		c.UsedAt = time.Unix(used, 0)
	}
	return &c, nil
}

// SigninCodeByLink is the mail whose link token hashes to linkHash, used or
// not (nil for none): the caller tells «used» from «never made».
func (s *Store) SigninCodeByLink(linkHash string) (*SigninCode, error) {
	return scanSigninCode(s.read.QueryRow(`SELECT `+signinCodeCols+` FROM hub_signin_codes WHERE link_hash = ?`, linkHash))
}

// SigninCodeForBrowser is the newest mail this browser asked for that can
// still be used (nil for none).
func (s *Store) SigninCodeForBrowser(browserHash string, now time.Time) (*SigninCode, error) {
	return scanSigninCode(s.read.QueryRow(`SELECT `+signinCodeCols+` FROM hub_signin_codes
		WHERE browser_hash = ? AND used_at = 0 AND expires_at > ?
		ORDER BY created_at DESC, id DESC LIMIT 1`, browserHash, now.Unix()))
}

// UseSigninCode spends a mail: ok=false when it was already used, voided or
// has expired — whoever got here second.
func (s *Store) UseSigninCode(id string, now time.Time) (bool, error) {
	res, err := s.write.Exec(`UPDATE hub_signin_codes SET used_at = ?
		WHERE id = ? AND used_at = 0 AND expires_at > ?`, now.Unix(), id, now.Unix())
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// FailSigninCode counts one wrong code against a mail; the SigninCodeTries-th
// voids it. left is how many tries remain (0 = void).
func (s *Store) FailSigninCode(id string, now time.Time) (left int, err error) {
	if _, err = s.write.Exec(`UPDATE hub_signin_codes SET tries = tries + 1 WHERE id = ? AND used_at = 0`, id); err != nil {
		return 0, err
	}
	if _, err = s.write.Exec(`UPDATE hub_signin_codes SET used_at = ? WHERE id = ? AND used_at = 0 AND tries >= ?`,
		now.Unix(), id, SigninCodeTries); err != nil {
		return 0, err
	}
	var tries int
	if err = s.write.QueryRow(`SELECT tries FROM hub_signin_codes WHERE id = ?`, id).Scan(&tries); err != nil {
		return 0, err
	}
	if left = SigninCodeTries - tries; left < 0 {
		left = 0
	}
	return left, nil
}

// SpendSigninValue marks a one-use value (its hash) spent until expires:
// ok=false when it already was — a replay.
func (s *Store) SpendSigninValue(hash string, expires, now time.Time) (bool, error) {
	_, _ = s.write.Exec(`DELETE FROM hub_signin_spent WHERE expires_at < ?`, now.Unix())
	res, err := s.write.Exec(s.d.insertIgnore(`INSERT OR IGNORE INTO hub_signin_spent (hash, expires_at) VALUES (?, ?)`), hash, expires.Unix())
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}
