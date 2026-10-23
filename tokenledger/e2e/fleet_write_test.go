package e2e

import (
	"net/http"

	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// End to end through a real agent and the REAL fleet-control.py: the hub's
// write reaches the node's controller, which journals it under the same id
// and runs it detached; operation_get reads the executor's outcome back.
func TestFleetWriteIntegrationRealFleetControl(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("no python3")
	}
	bin, _ := filepath.Abs("../../bin")
	if _, err := os.Stat(filepath.Join(bin, "fleet_control.py")); err != nil {
		t.Skip("no claude-fleet bin/ beside tokenledger/")
	}
	h := newFleetHarness(t)
	home := t.TempDir()
	installFakeFleetControl(t, py, bin, home, "fleet-alpha", writeRepo)
	token := h.Enroll(t, "mac-c")
	reads := filepath.Join(home, "task-reads")
	t.Setenv("FLEET_TEST_TASK_HUB_URL", h.HTTP.URL)
	t.Setenv("FLEET_TEST_TASK_NODE_TOKEN", token)
	t.Setenv("FLEET_TEST_TASK_READS", reads)
	a, err := agent.New(agent.Config{
		HubURL: h.HTTP.URL, Token: token, Home: home,
		StateDir: filepath.Join(home, "state"), SessionsDir: filepath.Join(home, "sessions"),
		Sources: "claude", LiveInterval: 150 * time.Millisecond, ScanInterval: time.Hour, LimitsInterval: time.Hour,
		Fleet: true, Version: "it-write",
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { a.Run(ctx); close(done) }()
	t.Cleanup(func() { cancel(); <-done })
	waitFor(t, 10*time.Second, "fleet registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 1
	})
	fid := getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)[0].(map[string]any)["fleet_id"].(string)

	// The fake adapter's window list holds issue 42, so a start of 42 is
	// observed by the executor and confirmed.
	op := postFleet(t, h, "worker_start", map[string]any{"issue": 42, "fleet_id": fid, "idempotency_key": "it-42"}, 200)
	switch op["status"] {
	case "accepted", "running", "succeeded":
	default:
		t.Fatalf("worker_start through the real controller = %v", op)
	}
	id := op["operation_id"].(string)
	var final map[string]any
	waitFor(t, 15*time.Second, "the executor's outcome", func() bool {
		final = getFleet(t, h, "/v1/fleet/operation_get?operation_id="+id, 200)
		return final["status"] == "succeeded" || final["status"] == "failed"
	})
	if final["status"] != "succeeded" {
		t.Fatalf("operation = %v; want succeeded", final)
	}
	// The node journalled the hub's operation id, not one of its own.
	script := filepath.Join(home, ".claude", "fleet", "bin", "fleet-control.py")
	disc, _ := json.Marshal(map[string]any{"protocol": 1, "method": "discover", "params": map[string]any{}})
	cmd := exec.Command(script, "rpc")
	cmd.Stdin = bytes.NewReader(disc)
	out, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	var d map[string]any
	_ = json.Unmarshal(out, &d)
	get, _ := json.Marshal(map[string]any{"protocol": 1, "method": "operation_get", "machine_id": d["machine_id"],
		"params": map[string]any{"operation_id": id}})
	cmd = exec.Command(script, "rpc")
	cmd.Stdin = bytes.NewReader(get)
	if out, err = cmd.Output(); err != nil || !strings.Contains(string(out), `"status":"succeeded"`) {
		t.Fatalf("the node's own journal for %s: %s (%v)", id, out, err)
	}
	if _, err := os.Stat(reads); !os.IsNotExist(err) {
		t.Fatalf("legacy start must not read task authority: %v", err)
	}
	// An explicit provider creates an accepted task. The same real controller
	// must now fetch that record over authenticated HTTP before its adapter runs.
	accepted := postFleet(t, h, "worker_start", map[string]any{
		"issue": 42, "fleet_id": fid, "idempotency_key": "it-42-accepted", "coding_agent": "claude",
	}, 200)
	acceptedID := accepted["operation_id"].(string)
	waitFor(t, 15*time.Second, "accepted task executor outcome", func() bool {
		final = getFleet(t, h, "/v1/fleet/operation_get?operation_id="+acceptedID, 200)
		return final["status"] == "succeeded" || final["status"] == "failed"
	})
	if final["status"] != "succeeded" {
		t.Fatalf("accepted task operation = %v; want succeeded", final)
	}
	journal, err := h.Srv.Store.FleetOperation(acceptedID)
	if err != nil {
		t.Fatal(err)
	}
	var request struct {
		Params struct {
			Task string `json:"task"`
		} `json:"params"`
	}
	if err := json.Unmarshal([]byte(journal.Request), &request); err != nil || request.Params.Task == "" {
		t.Fatalf("accepted request missing task: %s (%v)", journal.Request, err)
	}
	record, err := h.Srv.Store.FleetTask(store.ParseTaskRef(request.Params.Task))
	if err != nil || record.AuthorityVersion != 1 {
		t.Fatalf("accepted record: %+v %v", record, err)
	}
	readLog, err := os.ReadFile(reads)
	if err != nil || strings.TrimSpace(string(readLog)) != request.Params.Task {
		t.Fatalf("controller did not read its real Hub task: %q %v", readLog, err)
	}
}

const writeRepo = "verkyyi/claude-fleet"

func postFleet(t *testing.T, h *harness, tool string, args map[string]any, wantStatus int) map[string]any {
	t.Helper()
	body, _ := json.Marshal(args)
	req, _ := http.NewRequest(http.MethodPost, h.HTTP.URL+"/v1/fleet/"+tool, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if resp.StatusCode != wantStatus {
		t.Fatalf("%s: HTTP %d (%v), want %d", tool, resp.StatusCode, out, wantStatus)
	}
	return out
}
