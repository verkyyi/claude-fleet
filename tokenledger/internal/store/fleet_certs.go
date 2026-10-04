package store

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Issued SSH certificates (claude-fleet#1412) — the audit trail, not a
// credential store: the certificate itself is public material and the hub
// keeps only what it said and to whom. sshd logs the key id on every login;
// this table turns that id back into a person, a key and a moment.
//
// Created only with the fleet module on (EnsureNodes), like every fleet table.
const fleetCertsSchema = `
CREATE TABLE IF NOT EXISTS fleet_certs (
  serial          TEXT PRIMARY KEY,
  principal_id    TEXT NOT NULL,
  key_id          TEXT NOT NULL,
  principals      TEXT NOT NULL,
  key_fingerprint TEXT NOT NULL,
  via             TEXT NOT NULL,
  issued_at       TEXT NOT NULL,
  valid_after     TEXT NOT NULL,
  valid_before    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS fleet_certs_principal ON fleet_certs(principal_id, issued_at);`

// FleetCert is one issued certificate.
type FleetCert struct {
	Serial         string    `json:"serial"`
	PrincipalID    string    `json:"principal_id"`
	KeyID          string    `json:"key_id"`
	Principals     []string  `json:"principals"`
	KeyFingerprint string    `json:"key_fingerprint"`
	Via            string    `json:"via"` // device | web
	IssuedAt       time.Time `json:"issued_at"`
	ValidAfter     time.Time `json:"valid_after"`
	ValidBefore    time.Time `json:"valid_before"`
}

func (s *Store) ensureFleetCerts() error {
	if _, err := s.write.Exec(fleetCertsSchema); err != nil {
		return fmt.Errorf("create fleet_certs table: %w", err)
	}
	return nil
}

// RecordCert writes one issuance. A certificate whose issuance could not be
// recorded is never handed out: the caller refuses on error.
func (s *Store) RecordCert(c FleetCert) error {
	_, err := s.write.Exec(`INSERT INTO fleet_certs (serial, principal_id, key_id, principals,
		key_fingerprint, via, issued_at, valid_after, valid_before) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		c.Serial, c.PrincipalID, c.KeyID, strings.Join(c.Principals, ","), c.KeyFingerprint, c.Via,
		c.IssuedAt.UTC().Format(rfc), c.ValidAfter.UTC().Format(rfc), c.ValidBefore.UTC().Format(rfc))
	return err
}

// FleetCerts lists issuances, newest first; principalID "" means everyone's.
func (s *Store) FleetCerts(principalID string, limit int) ([]FleetCert, error) {
	if limit <= 0 {
		limit = 50
	}
	q := `SELECT serial, principal_id, key_id, principals, key_fingerprint, via, issued_at, valid_after, valid_before
		FROM fleet_certs`
	args := []any{}
	if principalID != "" {
		q += ` WHERE principal_id = ?`
		args = append(args, principalID)
	}
	q += ` ORDER BY issued_at DESC, serial LIMIT ` + strconv.Itoa(limit)
	rows, err := s.read.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []FleetCert{}
	for rows.Next() {
		var c FleetCert
		var ps, issued, after, before string
		if err := rows.Scan(&c.Serial, &c.PrincipalID, &c.KeyID, &ps, &c.KeyFingerprint, &c.Via,
			&issued, &after, &before); err != nil {
			return nil, err
		}
		c.Principals = strings.Split(ps, ",")
		c.IssuedAt, _ = time.Parse(rfc, issued)
		c.ValidAfter, _ = time.Parse(rfc, after)
		c.ValidBefore, _ = time.Parse(rfc, before)
		out = append(out, c)
	}
	return out, rows.Err()
}
