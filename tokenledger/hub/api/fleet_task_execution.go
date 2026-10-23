package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

func (w *writeRequest) canonicalize() {
	whole := map[string]any{"action": w.action, "fleet_id": w.fleetID, "node": w.node, "params": w.params}
	if w.controlVersion != 0 {
		whole["control_version"] = w.controlVersion
	}
	b, _ := json.Marshal(whole)
	w.canonical = string(b)
}

func (s *Server) canTaskExecution(ctx context.Context, endpoint string) bool {
	if c := s.nodes.get(endpoint); c != nil {
		return c.canTaskExecution
	}
	if peer, ok := s.peerOf(ctx, endpoint); ok {
		return peer.HasCap(control.CapTaskExecution)
	}
	return false
}

func (s *Server) journalTaskExecution(op store.FleetOperation, w writeRequest, endpoint string) error {
	if w.controlVersion == 1 {
		_, err := s.Store.AuthorizeTaskExecution(op, endpoint)
		return err
	}
	return s.Store.InsertFleetOperation(op)
}

// One strict object; unknown fields cannot spoof the transport identity.
func taskExecutionBody(w http.ResponseWriter, r *http.Request, dst any) bool {
	return taskExecutionBodyLimit(w, r, dst, 16<<10)
}

func taskExecutionBodyLimit(w http.ResponseWriter, r *http.Request, dst any, limit int64) bool {
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, limit))
	d.DisallowUnknownFields()
	if d.Decode(dst) != nil {
		httpError(w, http.StatusBadRequest, "invalid task execution request")
		return false
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		httpError(w, http.StatusBadRequest, "expected one JSON object")
		return false
	}
	return true
}

// Token ownership is necessary but not sufficient: the reserved endpoint alone
// may inspect or claim this execution. A sibling node cannot claim it.
func (s *Server) nodeTaskExecution(w http.ResponseWriter, r *http.Request, ep *store.Endpoint, owner, ref string) bool {
	if ref == "executions" {
		if r.Method != http.MethodGet {
			httpError(w, http.StatusMethodNotAllowed, "GET")
			return true
		}
		snapshots, err := s.Store.TaskExecutionSnapshots(owner, ep.ID)
		if err != nil {
			taskWriteError(w, err)
			return true
		}
		if snapshots == nil {
			snapshots = []store.TaskExecutionSnapshot{}
		}
		writeJSON(w, http.StatusOK, map[string]any{"control_version": 1, "task_executions": snapshots})
		return true
	}
	task, route, found := strings.Cut(ref, "/")
	if !found || (route != "execution" && route != "execution/claim" && route != "execution/exit" && route != "execution/start") {
		return false
	}
	t, err := s.nodeOwnTask(owner, task)
	if err != nil {
		httpError(w, http.StatusNotFound, "no task execution on this node")
		return true
	}
	// An accepted exit releases the endpoint. Its retry must authenticate the
	// original node and let the Store check the immutable receipt, not require
	// the task to retain that old active binding (or inspect a newer one).
	if route == "execution/exit" {
		s.nodeTaskSessionExit(w, r, ep, owner, t)
		return true
	}
	if t.ExecutionEndpoint != ep.ID {
		httpError(w, http.StatusNotFound, "no task execution on this node")
		return true
	}
	if route == "execution/start" {
		if r.Method != http.MethodGet {
			httpError(w, http.StatusMethodNotAllowed, "GET")
			return true
		}
		current, err := s.Store.TaskExecutionStart(t.ID, owner, ep.ID)
		if err != nil {
			taskWriteError(w, err)
			return true
		}
		writeJSON(w, http.StatusOK, current)
		return true
	}
	snapshot, err := s.Store.TaskExecutionSnapshot(t.ID, owner)
	if err != nil {
		taskWriteError(w, err)
		return true
	}
	if route == "execution" {
		if r.Method != http.MethodGet {
			httpError(w, http.StatusMethodNotAllowed, "GET")
			return true
		}
		writeJSON(w, http.StatusOK, snapshot)
		return true
	}
	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return true
	}
	var in struct {
		Version     int    `json:"control_version"`
		OperationID string `json:"operation_id"`
		WorkerID    string `json:"worker_id"`
		Generation  int64  `json:"generation"`
		AttemptID   string `json:"attempt_id"`
	}
	if !taskExecutionBody(w, r, &in) {
		return true
	}
	fleet, key, e := fleetid.ParseWorkerID(in.WorkerID)
	fl, fe := s.Store.Fleet(fleet)
	start, se := s.Store.FleetOperation(snapshot.OperationID)
	if in.Version != 1 || e != nil || !fleetid.IsUUID(key) || fe != nil || se != nil || fl.EndpointID != ep.ID || start.FleetID != fleet {
		httpError(w, http.StatusBadRequest, "claim requires this endpoint's reserved fleet and a real session UUID")
		return true
	}
	_, err = s.Store.ClaimTaskExecution(t.ID, owner, in.OperationID, ep.ID, in.WorkerID, in.Generation, in.AttemptID)
	if err != nil {
		taskWriteError(w, err)
		return true
	}
	snapshot, err = s.Store.TaskExecutionSnapshot(t.ID, owner)
	if err != nil {
		taskWriteError(w, err)
		return true
	}
	writeJSON(w, http.StatusOK, snapshot)
	return true
}

// LOCAL is a transport optimization, never an admission bypass. The operation
// and endpoint reservation are durable before returning the grant to a spawner.
func (s *Server) authorizeLocalTask(ctx context.Context, p fleetPrincipal, w writeRequest, idem string, pl Placement) (map[string]any, error) {
	target, err := s.Store.Fleet(pl.FleetID)
	if err != nil {
		return nil, err
	}
	if !s.canTaskExecution(ctx, target.EndpointID) {
		return nil, fault("UNAVAILABLE", "selected node cannot enforce task execution control")
	}
	authority, err := s.Store.OwnerAuthority(p.taskOwner())
	if err != nil {
		return nil, err
	}
	if authority.Mode == "hub" && !s.canRepoAuthority(ctx, target.EndpointID) {
		return nil, fault("UNAVAILABLE", "selected node cannot enforce task authority")
	}
	w.fleetID = target.FleetID
	w.canonicalize()
	now := time.Now()
	op := store.FleetOperation{ID: newOperationID(), FleetID: target.FleetID, Action: "worker_start", Request: w.canonical,
		Actor: p.Actor, TaskOwner: p.taskOwner(), Idem: idem, Status: "pending", Created: now, Updated: now}
	b, _ := json.Marshal(pl)
	op.Placement = string(b)
	if p.Worker != nil {
		op.WorkerID = p.Worker.WorkerID
	}
	err = s.journalTaskExecution(op, w, target.EndpointID)
	if errors.Is(err, store.ErrIdemTaken) {
		op, err = s.Store.FleetOperationByIdem(p.Actor, idem)
		if err == nil {
			_, err = replayDispatch(op, w)
		}
	}
	if err != nil {
		return nil, err
	}
	snapshot, err := s.Store.TaskExecutionSnapshot(store.ParseTaskRef(asString(w.params["task"])), p.taskOwner())
	if err != nil {
		return nil, err
	}
	if snapshot.CancelRequest != "" || snapshot.OperationID != op.ID || snapshot.ExecutionEndpoint != target.EndpointID {
		return nil, fault("INVALID_STATE", "task start authorization cancelled or replaced")
	}
	return map[string]any{"local": true, "placement": pl, "dispatch": w.params["dispatch"], "control_version": 1, "operation_id": op.ID, "task_execution": snapshot}, nil
}

// Save intent before inspecting connectivity. A successful response confirms
// the durable stop request only; neither RPC receipt nor timeout proves exit.
func (s *Server) stopFleetTask(w http.ResponseWriter, r *http.Request, p fleetPrincipal, ref string) {
	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	t, err := s.ownTask(p, ref)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			httpError(w, http.StatusNotFound, "no such task of yours")
		} else {
			taskRefError(w, ref, err)
		}
		return
	}
	s.requestFleetTaskStop(w, r, t)
}

// Both owner-authenticated entry points persist and deliver through this one
// road. A node may request its owner's stop from any of that owner's logins;
// the reserved execution endpoint still decides where the stop is delivered.
func (s *Server) requestFleetTaskStop(w http.ResponseWriter, r *http.Request, t store.FleetTask) {
	var in struct {
		Key      string `json:"idempotency_key"`
		Evidence string `json:"evidence"`
	}
	if !taskExecutionBody(w, r, &in) {
		return
	}
	if !idemRE.MatchString(in.Key) || len(in.Evidence) > 8000 {
		httpError(w, http.StatusBadRequest, "bounded idempotency_key and evidence required")
		return
	}
	if strings.TrimSpace(in.Evidence) == "" {
		in.Evidence = "person requested task stop"
	}
	stopped, op, err := s.Store.RequestTaskStop(t.ID, t.Owner, in.Key, in.Evidence, time.Now())
	if err != nil {
		taskWriteError(w, err)
		return
	}
	s.finishTaskStop(w, r, stopped, op)
}

// The durable acceptance has already committed when this helper runs. A node
// may acknowledge exit (and a later explicit resume may win) before we respond.
func (s *Server) finishTaskStop(w http.ResponseWriter, r *http.Request, stopped store.FleetTask, op store.FleetOperation) {
	if stopped.ExecutionEndpoint == "" && stopped.ExecutionOwner == "" {
		// RequestTaskStop accepted this released binding only after checking its
		// exact start/stop/exit history. No active snapshot or redelivery exists.
		// The confirmation refers to this stop, even if a later explicit resume
		// wins immediately after the transaction; it is not current task status.
		writeJSON(w, http.StatusAccepted, map[string]any{"stop_requested": true, "execution_exit_confirmed": true,
			"scope": "native_session", "delivery": op.Status, "operation": operationView(op)})
		return
	}
	// A stop that won before claim can prove the start never acquired execution
	// authority, even while the node is offline. Keep this distinct from a native
	// exit receipt and retain the endpoint/cancellation binding for cleanup.
	snapshot, err := s.Store.TaskUnclaimedStop(stopped.ID, stopped.Owner, op.ID)
	neverStarted := err == nil
	if !neverStarted {
		snapshot, err = s.Store.TaskExecutionSnapshot(stopped.ID, stopped.Owner)
	}
	if err != nil || snapshot.CancelRequest != op.ID {
		// Exit or a newer explicit start can win after stop acceptance. Keep
		// that durable acceptance as the response; never send the old stop with
		// a newer binding, nor turn successful acceptance into a snapshot 409.
		writeJSON(w, http.StatusAccepted, map[string]any{"stop_requested": true, "execution_exit_confirmed": false,
			"delivery": op.Status, "operation": operationView(op)})
		return
	}
	// Stop remains pending while offline. Repeating any key redelivers the same
	// canonical operation; aliases are never executed or shown as stop results.
	delivery := "pending"
	if e := s.deliverTaskStop(r.Context(), op, snapshot); e != nil {
		log.Printf("task stop %s delivery pending: %v", op.ID, e)
	}
	if latest, e := s.Store.FleetOperation(op.ID); e == nil {
		op = latest
		delivery = latest.Status
	}
	out := map[string]any{"stop_requested": true, "execution_exit_confirmed": false, "delivery": delivery, "operation": operationView(op), "task_execution": snapshot}
	if neverStarted {
		out["execution_never_started"] = true
	}
	writeJSON(w, http.StatusAccepted, out)
}

func taskExecutionError(w http.ResponseWriter, err error) {
	var f *FleetFault
	if errors.As(err, &f) {
		writeJSON(w, placeStatus(err), map[string]any{"error": errorObject(err)})
		return
	}
	taskWriteError(w, err)
}

func controlledExecutionRequest(request string) bool {
	var r struct {
		Version int `json:"control_version"`
	}
	return json.Unmarshal([]byte(request), &r) == nil && r.Version == 1
}

// The canonical stop remains the authority regardless of its delivery status.
// Reconnection replays it, including a failed/unknown previous delivery. Node
// receipt is idempotent; no operation status releases the execution binding.
func (s *Server) deliverTaskStop(ctx context.Context, op store.FleetOperation, snapshot store.TaskExecutionSnapshot) error {
	if op.ID != snapshot.CancelRequest || op.Action != "worker_stop" || !controlledExecutionRequest(op.Request) {
		return store.ErrTaskFence
	}
	target, err := s.Store.Fleet(op.FleetID)
	if err != nil {
		return err
	}
	if target.EndpointID != snapshot.ExecutionEndpoint {
		return store.ErrTaskFence
	}
	if !s.canTaskExecution(ctx, target.EndpointID) {
		return fault("UNAVAILABLE", "task execution node is offline or incompatible")
	}
	var original struct {
		Params map[string]any `json:"params"`
	}
	if json.Unmarshal([]byte(op.Request), &original) != nil || original.Params == nil {
		return store.ErrTaskInvalid
	}
	envelope := map[string]any{"operation_id": op.ID, "fleet_id": op.FleetID, "action": op.Action, "actor": op.Actor, "params": original.Params, "control_version": 1, "task_execution": snapshot}
	status, result := s.sendWrite(ctx, target, op, envelope)
	return s.Store.UpdateFleetOperation(op.ID, status, result, time.Now())
}

func (s *Server) redeliverTaskStops(ep *store.Endpoint) {
	snapshots, err := s.Store.TaskExecutionSnapshots(s.nodeTaskOwner(ep), ep.ID)
	if err != nil {
		log.Printf("node %s task stop snapshot: %v", ep.ID, err)
		return
	}
	for _, snapshot := range snapshots {
		if snapshot.CancelRequest == "" {
			continue
		}
		op, err := s.Store.FleetOperation(snapshot.CancelRequest)
		if err == nil {
			err = s.deliverTaskStop(context.Background(), op, snapshot)
		}
		if err != nil {
			log.Printf("node %s task stop %s pending: %v", ep.ID, snapshot.CancelRequest, err)
		}
	}
}
