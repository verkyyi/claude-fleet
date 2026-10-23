package store

import (
	"database/sql"
	"errors"
)

// TaskExecutionSnapshot is admission data, not a Task lifecycle or native
// process observation. A reservation has no ExecutionOwner until a node claims
// a real session identity. A stopped snapshot keeps the old binding and its
// generation so cleanup can address it without granting another execution.
//
// This is not a bearer grant. A node may only consume it over its authenticated
// authority path after validating the destination and the operation. Historical
// task execution fields alone never opt an existing session into this protocol.
type TaskExecutionSnapshot struct {
	TaskRef           string `json:"task_ref"`
	TaskFID           string `json:"task_fid"`
	Generation        int64  `json:"generation"`
	BindingGeneration int64  `json:"binding_generation"`
	AttemptID         string `json:"attempt_id"`
	OperationID       string `json:"operation_id"`
	ExecutionEndpoint string `json:"execution_endpoint"`
	ExecutionOwner    string `json:"execution_owner"`
	CancelRequest     string `json:"cancel_request"`
}

// TaskExecutionSnapshot reads the task and its admission journal in one
// transaction. It exports only explicitly controlled bindings. The transport
// must derive owner from authentication, never from an untrusted request body.
func (s *Store) TaskExecutionSnapshot(taskID int64, owner string) (TaskExecutionSnapshot, error) {
	var snapshot TaskExecutionSnapshot
	tx, err := s.write.Begin()
	if err != nil {
		return snapshot, err
	}
	defer tx.Rollback()
	t, err := s.taskInTx(tx, taskID)
	if errors.Is(err, sql.ErrNoRows) {
		return snapshot, ErrTaskFence
	}
	if err != nil {
		return snapshot, err
	}
	snapshot, err = taskExecutionSnapshotTx(tx, t, owner)
	if err != nil {
		return snapshot, err
	}
	return snapshot, tx.Commit()
}

func taskExecutionSnapshotTx(tx *sql.Tx, t FleetTask, owner string) (TaskExecutionSnapshot, error) {
	var snapshot TaskExecutionSnapshot
	if owner == "" || t.Owner != owner {
		return snapshot, ErrTaskFence
	}
	_, generation, err := taskExecutionBindingTx(tx, t)
	if err != nil {
		return snapshot, err
	}
	if t.CancelRequest != "" {
		stop, taskOwner, ref, originalGeneration, err := executionOperationTx(tx, t.CancelRequest)
		if err != nil {
			return snapshot, err
		}
		if stop.Action != "worker_stop" || !taskExecutionVersion(stop.Request) || taskOwner != owner || ref != t.Ref || originalGeneration != generation {
			return snapshot, ErrTaskFence
		}
	} else if t.Generation != generation {
		return snapshot, ErrTaskFence
	}
	snapshot = TaskExecutionSnapshot{TaskRef: t.Ref, TaskFID: t.FID, Generation: t.Generation,
		BindingGeneration: generation, AttemptID: t.AttemptID, OperationID: t.OperationID,
		ExecutionEndpoint: t.ExecutionEndpoint, ExecutionOwner: t.ExecutionOwner, CancelRequest: t.CancelRequest}
	return snapshot, nil
}

// TaskExecutionSnapshots is the reconnect synchronization view. There is no
// presentation limit: a stop outside a UI's first page must still reach its
// endpoint. Legacy journal entries do not enroll old sessions. Corrupt explicit
// bindings fail the read instead of returning a seemingly complete partial set.
func (s *Store) TaskExecutionSnapshots(owner, endpoint string) ([]TaskExecutionSnapshot, error) {
	if owner == "" || endpoint == "" {
		return nil, ErrTaskInvalid
	}
	tx, err := s.write.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	rows, err := tx.Query(`SELECT id FROM fleet_tasks WHERE owner = ? AND execution_endpoint = ? ORDER BY id`, owner, endpoint)
	if err != nil {
		return nil, err
	}
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		ids = append(ids, id)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, err
	}
	result := make([]TaskExecutionSnapshot, 0, len(ids))
	for _, id := range ids {
		t, err := s.taskInTx(tx, id)
		if err != nil {
			return nil, err
		}
		if t.Owner != owner || t.ExecutionEndpoint != endpoint {
			return nil, ErrTaskFence
		}
		if t.OperationID == "" {
			continue // historical archive fields have no execution authority
		}
		o, _, _, _, err := executionOperationTx(tx, t.OperationID)
		if err != nil {
			return nil, err
		}
		if !taskExecutionVersion(o.Request) {
			continue
		}
		snapshot, err := taskExecutionSnapshotTx(tx, t, owner)
		if err != nil {
			return nil, err
		}
		result = append(result, snapshot)
	}
	return result, tx.Commit()
}
