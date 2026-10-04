package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"time"
)

// Join codes (claude-fleet#1418): the one-time credential a brand-new machine
// trades for its own enrollment token, so adding a machine is one command on
// that machine instead of `ccquota enroll` on the hub plus a copied token.
//
// Only the code's hash is kept, like an enrollment token's. A code redeems
// once, before it expires; redeeming it and enrolling the endpoint happen in
// one transaction, so a code can never mint two tokens and a failed enroll
// never burns a code.
//
// Created only with the fleet module on (EnsureNodes), like every fleet table.
const fleetJoinSchema = `
CREATE TABLE IF NOT EXISTS fleet_join_codes (
  code_hash    TEXT PRIMARY KEY,
  label        TEXT NOT NULL DEFAULT '',
  created_at   TEXT NOT NULL,
  expires_at   TEXT NOT NULL,
  used_at      TEXT,
  endpoint_id  TEXT,
  joined_host  TEXT NOT NULL DEFAULT '',
  joined_user  TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS fleet_join_codes_created ON fleet_join_codes(created_at);`

// JoinCode is one code as the operator sees it — never the code itself.
type JoinCode struct {
	Label      string     `json:"label"`
	CreatedAt  time.Time  `json:"created_at"`
	ExpiresAt  time.Time  `json:"expires_at"`
	UsedAt     *time.Time `json:"used_at"`
	EndpointID string     `json:"endpoint_id,omitempty"`
	JoinedHost string     `json:"joined_host,omitempty"`
	JoinedUser string     `json:"joined_user,omitempty"`
}

// ErrJoinCode is a code that is unknown, already used or expired. One error
// for all three on purpose: the joining side cannot learn which.
var ErrJoinCode = errors.New("join code is unknown, used or expired")

func (s *Store) ensureFleetJoin() error {
	if _, err := s.write.Exec(fleetJoinSchema); err != nil {
		return fmt.Errorf("create fleet_join_codes table: %w", err)
	}
	return nil
}

// CreateJoinCode stores a new code by its hash.
func (s *Store) CreateJoinCode(codeHash, label string, now time.Time, ttl time.Duration) error {
	_, err := s.write.Exec(`INSERT INTO fleet_join_codes (code_hash, label, created_at, expires_at)
		VALUES (?, ?, ?, ?)`, codeHash, label, fmtTime(now), fmtTime(now.Add(ttl)))
	return err
}

// RedeemJoinCode spends a code and enrolls an agent endpoint under it, in one
// transaction. label names the endpoint when the code carries none.
func (s *Store) RedeemJoinCode(codeHash string, now time.Time, endpointID, label, tokenHash, host, osUser string) error {
	tx, err := s.write.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var codeLabel string
	err = tx.QueryRow(`SELECT label FROM fleet_join_codes
		WHERE code_hash = ? AND used_at IS NULL AND expires_at > ?`, codeHash, fmtTime(now)).Scan(&codeLabel)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrJoinCode
	}
	if err != nil {
		return err
	}
	if codeLabel != "" {
		label = codeLabel
	}
	res, err := tx.Exec(`UPDATE fleet_join_codes SET used_at = ?, endpoint_id = ?, joined_host = ?, joined_user = ?
		WHERE code_hash = ? AND used_at IS NULL`, fmtTime(now), endpointID, host, osUser, codeHash)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return ErrJoinCode
	}
	// hostname / os_user are what the joining side reported. The agent's own
	// usage reports overwrite them; recording them now is what lets the admin
	// gate (os_user on the hub's list, claude-fleet#1411) recognise the
	// agent's FIRST connection — before it, os_user is empty and the hello
	// would be refused the admin role until some later reconnect. Same trust
	// as that later report: both are the agent's own word.
	if _, err := tx.Exec(`INSERT INTO endpoints (endpoint_id, account_uuid, label, token_hash, enrolled_at, kind, hostname, os_user)
		VALUES (?, NULL, ?, ?, ?, 'agent', ?, ?)`, endpointID, label, tokenHash, fmtTime(now), host, osUser); err != nil {
		return fmt.Errorf("enroll endpoint: %w", err)
	}
	return tx.Commit()
}

// JoinCodes lists codes, newest first.
func (s *Store) JoinCodes(limit int) ([]JoinCode, error) {
	if limit <= 0 {
		limit = 20
	}
	rows, err := s.read.Query(`SELECT label, created_at, expires_at, used_at, endpoint_id, joined_host, joined_user
		FROM fleet_join_codes ORDER BY created_at DESC LIMIT ` + strconv.Itoa(limit))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []JoinCode{}
	for rows.Next() {
		var c JoinCode
		var created, expires string
		var used, ep sql.NullString
		if err := rows.Scan(&c.Label, &created, &expires, &used, &ep, &c.JoinedHost, &c.JoinedUser); err != nil {
			return nil, err
		}
		c.CreatedAt, _ = time.Parse(rfc, created)
		c.ExpiresAt, _ = time.Parse(rfc, expires)
		c.UsedAt = parseNullTime(used)
		c.EndpointID = ep.String
		out = append(out, c)
	}
	return out, rows.Err()
}
