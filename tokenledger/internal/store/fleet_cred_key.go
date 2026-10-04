package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// The vault's data key, wrapped by KMS (claude-fleet#1417).
//
// Envelope encryption: the key that seals fleet_credentials is itself stored
// here — but only as KMS ciphertext. Opening it takes a KMS Decrypt call made
// with the hub's cloud identity, so the database and every k8s Secret taken
// together still open nothing. One row: the hub has one data key.
const fleetCredKeySchema = `
CREATE TABLE IF NOT EXISTS fleet_cred_key (
  id          INTEGER PRIMARY KEY CHECK (id = 1),
  kms_key_id  TEXT NOT NULL,
  wrapped     TEXT NOT NULL,
  created_at  TEXT NOT NULL,
  rewrapped_at TEXT
);`

// CredUnlock is the audit action for the vault's key being unwrapped (or
// failing to be): one row per attempt outcome, carrying the KMS request id.
const CredUnlock = "unlock"

// VaultKey is the wrapped data key. KMSKeyID is the master key it was wrapped
// under, as the hub was configured to name it (an id or an alias).
type VaultKey struct {
	KMSKeyID    string
	Wrapped     string // KMS CiphertextBlob
	CreatedAt   time.Time
	RewrappedAt *time.Time
}

// ErrNoVaultKey is returned before the first KMS-mode start has wrapped a key.
var ErrNoVaultKey = errors.New("no wrapped vault key yet")

func (s *Store) ensureFleetCredKey() error {
	if _, err := s.write.Exec(fleetCredKeySchema); err != nil {
		return fmt.Errorf("create fleet credential key table: %w", err)
	}
	return nil
}

// VaultKey reads the wrapped data key.
func (s *Store) VaultKey() (*VaultKey, error) {
	var k VaultKey
	var created string
	var rewrapped sql.NullString
	err := s.write.QueryRow(`SELECT kms_key_id, wrapped, created_at, rewrapped_at FROM fleet_cred_key WHERE id = 1`).
		Scan(&k.KMSKeyID, &k.Wrapped, &created, &rewrapped)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNoVaultKey
	}
	if err != nil {
		return nil, err
	}
	k.CreatedAt, _ = time.Parse(rfc, created)
	k.RewrappedAt = parseTimePtr(rewrapped)
	return &k, nil
}

// RewrapVaultKey replaces the wrapping (the same data key under another
// master key). The data it seals is untouched.
func (s *Store) RewrapVaultKey(kmsKeyID, wrapped string, at time.Time) error {
	res, err := s.write.Exec(`UPDATE fleet_cred_key SET kms_key_id = ?, wrapped = ?, rewrapped_at = ? WHERE id = 1`,
		kmsKeyID, wrapped, fmtTime(at))
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNoVaultKey
	}
	return nil
}

// InstallVaultKey stores the first wrapped key, re-sealing every existing
// credential row through reseal in the SAME transaction — so a crash leaves
// either the old key's rows and no key row, or the new key's rows and its
// key row, never a mix. reseal gets each row's sealed halves and returns them
// sealed anew (access may be nil). A key row already present is an error: the
// data key is installed once.
func (s *Store) InstallVaultKey(k VaultKey, reseal func(c Credential) (secret, access []byte, err error)) (int, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	var n int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM fleet_cred_key`).Scan(&n); err != nil {
		return 0, err
	}
	if n > 0 {
		return 0, errors.New("a vault key is already installed")
	}
	rows, err := tx.Query(credColumns)
	if err != nil {
		return 0, err
	}
	var creds []Credential
	for rows.Next() {
		c, err := scanCred(rows)
		if err != nil {
			rows.Close()
			return 0, err
		}
		creds = append(creds, c)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}
	if len(creds) > 0 && reseal == nil {
		return 0, fmt.Errorf("%d credential(s) are sealed under a key this hub was not given", len(creds))
	}
	for _, c := range creds {
		secret, access, err := reseal(c)
		if err != nil {
			return 0, fmt.Errorf("re-seal %s/%s/%s: %w", c.PrincipalID, c.Provider, c.Account, err)
		}
		if _, err := tx.Exec(`UPDATE fleet_credentials SET secret_sealed = ?, access_sealed = ?
			WHERE principal_id = ? AND provider = ? AND account = ?`,
			secret, access, c.PrincipalID, c.Provider, c.Account); err != nil {
			return 0, err
		}
	}
	if _, err := tx.Exec(`INSERT INTO fleet_cred_key (id, kms_key_id, wrapped, created_at) VALUES (1, ?, ?, ?)`,
		k.KMSKeyID, k.Wrapped, fmtTime(k.CreatedAt)); err != nil {
		return 0, err
	}
	return len(creds), tx.Commit()
}
