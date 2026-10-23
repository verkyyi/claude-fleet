package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func continueUnclaimedFixture(t *testing.T) (*harness, *writeNode, store.FleetTask, store.TaskExecutionSnapshot) {
	t.Helper()
	h, _, node, _, _ := twoNodesCaps(t, control.CapTaskExecution, control.CapTaskContinuation)
	postFleet(t, h, "worker_start", map[string]any{"kind": "scratch", "repo": writeRepo, "idempotency_key": "unclaimed-first", "coding_agent": "codex", "control_version": 1}, 200)
	node.mu.Lock()
	ref := node.writes[0]["task_execution"].(map[string]any)["task_ref"].(string)
	node.mu.Unlock()
	postFleet(t, h, "tasks/"+ref+"/stop", map[string]any{"idempotency_key": "unclaimed-stop"}, 202)
	task, err := h.srv.Store.FleetTask(store.ParseTaskRef(ref))
	if err != nil {
		t.Fatal(err)
	}
	snap, err := h.srv.Store.TaskExecutionSnapshot(task.ID, task.Owner)
	if err != nil {
		t.Fatal(err)
	}
	return h, node, task, snap
}

func TestTaskContinueUnclaimedAPIStart(t *testing.T) {
	h, node, task, stopped := continueUnclaimedFixture(t)
	before := node.count()
	body := continueBody(stopped, "unclaimed-retry")
	out := postFleet(t, h, "tasks/"+task.Ref+"/continue", body, 202)
	if out["stop_operation_id"] != stopped.CancelRequest || out["exit_operation_id"] != nil || out["agent"] != "codex" || node.count() != before+1 {
		t.Fatalf("retry: %v writes=%d", out, node.count())
	}
	status, view := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodGet, NodeTasksPath+"/"+task.Ref+"/execution/start", nil)
	if status != 200 || view["source_stop"] == nil || view["workspace_source"] != nil {
		t.Fatalf("unclaimed source: %d %v", status, view)
	}
	stop := view["source_stop"].(map[string]any)
	source := view["source_start"].(map[string]any)
	if len(stop) != 9 || stop["operation_id"] != stopped.OperationID || stop["execution_owner"] != "" || stop["cancel_request"] != stopped.CancelRequest || len(source) != 4 || source["operation_id"] != stopped.OperationID {
		t.Fatalf("source shape: %v", view)
	}
	if status, out := nodeTaskCall(t, h, h.tokens["mac-d"], http.MethodGet, NodeTasksPath+"/"+task.Ref+"/execution/start", nil); status != 404 {
		t.Fatalf("foreign read: %d %v", status, out)
	}
}

func TestTaskContinueUnclaimedAPIWorkspaceAndReplay(t *testing.T) {
	h, node, task, nativeStop, exitID := continueFixture(t)
	first := continueBody(nativeStop, "first-unclaimed-provider")
	first["agent"] = "claude"
	postFleet(t, h, "tasks/"+task.Ref+"/continue", first, 202)
	postFleet(t, h, "tasks/"+task.Ref+"/stop", map[string]any{"idempotency_key": "first-unclaimed-provider-stop"}, 202)
	stopped, err := h.srv.Store.TaskExecutionSnapshot(task.ID, task.Owner)
	if err != nil {
		t.Fatal(err)
	}
	var originalBody map[string]any
	var originalID any
	for i := 0; i < 3; i++ {
		body := continueBody(stopped, fmt.Sprintf("unclaimed-cycle-%d", i))
		out := postFleet(t, h, "tasks/"+task.Ref+"/continue", body, 202)
		if i == 0 {
			originalBody = body
			originalID = out["operation"].(map[string]any)["operation_id"]
		}
		if out["agent"] != "claude" || out["exit_operation_id"] != nil || out["stop_operation_id"] != stopped.CancelRequest {
			t.Fatalf("continued: %v", out)
		}
		status, view := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodGet, NodeTasksPath+"/"+task.Ref+"/execution/start", nil)
		if status != 200 {
			t.Fatalf("read: %d %v", status, view)
		}
		workspace := view["workspace_source"].(map[string]any)
		source := view["source_start"].(map[string]any)
		native := workspace["start"].(map[string]any)
		if len(workspace) != 2 || len(native) != 4 || workspace["exit_operation_id"] != exitID || native["operation_id"] != nativeStop.OperationID || native["agent"] != "codex" || source["operation_id"] != stopped.OperationID || source["agent"] != "claude" {
			t.Fatalf("workspace confused with immediate provider: %v", view)
		}
		postFleet(t, h, "tasks/"+task.Ref+"/stop", map[string]any{"idempotency_key": fmt.Sprintf("cycle-stop-%d", i)}, 202)
		stopped, err = h.srv.Store.TaskExecutionSnapshot(task.ID, task.Owner)
		if err != nil {
			t.Fatal(err)
		}
	}
	before := node.count()
	replay := postFleet(t, h, "tasks/"+task.Ref+"/continue", originalBody, 202)
	if replay["operation"].(map[string]any)["operation_id"] != originalID || node.count() != before {
		t.Fatal("old key rebound or redispatched")
	}
	changed := map[string]any{}
	for k, v := range originalBody {
		changed[k] = v
	}
	changed["agent"] = "claude"
	postFleet(t, h, "tasks/"+task.Ref+"/continue", changed, 409)
	stale := map[string]any{}
	for k, v := range originalBody {
		stale[k] = v
	}
	stale["idempotency_key"] = "stale-new-key"
	postFleet(t, h, "tasks/"+task.Ref+"/continue", stale, 409)
	// An original claimed-native proof remains historical; it cannot release a
	// newer never-claimed binding or replace its canonical stop source.
	old := sessionExitBody(nativeStop)
	old["idempotency_key"] = "old-exit-fresh-key"
	if status, out := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodPost, NodeTasksPath+"/"+task.Ref+"/execution/exit", old); status != 409 {
		t.Fatalf("old proof released new source: %d %v", status, out)
	}
}

func TestTaskContinueUnclaimedAPIConcurrent(t *testing.T) {
	for _, mode := range []string{"same-request", "same-key-different-provider", "different-keys"} {
		t.Run(mode, func(t *testing.T) {
			h, node, task, stop := continueUnclaimedFixture(t)
			before := node.count()
			type result struct {
				status int
				err    error
				out    map[string]any
			}
			gate := make(chan struct{})
			done := make(chan result, 6)
			for i := 0; i < 6; i++ {
				go func(i int) {
					body := continueBody(stop, "concurrent-unclaimed")
					if mode == "same-key-different-provider" && i%2 == 1 {
						body["agent"] = "claude"
					}
					if mode == "different-keys" {
						body["idempotency_key"] = fmt.Sprintf("different-key-%d", i)
					}
					b, _ := json.Marshal(body)
					r, _ := http.NewRequest(http.MethodPost, h.http.URL+FleetTasksPath+"/"+task.Ref+"/continue", bytes.NewReader(b))
					r.Header.Set("Authorization", "Bearer "+viewerToken)
					r.Header.Set("Content-Type", "application/json")
					<-gate
					response, err := h.http.Client().Do(r)
					if err != nil {
						done <- result{err: err}
						return
					}
					defer response.Body.Close()
					var out map[string]any
					err = json.NewDecoder(response.Body).Decode(&out)
					done <- result{response.StatusCode, err, out}
				}(i)
			}
			close(gate)
			statuses := map[int]int{}
			var id any
			for i := 0; i < 6; i++ {
				r := <-done
				if r.err != nil {
					t.Fatal(r.err)
				}
				statuses[r.status]++
				if r.status == 202 {
					got := r.out["operation"].(map[string]any)["operation_id"]
					if id != nil && id != got {
						t.Fatal("more than one authorization")
					}
					id = got
				} else if r.status != 409 {
					t.Fatalf("race: %d %v", r.status, r.out)
				}
			}
			want := 1
			if mode == "same-request" {
				want = 6
			} else if mode == "same-key-different-provider" {
				want = 3
			}
			if statuses[202] != want || node.count() != before+1 {
				t.Fatalf("race: %v writes=%d", statuses, node.count()-before)
			}
		})
	}
}

func TestTaskContinueUnclaimedAPILocalAndNoRepo(t *testing.T) {
	h, _, node, _, fleet := twoNodesCaps(t, control.CapTaskExecution, control.CapTaskContinuation)
	status, out := placeCall(t, h, h.tokens["mac-c"], map[string]any{"kind": "scratch", "no_repo": true, "fleet_id": fleet.FleetID, "node": "mac-c", "idempotency_key": "local-unclaimed", "coding_agent": "codex", "control_version": 1, "local_dispatch": true})
	if status != 200 || out["local"] != true || node.count() != 0 {
		t.Fatalf("LOCAL: %d %v", status, out)
	}
	snap := out["task_execution"].(map[string]any)
	ref := snap["task_ref"].(string)
	postFleet(t, h, "tasks/"+ref+"/stop", map[string]any{"idempotency_key": "local-unclaimed-stop"}, 202)
	task, err := h.srv.Store.FleetTask(store.ParseTaskRef(ref))
	if err != nil {
		t.Fatal(err)
	}
	stopped, err := h.srv.Store.TaskExecutionSnapshot(task.ID, task.Owner)
	if err != nil {
		t.Fatal(err)
	}
	postFleet(t, h, "tasks/"+ref+"/continue", continueBody(stopped, "local-unclaimed-retry"), 202)
	status, view := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodGet, NodeTasksPath+"/"+ref+"/execution/start", nil)
	if status != 200 {
		t.Fatalf("LOCAL source read: %d %v", status, view)
	}
	source := view["source_start"].(map[string]any)
	if source["operation_id"] != snap["operation_id"] || source["repo"] != "" || source["no_repo"] != true || view["workspace_source"] != nil {
		t.Fatalf("LOCAL source invented workspace: %v", view)
	}
}

func TestTaskContinueUnclaimedAPIUnknownAndCapability(t *testing.T) {
	h, node, task, stop := continueUnclaimedFixture(t)
	node.mu.Lock()
	node.answer = func(map[string]any) (any, *control.Error) {
		return nil, &control.Error{Code: "UNKNOWN", Message: "ack lost"}
	}
	node.mu.Unlock()
	body := continueBody(stop, "unknown-unclaimed")
	out := postFleet(t, h, "tasks/"+task.Ref+"/continue", body, 202)
	before := node.count()
	again := postFleet(t, h, "tasks/"+task.Ref+"/continue", body, 202)
	if out["operation"].(map[string]any)["operation_id"] != again["operation"].(map[string]any)["operation_id"] || node.count() != before {
		t.Fatal("unknown ACK caused redispatch")
	}
	postFleet(t, h, "tasks/"+task.Ref+"/stop", map[string]any{"idempotency_key": "unknown-explicit-stop"}, 202)
	stop, err := h.srv.Store.TaskExecutionSnapshot(task.ID, task.Owner)
	if err != nil {
		t.Fatal(err)
	}
	connectWriteNodeCaps(t, h, h.tokens["mac-c"], control.CapRead, control.CapWrite, control.CapTaskExecution)
	waitFor(t, 3*time.Second, "old-cap replacement", func() bool { c := h.srv.nodes.get(stop.ExecutionEndpoint); return c != nil && !c.canTaskContinuation })
	postFleet(t, h, "tasks/"+task.Ref+"/continue", continueBody(stop, "wait-for-capability"), 503)
	connectWriteNodeCaps(t, h, h.tokens["mac-c"], control.CapRead, control.CapWrite, control.CapTaskExecution, control.CapTaskContinuation)
	waitFor(t, 3*time.Second, "capability restored", func() bool { return h.srv.canTaskContinuation(context.Background(), stop.ExecutionEndpoint) })
	postFleet(t, h, "tasks/"+task.Ref+"/continue", continueBody(stop, "wait-for-capability"), 202)
}
