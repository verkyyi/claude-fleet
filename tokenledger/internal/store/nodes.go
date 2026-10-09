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

// EnsureNodes creates the node roster, the fleet registry (claude-fleet#1409),
// the principal/account tables (claude-fleet#1411), the certificate audit
// (claude-fleet#1412), the credential vault (claude-fleet#1415), the issue
// leases (claude-fleet#1422) and the relay audit (claude-fleet#1413). Idempotent.
func (s *Store) EnsureNodes() error {
	if _, err := s.write.Exec(s.d.ddl(nodesSchema)); err != nil {
		return fmt.Errorf("create nodes table: %w", err)
	}
	// The Fleet Hub registry rides the same switch (claude-fleet#1409).
	if _, err := s.write.Exec(s.d.ddl(fleetSchema)); err != nil {
		return fmt.Errorf("create fleet registry tables: %w", err)
	}
	if err := s.ensureFleetColumns(); err != nil {
		return err
	}
	if err := s.ensureFleetRelays(); err != nil {
		return err
	}
	if err := s.ensureFleetAccounts(); err != nil {
		return err
	}
	if err := s.ensureFleetCerts(); err != nil {
		return err
	}
	// Machine-to-machine certificates (claude-fleet#1626).
	if err := s.ensureFleetPeerCerts(); err != nil {
		return err
	}
	// The team configuration layer (claude-fleet#1726).
	if err := s.ensureFleetTeamBundles(); err != nil {
		return err
	}
	// Each person's own configuration layer (claude-fleet#1856).
	if err := s.ensureFleetPersonBundles(); err != nil {
		return err
	}
	// What a worker on another machine left behind (claude-fleet#1609).
	if err := s.ensureFleetWorkerRecords(); err != nil {
		return err
	}
	// One progress stream per parent (claude-fleet#1648).
	if err := s.ensureFleetProgress(); err != nil {
		return err
	}
	// Registered devices + their audit (claude-fleet#1470).
	if err := s.ensureFleetDevices(); err != nil {
		return err
	}
	// Drill people (claude-fleet#2010) — after the devices they own.
	if err := s.ensureFleetDrill(); err != nil {
		return err
	}
	if err := s.ensureFleetCreds(); err != nil {
		return err
	}
	// Session passes for untrusted machines (claude-fleet#1969).
	if err := s.ensureFleetSessionCreds(); err != nil {
		return err
	}
	// Their account bindings, for the cluster credential proxy (claude-fleet#1973).
	if err := s.ensureFleetSessionBinds(); err != nil {
		return err
	}
	// Each person's current home session (claude-fleet#2564).
	if err := s.ensureFleetHomeCurrent(); err != nil {
		return err
	}
	// Per-person usage against a person's budget (claude-fleet#1977).
	if err := s.ensureFleetPersonUsage(); err != nil {
		return err
	}
	// The vault's KMS-wrapped data key (claude-fleet#1417).
	if err := s.ensureFleetCredKey(); err != nil {
		return err
	}
	// Session moves through the hub (claude-fleet#1426).
	if err := s.ensureFleetMoves(); err != nil {
		return err
	}
	// Writing-area attachments in transit (claude-fleet#2393).
	if err := s.ensureFleetAttachments(); err != nil {
		return err
	}
	// Issue leases (claude-fleet#1422).
	if err := s.ensureFleetLeases(); err != nil {
		return err
	}
	// Join codes (claude-fleet#1418).
	if err := s.ensureFleetJoin(); err != nil {
		return err
	}
	// SPOT nodes and node kinds (claude-fleet#1428) — after the join codes,
	// whose table it widens.
	if err := s.ensureFleetSpot(); err != nil {
		return err
	}
	// Trust on the endpoint, join codes that carry it, and each machine's
	// desired state (claude-fleet#2214) — after the join codes, too.
	if err := s.ensureFleetIdentity(); err != nil {
		return err
	}
	// Node-lost / lease-conflict alerts (claude-fleet#1630).
	if err := s.ensureFleetAlerts(); err != nil {
		return err
	}
	// The relay audit (claude-fleet#1413).
	return s.ensureFleetSSHRelays()
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
	// An endpoint enrolled with no machine name (`ccquota enroll`, the
	// operator's) enrolls under the first one it reports (claude-fleet#2214);
	// a join always names one, and a stamped name is never moved.
	if hostname != "" {
		if _, err := s.write.Exec(`UPDATE endpoints SET enrolled_host = ? WHERE endpoint_id = ? AND enrolled_host = ''`,
			hostname, endpointID); err != nil {
			return fmt.Errorf("stamp enrolled host: %w", err)
		}
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
