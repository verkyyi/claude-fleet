package store

import (
	"fmt"
	"strconv"
	"time"
)

// Machine-to-machine certificates (claude-fleet#1626) — the audit trail of
// every cross-machine login the hub let happen. A node asks for "<target>,
// for <purpose>" with its own enrollment token; the hub signs a five-minute
// certificate and writes the row here BEFORE handing it out, so a
// certificate the hub cannot account for is never issued. sshd on the target
// logs the key id ("peer:<source>><target>:<purpose>"); this table turns it
// back into an endpoint, a login and a moment.
//
// Created only with the fleet module on (EnsureNodes), like every fleet table.
const fleetPeerCertsSchema = `
CREATE TABLE IF NOT EXISTS fleet_peer_certs (
  serial           TEXT PRIMARY KEY,
  source_endpoint  TEXT NOT NULL,
  source_host      TEXT NOT NULL,
  source_user      TEXT NOT NULL,
  target_endpoint  TEXT NOT NULL,
  target_host      TEXT NOT NULL,
  login            TEXT NOT NULL,
  purpose          TEXT NOT NULL,
  key_id           TEXT NOT NULL,
  key_fingerprint  TEXT NOT NULL,
  issued_at        TEXT NOT NULL,
  valid_before     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS fleet_peer_certs_issued ON fleet_peer_certs(issued_at);`

// FleetPeerCert is one issued machine-to-machine certificate.
type FleetPeerCert struct {
	Serial         string    `json:"serial"`
	SourceEndpoint string    `json:"source_endpoint"`
	SourceHost     string    `json:"source_host"`
	SourceUser     string    `json:"source_user"`
	TargetEndpoint string    `json:"target_endpoint"`
	TargetHost     string    `json:"target_host"`
	Login          string    `json:"login"`
	Purpose        string    `json:"purpose"`
	KeyID          string    `json:"key_id"`
	KeyFingerprint string    `json:"key_fingerprint"`
	IssuedAt       time.Time `json:"issued_at"`
	ValidBefore    time.Time `json:"valid_before"`
}

func (s *Store) ensureFleetPeerCerts() error {
	if _, err := s.write.Exec(fleetPeerCertsSchema); err != nil {
		return fmt.Errorf("create fleet_peer_certs table: %w", err)
	}
	return nil
}

// RecordPeerCert writes one issuance. The caller refuses on error.
func (s *Store) RecordPeerCert(c FleetPeerCert) error {
	_, err := s.write.Exec(`INSERT INTO fleet_peer_certs (serial, source_endpoint, source_host,
		source_user, target_endpoint, target_host, login, purpose, key_id, key_fingerprint,
		issued_at, valid_before) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		c.Serial, c.SourceEndpoint, c.SourceHost, c.SourceUser, c.TargetEndpoint, c.TargetHost,
		c.Login, c.Purpose, c.KeyID, c.KeyFingerprint,
		c.IssuedAt.UTC().Format(rfc), c.ValidBefore.UTC().Format(rfc))
	return err
}

// FleetPeerCerts lists issuances, newest first.
func (s *Store) FleetPeerCerts(limit int) ([]FleetPeerCert, error) {
	if limit <= 0 {
		limit = 50
	}
	rows, err := s.read.Query(`SELECT serial, source_endpoint, source_host, source_user,
		target_endpoint, target_host, login, purpose, key_id, key_fingerprint, issued_at, valid_before
		FROM fleet_peer_certs ORDER BY issued_at DESC, serial LIMIT ` + strconv.Itoa(limit))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []FleetPeerCert{}
	for rows.Next() {
		var c FleetPeerCert
		var issued, before string
		if err := rows.Scan(&c.Serial, &c.SourceEndpoint, &c.SourceHost, &c.SourceUser,
			&c.TargetEndpoint, &c.TargetHost, &c.Login, &c.Purpose, &c.KeyID, &c.KeyFingerprint,
			&issued, &before); err != nil {
			return nil, err
		}
		c.IssuedAt, _ = time.Parse(rfc, issued)
		c.ValidBefore, _ = time.Parse(rfc, before)
		out = append(out, c)
	}
	return out, rows.Err()
}
