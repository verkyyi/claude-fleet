package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func TestTaskExecutionAPIRemoteAndClaim(t *testing.T) {
	h, first, target, f5, f4 := twoNodesCaps(t, control.CapTaskExecution)
	args := map[string]any{"kind": "scratch", "repo": writeRepo, "idempotency_key": "execution-remote", "coding_agent": "codex", "control_version": 1}
	op := postFleet(t, h, "worker_start", args, 200)
	target.mu.Lock()
	env := target.writes[0]
	target.mu.Unlock()
	snapshot := env["task_execution"].(map[string]any)
	ref := snapshot["task_ref"].(string)
	if env["control_version"] != float64(1) || snapshot["operation_id"] != op["operation_id"] || snapshot["execution_owner"] != "" {
		t.Fatalf("grant: %v", env)
	}
	postFleet(t, h, "worker_start", args, 200)
	if target.count() != 1 || first.count() != 0 {
		t.Fatal("replay dispatched twice")
	}
	route := NodeTasksPath + "/" + ref + "/execution"
	if st, out := nodeTaskCall(t, h, h.tokens["mac-d"], http.MethodGet, route, nil); st != 404 {
		t.Fatalf("sibling read: %d %v", st, out)
	}
	if st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodGet, route, nil); st != 200 || out["operation_id"] != op["operation_id"] {
		t.Fatalf("snapshot: %d %v", st, out)
	}
	claim := map[string]any{"control_version": 1, "operation_id": op["operation_id"], "worker_id": f5.FleetID + "/" + wrFid, "generation": snapshot["generation"], "attempt_id": snapshot["attempt_id"]}
	if st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, route+"/claim", claim); st != 400 {
		t.Fatalf("foreign fleet claim: %d %v", st, out)
	}
	claim["worker_id"] = f4.FleetID + "/" + wrFid
	claim["endpoint"] = "spoofed"
	if st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, route+"/claim", claim); st != 400 {
		t.Fatalf("endpoint spoof: %d %v", st, out)
	}
	delete(claim, "endpoint")
	for i := 0; i < 2; i++ {
		if st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, route+"/claim", claim); st != 200 || out["execution_owner"] != claim["worker_id"] {
			t.Fatalf("claim: %d %v", st, out)
		}
	}
	claim["worker_id"] = f4.FleetID + "/44444444-4444-4444-8444-444444444444"
	if st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, route+"/claim", claim); st != 409 {
		t.Fatalf("second worker: %d %v", st, out)
	}
}

func TestTaskExecutionAPICapabilityAndLocal(t *testing.T) {
	t.Run("old task capability refuses", func(t *testing.T) {
		h, first, target, _, _ := twoNodesCaps(t, control.CapTask)
		args := map[string]any{"kind": "scratch", "repo": writeRepo, "idempotency_key": "old-cap", "coding_agent": "codex", "control_version": 1}
		postFleet(t, h, "worker_start", args, 503)
		if first.count()+target.count() != 0 {
			t.Fatal("old node received controlled start")
		}
	})
	t.Run("local reserves before response", func(t *testing.T) {
		h, _, target, _, f4 := twoNodesCaps(t, control.CapTaskExecution)
		input := map[string]any{"kind": "scratch", "repo": writeRepo, "fleet_id": f4.FleetID, "node": "mac-c", "idempotency_key": "local-control", "coding_agent": "codex", "control_version": 1, "local_dispatch": true}
		st, out := placeCall(t, h, h.tokens["mac-c"], input)
		if st != 200 || out["local"] != true || out["operation_id"] == nil {
			t.Fatalf("LOCAL: %d %v", st, out)
		}
		snapshot := out["task_execution"].(map[string]any)
		rec, e := h.srv.Store.FleetTask(store.ParseTaskRef(snapshot["task_ref"].(string)))
		if e != nil || rec.OperationID != out["operation_id"] || rec.ExecutionEndpoint == "" || target.count() != 0 {
			t.Fatalf("LOCAL not reserved: %+v %v", rec, e)
		}
		st, again := placeCall(t, h, h.tokens["mac-c"], input)
		if st != 200 || again["operation_id"] != out["operation_id"] {
			t.Fatalf("LOCAL replay: %d %v", st, again)
		}
		_, _, e = h.srv.Store.RequestTaskStop(rec.ID, rec.Owner, "stop-local", "user stop", time.Now())
		if e != nil {
			t.Fatal(e)
		}
		st, out = placeCall(t, h, h.tokens["mac-c"], input)
		if st == 200 {
			t.Fatalf("stopped local reauthorized: %v", out)
		}
	})
}

func TestTaskExecutionAPIStopOfflineCanonical(t *testing.T) {
	h, _, target, _, _ := twoNodesCaps(t, control.CapTaskExecution)
	op := postFleet(t, h, "worker_start", map[string]any{"kind": "scratch", "repo": writeRepo, "idempotency_key": "offline-stop", "coding_agent": "codex", "control_version": 1}, 200)
	target.mu.Lock()
	snapshot := target.writes[0]["task_execution"].(map[string]any)
	target.mu.Unlock()
	rec, e := h.srv.Store.FleetTask(store.ParseTaskRef(snapshot["task_ref"].(string)))
	if e != nil {
		t.Fatal(e)
	}
	// A separate server using the same store has no connection or peer directory.
	s := &Server{Store: h.srv.Store}
	var stopID any
	for _, key := range []string{"stop-one", "stop-two", "stop-one"} {
		r := httptest.NewRequest(http.MethodPost, "http://fleet.test/stop", strings.NewReader(`{"idempotency_key":"`+key+`"}`))
		w := httptest.NewRecorder()
		s.stopFleetTask(w, r, fleetPrincipal{Actor: rec.Owner}, rec.Ref)
		var out map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &out)
		if w.Code != 202 || out["stop_requested"] != true || out["execution_exit_confirmed"] != false {
			t.Fatalf("offline stop: %d %v", w.Code, out)
		}
		got := out["operation"].(map[string]any)["operation_id"]
		if stopID != nil && got != stopID {
			t.Fatal("stop alias returned as executable operation")
		}
		stopID = got
	}
	start, e := s.Store.FleetOperation(op["operation_id"].(string))
	if e != nil || !strings.Contains(start.Result, "TASK_CANCELLED") {
		t.Fatalf("start not fenced: %+v %v", start, e)
	}
}

func TestTaskExecutionAPIStopBeforeDelivery(t *testing.T) {
	h, _, target, _, _ := twoNodesCaps(t, control.CapTaskExecution)
	postFleet(t, h, "worker_start", map[string]any{"kind": "scratch", "repo": writeRepo, "idempotency_key": "online-stop", "coding_agent": "codex", "control_version": 1}, 200)
	target.mu.Lock()
	snap := target.writes[0]["task_execution"].(map[string]any)
	target.mu.Unlock()
	rec, e := h.srv.Store.FleetTask(store.ParseTaskRef(snap["task_ref"].(string)))
	if e != nil {
		t.Fatal(e)
	}
	observed := make(chan bool, 1)
	target.mu.Lock()
	target.answer = func(env map[string]any) (any, *control.Error) {
		latest, err := h.srv.Store.TaskExecutionSnapshot(rec.ID, rec.Owner)
		sent, _ := env["task_execution"].(map[string]any)
		observed <- err == nil && latest.CancelRequest == env["operation_id"] && latest.Generation > latest.BindingGeneration && sent["cancel_request"] == latest.CancelRequest && env["action"] == "worker_stop"
		return accepted(env)
	}
	target.mu.Unlock()
	r := httptest.NewRequest(http.MethodPost, "http://fleet.test/stop", strings.NewReader(`{"idempotency_key":"online-stop-click"}`))
	w := httptest.NewRecorder()
	h.srv.stopFleetTask(w, r, fleetPrincipal{Actor: rec.Owner}, rec.Ref)
	var out map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	if w.Code != 202 || out["execution_exit_confirmed"] != false || out["delivery"] != "accepted" {
		t.Fatalf("stop: %d %v", w.Code, out)
	}
	if !<-observed {
		t.Fatal("network stop preceded durable stop fence")
	}
}

func TestTaskExecutionAPIControlledPlacementNeverFallsBack(t *testing.T) {
	h, first, target, f5, _ := twoNodesCaps(t, control.CapTaskExecution)
	target.setOpGet(finished("failed", map[string]any{"exit": 1, "stderr": "declined"}))
	st, out := placeCall(t, h, h.tokens["mac-d"], map[string]any{"kind": "scratch", "repo": writeRepo, "fleet_id": f5.FleetID, "node": "auto", "coding_agent": "codex", "control_version": 1, "idempotency_key": "no-fallback", "local_dispatch": true, "tries": 3})
	if st != 200 || out["local"] != false || first.count() != 0 || target.count() != 1 {
		t.Fatalf("controlled fallback: %d %v writes %d/%d", st, out, first.count(), target.count())
	}
	snapshot := target.writes[0]["task_execution"].(map[string]any)
	rec, e := h.srv.Store.FleetTask(store.ParseTaskRef(snapshot["task_ref"].(string)))
	if e != nil || rec.OperationID == "" || rec.ExecutionEndpoint != "ep_mac-c" {
		t.Fatalf("failure released binding: %+v %v", rec, e)
	}
}

func TestTaskExecutionAPIStopOwnerMiddleware(t *testing.T) {
	s := &Server{Store: openTestStore(t), LiveStore: NewLive(), ViewerToken: viewerToken, Fleet: true}
	if e := s.Store.EnsureNodes(); e != nil {
		t.Fatal(e)
	}
	enablePeople(t, &harness{srv: s}, pAlice, pBob)
	wr, _, e := parseWrite("worker_start", map[string]any{"kind": "scratch", "no_repo": true, "coding_agent": "codex", "idempotency_key": "owner-stop", "control_version": 1})
	if e != nil {
		t.Fatal(e)
	}
	if e = s.acceptDispatch(fleetPrincipal{Actor: pAlice, Person: pAlice}, &wr); e != nil {
		t.Fatal(e)
	}
	now := time.Now()
	task, e := s.Store.AuthorizeTaskExecution(store.FleetOperation{ID: newOperationID(), FleetID: wrFleetM5, Action: "worker_start", Request: wr.canonical, Actor: pAlice, TaskOwner: pAlice, Idem: "owner-stop", Status: "pending", Created: now, Updated: now}, "offline-endpoint")
	if e != nil {
		t.Fatal(e)
	}
	handler := s.Handler()
	call := func(cookie *http.Cookie, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodPost, "http://fleet.test"+FleetTasksPath+"/"+task.Ref+"/stop", strings.NewReader(body))
		r.Header.Set("Origin", "http://fleet.test")
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Accept", "application/json")
		if cookie != nil {
			r.AddCookie(cookie)
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	ro := &http.Cookie{Name: authz.CookieName, Value: authz.SignReadOnly(store.IdentityGitHub, pAlice, "alice", roleUser, s.sessionKey(), time.Now(), time.Hour)}
	for _, tc := range []struct {
		cookie *http.Cookie
		want   int
	}{{nil, 401}, {personCookie(pBob, "bob"), 404}, {ro, 403}} {
		w := call(tc.cookie, `{"idempotency_key":"stop"}`)
		if w.Code != tc.want {
			t.Fatalf("stop auth: %d %s", w.Code, w.Body.String())
		}
	}
	owner := personCookie(pAlice, "alice")
	for _, body := range []string{`null`, `{"idempotency_key":"stop","endpoint":"spoof"}`, `{"idempotency_key":"stop"} {}`} {
		w := call(owner, body)
		if w.Code != 400 {
			t.Fatalf("invalid body: %d %s", w.Code, w.Body.String())
		}
	}
	before, _ := s.Store.FleetTask(task.ID)
	if before.CancelRequest != "" {
		t.Fatal("refused caller persisted stop")
	}
	w := call(owner, `{"idempotency_key":"stop"}`)
	if w.Code != 202 {
		t.Fatalf("owner offline stop: %d %s", w.Code, w.Body.String())
	}
}

func TestTaskExecutionAPIReplacementCapability(t *testing.T) {
	h, _, _, _, f4 := twoNodesCaps(t, control.CapTask)
	fl, e := h.srv.Store.Fleet(f4.FleetID)
	if e != nil {
		t.Fatal(e)
	}
	op := store.FleetOperation{ID: newOperationID(), FleetID: f4.FleetID, Action: "worker_start", Request: `{"control_version":1}`}
	status, result := h.srv.sendWrite(context.Background(), fl, op, map[string]any{"control_version": 1})
	if status != "failed" || !strings.Contains(result, "replacement node") {
		t.Fatalf("late capability gate: %s %s", status, result)
	}
}

func TestTaskExecutionAPIClientPlacement(t *testing.T) {
	h, _, target, _, _ := twoNodesCaps(t, control.CapTaskExecution)
	lease, key := clientLeaseFor(t, h)
	input := map[string]any{"repo": writeRepo, "kind": "scratch", "coding_agent": "codex", "control_version": 1, "idempotency_key": "controlled-client"}
	st, out := clientPlace(t, h, lease, key, input)
	if st != 200 || out.OperationID == "" {
		t.Fatalf("client placement: %d %+v", st, out)
	}
	target.mu.Lock()
	env := target.writes[0]
	target.mu.Unlock()
	if env["control_version"] != float64(1) || env["task_execution"] == nil {
		t.Fatalf("client lost control protocol: %v", env)
	}
	input["kind"] = "restore"
	input["key"] = "scratch-1"
	if st, _ := clientPlace(t, h, lease, key, input); st != 400 {
		t.Fatalf("restore adopted task: %d", st)
	}
}

func TestTaskExecutionAPIReconnectRedeliversCanonicalStop(t *testing.T) {
	h, _, target, _, _ := twoNodesCaps(t, control.CapTaskExecution)
	postFleet(t, h, "worker_start", map[string]any{"kind": "scratch", "repo": writeRepo, "idempotency_key": "reconnect-start", "coding_agent": "codex", "control_version": 1}, 200)
	target.mu.Lock()
	snap := target.writes[0]["task_execution"].(map[string]any)
	target.mu.Unlock()
	rec, e := h.srv.Store.FleetTask(store.ParseTaskRef(snap["task_ref"].(string)))
	if e != nil {
		t.Fatal(e)
	}
	_, stop, e := h.srv.Store.RequestTaskStop(rec.ID, rec.Owner, "reconnect-stop", "user stop", time.Now())
	if e != nil {
		t.Fatal(e)
	}
	if e = h.srv.Store.UpdateFleetOperation(stop.ID, "failed", `{"error":{"code":"UNAVAILABLE"}}`, time.Now()); e != nil {
		t.Fatal(e)
	}
	next := connectWriteNodeCaps(t, h, h.tokens["mac-c"], control.CapRead, control.CapWrite, control.CapTaskExecution)
	waitFor(t, 3*time.Second, "canonical stop replay after reconnect", func() bool { return next.count() == 1 })
	next.mu.Lock()
	env := next.writes[0]
	next.mu.Unlock()
	if env["operation_id"] != stop.ID || env["action"] != "worker_stop" || env["evidence"] != nil || env["task_execution"].(map[string]any)["cancel_request"] != stop.ID {
		t.Fatalf("reconnect envelope: %v", env)
	}
	st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodGet, NodeTasksPath+"/executions", nil)
	snapshots, _ := out["task_executions"].([]any)
	if st != 200 || len(snapshots) != 1 || snapshots[0].(map[string]any)["cancel_request"] != stop.ID {
		t.Fatalf("snapshot roster: %d %v", st, out)
	}
	st, out = nodeTaskCall(t, h, h.tokens["mac-d"], http.MethodGet, NodeTasksPath+"/executions", nil)
	snapshots, _ = out["task_executions"].([]any)
	if st != 200 || len(snapshots) != 0 {
		t.Fatalf("sibling roster leak: %d %v", st, out)
	}
	persisted, e := h.srv.Store.FleetTask(rec.ID)
	if e != nil || persisted.OperationID == "" || persisted.CancelRequest != stop.ID {
		t.Fatalf("reconnect released binding: %+v %v", persisted, e)
	}
}
