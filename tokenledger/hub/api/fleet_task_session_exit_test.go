package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func sessionExitBody(snapshot store.TaskExecutionSnapshot) map[string]any {
	roots := []map[string]any{}
	for i, component := range []string{"supervisor", "child", "client", "server"} {
		roots = append(roots, map[string]any{"component": component, "pid": 71001 + i,
			"birth": "Fri Oct 23 01:00:00 2026:101", "evidence": "pid_absent"})
	}
	return map[string]any{"control_version": 1, "idempotency_key": "native-exit", "proof": map[string]any{
		"scope": "native_session", "snapshot": snapshot, "provider": "codex", "launch_id": "launch-1",
		"launches": []map[string]any{{"launch_id": "launch-1", "roots": roots}},
		"wrapper":  map[string]any{"pid": 71000, "birth": "Fri Oct 23 01:00:00 2026:100"}, "observed_at": 1792742400,
	}}
}

func sessionExitFixture(t *testing.T) (*harness, *writeNode, store.FleetTask, store.TaskExecutionSnapshot) {
	t.Helper()
	h, _, target, _, fleet := twoNodesCaps(t, control.CapTaskExecution)
	postFleet(t, h, "worker_start", map[string]any{"kind": "scratch", "repo": writeRepo,
		"idempotency_key": "native-start", "coding_agent": "codex", "control_version": 1}, 200)
	target.mu.Lock()
	raw, _ := json.Marshal(target.writes[0]["task_execution"])
	target.mu.Unlock()
	var snapshot store.TaskExecutionSnapshot
	if err := json.Unmarshal(raw, &snapshot); err != nil {
		t.Fatal(err)
	}
	st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, NodeTasksPath+"/"+snapshot.TaskRef+"/execution/claim",
		map[string]any{"control_version": 1, "operation_id": snapshot.OperationID, "worker_id": fleet.FleetID + "/" + wrFid,
			"generation": snapshot.Generation, "attempt_id": snapshot.AttemptID})
	if st != 200 {
		t.Fatalf("claim: %d %v", st, out)
	}
	postFleet(t, h, "tasks/"+snapshot.TaskRef+"/stop", map[string]any{"idempotency_key": "native-stop"}, 202)
	postFleet(t, h, "tasks/"+snapshot.TaskRef+"/stop", map[string]any{"idempotency_key": "native-stop-alias"}, 202)
	task, err := h.srv.Store.FleetTask(store.ParseTaskRef(snapshot.TaskRef))
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err = h.srv.Store.TaskExecutionSnapshot(task.ID, task.Owner)
	if err != nil {
		t.Fatal(err)
	}
	return h, target, task, snapshot
}

func resumeSessionExitForTest(t *testing.T, h *harness, taskID int64, exitID, endpoint string) (store.FleetTask, store.FleetOperation, string) {
	t.Helper()
	got, err := h.srv.Store.FleetTask(taskID)
	if err != nil {
		t.Fatal(err)
	}
	op, err := h.srv.Store.FleetOperation(got.OperationID)
	if err != nil {
		t.Fatal(err)
	}
	var request map[string]any
	_ = json.Unmarshal([]byte(op.Request), &request)
	dispatch := request["params"].(map[string]any)["dispatch"].(map[string]any)
	dispatch["generation"], dispatch["attempt_id"] = got.Generation+1, fmt.Sprintf("task:%s:g%d", got.Ref, got.Generation+1)
	raw, _ := json.Marshal(request)
	op.ID, op.Idem, op.Request, op.Status, op.Result = newOperationID(), "explicit-resume", string(raw), "pending", ""
	op.Created, op.Updated = time.Now(), time.Now()
	resumed, err := h.srv.Store.ResumeTaskExecution(op, endpoint, exitID)
	if err != nil {
		t.Fatal(err)
	}
	worker := op.FleetID + "/44444444-4444-4444-8444-444444444444"
	if _, err := h.srv.Store.ClaimTaskExecution(got.ID, got.Owner, op.ID, endpoint, worker, resumed.Generation, resumed.AttemptID); err != nil {
		t.Fatal(err)
	}
	return resumed, op, worker
}

func TestTaskSessionExitAPIReplayAndReleasedStop(t *testing.T) {
	h, target, task, snapshot := sessionExitFixture(t)
	path := NodeTasksPath + "/" + task.Ref + "/execution/exit"
	body := sessionExitBody(snapshot)
	var exitID string
	for i := 0; i < 2; i++ {
		st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, path, body)
		if st != 200 || out["scope"] != "native_session" || out["execution_exit_confirmed"] != true {
			t.Fatalf("exit: %d %v", st, out)
		}
		id := out["operation"].(map[string]any)["operation_id"].(string)
		if exitID != "" && id != exitID {
			t.Fatal("receipt replay created another operation")
		}
		exitID = id
	}
	got, _ := h.srv.Store.FleetTask(task.ID)
	if got.ExecutionEndpoint != "" || got.ExecutionOwner != "" || got.CancelRequest != snapshot.CancelRequest || got.OperationID != snapshot.OperationID {
		t.Fatalf("exit release: %+v", got)
	}
	writes := target.count()
	for _, key := range []string{"native-stop", "native-stop-alias", "after-exit-alias", "after-exit-alias"} {
		out := postFleet(t, h, "tasks/"+task.Ref+"/stop", map[string]any{"idempotency_key": key}, 202)
		if out["execution_exit_confirmed"] != true || out["scope"] != "native_session" ||
			out["operation"].(map[string]any)["operation_id"] != snapshot.CancelRequest || out["task_execution"] != nil {
			t.Fatalf("released stop HTTP replay: %v", out)
		}
	}
	if target.count() != writes {
		t.Fatal("released stop was delivered again")
	}
	changed := sessionExitBody(snapshot)
	changed["proof"].(map[string]any)["observed_at"] = 1792742500
	if st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, path, changed); st != 409 {
		t.Fatalf("changed evidence reused receipt key: %d %v", st, out)
	}
	// No resume API in this slice. Exercise receipt replay after the existing
	// Store explicitly creates and claims a newer execution binding.
	resumed, op, worker := resumeSessionExitForTest(t, h, task.ID, exitID, snapshot.ExecutionEndpoint)
	if st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, path, body); st != 200 || out["operation"].(map[string]any)["operation_id"] != exitID {
		t.Fatalf("historical receipt replay after resume: %d %v", st, out)
	}
	for _, key := range []string{"native-stop", "native-stop-alias", "after-exit-alias"} {
		postFleet(t, h, "tasks/"+task.Ref+"/stop", map[string]any{"idempotency_key": key}, 409)
	}
	freshKey := sessionExitBody(snapshot)
	freshKey["idempotency_key"] = "late-new-key"
	if st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, path, freshKey); st != 409 {
		t.Fatalf("old proof with fresh key released new binding: %d %v", st, out)
	}
	got, _ = h.srv.Store.FleetTask(task.ID)
	if got.OperationID != op.ID || got.ExecutionOwner != worker || got.Generation != resumed.Generation || got.CancelRequest != "" {
		t.Fatalf("old proof or stop changed new binding: %+v", got)
	}
}

func TestTaskSessionExitAPIStopAcceptanceRace(t *testing.T) {
	h, target, stopped, snapshot := sessionExitFixture(t)
	stop, err := h.srv.Store.FleetOperation(snapshot.CancelRequest)
	if err != nil {
		t.Fatal(err)
	}
	// RequestTaskStop has committed. The node's real HTTP receipt wins before
	// the handler reads the active snapshot, then an explicit resume can win too.
	st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost,
		NodeTasksPath+"/"+stopped.Ref+"/execution/exit", sessionExitBody(snapshot))
	if st != 200 {
		t.Fatalf("exit before stop response: %d %v", st, out)
	}
	exitID := out["operation"].(map[string]any)["operation_id"].(string)
	writes := target.count()
	for _, resume := range []bool{false, true} {
		if resume {
			resumeSessionExitForTest(t, h, stopped.ID, exitID, snapshot.ExecutionEndpoint)
		}
		r := httptest.NewRequest(http.MethodPost, FleetTasksPath+"/"+stopped.Ref+"/stop", nil)
		w := httptest.NewRecorder()
		h.srv.finishTaskStop(w, r, stopped, stop)
		var response map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &response)
		if w.Code != 202 || response["stop_requested"] != true || response["task_execution"] != nil ||
			response["operation"].(map[string]any)["operation_id"] != stop.ID || target.count() != writes {
			t.Fatalf("accepted stop lost race (resume=%v): %d %v writes=%d/%d", resume, w.Code, response, writes, target.count())
		}
	}
}

func TestTaskSessionExitAPIEndpointAndUserAuthentication(t *testing.T) {
	h, _, task, snapshot := sessionExitFixture(t)
	path := NodeTasksPath + "/" + task.Ref + "/execution/exit"
	body := sessionExitBody(snapshot)
	otherLogin := enrollAs(t, h, "mac-c-other-login", "mac-c", "other-login")
	for _, token := range []string{h.tokens["mac-d"], otherLogin} {
		if st, out := nodeTaskCall(t, h, token, http.MethodPost, path, body); st != 404 {
			t.Fatalf("sibling endpoint/login reported exit: %d %v", st, out)
		}
	}
	forged := snapshot
	forged.ExecutionEndpoint = "ep_mac-d"
	if st, out := nodeTaskCall(t, h, h.tokens["mac-d"], http.MethodPost, path, sessionExitBody(forged)); st != 409 {
		t.Fatalf("sibling self-reported endpoint claimed foreign fleet: %d %v", st, out)
	}
	for _, token := range []string{"", viewerToken} {
		if st, out := nodeTaskCall(t, h, token, http.MethodPost, path, body); st != 401 {
			t.Fatalf("non-node bearer reported exit: %d %v", st, out)
		}
	}
	raw, _ := json.Marshal(body)
	r, _ := http.NewRequest(http.MethodPost, h.http.URL+path, bytes.NewReader(raw))
	r.AddCookie(personCookie(pAlice, "alice"))
	r.Header.Set("Content-Type", "application/json")
	resp, err := h.http.Client().Do(r)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 401 {
		t.Fatalf("person cookie reported node exit: %d", resp.StatusCode)
	}
	if st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, path, body); st != 200 {
		t.Fatalf("own endpoint exit: %d %v", st, out)
	}
	// Release must not turn the same proof into permission for a sibling node.
	if st, out := nodeTaskCall(t, h, h.tokens["mac-d"], http.MethodPost, path, body); st != 404 {
		t.Fatalf("sibling replay after release: %d %v", st, out)
	}
}

func TestTaskSessionExitAPINodeSignature(t *testing.T) {
	h, _, task, snapshot := sessionExitFixture(t)
	node := newSigNode(t)
	if st, out := sigCall(t, h, "Bearer "+h.tokens["mac-c"], http.MethodPost, NodeKeyPath,
		map[string]any{"public_key": node.pub, "proof": node.proof(), "bearer_off": true}); st != 200 {
		t.Fatalf("register node signature: %d %v", st, out)
	}
	path := NodeTasksPath + "/" + task.Ref + "/execution/exit"
	body := sessionExitBody(snapshot)
	if st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, path, body); st != 401 {
		t.Fatalf("disabled bearer reported exit: %d %v", st, out)
	}
	var id any
	for _, nonce := range []string{"native-exit-aaaaaaaaaaaa", "native-exit-bbbbbbbbbbbb"} {
		header := node.header(http.MethodPost, path, nonce, time.Now())
		st, out := sigCall(t, h, header, http.MethodPost, path, body)
		if st != 200 || id != nil && out["operation"].(map[string]any)["operation_id"] != id {
			t.Fatalf("signed receipt/replay: %d %v", st, out)
		}
		id = out["operation"].(map[string]any)["operation_id"]
		if st, out := sigCall(t, h, header, http.MethodPost, path, body); st != 401 {
			t.Fatalf("transport nonce replay accepted: %d %v", st, out)
		}
	}
}

func TestTaskSessionExitAPIRejectsSpoofedAndPartialProof(t *testing.T) {
	h, _, task, snapshot := sessionExitFixture(t)
	path := NodeTasksPath + "/" + task.Ref + "/execution/exit"
	for _, field := range []string{"endpoint", "execution_endpoint", "login", "owner"} {
		body := sessionExitBody(snapshot)
		body[field] = "spoofed"
		if st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, path, body); st != 400 {
			t.Fatalf("caller-defined %s accepted: %d %v", field, st, out)
		}
	}
	for _, field := range []string{"task", "fid", "worker", "start", "stop", "generation", "endpoint"} {
		wrong := snapshot
		switch field {
		case "task":
			wrong.TaskRef = "T99999"
		case "fid":
			wrong.TaskFID = "44444444-4444-4444-8444-444444444444"
		case "worker":
			wrong.ExecutionOwner = snapshot.ExecutionOwner[:37] + "44444444-4444-4444-8444-444444444444"
		case "start":
			wrong.OperationID = "wrong-start"
		case "stop":
			wrong.CancelRequest = "wrong-stop"
		case "generation":
			wrong.BindingGeneration++
		case "endpoint":
			wrong.ExecutionEndpoint = "ep_mac-d"
		}
		if st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, path, sessionExitBody(wrong)); st < 400 || st >= 500 {
			t.Fatalf("wrong %s accepted: %d %v", field, st, out)
		}
	}
	for _, field := range []string{"scope", "launches", "wrapper", "observed_at"} {
		body := sessionExitBody(snapshot)
		delete(body["proof"].(map[string]any), field)
		if st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, path, body); st != 400 {
			t.Fatalf("missing proof %s: %d %v", field, st, out)
		}
	}
	got, _ := h.srv.Store.FleetTask(task.ID)
	if got.ExecutionOwner != snapshot.ExecutionOwner || got.ExecutionEndpoint != snapshot.ExecutionEndpoint {
		t.Fatalf("rejected requests released binding: %+v", got)
	}
}

func TestTaskSessionExitAPIBoundedEpochHistory(t *testing.T) {
	h, _, task, snapshot := sessionExitFixture(t)
	path := NodeTasksPath + "/" + task.Ref + "/execution/exit"
	oversized := sessionExitBody(snapshot)
	oversized["proof"].(map[string]any)["wrapper"].(map[string]any)["birth"] = strings.Repeat("x", taskSessionExitBodyLimit)
	if st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, path, oversized); st != 400 {
		t.Fatalf("unbounded proof accepted: %d %v", st, out)
	}
	body := sessionExitBody(snapshot)
	proof := body["proof"].(map[string]any)
	current := proof["launches"].([]map[string]any)[0]
	var launches []map[string]any
	for i := 0; i < 60; i++ {
		launches = append(launches, map[string]any{"launch_id": fmt.Sprintf("historical-%d", i), "roots": current["roots"]})
	}
	proof["launches"] = append(launches, current)
	raw, _ := json.Marshal(body)
	if len(raw) <= 16<<10 {
		t.Fatal("fixture did not exceed the command body limit")
	}
	if st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, path, body); st != 200 {
		t.Fatalf("native epoch history truncated: %d %v", st, out)
	}
}

func TestTaskSessionExitAPIEpochComponents(t *testing.T) {
	for _, tc := range []struct {
		name, provider   string
		current, history []string
		duplicateLaunch  bool
		want             int
	}{
		{"missing-native", "codex", []string{"supervisor", "child"}, nil, false, 400},
		{"missing-server", "codex", []string{"supervisor", "child", "client"}, nil, false, 400},
		{"missing-client", "codex", []string{"supervisor", "child", "server"}, nil, false, 400},
		{"unknown", "codex", []string{"supervisor", "child", "server", "client", "other"}, nil, false, 400},
		{"duplicate-component", "codex", []string{"supervisor", "child", "server", "client", "client"}, nil, false, 400},
		{"mixed-native", "codex", []string{"supervisor", "child", "server", "client", "agent"}, nil, false, 400},
		{"claude-missing-agent", "claude", []string{"supervisor", "child"}, nil, false, 400},
		{"claude-wrong-native", "claude", []string{"supervisor", "child", "server", "client"}, nil, false, 400},
		{"history-missing-supervisor", "codex", nil, []string{"child", "server"}, false, 400},
		{"history-missing-child", "codex", nil, []string{"supervisor", "server"}, false, 400},
		{"history-mixed-native", "codex", nil, []string{"supervisor", "child", "agent", "client"}, false, 400},
		{"duplicate-launch", "codex", nil, []string{"supervisor", "child"}, true, 400},
		{"history-before-native", "codex", nil, []string{"supervisor", "child"}, false, 200},
		{"history-server-only", "codex", nil, []string{"supervisor", "child", "server"}, false, 200},
		{"history-client-only", "codex", nil, []string{"supervisor", "child", "client"}, false, 200},
		{"history-provider-switch", "codex", nil, []string{"supervisor", "child", "agent"}, false, 200},
		{"claude-complete", "claude", []string{"supervisor", "child", "agent"}, nil, false, 200},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h, _, task, snapshot := sessionExitFixture(t)
			body := sessionExitBody(snapshot)
			proof := body["proof"].(map[string]any)
			proof["provider"] = tc.provider
			launches := proof["launches"].([]map[string]any)
			roots := func(components []string) []map[string]any {
				var out []map[string]any
				for i, component := range components {
					out = append(out, map[string]any{"component": component, "pid": 72000 + i,
						"birth": "Fri Oct 23 01:00:00 2026:101", "evidence": "pid_absent"})
				}
				return out
			}
			if tc.current != nil {
				launches[0]["roots"] = roots(tc.current)
			}
			if tc.history != nil {
				id := "historical"
				if tc.duplicateLaunch {
					id = "launch-1"
				}
				launches = append([]map[string]any{{"launch_id": id, "roots": roots(tc.history)}}, launches...)
			}
			proof["launches"] = launches
			if st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost,
				NodeTasksPath+"/"+task.Ref+"/execution/exit", body); st != tc.want {
				t.Fatalf("exit epoch shape: %d %v, want %d", st, out, tc.want)
			}
			got, err := h.srv.Store.FleetTask(task.ID)
			if err != nil {
				t.Fatal(err)
			}
			if tc.want == 400 && (got.ExecutionOwner != snapshot.ExecutionOwner || got.ExecutionEndpoint != snapshot.ExecutionEndpoint) {
				t.Fatal("invalid proof released execution")
			}
		})
	}
}

func TestTaskSessionExitAPIHistoricalInventory(t *testing.T) {
	for _, mutation := range []string{"delete", "move"} {
		for _, accepted := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/accepted=%v", mutation, accepted), func(t *testing.T) {
				h, _, task, snapshot := sessionExitFixture(t)
				path := NodeTasksPath + "/" + task.Ref + "/execution/exit"
				body := sessionExitBody(snapshot)
				var id any
				if accepted {
					st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, path, body)
					if st != 200 {
						t.Fatalf("initial exit: %d %v", st, out)
					}
					id = out["operation"].(map[string]any)["operation_id"]
				}
				fleet := strings.Split(snapshot.ExecutionOwner, "/")[0]
				query := `DELETE FROM fleet_fleets WHERE fleet_id = ?`
				if mutation == "move" {
					query = `UPDATE fleet_fleets SET machine_id = (SELECT machine_id FROM fleet_machines WHERE endpoint_id = 'ep_mac-d') WHERE fleet_id = ?`
				}
				if _, err := h.srv.Store.DB().Exec(query, fleet); err != nil {
					t.Fatal(err)
				}
				st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, path, body)
				if st != 200 {
					t.Fatalf("original endpoint lost historical authority: %d %v", st, out)
				}
				if id != nil && out["operation"].(map[string]any)["operation_id"] != id {
					t.Fatal("inventory change replaced accepted receipt")
				}
				forged := snapshot
				forged.ExecutionEndpoint = "ep_mac-d"
				if st, out := nodeTaskCall(t, h, h.tokens["mac-d"], http.MethodPost, path, sessionExitBody(forged)); st != 409 {
					t.Fatalf("inventory change transferred historical authority: %d %v", st, out)
				}
			})
		}
	}
}
