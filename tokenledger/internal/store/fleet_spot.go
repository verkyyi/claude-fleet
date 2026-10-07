package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"time"
)

// SPOT nodes (claude-fleet#1428, EPIC #1419 R1): execution nodes the hub
// itself starts in its cluster when every fixed machine is busy, and releases
// again when they have sat idle for a while.
//
// Two things are recorded here, and both are deliberately NOT the roster:
//
//   - A node's KIND — fixed (m5, m4: a machine someone owns) or ephemeral (a
//     container the hub created, on a SPOT instance the cloud may take back
//     at any moment). It lives on the endpoint, stamped from the join code the
//     hub minted for it, so the agent's own word never decides it: a fixed
//     machine cannot talk itself into the ephemeral weight, and a SPOT pod
//     cannot claim to be m5. fleet_join_codes.kind carries it until the code
//     is redeemed.
//   - The SPOT node's LIFE — fleet_spot_nodes: one row per node the hub
//     started, from the pod create through join, online, idle, release or
//     reclaim, to released. The roster row and the endpoint go when the node
//     does (a released SPOT box never comes back under that identity, so
//     listing it as 失联 forever would be noise); this row stays, because the
//     record of "起节点 → 派活 → 释放" is the issue's definition of done.
//
// Created only with the fleet module on (EnsureNodes), like every fleet table.
const fleetSpotSchema = `
CREATE TABLE IF NOT EXISTS fleet_spot_nodes (
  id               TEXT PRIMARY KEY,
  pod_name         TEXT NOT NULL,
  namespace        TEXT NOT NULL DEFAULT '',
  code_hash        TEXT NOT NULL,
  endpoint_id      TEXT,
  state            TEXT NOT NULL,
  reason           TEXT NOT NULL DEFAULT '',
  created_at       TEXT NOT NULL,
  joined_at        TEXT,
  last_busy_at     TEXT,
  released_at      TEXT,
  peak_sessions    INTEGER NOT NULL DEFAULT 0,
  leases_released  INTEGER NOT NULL DEFAULT 0,
  sessions_lost    INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS fleet_spot_nodes_state ON fleet_spot_nodes(state, created_at);`

// Node kinds.
const (
	NodeKindFixed     = "fixed"
	NodeKindEphemeral = "ephemeral"
)

// SPOT node states, in the order a node passes through them.
const (
	// SpotProvisioning: the pod is created; its agent has not reported yet.
	SpotProvisioning = "provisioning"
	// SpotOnline: the agent is on the control channel; placement may use it.
	SpotOnline = "online"
	// SpotReleasing: idle too long (or released by hand); the pod delete is
	// sent, and the row waits for the pod to be gone.
	SpotReleasing = "releasing"
	// SpotReclaiming: the node said the cloud is taking it back; placement
	// avoids it, its idle sessions move off, and the pod's end is awaited.
	SpotReclaiming = "reclaiming"
	// SpotReleased: gone. The roster row and endpoint are retired with it.
	SpotReleased = "released"
)

// SpotNode is one row of the SPOT ledger.
type SpotNode struct {
	ID         string     `json:"id"`
	PodName    string     `json:"pod_name"`
	Namespace  string     `json:"namespace,omitempty"`
	CodeHash   string     `json:"-"`
	EndpointID string     `json:"endpoint_id,omitempty"`
	State      string     `json:"state"`
	Reason     string     `json:"reason,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
	JoinedAt   *time.Time `json:"joined_at,omitempty"`
	LastBusyAt *time.Time `json:"last_busy_at,omitempty"`
	ReleasedAt *time.Time `json:"released_at,omitempty"`
	// PeakSessions is the most sessions a heartbeat ever reported on it —
	// "派活" in the record, without storing every beat.
	PeakSessions int `json:"peak_sessions"`
	// LeasesReleased counts the issue leases the hub let go when the node
	// went; SessionsLost the sessions its last heartbeat still listed —
	// the ones that could not be moved off in time (意外下线).
	LeasesReleased int `json:"leases_released"`
	SessionsLost   int `json:"sessions_lost"`
}

// Live reports whether the node is still the hub's to track.
func (n SpotNode) Live() bool { return n.State != SpotReleased }

func (s *Store) ensureFleetSpot() error {
	if _, err := s.write.Exec(s.d.ddl(fleetSpotSchema)); err != nil {
		return fmt.Errorf("create fleet_spot_nodes table: %w", err)
	}
	for _, c := range []struct{ table, column, spec string }{
		{"fleet_join_codes", "kind", "TEXT NOT NULL DEFAULT 'fixed'"},
		{"endpoints", "node_kind", "TEXT NOT NULL DEFAULT 'fixed'"},
		// The device a login-registered node belongs to (claude-fleet#2212):
		// the fingerprint of the `fleet login` key that asked, so the same
		// device is never enrolled twice. '' for every other code.
		{"fleet_join_codes", "device_fp", "TEXT NOT NULL DEFAULT ''"},
	} {
		if err := s.addColumn(c.table, c.column, c.spec); err != nil {
			return err
		}
	}
	return nil
}

// CreateJoinCodeKind stores a new code by its hash, for a node of the given
// kind. The kind is copied onto the endpoint the code enrolls.
func (s *Store) CreateJoinCodeKind(codeHash, label, kind string, now time.Time, ttl time.Duration) error {
	if kind == "" {
		kind = NodeKindFixed
	}
	_, err := s.write.Exec(`INSERT INTO fleet_join_codes (code_hash, label, kind, created_at, expires_at)
		VALUES (?, ?, ?, ?, ?)`, codeHash, label, kind, fmtTime(now), fmtTime(now.Add(ttl)))
	return err
}

// EndpointNodeKind is an endpoint's kind: fixed, or ephemeral for a node the
// hub started itself.
func (s *Store) EndpointNodeKind(endpointID string) (string, error) {
	var k string
	err := s.read.QueryRow(`SELECT node_kind FROM endpoints WHERE endpoint_id = ?`, endpointID).Scan(&k)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNoSuchEndpoint
	}
	if k == "" {
		k = NodeKindFixed
	}
	return k, err
}

// EphemeralEndpoints lists the endpoints whose kind is not fixed: endpoint id
// → kind. Small by construction, so the roster and placement read it once.
func (s *Store) EphemeralEndpoints() (map[string]string, error) {
	rows, err := s.read.Query(`SELECT endpoint_id, node_kind FROM endpoints WHERE node_kind <> ? AND node_kind <> ''`, NodeKindFixed)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var id, k string
		if err := rows.Scan(&id, &k); err != nil {
			return nil, err
		}
		out[id] = k
	}
	return out, rows.Err()
}

// CreateSpotNode records a node the hub just asked the cluster for.
func (s *Store) CreateSpotNode(n SpotNode) error {
	_, err := s.write.Exec(`INSERT INTO fleet_spot_nodes (id, pod_name, namespace, code_hash, state, reason, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`, n.ID, n.PodName, n.Namespace, n.CodeHash, SpotProvisioning, n.Reason, fmtTime(n.CreatedAt))
	return err
}

const spotCols = `id, pod_name, namespace, code_hash, endpoint_id, state, reason, created_at, joined_at,
	last_busy_at, released_at, peak_sessions, leases_released, sessions_lost`

func scanSpot(sc interface{ Scan(...any) error }) (SpotNode, error) {
	var n SpotNode
	var ep, joined, busy, released sql.NullString
	var created string
	if err := sc.Scan(&n.ID, &n.PodName, &n.Namespace, &n.CodeHash, &ep, &n.State, &n.Reason, &created,
		&joined, &busy, &released, &n.PeakSessions, &n.LeasesReleased, &n.SessionsLost); err != nil {
		return n, err
	}
	n.EndpointID = ep.String
	n.CreatedAt, _ = time.Parse(rfc, created)
	n.JoinedAt, n.LastBusyAt, n.ReleasedAt = parseNullTime(joined), parseNullTime(busy), parseNullTime(released)
	return n, nil
}

// SpotNodes lists the ledger: every live node, plus — when withReleased is
// set — the newest `history` released ones. Oldest first among the live.
func (s *Store) SpotNodes(withReleased bool, history int) ([]SpotNode, error) {
	q := `SELECT ` + spotCols + ` FROM fleet_spot_nodes WHERE state <> ? ORDER BY created_at`
	rows, err := s.read.Query(q, SpotReleased)
	if err != nil {
		return nil, err
	}
	out := []SpotNode{}
	for rows.Next() {
		n, err := scanSpot(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		out = append(out, n)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if !withReleased {
		return out, nil
	}
	if history <= 0 {
		history = 5
	}
	rows, err = s.read.Query(`SELECT `+spotCols+` FROM fleet_spot_nodes WHERE state = ?
		ORDER BY released_at DESC LIMIT `+strconv.Itoa(history), SpotReleased)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		n, err := scanSpot(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	return out, rows.Err()
}

// SpotNodeByID reads one node.
func (s *Store) SpotNodeByID(id string) (SpotNode, error) {
	return scanSpot(s.read.QueryRow(`SELECT `+spotCols+` FROM fleet_spot_nodes WHERE id = ?`, id))
}

// SpotNodeByEndpoint reads the live node an endpoint belongs to; sql.ErrNoRows
// when the endpoint is not a SPOT node the hub still tracks.
func (s *Store) SpotNodeByEndpoint(endpointID string) (SpotNode, error) {
	return scanSpot(s.read.QueryRow(`SELECT `+spotCols+` FROM fleet_spot_nodes
		WHERE endpoint_id = ? AND state <> ? ORDER BY created_at DESC LIMIT 1`, endpointID, SpotReleased))
}

// SetSpotNodeState moves a node to state, with a reason. A released node is
// never revived: the transition is refused (false) once released_at is set.
func (s *Store) SetSpotNodeState(id, state, reason string, at time.Time) (bool, error) {
	res, err := s.write.Exec(`UPDATE fleet_spot_nodes SET state = ?, reason = ? WHERE id = ? AND state <> ?`,
		state, reason, id, SpotReleased)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// SpotNodeOnline records the first heartbeat seen from the node's agent.
func (s *Store) SpotNodeOnline(id string, at time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_spot_nodes SET state = ?, joined_at = COALESCE(joined_at, ?), last_busy_at = COALESCE(last_busy_at, ?)
		WHERE id = ? AND state = ?`, SpotOnline, fmtTime(at), fmtTime(at), id, SpotProvisioning)
	return err
}

// SpotNodeBusy records a heartbeat that listed sessions on the node: the idle
// clock restarts, and the peak is kept for the record.
func (s *Store) SpotNodeBusy(endpointID string, sessions int, at time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_spot_nodes SET last_busy_at = ?, peak_sessions = `+s.d.greatest("peak_sessions", "?")+`
		WHERE endpoint_id = ? AND state <> ?`, fmtTime(at), sessions, endpointID, SpotReleased)
	return err
}

// SpotNodeReleased closes the record.
func (s *Store) SpotNodeReleased(id, reason string, leasesReleased, sessionsLost int, at time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_spot_nodes SET state = ?, reason = ?, released_at = ?,
		leases_released = ?, sessions_lost = ? WHERE id = ? AND state <> ?`,
		SpotReleased, reason, fmtTime(at), leasesReleased, sessionsLost, id, SpotReleased)
	return err
}

// DeleteNode drops an endpoint's roster row. Only a released SPOT node's: a
// fixed machine that stops reporting stays listed as lost (claude-fleet#1408).
func (s *Store) DeleteNode(endpointID string) error {
	_, err := s.write.Exec(`DELETE FROM nodes WHERE endpoint_id = ?`, endpointID)
	return err
}

// ReleaseLeasesOfEndpoint lets every lease an endpoint holds go, at once, and
// returns them. For a node the hub KNOWS is gone (a released SPOT box): the
// 30-minute lost TTL exists for a machine that may come back, and this one
// will not. Only released — nothing is re-dispatched, as for any lost node.
func (s *Store) ReleaseLeasesOfEndpoint(endpointID string) ([]Lease, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if err := s.d.claimWrites(tx, "fleet_leases"); err != nil {
		return nil, err
	}
	rows, err := tx.Query(`SELECT `+leaseCols+` FROM fleet_leases WHERE endpoint_id = ?`+s.d.forUpdate(), endpointID)
	if err != nil {
		return nil, err
	}
	var held []Lease
	for rows.Next() {
		l, err := scanLease(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		held = append(held, l)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(`DELETE FROM fleet_leases WHERE endpoint_id = ?`, endpointID); err != nil {
		return nil, err
	}
	return held, tx.Commit()
}
