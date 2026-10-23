package store

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"errors"
	"io"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

func (c TaskContinuation) Valid() bool {
	return c.Version == 1 && (c.ExitOperationID != "") != (c.StopOperationID != "")
}

// Require exactly two unique keys, including exactly one nonempty proof ID.
// A null, an explicitly empty alternate branch or a duplicated key is not the
// same thing as omitting that branch from the immutable transport object.
func (c *TaskContinuation) UnmarshalJSON(raw []byte) error {
	d := json.NewDecoder(bytes.NewReader(raw))
	if token, err := d.Token(); err != nil || token != json.Delim('{') {
		return ErrTaskInvalid
	}
	fields := map[string]json.RawMessage{}
	for d.More() {
		token, err := d.Token()
		key, ok := token.(string)
		if err != nil || !ok || fields[key] != nil {
			return ErrTaskInvalid
		}
		var value json.RawMessage
		if d.Decode(&value) != nil {
			return ErrTaskInvalid
		}
		fields[key] = value
	}
	if token, err := d.Token(); err != nil || token != json.Delim('}') {
		return ErrTaskInvalid
	}
	if _, err := d.Token(); err != io.EOF || len(fields) != 2 {
		return ErrTaskInvalid
	}
	var value TaskContinuation
	if json.Unmarshal(fields["version"], &value.Version) != nil {
		return ErrTaskInvalid
	}
	if raw, ok := fields["exit_operation_id"]; ok {
		if json.Unmarshal(raw, &value.ExitOperationID) != nil {
			return ErrTaskInvalid
		}
	} else if raw, ok := fields["stop_operation_id"]; ok {
		if json.Unmarshal(raw, &value.StopOperationID) != nil {
			return ErrTaskInvalid
		}
	}
	if !value.Valid() {
		return ErrTaskInvalid
	}
	*c = value
	return nil
}

// Read a historical start through its indexed association, never just request
// JSON. The canonical stop records the endpoint; each continuation edge below
// checks it against both the current endpoint and the next start's fleet.
func taskIndexedStartTx(tx *sql.Tx, t FleetTask, id string) (FleetOperation, *taskStartEnvelope, error) {
	op, owner, ref, generation, err := executionOperationTx(tx, id)
	if errors.Is(err, sql.ErrNoRows) {
		return op, nil, ErrTaskFence
	}
	if err != nil {
		return op, nil, err
	}
	d, err := taskStartOf(op)
	if err != nil || d == nil || !taskExecutionVersion(op.Request) || owner != t.Owner || ref != t.Ref ||
		d.Task != t.Ref || d.Generation != generation || op.FleetID == "" {
		return op, nil, ErrTaskFence
	}
	return op, d, nil
}

func taskSingleProofTx(tx *sql.Tx, t FleetTask, action string, generation int64, id string) error {
	rows, err := tx.Query(`SELECT id FROM fleet_operations WHERE task_ref = ? AND task_generation = ? AND action = ?`, t.Ref, generation, action)
	if err != nil {
		return err
	}
	defer rows.Close()
	count := 0
	for rows.Next() {
		var got string
		if err := rows.Scan(&got); err != nil {
			return err
		}
		if got != id {
			return ErrTaskFence
		}
		count++
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if count != 1 {
		return ErrTaskFence
	}
	return nil
}

// This historical proof has no dependency on a mutable current cancel pointer.
// Only RequestTaskStop writes an indexed worker_stop, at the same Task-row
// boundary as claim. Ordinary InsertFleetOperation cannot create that index.
func taskUnclaimedStopHistoryTx(tx *sql.Tx, t FleetTask, id string) (TaskExecutionSnapshot, FleetOperation, FleetOperation, error) {
	var snapshot TaskExecutionSnapshot
	var start FleetOperation
	stop, owner, ref, generation, err := executionOperationTx(tx, id)
	if errors.Is(err, sql.ErrNoRows) {
		return snapshot, start, stop, ErrTaskFence
	}
	if err != nil {
		return snapshot, start, stop, err
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
	if t.AuthorityVersion != TaskAuthorityVersion || t.FID == "" || t.Owner == "" || id == "" ||
		json.Unmarshal([]byte(stop.Request), &request) != nil || request.Version != 1 || request.Action != "worker_stop" ||
		stop.Action != "worker_stop" || stop.Actor != t.Owner || owner != t.Owner || ref != t.Ref || generation < 1 ||
		stop.WorkerID != "" || request.Params.WorkerID == nil || *request.Params.WorkerID != "" ||
		request.Params.Task != t.Ref || request.Params.Endpoint == "" || request.Params.AttemptID == "" ||
		request.Params.Generation != generation || request.FleetID != stop.FleetID {
		return snapshot, start, stop, ErrTaskFence
	}
	start, d, err := taskIndexedStartTx(tx, t, request.Params.StartOperationID)
	if err != nil {
		return snapshot, start, stop, err
	}
	if d.Generation != generation || d.AttemptID != request.Params.AttemptID || start.FleetID != stop.FleetID {
		return snapshot, start, stop, ErrTaskFence
	}
	if err := taskSingleProofTx(tx, t, "worker_stop", generation, id); err != nil {
		return snapshot, start, stop, err
	}
	var exits int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM fleet_operations WHERE task_ref = ? AND task_generation = ? AND action = ?`, t.Ref, generation, taskSessionExitAction).Scan(&exits); err != nil {
		return snapshot, start, stop, err
	}
	if exits != 0 {
		return snapshot, start, stop, ErrTaskFence
	}
	snapshot = TaskExecutionSnapshot{TaskRef: t.Ref, TaskFID: t.FID, Generation: generation + 1, BindingGeneration: generation,
		AttemptID: d.AttemptID, OperationID: start.ID, ExecutionEndpoint: request.Params.Endpoint, ExecutionOwner: "", CancelRequest: id}
	return snapshot, start, stop, nil
}

func taskNativeContinuationSourceTx(tx *sql.Tx, t FleetTask, exitID string) (TaskSessionExitReceipt, FleetOperation, error) {
	_, receipt, err := taskSessionExitTx(tx, t, exitID)
	var start FleetOperation
	if err != nil {
		return receipt, start, err
	}
	start, _, err = taskIndexedStartTx(tx, t, receipt.StartOperationID)
	if err != nil {
		return receipt, start, err
	}
	fleet, fid, err := fleetid.ParseWorkerID(receipt.ExecutionOwner)
	if err != nil || !fleetid.IsUUID(fid) || fleet != start.FleetID || receipt.ExecutionEndpoint == "" {
		return receipt, start, ErrTaskFence
	}
	if err := taskSingleProofTx(tx, t, taskSessionExitAction, receipt.Generation, exitID); err != nil {
		return receipt, start, err
	}
	if err := taskSingleProofTx(tx, t, "worker_stop", receipt.Generation, receipt.StopOperationID); err != nil {
		return receipt, start, err
	}
	stop, _, _, _, err := executionOperationTx(tx, receipt.StopOperationID)
	if err != nil {
		return receipt, start, err
	}
	var request struct {
		Version int    `json:"control_version"`
		Action  string `json:"action"`
		FleetID string `json:"fleet_id"`
		Params  struct {
			WorkerID *string `json:"worker_id"`
		} `json:"params"`
	}
	// taskSessionExitTx already checks the complete source/stop/receipt tuple;
	// additionally require the canonical stop envelope and explicit claim value.
	if json.Unmarshal([]byte(stop.Request), &request) != nil || request.Version != 1 || request.Action != "worker_stop" ||
		request.FleetID != start.FleetID || stop.Actor != t.Owner || stop.WorkerID != "" ||
		request.Params.WorkerID == nil || *request.Params.WorkerID != receipt.ExecutionOwner {
		return receipt, start, ErrTaskFence
	}
	return receipt, start, nil
}

func taskContinuationSourceTx(tx *sql.Tx, t FleetTask) (TaskContinuationSource, error) {
	var source TaskContinuationSource
	var err error
	if t.ExecutionEndpoint == "" {
		source, err = taskReleasedSourceTx(tx, t)
		if err == nil {
			_, _, err = taskNativeContinuationSourceTx(tx, t, source.ExitOperationID)
		}
	} else {
		_, err = unclaimedStopTx(tx, t, t.CancelRequest)
		source.Task, source.StopOperationID, source.Endpoint = t, t.CancelRequest, t.ExecutionEndpoint
		if err == nil {
			_, source.Start, _, err = taskUnclaimedStopHistoryTx(tx, t, t.CancelRequest)
		}
	}
	if err != nil {
		return source, err
	}
	if _, err := taskContinuationChainTx(tx, t, source.Start, source.Endpoint); err != nil {
		return source, err
	}
	return source, nil
}

// All starts, including unindexed legacy envelopes, must belong to the exact
// chain. A missing proof cannot be hidden by choosing an unrelated recent stop.
func taskContinueStartIDsTx(tx *sql.Tx, t FleetTask) (map[string]bool, error) {
	rows, err := tx.Query(`SELECT id, task_ref, request FROM fleet_operations WHERE action = 'worker_start' AND (task_ref = ? OR task_ref = '')`, t.Ref)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	ids := map[string]bool{}
	for rows.Next() {
		var id, ref, request string
		if err := rows.Scan(&id, &ref, &request); err != nil {
			return nil, err
		}
		var r struct {
			Params struct {
				Task     string             `json:"task"`
				Dispatch *taskStartEnvelope `json:"dispatch"`
			} `json:"params"`
		}
		if ref == t.Ref || json.Unmarshal([]byte(request), &r) == nil && (r.Params.Task == t.Ref || r.Params.Dispatch != nil && r.Params.Dispatch.Task == t.Ref) {
			ids[id] = true
		}
	}
	return ids, rows.Err()
}

type taskContinuationChain struct {
	SourceStart     *TaskStartMetadata
	SourceStop      *TaskExecutionSnapshot
	WorkspaceSource *TaskWorkspaceSource
}

// Walk the immutable chain, decreasing generation by exactly two per edge.
// The nearest native exit supplies workspace provenance, while the immediate
// source supplies the latest explicit provider choice. Neither is a path from
// the caller, and no previous continuation is forwarded as a node instruction.
func taskContinuationChainTx(tx *sql.Tx, t FleetTask, head FleetOperation, endpoint string) (taskContinuationChain, error) {
	var result taskContinuationChain
	ids, err := taskContinueStartIDsTx(tx, t)
	if err != nil {
		return result, err
	}
	seen := map[string]bool{}
	current := head.ID
	first := true
	stopHead := false
	for {
		if seen[current] || !ids[current] {
			return taskContinuationChain{}, ErrTaskFence
		}
		seen[current] = true
		op, d, err := taskIndexedStartTx(tx, t, current)
		if err != nil {
			return taskContinuationChain{}, err
		}
		next, intent, err := taskStartMetadata(op)
		if err != nil {
			return taskContinuationChain{}, err
		}
		c := next.Continuation
		if c == nil {
			if intent != nil || d.Generation != 1 {
				return taskContinuationChain{}, ErrTaskFence
			}
			break
		}
		if first {
			stopHead = c.StopOperationID != ""
		}
		if intent == nil || intent.Task != t.Ref || intent.ExpectedGeneration != d.Generation-1 ||
			op.Actor != t.Owner || op.WorkerID != "" || intent.RequestedAgent != nil && *intent.RequestedAgent != next.Agent {
			return taskContinuationChain{}, ErrTaskFence
		}
		var stopped TaskExecutionSnapshot
		var previous FleetOperation
		if c.StopOperationID != "" {
			stopped, previous, _, err = taskUnclaimedStopHistoryTx(tx, t, c.StopOperationID)
		} else {
			var receipt TaskSessionExitReceipt
			receipt, previous, err = taskNativeContinuationSourceTx(tx, t, c.ExitOperationID)
			stopped = TaskExecutionSnapshot{TaskRef: t.Ref, TaskFID: t.FID, Generation: receipt.Generation + 1, BindingGeneration: receipt.Generation,
				AttemptID: receipt.AttemptID, OperationID: receipt.StartOperationID, ExecutionEndpoint: receipt.ExecutionEndpoint,
				ExecutionOwner: receipt.ExecutionOwner, CancelRequest: receipt.StopOperationID}
		}
		if err != nil {
			return taskContinuationChain{}, err
		}
		if stopped.ExecutionEndpoint != endpoint || stopped.Generation != d.Generation-1 ||
			stopped.CancelRequest != intent.ExpectedStopOperationID || previous.FleetID != op.FleetID {
			return taskContinuationChain{}, ErrTaskFence
		}
		metadata, _, err := taskStartMetadata(previous)
		if err != nil {
			return taskContinuationChain{}, err
		}
		if metadata.Repo != next.Repo || metadata.NoRepo != next.NoRepo || intent.RequestedAgent == nil && metadata.Agent != next.Agent {
			return taskContinuationChain{}, ErrTaskFence
		}
		metadata.Continuation = nil
		if first {
			result.SourceStart = &metadata
			if stopHead {
				copy := stopped
				result.SourceStop = &copy
			}
		}
		if stopHead && c.ExitOperationID != "" && result.WorkspaceSource == nil {
			result.WorkspaceSource = &TaskWorkspaceSource{ExitOperationID: c.ExitOperationID, Start: metadata}
		}
		first, current = false, previous.ID
	}
	if len(seen) != len(ids) {
		return taskContinuationChain{}, ErrTaskConflict
	}
	return result, nil
}
