package store

import (
	"database/sql"
	"errors"
	"time"
)

// A trial person's key to a partner product, held by the hub only (task XA4R,
// 试用网页直接在微信打开): the first time a trial's session publishes a web
// page, the hub opens a 活页 (LivePage) account for them by the WeChat
// identity they scanned in with and keeps the workspace key it is given here,
// sealed to that principal (the caller seals — internal/credvault). Only the
// machine's credential proxy asks for it (GET/POST /v1/node/livepage-token);
// the session never sees it. One row per (principal, kind). revoked_at set =
// the key is dead here: never handed out again; remote_done says the partner
// was told too (the sweep retries until it was). fail_* is the provision
// back-off: a partner that is down is asked again after a while, not on every
// request. The token itself is never in a log or an audit row.
const partnerCredsSchema = `
CREATE TABLE IF NOT EXISTS hub_partner_creds (
  principal     TEXT NOT NULL,
  kind          TEXT NOT NULL,
  subject       TEXT NOT NULL DEFAULT '',
  enc_token     BLOB,
  until         INTEGER NOT NULL DEFAULT 0,
  created_at    INTEGER NOT NULL DEFAULT 0,
  revoked_at    INTEGER NOT NULL DEFAULT 0,
  revoke_reason TEXT NOT NULL DEFAULT '',
  remote_done   INTEGER NOT NULL DEFAULT 0,
  fail_at       INTEGER NOT NULL DEFAULT 0,
  fail_count    INTEGER NOT NULL DEFAULT 0,
  fail_why      TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (principal, kind)
);`

// PartnerLivePage is the 活页 kind.
const PartnerLivePage = "livepage"

// PartnerCred is one row; Sealed is empty before the first provision.
type PartnerCred struct {
	Principal string
	Kind      string
	// Subject is who the partner knows them as: the service account's openid.
	Subject      string
	Sealed       []byte
	Until        time.Time
	CreatedAt    time.Time
	RevokedAt    time.Time
	RevokeReason string
	RemoteDone   bool
	FailAt       time.Time
	FailCount    int
	FailWhy      string
}

// Live says the key may still be handed out at now.
func (c *PartnerCred) Live(now time.Time) bool {
	return c != nil && len(c.Sealed) > 0 && c.RevokedAt.IsZero() && (c.Until.IsZero() || now.Before(c.Until))
}

func (s *Store) ensurePartnerCreds() error {
	_, err := s.write.Exec(s.d.ddl(partnerCredsSchema))
	return err
}

const partnerCredCols = `principal, kind, subject, enc_token, until, created_at, revoked_at, revoke_reason, remote_done, fail_at, fail_count, fail_why`

func scanPartnerCred(row interface{ Scan(...any) error }) (*PartnerCred, error) {
	var c PartnerCred
	var until, cr, rv, fa int64
	var rd int
	if err := row.Scan(&c.Principal, &c.Kind, &c.Subject, &c.Sealed, &until, &cr, &rv, &c.RevokeReason, &rd, &fa, &c.FailCount, &c.FailWhy); err != nil {
		return nil, err
	}
	c.Until, c.CreatedAt, c.RevokedAt, c.FailAt = unixOrZero(until), unixOrZero(cr), unixOrZero(rv), unixOrZero(fa)
	c.RemoteDone = rd != 0
	return &c, nil
}

// PartnerCred is pid's row of kind; nil, nil for none.
func (s *Store) PartnerCred(pid, kind string) (*PartnerCred, error) {
	c, err := scanPartnerCred(s.write.QueryRow(`SELECT `+partnerCredCols+` FROM hub_partner_creds
		WHERE principal = ? AND kind = ?`, pid, kind))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return c, err
}

// PutPartnerCred keeps a freshly provisioned sealed key for pid, live until
// until — a new key replaces a revoked one (a trial that came back) and
// clears the back-off.
func (s *Store) PutPartnerCred(pid, kind, subject string, sealed []byte, until, now time.Time) error {
	_, err := s.write.Exec(`INSERT INTO hub_partner_creds (principal, kind, subject, enc_token, until, created_at)
		VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(principal, kind) DO UPDATE SET enc_token = excluded.enc_token,
		subject = excluded.subject,
		until = excluded.until, created_at = excluded.created_at, revoked_at = 0, revoke_reason = '',
		remote_done = 0, fail_at = 0, fail_count = 0, fail_why = ''`,
		pid, kind, subject, sealed, until.Unix(), now.Unix())
	return err
}

// PartnerCredFailed records a failed provision for pid (the back-off).
func (s *Store) PartnerCredFailed(pid, kind, why string, now time.Time) error {
	_, err := s.write.Exec(`INSERT INTO hub_partner_creds (principal, kind, fail_at, fail_count, fail_why)
		VALUES (?, ?, ?, 1, ?) ON CONFLICT(principal, kind) DO UPDATE SET fail_at = excluded.fail_at,
		fail_count = hub_partner_creds.fail_count + 1, fail_why = excluded.fail_why`,
		pid, kind, now.Unix(), why)
	return err
}

// RevokePartnerCred kills pid's key here at now for reason (the first reason
// stays); changed says it was live. The sealed key is dropped with it.
func (s *Store) RevokePartnerCred(pid, kind, reason string, now time.Time) (bool, error) {
	res, err := s.write.Exec(`UPDATE hub_partner_creds SET revoked_at = ?, revoke_reason = ?, enc_token = NULL
		WHERE principal = ? AND kind = ? AND revoked_at = 0 AND created_at > 0`, now.Unix(), reason, pid, kind)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// ErasePartnerCred marks pid's key for erasure (they deleted their data): taken
// back if it still lived, and the partner told again — now to close the
// account at once — even when an earlier revoke was told already. changed
// says there was an account and it was not marked so before.
func (s *Store) ErasePartnerCred(pid, kind string, now time.Time) (bool, error) {
	res, err := s.write.Exec(`UPDATE hub_partner_creds SET revoked_at = CASE WHEN revoked_at = 0 THEN ? ELSE revoked_at END,
		revoke_reason = 'erase', remote_done = 0, enc_token = NULL
		WHERE principal = ? AND kind = ? AND created_at > 0 AND revoke_reason <> 'erase'`, now.Unix(), pid, kind)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// PartnerCredRemoteDone records that the partner was told of the revoke.
func (s *Store) PartnerCredRemoteDone(pid, kind string) error {
	_, err := s.write.Exec(`UPDATE hub_partner_creds SET remote_done = 1 WHERE principal = ? AND kind = ?`, pid, kind)
	return err
}

// PartnerCreds is every row of kind that was ever provisioned: live ones (the
// expiry sweep reads them) and revoked ones the partner was not yet told of.
func (s *Store) PartnerCreds(kind string) ([]PartnerCred, error) {
	rows, err := s.read.Query(`SELECT `+partnerCredCols+` FROM hub_partner_creds
		WHERE kind = ? AND created_at > 0 AND (revoked_at = 0 OR remote_done = 0) ORDER BY principal`, kind)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PartnerCred
	for rows.Next() {
		c, err := scanPartnerCred(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *c)
	}
	return out, rows.Err()
}
