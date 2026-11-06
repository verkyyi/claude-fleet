package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func retryFixtureTask(t *testing.T, h *harness, title string, blank bool) store.FleetTask {
	t.Helper()
	payload, _ := json.Marshal(map[string]any{"dispatch": dispatchChoice{Version: 1, RequestID: "retry-accepted", RequestedAgent: "codex", ResolvedAgent: "codex", AgentSource: "explicit"},
		"title": title, "body": "", "blank": blank, "repo": writeRepo})
	task, err := h.srv.Store.CreateFleetTask(store.FleetTask{Owner: "operator", Title: title, Repo: writeRepo, AuthorityVersion: 1,
		RequestedAgent: "codex", ResolvedAgent: "codex", RequestPayload: string(payload)}, "retry-accepted", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return task
}

func TestTaskStartRetrySameRecordAndReplay(t *testing.T) {
	h, first, target, _, _ := twoNodesCaps(t, control.CapTaskExecution)
	task := retryFixtureTask(t, h, strings.Repeat("长", 80), false)
	out := postFleet(t, h, "tasks/"+task.Ref+"/retry-start", map[string]any{"expected_generation": task.Generation}, 202)
	again := postFleet(t, h, "tasks/"+task.Ref+"/retry-start", map[string]any{"expected_generation": task.Generation}, 202)
	if out["operation_id"] != again["operation_id"] || first.count()+target.count() != 1 {
		t.Fatalf("duplicate start: %v %v", out, again)
	}
	target.mu.Lock()
	env := target.writes[0]
	target.mu.Unlock()
	params := env["params"].(map[string]any)
	if params["task"] != task.Ref || len([]rune(params["name"].(string))) > 64 || params["body"] != task.Title || env["control_version"] != float64(1) {
		t.Fatalf("lost work: %v", env)
	}
	rec, _ := h.srv.Store.FleetTask(task.ID)
	if rec.FID != task.FID || rec.Generation != task.Generation || rec.ExecutionEndpoint == "" {
		t.Fatalf("identity: %+v", rec)
	}
	if ok, _ := h.srv.Store.TaskStartRetryable(rec); ok {
		t.Fatal("active binding retryable")
	}
	// A late refusal cannot cover up admitted execution.
	if st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, NodeTasksPath+"/"+task.Ref+"/start-failed", map[string]any{"generation": task.Generation, "reason": "late"}); st != 409 {
		t.Fatalf("late: %d %v", st, out)
	}
}

func TestTaskStartRetryBlankFailureAndDelete(t *testing.T) {
	h, first, target, _, _ := twoNodesCaps(t, control.CapTaskExecution)
	task := retryFixtureTask(t, h, "新会话", true)
	args, err := taskRetryArgs(task)
	if err != nil || args["body"] != nil || args["name"] != "新会话" {
		t.Fatalf("blank: %v %v", args, err)
	}
	route := NodeTasksPath + "/" + task.Ref + "/start-failed"
	for _, reason := range []string{"ALL_DECLINED: no eligible node", "name must be at most 64 characters"} {
		if st, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, route, map[string]any{"generation": task.Generation, "reason": reason}); st != 200 {
			t.Fatalf("failure: %d %v", st, out)
		}
		b, err := h.srv.buildBoard(task.Owner, nil, time.Now())
		if err != nil {
			t.Fatal(err)
		}
		found := false
		for _, row := range b.Rows {
			if row.Task == task.Ref {
				found = true
				if row.Tag != "start_failed" || !row.StartRetry || row.StartFailure != reason {
					t.Fatalf("board: %+v", row)
				}
			}
		}
		if !found {
			t.Fatal("missing failed task")
		}
	}
	postFleet(t, h, "tasks/"+task.Ref+"/retry-start", map[string]any{"expected_generation": task.Generation + 1}, 409)
	postFleet(t, h, "tasks/"+task.Ref+"/cancel", map[string]any{}, 200)
	postFleet(t, h, "tasks/"+task.Ref+"/retry-start", map[string]any{"expected_generation": task.Generation}, 409)
	if first.count()+target.count() != 0 {
		t.Fatal("cancelled task dispatched")
	}
}

func TestTaskStartPlacementRefusalIsRecorded(t *testing.T) {
	h, first, target, f5, f4 := twoNodesCaps(t, control.CapTaskExecution)
	task := retryFixtureTask(t, h, "New session", true)
	args, _ := taskRetryArgs(task)
	d := args["dispatch"].(*dispatchChoice)
	// Validation happens before acceptance in /node/place; the previously
	// accepted task must still retain that rejection (the ARJ8 failure).
	req := map[string]any{"kind": "scratch", "repo": writeRepo, "fleet_id": f5.FleetID, "name": strings.Repeat("x", 65), "dispatch": d}
	if st, out := placeCall(t, h, h.tokens["mac-d"], req); st != 400 {
		t.Fatalf("validation: %d %v", st, out)
	}
	got, _ := h.srv.Store.FleetTask(task.ID)
	if !strings.Contains(got.StartFailure(), "64") {
		t.Fatalf("missing validation reason: %+v", got)
	}
	beatAdmit(t, h, first, "mac-d", machineA, 3, boolp(false), "capacity", 5, f5)
	beatAdmit(t, h, target, "mac-c", machineB, 1, boolp(false), "capacity", 0, f4)
	req["name"] = "New session"
	if st, out := placeCall(t, h, h.tokens["mac-d"], req); st != 429 {
		t.Fatalf("admission: %d %v", st, out)
	}
	got, _ = h.srv.Store.FleetTask(task.ID)
	if !strings.Contains(got.StartFailure(), "AT_CAPACITY") {
		t.Fatalf("missing admission reason: %+v", got)
	}
	if ok, _ := h.srv.Store.TaskStartRetryable(got); !ok {
		t.Fatal("refusal lost retry")
	}
	if first.count()+target.count() != 0 {
		t.Fatal("refusal sent work")
	}
}

func TestTaskStartRetryEntryOwnerOnly(t *testing.T) {
	h, first, target, _, _ := twoNodesCaps(t, control.CapTaskExecution)
	task := retryFixtureTask(t, h, "New session", true)
	raw, _ := json.Marshal(map[string]any{"task": task.Ref, "expected_generation": task.Generation})
	req := WriteRequest{Tool: "task_retry_start", ArgsJSON: string(raw)}
	for _, auth := range []struct{ token, worker string }{{h.tokens["mac-c"], ""}, {"fcp-h2.worker", ""}, {viewerToken, "assertion"}} {
		if st, out := continueWriteCall(t, h, req, auth.token, auth.worker); st != 401 && st != 403 {
			t.Fatalf("not person: %d %v", st, out)
		}
	}
	if first.count()+target.count() != 0 {
		t.Fatal("node/worker dispatched retry")
	}
	for i := 0; i < 2; i++ {
		if st, out := continueWriteCall(t, h, req, viewerToken, ""); st != 202 {
			t.Fatalf("owner: %d %v", st, out)
		}
	}
	if first.count()+target.count() != 1 {
		t.Fatal("signed retry duplicated start")
	}
}
