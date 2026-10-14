package store

import (
	"database/sql"
	"errors"
	"time"
)

// CredentialQuotaRead persists the last attempt separately from successful
// snapshots, so a restart cannot hide a failed read or erase its last good data.
type CredentialQuotaRead struct {
	At    time.Time `json:"at"`
	Error string    `json:"error,omitempty"`
}

func (s *Store) SaveCredentialQuotaRead(id string, at time.Time, note string) error {
	_, err := s.write.Exec(`INSERT INTO fleet_credential_quota (credential_id, at, error)
	VALUES (?, ?, ?) ON CONFLICT(credential_id) DO UPDATE SET at=excluded.at, error=excluded.error
	WHERE excluded.at >= fleet_credential_quota.at`, id, fmtTime(at), note)
	return err
}

func (s *Store) CredentialQuotaRead(id string) (*CredentialQuotaRead, error) {
	var at, note string
	err := s.read.QueryRow(`SELECT at, error FROM fleet_credential_quota WHERE credential_id=?`, id).Scan(&at, &note)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	t, err := time.Parse(time.RFC3339Nano, at)
	return &CredentialQuotaRead{At: t, Error: note}, err
}
