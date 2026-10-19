package store

import "time"

// Node kinds. Only fixed is minted since the SPOT nodes went
// (claude-fleet#4797); fleet_join_codes.kind and endpoints.node_kind stay,
// written fixed, read by nothing that decides. A row an older hub wrote
// ephemeral is left as it was.
const NodeKindFixed = "fixed"

// ensureNodeKind adds the columns the SPOT nodes once needed
// (claude-fleet#1428) and the device a login-registered node belongs to
// (claude-fleet#2212): the fingerprint of the `fleet login` key that asked,
// so the same device is never enrolled twice (” for every other code).
func (s *Store) ensureNodeKind() error {
	for _, c := range []struct{ table, column, spec string }{
		{"fleet_join_codes", "kind", "TEXT NOT NULL DEFAULT 'fixed'"},
		{"endpoints", "node_kind", "TEXT NOT NULL DEFAULT 'fixed'"},
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

// DeleteNode drops an endpoint's roster row — a retired node's: a machine
// that merely stops reporting stays listed as lost (claude-fleet#1408).
func (s *Store) DeleteNode(endpointID string) error {
	_, err := s.write.Exec(`DELETE FROM nodes WHERE endpoint_id = ?`, endpointID)
	return err
}

// ReleaseLeasesOfEndpoint lets every legacy lease an endpoint holds go, at once, and
// returns them. For a node the hub KNOWS is gone (a retired login): the
// 30-minute lost TTL exists for a machine that may come back, and this one
// will not. Task leases still require their fenced terminal result. Only
// released — nothing is re-dispatched, as for any lost node.
func (s *Store) ReleaseLeasesOfEndpoint(endpointID string) ([]Lease, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if err := s.d.claimWrites(tx, "fleet_leases"); err != nil {
		return nil, err
	}
	rows, err := tx.Query(`SELECT `+leaseReadCols+` FROM fleet_leases WHERE endpoint_id = ? AND task_id = 0`+s.d.forUpdate(), endpointID)
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
	if _, err := tx.Exec(`DELETE FROM fleet_leases WHERE endpoint_id = ? AND task_id = 0`, endpointID); err != nil {
		return nil, err
	}
	return held, tx.Commit()
}
