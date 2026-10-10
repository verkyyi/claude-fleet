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

// claude-fleet#2918: the node supervisor restarted the machine's agent
// (logins/*.env changed) while it ran the very create that changed it; the
// result lived in memory only and the hub's op stayed unknown for good.

func readBook(t *testing.T, path string) accountBook {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var b accountBook
	if err := json.Unmarshal(data, &b); err != nil {
		t.Fatal(err)
	}
	return b
}

// The op running is on disk while it runs (what the supervisor reads), and
// leaves the "inflight" key the moment its result is in.
func TestAccountBookMarksTheOpRunning(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent", accountOpsFile)
	var o accountOps
	o.load(path)
	if !o.claim("op-1", control.AccountOp{Op: control.AccountCreate, Login: "alice", JoinCode: "fj_secret"}) {
		t.Fatal("first claim refused")
	}
	b := readBook(t, path)
	if f, ok := b.Inflight["op-1"]; !ok || f.Login != "alice" || f.Op != control.AccountCreate || f.PID != os.Getpid() {
		t.Fatalf("inflight = %+v; want op-1 creating alice by this pid", b.Inflight)
	}
	raw, _ := os.ReadFile(path)
	if strings.Contains(string(raw), "fj_secret") {
		t.Fatal("the book carries the join code")
	}
	if fi, _ := os.Stat(path); fi.Mode().Perm() != 0o600 {
		t.Fatalf("book mode %v, want 0600", fi.Mode().Perm())
	}
	m, _ := control.New(control.TypeAccountResult, control.AccountResult{Op: control.AccountCreate, Login: "alice", OK: true})
	m.OpID = "op-1"
	o.deliver(m)
	b = readBook(t, path)
	if len(b.Inflight) != 0 || b.Outbox["op-1"].OpID != "op-1" {
		t.Fatalf("after the result: inflight=%v outbox=%v", b.Inflight, b.Outbox)
	}
	o.acked("op-1")
	if b = readBook(t, path); len(b.Outbox) != 0 {
		t.Fatalf("acked result still in the outbox: %v", b.Outbox)
	}
}

// A new process reads the book: an op_id it saw is never run again, a result
// not acked is still owed, and an op cut off mid-run is answered.
func TestAccountBookSurvivesARestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), accountOpsFile)
	exists := map[string]bool{"half": true}
	old := accountLoginExists
	accountLoginExists = func(l string) bool { return exists[l] }
	t.Cleanup(func() { accountLoginExists = old })

	var o1 accountOps
	o1.load(path)
	o1.claim("done", control.AccountOp{Op: control.AccountCreate, Login: "bob"})
	m, _ := control.New(control.TypeAccountResult, control.AccountResult{Op: control.AccountCreate, Login: "bob", OK: true})
	m.OpID = "done"
	o1.deliver(m)
	o1.claim("cut", control.AccountOp{Op: control.AccountCreate, Login: "half"})
	o1.claim("cut2", control.AccountOp{Op: control.AccountCreate, Login: "never"})
	o1.claim("gone", control.AccountOp{Op: control.AccountRemove, Login: "carol"})

	var o2 accountOps // the restarted agent
	o2.load(path)
	for _, id := range []string{"done", "cut", "cut2", "gone"} {
		if o2.claim(id, control.AccountOp{}) {
			t.Fatalf("op %s would run again after a restart", id)
		}
	}
	res := func(id string) control.AccountResult {
		var r control.AccountResult
		json.Unmarshal(o2.outbox[id].Payload, &r)
		if o2.outbox[id].OpID != id {
			t.Fatalf("no result owed for %s", id)
		}
		return r
	}
	if r := res("done"); !r.OK {
		t.Fatalf("done = %+v; want the stored ok result", r)
	}
	if r := res("cut"); r.OK || r.Exit != -1 || !strings.Contains(r.Detail, "exists on this machine") {
		t.Fatalf("cut = %+v; want failed, the login half made", r)
	}
	if r := res("cut2"); r.OK || !strings.Contains(r.Detail, "nothing was made") {
		t.Fatalf("cut2 = %+v; want failed, nothing made", r)
	}
	if r := res("gone"); r.Exit != control.RemoveExitNoLogin {
		t.Fatalf("gone = %+v; want the no-such-login exit (the hub reads it removed)", r)
	}
	if b := readBook(t, path); len(b.Inflight) != 0 {
		t.Fatalf("still marked running after the restart: %v", b.Inflight)
	}
}

// End to end: an agent restarted mid-create answers the hub with the op's own
// op_id on its first connection, and a hub re-asking the op runs nothing.
func TestAdminAgentAnswersAnOpCutOffByARestart(t *testing.T) {
	shrinkBackoff(t)
	hub := newAccountHub(t, control.AccountOp{Op: control.AccountCreate, Login: "alice", FullName: "Alice"})
	a := adminAgent(t, hub.srv.URL, true)
	newLog, _ := fakeLoginScripts(t, a.cfg.Home, "0")
	// what the killed process left behind: the hub's op, marked running
	book := filepath.Join(a.cfg.StateDir, accountOpsFile)
	var dead accountOps
	dead.load(book)
	dead.claim(hub.op.OpID, control.AccountOp{Op: control.AccountCreate, Login: "alice"})
	old := accountLoginExists
	accountLoginExists = func(string) bool { return true }
	t.Cleanup(func() { accountLoginExists = old })
	a.acct = accountOps{}
	a.acct.load(book)

	runAgentUntil(t, a, 5*time.Second, func() bool { r, _, _ := hub.snapshot(); return len(r) > 0 })
	results, _, _ := hub.snapshot()
	if len(results) == 0 || results[0].OpID != hub.op.OpID {
		t.Fatalf("results = %v; want the cut-off op answered", results)
	}
	var res control.AccountResult
	json.Unmarshal(results[0].Payload, &res)
	if res.OK || res.Login != "alice" {
		t.Fatalf("result = %+v; want a failure naming alice", res)
	}
	if got, _ := os.ReadFile(newLog); len(got) != 0 {
		t.Fatalf("the re-asked op ran the script again: %q", got)
	}
}
