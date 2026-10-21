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
	// AlertSpareEmpty: a machine or cluster that should hold spares has had
	// none ready for spareEmptyAfter (claude-fleet#3509) — subject its
	// hostname. AlertSpareFailed: a spare there was made or washed badly and
	// waits for the operator — which stops its refill (claude-fleet#3509).
	// Both are raised at most once a day per (kind, place).
	AlertSpareEmpty  = "spare_empty"
	AlertSpareFailed = "spare_failed"
	// AlertSvcDegraded: a service principal's runs failing in a batch or
	// waiting too long to start (claude-fleet#4007) — subject the principal
	// (svc:<name>); raised at most once an hour.
	AlertSvcDegraded = "svc_degraded"
	// AlertTrialOpenSlow: a trial's seat on a machine did not become usable
	// within fleet.trial.open_slow_secs and was put back (claude-fleet#4235)
	// — subject its hostname; cleared once a trial seat there is ready.
	AlertTrialOpenSlow = "trial_open_slow"
	// AlertTrialNoSpare: a trial waits because no fit machine holds a ready
	// spare (claude-fleet#4259) — subject "hub"; cleared by the next claim.
	AlertTrialNoSpare = "trial_no_spare"
	// AlertTrialCodeBurst: a 试用二维码 started more than fleet.qr.burst trials
	// in 10 minutes and paused itself (claude-fleet MRGB) — subject the code's
	// id; cleared when an admin resumes it.
	AlertTrialCodeBurst = "trial_code_burst"
	// AlertEntryHostKeyChanged: a machine reported an entry host key other
	// than the one the hub held (claude-fleet T743) — every client that pinned
	// the old one now refuses that machine. Subject its hostname; detail the
	// old and new fingerprints. Cleared by the operator once they know why.
	AlertEntryHostKeyChanged = "entry_hostkey_changed"
	// AlertQueueLong: someone has waited in the trial line — the one line a
	// person waits in for a seat — longer than queueLongAfter (claude-fleet
	// QSSW, EPIC WACK C7). Subject "trial"; cleared once nobody still on the
	// page has waited that long.
	AlertQueueLong = "queue_long"
	// AlertStartFailed: at least startFailedMin session starts failed hub-wide
	// within startFailedWindow, whoever asked (claude-fleet QSSW). Subject
	// "hub"; cleared once the window holds fewer.
	AlertStartFailed = "start_failed"
)

// How a raised row was handed to the hub's notifier (claude-fleet QSSW): ""
// not yet, sent, quiet (its kind was sent within fleet.alert.quiet_mins) or
// self (its raiser tells people its own way).
const (
	AlertNotifySent  = "sent"
	AlertNotifyQuiet = "quiet"
	AlertNotifySelf  = "self"
)

// FleetAlert is one row.
type FleetAlert struct {
	ID        int64      `json:"id"`
	Kind      string     `json:"kind"`
	Subject   string     `json:"subject"`
	Detail    string     `json:"detail"`
	RaisedAt  time.Time  `json:"raised_at"`
	ClearedAt *time.Time `json:"cleared_at,omitempty"`
	// Notify is how the raise reached the notifier ("" not yet), NotifiedAt
	// when (claude-fleet QSSW).
	Notify     string     `json:"notify,omitempty"`
	NotifiedAt *time.Time `json:"notified_at,omitempty"`
}

func (s *Store) ensureFleetAlerts() error {
	if _, err := s.write.Exec(s.d.ddl(fleetAlertsSchema)); err != nil {
		return fmt.Errorf("create fleet_alerts table: %w", err)
	}
	if err := s.addColumn("fleet_alerts", "notify", "TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	return s.addColumn("fleet_alerts", "notified_at", "TEXT")
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

// OpenFleetAlert is the open (kind, subject) row's detail and when it was
// raised; ok false when none is open.
func (s *Store) OpenFleetAlert(kind, subject string) (detail string, raised time.Time, ok bool, err error) {
	var at string
	err = s.read.QueryRow(`SELECT detail, raised_at FROM fleet_alerts WHERE kind = ? AND subject = ? AND cleared_at IS NULL
		ORDER BY id DESC LIMIT 1`, kind, subject).Scan(&detail, &at)
	if errors.Is(err, sql.ErrNoRows) {
		return "", time.Time{}, false, nil
	}
	if err != nil {
		return "", time.Time{}, false, err
	}
	raised, _ = time.Parse(rfc, at)
	return detail, raised, true, nil
}

// LastFleetAlertRaised is when (kind, subject) was last raised, open or
// cleared — zero when never (or pruned).
func (s *Store) LastFleetAlertRaised(kind, subject string) (time.Time, error) {
	var raised sql.NullString
	err := s.read.QueryRow(`SELECT raised_at FROM fleet_alerts WHERE kind = ? AND subject = ?
		ORDER BY id DESC LIMIT 1`, kind, subject).Scan(&raised)
	if errors.Is(err, sql.ErrNoRows) {
		return time.Time{}, nil
	}
	if err != nil || !raised.Valid || raised.String == "" {
		return time.Time{}, err
	}
	t, err := time.Parse(rfc, raised.String)
	if err != nil {
		return time.Time{}, nil
	}
	return t.UTC(), nil
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
	rows, err := s.read.Query(`SELECT id, kind, subject, detail, raised_at, cleared_at, notify, notified_at FROM fleet_alerts
		ORDER BY (cleared_at IS NULL) DESC, id DESC LIMIT ` + strconv.Itoa(limit))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []FleetAlert{}
	for rows.Next() {
		var a FleetAlert
		var raised string
		var cleared, notified sql.NullString
		if err := rows.Scan(&a.ID, &a.Kind, &a.Subject, &a.Detail, &raised, &cleared, &a.Notify, &notified); err != nil {
			return nil, err
		}
		a.RaisedAt, _ = time.Parse(rfc, raised)
		a.ClearedAt = parseTimePtr(cleared)
		a.NotifiedAt = parseTimePtr(notified)
		out = append(out, a)
	}
	return out, rows.Err()
}

// UnnotifiedFleetAlerts are the rows raised at or after since that no
// notifier pass has handled yet, oldest first (claude-fleet QSSW).
func (s *Store) UnnotifiedFleetAlerts(since time.Time) ([]FleetAlert, error) {
	// The text bound (second precision, no zone) only narrows the scan; the
	// exact cut is the time compare below.
	rows, err := s.read.Query(`SELECT id, kind, subject, detail, raised_at FROM fleet_alerts
		WHERE notify = '' AND raised_at >= ? ORDER BY id`, since.UTC().Format("2006-01-02T15:04:05"))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []FleetAlert
	for rows.Next() {
		var a FleetAlert
		var raised string
		if err := rows.Scan(&a.ID, &a.Kind, &a.Subject, &a.Detail, &raised); err != nil {
			return nil, err
		}
		a.RaisedAt, _ = time.Parse(rfc, raised)
		// Compared as time: RFC3339Nano text does not sort.
		if !a.RaisedAt.Before(since) {
			out = append(out, a)
		}
	}
	return out, rows.Err()
}

// MarkFleetAlertNotified records how row id reached the notifier; false when
// another pass already did.
func (s *Store) MarkFleetAlertNotified(id int64, how string, at time.Time) (bool, error) {
	res, err := s.write.Exec(`UPDATE fleet_alerts SET notify = ?, notified_at = ? WHERE id = ? AND notify = ''`,
		how, at.UTC().Format(rfc), id)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// LastFleetAlertSent is when a row of kind was last sent to the notifier —
// zero when never (or pruned).
func (s *Store) LastFleetAlertSent(kind string) (time.Time, error) {
	rows, err := s.read.Query(`SELECT notified_at FROM fleet_alerts WHERE kind = ? AND notify = ? AND notified_at IS NOT NULL`,
		kind, AlertNotifySent)
	if err != nil {
		return time.Time{}, err
	}
	defer rows.Close()
	var last time.Time
	for rows.Next() {
		var at string
		if err := rows.Scan(&at); err != nil {
			return time.Time{}, err
		}
		if t, err := time.Parse(rfc, at); err == nil && t.After(last) {
			last = t.UTC()
		}
	}
	return last, rows.Err()
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
