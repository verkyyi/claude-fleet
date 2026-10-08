package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// A machine's identity and its desired state (claude-fleet#2214, EPIC #2329 C2).
//
// Trust used to be a word about a machine NAME (fleet.node_trust.<machine>),
// and the name is whatever the agent reports — so an untrusted endpoint that
// reported a trusted machine's hostname inherited its trust. Trust now rides
// the endpoint itself, the identity the hub minted with its token:
//
//   - endpoints.trust / trust_source: set when a join code that carries trust
//     is redeemed (source join_code), or by the operator's desired-state write
//     (source operator) — never by anything the node says;
//   - endpoints.enrolled_host (a core column, store.go): the name the endpoint
//     enrolled under. The old name-keyed trust still holds for one version
//     (compat-1v), but only while the endpoint reports the name it enrolled
//     with — a borrowed name inherits nothing.
//
// fleet_node_desired is the hub's copy of what a managed machine should look
// like (release, component versions, accounts, spares). The node reads it and
// converges; its heartbeat says which version it reached. docs/MANAGED-NODE.md
// is the shape.
const fleetDesiredSchema = `
CREATE TABLE IF NOT EXISTS fleet_node_desired (
  endpoint_id  TEXT PRIMARY KEY,
  version      INTEGER NOT NULL DEFAULT 0,
  body         TEXT NOT NULL DEFAULT '{}',
  updated_at   TEXT NOT NULL,
  updated_by   TEXT NOT NULL DEFAULT ''
);`

// Trust sources: where an endpoint's own trust came from.
const (
	TrustSourceJoinCode = "join_code"
	TrustSourceOperator = "operator"
)

// NodeRoleManaged is a machine the fleet manages whole (EPIC #2329).
const NodeRoleManaged = "managed"

// EndpointTrust is an endpoint's own trust record. Trust "" = the endpoint
// carries none, and the machine-name rule decides.
type EndpointTrust struct {
	Trust        string
	Source       string
	Role         string
	EnrolledHost string
}

// ErrDesiredVersion is a desired-state write that names a version other than
// the current one.
var ErrDesiredVersion = errors.New("desired state changed since it was read")

func (s *Store) ensureFleetIdentity() error {
	if _, err := s.write.Exec(s.d.ddl(fleetDesiredSchema)); err != nil {
		return fmt.Errorf("create fleet_node_desired table: %w", err)
	}
	for _, c := range []struct{ table, column string }{
		{"endpoints", "trust"}, {"endpoints", "trust_source"}, {"endpoints", "role"},
		{"fleet_join_codes", "trust"}, {"fleet_join_codes", "role"},
	} {
		if err := s.addColumn(c.table, c.column, "TEXT NOT NULL DEFAULT ''"); err != nil {
			return err
		}
	}
	return nil
}

// CreateJoinCodeFor stores a code that also carries the trust and role the
// endpoint it enrolls will hold — the operator's word, written at minting.
func (s *Store) CreateJoinCodeFor(codeHash, label, kind, trust, role string, now time.Time, ttl time.Duration) error {
	if kind == "" {
		kind = NodeKindFixed
	}
	_, err := s.write.Exec(`INSERT INTO fleet_join_codes (code_hash, label, kind, created_at, expires_at, trust, role)
		VALUES (?, ?, ?, ?, ?, ?, ?)`, codeHash, label, kind, fmtTime(now), fmtTime(now.Add(ttl)), trust, role)
	return err
}

// EndpointTrustOf is one endpoint's own trust record. Its own query, like
// EndpointKind: it gates credentials, so a caller asks for it by name.
func (s *Store) EndpointTrustOf(endpointID string) (EndpointTrust, error) {
	var t EndpointTrust
	err := s.read.QueryRow(`SELECT trust, trust_source, role, enrolled_host FROM endpoints WHERE endpoint_id = ?`,
		endpointID).Scan(&t.Trust, &t.Source, &t.Role, &t.EnrolledHost)
	if errors.Is(err, sql.ErrNoRows) {
		return EndpointTrust{}, ErrNoSuchEndpoint
	}
	return t, err
}

// EndpointTrusts is every live endpoint's trust record with its current
// hostname, by endpoint id — the roster's and the machine check's one read.
func (s *Store) EndpointTrusts() (map[string]EndpointTrust, map[string]string, error) {
	rows, err := s.read.Query(`SELECT endpoint_id, hostname, trust, trust_source, role, enrolled_host
		FROM endpoints WHERE retired_at IS NULL`)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	out, hosts := map[string]EndpointTrust{}, map[string]string{}
	for rows.Next() {
		var id, host string
		var t EndpointTrust
		if err := rows.Scan(&id, &host, &t.Trust, &t.Source, &t.Role, &t.EnrolledHost); err != nil {
			return nil, nil, err
		}
		out[id], hosts[id] = t, host
	}
	return out, hosts, rows.Err()
}

// SetEndpointTrust writes an endpoint's own trust ("" clears it, so the
// machine-name rule decides again).
func (s *Store) SetEndpointTrust(endpointID, trust, source string) error {
	if trust == "" {
		source = ""
	}
	res, err := s.write.Exec(`UPDATE endpoints SET trust = ?, trust_source = ? WHERE endpoint_id = ? AND retired_at IS NULL`,
		trust, source, endpointID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return ErrNoSuchEndpoint
	}
	return nil
}

// NodeDesired is one machine's desired state as the hub keeps it. Body is the
// JSON object docs/MANAGED-NODE.md describes, without trust (that lives on the
// endpoint); Version bumps on every write, 0 = never written.
type NodeDesired struct {
	EndpointID string
	Version    int
	Body       string
	UpdatedAt  time.Time
	UpdatedBy  string
}

// DesiredOf is an endpoint's desired state; Version 0 and Body "{}" when the
// operator never wrote one.
func (s *Store) DesiredOf(endpointID string) (NodeDesired, error) {
	d := NodeDesired{EndpointID: endpointID, Body: "{}"}
	var at string
	err := s.read.QueryRow(`SELECT version, body, updated_at, updated_by FROM fleet_node_desired WHERE endpoint_id = ?`,
		endpointID).Scan(&d.Version, &d.Body, &at, &d.UpdatedBy)
	if errors.Is(err, sql.ErrNoRows) {
		return d, nil
	}
	if err != nil {
		return d, err
	}
	d.UpdatedAt, _ = time.Parse(rfc, at)
	return d, nil
}

// PutDesired replaces an endpoint's desired state and returns the new
// version. ifVersion ≥ 0 is the version the writer read: anything else is
// ErrDesiredVersion and nothing is written.
func (s *Store) PutDesired(endpointID, body, by string, ifVersion int, now time.Time) (int, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	var cur int
	switch err := tx.QueryRow(`SELECT version FROM fleet_node_desired WHERE endpoint_id = ?`, endpointID).Scan(&cur); {
	case errors.Is(err, sql.ErrNoRows):
		cur = 0
	case err != nil:
		return 0, err
	}
	if ifVersion >= 0 && ifVersion != cur {
		return cur, ErrDesiredVersion
	}
	next := cur + 1
	if _, err := tx.Exec(`INSERT INTO fleet_node_desired (endpoint_id, version, body, updated_at, updated_by)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(endpoint_id) DO UPDATE SET version = excluded.version, body = excluded.body,
		  updated_at = excluded.updated_at, updated_by = excluded.updated_by`,
		endpointID, next, body, fmtTime(now), by); err != nil {
		return 0, err
	}
	return next, tx.Commit()
}
