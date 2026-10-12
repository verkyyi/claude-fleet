package agent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// claude-fleet#3504: a reset runs the remove script's --recycle mode with its
// own fixed argv, hands it the op's join code in the environment (never the
// argv), and reads the script's last two lines — `reset: …` then
// `credsep: …` — into the result. The hello says CapRecycle only when the
// remove script carries the mode.
func TestAdminAgentRunsFixedResetArgv(t *testing.T) {
	for _, tc := range []struct {
		name, tail, reset, credsep string
	}{
		{"clean", "echo 'reset: clean'\necho 'credsep: separated'\n", control.ResetClean, control.CredsepSeparated},
		{"dirty", "echo 'reset: dirty home,crontab'\necho 'credsep: separated'\n", "dirty home,crontab", control.CredsepSeparated},
		{"no verdict", "echo 'credsep: separated'\n", "", control.CredsepSeparated},
	} {
		t.Run(tc.name, func(t *testing.T) {
			shrinkBackoff(t)
			code := "fj_abcdefghijklmnopqrstuvwxyz"
			hub := newAccountHub(t, control.AccountOp{Op: control.AccountReset, Login: "alice", JoinCode: code})
			a := adminAgent(t, hub.srv.URL, true)
			newLog, _ := fakeLoginScripts(t, a.cfg.Home, "0")
			argv := filepath.Join(t.TempDir(), "argv")
			body := "#!/bin/sh\n# --recycle\nfor x in \"$@\"; do printf '[%s]' \"$x\"; done > " + argv + "\necho\n" +
				"echo \"code=${FLEET_LOGIN_JOIN_CODE:-}\" >> " + argv + "\n" + tc.tail
			if err := os.WriteFile(filepath.Join(a.cfg.Home, loginRemoveScript), []byte(body), 0o755); err != nil {
				t.Fatal(err)
			}
			runAgentUntil(t, a, 5*time.Second, func() bool { r, _, _ := hub.snapshot(); return len(r) > 0 })
			results, errs, _ := hub.snapshot()
			if len(errs) != 0 || len(results) != 1 {
				t.Fatalf("results=%v errors=%v", results, errs)
			}
			var res control.AccountResult
			json.Unmarshal(results[0].Payload, &res)
			if !res.OK || res.Op != control.AccountReset || res.Reset != tc.reset || res.Credsep != tc.credsep {
				t.Fatalf("result = %+v; want reset %q credsep %q", res, tc.reset, tc.credsep)
			}
			got, _ := os.ReadFile(argv)
			if want := "[alice][--recycle][--keep-home][--apply]code=" + code + "\n"; string(got) != want {
				t.Fatalf("fleet-login-remove.sh argv/env = %q, want %q", got, want)
			}
			if _, err := os.Stat(newLog); err == nil {
				t.Fatal("a reset ran the create script")
			}
			hub.mu.Lock()
			caps := "," + strings.Join(hub.hellos[0].Capabilities, ",") + ","
			hub.mu.Unlock()
			if !strings.Contains(caps, ","+control.CapRecycle+",") {
				t.Fatalf("hello capabilities %s lack %s", caps, control.CapRecycle)
			}
		})
	}
}

func TestRecycleCapableNeedsTheMode(t *testing.T) {
	home := t.TempDir()
	if recycleCapable(home) {
		t.Fatal("no script, yet recycle capable")
	}
	fakeLoginScripts(t, home, "0")
	if recycleCapable(home) {
		t.Fatal("a remove script without --recycle counted as recycling")
	}
	if err := validateAccountOp(control.AccountOp{Op: control.AccountReset, Login: "alice", JoinCode: "fj_abcdefghijklmnopqrstuvwxyz"}, ""); err != nil {
		t.Fatalf("a reset with a join code was refused: %v", err)
	}
	if err := validateAccountOp(control.AccountOp{Op: control.AccountRemove, Login: "alice", JoinCode: "fj_abcdefghijklmnopqrstuvwxyz"}, ""); err == nil {
		t.Fatal("a remove with a join code was accepted")
	}
	if err := validateAccountOp(control.AccountOp{Op: control.AccountReset, Login: "verkyyi"}, "verkyyi"); err == nil {
		t.Fatal("a reset of the agent's own login was accepted")
	}
	if err := validateLinuxAccountOp(control.AccountOp{Op: control.AccountReset, Login: "alice"}, "fleetsvc"); err == nil {
		t.Fatal("a Linux machine's opener took a reset (the cloud destroys, never washes)")
	}
	if resetResult("x\nreset: clean\ncredsep: separated\n") != control.ResetClean || resetResult("credsep: separated") != "" {
		t.Fatal("resetResult reads the wrong line")
	}
}
