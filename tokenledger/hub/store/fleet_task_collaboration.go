package store

import (
	"database/sql"
	"errors"
	"strings"
	"time"
)

// The task graph: a child record names its parent record and the session that
// dispatched it. Neither a local issue key nor a transport acknowledgement is a
// task result — a session's result is its window's ID's (EPIC T497 C8).

// bindTaskParentTx names a child's parent record. The parent is the dispatching
// session — its ID (parent_session, checked to be this account's by the caller,
// EPIC T497 C16) — and parent_task only names that session's record; no record is
// asked for an executor. A parent_session alone names a record only through a
// pre-C8 record's archived executor (a session a launch proof ran, still
// dispatching its batch on the C8 release).
func (s *Store) bindTaskParentTx(tx *sql.Tx, child *FleetTask) error {
	var parent FleetTask
	var err error
	if child.ParentTask != "" {
		parent, err = s.taskInTx(tx, ParseTaskRef(child.ParentTask))
	} else if child.ParentSession != "" {
		var id int64
		err = tx.QueryRow(`SELECT id FROM fleet_tasks WHERE owner = ? AND authority_version = 1 AND execution_owner = ? ORDER BY id DESC LIMIT 1`, child.Owner, child.ParentSession).Scan(&id)
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		if err == nil {
			parent, err = s.taskInTx(tx, id)
		}
	} else {
		return nil
	}
	if err != nil {
		return err
	}
	if parent.Owner != child.Owner {
		return ErrTaskFence
	}
	if parent.AuthorityVersion == 0 {
		return nil
	}
	child.ParentTask, child.ParentGeneration = parent.Ref, parent.Generation
	return nil
}

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
