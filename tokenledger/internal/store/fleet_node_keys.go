package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// A machine's and a login's own signing key (claude-fleet#3699, EPIC #3500).
//
// An enrollment token is a bearer: whoever copies node.env / machine.env holds
// the node. A node that registers an Ed25519 public key here signs its requests
// instead (`Authorization: FleetSig …`, internal/api/node_sig.go): the private
// key never leaves the machine, and a signature is good once (the nonce) and
// for two minutes (the timestamp). An endpoint is a (machine, login) pair, so
// the machine and each login register their own.
//
// bearer_off is the node's own word that everything on it now signs: from
// then on its bare token is refused (the replay a copied token was). Off, the
// token still works beside the key for one version (# compat-1v: 下一批删 —
// the next version refuses a keyed endpoint's bearer outright).
//
// Created only with the fleet module on (EnsureNodes); a hub without the
// table, or an endpoint with no row, authenticates byte for byte as before.
const fleetNodeKeysSchema = `
CREATE TABLE IF NOT EXISTS fleet_node_keys (
  key_id       TEXT PRIMARY KEY,
  endpoint_id  TEXT NOT NULL,
  public_key   TEXT NOT NULL,
  bearer_off   INTEGER NOT NULL DEFAULT 0,
  created_at   TEXT NOT NULL,
  revoked_at   TEXT
);
CREATE INDEX IF NOT EXISTS fleet_node_keys_endpoint ON fleet_node_keys(endpoint_id);
CREATE TABLE IF NOT EXISTS fleet_sig_nonces (
  key_id   TEXT NOT NULL,
  nonce    TEXT NOT NULL,
  seen_at  TEXT NOT NULL,
  PRIMARY KEY (key_id, nonce)
);
CREATE INDEX IF NOT EXISTS fleet_sig_nonces_seen ON fleet_sig_nonces(seen_at);`

// NodeKey is one endpoint's registered signing key.
type NodeKey struct {
	KeyID      string    `json:"key_id"`
	EndpointID string    `json:"endpoint_id"`
	PublicKey  string    `json:"public_key"` // base64 (std) of the 32-byte Ed25519 key
	BearerOff  bool      `json:"bearer_off"`
	CreatedAt  time.Time `json:"created_at"`
}

// ErrNoNodeKey: the key id names no live key.
var ErrNoNodeKey = errors.New("no such node key")

func (s *Store) ensureFleetNodeKeys() error {
	if _, err := s.write.Exec(s.d.ddl(fleetNodeKeysSchema)); err != nil {
		return fmt.Errorf("create fleet_node_keys table: %w", err)
	}
	return nil
}

// RegisterNodeKey makes k the endpoint's one live key: an earlier key of the
// same endpoint is revoked in the same transaction. Registering the live key
// again only updates bearer_off — and never turns it back on (a node that said
// «everything here signs» is not talked out of it by a bearer request).
func (s *Store) RegisterNodeKey(k NodeKey, now time.Time) error {
	tx, err := s.write.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	ts := now.UTC().Format(rfc)
	if _, err := tx.Exec(`UPDATE fleet_node_keys SET revoked_at = ?
		WHERE endpoint_id = ? AND key_id <> ? AND revoked_at IS NULL`, ts, k.EndpointID, k.KeyID); err != nil {
		return err
	}
	off := 0
	if k.BearerOff {
		off = 1
	}
	res, err := tx.Exec(`UPDATE fleet_node_keys SET bearer_off = CASE WHEN bearer_off = 1 THEN 1 ELSE ? END
		WHERE key_id = ? AND endpoint_id = ? AND revoked_at IS NULL`, off, k.KeyID, k.EndpointID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		if _, err := tx.Exec(`INSERT INTO fleet_node_keys (key_id, endpoint_id, public_key, bearer_off, created_at)
			VALUES (?, ?, ?, ?, ?)`, k.KeyID, k.EndpointID, k.PublicKey, off, ts); err != nil {
			if isUniqueViolation(err) {
				return fmt.Errorf("key %s is registered to another endpoint, or was revoked", k.KeyID)
			}
			return err
		}
	}
	return tx.Commit()
}

func scanNodeKey(row *sql.Row) (*NodeKey, error) {
	var k NodeKey
	var off int
	var created string
	if err := row.Scan(&k.KeyID, &k.EndpointID, &k.PublicKey, &off, &created); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNoNodeKey
		}
		return nil, err
	}
	k.BearerOff = off == 1
	k.CreatedAt, _ = time.Parse(rfc, created)
	return &k, nil
}

// NodeKeyByID is a live key by its id.
func (s *Store) NodeKeyByID(keyID string) (*NodeKey, error) {
	return scanNodeKey(s.read.QueryRow(`SELECT key_id, endpoint_id, public_key, bearer_off, created_at
		FROM fleet_node_keys WHERE key_id = ? AND revoked_at IS NULL`, keyID))
}

// NodeKeyOf is an endpoint's live key; ErrNoNodeKey when it has none (or the
// table does not exist — a hub without the fleet module).
func (s *Store) NodeKeyOf(endpointID string) (*NodeKey, error) {
	k, err := scanNodeKey(s.read.QueryRow(`SELECT key_id, endpoint_id, public_key, bearer_off, created_at
		FROM fleet_node_keys WHERE endpoint_id = ? AND revoked_at IS NULL ORDER BY created_at DESC LIMIT 1`, endpointID))
	if err != nil && isMissingTable(err) {
		return nil, ErrNoNodeKey
	}
	return k, err
}

// SpendSigNonce records (key, nonce) as used; false when it already was — a
// replayed signature. Nonces older than keep are pruned on the way.
func (s *Store) SpendSigNonce(keyID, nonce string, now time.Time, keep time.Duration) (bool, error) {
	if _, err := s.write.Exec(`DELETE FROM fleet_sig_nonces WHERE seen_at < ?`,
		now.Add(-keep).UTC().Format(rfc)); err != nil {
		return false, err
	}
	res, err := s.write.Exec(s.d.insertIgnore(`INSERT OR IGNORE INTO fleet_sig_nonces (key_id, nonce, seen_at) VALUES (?, ?, ?)`),
		keyID, nonce, now.UTC().Format(rfc))
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n == 1, err
}

// LiveEndpoint is an endpoint by id, nil + sql.ErrNoRows when it is unknown
// or retired — the same filter EndpointByTokenHash applies, for an endpoint a
// signature (not a token) names.
func (s *Store) LiveEndpoint(endpointID string) (*Endpoint, error) {
	return scanEndpoint(s.read.QueryRow(endpointColumns+
		` FROM endpoints WHERE endpoint_id = ? AND retired_at IS NULL`, endpointID))
}

// EndpointTokenHash is an endpoint's current token hash — what a worker
// assertion is keyed with (claude-fleet#1810), for a request that proved the
// endpoint by its signature rather than by the token itself.
func (s *Store) EndpointTokenHash(endpointID string) (string, error) {
	var h string
	err := s.read.QueryRow(`SELECT token_hash FROM endpoints WHERE endpoint_id = ?`, endpointID).Scan(&h)
	return h, err
}

// isMissingTable: the query named a table this database does not have —
// SQLite's "no such table", Postgres's SQLSTATE 42P01.
func isMissingTable(err error) bool {
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		return pe.Code == "42P01"
	}
	return err != nil && strings.Contains(err.Error(), "no such table")
}
