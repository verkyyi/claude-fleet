package store

import (
	"database/sql"
	"encoding/json"
	"errors"
)

// taskStartEnvelope is the identity already carried by v1 dispatches. It is
// neither a new execution protocol nor proof that a process has started.
type taskStartEnvelope struct {
	Task       string `json:"task"`
	Generation int64  `json:"generation"`
	AttemptID  string `json:"attempt_id"`
}

// Keep the existing operation status vocabulary. This exact result is the
// durable revocation marker; ordinary failed operations remain reconcilable.
const taskStartCancelledResult = `{"error":{"code":"TASK_CANCELLED","message":"Start authorization cancelled; remote process exit is not confirmed"}}`

func taskStartOf(o FleetOperation) (*taskStartEnvelope, error) {
	if o.Action != "worker_start" {
		return nil, nil
	}
	var request struct {
		Params struct {
			Task     string             `json:"task"`
			Dispatch *taskStartEnvelope `json:"dispatch"`
		} `json:"params"`
	}
	if json.Unmarshal([]byte(o.Request), &request) != nil {
		return nil, nil // unchanged for legacy operations without an envelope
	}
	d := request.Params.Dispatch
	if d == nil || (d.Task == "" && d.Generation == 0 && d.AttemptID == "") {
		// An unsent draft may carry a provider choice but no accepted task.
		return nil, nil
	}
	if ParseTaskRef(d.Task) == 0 || d.Generation < 1 || d.AttemptID == "" ||
		(request.Params.Task != "" && request.Params.Task != d.Task) {
		return nil, ErrTaskInvalid
	}
	return d, nil
}

// fenceTaskStartTx closes acceptance -> journal's cancellation race. The same
// task lock is held by CancelUnopenedTask until both record and journal commit.
// It does not claim execution ownership or fence already running processes.
func (s *Store) fenceTaskStartTx(tx *sql.Tx, o FleetOperation) (string, int64, error) {
	d, err := taskStartOf(o)
	if err != nil {
		return "", 0, err
	}
	if d == nil {
		// Older clients can carry only params.task. Serialize that start with
		// explicit admission too, while keeping all unbound legacy semantics.
		var request struct {
			Params struct {
				Task string `json:"task"`
			} `json:"params"`
		}
		if json.Unmarshal([]byte(o.Request), &request) != nil || ParseTaskRef(request.Params.Task) == 0 {
			return "", 0, nil
		}
		t, err := s.taskInTx(tx, ParseTaskRef(request.Params.Task))
		if errors.Is(err, sql.ErrNoRows) {
			return "", 0, nil
		}
		if err != nil {
			return "", 0, err
		}
		if controlled, err := taskExecutionProtectedTx(tx, t); err != nil {
			return "", 0, err
		} else if controlled {
			return "", 0, ErrTaskConflict
		}
		return "", 0, nil
	}
	t, err := s.taskInTx(tx, ParseTaskRef(d.Task))
	if errors.Is(err, sql.ErrNoRows) {
		return "", 0, ErrTaskFence
	}
	if err != nil {
		return "", 0, err
	}
	if t.Owner != o.TaskOwner || t.AuthorityVersion != TaskAuthorityVersion ||
		t.Generation != d.Generation || t.AttemptID != d.AttemptID ||
		t.CancelRequest != "" || t.State == TaskCancelled || t.Outcome == TaskCancelled {
		return "", 0, ErrTaskFence
	}
	// Explicit control admission owns this task now. A legacy journal with a
	// different key must not create a second launch beside its reserved endpoint.
	if controlled, err := taskExecutionProtectedTx(tx, t); err != nil {
		return "", 0, err
	} else if controlled {
		return "", 0, ErrTaskConflict
	}
	return t.Ref, t.Generation, nil
}

// cancelTaskStartsTx also covers journals written before task_ref was filled.
// A cancellation invalidates permission to launch; it never claims the remote
// process has exited. The node must check the record before creating a process.
func cancelTaskStartsTx(tx *sql.Tx, t FleetTask, at string) error {
	// Ordinary failures may still receive late accepted/succeeded replies.
	// Revoke those too; a succeeded launch remains its historical launch fact.
	rows, err := tx.Query(`SELECT id, request FROM fleet_operations
		WHERE action = 'worker_start' AND status <> 'succeeded'
		AND (task_ref = ? OR task_ref = '')`, t.Ref)
	if err != nil {
		return err
	}
	var ids []string
	for rows.Next() {
		var id, request string
		if err := rows.Scan(&id, &request); err != nil {
			rows.Close()
			return err
		}
		d, err := taskStartOf(FleetOperation{Action: "worker_start", Request: request})
		if err == nil && d != nil && d.Task == t.Ref {
			ids = append(ids, id)
		}
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	for _, id := range ids {
		if _, err := tx.Exec(`UPDATE fleet_operations SET status = 'failed', result = ?, updated = ?
			WHERE id = ? AND status <> 'succeeded'`, taskStartCancelledResult, at, id); err != nil {
			return err
		}
	}
	return nil
}

// TaskStartPending reads the already-journalled start for this exact Task and
// generation. Historical outcomes and operation IDs from earlier attempts do
// not provide a pending-start observation.
func (s *Store) TaskStartPending(t FleetTask) bool {
	if t.OperationID == "" || t.CancelRequest != "" {
		return false
	}
	var count int
	err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_operations WHERE id = ? AND action = 'worker_start'
  AND task_owner = ? AND task_ref = ? AND task_generation = ? AND status IN ('pending','sent','running')`,
		t.OperationID, t.Owner, t.Ref, t.Generation).Scan(&count)
	return err == nil && count == 1
}
