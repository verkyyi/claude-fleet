package api

import (
	"encoding/json"
	"net/http"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

func TestTaskParentNodeWriteRetired(t *testing.T) {
	h, _, nodes := peerHarness(t)
	in := map[string]any{"authority_version": 1, "token": "parent-retired", "title": "independent", "requested_agent": "codex", "resolved_agent": "codex", "parent_task": "missing-old-parent", "parent_session": "retired/session", "request_payload": map[string]any{"body": map[string]any{"parent_task": "user value"}}}
	code, rec := nodeTaskCall(t, h, nodes["bob4"].token, http.MethodPost, NodeTasksPath, in)
	if code != 200 {
		t.Fatalf("legacy transport input should be ignored: %d %v", code, rec)
	}
	if rec["parent_task"] != nil || rec["parent_session"] != nil {
		t.Fatalf("new relationship: %v", rec)
	}
	delete(in, "parent_task")
	delete(in, "parent_session")
	code, again := nodeTaskCall(t, h, nodes["bob4"].token, http.MethodPost, NodeTasksPath, in)
	if code != 200 || again["id"] != rec["id"] {
		t.Fatalf("replay: %d %v", code, again)
	}
	// Actual historical accepted bytes and columns survive an HTTP replay.
	var original string
	id := store.ParseTaskRef(rec["id"].(string))
	if err := h.srv.Store.DB().QueryRow(`SELECT accepted_request FROM fleet_tasks WHERE id=?`, id).Scan(&original); err != nil {
		t.Fatal(err)
	}
	var old map[string]any
	json.Unmarshal([]byte(original), &old)
	old["ParentTask"], old["ParentSession"] = "T999", "old/session"
	bytes, _ := json.MarshalIndent(old, "", "  ")
	if _, err := h.srv.Store.DB().Exec(`UPDATE fleet_tasks SET accepted_request=?, parent_task='T999', parent_session='old/session', parent_generation=9 WHERE id=?`, string(bytes), id); err != nil {
		t.Fatal(err)
	}
	code, again = nodeTaskCall(t, h, nodes["bob4"].token, http.MethodPost, NodeTasksPath, in)
	if code != 200 || again["id"] != rec["id"] || again["parent_task"] != "T999" {
		t.Fatalf("historical replay: %d %v", code, again)
	}
	in["request_payload"] = map[string]any{"body": map[string]any{"parent_task": "different user value"}}
	if code, out := nodeTaskCall(t, h, nodes["bob4"].token, http.MethodPost, NodeTasksPath, in); code != 409 {
		t.Fatalf("user payload difference: %d %v", code, out)
	}
	var after string
	if err := h.srv.Store.DB().QueryRow(`SELECT accepted_request FROM fleet_tasks WHERE id=?`, id).Scan(&after); err != nil || after != string(bytes) {
		t.Fatal("historical accepted_request rewritten", err)
	}
	var count int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_tasks WHERE owner=?`, rec["owner"]).Scan(&count); err != nil || count != 1 {
		t.Fatalf("replay created another task: %d %v", count, err)
	}
}

func TestTaskParentOperationReplayRetired(t *testing.T) {
	args := map[string]any{"idempotency_key": "old-start", "kind": "scratch", "no_repo": true, "name": "same task", "body": "parent_task is user text"}
	w, _, err := parseWrite("worker_start", args)
	if err != nil {
		t.Fatal(err)
	}
	var old map[string]any
	json.Unmarshal([]byte(w.canonical), &old)
	old["params"].(map[string]any)["origin_wid"] = wrFleetM5 + "/" + wrFid
	raw, _ := json.Marshal(old)
	op := store.FleetOperation{ID: "original-operation", Action: "worker_start", Request: string(raw), Status: "accepted"}
	got, err := replayDispatch(op, w)
	if err != nil || got["operation_id"] != op.ID {
		t.Fatalf("old operation replay: %v %v", got, err)
	}
	if op.Request != string(raw) {
		t.Fatal("historical operation rewritten")
	}
	args["body"] = "changed parent_task user text"
	w, _, err = parseWrite("worker_start", args)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = replayDispatch(op, w); err == nil || errorObject(err)["code"] != "IDEMPOTENCY_CONFLICT" {
		t.Fatalf("user input change accepted: %v", err)
	}
}

func TestTaskParentWriteParamsRetired(t *testing.T) {
	w, _, err := parseWrite("worker_start", map[string]any{"idempotency_key": "new-start", "kind": "scratch", "no_repo": true, "origin_wid": wrFleetM5 + "/" + wrFid})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := w.params["origin_wid"]; ok {
		t.Fatal("origin_wid still forwarded to node")
	}
}

func TestTaskParentAcceptedDispatchReplay(t *testing.T) {
	s := &Server{Store: openTestStore(t)}
	if err := s.Store.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	p := fleetPrincipal{Actor: "operator"}
	args := map[string]any{"idempotency_key": "historical-dispatch", "kind": "scratch", "no_repo": true, "coding_agent": "codex", "body": "original user text"}
	w, _, err := parseWrite("worker_start", args)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.acceptDispatch(p, &w); err != nil {
		t.Fatal(err)
	}
	dispatch := w.params["dispatch"].(*dispatchChoice)
	task, err := s.Store.FleetTask(store.ParseTaskRef(dispatch.Task))
	if err != nil {
		t.Fatal(err)
	}
	var old map[string]any
	json.Unmarshal([]byte(task.RequestPayload), &old)
	old["params"].(map[string]any)["origin_wid"] = "retired/session"
	raw, _ := json.Marshal(old)
	if _, err := s.Store.DB().Exec(`UPDATE fleet_tasks SET parent_session='retired/session', request_payload=? WHERE id=?`, string(raw), task.ID); err != nil {
		t.Fatal(err)
	}
	args["dispatch"] = dispatch
	replay, _, err := parseWrite("worker_start", args)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.acceptDispatch(p, &replay); err != nil {
		t.Fatalf("old accepted dispatch: %v", err)
	}
	if replay.params["task"] != task.Ref || replay.params["origin_wid"] != nil {
		t.Fatal("replay changed task or restored Parent")
	}
	args["body"] = "changed user text"
	changed, _, err := parseWrite("worker_start", args)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.acceptDispatch(p, &changed); err == nil || errorObject(err)["code"] != "IDEMPOTENCY_CONFLICT" {
		t.Fatalf("changed old dispatch: %v", err)
	}
	// The operation replay restores its accepted Task identity, then compares
	// the transport projection without modifying the historical journal.
	var operation map[string]any
	json.Unmarshal([]byte(w.canonical), &operation)
	operation["params"].(map[string]any)["origin_wid"] = "retired/session"
	operationRaw, _ := json.Marshal(operation)
	op := store.FleetOperation{ID: "accepted-operation", Action: "worker_start", Request: string(operationRaw), Status: "accepted"}
	args["body"] = "original user text"
	delete(args, "dispatch")
	replay, _, err = parseWrite("worker_start", args)
	if err != nil {
		t.Fatal(err)
	}
	if out, err := replayDispatch(op, replay); err != nil || out["operation_id"] != op.ID {
		t.Fatalf("operation replay with Task identity: %v %v", out, err)
	}
	after, err := s.Store.FleetTask(task.ID)
	if err != nil || after.RequestPayload != string(raw) || after.ParentSession != "retired/session" {
		t.Fatal("historical task mutated", err)
	}
}
