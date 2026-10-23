package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// Real HTTP bridges the Hub transaction/receipt and the Python execution fence.
// The native program is a bounded test process; this is not provider acceptance.
func TestTaskCyclePythonHTTP(t *testing.T) {
	python, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 unavailable")
	}
	_, file, _, _ := runtime.Caller(0)
	bin := filepath.Clean(filepath.Join(filepath.Dir(file), "../../../bin"))
	bridge := filepath.Join(filepath.Dir(file), "testdata/task_cycle_node.py")
	root := t.TempDir()
	h, _, node, _, fleet := twoNodesCaps(t, control.CapTaskExecution, control.CapTaskContinuation)
	call := func(action string, input map[string]any) (map[string]any, error) {
		input["action"], input["root"], input["bin"] = action, root, bin
		input["url"], input["token"], input["fleet"] = h.http.URL, h.tokens["mac-c"], fleet.FleetID
		payload, _ := json.Marshal(input)
		ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, python, bridge)
		cmd.Stdin = bytes.NewReader(payload)
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		out, e := cmd.Output()
		if e != nil {
			t.Logf("Python %s: %s", action, stderr.String())
			return nil, e
		}
		var result map[string]any
		e = json.Unmarshal(out, &result)
		return result, e
	}
	run := func(action string, input map[string]any) map[string]any {
		out, e := call(action, input)
		if e != nil {
			t.Fatalf("Python %s: %v", action, e)
		}
		return out
	}
	status, placed := placeCall(t, h, h.tokens["mac-c"], map[string]any{
		"kind": "scratch", "repo": writeRepo, "fleet_id": fleet.FleetID, "node": "mac-c",
		"idempotency_key": "python-cycle", "coding_agent": "claude", "control_version": 1, "local_dispatch": true,
	})
	if status != 200 || placed["local"] != true {
		t.Fatalf("LOCAL placement: %d %v", status, placed)
	}
	initial := placed["task_execution"].(map[string]any)
	ref := initial["task_ref"].(string)
	t.Cleanup(func() {
		if _, e := call("cleanup", map[string]any{"tasks": []string{ref}}); e != nil {
			t.Errorf("fixture process cleanup: %v", e)
		}
	})
	first := run("start", map[string]any{"snapshot": initial})
	var oldStop, oldFID string
	for cycle := 0; cycle < 2; cycle++ {
		out := postFleet(t, h, "tasks/"+ref+"/stop", map[string]any{"idempotency_key": "python-stop-" + string(rune('0'+cycle))}, 202)
		op := out["operation"].(map[string]any)["operation_id"].(string)
		var request map[string]any
		node.mu.Lock()
		for _, v := range node.writes {
			if v["operation_id"] == op {
				request = v
			}
		}
		node.mu.Unlock()
		if request == nil {
			t.Fatal("Hub did not deliver the canonical stop")
		}
		receipt := run("stop", map[string]any{"request": request})
		if receipt["confirmed"] != true {
			t.Fatalf("unconfirmed real process receipt: %v", receipt)
		}
		if cycle == 1 {
			run("old", map[string]any{"fid": oldFID, "stop": oldStop})
			break
		}
		oldStop, oldFID = op, strings.Split(first["execution_owner"].(string), "/")[1]
		task, e := h.srv.Store.FleetTask(store.ParseTaskRef(ref))
		if e != nil || task.ExecutionEndpoint != "" {
			t.Fatalf("receipt did not release binding: %v %+v", e, task)
		}
		body := map[string]any{"idempotency_key": "python-continue", "expected_stop_operation_id": op, "expected_generation": task.Generation}
		postFleet(t, h, "tasks/"+ref+"/continue", body, 202)
		st, metadata := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodGet, NodeTasksPath+"/"+ref+"/execution/start", nil)
		if st != 200 {
			t.Fatalf("current start: %d %v", st, metadata)
		}
		next := run("continue", map[string]any{"snapshot": metadata["task_execution"], "exit": receipt["operation_id"]})
		if next["execution_owner"] == first["execution_owner"] || next["task_fid"] != first["task_fid"] {
			t.Fatalf("continuation identity changed incorrectly: %v %v", first, next)
		}
		run("old", map[string]any{"fid": oldFID, "stop": oldStop})
	}
}
