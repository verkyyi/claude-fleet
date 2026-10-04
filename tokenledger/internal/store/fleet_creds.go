package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// The hub's credential vault (claude-fleet#1415): every person's long-lived
// Claude / Codex credentials live here and nowhere else; a node only ever
// receives the short-lived half. The store keeps the two halves as opaque
// sealed blobs — sealing and opening them is internal/credvault's job, so the
// key never comes near SQLite — plus an audit row for every issue, denial and
// change, and the revocations that stop a node or a person from leasing more.
const fleetCredsSchema = `
CREATE TABLE IF NOT EXISTS fleet_credentials (
  principal_id     TEXT NOT NULL,
  provider         TEXT NOT NULL,
  account          TEXT NOT NULL,
  secret_sealed    BLOB NOT NULL,
  access_sealed    BLOB,
  access_expires_at TEXT,
  version          INTEGER NOT NULL DEFAULT 1,
  refreshed_at     TEXT,
  refresh_error    TEXT NOT NULL DEFAULT '',
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL,
  PRIMARY KEY (principal_id, provider, account)
);
CREATE TABLE IF NOT EXISTS fleet_cred_audit (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  at          TEXT NOT NULL,
  action      TEXT NOT NULL,
  principal_id TEXT NOT NULL DEFAULT '',
  provider    TEXT NOT NULL DEFAULT '',
  account     TEXT NOT NULL DEFAULT '',
  hostname    TEXT NOT NULL DEFAULT '',
  os_user     TEXT NOT NULL DEFAULT '',
  endpoint_id TEXT NOT NULL DEFAULT '',
  expires_at  TEXT,
  detail      TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS fleet_cred_audit_at ON fleet_cred_audit(at);
CREATE TABLE IF NOT EXISTS fleet_cred_revocations (
  hostname     TEXT NOT NULL DEFAULT '',
  principal_id TEXT NOT NULL DEFAULT '',
  revoked_at   TEXT NOT NULL,
  reason       TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (hostname, principal_id)
);`

// Audit actions.
const (
	CredIssue    = "issue"    // a node received a lease
	CredDeny     = "deny"     // a node asked and was refused
	CredRefresh  = "refresh"  // the hub refreshed an account (ok or failed: see detail)
	CredPut      = "put"      // the operator stored or replaced a credential
	CredDelete   = "delete"   // the operator removed a credential
	CredRevoke   = "revoke"   // a node / person was revoked
	CredUnrevoke = "unrevoke" // a revocation was lifted
)

// Credential is one stored (principal, provider, account) row. The sealed
// blobs are opaque here.
type Credential struct {
	PrincipalID     string     `json:"principal_id"`
	Provider        string     `json:"provider"`
	Account         string     `json:"account"`
	SecretSealed    []byte     `json:"-"`
	AccessSealed    []byte     `json:"-"`
	AccessExpiresAt *time.Time `json:"access_expires_at,omitempty"`
	Version         int64      `json:"version"`
	RefreshedAt     *time.Time `json:"refreshed_at,omitempty"`
	RefreshError    string     `json:"refresh_error,omitempty"`
	CreatedAt       time.Time  `json:"created_at"`
	UpdatedAt       time.Time  `json:"updated_at"`
}

// CredAudit is one audit row.
type CredAudit struct {
	ID          int64      `json:"id"`
	At          time.Time  `json:"at"`
	Action      string     `json:"action"`
	PrincipalID string     `json:"principal_id,omitempty"`
	Provider    string     `json:"provider,omitempty"`
	Account     string     `json:"account,omitempty"`
	Hostname    string     `json:"hostname,omitempty"`
	OSUser      string     `json:"os_user,omitempty"`
	EndpointID  string     `json:"endpoint_id,omitempty"`
	ExpiresAt   *time.Time `json:"expires_at,omitempty"`
	Detail      string     `json:"detail,omitempty"`
}

// CredRevocation stops leases: a hostname alone revokes the node, a principal
// alone revokes the person everywhere, both revoke the person on that node.
type CredRevocation struct {
	Hostname    string    `json:"hostname,omitempty"`
	PrincipalID string    `json:"principal_id,omitempty"`
	RevokedAt   time.Time `json:"revoked_at"`
	Reason      string    `json:"reason,omitempty"`
}

// ErrCredConflict is returned when a credential changed under a writer that
// read an older version.
var ErrCredConflict = errors.New("credential changed concurrently")

// ErrNoCredential is returned for an unknown (principal, provider, account).
var ErrNoCredential = errors.New("no such credential")

func (s *Store) ensureFleetCreds() error {
	if _, err := s.write.Exec(fleetCredsSchema); err != nil {
		return fmt.Errorf("create fleet credential tables: %w", err)
	}
	return nil
}

const credColumns = `SELECT principal_id, provider, account, secret_sealed, access_sealed, access_expires_at,
	version, refreshed_at, refresh_error, created_at, updated_at FROM fleet_credentials`

func scanCred(sc interface{ Scan(...any) error }) (Credential, error) {
	var c Credential
	var exp, ref sql.NullString
	var created, updated string
	if err := sc.Scan(&c.PrincipalID, &c.Provider, &c.Account, &c.SecretSealed, &c.AccessSealed, &exp,
		&c.Version, &ref, &c.RefreshError, &created, &updated); err != nil {
		return c, err
	}
	c.AccessExpiresAt = parseTimePtr(exp)
	c.RefreshedAt = parseTimePtr(ref)
	c.CreatedAt, _ = time.Parse(rfc, created)
	c.UpdatedAt, _ = time.Parse(rfc, updated)
	return c, nil
}

func parseTimePtr(v sql.NullString) *time.Time {
	if !v.Valid || v.String == "" {
		return nil
	}
	t, err := time.Parse(rfc, v.String)
	if err != nil {
		return nil
	}
	return &t
}

// Credential reads one row.
func (s *Store) Credential(principalID, provider, account string) (*Credential, error) {
	c, err := scanCred(s.write.QueryRow(credColumns+` WHERE principal_id = ? AND provider = ? AND account = ?`,
		principalID, provider, account))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNoCredential
	}
	if err != nil {
		return nil, err
	}
	return &c, nil
}

// Credentials lists rows; principalID "" means everyone's.
func (s *Store) Credentials(principalID string) ([]Credential, error) {
	q, args := credColumns+` ORDER BY principal_id, provider, account`, []any{}
	if principalID != "" {
		q, args = credColumns+` WHERE principal_id = ? ORDER BY provider, account`, []any{principalID}
	}
	// Read from the writer connection: a lease reads right after a refresh
	// committed, and must see it.
	rows, err := s.write.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Credential{}
	for rows.Next() {
		c, err := scanCred(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// PutCredential stores (or replaces) a credential's long-lived half. Any
// cached short-lived half is dropped: it was minted from the old secret.
func (s *Store) PutCredential(principalID, provider, account string, secret []byte, at time.Time) error {
	now := fmtTime(at)
	_, err := s.write.Exec(`INSERT INTO fleet_credentials
		(principal_id, provider, account, secret_sealed, access_sealed, access_expires_at, version, refresh_error, created_at, updated_at)
		VALUES (?, ?, ?, ?, NULL, NULL, 1, '', ?, ?)
		ON CONFLICT(principal_id, provider, account) DO UPDATE SET
		  secret_sealed = excluded.secret_sealed, access_sealed = NULL, access_expires_at = NULL,
		  version = fleet_credentials.version + 1, refresh_error = '', updated_at = excluded.updated_at`,
		principalID, provider, account, secret, now, now)
	return err
}

// DeleteCredential removes a credential.
func (s *Store) DeleteCredential(principalID, provider, account string) error {
	res, err := s.write.Exec(`DELETE FROM fleet_credentials WHERE principal_id = ? AND provider = ? AND account = ?`,
		principalID, provider, account)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNoCredential
	}
	return nil
}

// SaveRefresh records a refresh's result — the rotated long-lived half and the
// new short-lived one — but only if the row is still at version: a refresh
// computed from a secret the operator has since replaced must not overwrite it.
func (s *Store) SaveRefresh(principalID, provider, account string, version int64, secret, access []byte,
	expires *time.Time, at time.Time) error {
	res, err := s.write.Exec(`UPDATE fleet_credentials SET secret_sealed = ?, access_sealed = ?, access_expires_at = ?,
		version = version + 1, refreshed_at = ?, refresh_error = '', updated_at = ?
		WHERE principal_id = ? AND provider = ? AND account = ? AND version = ?`,
		secret, access, fmtTimePtr(expires), fmtTime(at), fmtTime(at), principalID, provider, account, version)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrCredConflict
	}
	return nil
}

// NoteRefreshError records why the last refresh failed, leaving the stored
// halves untouched.
func (s *Store) NoteRefreshError(principalID, provider, account, detail string, at time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_credentials SET refresh_error = ?, updated_at = ?
		WHERE principal_id = ? AND provider = ? AND account = ?`, detail, fmtTime(at), principalID, provider, account)
	return err
}

// AddCredAudit appends an audit row.
func (s *Store) AddCredAudit(a CredAudit) error {
	if a.At.IsZero() {
		a.At = time.Now()
	}
	_, err := s.write.Exec(`INSERT INTO fleet_cred_audit
		(at, action, principal_id, provider, account, hostname, os_user, endpoint_id, expires_at, detail)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		fmtTime(a.At), a.Action, a.PrincipalID, a.Provider, a.Account, a.Hostname, a.OSUser, a.EndpointID,
		fmtTimePtr(a.ExpiresAt), a.Detail)
	return err
}

// CredAuditLog returns the newest rows first; principalID "" means everyone's.
func (s *Store) CredAuditLog(principalID string, limit int) ([]CredAudit, error) {
	if limit <= 0 || limit > 1000 {
		limit = 200
	}
	q := `SELECT id, at, action, principal_id, provider, account, hostname, os_user, endpoint_id, expires_at, detail
		FROM fleet_cred_audit`
	args := []any{}
	if principalID != "" {
		q += ` WHERE principal_id = ?`
		args = append(args, principalID)
	}
	q += ` ORDER BY id DESC LIMIT ?`
	args = append(args, limit)
	rows, err := s.write.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []CredAudit{}
	for rows.Next() {
		var a CredAudit
		var at string
		var exp sql.NullString
		if err := rows.Scan(&a.ID, &at, &a.Action, &a.PrincipalID, &a.Provider, &a.Account, &a.Hostname,
			&a.OSUser, &a.EndpointID, &exp, &a.Detail); err != nil {
			return nil, err
		}
		a.At, _ = time.Parse(rfc, at)
		a.ExpiresAt = parseTimePtr(exp)
		out = append(out, a)
	}
	return out, rows.Err()
}

// Revoke records a revocation (idempotent; a repeat refreshes the reason).
func (s *Store) Revoke(hostname, principalID, reason string, at time.Time) error {
	if hostname == "" && principalID == "" {
		return errors.New("a revocation needs a hostname, a principal, or both")
	}
	_, err := s.write.Exec(`INSERT INTO fleet_cred_revocations (hostname, principal_id, revoked_at, reason)
		VALUES (?, ?, ?, ?) ON CONFLICT(hostname, principal_id) DO UPDATE SET revoked_at = excluded.revoked_at,
		reason = excluded.reason`, hostname, principalID, fmtTime(at), reason)
	return err
}

// Unrevoke lifts exactly the revocation named by (hostname, principalID).
func (s *Store) Unrevoke(hostname, principalID string) (bool, error) {
	res, err := s.write.Exec(`DELETE FROM fleet_cred_revocations WHERE hostname = ? AND principal_id = ?`,
		hostname, principalID)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// Revocations lists every revocation, newest first.
func (s *Store) Revocations() ([]CredRevocation, error) {
	rows, err := s.write.Query(`SELECT hostname, principal_id, revoked_at, reason FROM fleet_cred_revocations
		ORDER BY revoked_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []CredRevocation{}
	for rows.Next() {
		var r CredRevocation
		var at string
		if err := rows.Scan(&r.Hostname, &r.PrincipalID, &at, &r.Reason); err != nil {
			return nil, err
		}
		r.RevokedAt, _ = time.Parse(rfc, at)
		out = append(out, r)
	}
	return out, rows.Err()
}

// RevokedFor reports the revocation (if any) that stops principalID leasing
// on hostname: the node, the person, or the person on that node.
func (s *Store) RevokedFor(hostname, principalID string) (*CredRevocation, error) {
	var r CredRevocation
	var at string
	err := s.write.QueryRow(`SELECT hostname, principal_id, revoked_at, reason FROM fleet_cred_revocations
		WHERE (hostname = ? AND principal_id = '') OR (hostname = '' AND principal_id = ?)
		   OR (hostname = ? AND principal_id = ?)
		ORDER BY revoked_at DESC LIMIT 1`, hostname, principalID, hostname, principalID).
		Scan(&r.Hostname, &r.PrincipalID, &at, &r.Reason)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	r.RevokedAt, _ = time.Parse(rfc, at)
	return &r, nil
}

// PrincipalForLogin resolves the person whose ACTIVE fleet account is login on
// hostname — the only identity a node's lease is answered for.
func (s *Store) PrincipalForLogin(hostname, login string) (string, error) {
	var id string
	err := s.write.QueryRow(`SELECT principal_id FROM fleet_accounts WHERE hostname = ? AND login = ? AND state = ?`,
		hostname, login, AccountActive).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNoPrincipal
	}
	return id, err
}
