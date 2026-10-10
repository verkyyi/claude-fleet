package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// Debug reports (claude-fleet#2893, EPIC #2889 C4): one row per diagnostic
// bundle a computer sent up — which ticket sent it, its sha256 (the same bytes
// again are the same report), where it is in its life (uploaded → queued |
// diagnosing → concluded | unfinished) and, once the debugger answered, the
// one line the orchestrator is told plus what it asks us to change (ours —
// the page's last section, and every debug_propose since). updated_at moves on
// every change: it is the cursor the orchestrator's feed reads by. The bundle and the rendered page live in
// CCQUOTA_FLEET_DEBUG_DIR/<id>/, never in the database; the row is what says
// they exist. Seven days after the upload both go (PruneDebugReports).
//
// Created only with the fleet module on (EnsureNodes), like every fleet table.
const fleetDebugReportsSchema = `
CREATE TABLE IF NOT EXISTS fleet_debug_reports (
  id            TEXT PRIMARY KEY,
  ticket_id     TEXT NOT NULL,
  fp            TEXT NOT NULL,
  owner         TEXT NOT NULL,
  sha256        TEXT NOT NULL,
  size          INTEGER NOT NULL,
  note          TEXT NOT NULL,
  state         TEXT NOT NULL,
  why           TEXT NOT NULL,
  endpoint_id   TEXT NOT NULL,
  cause         TEXT NOT NULL,
  ours          TEXT NOT NULL,
  uploaded_at   TEXT NOT NULL,
  dispatched_at TEXT NOT NULL,
  concluded_at  TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS fleet_debug_reports_sha ON fleet_debug_reports(sha256);
CREATE INDEX IF NOT EXISTS fleet_debug_reports_uploaded ON fleet_debug_reports(uploaded_at);
CREATE INDEX IF NOT EXISTS fleet_debug_reports_updated ON fleet_debug_reports(updated_at);`

// The states a report goes through.
const (
	DebugUploaded   = "uploaded"   // stored, no debugger asked yet
	DebugQueued     = "queued"     // the hub's day of sessions was spent: the person decides
	DebugDiagnosing = "diagnosing" // a debugger session was opened for it
	DebugConcluded  = "concluded"  // the page is there
	DebugUnfinished = "unfinished" // no page in time, or no debugger could be opened
)

// DebugReport is one bundle's row.
type DebugReport struct {
	ID           string    `json:"id"`
	TicketID     string    `json:"ticket_id"`
	FP           string    `json:"fp,omitempty"`
	Owner        string    `json:"owner,omitempty"`
	SHA256       string    `json:"sha256"`
	Size         int64     `json:"size"`
	Note         string    `json:"note,omitempty"`
	State        string    `json:"state"`
	Why          string    `json:"why,omitempty"`
	EndpointID   string    `json:"endpoint_id,omitempty"`
	Cause        string    `json:"cause,omitempty"`
	Ours         []string  `json:"ours,omitempty"`
	UploadedAt   time.Time `json:"uploaded_at"`
	DispatchedAt time.Time `json:"dispatched_at,omitzero"`
	ConcludedAt  time.Time `json:"concluded_at,omitzero"`
	UpdatedAt    time.Time `json:"updated_at"`
}

func (s *Store) ensureFleetDebugReports() error {
	if _, err := s.write.Exec(s.d.ddl(fleetDebugReportsSchema)); err != nil {
		return fmt.Errorf("create fleet_debug_reports table: %w", err)
	}
	return nil
}

const debugReportCols = `id, ticket_id, fp, owner, sha256, size, note, state, why, endpoint_id, cause, ours, uploaded_at, dispatched_at, concluded_at, updated_at`

func debugTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(rfc)
}

func scanDebugReport(sc interface{ Scan(...any) error }) (*DebugReport, error) {
	var r DebugReport
	var ours, up, disp, conc, upd string
	if err := sc.Scan(&r.ID, &r.TicketID, &r.FP, &r.Owner, &r.SHA256, &r.Size, &r.Note, &r.State, &r.Why,
		&r.EndpointID, &r.Cause, &ours, &up, &disp, &conc, &upd); err != nil {
		return nil, err
	}
	if ours != "" {
		_ = json.Unmarshal([]byte(ours), &r.Ours)
	}
	r.UpdatedAt, _ = time.Parse(rfc, upd)
	r.UploadedAt, _ = time.Parse(rfc, up)
	if disp != "" {
		r.DispatchedAt, _ = time.Parse(rfc, disp)
	}
	if conc != "" {
		r.ConcludedAt, _ = time.Parse(rfc, conc)
	}
	return &r, nil
}

// InsertDebugReport writes a new report's row.
func (s *Store) InsertDebugReport(r DebugReport) error {
	_, err := s.write.Exec(`INSERT INTO fleet_debug_reports (`+debugReportCols+`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		r.ID, r.TicketID, r.FP, r.Owner, r.SHA256, r.Size, r.Note, r.State, r.Why, r.EndpointID, r.Cause, oursJSON(r.Ours),
		debugTime(r.UploadedAt), debugTime(r.DispatchedAt), debugTime(r.ConcludedAt), debugTime(r.UploadedAt))
	return err
}

// DebugReport is one report's row; nil, nil when there is none.
func (s *Store) DebugReport(id string) (*DebugReport, error) {
	r, err := scanDebugReport(s.read.QueryRow(`SELECT `+debugReportCols+` FROM fleet_debug_reports WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return r, err
}

// DebugReportBySHA is the report the same bytes made from the same computer
// (共同约定 3: a bundle sent again is the same page); nil, nil when none.
func (s *Store) DebugReportBySHA(sha, fp string) (*DebugReport, error) {
	r, err := scanDebugReport(s.read.QueryRow(`SELECT `+debugReportCols+` FROM fleet_debug_reports
		WHERE sha256 = ? AND fp = ? ORDER BY uploaded_at DESC LIMIT 1`, sha, fp))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return r, err
}

// DebugReports is every report uploaded since, newest first.
func (s *Store) DebugReports(since time.Time) ([]DebugReport, error) {
	rows, err := s.read.Query(`SELECT `+debugReportCols+` FROM fleet_debug_reports WHERE uploaded_at >= ? ORDER BY uploaded_at DESC`,
		since.UTC().Format(rfc))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []DebugReport
	for rows.Next() {
		r, err := scanDebugReport(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *r)
	}
	return out, rows.Err()
}

// SetDebugReportState moves a report on, only from one of the states named
// (none = from any): one conditional UPDATE, so two replicas racing on one
// report move it once. false = it was not in one of them (or is gone).
func (s *Store) SetDebugReportState(id, state, why, endpointID string, at time.Time, from ...string) (bool, error) {
	q := `UPDATE fleet_debug_reports SET state = ?, why = ?, updated_at = ?`
	args := []any{state, why, debugTime(at)}
	switch state {
	case DebugDiagnosing:
		q += `, endpoint_id = ?, dispatched_at = ?`
		args = append(args, endpointID, debugTime(at))
	case DebugUnfinished:
		q += `, concluded_at = ?`
		args = append(args, debugTime(at))
	}
	q += ` WHERE id = ?`
	args = append(args, id)
	if len(from) > 0 {
		q += ` AND state IN (?` + repeatComma(len(from)-1) + `)`
		for _, f := range from {
			args = append(args, f)
		}
	}
	res, err := s.write.Exec(q, args...)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n == 1, nil
}

func repeatComma(n int) string {
	b := make([]byte, 0, 3*n)
	for i := 0; i < n; i++ {
		b = append(b, ", ?"...)
	}
	return string(b)
}

// ConcludeDebugReport records the debugger's answer: the page is written,
// cause is its one line, ours what the page asks us to change. A report already concluded is concluded again (the
// debugger may correct itself before it stops); an unfinished one too — a late
// page is still the answer.
func (s *Store) ConcludeDebugReport(id, cause string, ours []string, at time.Time) (bool, error) {
	res, err := s.write.Exec(`UPDATE fleet_debug_reports SET state = ?, why = '', cause = ?, ours = ?, concluded_at = ?, updated_at = ? WHERE id = ?`,
		DebugConcluded, cause, oursJSON(ours), debugTime(at), debugTime(at), id)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n == 1, nil
}

// AddDebugProposal appends one thing the debugger asks us to change
// (debug_propose) — a line for the person to nod at, never an issue by itself.
func (s *Store) AddDebugProposal(id, text string, at time.Time) (bool, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback() //nolint:errcheck // a committed tx makes this a no-op
	var ours string
	if err := tx.QueryRow(`SELECT ours FROM fleet_debug_reports WHERE id = ?`, id).Scan(&ours); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return false, nil
		}
		return false, err
	}
	var list []string
	if ours != "" {
		_ = json.Unmarshal([]byte(ours), &list)
	}
	for _, o := range list {
		if o == text {
			return true, tx.Commit() // the same line again changes nothing
		}
	}
	if _, err := tx.Exec(`UPDATE fleet_debug_reports SET ours = ?, updated_at = ? WHERE id = ?`,
		oursJSON(append(list, text)), debugTime(at), id); err != nil {
		return false, err
	}
	return true, tx.Commit()
}

// DebugReportsUpdatedAfter is every report changed after t, oldest change
// first — the orchestrator's feed.
func (s *Store) DebugReportsUpdatedAfter(t time.Time, limit int) ([]DebugReport, error) {
	rows, err := s.read.Query(`SELECT `+debugReportCols+` FROM fleet_debug_reports WHERE updated_at > ? ORDER BY updated_at LIMIT ?`,
		debugTime(t), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []DebugReport
	for rows.Next() {
		r, err := scanDebugReport(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *r)
	}
	return out, rows.Err()
}

func oursJSON(ours []string) string {
	if len(ours) == 0 {
		return ""
	}
	b, _ := json.Marshal(ours)
	return string(b)
}

// DeleteDebugReport removes one report's row (its directory is the caller's).
func (s *Store) DeleteDebugReport(id string) (bool, error) {
	res, err := s.write.Exec(`DELETE FROM fleet_debug_reports WHERE id = ?`, id)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n == 1, nil
}

// StaleDebugReports are the reports uploaded before cutoff — the ones the
// seven days are up for.
func (s *Store) StaleDebugReports(cutoff time.Time) ([]string, error) {
	rows, err := s.read.Query(`SELECT id FROM fleet_debug_reports WHERE uploaded_at < ?`, cutoff.UTC().Format(rfc))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}
