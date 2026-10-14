package api

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A spare is ready only while the hub can make a home of it (claude-fleet
// #4234, BREAK-IT trial-seat-no-home). On 2026-10-14 a trial was handed a
// spare held active for six days whose fleet the hub had never seen: the
// claim said 「opening」 and /v1/chat/home 409 no_home until the trial was
// taken back. Now a spare whose fleet is live is handed and becomes the
// person's home; one still unseen spareDeadAfter after its open answered is
// dead — not ready, never claimed (the person waits instead), and the refill
// closes it (a wash where the machine recycles, a remove here) with one
// spare.dead audit line.
func TestTrialSeatNeverAHomelessSpare(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	setHubSetting(t, h.srv, TrialKey, "on")
	sparesOn(t, h, "1")
	openSpares(t, nodes["mac-c"], 1, control.CredsepSeparated)
	macD := openSpares(t, nodes["mac-d"], 1, control.CredsepSeparated)
	readySpares(t, h, "mac-d", 1)
	setHubSetting(t, h.srv, NodeUserCapPrefix+"mac-c", "0") // only mac-d hands one out

	// mac-d's spare brings its fleet up: it is handed, and it is a home.
	loginReportsFleet(t, h, "mac-d", macD[0], "6f1c2a3e-0000-4000-8000-00000000d0d0")
	old := spareDeadAfter
	spareDeadAfter = 50 * time.Millisecond
	t.Cleanup(func() { spareDeadAfter = old })
	time.Sleep(100 * time.Millisecond)
	if r := h.srv.spareReadyHosts()["mac-d"]; r != 1 {
		t.Fatalf("mac-d ready = %d with its spare's fleet live; want 1", r)
	}
	const a, b = "gh:7401", "gh:7402"
	now := time.Now()
	for i, p := range []string{a, b} {
		if err := h.srv.Store.StartTrial(p, now.Add(time.Duration(i)*time.Second)); err != nil {
			t.Fatal(err)
		}
	}
	code, _, out := tryDo(t, h, http.MethodPost, TryClaimPath, a, nil)
	if code != http.StatusOK || (out["state"] != "ready" && out["state"] != "opening") {
		t.Fatalf("a's claim = %d %v; want a seat", code, out)
	}
	if home, ok, err := h.srv.Store.EntryHomeOf(a); err != nil || !ok || home.Login != macD[0] {
		t.Fatalf("a's home = %+v %v %v; want %s on mac-d at the claim", home, ok, err, macD[0])
	}

	// The refill's spare never brings a fleet up (no node of its own).
	m, op := expectAccountOp(t, nodes["mac-d"].tnode)
	if op.Op != control.AccountCreate || !strings.HasPrefix(op.Login, "fleetu") {
		t.Fatalf("refill op = %+v", op)
	}
	dead := op.Login
	sendResult(t, nodes["mac-d"].c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: dead, OK: true,
		Credsep: control.CredsepSeparated})
	waitFor(t, 3*time.Second, dead+" to be active", func() bool {
		for _, a := range mustSpares(t, h) {
			if a.Login == dead && a.State == store.AccountActive {
				return true
			}
		}
		return false
	})
	time.Sleep(100 * time.Millisecond)
	if r := h.srv.spareReadyHosts()["mac-d"]; r != 0 {
		t.Fatalf("mac-d ready = %d with a spare whose fleet never came up; want 0", r)
	}
	// b waits: the homeless spare is never handed.
	code, _, out = tryDo(t, h, http.MethodPost, TryClaimPath, b, nil)
	if code != http.StatusOK || out["state"] != "waiting" {
		t.Fatalf("b's claim with only a dead spare = %d %v; want waiting", code, out)
	}
	if as := mustAccounts(t, h, b); len(as) != 0 {
		t.Fatalf("b was handed %+v; want nothing", as)
	}
	// The refill closes it: mac-d's admin cannot recycle here, so a remove.
	h.srv.replenishSpares(time.Now(), true)
	h.srv.dispatchAccounts()
	_, op = expectAccountOp(t, nodes["mac-d"].tnode)
	if op.Op != control.AccountRemove || op.Login != dead {
		t.Fatalf("heal op = %+v; want the remove of %s", op, dead)
	}
	found := false
	for _, e := range mustAudit(t, h) {
		if e.Action == "spare.dead" && e.Target == dead {
			found = true
		}
	}
	if !found {
		t.Fatalf("no spare.dead audit for %s", dead)
	}
}

// A spare whose fleet is live but whose login the proxy does not serve is
// dead too (claude-fleet#4247, BREAK-IT spare-unserved-handed). On 2026-10-14
// the machine's shared proxy was an orphan that served only the tenants of
// its start (#4245): a later spare's fleet ran, the hub counted it ready, and
// the trial it was handed read «no session credential from the proxy (rc 1)»
// as its first word. Now a node that says cred_served false makes its spare
// not ready and never claimed; one that says true — or says nothing, an older
// node — is handed as before.
func TestTrialSeatNeverAnUnservedSpare(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	setHubSetting(t, h.srv, TrialKey, "on")
	sparesOn(t, h, "1")
	openSpares(t, nodes["mac-c"], 1, control.CredsepSeparated)
	macD := openSpares(t, nodes["mac-d"], 1, control.CredsepSeparated)
	readySpares(t, h, "mac-d", 1)
	setHubSetting(t, h.srv, NodeUserCapPrefix+"mac-c", "0") // only mac-d hands one out

	// mac-d's spare brings its fleet up, but its node says the proxy does not
	// serve it.
	const machine = "6f1c2a3e-0000-4000-8000-00000000d1d1"
	login := macD[0]
	n := connectNode(t, h, "mac-d-"+login, "mac-d", login, false)
	served := func(v *bool) {
		t.Helper()
		beat(t, n.c, control.Proto, control.Heartbeat{Hostname: "mac-d", OSUser: login, MachineID: machine,
			Fleets: []control.Fleet{fakeFleet(t, machine, "fleet", "o/r", "/Users/"+login+"/r")}, ObservedAt: time.Now(),
			Credsep: control.CredsepSeparated, CredServed: v})
	}
	no, yes := false, true
	served(&no)
	waitFor(t, 3*time.Second, login+"@mac-d's fleet to be registered", func() bool {
		return h.srv.loginsWithFleet()[[2]string{"mac-d", login}]
	})
	old := spareDeadAfter
	spareDeadAfter = 50 * time.Millisecond
	t.Cleanup(func() { spareDeadAfter = old })
	time.Sleep(100 * time.Millisecond)
	waitFor(t, 3*time.Second, "the unserved beat to land", func() bool {
		ds := h.srv.deadSpareLogins("mac-d", time.Now())
		return len(ds) == 1 && ds[0] == login
	})
	if r := h.srv.spareReadyHosts()["mac-d"]; r != 0 {
		t.Fatalf("mac-d ready = %d with its spare's login unserved by the proxy; want 0", r)
	}
	const a = "gh:7411"
	if err := h.srv.Store.StartTrial(a, time.Now()); err != nil {
		t.Fatal(err)
	}
	code, _, out := tryDo(t, h, http.MethodPost, TryClaimPath, a, nil)
	if code != http.StatusOK || out["state"] != "waiting" {
		t.Fatalf("a's claim with only an unserved spare = %d %v; want waiting", code, out)
	}
	if as := mustAccounts(t, h, a); len(as) != 0 {
		t.Fatalf("a was handed %+v; want nothing", as)
	}

	// The proxy serves it again (or the node stops saying): it is ready.
	for _, c := range []struct {
		say string
		v   *bool
	}{{"true", &yes}, {"unsaid", nil}} {
		served(c.v)
		waitFor(t, 3*time.Second, "the spare to be ready again", func() bool {
			return len(h.srv.deadSpareLogins("mac-d", time.Now())) == 0
		})
		if r := h.srv.spareReadyHosts()["mac-d"]; r != 1 {
			t.Fatalf("mac-d ready = %d with cred_served %s; want 1", r, c.say)
		}
	}
}
