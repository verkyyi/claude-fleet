package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"reflect"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func (s *Server) canTaskContinuation(ctx context.Context, endpoint string) bool {
	if c := s.nodes.get(endpoint); c != nil {
		return c.canTaskExecution && c.canTaskContinuation
	}
	if p, ok := s.peerOf(ctx, endpoint); ok {
		return p.HasCap(control.CapTaskExecution) && p.HasCap(control.CapTaskContinuation)
	}
	return false
}

func continuationRequest(request string) bool {
	var r struct {
		Params map[string]json.RawMessage `json:"params"`
	}
	if json.Unmarshal([]byte(request), &r) != nil {
		return false
	}
	_, present := r.Params["continuation"]
	return present
}

func (s *Server) continueFleetTask(w http.ResponseWriter, r *http.Request, p fleetPrincipal, ref string) {
	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	if p.Worker != nil || p.Actor == "" {
		httpError(w, http.StatusForbidden, "continuation requires the task's person")
		return
	}
	if err := s.authorize(p, "worker:start", ""); err != nil {
		taskExecutionError(w, err)
		return
	}
	t, err := s.ownTask(p, ref)
	// Even the operator's all-task read scope is not ownership of another
	// person's task. Node/worker dispatch does not call this user-only route.
	if errors.Is(err, sql.ErrNoRows) || err == nil && t.Owner != p.Actor {
		httpError(w, http.StatusNotFound, "no such task of yours")
		return
	}
	if err != nil {
		taskRefError(w, ref, err)
		return
	}
	var in struct {
		Key        string  `json:"idempotency_key"`
		Stop       string  `json:"expected_stop_operation_id"`
		Generation int64   `json:"expected_generation"`
		Agent      *string `json:"agent"`
	}
	if !taskExecutionBody(w, r, &in) {
		return
	}
	if !idemRE.MatchString(in.Key) || !idemRE.MatchString(in.Stop) || in.Generation < 2 || in.Agent != nil && !codingAgentOK(*in.Agent) {
		httpError(w, http.StatusBadRequest, "idempotency_key, expected stop/generation and an optional supported agent required")
		return
	}
	intent := store.TaskContinuationIntent{Task: t.Ref, ExpectedStopOperationID: in.Stop, ExpectedGeneration: in.Generation, RequestedAgent: in.Agent}
	out, err := s.continueTask(r.Context(), p, t, in.Key, intent)
	if err != nil {
		taskExecutionError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, out)
}

func continuedOperation(o store.FleetOperation, intent store.TaskContinuationIntent) (map[string]any, error) {
	var request struct {
		Intent *store.TaskContinuationIntent `json:"continuation_intent"`
		Params struct {
			Agent        string                  `json:"agent"`
			Dispatch     dispatchChoice          `json:"dispatch"`
			Continuation *store.TaskContinuation `json:"continuation"`
		} `json:"params"`
	}
	if o.Action != "worker_start" || !controlledExecutionRequest(o.Request) || json.Unmarshal([]byte(o.Request), &request) != nil ||
		request.Intent == nil || !reflect.DeepEqual(*request.Intent, intent) || request.Params.Continuation == nil ||
		!request.Params.Continuation.Valid() ||
		request.Params.Dispatch.Task != intent.Task || request.Params.Dispatch.Generation != intent.ExpectedGeneration+1 ||
		!codingAgentOK(request.Params.Agent) || request.Params.Dispatch.ResolvedAgent != request.Params.Agent {
		return nil, fault("IDEMPOTENCY_CONFLICT", "Key was used for a different operation")
	}
	out := map[string]any{"task": intent.Task, "operation": operationView(o), "agent": request.Params.Agent,
		"authorized_generation": request.Params.Dispatch.Generation}
	if id := request.Params.Continuation.ExitOperationID; id != "" {
		out["exit_operation_id"] = id
	} else {
		out["stop_operation_id"] = request.Params.Continuation.StopOperationID
	}
	return out, nil
}

func (s *Server) continueTask(ctx context.Context, p fleetPrincipal, t store.FleetTask, key string, intent store.TaskContinuationIntent) (out map[string]any, err error) {
	// Another same-key call can commit between our initial lookup and source
	// read. Even a resulting fence/preflight error must replay that operation.
	defer func() {
		if err != nil {
			if existing, lookupErr := s.Store.FleetOperationByIdem(p.Actor, key); lookupErr == nil {
				out, err = continuedOperation(existing, intent)
			}
		}
	}()
	// Replay before looking at any current binding or resolving an omitted
	// provider: a later stop/continue must not change this request's meaning.
	if o, err := s.Store.FleetOperationByIdem(p.Actor, key); err == nil {
		return continuedOperation(o, intent)
	} else if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	source, err := s.Store.TaskContinuationSource(t.ID, t.Owner)
	if err != nil {
		return nil, err
	}
	if intent.ExpectedGeneration != source.Task.Generation || intent.ExpectedStopOperationID != source.Task.CancelRequest {
		return nil, store.ErrTaskFence
	}
	agent := source.Agent
	if intent.RequestedAgent != nil {
		agent = *intent.RequestedAgent
	}
	target, err := s.visibleFleet(p, source.Start.FleetID)
	if err != nil {
		return nil, err
	}
	if target.EndpointID != source.Endpoint || !target.Present {
		return nil, store.ErrTaskFence
	}
	if err := s.checkContinueTarget(ctx, p, target, agent); err != nil {
		return nil, err
	}
	params, request, err := continuationStart(source, key, agent, intent, target)
	if err != nil {
		return nil, err
	}
	now := time.Now()
	op := store.FleetOperation{ID: newOperationID(), FleetID: target.FleetID, Action: "worker_start", Request: request,
		Actor: p.Actor, TaskOwner: t.Owner, Idem: key, Status: "pending", Created: now, Updated: now}
	accepted, err := s.Store.ContinueTaskExecution(op, target.EndpointID)
	if errors.Is(err, store.ErrIdemTaken) {
		o, e := s.Store.FleetOperationByIdem(p.Actor, key)
		if e != nil {
			return nil, e
		}
		return continuedOperation(o, intent)
	}
	if err != nil {
		return nil, err
	}
	// Build the snapshot of THIS accepted authorization. A concurrent stop may
	// already have won; the node must read fresh authority before allocating.
	// Never fetch a newer binding and attach it to this immutable operation.
	snapshot := store.TaskExecutionSnapshot{TaskRef: accepted.Ref, TaskFID: accepted.FID, Generation: accepted.Generation,
		BindingGeneration: accepted.Generation, AttemptID: accepted.AttemptID, OperationID: op.ID,
		ExecutionEndpoint: target.EndpointID, ExecutionOwner: "", CancelRequest: ""}
	envelope := map[string]any{"operation_id": op.ID, "fleet_id": op.FleetID, "action": op.Action,
		"params": params, "actor": p.Actor, "control_version": 1, "task_execution": snapshot}
	hb, _, _ := s.nodeStatusOf(target.EndpointID, now)
	noted := s.recent.note(target.EndpointID, hb.SessionsCount(), now)
	status, result := s.sendWrite(ctx, target, op, envelope)
	status = settleRefusedStart(op.Action, status, result)
	if status == "failed" {
		s.recent.forget(target.EndpointID, noted)
	}
	if err := s.Store.UpdateFleetOperation(op.ID, status, result, time.Now()); err != nil {
		log.Printf("task continue %s: record %s: %v", op.ID, status, err)
	}
	stored, err := s.Store.FleetOperation(op.ID)
	if err != nil {
		return nil, err
	}
	return continuedOperation(stored, intent)
}

// Same-node continuation is still subject to the ordinary named-start policy
// and caps. No new placement, node fallback, or acceptance of another Task.
func (s *Server) checkContinueTarget(ctx context.Context, p fleetPrincipal, target store.FleetRow, agent string) error {
	if err := s.writableAnywhere(ctx, target.EndpointID); err != nil {
		return fault("UNAVAILABLE", err.Error())
	}
	if !s.canTaskContinuation(ctx, target.EndpointID) {
		return fault("UNAVAILABLE", "original node cannot enforce task continuation; nothing was sent")
	}
	now := time.Now()
	hb, _, _ := s.nodeStatusOf(target.EndpointID, now)
	if s.personalOf(target.EndpointID, hb) && !s.isMachine(target.Hostname, s.askedFrom(p, now)) {
		return fault("NO_ELIGIBLE_NODE", target.Hostname+": "+excludedPersonal)
	}
	if s.endpointRole(target.EndpointID) == store.NodeRoleClient {
		return fault("NO_ELIGIBLE_NODE", target.Hostname+": "+excludedClient)
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return err
	}
	if why := otherLoginExcluded(target.Hostname, target.OSUser, settings); why != "" {
		return fault("NO_ELIGIBLE_NODE", why)
	}
	if why := s.denyEndpoint(machineAllowOf(settings, p.Person), target.EndpointID, target.Hostname); why != "" {
		return fault("NO_ELIGIBLE_NODE", why)
	}
	if cv := s.computeFor(target.EndpointID, target.Hostname, hb, settings, agent, now); cv.Off {
		return fault("NO_ELIGIBLE_NODE", cv.Reason())
	}
	if err := s.checkNodeCap(target, now); err != nil {
		return err
	}
	if err := s.checkMemberSessions(target, now); err != nil {
		return err
	}
	a, err := s.Store.OwnerAuthority(p.taskOwner())
	if err != nil {
		return err
	}
	if a.Mode == "hub" && !s.canRepoAuthority(ctx, target.EndpointID) {
		return fault("UNAVAILABLE", "original node cannot enforce task authority")
	}
	return nil
}

func continuationStart(source store.TaskContinuationSource, key, agent string, intent store.TaskContinuationIntent, target store.FleetRow) (map[string]any, string, error) {
	var previous struct {
		Params map[string]any `json:"params"`
	}
	if json.Unmarshal([]byte(source.Start.Request), &previous) != nil {
		return nil, "", store.ErrTaskFence
	}
	params := map[string]any{}
	// Preserve the original task/environment inputs, not parent routing, old
	// native resume IDs, queue/loop plans or arbitrary transport extensions.
	for _, k := range []string{"kind", "repo", "no_repo", "issue", "name", "title", "body", "as", "account_class", "reap", "attachments", "test", "ticket_ref"} {
		if value, ok := previous.Params[k]; ok {
			params[k] = value
		}
	}
	generation := intent.ExpectedGeneration + 1
	params["task"], params["agent"] = source.Task.Ref, agent
	params["dispatch"] = dispatchChoice{Version: 1, RequestID: key, RequestedAgent: agent, ResolvedAgent: agent, AgentSource: "explicit",
		Task: source.Task.Ref, Generation: generation, AttemptID: fmt.Sprintf("task:%s:g%d", source.Task.Ref, generation)}
	params["continuation"] = store.TaskContinuation{Version: 1, ExitOperationID: source.ExitOperationID, StopOperationID: source.StopOperationID}
	raw, err := json.Marshal(map[string]any{"action": "worker_start", "fleet_id": target.FleetID, "node": target.Hostname,
		"control_version": 1, "params": params, "continuation_intent": intent})
	return params, string(raw), err
}
