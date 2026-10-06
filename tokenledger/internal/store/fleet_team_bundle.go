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
