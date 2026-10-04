package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// The node roster of the fleet control channel (claude-fleet#1408): one row per
// agent connection, i.e. per (machine, login) endpoint, with its newest
// heartbeat.
//
// The table is created by EnsureNodes, never by schema.sql, because the whole
// fleet module is opt-in (CCQUOTA_FLEET=1): a hub that has not turned it on must
// leave its database exactly as it was. CREATE TABLE IF NOT EXISTS makes the
// call forward-compatible — a later version adds columns through the same
// migrate-style ALTERs, never by recreating the table.
const nodesSchema = `
CREATE TABLE IF NOT EXISTS nodes (
  endpoint_id    TEXT PRIMARY KEY REFERENCES endpoints(endpoint_id),
  hostname       TEXT NOT NULL DEFAULT '',
  os_user        TEXT NOT NULL DEFAULT '',
  machine_id     TEXT NOT NULL DEFAULT '',
  proto          INTEGER NOT NULL DEFAULT 0,
  heartbeat_ms  INTEGER NOT NULL DEFAULT 0,
  agent_version  TEXT NOT NULL DEFAULT '',
  connected_at   TEXT,
  last_heartbeat TEXT,
  status_json    TEXT NOT NULL DEFAULT '{}'
);`

// Node is one row of the roster.
type Node struct {
	EndpointID    string     `json:"endpoint_id"`
	Hostname      string     `json:"hostname"`
	OSUser        string     `json:"os_user"`
	MachineID     string     `json:"machine_id"`
	Proto         int        `json:"proto"`
	HeartbeatMS   int        `json:"heartbeat_ms"`
	AgentVersion  string     `json:"agent_version"`
	ConnectedAt   *time.Time `json:"connected_at"`
	LastHeartbeat *time.Time `json:"last_heartbeat"`
	// StatusJSON is the newest heartbeat payload, verbatim.
	StatusJSON string `json:"-"`
}

// EnsureNodes creates the node roster and the principal/account tables
// (claude-fleet#1411). Idempotent.
func (s *Store) EnsureNodes() error {
	if _, err := s.write.Exec(nodesSchema); err != nil {
		return fmt.Errorf("create nodes table: %w", err)
	}
	return s.ensureFleetAccounts()
}

// NodeConnected records that endpointID opened a control channel speaking
// proto, and will send a heartbeat every heartbeatMS milliseconds.
//
// last_heartbeat is set too: a node that has just said hello is alive by
// definition, and leaving it NULL would show a fresh connection as lost until
// its first heartbeat lands.
func (s *Store) NodeConnected(endpointID, hostname, osUser, agentVersion string, proto, heartbeatMS int, at time.Time) error {
	ts := at.UTC().Format(rfc)
	_, err := s.write.Exec(`
		INSERT INTO nodes (endpoint_id, hostname, os_user, proto, heartbeat_ms, agent_version, connected_at, last_heartbeat)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(endpoint_id) DO UPDATE SET
		  hostname = excluded.hostname, os_user = excluded.os_user,
		  proto = excluded.proto, heartbeat_ms = excluded.heartbeat_ms,
		  agent_version = excluded.agent_version,
		  connected_at = excluded.connected_at, last_heartbeat = excluded.last_heartbeat`,
		endpointID, hostname, osUser, proto, heartbeatMS, agentVersion, ts, ts)
	return err
}

// NodeHeartbeat stores a heartbeat. The row must exist (NodeConnected first):
// a heartbeat with no hello is refused rather than inventing a node whose
// protocol version nobody stated.
func (s *Store) NodeHeartbeat(endpointID, hostname, osUser, machineID string, proto int, statusJSON string, at time.Time) error {
	res, err := s.write.Exec(`
		UPDATE nodes SET hostname = ?, os_user = ?, machine_id = ?, proto = ?,
		       status_json = ?, last_heartbeat = ?
		 WHERE endpoint_id = ?`,
		hostname, osUser, machineID, proto, statusJSON, at.UTC().Format(rfc), endpointID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return errors.New("heartbeat from a node that never said hello")
	}
	return nil
}

// Nodes lists the roster, by hostname then login. Lost nodes are listed too:
// a lost node is reported as lost, never dropped and never read as idle.
func (s *Store) Nodes() ([]Node, error) {
	rows, err := s.read.Query(`
		SELECT endpoint_id, hostname, os_user, machine_id, proto, heartbeat_ms,
		       agent_version, connected_at, last_heartbeat, status_json
		  FROM nodes ORDER BY hostname, os_user, endpoint_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Node{}
	for rows.Next() {
		var n Node
		var conn, last sql.NullString
		if err := rows.Scan(&n.EndpointID, &n.Hostname, &n.OSUser, &n.MachineID, &n.Proto,
			&n.HeartbeatMS, &n.AgentVersion, &conn, &last, &n.StatusJSON); err != nil {
			return nil, err
		}
		n.ConnectedAt = parseNullTime(conn)
		n.LastHeartbeat = parseNullTime(last)
		out = append(out, n)
	}
	return out, rows.Err()
}
