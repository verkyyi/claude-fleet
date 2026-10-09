package agent

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// accountHub is a hub that sends one account op after the welcome and records
// every account_result / error that comes back. With ackResults it acks them.
type accountHub struct {
	srv        *httptest.Server
	op         control.Message
	ackResults bool
	// dropAfterOp closes the FIRST connection right after sending the op, as
	// a link that dies while the script runs.
	dropAfterOp bool

	mu      sync.Mutex
	dials   int
	results []control.Message
	errors  []control.Message
	hellos  []control.Hello
}

func newAccountHub(t *testing.T, op control.AccountOp) *accountHub {
	t.Helper()
	m, _ := control.New(control.TypeAccountOp, op)
	h := &accountHub{op: m, ackResults: true}
	h.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != control.Path {
			w.Write([]byte(`{}`))
			return
		}
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.CloseNow()
		ctx := r.Context()
		var hello control.Message
		if wsjson.Read(ctx, c, &hello) != nil {
			return
		}
		var hp control.Hello
		json.Unmarshal(hello.Payload, &hp)
		h.mu.Lock()
		h.dials++
		first := h.dials == 1
		h.hellos = append(h.hellos, hp)
		h.mu.Unlock()
		reply, _ := control.New(control.TypeWelcome, control.Welcome{Accepted: true, HubProto: control.Proto, MinProto: control.MinProto})
		reply.OpID = hello.OpID
		if wsjson.Write(ctx, c, reply) != nil {
			return
		}
		if first {
			if wsjson.Write(ctx, c, h.op) != nil {
				return
			}
			if h.dropAfterOp {
				c.Close(websocket.StatusGoingAway, "link lost")
				return
			}
		}
		for {
			var m control.Message
			if wsjson.Read(ctx, c, &m) != nil {
				return
			}
			switch m.Type {
			case control.TypeAccountResult:
				h.mu.Lock()
				h.results = append(h.results, m)
				h.mu.Unlock()
				if h.ackResults {
					wsjson.Write(ctx, c, control.Message{Type: control.TypeAck, OpID: m.OpID, Proto: control.Proto})
				}
			case control.TypeError:
				h.mu.Lock()
				h.errors = append(h.errors, m)
				h.mu.Unlock()
			}
		}
	}))
	t.Cleanup(h.srv.Close)
	return h
}

func (h *accountHub) snapshot() (results, errs []control.Message, dials int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]control.Message(nil), h.results...), append([]control.Message(nil), h.errors...), h.dials
}

// fakeLoginScripts installs fleet-login-new.sh / fleet-login-remove.sh into
// the agent's home that record their argv, one line per run, and exit code.
func fakeLoginScripts(t *testing.T, home string, code string) (newLog, removeLog string) {
	t.Helper()
	bin := filepath.Join(home, ".claude", "fleet", "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	newLog, removeLog = filepath.Join(home, "new.args"), filepath.Join(home, "remove.args")
	for name, logf := range map[string]string{"fleet-login-new.sh": newLog, "fleet-login-remove.sh": removeLog} {
		body := "#!/bin/sh\nfor a in \"$@\"; do printf '[%s]' \"$a\"; done >> '" + logf + "'\necho >> '" + logf + "'\necho ran in $(pwd)\nexit " + code + "\n"
		if err := os.WriteFile(filepath.Join(bin, name), []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return newLog, removeLog
}

func adminAgent(t *testing.T, hub string, admin bool) *Agent {
	t.Helper()
	a := nodeTestAgent(t, hub, true)
	a.cfg.FleetAdmin = admin
	a.cfg.LiveInterval = time.Hour // keep heartbeats out of the way
	return a
}

func runAgentUntil(t *testing.T, a *Agent, d time.Duration, done func() bool) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), d)
	defer cancel()
	go func() {
		for ctx.Err() == nil {
			if done() {
				cancel()
				return
			}
			time.Sleep(20 * time.Millisecond)
		}
	}()
	a.Run(ctx)
}

// The create op runs fleet-login-new.sh with exactly the onboarding argv, from
// /, and its success travels back as an account_result on the op's op_id.
func TestAdminAgentRunsFixedCreateArgv(t *testing.T) {
	shrinkBackoff(t)
	hub := newAccountHub(t, control.AccountOp{Op: control.AccountCreate, Login: "alice", FullName: "Alice Wang"})
	a := adminAgent(t, hub.srv.URL, true)
	newLog, removeLog := fakeLoginScripts(t, a.cfg.Home, "0")

	runAgentUntil(t, a, 5*time.Second, func() bool { r, _, _ := hub.snapshot(); return len(r) > 0 })

	results, errs, _ := hub.snapshot()
	if len(errs) != 0 || len(results) != 1 {
		t.Fatalf("results=%v errors=%v", results, errs)
	}
	if results[0].OpID != hub.op.OpID {
		t.Fatalf("result op_id %s, want %s", results[0].OpID, hub.op.OpID)
	}
	var res control.AccountResult
	json.Unmarshal(results[0].Payload, &res)
	if !res.OK || res.Exit != 0 || res.Login != "alice" || res.Op != control.AccountCreate {
		t.Fatalf("result = %+v", res)
	}
	if !strings.Contains(res.Detail, "ran in /") {
		t.Fatalf("script did not run from /: %q", res.Detail)
	}
	got, _ := os.ReadFile(newLog)
	if want := "[alice][--full-name][Alice Wang][--share-pool][--apply]\n"; string(got) != want {
		t.Fatalf("fleet-login-new.sh argv = %q, want %q", got, want)
	}
	if _, err := os.Stat(removeLog); err == nil {
		t.Fatal("a create op ran the remove script")
	}
	hub.mu.Lock()
	defer hub.mu.Unlock()
	if !hub.hellos[0].Admin {
		t.Fatal("an admin agent did not say so in its hello")
	}
}

func TestAdminAgentRunsFixedRemoveArgv(t *testing.T) {
	shrinkBackoff(t)
	hub := newAccountHub(t, control.AccountOp{Op: control.AccountRemove, Login: "alice"})
	a := adminAgent(t, hub.srv.URL, true)
	newLog, removeLog := fakeLoginScripts(t, a.cfg.Home, "0")
	runAgentUntil(t, a, 5*time.Second, func() bool { r, _, _ := hub.snapshot(); return len(r) > 0 })
	got, _ := os.ReadFile(removeLog)
	if want := "[alice][--keep-home][--apply]\n"; string(got) != want {
		t.Fatalf("fleet-login-remove.sh argv = %q, want %q", got, want)
	}
	if _, err := os.Stat(newLog); err == nil {
		t.Fatal("a remove op ran the create script")
	}
}

// A drill's login is removed without the archive (claude-fleet#2652): the
// hub's drop_home is the one thing that turns --keep-home into --delete-home.
func TestAdminAgentDropHomeDeletesHome(t *testing.T) {
	shrinkBackoff(t)
	hub := newAccountHub(t, control.AccountOp{Op: control.AccountRemove, Login: "drill1009", DropHome: true})
	a := adminAgent(t, hub.srv.URL, true)
	_, removeLog := fakeLoginScripts(t, a.cfg.Home, "0")
	runAgentUntil(t, a, 5*time.Second, func() bool { r, _, _ := hub.snapshot(); return len(r) > 0 })
	got, _ := os.ReadFile(removeLog)
	if want := "[drill1009][--delete-home][--apply]\n"; string(got) != want {
		t.Fatalf("fleet-login-remove.sh argv = %q, want %q", got, want)
	}
}

// A create's join code (claude-fleet#2652) reaches fleet-login-new.sh in its
// environment with this hub's address — never in its argv.
func TestAdminAgentHandsJoinCodeInEnv(t *testing.T) {
	shrinkBackoff(t)
	code := "fj_abcdefghijklmnopqrstuvwxyz"
	hub := newAccountHub(t, control.AccountOp{Op: control.AccountCreate, Login: "alice", FullName: "Alice", JoinCode: code})
	a := adminAgent(t, hub.srv.URL, true)
	newLog, _ := fakeLoginScripts(t, a.cfg.Home, "0")
	runAgentUntil(t, a, 5*time.Second, func() bool { r, _, _ := hub.snapshot(); return len(r) > 0 })
	got, _ := os.ReadFile(newLog)
	if want := "[alice][--full-name][Alice][--share-pool][--apply]\n"; string(got) != want {
		t.Fatalf("argv = %q, want %q (the code never in it)", got, want)
	}
	env := accountEnv(a.cfg.HubURL, control.AccountOp{Op: control.AccountCreate, JoinCode: code})
	joined := strings.Join(env, "\n")
	if !strings.Contains(joined, "FLEET_LOGIN_JOIN_CODE="+code) || !strings.Contains(joined, "FLEET_LOGIN_HUB="+a.cfg.HubURL) {
		t.Fatalf("env lacks the join code / hub")
	}
	if accountEnv(a.cfg.HubURL, control.AccountOp{Op: control.AccountRemove, JoinCode: code}) != nil {
		t.Fatal("a remove got the join code")
	}
	if err := validateAccountOp(control.AccountOp{Op: control.AccountCreate, Login: "alice", FullName: "A", JoinCode: "fj_x; rm -rf /"}, ""); err == nil {
		t.Fatal("a malformed join code was accepted")
	}
}

// An agent not started as the admin agent refuses every account op, and runs
// nothing — whatever the hub believes.
func TestNonAdminAgentRefusesAccountOps(t *testing.T) {
	shrinkBackoff(t)
	hub := newAccountHub(t, control.AccountOp{Op: control.AccountCreate, Login: "alice", FullName: "Alice"})
	a := adminAgent(t, hub.srv.URL, false)
	newLog, _ := fakeLoginScripts(t, a.cfg.Home, "0")

	runAgentUntil(t, a, 5*time.Second, func() bool { _, e, _ := hub.snapshot(); return len(e) > 0 })

	results, errs, _ := hub.snapshot()
	if len(results) != 0 || len(errs) != 1 || errs[0].Error == nil || errs[0].Error.Code != control.CodeNotAdmin || errs[0].OpID != hub.op.OpID {
		t.Fatalf("results=%v errors=%+v; want one NOT_ADMIN refusal", results, errs)
	}
	if _, err := os.Stat(newLog); err == nil {
		t.Fatal("a non-admin agent ran fleet-login-new.sh")
	}
	hub.mu.Lock()
	defer hub.mu.Unlock()
	if hub.hellos[0].Admin {
		t.Fatal("a non-admin agent claimed admin in its hello")
	}
}

// Arguments off the whitelist are refused before anything runs.
func TestAdminAgentRefusesBadArgs(t *testing.T) {
	for _, op := range []control.AccountOp{
		{Op: control.AccountCreate, Login: "-rf", FullName: "x"},
		{Op: control.AccountCreate, Login: "Alice", FullName: "x"},
		{Op: control.AccountCreate, Login: "root", FullName: "x"},
		{Op: control.AccountCreate, Login: "alice", FullName: "--apply"},
		{Op: control.AccountCreate, Login: "alice", FullName: "a\nb"},
		{Op: "delete_everything", Login: "alice"},
	} {
		t.Run(op.Op+"/"+op.Login+"/"+op.FullName, func(t *testing.T) {
			shrinkBackoff(t)
			hub := newAccountHub(t, op)
			a := adminAgent(t, hub.srv.URL, true)
			newLog, removeLog := fakeLoginScripts(t, a.cfg.Home, "0")
			runAgentUntil(t, a, 5*time.Second, func() bool { _, e, _ := hub.snapshot(); return len(e) > 0 })
			_, errs, _ := hub.snapshot()
			if len(errs) != 1 || errs[0].Error.Code != control.CodeBadArgs {
				t.Fatalf("errors = %+v; want one BAD_ARGS", errs)
			}
			for _, f := range []string{newLog, removeLog} {
				if _, err := os.Stat(f); err == nil {
					t.Fatalf("%s ran on a refused op", filepath.Base(f))
				}
			}
		})
	}
}

// Exit 3 is "the login already exists" — reported as such, never as OK.
func TestAdminAgentReportsExisting(t *testing.T) {
	shrinkBackoff(t)
	hub := newAccountHub(t, control.AccountOp{Op: control.AccountCreate, Login: "alice", FullName: "Alice"})
	a := adminAgent(t, hub.srv.URL, true)
	fakeLoginScripts(t, a.cfg.Home, "3")
	runAgentUntil(t, a, 5*time.Second, func() bool { r, _, _ := hub.snapshot(); return len(r) > 0 })
	results, _, _ := hub.snapshot()
	var res control.AccountResult
	json.Unmarshal(results[0].Payload, &res)
	if res.OK || !res.Exists || res.Exit != 3 {
		t.Fatalf("result = %+v; want exists, not ok", res)
	}
}

// A link that drops while the script runs loses nothing: the result goes out
// on the next connection, and the script ran once.
func TestAdminAgentResendsResultAfterReconnect(t *testing.T) {
	shrinkBackoff(t)
	hub := newAccountHub(t, control.AccountOp{Op: control.AccountCreate, Login: "alice", FullName: "Alice"})
	hub.dropAfterOp = true
	a := adminAgent(t, hub.srv.URL, true)
	newLog, _ := fakeLoginScripts(t, a.cfg.Home, "0")
	runAgentUntil(t, a, 5*time.Second, func() bool { r, _, _ := hub.snapshot(); return len(r) > 0 })
	results, _, dials := hub.snapshot()
	if len(results) == 0 || results[0].OpID != hub.op.OpID || dials < 2 {
		t.Fatalf("results=%v dials=%d; want the result re-sent on a later connection", results, dials)
	}
	got, _ := os.ReadFile(newLog)
	if strings.Count(string(got), "\n") != 1 {
		t.Fatalf("script ran %d times, want once: %q", strings.Count(string(got), "\n"), got)
	}
}

// A digit-leading login the hub marks existing (the person's adopted login on
// another machine) is created on macOS with the same fixed argv; unmarked, all
// digits, or on Linux it is refused before anything runs (claude-fleet#2105).
func TestAdminAgentCreatesExistingDigitLogin(t *testing.T) {
	old := accountGOOS
	t.Cleanup(func() { accountGOOS = old })

	accountGOOS = "darwin"
	shrinkBackoff(t)
	hub := newAccountHub(t, control.AccountOp{Op: control.AccountCreate, Login: "24haowan", FullName: "Cao Jian", Existing: true})
	a := adminAgent(t, hub.srv.URL, true)
	newLog, _ := fakeLoginScripts(t, a.cfg.Home, "0")
	runAgentUntil(t, a, 5*time.Second, func() bool { r, _, _ := hub.snapshot(); return len(r) > 0 })
	results, errs, _ := hub.snapshot()
	if len(errs) != 0 || len(results) != 1 {
		t.Fatalf("results=%v errors=%v", results, errs)
	}
	got, _ := os.ReadFile(newLog)
	if want := "[24haowan][--full-name][Cao Jian][--share-pool][--apply]\n"; string(got) != want {
		t.Fatalf("fleet-login-new.sh argv = %q, want %q", got, want)
	}

	for name, c := range map[string]struct {
		goos string
		op   control.AccountOp
	}{
		"unmarked":   {"darwin", control.AccountOp{Op: control.AccountCreate, Login: "24haowan", FullName: "x"}},
		"all digits": {"darwin", control.AccountOp{Op: control.AccountCreate, Login: "2468", FullName: "x", Existing: true}},
		"linux":      {"linux", control.AccountOp{Op: control.AccountCreate, Login: "24haowan", FullName: "x", Existing: true}},
	} {
		t.Run(name, func(t *testing.T) {
			accountGOOS = c.goos
			shrinkBackoff(t)
			hub := newAccountHub(t, c.op)
			a := adminAgent(t, hub.srv.URL, true)
			newLog, _ := fakeLoginScripts(t, a.cfg.Home, "0")
			runAgentUntil(t, a, 5*time.Second, func() bool { _, e, _ := hub.snapshot(); return len(e) > 0 })
			_, errs, _ := hub.snapshot()
			if len(errs) != 1 || errs[0].Error.Code != control.CodeBadArgs {
				t.Fatalf("errors = %+v; want one BAD_ARGS", errs)
			}
			if c.goos == "linux" && !strings.Contains(errs[0].Error.Message, "macOS") {
				t.Fatalf("linux refusal does not say why: %q", errs[0].Error.Message)
			}
			if _, err := os.Stat(newLog); err == nil {
				t.Fatal("fleet-login-new.sh ran on a refused op")
			}
		})
	}
}

// A fleet-login-new.sh that separates the logins it opens (claude-fleet#2294):
// the admin agent says CapCredsep in its hello, and a create that ends with
// `credsep: separated` carries AccountResult.Credsep "separated"; one that ends
// otherwise (pending / off) carries nothing. A script from before #2294 — no
// such words — earns neither (TestAdminAgentRunsFixedCreateArgv's fake).
func TestAdminAgentSaysCredsep(t *testing.T) {
	for _, tc := range []struct{ last, want string }{
		{"credsep: separated", control.CredsepSeparated},
		{"credsep: pending — proxy not running", ""},
		{"credsep: off (--no-credsep)", ""},
	} {
		shrinkBackoff(t)
		hub := newAccountHub(t, control.AccountOp{Op: control.AccountCreate, Login: "alice", FullName: "Alice Wang"})
		a := adminAgent(t, hub.srv.URL, true)
		fakeLoginScripts(t, a.cfg.Home, "0")
		body := "#!/bin/sh\n# --no-credsep … credsep: separated\necho step 7b\necho '" + tc.last + "'\n"
		if err := os.WriteFile(filepath.Join(a.cfg.Home, loginNewScript), []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
		runAgentUntil(t, a, 5*time.Second, func() bool { r, _, _ := hub.snapshot(); return len(r) > 0 })
		results, _, _ := hub.snapshot()
		if len(results) != 1 {
			t.Fatalf("%q: results=%v", tc.last, results)
		}
		var res control.AccountResult
		json.Unmarshal(results[0].Payload, &res)
		if !res.OK || res.Credsep != tc.want {
			t.Fatalf("%q: result = %+v, want credsep %q", tc.last, res, tc.want)
		}
		hub.mu.Lock()
		caps := strings.Join(hub.hellos[0].Capabilities, ",")
		hub.mu.Unlock()
		if !strings.Contains(","+caps+",", ","+control.CapCredsep+",") {
			t.Fatalf("hello capabilities %s lack %s", caps, control.CapCredsep)
		}
	}
}

// No separating script (or not the admin agent): no CapCredsep in the hello.
func TestCredsepCapableNeedsTheScript(t *testing.T) {
	home := t.TempDir()
	if credsepCapable(home) {
		t.Fatal("no script, yet credsep capable")
	}
	fakeLoginScripts(t, home, "0")
	if credsepCapable(home) {
		t.Fatal("a script from before #2294 counted as separating")
	}
	if credsepResult("x\ncredsep: separated\n\n") != control.CredsepSeparated || credsepResult("credsep: separated\nmore") != "" {
		t.Fatal("credsepResult reads the wrong line")
	}
}
