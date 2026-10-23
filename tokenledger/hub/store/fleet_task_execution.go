package store

// Explicit task execution admission. Existing InsertFleetOperation callers do
// not acquire this authority. No timeout or operation result releases a binding;
// a later change must supply verified execution-domain exit before replacement.

import (
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

// task_stop_alias is an immutable idempotency receipt, never an executable
// worker_stop. Its succeeded status means only that the key was registered.
const taskStopAliasAction = "task_stop_alias"

func taskExecutionOperationID() (string, error) {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return "", err
	}
	id[6] = id[6]&15 | 64
	id[8] = id[8]&63 | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", id[:4], id[4:6], id[6:8], id[8:10], id[10:]), nil
}

func registerTaskStopAliasTx(tx *sql.Tx, t FleetTask, stop FleetOperation, generation int64, idem, evidence string, now time.Time) error {
	id, err := taskExecutionOperationID()
	if err != nil {
		return err
	}
	request, err := json.Marshal(map[string]any{"control_version": 1, "action": taskStopAliasAction,
		"task": t.Ref, "stop_operation_id": stop.ID, "evidence": evidence})
	if err != nil {
		return err
	}
	result, err := json.Marshal(map[string]any{"registered": true, "stop_operation_id": stop.ID})
	if err != nil {
		return err
	}
	alias := FleetOperation{ID: id, FleetID: stop.FleetID, Action: taskStopAliasAction, Actor: t.Owner, TaskOwner: t.Owner,
		Idem: idem, Status: "succeeded", Request: string(request), Result: string(result), Created: now.UTC(), Updated: now.UTC()}
	return insertExecutionOperationTx(tx, alias, t.Ref, generation)
}

func taskExecutionVersion(request string) bool {
	var r struct {
		Version int `json:"control_version"`
	}
	return json.Unmarshal([]byte(request), &r) == nil && r.Version == 1
}

// The old write roads cannot alter or dispatch a record enrolled in the new
// protocol, including one whose other binding fields need investigation.
func taskExecutionProtectedTx(tx *sql.Tx, t FleetTask) (bool, error) {
	if t.OperationID == "" {
		return false, nil
	}
	var request string
	err := tx.QueryRow(`SELECT request FROM fleet_operations WHERE id = ?`, t.OperationID).Scan(&request)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return taskExecutionVersion(request), err
}

// A historical operation may have reached a node before an ID was observed.
// Without an execution-domain exit proof none of its statuses authorize
// adoption. Pre-index and pre-dispatch-envelope journals count as well.
func taskPriorStartTx(tx *sql.Tx, t FleetTask) (bool, error) {
	rows, err := tx.Query(`SELECT task_ref, request FROM fleet_operations WHERE action = 'worker_start' AND (task_ref = ? OR task_ref = '')`, t.Ref)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	for rows.Next() {
		var ref, request string
		if err := rows.Scan(&ref, &request); err != nil {
			return false, err
		}
		if ref == t.Ref {
			return true, nil
		}
		var r struct {
			Params struct {
				Task     string             `json:"task"`
				Dispatch *taskStartEnvelope `json:"dispatch"`
			} `json:"params"`
		}
		if json.Unmarshal([]byte(request), &r) == nil && (r.Params.Task == t.Ref || r.Params.Dispatch != nil && r.Params.Dispatch.Task == t.Ref) {
			return true, nil
		}
	}
	return false, rows.Err()
}

// executionOperationTx also reads the stored task association: the normal
// operation reader intentionally omits these write-only bookkeeping columns.
func executionOperationTx(tx *sql.Tx, id string) (FleetOperation, string, string, int64, error) {
	o, err := scanFleetOperation(tx.QueryRow(`SELECT `+fleetOpCols+` FROM fleet_operations WHERE id = ?`, id))
	if err != nil {
		return o, "", "", 0, err
	}
	var owner, ref string
	var generation int64
	err = tx.QueryRow(`SELECT task_owner, task_ref, task_generation FROM fleet_operations WHERE id = ?`, id).Scan(&owner, &ref, &generation)
	o.TaskOwner = owner
	return o, owner, ref, generation, err
}

// taskExecutionBindingTx distinguishes explicit new admission from pre-C8
// archive fields. The current generation may have advanced because of stop;
// the operation keeps the binding's original generation and attempt.
func taskExecutionBindingTx(tx *sql.Tx, t FleetTask) (FleetOperation, int64, error) {
	if t.AuthorityVersion != TaskAuthorityVersion || t.OperationID == "" || t.ExecutionEndpoint == "" {
		return FleetOperation{}, 0, ErrTaskFence
	}
	o, owner, ref, generation, err := executionOperationTx(tx, t.OperationID)
	if errors.Is(err, sql.ErrNoRows) {
		return o, 0, ErrTaskFence
	}
	if err != nil {
		return o, 0, err
	}
	d, err := taskStartOf(o)
	if err != nil || d == nil || !taskExecutionVersion(o.Request) || owner != t.Owner || ref != t.Ref ||
		d.Task != t.Ref || d.Generation != generation || d.AttemptID != t.AttemptID || o.FleetID == "" {
		return o, 0, ErrTaskFence
	}
	return o, generation, nil
}

func insertExecutionOperationTx(tx *sql.Tx, o FleetOperation, ref string, generation int64) error {
	res, err := tx.Exec(`INSERT INTO fleet_operations
		(id, fleet_id, action, request, actor, idem, status, created, updated, result, placement, worker_id, task_owner, task_ref, task_generation)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULLIF(?, ''), ?, ?, ?, ?, ?)
		ON CONFLICT(actor, idem) DO NOTHING`, o.ID, o.FleetID, o.Action, o.Request, o.Actor, o.Idem, o.Status,
		o.Created.UTC().Format(rfc), o.Updated.UTC().Format(rfc), o.Result, o.Placement, o.WorkerID, o.TaskOwner, ref, generation)
	if err != nil {
		return err
	}
	if n, err := res.RowsAffected(); err != nil {
		return err
	} else if n == 0 {
		return ErrIdemTaken
	}
	return nil
}

// AuthorizeTaskExecution atomically reserves one task's endpoint and journals
// the start. Actor is the authenticated actor; TaskOwner is its API-authorized
// delegation (empty means Actor), exactly as with InsertFleetOperation.
// The task's accepted generation/attempt becomes executable only here. A second
// key cannot acquire it, even if the first start has failed or succeeded.
func (s *Store) AuthorizeTaskExecution(o FleetOperation, endpoint string) (FleetTask, error) {
	if o.TaskOwner == "" {
		o.TaskOwner = o.Actor
	}
	d, err := taskStartOf(o)
	if err != nil || d == nil || !taskExecutionVersion(o.Request) || o.Actor == "" || o.TaskOwner == "" ||
		o.ID == "" || o.Idem == "" || o.FleetID == "" || endpoint == "" || o.Status != "pending" ||
		o.Created.IsZero() || o.Updated.IsZero() || o.Result != "" || d.AttemptID != fmt.Sprintf("task:%s:g%d", d.Task, d.Generation) {
		return FleetTask{}, ErrTaskInvalid
	}
	tx, err := s.write.Begin()
	if err != nil {
		return FleetTask{}, err
	}
	defer tx.Rollback()
	// Serialize the same actor/key even when two callers name different tasks.
	if err = s.d.lockKey(tx, "fleet_operations", "task-execution:"+o.Actor+":"+o.Idem); err != nil {
		return FleetTask{}, err
	}
	var existing string
	err = tx.QueryRow(`SELECT id FROM fleet_operations WHERE actor = ? AND idem = ?`, o.Actor, o.Idem).Scan(&existing)
	if err == nil {
		return FleetTask{}, ErrIdemTaken
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return FleetTask{}, err
	}
	// Keep the existing start/cutover lock order: owner authority before task.
	_, accepted := repoOfStart(o)
	if err = s.ownerStartTx(tx, o.TaskOwner, accepted); err != nil {
		return FleetTask{}, err
	}
	t, err := s.taskInTx(tx, ParseTaskRef(d.Task))
	if errors.Is(err, sql.ErrNoRows) {
		return t, ErrTaskFence
	}
	if err != nil {
		return t, err
	}
	if t.Owner != o.TaskOwner || t.AuthorityVersion != TaskAuthorityVersion || t.Generation != d.Generation || t.AttemptID != d.AttemptID ||
		t.CancelRequest != "" || t.State == TaskCancelled || t.Outcome != "" {
		return t, ErrTaskFence
	}
	if t.ExecutionOwner != "" || t.ExecutionEndpoint != "" || t.OperationID != "" {
		if _, _, err = taskExecutionBindingTx(tx, t); err != nil {
			return t, err
		}
		return t, ErrTaskConflict
	}
	if t.WorkerID != "" || t.SessionKey != "" || t.State != TaskAccepted {
		return t, ErrTaskFence
	}
	if carried, _, e := idCarrying(tx, t.Owner, t.Ref); e != nil {
		return t, e
	} else if carried {
		return t, ErrTaskFence
	}
	if prior, e := taskPriorStartTx(tx, t); e != nil {
		return t, e
	} else if prior {
		return t, ErrTaskConflict
	}
	if err = insertExecutionOperationTx(tx, o, t.Ref, t.Generation); err != nil {
		return t, err
	}
	if _, err = tx.Exec(`UPDATE fleet_tasks SET execution_endpoint = ?, operation_id = ?, updated_at = ? WHERE id = ?`, endpoint, o.ID, o.Updated.UTC().Format(rfc), t.ID); err != nil {
		return t, err
	}
	t.ExecutionEndpoint, t.OperationID, t.UpdatedAt = endpoint, o.ID, o.Updated.UTC()
	return t, tx.Commit()
}

// ClaimTaskExecution binds the real session identity after endpoint admission.
// It does not prove that a native process exists or replace a node's atomic
// process-creation/stop interlock. Stop invalidates even a repeated old claim.
func (s *Store) ClaimTaskExecution(taskID int64, owner, operationID, endpoint, workerID string, generation int64, attempt string) (FleetTask, error) {
	fleet, fid, parseErr := fleetid.ParseWorkerID(workerID)
	if parseErr != nil || !fleetid.IsUUID(fid) || owner == "" || endpoint == "" || operationID == "" {
		return FleetTask{}, ErrTaskInvalid
	}
	tx, err := s.write.Begin()
	if err != nil {
		return FleetTask{}, err
	}
	defer tx.Rollback()
	// Different tasks have different row locks; the worker identity lock also
	// serializes competing claims across tasks. Stop does not release it.
	if err = s.d.lockKey(tx, "fleet_tasks", "task-execution-worker:"+workerID); err != nil {
		return FleetTask{}, err
	}
	t, err := s.taskInTx(tx, taskID)
	if errors.Is(err, sql.ErrNoRows) {
		return t, ErrTaskFence
	}
	if err != nil {
		return t, err
	}
	if t.Owner != owner || t.OperationID != operationID || t.ExecutionEndpoint != endpoint || t.Generation != generation || t.AttemptID != attempt || t.CancelRequest != "" {
		return t, ErrTaskFence
	}
	o, originalGeneration, err := taskExecutionBindingTx(tx, t)
	if err != nil {
		return t, err
	}
	if o.FleetID != fleet || originalGeneration != generation {
		return t, ErrTaskFence
	}
	var other int64
	err = tx.QueryRow(`SELECT id FROM fleet_tasks WHERE execution_owner = ? AND id <> ? LIMIT 1`, workerID, t.ID).Scan(&other)
	if err == nil {
		return t, ErrTaskConflict
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return t, err
	}
	if t.ExecutionOwner != "" {
		if t.ExecutionOwner != workerID {
			return t, ErrTaskConflict
		}
		return t, tx.Commit()
	}
	at := time.Now().UTC()
	if _, err = tx.Exec(`UPDATE fleet_tasks SET execution_owner = ?, updated_at = ? WHERE id = ?`, workerID, at.Format(rfc), t.ID); err != nil {
		return t, err
	}
	t.ExecutionOwner = workerID
	t.UpdatedAt = at
	return t, tx.Commit()
}

// RequestTaskStop persists revocation without consulting node connectivity.
// Both the stopped binding and its start operation keep their original attempt
// and generation. Neither this request nor an ordinary stop operation receipt
// releases that binding. Repeated stop requests return the same intent.
func (s *Store) RequestTaskStop(taskID int64, owner, idem, evidence string, now time.Time) (FleetTask, FleetOperation, error) {
	if taskID < 1 || owner == "" || idem == "" || evidence == "" || now.IsZero() {
		return FleetTask{}, FleetOperation{}, ErrTaskInvalid
	}
	tx, err := s.write.Begin()
	if err != nil {
		return FleetTask{}, FleetOperation{}, err
	}
	defer tx.Rollback()
	if err = s.d.lockKey(tx, "fleet_operations", "task-execution:"+owner+":"+idem); err != nil {
		return FleetTask{}, FleetOperation{}, err
	}
	t, err := s.taskInTx(tx, taskID)
	if errors.Is(err, sql.ErrNoRows) {
		return t, FleetOperation{}, ErrTaskFence
	}
	if err != nil {
		return t, FleetOperation{}, err
	}
	if t.Owner != owner {
		return t, FleetOperation{}, ErrTaskFence
	}
	start, generation, err := taskExecutionBindingTx(tx, t)
	if err != nil {
		return t, FleetOperation{}, err
	}
	var existing string
	err = tx.QueryRow(`SELECT id FROM fleet_operations WHERE actor = ? AND idem = ?`, owner, idem).Scan(&existing)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return t, FleetOperation{}, err
	}
	if existing != "" && existing != t.CancelRequest {
		alias, taskOwner, ref, oldGeneration, err := executionOperationTx(tx, existing)
		if err != nil {
			return t, FleetOperation{}, err
		}
		var receipt struct {
			StopID string `json:"stop_operation_id"`
		}
		if t.CancelRequest == "" || alias.Action != taskStopAliasAction || alias.Status != "succeeded" || !taskExecutionVersion(alias.Request) ||
			taskOwner != owner || ref != t.Ref || oldGeneration != generation || json.Unmarshal([]byte(alias.Request), &receipt) != nil || receipt.StopID != t.CancelRequest {
			return t, FleetOperation{}, ErrTaskConflict
		}
	}
	if t.CancelRequest != "" {
		stop, taskOwner, ref, oldGeneration, err := executionOperationTx(tx, t.CancelRequest)
		if errors.Is(err, sql.ErrNoRows) {
			return t, stop, ErrTaskFence
		}
		if err != nil {
			return t, stop, err
		}
		if stop.Action != "worker_stop" || !taskExecutionVersion(stop.Request) || taskOwner != owner || ref != t.Ref || oldGeneration != generation {
			return t, stop, ErrTaskFence
		}
		// Every accepted key needs a durable journal association, even when
		// it repeats another key's stop. Return only the original worker_stop;
		// aliases are never dispatched and do not release the task binding.
		if existing == "" {
			if err := registerTaskStopAliasTx(tx, t, stop, generation, idem, evidence, now); err != nil {
				return t, stop, err
			}
		}
		return t, stop, tx.Commit()
	}
	if t.Generation != generation {
		return t, FleetOperation{}, ErrTaskFence
	}
	id, err := taskExecutionOperationID()
	if err != nil {
		return t, FleetOperation{}, err
	}
	stop := FleetOperation{ID: id, FleetID: start.FleetID,
		Action: "worker_stop", Actor: owner, TaskOwner: owner, Idem: idem, Status: "pending", Created: now.UTC(), Updated: now.UTC()}
	request, err := json.Marshal(map[string]any{"control_version": 1, "action": "worker_stop", "fleet_id": start.FleetID, "evidence": evidence,
		"params": map[string]any{"task": t.Ref, "worker_id": t.ExecutionOwner, "execution_endpoint": t.ExecutionEndpoint,
			"start_operation_id": start.ID, "generation": generation, "attempt_id": t.AttemptID}})
	if err != nil {
		return t, stop, err
	}
	stop.Request = string(request)
	if err = insertExecutionOperationTx(tx, stop, t.Ref, generation); err != nil {
		return t, stop, err
	}
	t.Generation++
	t.CancelRequest = stop.ID
	t.UpdatedAt = now.UTC()
	if _, err = tx.Exec(`UPDATE fleet_tasks SET generation = ?, cancel_request = ?, updated_at = ? WHERE id = ?`, t.Generation, t.CancelRequest, now.UTC().Format(rfc), t.ID); err != nil {
		return t, stop, err
	}
	if err = cancelTaskStartsTx(tx, t, now.UTC().Format(rfc)); err != nil {
		return t, stop, err
	}
	return t, stop, tx.Commit()
}
