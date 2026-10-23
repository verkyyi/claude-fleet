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
	return snapshot, tx.Commit()
}
