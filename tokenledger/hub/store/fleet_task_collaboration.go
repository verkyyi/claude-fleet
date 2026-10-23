package store

import (
	"strings"
	"time"
)

// Historical Parent columns remain available to read-only compatibility views.

// FleetTaskChildren lists the records that name parent as theirs.
func (s *Store) FleetTaskChildren(owner, parent string) ([]FleetTask, error) {
	rows, err := s.read.Query(`SELECT `+fleetTaskCols+` FROM fleet_tasks WHERE owner = ? AND authority_version = 1 AND parent_task = ? ORDER BY id`, owner, parent)
	if err != nil {
		return nil, err
	}
	out, err := scanFleetTasks(rows)
	if out == nil {
		out = []FleetTask{}
	}
	return out, err
}

// TaskProgress is a task's newest workflow word (claude-fleet#4957): an EPIC
// driver's tick line on its parent task. Since EPIC T497 C12 it is the progress
// word of the ID that carries the record (fleet_ids.progress).
type TaskProgress struct {
	Status  string    `json:"status"`
	Summary string    `json:"summary,omitempty"`
	At      time.Time `json:"at"`
}

// SessionOfTask answers whether owner's session worker (`<fleet>/<ID>`) works a
// task record: its window's ID carries one (EPIC T497 C8), or — a pre-C8 session
// — a launch proof once claimed a record for it (the archived task_attempt row).
// Any other session of owner's is legacy work for a person's authority cutover.
func (s *Store) SessionOfTask(owner, worker string) (bool, error) {
	if _, id, ok := strings.Cut(worker, "/"); ok && id != "" {
		var n int
		if err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_ids WHERE id = ? AND owner = ? AND task != ''`, id, owner).Scan(&n); err != nil {
			return false, err
		}
		if n > 0 {
			return true, nil
		}
	}
	var count int
	err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_operations WHERE action = 'task_attempt' AND actor = ? AND worker_id = ?`, owner, worker).Scan(&count)
	return count > 0, err
}
