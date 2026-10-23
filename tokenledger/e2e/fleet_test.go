package e2e

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

// TestFleetIntegrationRealFleetControl is the issue's integration check: two
// agents, each with its own fake fleet behind the REAL fleet-control.py (only
// the tmux-reading adapter is faked), and fleet_status through the hub must
// return both machines' windows with the very worker_ids each node's own
// fleet-control.py prints.
func TestFleetIntegrationRealFleetControl(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("no python3")
	}
	bin, _ := filepath.Abs("../../bin")
	if _, err := os.Stat(filepath.Join(bin, "fleet_control.py")); err != nil {
		t.Skip("no claude-fleet bin/ beside tokenledger/")
	}
	h := newFleetHarness(t)
	const every = 150 * time.Millisecond

	type node struct{ label, host, session, repo string }
	nodes := []node{{"mac-d", "mac-d", "fleet-alpha", "verkyyi/claude-fleet"}, {"mac-c", "mac-c", "fleet-beta", ""}}
	scripts := map[string]string{}
	for _, n := range nodes {
		home := t.TempDir()
		script := installFakeFleetControl(t, py, bin, home, n.session, n.repo)
		scripts[n.session] = script
		a, err := agent.New(agent.Config{
			HubURL: h.HTTP.URL, Token: h.Enroll(t, n.label), Home: home,
			StateDir: filepath.Join(home, "state"), SessionsDir: filepath.Join(home, "sessions"),
			Sources: "claude", LiveInterval: every, ScanInterval: time.Hour, LimitsInterval: time.Hour,
			Fleet: true, Version: "it-" + n.label,
		})
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan struct{})
		go func() { a.Run(ctx); close(done) }()
		t.Cleanup(func() { cancel(); <-done })
	}

	waitFor(t, 10*time.Second, "both fleets registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})

	// What each node's own fleet-control.py says, asked directly.
	rpc := func(script string, req map[string]any) map[string]any {
		in, _ := json.Marshal(req)
		cmd := exec.Command(script, "rpc")
		cmd.Stdin = strings.NewReader(string(in))
		out, err := cmd.Output()
		if err != nil {
			t.Fatalf("%s rpc: %v: %s", script, err, out)
		}
		var resp map[string]any
		if err := json.Unmarshal(out, &resp); err != nil || resp["result"] == nil {
			t.Fatalf("%s rpc: %s", script, out)
		}
		return resp
	}
	machines := map[string]bool{}
	for _, f := range getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any) {
		f := f.(map[string]any)
		// Both test agents share this host's real hostname; the endpoint is
		// what tells the two "machines" apart here.
		machines[f["endpoint_id"].(string)] = true
		fid := f["fleet_id"].(string)
		st := getFleet(t, h, "/v1/fleet/fleet_status?fleet_id="+fid, 200)
		if st["source"] != "live" {
			t.Errorf("fleet %s answered from %v, want a live read through the control channel (%v)", fid, st["source"], st["live_error"])
		}
		script := scripts[f["name"].(string)]
		disc := rpc(script, map[string]any{"protocol": 1, "method": "discover", "params": map[string]any{}})
		local := rpc(script, map[string]any{"protocol": 1, "method": "fleet_status",
			"machine_id": disc["machine_id"], "params": map[string]any{"fleet_id": fid}})
		want := workerIDs(local["result"].(map[string]any)["workers"])
		got := workerIDs(st["workers"])
		if len(want) == 0 || strings.Join(got, ",") != strings.Join(want, ",") {
			t.Errorf("fleet %s worker_ids via hub = %v; the node's fleet-control.py says %v", fid, got, want)
		}
		// And the hub re-derives the fleet UUID itself.
		if again, _ := fleetid.FleetID(f["machine_id"].(string), f["name"].(string), f["repo"].(string), f["checkout"].(string)); again != fid {
			t.Errorf("fleet %s does not re-derive (got %s)", fid, again)
		}
	}
	if !machines["ep_mac-d"] || !machines["ep_mac-c"] {
		t.Fatalf("endpoints = %v, want ep_mac-d and ep_mac-c", machines)
	}
	s := getFleet(t, h, "/v1/fleet/fleet_sessions", 200)
	if s["count"].(float64) != 4 {
		t.Fatalf("fleet_sessions = %v; want 2 sessions on each machine", s["count"])
	}
}

func workerIDs(v any) []string {
	out := []string{}
	for _, w := range v.([]any) {
		if id, ok := w.(map[string]any)["worker_id"].(string); ok {
			out = append(out, id)
		}
	}
	sort.Strings(out)
	return out
}

// installFakeFleetControl lays out <home>/.claude/fleet/bin/ with the real
// fleet_control.py + its imports, a wrapper entry point pinning
// FLEET_CONF_DIR to this home (so two "machines" in one test process each mint
// their own machine_id), and a fake fleet-control-read.sh standing in for
// tmux: one fleet, an issue worker and a scratch session.
func installFakeFleetControl(t *testing.T, py, src, home, session, repo string) string {
	t.Helper()
	// The heartbeat reads' cache (claude-fleet#3514) holds an answer up to 15 s
	// unless a state change nudges it; these tests swap the fake adapter's
	// output mid-test with no nudge, so every read is fresh (claude-fleet#3520).
	t.Setenv("FLEET_CONTROL_READ_CACHE", "0")
	dir := filepath.Join(home, ".claude", "fleet", "bin")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"fleet_control.py", "fleet_dispatch.py", "fleet_park_metrics.py", "fleet_iso.py", "fleet_hub_common.py", "fleet_config_write.py"} {
		b, err := os.ReadFile(filepath.Join(src, f))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, f), b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	conf := filepath.Join(home, ".config", "claude-fleet")
	entry := "#!" + py + `
import os, sys
here = os.path.dirname(os.path.abspath(__file__))
os.environ["FLEET_CONF_DIR"] = ` + pyQuote(conf) + `
sys.path.insert(0, here)
from fleet_control import Control, main
# Production intentionally drops arbitrary inherited Fleet overrides. Pass only
# this fixture's real-Hub transport inputs through its detached executor.
original_environment = Control.environment
def fixture_environment(self):
    env = original_environment(self)
    for key in ("FLEET_TEST_TASK_HUB_URL", "FLEET_TEST_TASK_NODE_TOKEN", "FLEET_TEST_TASK_READS"):
        if key in os.environ:
            env[key] = os.environ[key]
    return env
Control.environment = fixture_environment
sys.exit(main())
`
	checkout := filepath.Join(home, "checkout")
	adapter := `#!/bin/bash
case "$1" in
  inventory) printf '%s\0' ` + shQuote(session) + ` ` + shQuote(repo) + ` ` + shQuote(checkout) + ` claude ` + shQuote(filepath.Join(conf, "fleet.conf")) + ` ` + shQuote(repo) + ` ;;
  workers) printf '@1\t42\t\t/w/x-issue-42\tworking\tclaude\tw1\t\t\n@2\t\t1\t/w/x-scratch-3\tidle\tclaude\tw2\t\t\n' ;;
  config) printf '%s\0' 8 0 1 ;;
  start) exit 0 ;;
  *) exit 2 ;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "fleet-control.py"), []byte(entry), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "fleet-control-read.sh"), []byte(adapter), 0o755); err != nil {
		t.Fatal(err)
	}
	// The real dispatch validator reads the real test Hub's authenticated
	// task route. Only the node-config/shell transport wrapper is replaced;
	// no task state or authorization decision is fabricated in this fixture.
	// Test enrollment credentials are passed in the process environment only.
	reader := "#!/bin/sh\nexec " + shQuote(py) + ` - "$@" <<'PY'
import os, sys, urllib.parse, urllib.request
if len(sys.argv) != 3 or sys.argv[1] != "get":
    raise SystemExit("fixture task reader only accepts get <task>")
task = sys.argv[2]
request = urllib.request.Request(
    os.environ["FLEET_TEST_TASK_HUB_URL"] + "/v1/node/tasks/" + urllib.parse.quote(task, safe=""),
    headers={"Authorization": "Bearer " + os.environ["FLEET_TEST_TASK_NODE_TOKEN"]})
with urllib.request.urlopen(request, timeout=10) as response:
    body = response.read()
with open(os.environ["FLEET_TEST_TASK_READS"], "a") as log:
    log.write(task + "\n")
sys.stdout.buffer.write(body)
PY
`
	if err := os.WriteFile(filepath.Join(dir, "fleet-task-record.sh"), []byte(reader), 0o755); err != nil {
		t.Fatal(err)
	}
	return filepath.Join(dir, "fleet-control.py")
}

func pyQuote(s string) string { b, _ := json.Marshal(s); return string(b) }

func shQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// Exercise the real accept -> detached execute -> adapter environment boundary
// without TCP. The HTTP-backed integration test above/beside this one verifies
// actual Hub authorization; this test prevents its transport env being dropped.
func TestFleetControlFixtureDetachedEnvironment(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("no python3")
	}
	bin, _ := filepath.Abs("../../bin")
	home := t.TempDir()
	script := installFakeFleetControl(t, py, bin, home, "fixture", writeRepo)
	marker := filepath.Join(home, "child-env-ok")
	t.Setenv("FLEET_TEST_TASK_HUB_URL", "fixture-hub")
	t.Setenv("FLEET_TEST_TASK_NODE_TOKEN", "fixture-token")
	t.Setenv("FLEET_TEST_TASK_READS", marker)
	t.Setenv("FLEET_TEST_DO_NOT_FORWARD", "must-not-reach-executor")
	adapter := filepath.Join(filepath.Dir(script), "fleet-control-read.sh")
	b, err := os.ReadFile(adapter)
	if err != nil {
		t.Fatal(err)
	}
	start := `start)
    [ "$FLEET_TEST_TASK_HUB_URL" = fixture-hub ] &&
    [ "$FLEET_TEST_TASK_NODE_TOKEN" = fixture-token ] &&
    [ -n "$FLEET_TEST_TASK_READS" ] &&
    [ -z "${FLEET_TEST_DO_NOT_FORWARD:-}" ] || exit 9
    printf ok > "$FLEET_TEST_TASK_READS"
    exit 0 ;;
`
	if err := os.WriteFile(adapter, []byte(strings.Replace(string(b), "start) exit 0 ;;", start, 1)), 0o755); err != nil {
		t.Fatal(err)
	}
	rpc := func(method string, machine any, params map[string]any) map[string]any {
		t.Helper()
		in, _ := json.Marshal(map[string]any{"protocol": 1, "method": method, "machine_id": machine, "params": params})
		cmd := exec.Command(script, "rpc")
		cmd.Stdin = strings.NewReader(string(in))
		out, err := cmd.CombinedOutput()
		var response map[string]any
		if err != nil || json.Unmarshal(out, &response) != nil || response["result"] == nil {
			t.Fatalf("fixture RPC %s: %v %s", method, err, out)
		}
		return response["result"].(map[string]any)
	}
	discovery := rpc("discover", nil, map[string]any{})
	fleet := discovery["fleets"].([]any)[0].(map[string]any)["fleet_id"]
	const operationID = "71614df1-7915-4b2d-9bd1-f86dbf66b63d"
	rpc("submit", discovery["machine_id"], map[string]any{"operation_id": operationID, "fleet_id": fleet,
		"action": "worker_start", "params": map[string]any{"issue": 42}, "actor": "fixture"})
	var final map[string]any
	waitFor(t, 5*time.Second, "detached fixture executor", func() bool {
		final = rpc("operation_get", discovery["machine_id"], map[string]any{"operation_id": operationID})
		return final["status"] != "accepted" && final["status"] != "running"
	})
	if final["status"] != "succeeded" {
		t.Fatalf("detached fixture lost transport environment: %v", final)
	}
	if b, err := os.ReadFile(marker); err != nil || string(b) != "ok" {
		t.Fatalf("detached adapter env check: %q %v", b, err)
	}
}
