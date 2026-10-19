package agent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// seatAgent is an admin agent in seat mode (claude-fleet#3696): its gate dir
// with an admin.conf naming a release bin/, and a fake sudo that records its
// argv and stdin, one run per line, then exits code.
func seatAgent(t *testing.T, hub string, code string) (a *Agent, sudoLog string) {
	t.Helper()
	a = adminAgent(t, hub, true)
	a.cfg.FleetAdminSeat = true
	gate := filepath.Join(t.TempDir(), "admin")
	rel := filepath.Join(t.TempDir(), "bin")
	for _, d := range []string{gate, rel} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	a.cfg.AdminGateDir = gate
	os.WriteFile(filepath.Join(gate, "admin.conf"), []byte("bin="+rel+"\nhub=https://hub.example\n"), 0o644)
	os.WriteFile(filepath.Join(rel, "fleet-login-new.sh"), []byte("# "+credsepMark+"\n"), 0o755)
	os.WriteFile(filepath.Join(rel, "fleet-login-remove.sh"), []byte("# "+recycleScriptMark+"\n"), 0o755)
	sudoLog = filepath.Join(t.TempDir(), "sudo.log")
	sudo := filepath.Join(t.TempDir(), "sudo")
	body := "#!/bin/sh\nfor x in \"$@\"; do printf '[%s]' \"$x\"; done >> '" + sudoLog + "'\n" +
		"printf ' stdin=' >> '" + sudoLog + "'\ncat >> '" + sudoLog + "'\necho >> '" + sudoLog + "'\nexit " + code + "\n"
	if err := os.WriteFile(sudo, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	old := accountSudo
	accountSudo = sudo
	t.Cleanup(func() { accountSudo = old })
	return a, sudoLog
}

// The seat runs a create as `sudo -n <gate>/fleet-login-new.sh --ticket <t>
// <accountArgv>`, the join code on stdin (never the argv, never an env sudo
// would drop), and says CapAdminSeat — with CapCredsep / CapRecycle read off
// the release the gate runs, not a home it does not have.
func TestAdminSeatRunsThroughTheGate(t *testing.T) {
	shrinkBackoff(t)
	code := "fj_abcdefghijklmnopqrstuvwxyz"
	hub := newAccountHub(t, control.AccountOp{Op: control.AccountCreate, Login: "alice", FullName: "Alice Wang",
		JoinCode: code, Ticket: "v1.payload.sig"})
	a, sudoLog := seatAgent(t, hub.srv.URL, "0")
	runAgentUntil(t, a, 5*time.Second, func() bool { r, _, _ := hub.snapshot(); return len(r) > 0 })

	results, errs, _ := hub.snapshot()
	if len(errs) != 0 || len(results) != 1 {
		t.Fatalf("results=%v errors=%v", results, errs)
	}
	var res control.AccountResult
	json.Unmarshal(results[0].Payload, &res)
	if !res.OK {
		t.Fatalf("result = %+v", res)
	}
	got, _ := os.ReadFile(sudoLog)
	want := "[-n][" + filepath.Join(a.cfg.AdminGateDir, "fleet-login-new.sh") + "][--ticket][v1.payload.sig]" +
		"[alice][--full-name][Alice Wang][--share-pool][--apply] stdin=FLEET_LOGIN_JOIN_CODE=" + code + "\n\n"
	if string(got) != want {
		t.Fatalf("sudo ran\n %q\nwant\n %q", got, want)
	}
	hub.mu.Lock()
	defer hub.mu.Unlock()
	caps := hub.hellos[0].Capabilities
	for _, c := range []string{control.CapAdminSeat, control.CapCredsep, control.CapRecycle, control.CapLoginJoin} {
		if !slices.Contains(caps, c) {
			t.Fatalf("hello caps %v lack %s", caps, c)
		}
	}
}

// A remove carries no stdin: the gate reads a code only for an op that opens.
func TestAdminSeatRemoveArgv(t *testing.T) {
	shrinkBackoff(t)
	hub := newAccountHub(t, control.AccountOp{Op: control.AccountReset, Login: "alice", Ticket: "v1.p.s"})
	a, sudoLog := seatAgent(t, hub.srv.URL, "0")
	runAgentUntil(t, a, 5*time.Second, func() bool { r, _, _ := hub.snapshot(); return len(r) > 0 })
	got, _ := os.ReadFile(sudoLog)
	want := "[-n][" + filepath.Join(a.cfg.AdminGateDir, "fleet-login-remove.sh") + "][--ticket][v1.p.s]" +
		"[alice][--recycle][--keep-home][--apply] stdin=\n"
	if string(got) != want {
		t.Fatalf("sudo ran %q, want %q", got, want)
	}
}

// An op with no ticket is refused before anything runs: the seat has no other
// road to root.
func TestAdminSeatRefusesAnOpWithoutTicket(t *testing.T) {
	shrinkBackoff(t)
	hub := newAccountHub(t, control.AccountOp{Op: control.AccountRemove, Login: "alice"})
	a, sudoLog := seatAgent(t, hub.srv.URL, "0")
	runAgentUntil(t, a, 5*time.Second, func() bool { _, e, _ := hub.snapshot(); return len(e) > 0 })
	_, errs, _ := hub.snapshot()
	if len(errs) != 1 || errs[0].Error == nil || errs[0].Error.Code != control.CodeBadArgs ||
		!strings.Contains(errs[0].Error.Message, "ticket") {
		t.Fatalf("errors = %+v", errs)
	}
	if _, err := os.Stat(sudoLog); err == nil {
		t.Fatal("sudo ran for an op with no ticket")
	}
}

// A failed create is rolled back by the gate, not by the seat: the seat holds
// no remove ticket, so it never runs a second sudo — and it reads the op's mark
// from the gate's directory.
func TestAdminSeatLeavesTheRollbackToTheGate(t *testing.T) {
	shrinkBackoff(t)
	oldExists := accountLoginExists
	accountLoginExists = func(string) bool { return true }
	t.Cleanup(func() { accountLoginExists = oldExists })
	hub := newAccountHub(t, control.AccountOp{Op: control.AccountCreate, Login: "alice", FullName: "Alice", Ticket: "v1.p.s"})
	a, sudoLog := seatAgent(t, hub.srv.URL, "1")
	mark := filepath.Join(a.cfg.AdminGateDir, "alice-onboard")
	os.MkdirAll(mark, 0o755)
	os.WriteFile(filepath.Join(mark, "op"), []byte("op=other\npid=1\nstarted=x\n"), 0o644)
	if a.ownsCreate("alice", hub.op.OpID) || !a.ownsCreate("alice", "other") {
		t.Fatal("the seat does not read the op mark from its gate directory")
	}
	runAgentUntil(t, a, 5*time.Second, func() bool { r, _, _ := hub.snapshot(); return len(r) > 0 })
	results, _, _ := hub.snapshot()
	var res control.AccountResult
	json.Unmarshal(results[0].Payload, &res)
	if res.OK || res.Exit != 1 {
		t.Fatalf("result = %+v", res)
	}
	got, _ := os.ReadFile(sudoLog)
	if n := strings.Count(string(got), "\n"); n != 1 || strings.Contains(string(got), "remove") {
		t.Fatalf("the seat ran more than the create: %q", got)
	}
}

// An admin agent that is not a seat says no CapAdminSeat and runs its own
// login's scripts, byte for byte as before.
func TestAdminAgentWithoutSeatSaysNoSeat(t *testing.T) {
	shrinkBackoff(t)
	hub := newAccountHub(t, control.AccountOp{Op: control.AccountRemove, Login: "alice"})
	a := adminAgent(t, hub.srv.URL, true)
	fakeLoginScripts(t, a.cfg.Home, "0")
	runAgentUntil(t, a, 5*time.Second, func() bool { r, _, _ := hub.snapshot(); return len(r) > 0 })
	hub.mu.Lock()
	defer hub.mu.Unlock()
	if slices.Contains(hub.hellos[0].Capabilities, control.CapAdminSeat) {
		t.Fatal("an admin agent that is no seat listed CapAdminSeat")
	}
}
