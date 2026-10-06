package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// The team configuration (claude-fleet#1726, EPIC #1718 C8) — one layer the
// hub hands every computer between the fleet's defaults and the login's own:
// MCP servers, hooks, skills and Agent settings, never a credential. Every
// PUT is a new version with a pointer to the one it replaced, so the history
// is append-only and a rollback is one more version carrying an older body.
//
// Created only with the fleet module on (EnsureNodes), like every fleet table.
const fleetTeamBundleSchema = `
CREATE TABLE IF NOT EXISTS fleet_team_bundles (
  version  INTEGER PRIMARY KEY,
  prev     INTEGER NOT NULL,
  bundle   TEXT NOT NULL,
  actor    TEXT NOT NULL,
  note     TEXT NOT NULL DEFAULT '',
  created  TEXT NOT NULL
);
`

// FleetTeamBundle is one version of the team layer. Bundle is the JSON text
// exactly as the hub validated it.
type FleetTeamBundle struct {
	Version int       `json:"version"`
	Prev    int       `json:"prev"`
	Bundle  string    `json:"-"`
	Actor   string    `json:"actor"`
	Note    string    `json:"note,omitempty"`
	Created time.Time `json:"created"`
}

// ErrNoTeamBundle is a version that was never written.
var ErrNoTeamBundle = errors.New("no such team bundle version")

// ErrTeamBundleBase is a PUT whose base is not the current version: someone
// changed it in between.
var ErrTeamBundleBase = errors.New("the team bundle changed since that version")

func (s *Store) ensureFleetTeamBundles() error {
	if _, err := s.write.Exec(fleetTeamBundleSchema); err != nil {
		return fmt.Errorf("create fleet_team_bundles table: %w", err)
	}
	return nil
}

// TeamBundle returns version v, or the current one for v <= 0. No version
// at all → ErrNoTeamBundle.
func (s *Store) TeamBundle(v int) (FleetTeamBundle, error) {
	q := `SELECT version, prev, bundle, actor, note, created FROM fleet_team_bundles `
	var row *sql.Row
	if v > 0 {
		row = s.read.QueryRow(q+`WHERE version = ?`, v)
	} else {
		row = s.read.QueryRow(q + `ORDER BY version DESC LIMIT 1`)
	}
	var b FleetTeamBundle
	var created string
	if err := row.Scan(&b.Version, &b.Prev, &b.Bundle, &b.Actor, &b.Note, &created); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return FleetTeamBundle{}, ErrNoTeamBundle
		}
		return FleetTeamBundle{}, err
	}
	b.Created, _ = time.Parse(rfc, created)
	return b, nil
}

// TeamBundles lists the versions, newest first, without their bodies.
func (s *Store) TeamBundles(limit int) ([]FleetTeamBundle, error) {
	if limit <= 0 {
		limit = 20
	}
	rows, err := s.read.Query(`SELECT version, prev, actor, note, created FROM fleet_team_bundles
		ORDER BY version DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []FleetTeamBundle
	for rows.Next() {
		var b FleetTeamBundle
		var created string
		if err := rows.Scan(&b.Version, &b.Prev, &b.Actor, &b.Note, &created); err != nil {
			return nil, err
		}
		b.Created, _ = time.Parse(rfc, created)
		out = append(out, b)
	}
	return out, rows.Err()
}

// PutTeamBundle writes the next version. base >= 0 must equal the current
// version (0 = none yet) or ErrTeamBundleBase; base < 0 skips the check.
func (s *Store) PutTeamBundle(bundle, actor, note string, base int, at time.Time) (FleetTeamBundle, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return FleetTeamBundle{}, err
	}
	defer tx.Rollback() //nolint:errcheck — a no-op after Commit
	var cur int
	if err := tx.QueryRow(`SELECT COALESCE(MAX(version), 0) FROM fleet_team_bundles`).Scan(&cur); err != nil {
		return FleetTeamBundle{}, err
	}
	if base >= 0 && base != cur {
		return FleetTeamBundle{}, ErrTeamBundleBase
	}
	b := FleetTeamBundle{Version: cur + 1, Prev: cur, Bundle: bundle, Actor: actor, Note: note, Created: at.UTC()}
	if _, err := tx.Exec(`INSERT INTO fleet_team_bundles (version, prev, bundle, actor, note, created)
		VALUES (?, ?, ?, ?, ?, ?)`, b.Version, b.Prev, b.Bundle, b.Actor, b.Note, at.UTC().Format(rfc)); err != nil {
		return FleetTeamBundle{}, err
	}
	return b, tx.Commit()
}

// The personal configuration (claude-fleet#1856, EPIC #1855 C1) — the same
// layer, one per person (principal): what a member wants in every session
// on every computer they work from. Same versions, same append-only history,
// keyed by (principal, version). The row's principal is the canonical
// fleet_principals spelling, so a case-folded lookup reads one book.
const fleetPersonBundleSchema = `
CREATE TABLE IF NOT EXISTS fleet_person_bundles (
  principal TEXT NOT NULL,
  version   INTEGER NOT NULL,
  prev      INTEGER NOT NULL,
  bundle    TEXT NOT NULL,
  actor     TEXT NOT NULL,
  note      TEXT NOT NULL DEFAULT '',
  created   TEXT NOT NULL,
  PRIMARY KEY (principal, version)
);
`

func (s *Store) ensureFleetPersonBundles() error {
	if _, err := s.write.Exec(fleetPersonBundleSchema); err != nil {
		return fmt.Errorf("create fleet_person_bundles table: %w", err)
	}
	return nil
}

// PersonBundle is TeamBundle for one principal's layer.
func (s *Store) PersonBundle(principal string, v int) (FleetTeamBundle, error) {
	q := `SELECT version, prev, bundle, actor, note, created FROM fleet_person_bundles WHERE principal = ? `
	var row *sql.Row
	if v > 0 {
		row = s.read.QueryRow(q+`AND version = ?`, principal, v)
	} else {
		row = s.read.QueryRow(q+`ORDER BY version DESC LIMIT 1`, principal)
	}
	var b FleetTeamBundle
	var created string
	if err := row.Scan(&b.Version, &b.Prev, &b.Bundle, &b.Actor, &b.Note, &created); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return FleetTeamBundle{}, ErrNoTeamBundle
		}
		return FleetTeamBundle{}, err
	}
	b.Created, _ = time.Parse(rfc, created)
	return b, nil
}

// PersonBundles is TeamBundles for one principal's layer.
func (s *Store) PersonBundles(principal string, limit int) ([]FleetTeamBundle, error) {
	if limit <= 0 {
		limit = 20
	}
	rows, err := s.read.Query(`SELECT version, prev, actor, note, created FROM fleet_person_bundles
		WHERE principal = ? ORDER BY version DESC LIMIT ?`, principal, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []FleetTeamBundle
	for rows.Next() {
		var b FleetTeamBundle
		var created string
		if err := rows.Scan(&b.Version, &b.Prev, &b.Actor, &b.Note, &created); err != nil {
			return nil, err
		}
		b.Created, _ = time.Parse(rfc, created)
		out = append(out, b)
	}
	return out, rows.Err()
}

// PutPersonBundle is PutTeamBundle for one principal's layer: base >= 0
// must be that principal's current version or ErrTeamBundleBase.
func (s *Store) PutPersonBundle(principal, bundle, actor, note string, base int, at time.Time) (FleetTeamBundle, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return FleetTeamBundle{}, err
	}
	defer tx.Rollback() //nolint:errcheck — a no-op after Commit
	var cur int
	if err := tx.QueryRow(`SELECT COALESCE(MAX(version), 0) FROM fleet_person_bundles WHERE principal = ?`, principal).Scan(&cur); err != nil {
		return FleetTeamBundle{}, err
	}
	if base >= 0 && base != cur {
		return FleetTeamBundle{}, ErrTeamBundleBase
	}
	b := FleetTeamBundle{Version: cur + 1, Prev: cur, Bundle: bundle, Actor: actor, Note: note, Created: at.UTC()}
	if _, err := tx.Exec(`INSERT INTO fleet_person_bundles (principal, version, prev, bundle, actor, note, created)
		VALUES (?, ?, ?, ?, ?, ?, ?)`, principal, b.Version, b.Prev, b.Bundle, b.Actor, b.Note, at.UTC().Format(rfc)); err != nil {
		return FleetTeamBundle{}, err
	}
	return b, tx.Commit()
}
