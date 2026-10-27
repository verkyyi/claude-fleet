package agent

import (
	"context"
	"encoding/json"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/schedule"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestScheduleLaneAndStdin(t *testing.T) {
	d := t.TempDir()
	script := filepath.Join(d, "supervisor.py")
	seen := filepath.Join(d, "seen")
	_ = os.WriteFile(script, []byte("import sys,json\nopen("+quoted(seen)+",'w').write(json.dumps({'argv':sys.argv[1:],'body':json.load(sys.stdin)}))\nprint('{}')\n"), 0600)
	a := &Agent{cfg: Config{RunAs: &RunAs{Login: "alice"}, ServiceCtl: script}}
	spec := schedule.Spec{ID: "schedule-test", Revision: 1, Name: "daily", Prompt: "do not put me in argv", At: "07:00", Timezone: "Asia/Shanghai", Enabled: true}
	send := func(login string) string {
		env, _ := json.Marshal(map[string]any{"operation_id": "op1", "action": "schedule_control", "params": map[string]any{"login": login, "action": "apply", "schedule": spec}})
		m, _ := control.New(control.TypeWrite, control.Request{Method: "submit", Params: env})
		l := &capLink{}
		if !a.scheduleWrite(context.Background(), l, m) || len(l.got) != 1 {
			t.Fatal("not handled")
		}
		return string(l.got[0].Payload)
	}
	if out := send("bob"); !strings.Contains(out, "failed") {
		t.Fatal(out)
	}
	if _, e := os.Stat(seen); !os.IsNotExist(e) {
		t.Fatal("wrong lane executed")
	}
	if out := send("alice"); !strings.Contains(out, "succeeded") {
		t.Fatal(out)
	}
	var got struct {
		Argv []string       `json:"argv"`
		Body map[string]any `json:"body"`
	}
	raw, _ := os.ReadFile(seen)
	_ = json.Unmarshal(raw, &got)
	if strings.Join(got.Argv, " ") != "schedule --login alice" {
		t.Fatal(got.Argv)
	}
	if !strings.Contains(string(raw), spec.Prompt) {
		t.Fatal("prompt did not travel on stdin")
	}
}
func quoted(s string) string { b, _ := json.Marshal(s); return string(b) }
