package agent

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// A Linux managed machine opens its own logins on the machine link's own half
// (claude-fleet#3210, EPIC #3208 C2).

const testOpener = "/opt/claude-fleet/current/bin/fleet-node-linux.py"

// machineAcctHub is a hub that takes the machine hello, then sends ops on the
// machine's own half (Login ""), records what comes back and acks results.
type machineAcctHub struct {
	srv  *httptest.Server
	ops  chan control.Message
	mu   sync.Mutex
	caps []string
	got  []control.Message
}

func newMachineAcctHub(t *testing.T) *machineAcctHub {
	t.Helper()
	h := &machineAcctHub{ops: make(chan control.Message, 16)}
	h.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
		_ = json.Unmarshal(hello.Payload, &hp)
		h.mu.Lock()
		h.caps = hp.Capabilities
		h.mu.Unlock()
		welcome, _ := control.New(control.TypeWelcome, control.Welcome{Accepted: true, HubProto: control.Proto, MinProto: control.MinProto})
		if wsjson.Write(ctx, c, welcome) != nil {
			return
		}
		go func() {
			for m := range h.ops {
				if wsjson.Write(ctx, c, m) != nil {
					return
				}
			}
		}()
		for {
			var m control.Message
			if wsjson.Read(ctx, c, &m) != nil {
				return
			}
			if m.Type == control.TypeHeartbeat {
				continue
			}
			h.mu.Lock()
			h.got = append(h.got, m)
			h.mu.Unlock()
			if m.Type == control.TypeAccountResult {
				_ = wsjson.Write(ctx, c, control.Message{Type: control.TypeAck, OpID: m.OpID, Proto: control.Proto})
			}
		}
	}))
	t.Cleanup(func() { close(h.ops); h.srv.Close() })
	return h
}

func (h *machineAcctHub) send(t *testing.T, op control.AccountOp) control.Message {
	t.Helper()
	m, err := control.New(control.TypeAccountOp, op)
	if err != nil {
		t.Fatal(err)
	}
	h.ops <- m
	return m
}

// answer waits for the message that answers opID.
func (h *machineAcctHub) answer(t *testing.T, opID string) control.Message {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		h.mu.Lock()
		for _, m := range h.got {
			if m.OpID == opID {
				h.mu.Unlock()
				return m
			}
		}
		h.mu.Unlock()
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("no answer to op %s", opID)
	return control.Message{}
}

// fakeOpener records every account command (argv + the env it was handed)
// and runs `sh -c script` in its place.
type fakeOpener struct {
	mu   sync.Mutex
	runs [][]string
	envs [][]string
}

func installFakeOpener(t *testing.T, script func(args []string) string) *fakeOpener {
	t.Helper()
	f := &fakeOpener{}
	old := accountCommand
	accountCommand = func(ctx context.Context, name string, args ...string) *exec.Cmd {
		f.mu.Lock()
		f.runs = append(f.runs, append([]string{name}, args...))
		f.mu.Unlock()
		cmd := exec.CommandContext(ctx, "/bin/sh", "-c", script(args))
		return cmd
	}
	t.Cleanup(func() { accountCommand = old })
	return f
}

func (f *fakeOpener) snapshot() [][]string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([][]string(nil), f.runs...)
}

func runMachineLink(t *testing.T, mc MachineConfig) *machineLink {
	t.Helper()
	ml := newMachineLink(mc)
	ml.acct = newMachineAccounts(mc)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go ml.run(ctx)
	return ml
}

func linuxMachineConfig(t *testing.T, hub string) MachineConfig {
	dir := t.TempDir()
	return MachineConfig{HubURL: hub, Token: "machine", LiveInterval: time.Hour,
		AccountOpener: testOpener, AccountState: filepath.Join(dir, "agent", "_machine"),
		ServiceLogin: "fleet", LinuxTenants: filepath.Join(dir, "linux-tenants")}
}

// The two fixed argvs, as root, the join code and op_id in the environment —
// and the hello says the machine opens its logins.
func TestMachineOpensLoginsWithFixedArgv(t *testing.T) {
	shrinkBackoff(t)
	envFile := filepath.Join(t.TempDir(), "env")
	f := installFakeOpener(t, func(args []string) string {
		return "env | grep '^FLEET_LOGIN_' > " + envFile + "; echo 'credsep: separated'"
	})
	hub := newMachineAcctHub(t)
	runMachineLink(t, linuxMachineConfig(t, hub.srv.URL))
	code := "fj_" + strings.Repeat("a", 26)
	m := hub.send(t, control.AccountOp{Op: control.AccountCreate, Login: "24haowan", Existing: true,
		FullName: "Arvin, Wang", JoinCode: code})
	r := hub.answer(t, m.OpID)
	var res control.AccountResult
	_ = json.Unmarshal(r.Payload, &res)
	if r.Type != control.TypeAccountResult || !res.OK || res.Credsep != control.CredsepSeparated || r.Login != "" {
		t.Fatalf("create answered %+v %+v", r, res)
	}
	hub.mu.Lock()
	caps := hub.caps
	hub.mu.Unlock()
	if !hasCap(caps, control.CapLoginJoin) {
		t.Fatalf("machine hello caps %v lack %s", caps, control.CapLoginJoin)
	}
	want := []string{serviceCtlPython, "-I", testOpener, "login", "open", "24haowan", "--full-name", "Arvin Wang"}
	runs := f.snapshot()
	if len(runs) != 1 || !reflect.DeepEqual(runs[0], want) {
		t.Fatalf("create ran %q; want %q", runs, want)
	}
	for _, a := range runs[0] {
		if strings.Contains(a, code) {
			t.Fatal("the join code is in argv")
		}
	}
	envb, _ := os.ReadFile(envFile)
	env := strings.Split(strings.TrimSpace(string(envb)), "\n")
	if !hasEnv(env, "FLEET_LOGIN_JOIN_CODE="+code) || !hasEnv(env, "FLEET_LOGIN_OP_ID="+m.OpID) {
		t.Fatalf("the create's environment %q lacks its join code or op_id", env)
	}

	m = hub.send(t, control.AccountOp{Op: control.AccountRemove, Login: "drill2"})
	hub.answer(t, m.OpID)
	want = []string{serviceCtlPython, "-I", testOpener, "login", "remove", "drill2", "--keep-home"}
	if runs = f.snapshot(); len(runs) != 2 || !reflect.DeepEqual(runs[1], want) {
		t.Fatalf("remove ran %q; want %q", runs, want)
	}
}

// BREAK-IT linux-hub-other-root-op: anything but the two ops on a fresh,
// well-formed login is refused BAD_ARGS and runs nothing.
func TestMachineRefusesOtherRootOps(t *testing.T) {
	shrinkBackoff(t)
	f := installFakeOpener(t, func([]string) string { return "exit 0" })
	hub := newMachineAcctHub(t)
	runMachineLink(t, linuxMachineConfig(t, hub.srv.URL))
	for name, op := range map[string]control.AccountOp{
		"another op":       {Op: "exec", Login: "drill2"},
		"root":             {Op: control.AccountRemove, Login: "root"},
		"the service":      {Op: control.AccountRemove, Login: "fleet"},
		"the credsep role": {Op: control.AccountRemove, Login: "fleetcred"},
		"all digits":       {Op: control.AccountCreate, Login: "1234", Existing: true, FullName: "x"},
		"digit, not held":  {Op: control.AccountCreate, Login: "24haowan", FullName: "x"},
		"a flag login":     {Op: control.AccountCreate, Login: "--uid=0", FullName: "x"},
		"a bad name":       {Op: control.AccountCreate, Login: "drill2", FullName: "a\nb"},
		"a bad join code":  {Op: control.AccountCreate, Login: "drill2", FullName: "x", JoinCode: "fj_x; rm -rf /"},
		"a remove's code":  {Op: control.AccountRemove, Login: "drill2", JoinCode: "fj_" + strings.Repeat("a", 26)},
	} {
		m := hub.send(t, op)
		r := hub.answer(t, m.OpID)
		if r.Type != control.TypeError || r.Error == nil || r.Error.Code != control.CodeBadArgs {
			t.Errorf("%s: answered %+v; want BAD_ARGS", name, r)
		}
	}
	if runs := f.snapshot(); len(runs) != 0 {
		t.Fatalf("a refused op ran %q", runs)
	}
}

// A create that fails after its own run declared the login is rolled back —
// the login removed with its home.
func TestMachineRollsBackItsFailedCreate(t *testing.T) {
	shrinkBackoff(t)
	oldExists := accountLoginExists
	accountLoginExists = func(string) bool { return true }
	t.Cleanup(func() { accountLoginExists = oldExists })
	hub := newMachineAcctHub(t)
	mc := linuxMachineConfig(t, hub.srv.URL)
	if err := os.MkdirAll(mc.LinuxTenants, 0o700); err != nil {
		t.Fatal(err)
	}
	var opID string
	f := installFakeOpener(t, func(args []string) string {
		if args[3] == "open" {
			decl, _ := json.Marshal(map[string]any{"login": "drill2", "uid": 10003, "gid": 10003, "op": opID})
			return "printf '%s' '" + string(decl) + "' > " + filepath.Join(mc.LinuxTenants, "drill2.json") + "; exit 1"
		}
		return "echo 'credsep: purged'"
	})
	runMachineLink(t, mc)
	m, _ := control.New(control.TypeAccountOp, control.AccountOp{Op: control.AccountCreate, Login: "drill2", FullName: "D"})
	opID = m.OpID
	hub.ops <- m
	r := hub.answer(t, m.OpID)
	var res control.AccountResult
	_ = json.Unmarshal(r.Payload, &res)
	if res.OK || !strings.Contains(res.Detail, "rolled back") {
		t.Fatalf("failed create answered %+v", res)
	}
	runs := f.snapshot()
	want := []string{serviceCtlPython, "-I", testOpener, "login", "remove", "drill2", "--delete-home"}
	if len(runs) != 2 || !reflect.DeepEqual(runs[1], want) {
		t.Fatalf("rollback ran %q; want %q", runs, want)
	}
}

// A Mac's machine program (no opener) is byte for byte as before: no
// CapLoginJoin in its hello, and an account op is refused NOT_ADMIN.
func TestMachineAccountOpsOffAddsNothing(t *testing.T) {
	shrinkBackoff(t)
	f := installFakeOpener(t, func([]string) string { return "exit 0" })
	hub := newMachineAcctHub(t)
	runMachineLink(t, MachineConfig{HubURL: hub.srv.URL, Token: "machine", LiveInterval: time.Hour})
	m := hub.send(t, control.AccountOp{Op: control.AccountCreate, Login: "drill2", FullName: "D"})
	r := hub.answer(t, m.OpID)
	if r.Type != control.TypeError || r.Error == nil || r.Error.Code != control.CodeNotAdmin {
		t.Fatalf("answered %+v; want NOT_ADMIN", r)
	}
	hub.mu.Lock()
	caps := hub.caps
	hub.mu.Unlock()
	if !reflect.DeepEqual(caps, []string{control.CapMachine}) {
		t.Fatalf("hello caps %v; want only %s", caps, control.CapMachine)
	}
	if runs := f.snapshot(); len(runs) != 0 {
		t.Fatalf("ran %q", runs)
	}
}

func hasCap(caps []string, c string) bool {
	for _, x := range caps {
		if x == c {
			return true
		}
	}
	return false
}

func hasEnv(env []string, kv string) bool {
	for _, x := range env {
		if x == kv {
			return true
		}
	}
	return false
}
