package agent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// capLink keeps what the agent wrote back.
type capLink struct{ got []control.Message }

func (l *capLink) write(_ context.Context, m control.Message) error {
	l.got = append(l.got, m)
	return nil
}
func (l *capLink) read(context.Context) (control.Message, error) { return control.Message{}, nil }
func (l *capLink) ping(context.Context) error                    { return nil }
func (l *capLink) close(string)                                  {}
func (l *capLink) closeNow()                                     {}

// A service_control submit runs the supervisor with a fixed argv on the lane's
// OWN login, answers final (succeeded / failed), and never reaches the
// login's fleet-control.py (claude-fleet#2527).
func TestServiceControlWrite(t *testing.T) {
	if _, err := os.Stat("/usr/bin/python3"); err != nil {
		t.Skip("no /usr/bin/python3")
	}
	dir := t.TempDir()
	argvFile := filepath.Join(dir, "argv")
	sup := filepath.Join(dir, "fleet-node-supervisor.py")
	os.WriteFile(sup, []byte(`import sys
open("`+argvFile+`", "a").write(" ".join(sys.argv[1:]) + "\n")
if "ghost" in sys.argv:
    sys.stderr.write("fleet-node-supervisor: alice/ghost is not registered\n"); sys.exit(1)
print("alice/daily: one run now")
`), 0o644)
	a := &Agent{cfg: Config{RunAs: &RunAs{Login: "alice"}, ServiceCtl: sup}}
	submit := func(params map[string]any) control.Message {
		env, _ := json.Marshal(map[string]any{"operation_id": "op-1", "fleet_id": "", "action": "service_control",
			"params": params, "actor": "p"})
		msg, _ := control.New(control.TypeWrite, control.Request{Method: "submit", Params: env})
		l := &capLink{}
		if !a.serviceControlWrite(context.Background(), l, msg) {
			t.Fatal("a service_control submit was left to the controller")
		}
		if len(l.got) != 1 || l.got[0].OpID != msg.OpID {
			t.Fatalf("replies = %+v", l.got)
		}
		return l.got[0]
	}
	remote := func(m control.Message) (string, map[string]any) {
		var r control.Result
		json.Unmarshal(m.Payload, &r)
		var out struct {
			OperationID string         `json:"operation_id"`
			Action      string         `json:"action"`
			Status      string         `json:"status"`
			Result      map[string]any `json:"result"`
		}
		if err := json.Unmarshal(r.Result, &out); err != nil || out.OperationID != "op-1" || out.Action != "service_control" {
			t.Fatalf("result identity = %s", r.Result)
		}
		return out.Status, out.Result
	}

	st, res := remote(submit(map[string]any{"login": "alice", "name": "daily", "action": "run_now"}))
	if st != "succeeded" || !strings.Contains(res["output"].(string), "one run now") {
		t.Fatalf("run_now = %s %v", st, res)
	}
	st, _ = remote(submit(map[string]any{"name": "daily", "action": "set_schedule", "at": "07:30", "tz": "Asia/Shanghai"}))
	if st != "succeeded" {
		t.Fatalf("set_schedule = %s", st)
	}
	st, res = remote(submit(map[string]any{"name": "ghost", "action": "stop"}))
	if e, _ := res["error"].(map[string]any); st != "failed" || e["code"] != "NOT_FOUND" || !strings.Contains(e["message"].(string), "not registered") {
		t.Fatalf("an unknown entry = %s %v", st, res)
	}
	b, _ := os.ReadFile(argvFile)
	want := "service run --login alice --name daily\n" +
		"service schedule --login alice --name daily --at 07:30 --tz Asia/Shanghai\n" +
		"service stop --login alice --name ghost\n"
	if string(b) != want {
		t.Fatalf("argv =\n%s\nwant\n%s", b, want)
	}

	// Refused before anything runs: another login, a bad action / name / schedule.
	for _, c := range []struct {
		params map[string]any
		code   string
	}{
		{map[string]any{"login": "bob", "name": "daily", "action": "stop"}, control.CodeWrongLogin},
		{map[string]any{"name": "daily", "action": "rm"}, control.CodeBadArgs},
		{map[string]any{"name": "../x", "action": "stop"}, control.CodeBadArgs},
		{map[string]any{"name": "daily", "action": "set_schedule"}, control.CodeBadArgs},
		{map[string]any{"name": "daily", "action": "set_schedule", "at": "7pm"}, control.CodeBadArgs},
		{map[string]any{"name": "daily", "action": "set_schedule", "cron": "0 7 * *"}, control.CodeBadArgs},
		{map[string]any{"name": "daily", "action": "set_schedule", "at": "07:00", "tz": "$(id)"}, control.CodeBadArgs},
	} {
		m := submit(c.params)
		if m.Type != control.TypeError || m.Error == nil || m.Error.Code != c.code {
			t.Errorf("%v = %+v, want %s", c.params, m, c.code)
		}
	}
	if b2, _ := os.ReadFile(argvFile); string(b2) != want {
		t.Fatalf("a refused write ran the supervisor:\n%s", b2)
	}

	// A plain agent (not the machine's) refuses; any other write is not ours.
	plain := &Agent{cfg: Config{}}
	env, _ := json.Marshal(map[string]any{"operation_id": "op-1", "action": "service_control", "params": map[string]any{}})
	msg, _ := control.New(control.TypeWrite, control.Request{Method: "submit", Params: env})
	l := &capLink{}
	if !plain.serviceControlWrite(context.Background(), l, msg) || l.got[0].Error == nil || l.got[0].Error.Code != "UNAVAILABLE" {
		t.Fatalf("plain agent = %+v", l.got)
	}
	env, _ = json.Marshal(map[string]any{"operation_id": "op-1", "action": "worker_stop", "params": map[string]any{}})
	msg, _ = control.New(control.TypeWrite, control.Request{Method: "submit", Params: env})
	if a.serviceControlWrite(context.Background(), &capLink{}, msg) {
		t.Fatal("a worker write was taken as service_control")
	}
}
