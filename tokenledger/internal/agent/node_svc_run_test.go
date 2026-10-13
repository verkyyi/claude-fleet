package agent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// A service login takes one attempt at a time (claude-fleet#4086): its own
// wrapper, the key on stdin only, killed and cleaned on a cancel; anything
// else is refused.
func TestSvcRunStartsTheLoginsWrapper(t *testing.T) {
	home := t.TempDir()
	rec := t.TempDir()
	bin := filepath.Join(home, ".claude", "fleet", "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	script := `#!/bin/sh
R=` + rec + `
if [ "$1" = clean ]; then echo "$2 $3" >> "$R/clean"; exit 0; fi
cat > "$R/stdin"
echo "$@" > "$R/argv"
env | grep '^FLEET_SVC_' | sort > "$R/env"
[ -f "$R/hang" ] && sleep 30
exit 0
`
	if err := os.WriteFile(filepath.Join(bin, "fleet-svc-local.sh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	tok := "fsj_" + strings.Repeat("b", 52)
	ask := func(a *Agent, typ string, v any) control.SvcRunAck {
		t.Helper()
		l := &recLink{}
		m, _ := control.New(typ, v)
		if typ == control.TypeSvcRun {
			a.answerSvcRun(context.Background(), l, m)
		} else {
			a.answerSvcRunCancel(context.Background(), l, m)
		}
		if len(l.out) != 1 || l.out[0].OpID != m.OpID || l.out[0].Type != control.TypeResult {
			t.Fatalf("answers = %+v; want one result, by op_id", l.out)
		}
		var ack control.SvcRunAck
		_ = json.Unmarshal(l.out[0].Payload, &ack)
		return ack
	}
	wait := func(f string) string {
		t.Helper()
		for i := 0; i < 100; i++ {
			if b, err := os.ReadFile(filepath.Join(rec, f)); err == nil && len(b) > 0 {
				return string(b)
			}
			time.Sleep(50 * time.Millisecond)
		}
		t.Fatalf("%s never written", f)
		return ""
	}
	good := control.SvcRunStart{Run: "R7", Attempt: 1, Deadline: 900, Token: tok}

	// not a service login: never offered, and refused
	off := &Agent{cfg: Config{Home: home, HubURL: "https://hub.example.com"}}
	if off.svcRunCapable() {
		t.Fatal("a login without CCQUOTA_FLEET_SVC offers svc_run")
	}
	if ack := ask(off, control.TypeSvcRun, good); ack.OK {
		t.Fatal("a plain login started a service run")
	}
	a := &Agent{cfg: Config{Home: home, HubURL: "https://hub.example.com", FleetSvc: true}}
	if !a.svcRunCapable() || (&Agent{cfg: Config{Home: t.TempDir(), FleetSvc: true}}).svcRunCapable() {
		t.Fatal("svcRunCapable: want only a service login with the wrapper installed")
	}
	for _, bad := range []control.SvcRunStart{
		{Run: "R7", Attempt: 0, Deadline: 900, Token: tok},
		{Run: "u-x", Attempt: 1, Deadline: 900, Token: tok},
		{Run: "R7", Attempt: 1, Deadline: 99999, Token: tok},
		{Run: "R7", Attempt: 1, Deadline: 900, Token: "fsj_short"},
	} {
		if ack := ask(a, control.TypeSvcRun, bad); ack.OK {
			t.Fatalf("%+v: started", bad)
		}
	}

	if ack := ask(a, control.TypeSvcRun, good); !ack.OK {
		t.Fatalf("a good start refused: %s", ack.Line)
	}
	if got := strings.TrimSpace(wait("stdin")); got != tok {
		t.Fatalf("stdin = %q; want the key", got)
	}
	argv, env := wait("argv"), wait("env")
	if strings.TrimSpace(argv) != "run" || strings.Contains(argv+env, tok) {
		t.Fatalf("the key left stdin: argv %q env %q", argv, env)
	}
	for _, kv := range []string{"FLEET_SVC_RUN=R7", "FLEET_SVC_ATTEMPT=1", "FLEET_SVC_DEADLINE=900",
		"FLEET_SVC_HUB=https://hub.example.com", "FLEET_SVC_CENTRAL=https://hub.example.com"} {
		if !strings.Contains(env, kv+"\n") {
			t.Fatalf("env lacks %s: %q", kv, env)
		}
	}

	// a running attempt: a second start refused, a cancel kills it and cleans
	os.Remove(filepath.Join(rec, "stdin"))
	os.WriteFile(filepath.Join(rec, "hang"), []byte("1"), 0o644)
	for i := 0; i < 100 && a.svcRuns.count() > 0; i++ {
		time.Sleep(20 * time.Millisecond)
	}
	two := control.SvcRunStart{Run: "R8", Attempt: 1, Deadline: 900, Token: tok}
	if ack := ask(a, control.TypeSvcRun, two); !ack.OK {
		t.Fatalf("start R8: %s", ack.Line)
	}
	wait("stdin")
	if ack := ask(a, control.TypeSvcRun, two); ack.OK {
		t.Fatal("the same attempt started twice")
	}
	if ack := ask(a, control.TypeSvcRunCancel, control.SvcRunCancel{Run: "R8", Attempt: 1}); !ack.OK {
		t.Fatalf("cancel: %s", ack.Line)
	}
	if got := strings.TrimSpace(wait("clean")); got != "R8 1" {
		t.Fatalf("clean = %q; want R8 1", got)
	}
	for i := 0; i < 100 && a.svcRuns.count() > 0; i++ {
		time.Sleep(20 * time.Millisecond)
	}
	if n := a.svcRuns.count(); n != 0 {
		t.Fatalf("%d attempts still held after the cancel", n)
	}
	// a cancel of what is not running here: already stopped
	if ack := ask(a, control.TypeSvcRunCancel, control.SvcRunCancel{Run: "R9", Attempt: 2}); !ack.OK {
		t.Fatal("a cancel of nothing must answer ok")
	}
}
