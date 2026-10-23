package api

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// The authenticated node route and write replay use real storage but no node
// transport: pending cancellation must work while every runtime is offline.
func TestTaskCancelOfflineDispatchBoundary(t *testing.T) {
	s := &Server{Store: openTestStore(t), LiveStore: NewLive(), ViewerToken: viewerToken}
	if err := s.Store.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	const token = "cancel-fixture-token"
	if err := s.Store.Enroll("cancel-node", "cancel node", HashToken(token)); err != nil {
		t.Fatal(err)
	}
	ep, err := s.Store.LiveEndpoint("cancel-node")
	if err != nil {
		t.Fatal(err)
	}
	p := fleetPrincipal{Actor: s.nodeTaskOwner(ep)}
	args := map[string]any{"idempotency_key": "queued-start", "kind": "scratch", "no_repo": true, "coding_agent": "codex", "name": "Cancel before start"}
	w, idem, err := parseWrite("worker_start", args)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.acceptDispatch(p, &w); err != nil {
		t.Fatal(err)
	}
	ref := asString(w.params["task"])
	original := w.params["dispatch"].(*dispatchChoice)
	op := store.FleetOperation{ID: newOperationID(), Actor: p.Actor, TaskOwner: p.taskOwner(), Idem: idem,
		Action: "worker_start", Request: w.canonical, Status: "pending", Created: time.Now(), Updated: time.Now()}
	if err := s.Store.InsertFleetOperation(op); err != nil {
		t.Fatal(err)
	}
	call := func(method, tok string, body any) map[string]any {
		t.Helper()
		b, _ := json.Marshal(body)
		r := httptest.NewRequest(method, NodeTasksPath+"/"+ref, bytes.NewReader(b))
		r.Header.Set("Authorization", "Bearer "+tok)
		rr := httptest.NewRecorder()
		s.handleNodeTasks(rr, r)
		if rr.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", method, rr.Code, rr.Body.String())
		}
		var out map[string]any
		if err := json.Unmarshal(rr.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		return out
	}
	cancel := map[string]any{"authority_version": 1, "mutation": map[string]any{
		"kind": "transition", "state": "cancelled", "idempotency_key": "cancel", "generation": original.Generation,
		"evidence": "person cancelled pending start"}}
	out := call(http.MethodPost, token, cancel)
	if out["generation"] != float64(original.Generation+1) || out["cancel_request"] == nil {
		t.Fatalf("cancel did not persist its fence: %v", out)
	}
	got := call(http.MethodGet, token, nil)["task"].(map[string]any)
	if got["cancel_request"] != out["cancel_request"] || got["attempt_id"] != original.AttemptID {
		t.Fatalf("node cannot observe old envelope revocation: %v", got)
	}
	// Existing key returns its original operation, with no transport or new
	// acceptance. Changed input and a different key cannot revive the task.
	replay, err := s.SubmitWrite(context.Background(), p, "worker_start", args)
	if err != nil || replay["operation_id"] != op.ID || replay["status"] != "failed" {
		t.Fatalf("offline replay: %v %v", replay, err)
	}
	read := httptest.NewRequest(http.MethodGet, "/", nil)
	read.Header.Set("Authorization", "Bearer "+viewerToken)
	if got, err := s.OperationGet(read, op.ID); err != nil || got["status"] != "failed" {
		t.Fatalf("cancelled operation needs no reachable node to read: %v %v", got, err)
	}
	args["name"] = "changed"
	if _, err := s.SubmitWrite(context.Background(), p, "worker_start", args); err == nil || errorObject(err)["code"] != "IDEMPOTENCY_CONFLICT" {
		t.Fatalf("changed replay: %v", err)
	}
	args["name"], args["idempotency_key"], args["dispatch"] = "Cancel before start", "queued-start:try1", original
	delete(args, "coding_agent")
	if _, err := s.SubmitWrite(context.Background(), p, "worker_start", args); err == nil || errorObject(err)["code"] != "INVALID_STATE" {
		t.Fatalf("old envelope must be refused by task fence, not placement/transport: %v", err)
	}
	if _, err := s.Store.FleetOperationByIdem(p.Actor, "queued-start:try1"); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("late API start acquired a journal entry: %v", err)
	}
	// A request accepted just before cancellation must also fail at the final
	// store transaction, even if acceptDispatch had already succeeded.
	op.ID, op.Idem = "late-queue", "late-queue"
	if err := s.Store.InsertFleetOperation(op); err != store.ErrTaskFence {
		t.Fatalf("late enqueue: %v", err)
	}
	persisted, err := s.Store.FleetTask(store.ParseTaskRef(ref))
	if err != nil || persisted.CancelRequest != out["cancel_request"] || persisted.Generation != original.Generation+1 {
		t.Fatalf("late start changed the persisted cancellation: %+v %v", persisted, err)
	}
}

func TestTaskDispatchDraftReplayStaysUnaccepted(t *testing.T) {
	w, _, err := parseWrite("worker_start", map[string]any{
		"idempotency_key": "draft-choice", "kind": "scratch", "no_repo": true,
		"draft": "words not submitted", "coding_agent": "codex",
	})
	if err != nil {
		t.Fatal(err)
	}
	op := store.FleetOperation{ID: newOperationID(), Action: "worker_start", Request: w.canonical, Status: "accepted"}
	if got, err := replayDispatch(op, w); err != nil || got["operation_id"] != op.ID {
		t.Fatalf("draft replay acquired task identity: %v %v", got, err)
	}
}
