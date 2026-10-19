package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Who holds each node's control channel (claude-fleet#2124, EPIC #2119 C5).
//
// A node's websocket ends in ONE hub process, and only that process can write
// down it. With two hub replicas behind one address a node is connected to
// either, so a write that lands on the other one must be handed across. This
// table is how the other one finds out where: a replica writes its row when a
// node says hello and deletes it when that link ends.
//
// The row is keyed by endpoint and stamped with conn_epoch — a value minted per
// link — so a node that reconnected to the OTHER replica before the first one
// noticed its old link die is never deleted by that late drop: the delete
// matches (endpoint, replica, epoch), and the newer row carries another epoch.
//
// The table exists only on a hub started as a replica (CCQUOTA_REPLICA): a
// single hub never creates it, never writes it, and never reads it, so its
// database is exactly what it was before (EPIC #2119 共同约定 1). Its rows are
// live state, not history: C3's move between databases does not carry them, a
// replica clears its own at start, and every node's next hello rewrites its row.
const fleetNodeConnsSchema = `
CREATE TABLE IF NOT EXISTS fleet_node_conns (
  endpoint_id  TEXT PRIMARY KEY,
  replica      TEXT NOT NULL,
  url          TEXT NOT NULL,
  conn_epoch   TEXT NOT NULL,
  admin        INTEGER NOT NULL DEFAULT 0,
  caps         TEXT NOT NULL DEFAULT '',
  connected_at TEXT NOT NULL
);`

// NodeConn is one row: endpoint's channel ends in replica, reachable at url.
type NodeConn struct {
	EndpointID  string    `json:"endpoint_id"`
	Replica     string    `json:"replica"`
	URL         string    `json:"url"`
	Epoch       string    `json:"conn_epoch"`
	Admin       bool      `json:"admin"`
	Caps        []string  `json:"caps"`
	ConnectedAt time.Time `json:"connected_at"`
}

// HasCap reports whether the link's hello offered capability c.
func (c NodeConn) HasCap(want string) bool {
	for _, x := range c.Caps {
		if x == want {
			return true
		}
	}
	return false
}

// EnsureFleetNodeConns creates the table. Only a replica calls it.
func (s *Store) EnsureFleetNodeConns() error {
	if _, err := s.write.Exec(s.d.ddl(fleetNodeConnsSchema)); err != nil {
		return fmt.Errorf("create fleet_node_conns table: %w", err)
	}
	return nil
}

// ClaimNodeConn records that c.EndpointID's channel now ends in c.Replica. A
// row another replica wrote is replaced: the newest hello is the truth.
func (s *Store) ClaimNodeConn(c NodeConn) error {
	_, err := s.write.Exec(`
		INSERT INTO fleet_node_conns (endpoint_id, replica, url, conn_epoch, admin, caps, connected_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(endpoint_id) DO UPDATE SET
		  replica = excluded.replica, url = excluded.url, conn_epoch = excluded.conn_epoch,
		  admin = excluded.admin, caps = excluded.caps, connected_at = excluded.connected_at`,
		c.EndpointID, c.Replica, c.URL, c.Epoch, c.Admin, strings.Join(c.Caps, ","),
		c.ConnectedAt.UTC().Format(rfc))
	return err
}

// ReleaseNodeConn deletes endpointID's row only while it is still the link
// (replica, epoch) wrote: a newer link's row stays.
func (s *Store) ReleaseNodeConn(endpointID, replica, epoch string) error {
	_, err := s.write.Exec(`DELETE FROM fleet_node_conns WHERE endpoint_id = ? AND replica = ? AND conn_epoch = ?`,
		endpointID, replica, epoch)
	return err
}

// ReleaseReplicaConns deletes every row replica wrote — at its start, when no
// link of its previous life can still be open.
func (s *Store) ReleaseReplicaConns(replica string) (int64, error) {
	res, err := s.write.Exec(`DELETE FROM fleet_node_conns WHERE replica = ?`, replica)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// NodeConnOf is endpointID's row; ok is false when no replica holds it.
func (s *Store) NodeConnOf(endpointID string) (NodeConn, bool, error) {
	row := s.read.QueryRow(`SELECT endpoint_id, replica, url, conn_epoch, admin, caps, connected_at
		  FROM fleet_node_conns WHERE endpoint_id = ?`, endpointID)
	c, err := scanNodeConn(row)
	if errors.Is(err, sql.ErrNoRows) {
		return NodeConn{}, false, nil
	}
	if err != nil {
		return NodeConn{}, false, err
	}
	return c, true, nil
}

// NodeConns is every row, by endpoint.
func (s *Store) NodeConns() ([]NodeConn, error) {
	rows, err := s.read.Query(`SELECT endpoint_id, replica, url, conn_epoch, admin, caps, connected_at
		  FROM fleet_node_conns ORDER BY endpoint_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []NodeConn{}
	for rows.Next() {
		c, err := scanNodeConn(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func scanNodeConn(r interface{ Scan(...any) error }) (NodeConn, error) {
	var c NodeConn
	var admin int
	var caps, at string
	if err := r.Scan(&c.EndpointID, &c.Replica, &c.URL, &c.Epoch, &admin, &caps, &at); err != nil {
		return NodeConn{}, err
	}
	c.Admin = admin != 0
	c.Caps = []string{}
	if caps != "" {
		c.Caps = strings.Split(caps, ",")
	}
	c.ConnectedAt, _ = time.Parse(rfc, at)
	return c, nil
}
