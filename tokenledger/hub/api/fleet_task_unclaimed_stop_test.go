package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func TestTaskUnclaimedStopAPIOffline(t *testing.T) {
	h, _, target, _, _ := twoNodesCaps(t, control.CapTaskExecution)
	postFleet(t, h, "worker_start", map[string]any{"kind": "scratch", "repo": writeRepo,
		"idempotency_key": "never-claimed", "coding_agent": "codex", "control_version": 1}, 200)
	target.mu.Lock()
	snapshot := target.writes[0]["task_execution"].(map[string]any)
	target.mu.Unlock()
	task, err := h.srv.Store.FleetTask(store.ParseTaskRef(snapshot["task_ref"].(string)))
	if err != nil {
		t.Fatal(err)
	}
	// No node connection or peer directory: proof comes from Hub admission,
	// never from a delivery acknowledgement or an absent node process/window.
	s := &Server{Store: h.srv.Store}
	var stopID any
	for _, key := range []string{"never-stop", "never-stop-alias", "never-stop"} {
		r := httptest.NewRequest(http.MethodPost, "http://fleet.test/stop", strings.NewReader(`{"idempotency_key":"`+key+`"}`))
		w := httptest.NewRecorder()
		s.stopFleetTask(w, r, fleetPrincipal{Actor: task.Owner}, task.Ref)
		var out map[string]any
		if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		if w.Code != 202 || out["execution_never_started"] != true || out["execution_exit_confirmed"] != false ||
			out["stop_requested"] != true || out["scope"] != nil || out["delivery"] != "pending" {
			t.Fatalf("unclaimed stop requires its own fact, not native exit: %d %v", w.Code, out)
		}
		got := out["operation"].(map[string]any)["operation_id"]
		if stopID != nil && stopID != got {
			t.Fatal("stop alias replaced canonical proof")
		}
		stopID = got
		stopped, err := s.Store.FleetTask(task.ID)
		if err != nil || stopped.ExecutionEndpoint != task.ExecutionEndpoint || stopped.ExecutionOwner != "" ||
			stopped.OperationID != task.OperationID || stopped.AttemptID != task.AttemptID || stopped.Generation != task.Generation+1 ||
			stopped.CancelRequest != got || stopped.State != task.State || stopped.Outcome != task.Outcome {
			t.Fatalf("stop changed binding or outcome: %+v %v", stopped, err)
		}
	}
}

func TestTaskUnclaimedStopAPIClaimACKLost(t *testing.T) {
	h, _, target, _, fleet := twoNodesCaps(t, control.CapTaskExecution)
	op := postFleet(t, h, "worker_start", map[string]any{"kind": "scratch", "repo": writeRepo,
		"idempotency_key": "claim-ack-lost", "coding_agent": "codex", "control_version": 1}, 200)
	target.mu.Lock()
	snapshot := target.writes[0]["task_execution"].(map[string]any)
	target.mu.Unlock()
	ref := snapshot["task_ref"].(string)
	claim := map[string]any{"control_version": 1, "operation_id": op["operation_id"],
		"worker_id": fleet.FleetID + "/" + wrFid, "generation": snapshot["generation"], "attempt_id": snapshot["attempt_id"]}
	// The node committed a claim and lost its response before writing inventory.
	if code, _ := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, NodeTasksPath+"/"+ref+"/execution/claim", claim); code != 200 {
		t.Fatalf("claim HTTP %d", code)
	}
	task, err := h.srv.Store.FleetTask(store.ParseTaskRef(ref))
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{Store: h.srv.Store}
	r := httptest.NewRequest(http.MethodPost, "http://fleet.test/stop", strings.NewReader(`{"idempotency_key":"claimed-stop"}`))
	w := httptest.NewRecorder()
	s.stopFleetTask(w, r, fleetPrincipal{Actor: task.Owner}, ref)
	var out map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if w.Code != 202 || out["stop_requested"] != true || out["execution_never_started"] == true ||
		out["execution_exit_confirmed"] != false || out["scope"] != nil {
		t.Fatalf("lost claim ACK fabricated proof: %d %v", w.Code, out)
	}
	if st, _ := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, NodeTasksPath+"/"+ref+"/execution/claim", claim); st != 409 {
		t.Fatalf("late claim survived stop: %d", st)
	}
}

func TestTaskUnclaimedStopAPIDeliveryStillCleans(t *testing.T) {
	h, _, target, _, _ := twoNodesCaps(t, control.CapTaskExecution)
	postFleet(t, h, "worker_start", map[string]any{"kind": "scratch", "repo": writeRepo,
		"idempotency_key": "unclaimed-cleanup", "coding_agent": "codex", "control_version": 1}, 200)
	target.mu.Lock()
	snapshot := target.writes[0]["task_execution"].(map[string]any)
	target.mu.Unlock()
	task, err := h.srv.Store.FleetTask(store.ParseTaskRef(snapshot["task_ref"].(string)))
	if err != nil {
		t.Fatal(err)
	}
	observed := make(chan bool, 1)
	target.mu.Lock()
	target.answer = func(env map[string]any) (any, *control.Error) {
		// Preclaim worktree/FID allocations can still need cleanup. Proving no
		// Hub claim must not suppress delivery or pretend those artifacts vanished.
		latest, err := h.srv.Store.TaskUnclaimedStop(task.ID, task.Owner, env["operation_id"].(string))
		observed <- err == nil && latest.CancelRequest == env["operation_id"] && env["action"] == "worker_stop"
		return accepted(env)
	}
	target.mu.Unlock()
	r := httptest.NewRequest(http.MethodPost, "http://fleet.test/stop", strings.NewReader(`{"idempotency_key":"unclaimed-cleanup-stop"}`))
	w := httptest.NewRecorder()
	h.srv.stopFleetTask(w, r, fleetPrincipal{Actor: task.Owner}, task.Ref)
	var out map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if w.Code != 202 || out["execution_never_started"] != true || out["execution_exit_confirmed"] != false || out["delivery"] != "accepted" {
		t.Fatalf("cleanup delivery changed proof: %d %v", w.Code, out)
	}
	select {
	case valid := <-observed:
		if !valid {
			t.Fatal("cleanup delivered without the canonical stop fence")
		}
	case <-time.After(time.Second):
		t.Fatal("proof suppressed best-effort cleanup")
	}
}
