package store

import (
	"time"
)

// FindingNotice is one row of finding_notices (claude-fleet#1469): the last
// thing the notifier said about one finding problem. See schema.sql.
type FindingNotice struct {
	Problem   string    `json:"problem"`
	FindingID string    `json:"finding_id"`
	Kind      string    `json:"kind"`
	Severity  string    `json:"severity"`
	Title     string    `json:"title"`
	FirstAt   time.Time `json:"first_at"` // when the problem was first announced
	LastAt    time.Time `json:"last_at"`  // when it was last announced (new, escalated or reminded)
}

// FindingNotices lists every row, keyed by problem.
func (s *Store) FindingNotices() (map[string]FindingNotice, error) {
	rows, err := s.read.Query(`SELECT problem, finding_id, kind, severity, title, first_at, last_at FROM finding_notices`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]FindingNotice{}
	for rows.Next() {
		var n FindingNotice
		var first, last string
		if err := rows.Scan(&n.Problem, &n.FindingID, &n.Kind, &n.Severity, &n.Title, &first, &last); err != nil {
			return nil, err
		}
		n.FirstAt, _ = time.Parse(rfc, first)
		n.LastAt, _ = time.Parse(rfc, last)
		out[n.Problem] = n
	}
	return out, rows.Err()
}

// PutFindingNotice writes (or replaces) the row for n.Problem.
func (s *Store) PutFindingNotice(n FindingNotice) error {
	_, err := s.write.Exec(`INSERT INTO finding_notices (problem, finding_id, kind, severity, title, first_at, last_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(problem) DO UPDATE SET finding_id = excluded.finding_id, kind = excluded.kind,
		  severity = excluded.severity, title = excluded.title, first_at = excluded.first_at, last_at = excluded.last_at`,
		n.Problem, n.FindingID, n.Kind, n.Severity, n.Title, n.FirstAt.UTC().Format(rfc), n.LastAt.UTC().Format(rfc))
	return err
}

// DeleteFindingNotice forgets a problem (it recovered).
func (s *Store) DeleteFindingNotice(problem string) error {
	_, err := s.write.Exec(`DELETE FROM finding_notices WHERE problem = ?`, problem)
	return err
}
