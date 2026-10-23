package store

import (
	"database/sql"
	"encoding/json"
	"errors"
)

// TaskUnclaimedStop proves that this exact start never acquired a Hub claim.
// Claim and stop serialize on the Task row: a committed claim, even with its
// acknowledgement lost, makes the canonical stop's immutable worker_id nonempty.
// No node receipt, process/window absence or operation status supplies this fact.
//
// This read neither releases the endpoint nor manufactures a native-session exit.
// Its snapshot describes this stop, not any later explicitly authorized start.
func (s *Store) TaskUnclaimedStop(taskID int64, owner, stopID string) (TaskExecutionSnapshot, error) {
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
	if _, err := unclaimedStopTx(tx, t, stopID); err != nil {
		return snapshot, err
	}
	snapshot, err = taskExecutionSnapshotTx(tx, t, owner)
	if err != nil {
		return snapshot, err
	}
	return snapshot, tx.Commit()
}

// Only the indexed canonical stop may prove an unclaimed binding. In particular,
// an alias, a generic worker_stop journal entry or a released native session must
// not become this proof merely because its current execution_owner is empty.
func unclaimedStopTx(tx *sql.Tx, t FleetTask, stopID string) (FleetOperation, error) {
	if stopID == "" || t.CancelRequest != stopID || t.ExecutionOwner != "" || t.ExecutionEndpoint == "" ||
		t.Generation < 2 || t.AttemptID == "" || t.FID == "" {
		return FleetOperation{}, ErrTaskFence
	}
	start, generation, err := taskExecutionBindingTx(tx, t)
	if err != nil {
		return FleetOperation{}, err
	}
	if generation != t.Generation-1 {
		return FleetOperation{}, ErrTaskFence
	}
	stop, owner, ref, stopGeneration, err := executionOperationTx(tx, stopID)
	if errors.Is(err, sql.ErrNoRows) {
		return stop, ErrTaskFence
	}
	if err != nil {
		return stop, err
	}
	var request struct {
		Version int    `json:"control_version"`
		Action  string `json:"action"`
		FleetID string `json:"fleet_id"`
		Params  struct {
			Task             string  `json:"task"`
			WorkerID         *string `json:"worker_id"`
			Endpoint         string  `json:"execution_endpoint"`
			StartOperationID string  `json:"start_operation_id"`
			Generation       int64   `json:"generation"`
			AttemptID        string  `json:"attempt_id"`
		} `json:"params"`
	}
	if json.Unmarshal([]byte(stop.Request), &request) != nil || request.Version != 1 || request.Action != "worker_stop" ||
		stop.Action != "worker_stop" || stop.FleetID != start.FleetID || request.FleetID != start.FleetID ||
		stop.Actor != t.Owner || owner != t.Owner || ref != t.Ref || stopGeneration != generation || stop.WorkerID != "" ||
		request.Params.Task != t.Ref || request.Params.WorkerID == nil || *request.Params.WorkerID != "" ||
		request.Params.Endpoint != t.ExecutionEndpoint || request.Params.StartOperationID != start.ID ||
		request.Params.Generation != generation || request.Params.AttemptID != t.AttemptID {
		return stop, ErrTaskFence
	}
	return stop, nil
}
