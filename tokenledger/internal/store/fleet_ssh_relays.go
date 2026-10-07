package store

import (
	"database/sql"
	"fmt"
	"time"
)

// The relay audit (claude-fleet#1413): one row per SSH connection the hub
// carried — who, to which machine, through which login's agent, for how long,
// and how many bytes each way. Written when the relay is admitted and again
// when it ends, so a hub that dies mid-relay leaves a row with no end rather
// than no row; the byte counts are what outbound bandwidth is billed on.
//
// Created with the rest of the fleet tables by EnsureNodes, never by
// schema.sql: a hub with the module off keeps its database as it was.
const fleetSSHRelaysSchema = `
CREATE TABLE IF NOT EXISTS fleet_ssh_relays (
  id          TEXT PRIMARY KEY,
  actor       TEXT NOT NULL DEFAULT '',
  hostname    TEXT NOT NULL DEFAULT '',
  endpoint_id TEXT NOT NULL DEFAULT '',
  os_user     TEXT NOT NULL DEFAULT '',
  started_at  TEXT NOT NULL,
  ended_at    TEXT,
  bytes_up    INTEGER NOT NULL DEFAULT 0,
  bytes_down  INTEGER NOT NULL DEFAULT 0,
  outcome     TEXT NOT NULL DEFAULT 'open',
  detail      TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS fleet_ssh_relays_started ON fleet_ssh_relays(started_at);`

// SSHRelay is one audited SSH relay.
type SSHRelay struct {
	ID         string     `json:"id"`
	Actor      string     `json:"actor"`
	Hostname   string     `json:"hostname"`
	EndpointID string     `json:"endpoint_id"`
	OSUser     string     `json:"os_user"`
	StartedAt  time.Time  `json:"started_at"`
	EndedAt    *time.Time `json:"ended_at"`
	BytesUp    int64      `json:"bytes_up"`
	BytesDown  int64      `json:"bytes_down"`
	// Outcome is open while it runs, then closed, or refused/failed with
	// Detail saying why.
	Outcome string `json:"outcome"`
	Detail  string `json:"detail,omitempty"`
}

func (s *Store) ensureFleetSSHRelays() error {
	if _, err := s.write.Exec(s.d.ddl(fleetSSHRelaysSchema)); err != nil {
		return fmt.Errorf("create fleet relay table: %w", err)
	}
	// A restarted hub carries no relay: whatever was open ended with it.
	_, err := s.write.Exec(`UPDATE fleet_ssh_relays SET outcome = 'closed', ended_at = ?,
		detail = 'hub restarted' WHERE ended_at IS NULL`, time.Now().UTC().Format(rfc))
	return err
}

// SSHRelayStarted records an admitted relay.
func (s *Store) SSHRelayStarted(r SSHRelay) error {
	_, err := s.write.Exec(`INSERT INTO fleet_ssh_relays
		(id, actor, hostname, endpoint_id, os_user, started_at, outcome, detail)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		r.ID, r.Actor, r.Hostname, r.EndpointID, r.OSUser, r.StartedAt.UTC().Format(rfc), r.Outcome, r.Detail)
	return err
}

// SSHRelayEnded closes a relay's row with its totals.
func (s *Store) SSHRelayEnded(id, outcome, detail string, up, down int64, at time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_ssh_relays SET ended_at = ?, outcome = ?, detail = ?,
		bytes_up = ?, bytes_down = ? WHERE id = ?`,
		at.UTC().Format(rfc), outcome, detail, up, down, id)
	return err
}

// SSHRelays lists the newest relays first, at most limit of them.
func (s *Store) SSHRelays(limit int) ([]SSHRelay, error) {
	rows, err := s.read.Query(`SELECT id, actor, hostname, endpoint_id, os_user, started_at,
		ended_at, bytes_up, bytes_down, outcome, detail
		FROM fleet_ssh_relays ORDER BY started_at DESC, id LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []SSHRelay{}
	for rows.Next() {
		var r SSHRelay
		var started string
		var ended sql.NullString
		if err := rows.Scan(&r.ID, &r.Actor, &r.Hostname, &r.EndpointID, &r.OSUser, &started,
			&ended, &r.BytesUp, &r.BytesDown, &r.Outcome, &r.Detail); err != nil {
			return nil, err
		}
		r.StartedAt, _ = time.Parse(rfc, started)
		r.EndedAt = parseNullTime(ended)
		out = append(out, r)
	}
	return out, rows.Err()
}
