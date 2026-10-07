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
  kind             TEXT NOT NULL DEFAULT '',
  secret_expires_at TEXT,
  reauth_required_at TEXT,
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
	// CredUpstreamRejected: a node reported that the upstream refused the
	// access token it was leased (claude-fleet#2007); the hub dropped its
	// cached copy. Detail names the code (token_revoked, …) and who said so.
	CredUpstreamRejected = "upstream_rejected"
	// CredReauth: the provider refused the stored refresh token itself
	// (invalid_grant and kin) — nothing more is leased from this account
	// until the operator logs in again and stores the new one.
	CredReauth = "reauth_required"
	// CredBind: the operator recorded which usage account an existing
	// credential belongs to (claude-fleet#2169) — no secret changed hands.
	// Detail names the account_uuid, never anything sealed.
	CredBind = "bind"
)

// PoolPrincipal is the principal_id of a SHARED-POOL credential
// (claude-fleet#1463): an account that belongs to the machine's pool rather
// than to one person (docs/SHARED-MACHINE.md 2b). A node's lease is answered
// with its own person's rows AND every pool row — still only for a login that
// IS some active principal, and still subject to that person's / machine's
// revocation. It is a sentinel, never a row in fleet_principals
// (insertPrincipal refuses it).
const PoolPrincipal = "pool"

// Credential is one stored (principal, provider, account) row. The sealed
// blobs are opaque here. Kind and SecretExpiresAt are metadata about the
// long-lived half (credvault.Kind*): "" on a row from before the column means
// the provider's original kind (refresh_token; token for github).
type Credential struct {
	PrincipalID     string     `json:"principal_id"`
	Provider        string     `json:"provider"`
	Account         string     `json:"account"`
	Kind            string     `json:"kind,omitempty"`
	SecretExpiresAt *time.Time `json:"secret_expires_at,omitempty"`
	SecretSealed    []byte     `json:"-"`
	AccessSealed    []byte     `json:"-"`
	AccessExpiresAt *time.Time `json:"access_expires_at,omitempty"`
	Version         int64      `json:"version"`
	RefreshedAt     *time.Time `json:"refreshed_at,omitempty"`
	RefreshError    string     `json:"refresh_error,omitempty"`
	// ReauthRequiredAt: since when the provider has refused this account's
	// refresh token (claude-fleet#2007). Set, nothing is refreshed or
	// leased from the row until a put replaces the secret; ReauthRequired
	// is the same fact as the status word the pages and the agent read.
	ReauthRequiredAt *time.Time `json:"reauth_required_at,omitempty"`
	ReauthRequired   bool       `json:"reauth_required,omitempty"`
	CreatedAt        time.Time  `json:"created_at"`
	UpdatedAt        time.Time  `json:"updated_at"`
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
	if _, err := s.write.Exec(s.d.ddl(fleetCredsSchema)); err != nil {
		return fmt.Errorf("create fleet credential tables: %w", err)
	}
	// Columns added after the table shipped (claude-fleet#1463): a hub whose
	// table predates them gets them here, with every existing row reading as
	// the provider's original kind.
	for _, c := range []struct{ column, spec string }{
		{"kind", "TEXT NOT NULL DEFAULT ''"},
		{"secret_expires_at", "TEXT"},
		{"reauth_required_at", "TEXT"}, // claude-fleet#2007
	} {
		if err := s.addColumn("fleet_credentials", c.column, c.spec); err != nil {
			return err
		}
	}
	return nil
}

const credColumns = `SELECT principal_id, provider, account, secret_sealed, access_sealed, access_expires_at,
	version, refreshed_at, refresh_error, created_at, updated_at, kind, secret_expires_at, reauth_required_at FROM fleet_credentials`

func scanCred(sc interface{ Scan(...any) error }) (Credential, error) {
	var c Credential
	var exp, ref, sexp, reauth sql.NullString
	var created, updated string
	if err := sc.Scan(&c.PrincipalID, &c.Provider, &c.Account, &c.SecretSealed, &c.AccessSealed, &exp,
		&c.Version, &ref, &c.RefreshError, &created, &updated, &c.Kind, &sexp, &reauth); err != nil {
		return c, err
	}
	c.ReauthRequiredAt = parseTimePtr(reauth)
	c.ReauthRequired = c.ReauthRequiredAt != nil
	c.AccessExpiresAt = parseTimePtr(exp)
	c.RefreshedAt = parseTimePtr(ref)
	c.SecretExpiresAt = parseTimePtr(sexp)
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

// PutCredential stores (or replaces) a credential's long-lived half, with its
// kind and — for a kind that runs out on its own (a setup token) — when. Any
// cached short-lived half is dropped: it was minted from the old secret.
func (s *Store) PutCredential(principalID, provider, account string, secret []byte, kind string, secretExpires *time.Time, at time.Time) error {
	now := fmtTime(at)
	_, err := s.write.Exec(`INSERT INTO fleet_credentials
		(principal_id, provider, account, secret_sealed, access_sealed, access_expires_at, version, refresh_error, created_at, updated_at, kind, secret_expires_at)
		VALUES (?, ?, ?, ?, NULL, NULL, 1, '', ?, ?, ?, ?)
		ON CONFLICT(principal_id, provider, account) DO UPDATE SET
		  secret_sealed = excluded.secret_sealed, access_sealed = NULL, access_expires_at = NULL,
		  version = fleet_credentials.version + 1, refresh_error = '', reauth_required_at = NULL, updated_at = excluded.updated_at,
		  kind = excluded.kind, secret_expires_at = excluded.secret_expires_at`,
		principalID, provider, account, secret, now, now, kind, fmtTimePtr(secretExpires))
	return err
}

// RewriteSecret replaces a credential's sealed long-lived half in place —
// only while the row is still at version, and leaving version, the cached
// access and every other column as they were: the secret it seals is the
// same token with a field added (claude-fleet#2169's account_uuid), not a new
// credential. ErrNoCredential when the row moved on or is gone.
func (s *Store) RewriteSecret(principalID, provider, account string, version int64, secret []byte, at time.Time) error {
	res, err := s.write.Exec(`UPDATE fleet_credentials SET secret_sealed = ?, updated_at = ?
		WHERE principal_id = ? AND provider = ? AND account = ? AND version = ?`,
		secret, fmtTime(at), principalID, provider, account, version)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNoCredential
	}
	return nil
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
		version = version + 1, refreshed_at = ?, refresh_error = '', reauth_required_at = NULL, updated_at = ?
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

// DropAccess forgets the cached short-lived half — the upstream refused it
// (claude-fleet#2007) — so the next lease refreshes instead of handing it out
// again. Only a row still at version: a refresh that landed meanwhile already
// replaced what was refused.
func (s *Store) DropAccess(principalID, provider, account string, version int64, at time.Time) error {
	res, err := s.write.Exec(`UPDATE fleet_credentials SET access_sealed = NULL, access_expires_at = NULL, updated_at = ?
		WHERE principal_id = ? AND provider = ? AND account = ? AND version = ?`,
		fmtTime(at), principalID, provider, account, version)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrCredConflict
	}
	return nil
}

// MarkReauthRequired records that the provider refused the stored refresh
// token itself: the account needs a new login. The cached access is dropped
// with it only when dropAccess (it was refused too); detail is the refusal.
func (s *Store) MarkReauthRequired(principalID, provider, account, detail string, dropAccess bool, at time.Time) error {
	q := `UPDATE fleet_credentials SET reauth_required_at = ?, refresh_error = ?, updated_at = ?`
	if dropAccess {
		q += `, access_sealed = NULL, access_expires_at = NULL`
	}
	_, err := s.write.Exec(q+` WHERE principal_id = ? AND provider = ? AND account = ?`,
		fmtTime(at), detail, fmtTime(at), principalID, provider, account)
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
