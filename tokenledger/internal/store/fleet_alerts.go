package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Fleet alerts (claude-fleet#1630): what the hub saw go wrong with its nodes
// while nobody was looking — a machine silent past FLEET_NODE_LOST_ALERT_SECS
// (node_lost), a node reconnecting with a session whose issue another worker
// now holds (lease_conflict). The hub only RECORDS: no lease changes hands and
// no session is touched because of a row here.
//
// A row is open until it is cleared (cleared_at set). At most one open row per
// (kind, subject): raising an open one again is a no-op, so a sweeper may raise
// on every tick and the row keeps the moment the condition was first seen.
// raised_at / cleared_at are exactly the timestamps a drill reads back.
const fleetAlertsSchema = `
CREATE TABLE IF NOT EXISTS fleet_alerts (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  kind       TEXT NOT NULL,
  subject    TEXT NOT NULL,
  detail     TEXT NOT NULL DEFAULT '{}',
  raised_at  TEXT NOT NULL,
  cleared_at TEXT
);
CREATE INDEX IF NOT EXISTS fleet_alerts_open ON fleet_alerts (kind, subject, cleared_at);`

// Alert kinds.
const (
	AlertNodeLost      = "node_lost"
	AlertLeaseConflict = "lease_conflict"
	// AlertServiceFailed: an entry of a machine's login-level register that
	// is meant to run and does not (claude-fleet#2526) — subject
	// "<hostname>/<login>/<name>", raised and cleared off the machine link's
	// beat.
	AlertServiceFailed = "service_failed"
)

// FleetAlert is one row.
type FleetAlert struct {
	ID        int64      `json:"id"`
	Kind      string     `json:"kind"`
	Subject   string     `json:"subject"`
	Detail    string     `json:"detail"`
	RaisedAt  time.Time  `json:"raised_at"`
	ClearedAt *time.Time `json:"cleared_at,omitempty"`
}

func (s *Store) ensureFleetAlerts() error {
	if _, err := s.write.Exec(s.d.ddl(fleetAlertsSchema)); err != nil {
		return fmt.Errorf("create fleet_alerts table: %w", err)
	}
	return nil
}

// RaiseFleetAlert opens (kind, subject) unless an open row exists. raised
// reports whether this call opened it.
func (s *Store) RaiseFleetAlert(kind, subject, detail string, at time.Time) (raised bool, err error) {
	if detail == "" {
		detail = "{}"
	}
	tx, err := s.write.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	var id int64
	err = tx.QueryRow(`SELECT id FROM fleet_alerts WHERE kind = ? AND subject = ? AND cleared_at IS NULL`,
		kind, subject).Scan(&id)
	switch {
	case err == nil:
		return false, nil
	case !errors.Is(err, sql.ErrNoRows):
		return false, err
	}
	if _, err := tx.Exec(`INSERT INTO fleet_alerts (kind, subject, detail, raised_at) VALUES (?, ?, ?, ?)`,
		kind, subject, detail, at.UTC().Format(rfc)); err != nil {
		return false, err
	}
	return true, tx.Commit()
}

// ClearFleetAlert closes the open (kind, subject) row, if any. cleared reports
// whether there was one.
func (s *Store) ClearFleetAlert(kind, subject string, at time.Time) (cleared bool, err error) {
	res, err := s.write.Exec(`UPDATE fleet_alerts SET cleared_at = ? WHERE kind = ? AND subject = ? AND cleared_at IS NULL`,
		at.UTC().Format(rfc), kind, subject)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// OpenFleetAlertSubjects lists the subjects of kind's open rows that start
// with prefix.
func (s *Store) OpenFleetAlertSubjects(kind, prefix string) ([]string, error) {
	rows, err := s.read.Query(`SELECT subject FROM fleet_alerts WHERE kind = ? AND cleared_at IS NULL`, kind)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var sub string
		if err := rows.Scan(&sub); err != nil {
			return nil, err
		}
		if strings.HasPrefix(sub, prefix) {
			out = append(out, sub)
		}
	}
	return out, rows.Err()
}

// FleetAlerts lists alerts newest first: every open one, and the cleared ones
// up to limit rows in all (default 100).
func (s *Store) FleetAlerts(limit int) ([]FleetAlert, error) {
	if limit <= 0 {
		limit = 100
	}
	rows, err := s.read.Query(`SELECT id, kind, subject, detail, raised_at, cleared_at FROM fleet_alerts
		ORDER BY (cleared_at IS NULL) DESC, id DESC LIMIT ` + strconv.Itoa(limit))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []FleetAlert{}
	for rows.Next() {
		var a FleetAlert
		var raised string
		var cleared sql.NullString
		if err := rows.Scan(&a.ID, &a.Kind, &a.Subject, &a.Detail, &raised, &cleared); err != nil {
			return nil, err
		}
		a.RaisedAt, _ = time.Parse(rfc, raised)
		a.ClearedAt = parseTimePtr(cleared)
		out = append(out, a)
	}
	return out, rows.Err()
}

// PruneFleetAlerts deletes cleared rows cleared before cutoff. Open rows stay.
func (s *Store) PruneFleetAlerts(cutoff time.Time) error {
	rows, err := s.read.Query(`SELECT id, cleared_at FROM fleet_alerts WHERE cleared_at IS NOT NULL`)
	if err != nil {
		return err
	}
	var old []int64
	for rows.Next() {
		var id int64
		var c string
		if err := rows.Scan(&id, &c); err != nil {
			rows.Close()
			return err
		}
		// Compared as time: RFC3339Nano text does not sort.
		if t, err := time.Parse(rfc, c); err == nil && t.Before(cutoff) {
			old = append(old, id)
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, id := range old {
		if _, err := s.write.Exec(`DELETE FROM fleet_alerts WHERE id = ?`, id); err != nil {
			return err
		}
	}
	return nil
}
