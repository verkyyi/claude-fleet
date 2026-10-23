package store

// Explicit task execution admission. Existing InsertFleetOperation callers do
// not acquire this authority. No timeout or operation result releases a binding;
// replacement requires a trusted node's receipt for the stopped native session.
// This is not a claim that arbitrary background services have stopped.

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

const taskSessionExitAction = "task_session_exit"

// TaskSessionExitReceipt identifies the exact native session a trusted node has
// verified exited. Evidence retains its root-component PID/birth exit evidence;
// the Store audits that JSON, it cannot verify a remote kernel. API callers must
// authenticate the node and validate the evidence before calling the Store.
// Scope deliberately excludes independently launched services and external work.
type TaskSessionExitReceipt struct {
	TaskFID           string          `json:"task_fid"`
	Task              string          `json:"task"`
	Owner             string          `json:"owner"`
	ExecutionOwner    string          `json:"execution_owner"`
	ExecutionEndpoint string          `json:"execution_endpoint"`
	Generation        int64           `json:"generation"`
	AttemptID         string          `json:"attempt_id"`
	StartOperationID  string          `json:"start_operation_id"`
	StopOperationID   string          `json:"stop_operation_id"`
	LaunchID          string          `json:"launch_id"`
	Scope             string          `json:"scope"`
	Evidence          json.RawMessage `json:"evidence"`
}

type taskSessionExitRequest struct {
	Version int                    `json:"control_version"`
	Action  string                 `json:"action"`
	Receipt TaskSessionExitReceipt `json:"receipt"`
}

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

// Only explicit resume can look past historical starts. Every start associated
// with this task, including old unindexed envelopes, needs its own accepted
// receipt. Ordinary AuthorizeTaskExecution retains the stricter no-history gate.
func taskResumeHistoryTx(tx *sql.Tx, t FleetTask) error {
	rows, err := tx.Query(`SELECT id, task_ref, request FROM fleet_operations WHERE action = 'worker_start' AND (task_ref = ? OR task_ref = '')`, t.Ref)
	if err != nil {
		return err
	}
	starts := map[string]bool{}
	for rows.Next() {
		var id, ref, request string
		if err = rows.Scan(&id, &ref, &request); err != nil {
			rows.Close()
			return err
		}
		var r struct {
			Params struct {
				Task     string             `json:"task"`
				Dispatch *taskStartEnvelope `json:"dispatch"`
			} `json:"params"`
		}
		if ref == t.Ref || json.Unmarshal([]byte(request), &r) == nil &&
			(r.Params.Task == t.Ref || r.Params.Dispatch != nil && r.Params.Dispatch.Task == t.Ref) {
			starts[id] = true
		}
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	rows, err = tx.Query(`SELECT id FROM fleet_operations WHERE action = ? AND task_ref = ?`, taskSessionExitAction, t.Ref)
	if err != nil {
		return err
	}
	var receipts []string
	for rows.Next() {
		var id string
		if err = rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		receipts = append(receipts, id)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	for _, id := range receipts {
		_, receipt, err := taskSessionExitTx(tx, t, id)
		if err != nil {
			return err
		}
		delete(starts, receipt.StartOperationID)
	}
	if len(starts) != 0 {
		return ErrTaskConflict
	}
	return nil
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

// taskStopBindingTx permits stop replay after a verified session exit released
// the endpoint. This is deliberately NOT a general binding/admission reader:
// only the exact retained start, canonical stop, attempt and generation may be
// recovered from their accepted exit receipt. A succeeded stop alone proves
// nothing, and a prior receipt cannot stand in for a newer execution binding.
func taskStopBindingTx(tx *sql.Tx, t FleetTask) (FleetOperation, int64, error) {
	if t.ExecutionEndpoint != "" || t.ExecutionOwner != "" || t.CancelRequest == "" {
		return taskExecutionBindingTx(tx, t)
	}
	if t.AuthorityVersion != TaskAuthorityVersion || t.OperationID == "" || t.Generation < 2 {
		return FleetOperation{}, 0, ErrTaskFence
	}
	rows, err := tx.Query(`SELECT id FROM fleet_operations WHERE action = ? AND task_owner = ? AND task_ref = ? AND task_generation = ?`,
		taskSessionExitAction, t.Owner, t.Ref, t.Generation-1)
	if err != nil {
		return FleetOperation{}, 0, err
	}
	var ids []string
	for rows.Next() {
		var id string
		if err = rows.Scan(&id); err != nil {
			rows.Close()
			return FleetOperation{}, 0, err
		}
		ids = append(ids, id)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return FleetOperation{}, 0, err
	}
	// RecordTaskSessionExit releases once; duplicates replay that same journal
	// row. More than one receipt for a binding is inconsistent, not a guess.
	if len(ids) != 1 {
		return FleetOperation{}, 0, ErrTaskFence
	}
	_, receipt, err := taskSessionExitTx(tx, t, ids[0])
	if err != nil {
		return FleetOperation{}, 0, err
	}
	if receipt.StartOperationID != t.OperationID || receipt.StopOperationID != t.CancelRequest ||
		receipt.AttemptID != t.AttemptID || receipt.Generation != t.Generation-1 {
		return FleetOperation{}, 0, ErrTaskFence
	}
	start, _, _, generation, err := executionOperationTx(tx, receipt.StartOperationID)
	return start, generation, err
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

// taskSessionExitTx reads only receipts accepted by this protocol. Re-check the
// immutable start and canonical stop associations, not an operation's status
// alone. It also works after the task has acquired a later execution binding.
func taskSessionExitTx(tx *sql.Tx, t FleetTask, id string) (FleetOperation, TaskSessionExitReceipt, error) {
	o, owner, ref, generation, err := executionOperationTx(tx, id)
	if errors.Is(err, sql.ErrNoRows) {
		return o, TaskSessionExitReceipt{}, ErrTaskFence
	}
	if err != nil {
		return o, TaskSessionExitReceipt{}, err
	}
	var request taskSessionExitRequest
	if json.Unmarshal([]byte(o.Request), &request) != nil || request.Version != 1 || request.Action != taskSessionExitAction ||
		o.Action != taskSessionExitAction || o.Status != "succeeded" || o.Result != `{"released":true}` {
		return o, request.Receipt, ErrTaskFence
	}
	r := request.Receipt
	if owner != t.Owner || ref != t.Ref || r.Owner != t.Owner || r.Task != t.Ref || r.TaskFID != t.FID ||
		generation != r.Generation || o.WorkerID != r.ExecutionOwner || r.Scope != "native_session" || r.LaunchID == "" {
		return o, r, ErrTaskFence
	}
	if err := taskSessionExitOperationsTx(tx, t, r, o.FleetID); err != nil {
		return o, r, err
	}
	return o, r, nil
}

func taskSessionExitOperationsTx(tx *sql.Tx, t FleetTask, r TaskSessionExitReceipt, fleet string) error {
	start, owner, ref, generation, err := executionOperationTx(tx, r.StartOperationID)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrTaskFence
	}
	if err != nil {
		return err
	}
	d, err := taskStartOf(start)
	if err != nil || d == nil || !taskExecutionVersion(start.Request) || owner != t.Owner || ref != t.Ref ||
		generation != r.Generation || d.Task != t.Ref || d.Generation != r.Generation || d.AttemptID != r.AttemptID || start.FleetID != fleet {
		return ErrTaskFence
	}
	stop, owner, ref, generation, err := executionOperationTx(tx, r.StopOperationID)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrTaskFence
	}
	if err != nil {
		return err
	}
	var request struct {
		Params struct {
			Task             string `json:"task"`
			WorkerID         string `json:"worker_id"`
			Endpoint         string `json:"execution_endpoint"`
			StartOperationID string `json:"start_operation_id"`
			Generation       int64  `json:"generation"`
			AttemptID        string `json:"attempt_id"`
		} `json:"params"`
	}
	if json.Unmarshal([]byte(stop.Request), &request) != nil || !taskExecutionVersion(stop.Request) || stop.Action != "worker_stop" ||
		stop.FleetID != fleet || owner != t.Owner || ref != t.Ref || generation != r.Generation || request.Params.Task != t.Ref ||
		request.Params.StartOperationID != start.ID || request.Params.WorkerID != r.ExecutionOwner || request.Params.Endpoint != r.ExecutionEndpoint ||
		request.Params.Generation != r.Generation || request.Params.AttemptID != r.AttemptID {
		return ErrTaskFence
	}
	return nil
}

// RecordTaskSessionExit consumes a trusted node's native-session exit receipt.
// A durable stop must precede it. Only the execution binding is released; the
// task's historical session fields, start operation and stop fence survive.
// Replaying the same key returns its historical receipt without touching any
// newer binding. This method never authorizes a new native launch.
func (s *Store) RecordTaskSessionExit(r TaskSessionExitReceipt, idem string, now time.Time) (FleetTask, FleetOperation, error) {
	fleet, fid, parseErr := fleetid.ParseWorkerID(r.ExecutionOwner)
	var evidence map[string]json.RawMessage
	if parseErr != nil || !fleetid.IsUUID(fid) || !fleetid.IsUUID(r.TaskFID) || ParseTaskRef(r.Task) < 1 || r.Owner == "" ||
		r.ExecutionEndpoint == "" || r.Generation < 1 || r.AttemptID == "" || r.StartOperationID == "" || r.StopOperationID == "" ||
		r.LaunchID == "" || r.Scope != "native_session" || idem == "" || now.IsZero() ||
		json.Unmarshal(r.Evidence, &evidence) != nil || len(evidence) == 0 {
		return FleetTask{}, FleetOperation{}, ErrTaskInvalid
	}
	request, err := json.Marshal(taskSessionExitRequest{1, taskSessionExitAction, r})
	if err != nil {
		return FleetTask{}, FleetOperation{}, ErrTaskInvalid
	}
	tx, err := s.write.Begin()
	if err != nil {
		return FleetTask{}, FleetOperation{}, err
	}
	defer tx.Rollback()
	if err = s.d.lockKey(tx, "fleet_operations", "task-execution:"+r.Owner+":"+idem); err != nil {
		return FleetTask{}, FleetOperation{}, err
	}
	t, err := s.taskInTx(tx, ParseTaskRef(r.Task))
	if errors.Is(err, sql.ErrNoRows) {
		return t, FleetOperation{}, ErrTaskFence
	}
	if err != nil {
		return t, FleetOperation{}, err
	}
	if t.Owner != r.Owner || t.FID != r.TaskFID || t.AuthorityVersion != TaskAuthorityVersion {
		return t, FleetOperation{}, ErrTaskFence
	}
	var existing string
	err = tx.QueryRow(`SELECT id FROM fleet_operations WHERE actor = ? AND idem = ?`, r.Owner, idem).Scan(&existing)
	if err == nil {
		o, _, err := taskSessionExitTx(tx, t, existing)
		if err != nil || o.Request != string(request) {
			return t, o, ErrTaskConflict
		}
		return t, o, tx.Commit()
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return t, FleetOperation{}, err
	}
	start, generation, err := taskExecutionBindingTx(tx, t)
	if err != nil {
		return t, FleetOperation{}, err
	}
	if t.ExecutionOwner != r.ExecutionOwner || t.ExecutionEndpoint != r.ExecutionEndpoint || start.ID != r.StartOperationID ||
		start.FleetID != fleet || generation != r.Generation || t.AttemptID != r.AttemptID || t.CancelRequest != r.StopOperationID ||
		t.Generation != generation+1 {
		return t, FleetOperation{}, ErrTaskFence
	}
	if err = taskSessionExitOperationsTx(tx, t, r, fleet); err != nil {
		return t, FleetOperation{}, err
	}
	id, err := taskExecutionOperationID()
	if err != nil {
		return t, FleetOperation{}, err
	}
	o := FleetOperation{ID: id, FleetID: fleet, Action: taskSessionExitAction, Actor: r.Owner, TaskOwner: r.Owner,
		Idem: idem, WorkerID: r.ExecutionOwner, Status: "succeeded", Request: string(request), Result: `{"released":true}`, Created: now.UTC(), Updated: now.UTC()}
	if err = insertExecutionOperationTx(tx, o, t.Ref, generation); err != nil {
		return t, o, err
	}
	if _, err = tx.Exec(`UPDATE fleet_tasks SET execution_owner = '', execution_endpoint = '', updated_at = ? WHERE id = ?`, now.UTC().Format(rfc), t.ID); err != nil {
		return t, o, err
	}
	t.ExecutionOwner, t.ExecutionEndpoint, t.UpdatedAt = "", "", now.UTC()
	return t, o, tx.Commit()
}

// AuthorizeTaskExecution atomically reserves one task's endpoint and journals
// the start. Actor is the authenticated actor; TaskOwner is its API-authorized
// delegation (empty means Actor), exactly as with InsertFleetOperation.
// The task's accepted generation/attempt becomes executable only here. A second
// key cannot acquire it, even if the first start has failed or succeeded.
func (s *Store) AuthorizeTaskExecution(o FleetOperation, endpoint string) (FleetTask, error) {
	return s.authorizeTaskExecution(o, endpoint, "")
}

// ResumeTaskExecution is a new explicit dispatch, never an automatic retry.
// The caller supplies the accepted session-exit operation and a fresh start
// idempotency key. Its envelope must name the generation AFTER the durable stop
// (current task generation + 1), with that generation's new attempt ID.
func (s *Store) ResumeTaskExecution(o FleetOperation, endpoint, exitOperationID string) (FleetTask, error) {
	if exitOperationID == "" {
		return FleetTask{}, ErrTaskInvalid
	}
	return s.authorizeTaskExecution(o, endpoint, exitOperationID)
}

func (s *Store) authorizeTaskExecution(o FleetOperation, endpoint, exitOperationID string) (FleetTask, error) {
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
	if t.Owner != o.TaskOwner || t.AuthorityVersion != TaskAuthorityVersion || t.State == TaskCancelled || t.Outcome != "" {
		return t, ErrTaskFence
	}
	if exitOperationID != "" {
		_, receipt, err := taskSessionExitTx(tx, t, exitOperationID)
		if err != nil {
			return t, err
		}
		if t.ExecutionOwner != "" || t.ExecutionEndpoint != "" || t.OperationID != receipt.StartOperationID ||
			t.CancelRequest != receipt.StopOperationID || t.AttemptID != receipt.AttemptID || t.Generation != receipt.Generation+1 ||
			d.Generation != t.Generation+1 {
			return t, ErrTaskFence
		}
		if err := taskResumeHistoryTx(tx, t); err != nil {
			return t, err
		}
		t.Generation, t.AttemptID, t.CancelRequest = d.Generation, d.AttemptID, ""
	} else {
		if t.Generation != d.Generation || t.AttemptID != d.AttemptID || t.CancelRequest != "" {
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
	}
	if err = insertExecutionOperationTx(tx, o, t.Ref, t.Generation); err != nil {
		return t, err
	}
	if _, err = tx.Exec(`UPDATE fleet_tasks SET execution_endpoint = ?, operation_id = ?, generation = ?, attempt_id = ?, cancel_request = ?, updated_at = ? WHERE id = ?`,
		endpoint, o.ID, t.Generation, t.AttemptID, t.CancelRequest, o.Updated.UTC().Format(rfc), t.ID); err != nil {
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
	// A Session FID survives moves between fleets. Serialize on that immutable
	// identity, not its current fleet prefix. Stop does not release it.
	if err = s.d.lockKey(tx, "fleet_tasks", "task-execution-session:"+fid); err != nil {
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
	err = tx.QueryRow(`SELECT id FROM fleet_tasks WHERE (execution_owner LIKE ? OR worker_id LIKE ? OR fid = ?) AND id <> ? LIMIT 1`, "%/"+fid, "%/"+fid, fid, t.ID).Scan(&other)
	if err == nil {
		return t, ErrTaskConflict
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return t, err
	}
	// Exit may precede the first inventory/ID ledger write. Its immutable audit
	// still owns the Session FID after execution_owner is released, including
	// after a fleet move changes the worker ID prefix.
	var historicalTask string
	err = tx.QueryRow(`SELECT task_ref FROM fleet_operations WHERE action = ? AND worker_id LIKE ? AND task_ref <> ? LIMIT 1`,
		taskSessionExitAction, "%/"+fid, t.Ref).Scan(&historicalTask)
	if err == nil {
		return t, ErrTaskConflict
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return t, err
	}
	// A pre-protocol session may have no execution_owner anywhere. Its ledger
	// still owns its identity, including aliases retained after migration. A
	// closed ledger is history, not authorization to move that identity to a
	// different task. The node must allocate a fresh session identity instead.
	var idOwner, idTask, idTaskFID, idAliases string
	err = tx.QueryRow(`SELECT owner, task, task_id, aliases FROM fleet_ids WHERE id = ?`, fid).Scan(&idOwner, &idTask, &idTaskFID, &idAliases)
	if err == nil {
		if idOwner != owner || idTask != "" && idTask != t.Ref || idTaskFID != "" && idTaskFID != t.FID {
			return t, ErrTaskConflict
		}
		if t.ExecutionOwner == "" && fid != t.FID && idTask != t.Ref && idTaskFID != t.FID {
			return t, ErrTaskConflict // an unassigned old session is not a fresh identity
		}
		var aliases []string
		if json.Unmarshal([]byte(idAliases), &aliases) != nil {
			return t, ErrTaskConflict
		}
		for _, ref := range aliases {
			if ParseTaskRef(ref) > 0 && ref != t.Ref {
				return t, ErrTaskConflict
			}
		}
	} else if !errors.Is(err, sql.ErrNoRows) {
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
	start, generation, err := taskStopBindingTx(tx, t)
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
