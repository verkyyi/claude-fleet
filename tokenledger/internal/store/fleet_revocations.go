package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"time"
)

// The revocation list (claude-fleet#3560, EPIC #3500 C18): what the hub has
// revoked that a relay or a door must refuse ON ITS OWN, without asking the
// hub per request. One row per entry, keyed by what it names:
//
//   - a pass or a certificate by id — jti `frl1:<sha256>` (a relay
//     credential), `fcp:<id>` (a session pass), `ssh:<serial>` (a connection
//     certificate); exp is when it would have died anyway;
//   - a scope — machine / principal / login, any of them — with `before`:
//     everything of that scope issued before that moment.
//
// Every entry carries exp: past it the entry is dropped (a short credential
// that has expired needs no entry), so the list never only grows. src groups
// the rows one revocation wrote, so lifting it lifts exactly those. One
// version counts every change; a reader holding version v asks for v and is
// answered when it moves. The table is written only while the list is on
// (CCQUOTA_FLEET_REVOCATIONS_TOKEN), so with it off it stays empty.
const fleetRevocationsSchema = `
CREATE TABLE IF NOT EXISTS fleet_revocations (
  k         TEXT PRIMARY KEY,
  jti       TEXT NOT NULL DEFAULT '',
  machine   TEXT NOT NULL DEFAULT '',
  principal TEXT NOT NULL DEFAULT '',
  login     TEXT NOT NULL DEFAULT '',
  before    INTEGER NOT NULL DEFAULT 0,
  exp       INTEGER NOT NULL,
  src       TEXT NOT NULL DEFAULT '',
  reason    TEXT NOT NULL DEFAULT '',
  at        TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS fleet_revocations_src ON fleet_revocations(src);
CREATE TABLE IF NOT EXISTS fleet_revocations_state (
  k       TEXT PRIMARY KEY,
  version INTEGER NOT NULL
);
`

// Revocation is one entry of the list. Before and Exp are Unix seconds.
type Revocation struct {
	JTI       string `json:"jti,omitempty"`
	Machine   string `json:"machine,omitempty"`
	Principal string `json:"principal,omitempty"`
	Login     string `json:"login,omitempty"`
	Before    int64  `json:"before,omitempty"`
	Exp       int64  `json:"exp"`
	Src       string `json:"src,omitempty"`
	Reason    string `json:"reason,omitempty"`
}

// key is the row's identity: the jti, else the scope.
func (r Revocation) key() string {
	if r.JTI != "" {
		return "jti:" + r.JTI
	}
	return "scope:" + r.Machine + "|" + r.Principal + "|" + r.Login
}

func (s *Store) ensureFleetRevocations() error {
	if _, err := s.write.Exec(s.d.ddl(fleetRevocationsSchema)); err != nil {
		return fmt.Errorf("create fleet_revocations table: %w", err)
	}
	return nil
}

func (s *Store) bumpRevocations(tx *sql.Tx) (int64, error) {
	if _, err := tx.Exec(s.d.insertIgnore(`INSERT OR IGNORE INTO fleet_revocations_state (k, version) VALUES ('v', 0)`)); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(`UPDATE fleet_revocations_state SET version = version + 1 WHERE k = 'v'`); err != nil {
		return 0, err
	}
	var v int64
	err := tx.QueryRow(`SELECT version FROM fleet_revocations_state WHERE k = 'v'`).Scan(&v)
	return v, err
}

// AddRevocations writes entries (a repeat refreshes its row), drops every
// entry already past its exp, and moves the version once.
func (s *Store) AddRevocations(entries []Revocation, at time.Time) (int64, error) {
	if len(entries) == 0 {
		return s.RevocationsVersion()
	}
	tx, err := s.write.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	for _, r := range entries {
		if r.JTI == "" && r.Machine == "" && r.Principal == "" && r.Login == "" {
			return 0, errors.New("a revocation names a jti or a scope")
		}
		if r.Exp <= 0 {
			return 0, errors.New("a revocation needs exp")
		}
		if _, err := tx.Exec(`INSERT INTO fleet_revocations (k, jti, machine, principal, login, before, exp, src, reason, at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(k) DO UPDATE SET before = excluded.before,
			exp = excluded.exp, src = excluded.src, reason = excluded.reason, at = excluded.at`,
			r.key(), r.JTI, r.Machine, r.Principal, r.Login, r.Before, r.Exp, r.Src, r.Reason, fmtTime(at)); err != nil {
			return 0, err
		}
	}
	if _, err := tx.Exec(`DELETE FROM fleet_revocations WHERE exp <= ?`, at.Unix()); err != nil {
		return 0, err
	}
	v, err := s.bumpRevocations(tx)
	if err != nil {
		return 0, err
	}
	return v, tx.Commit()
}

// LiftRevocations deletes every row src wrote; the version moves only when
// one went.
func (s *Store) LiftRevocations(src string) (int, int64, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return 0, 0, err
	}
	defer tx.Rollback()
	res, err := tx.Exec(`DELETE FROM fleet_revocations WHERE src = ?`, src)
	if err != nil {
		return 0, 0, err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		v, err := s.RevocationsVersion()
		return 0, v, err
	}
	v, err := s.bumpRevocations(tx)
	if err != nil {
		return 0, 0, err
	}
	return int(n), v, tx.Commit()
}

// RevocationsVersion is the current version, 0 when nothing was ever revoked.
func (s *Store) RevocationsVersion() (int64, error) {
	var v int64
	err := s.write.QueryRow(`SELECT version FROM fleet_revocations_state WHERE k = 'v'`).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	return v, err
}

// Revocations lists the entries still alive at at (exp after it), in key
// order, with the version they belong to.
func (s *Store) RevocationList(at time.Time) (int64, []Revocation, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return 0, nil, err
	}
	defer tx.Rollback()
	var v int64
	if err := tx.QueryRow(`SELECT version FROM fleet_revocations_state WHERE k = 'v'`).Scan(&v); err != nil &&
		!errors.Is(err, sql.ErrNoRows) {
		return 0, nil, err
	}
	rows, err := tx.Query(`SELECT jti, machine, principal, login, before, exp, src, reason FROM fleet_revocations
		WHERE exp > ? ORDER BY k`, at.Unix())
	if err != nil {
		return 0, nil, err
	}
	defer rows.Close()
	out := []Revocation{}
	for rows.Next() {
		var r Revocation
		if err := rows.Scan(&r.JTI, &r.Machine, &r.Principal, &r.Login, &r.Before, &r.Exp, &r.Src, &r.Reason); err != nil {
			return 0, nil, err
		}
		out = append(out, r)
	}
	return v, out, rows.Err()
}

// FleetCertBySerial is one issued certificate, ErrNoFleetCert when unknown.
func (s *Store) FleetCertBySerial(serial string) (FleetCert, error) {
	if _, err := strconv.ParseUint(serial, 10, 64); err != nil {
		return FleetCert{}, ErrNoFleetCert
	}
	certs, err := s.fleetCertsWhere(`serial = ?`, serial)
	if err != nil {
		return FleetCert{}, err
	}
	if len(certs) == 0 {
		return FleetCert{}, ErrNoFleetCert
	}
	return certs[0], nil
}

// LiveFleetCerts is principalID's certificates still valid at at.
func (s *Store) LiveFleetCerts(principalID string, at time.Time) ([]FleetCert, error) {
	return s.fleetCertsWhere(`principal_id = ? AND valid_before > ?`, principalID, at.UTC().Format(rfc))
}

// ErrNoFleetCert is an unknown certificate serial.
var ErrNoFleetCert = errors.New("no such certificate")
