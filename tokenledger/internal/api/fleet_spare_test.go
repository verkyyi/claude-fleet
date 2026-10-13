package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#2263 (EPIC #2259 C4): every host machine keeps logins opened
// ahead of a newcomer, so their first sign-in is ready at once. A spare is
// handed out only when it came back credential-separated (#2294), mapped —
// never renamed; the count is min(fleet.spare_max, the machine's login cap −
// the logins handed out); a machine 维护中, without credsep or failed gets
// none; a spare is nobody in the people views. Off (fleet.spares) adds
// nothing.

// connectCaps is connectNode with the hello listing caps.
func connectCaps(t *testing.T, h *harness, label, hostname, osUser string, admin bool, caps ...string) *fleetNode {
	t.Helper()
	tok := h.enroll(t, label)
	id := "ep_" + label
	ident := model.Identity{AccountUUID: "acct-" + label, Hostname: hostname, OSUser: osUser}
	if err := h.srv.Store.UpsertAccount(ident, "max", ""); err != nil {
		t.Fatal(err)
	}
	if _, _, err := h.srv.Store.TouchEndpoint(id, ident, "test", true, nil); err != nil {
		t.Fatal(err)
	}
	n := &fleetNode{token: tok, id: id}
	n.tnode = dialAdminCaps(t, h, tok, admin, caps...)
	beat(t, n.c, control.Proto, control.Heartbeat{Hostname: hostname, OSUser: osUser})
	return n
}

// spareFleet is four admin machines: mac-c busy, mac-d quiet (both separate
// credentials), m6 the same but 维护中, m7 (3 sessions) whose node does not
// separate credentials. Routes let /v1/fleet/home answer a machine.
func spareFleet(t *testing.T, h *harness) map[string]*fleetNode {
	t.Helper()
	h.srv.FleetAdmins = []string{"ivan"}
	nodes := map[string]*fleetNode{}
	for _, m := range []struct {
		host     string
		credsep  bool
		sessions int
	}{{"mac-c", true, 5}, {"mac-d", true, 1}, {"m6", true, 0}, {"m7", false, 3}} {
		var caps []string
		if m.credsep {
			caps = []string{control.CapCredsep}
		}
		n := connectCaps(t, h, m.host+"-op", m.host, "ivan", true, caps...)
		beatCount(t, n, m.host, "ivan", m.sessions)
		nodes[m.host] = n
	}
	if _, _, err := h.srv.enterMaintenance("m6", "drill", "test", time.Now()); err != nil {
		t.Fatal(err)
	}
	routes, err := ParseFleetRoutes(`[{"hostname":"mac-c","routes":[{"name":"public","host":"203.0.113.4"}]},
	  {"hostname":"mac-d","routes":[{"name":"public","host":"203.0.113.5"}]}]`)
	if err != nil {
		t.Fatal(err)
	}
	h.srv.FleetRoutes = routes
	waitFor(t, 3*time.Second, "the roster to carry every beat", func() bool {
		return h.srv.leastBusyMachine(time.Now()) == "mac-d"
	})
	return nodes
}

// openSpares answers count creates on n, with credsep as the result's word,
// and returns their logins.
func openSpares(t *testing.T, n *fleetNode, count int, credsep string) []string {
	t.Helper()
	var logins []string
	for i := 0; i < count; i++ {
		m, op := expectAccountOp(t, n.tnode)
		if op.Op != control.AccountCreate || !strings.HasPrefix(op.Login, "fleetu") || op.FullName != store.SpareFullName {
			t.Fatalf("op = %+v; want a create of a spare fleetu…", op)
		}
		sendResult(t, n.c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true, Credsep: credsep})
		logins = append(logins, op.Login)
	}
	return logins
}

// noOp says hosts are sent no account op.
func noOp(t *testing.T, nodes map[string]*fleetNode, hosts ...string) {
	t.Helper()
	for _, host := range hosts {
		if got, ok := readMsg(nodes[host].tnode, 250*time.Millisecond); ok && got.Type == control.TypeAccountOp {
			t.Fatalf("%s was sent %+v", host, got)
		}
	}
}

// sparesOn turns spares on at max per machine and runs the refill once.
func sparesOn(t *testing.T, h *harness, max string) {
	t.Helper()
	setHubSetting(t, h.srv, SparesKey, "on")
	setHubSetting(t, h.srv, SpareMaxKey, max)
	h.srv.replenishSpares(time.Now(), true)
	h.srv.dispatchAccounts()
}

func TestSpareHandedToANewcomerAndRefilled(t *testing.T) {
	h := newFleetHarness(t)
	const p = "gh:6001"
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	setHubSetting(t, h.srv, AutoAssignKey, "least-busy")
	sparesOn(t, h, "1")
	openSpares(t, nodes["mac-c"], 1, control.CredsepSeparated)
	macD := openSpares(t, nodes["mac-d"], 1, control.CredsepSeparated)
	// 维护中 (m6) and a node that does not separate credentials (m7): none.
	noOp(t, nodes, "m6", "m7")
	waitFor(t, 3*time.Second, "both spares to be ready", func() bool {
		r := h.srv.spareReadyHosts()
		return r["mac-c"] == 1 && r["mac-d"] == 1
	})

	listPerson(t, h, p, "LiSi")
	t0 := time.Now()
	code, body := asUID(t, h, http.MethodGet, control.HomePath, p, "", nil)
	took := time.Since(t0)
	var home struct {
		Login   string `json:"login"`
		Machine *struct {
			Hostname string `json:"hostname"`
		} `json:"machine"`
	}
	_ = json.Unmarshal(body, &home)
	if code != http.StatusOK || home.Machine == nil || home.Machine.Hostname != "mac-d" || home.Login != macD[0] {
		t.Fatalf("home: HTTP %d %s; want mac-d under its spare login %s at once", code, body, macD[0])
	}
	if took > 3*time.Second {
		t.Fatalf("home took %v; want ≤ 3s", took)
	}
	// Mapped, not renamed: the person's login IS the spare's name.
	if pr, err := h.srv.Store.Principal(p); err != nil || pr.Login != macD[0] || pr.DisplayName == store.SpareFullName {
		t.Fatalf("principal = %+v, %v", pr, err)
	}
	if a := accountState(t, h, p, "mac-d"); a.State != store.AccountActive || a.Login != macD[0] {
		t.Fatalf("account = %+v", a)
	}
	// The spare taken is refilled on its own; the other machine's stays.
	_, op := expectAccountOp(t, nodes["mac-d"].tnode)
	if op.Op != control.AccountCreate || !strings.HasPrefix(op.Login, "fleetu") || op.Login == macD[0] {
		t.Fatalf("refill op = %+v", op)
	}
	noOp(t, nodes, "mac-c")
}

// The count is min(fleet.spare_max, the machine's login cap − the logins
// handed out), and a machine over it shrinks: the newest ready spares close.
func TestSpareCountFollowsTheMachinesRoom(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	setHubSetting(t, h.srv, NodeUserCapPrefix+"mac-c", "3")
	// Two logins already handed out on mac-c.
	for _, id := range []string{"gh:7001", "gh:7002"} {
		p, err := h.srv.Store.AdoptPrincipal(id, "u"+id[3:], "", time.Now())
		if err != nil {
			t.Fatal(err)
		}
		if err := h.srv.Store.AdoptAccount(p, "mac-c", time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	sparesOn(t, h, "5")
	openSpares(t, nodes["mac-c"], 1, control.CredsepSeparated) // 3 − 2 = 1
	openSpares(t, nodes["mac-d"], 5, control.CredsepSeparated) // min(5, 10 − 0)
	noOp(t, nodes, "mac-c")
	waitFor(t, 3*time.Second, "the spares to be ready", func() bool {
		r := h.srv.spareReadyHosts()
		return r["mac-c"] == 1 && r["mac-d"] == 5
	})

	var snap NodesSnapshot
	h.getJSON(t, "/v1/nodes", &snap)
	seen := false
	for _, m := range snap.Machines {
		if m.Hostname != "mac-c" {
			continue
		}
		seen = true
		if m.Spare == nil || *m.Spare != 1 || m.LoginsUsed == nil || *m.LoginsUsed != 2 || m.LoginCap == nil || *m.LoginCap != 3 {
			t.Fatalf("mac-c = spare %v used %v cap %v; want 1 · 2 / 3", m.Spare, m.LoginsUsed, m.LoginCap)
		}
	}
	if !seen {
		t.Fatal("mac-c is not on the operator's roster")
	}

	// The cap comes down: mac-d's newest spares close until it holds 2.
	setHubSetting(t, h.srv, SpareMaxKey, "2")
	h.srv.replenishSpares(time.Now(), true)
	h.srv.dispatchAccounts()
	for i := 0; i < 3; i++ {
		if _, op := expectAccountOp(t, nodes["mac-d"].tnode); op.Op != control.AccountRemove || !strings.HasPrefix(op.Login, "fleetu") {
			t.Fatalf("shrink op = %+v; want a remove of a spare", op)
		}
	}
	noOp(t, nodes, "mac-d")
}

// A spare whose create did not come back credential-separated is never
// handed out, and stops that machine's refill until the operator looks.
func TestSpareUnseparatedIsNeverHandedOut(t *testing.T) {
	h := newFleetHarness(t)
	const p = "gh:6005"
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	setHubSetting(t, h.srv, AutoAssignKey, "least-busy")
	sparesOn(t, h, "1")
	openSpares(t, nodes["mac-c"], 1, control.CredsepSeparated)
	openSpares(t, nodes["mac-d"], 1, "") // a node that did not say separated
	waitFor(t, 3*time.Second, "mac-d's spare to fail and mac-c's to be ready", func() bool {
		pic, _ := h.srv.sparePicture()
		return pic["mac-d"] != nil && pic["mac-d"].Failed && pic["mac-c"] != nil && pic["mac-c"].Ready == 1
	})
	if h.srv.replenishSpares(time.Now(), true) {
		t.Fatal("the refill queued again beside a failed spare")
	}
	listPerson(t, h, p, "")
	h.srv.onPrincipalSignIn(p, "")
	if a := accountState(t, h, p, "mac-c"); a.State != store.AccountActive || !strings.HasPrefix(a.Login, "fleetu") {
		t.Fatalf("account on mac-c = %+v; want mac-c's separated spare (mac-d's is not handed out)", a)
	}
}

// A spare is nobody: no people list, no person's roster; the operator sees
// counts per machine and the rows apart in /v1/fleet/accounts.
func TestSpareIsInNoPeopleView(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	sparesOn(t, h, "1")
	openSpares(t, nodes["mac-c"], 1, control.CredsepSeparated)
	openSpares(t, nodes["mac-d"], 1, control.CredsepSeparated)
	waitFor(t, 3*time.Second, "both spares to be ready", func() bool {
		r := h.srv.spareReadyHosts()
		return r["mac-c"] == 1 && r["mac-d"] == 1
	})
	ps, err := h.srv.Store.Principals()
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range ps {
		if store.IsSparePrincipal(p.ID) {
			t.Fatalf("Principals lists a spare: %+v", p)
		}
	}
	var view FleetAccountsView
	h.getJSON(t, "/v1/fleet/accounts", &view)
	if len(view.Accounts) != 0 || len(view.Spares) != 2 {
		t.Fatalf("accounts view: %d accounts, %d spares; want 0 and 2", len(view.Accounts), len(view.Spares))
	}
	const p = "gh:6002"
	listPerson(t, h, p, "")
	_, body := asUID(t, h, http.MethodGet, "/v1/nodes", p, "", nil)
	if strings.Contains(string(body), `"spare"`) || strings.Contains(string(body), `"login_cap"`) {
		t.Fatalf("a person's roster carries the spare counts: %s", body)
	}
}

// spare-login-empty (docs/BREAK-IT.md): no spare ready (the refill still
// running) ⇒ the newcomer's login is opened as before, and every door says
// 「正在开」 with its ETA — never a silent wait, never a half-ready spare.
func TestSpareEmptyFallsBackToOpening(t *testing.T) {
	h := newFleetHarness(t)
	const p = "gh:6003"
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	setHubSetting(t, h.srv, AutoAssignKey, "least-busy")
	sparesOn(t, h, "1")
	expectAccountOp(t, nodes["mac-c"].tnode) // sent, never answered: creating
	expectAccountOp(t, nodes["mac-d"].tnode)

	listPerson(t, h, p, "WangWu")
	code, body := asUID(t, h, http.MethodGet, control.HomePath, p, "", nil)
	var home map[string]any
	_ = json.Unmarshal(body, &home)
	if code != http.StatusServiceUnavailable || home["code"] != "opening" {
		t.Fatalf("home with no ready spare: HTTP %d %s; want opening", code, body)
	}
	if eta, _ := home["eta_s"].(float64); eta < 5 {
		t.Fatalf("eta_s = %v", home["eta_s"])
	}
	_, op := expectAccountOp(t, nodes["mac-d"].tnode)
	if op.Op != control.AccountCreate || strings.HasPrefix(op.Login, "fleetu") || op.FullName == store.SpareFullName {
		t.Fatalf("op = %+v; want the person's own create", op)
	}
}

// A spare waits on whether a LOGIN can be opened, never on the session gate
// (claude-fleet#4076): mac-d's login says admit=false / room=0 with a high load
// average but a quiet CPU (cpu_busy first, as placement reads it) and memory
// to spare — a managed machine on 2026-10-13 — and still fills to its count; a lost
// login on mac-c whose last beat said admit=false holds nothing either.
func TestSpareRefillIgnoresTheSessionGate(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	busy := 0.40
	beat(t, nodes["mac-d"].c, control.Proto, control.Heartbeat{Hostname: "mac-d", OSUser: "ivan", Sessions: 25,
		NCPU: 15, Load1: 47.2, CPUBusy: &busy, MemTotalBytes: 64 << 30, MemFreeBytes: 18 << 30,
		Admit: boolp(false), AdmitWhy: "负载过高", Room: intp(0)})
	// A second login on mac-c with a fast cadence: one beat with its gate
	// shut, then silence until it is lost.
	tok := h.enroll(t, "mac-c-bob")
	ident := model.Identity{AccountUUID: "acct-mac-c-bob", Hostname: "mac-c", OSUser: "bob"}
	if err := h.srv.Store.UpsertAccount(ident, "max", ""); err != nil {
		t.Fatal(err)
	}
	if _, _, err := h.srv.Store.TouchEndpoint("ep_mac-c-bob", ident, "test", true, nil); err != nil {
		t.Fatal(err)
	}
	bob := dialHello(t, h, tok, control.Hello{HeartbeatMS: 100})
	beat(t, bob.c, control.Proto, control.Heartbeat{Hostname: "mac-c", OSUser: "bob",
		Admit: boolp(false), AdmitWhy: "内存紧张", Room: intp(0)})
	waitFor(t, 5*time.Second, "mac-d's busy beat and bob lost", func() bool {
		snap, err := h.srv.Nodes(time.Now())
		if err != nil {
			return false
		}
		seenBob, seenD := false, false
		for _, n := range snap.Nodes {
			if n.OSUser == "bob" && n.Admit != nil && !*n.Admit && n.Status == "lost" {
				seenBob = true
			}
			if n.Hostname == "mac-d" && n.Admit != nil && !*n.Admit {
				seenD = true
			}
		}
		return seenBob && seenD
	})
	fit := h.srv.spareFitMachines(time.Now())
	if strings.Join(fit, ",") != "mac-c,mac-d" && strings.Join(fit, ",") != "mac-d,mac-c" {
		t.Fatalf("fit = %v; want mac-c and mac-d (session gate shut, a lost login's old verdict)", fit)
	}
	sparesOn(t, h, "2")
	openSpares(t, nodes["mac-c"], 2, control.CredsepSeparated)
	openSpares(t, nodes["mac-d"], 2, control.CredsepSeparated)
	waitFor(t, 3*time.Second, "both machines at their count", func() bool {
		r := h.srv.spareReadyHosts()
		return r["mac-c"] == 2 && r["mac-d"] == 2
	})

	// CPU really busy still holds the refill: the gate that stays is the CPU's.
	hot := 0.95
	beat(t, nodes["mac-d"].c, control.Proto, control.Heartbeat{Hostname: "mac-d", OSUser: "ivan", Sessions: 25,
		NCPU: 15, Load1: 47.2, CPUBusy: &hot, MemTotalBytes: 64 << 30, MemFreeBytes: 18 << 30})
	waitFor(t, 3*time.Second, "mac-d out of the fit list on a busy CPU", func() bool {
		for _, m := range h.srv.spareFitMachines(time.Now()) {
			if m == "mac-d" {
				return false
			}
		}
		return true
	})
}

// Off (the default): nothing is created or claimed, and no answer changes.
func TestSpareOffAddsNothing(t *testing.T) {
	h := newFleetHarness(t)
	const p = "gh:6004"
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	setHubSetting(t, h.srv, AutoAssignKey, "least-busy")
	if h.srv.replenishSpares(time.Now(), true) {
		t.Fatal("spares off, yet the refill queued one")
	}
	var snap NodesSnapshot
	h.getJSON(t, "/v1/nodes", &snap)
	for _, m := range snap.Machines {
		if m.Spare != nil || m.LoginsUsed != nil || m.LoginCap != nil {
			t.Fatalf("spares off, yet %s carries spare counts", m.Hostname)
		}
	}
	listPerson(t, h, p, "ZhaoLiu")
	h.srv.onPrincipalSignIn(p, "ZhaoLiu")
	if _, op := expectAccountOp(t, nodes["mac-d"].tnode); op.Login != "zhaoliu" {
		t.Fatalf("op = %+v; want the person's own create", op)
	}
}

func TestSpareSettings(t *testing.T) {
	for v, ok := range map[string]bool{"0": true, "5": true, "20": true, "21": false, "-1": false, "x": false} {
		if _, msg := checkSpareMax(nil, v); (msg == "") != ok {
			t.Errorf("%s=%q: refusal %q, want ok=%v", SpareMaxKey, v, msg, ok)
		}
	}
	if got := nodeUserCap("mac-c.lan", map[string]string{NodeUserCapPrefix + "mac-c": "3"}); got != 3 {
		t.Errorf("nodeUserCap(mac-c.lan) = %d, want 3", got)
	}
	if got := nodeUserCap("m9", nil); got != defaultNodeUserCap {
		t.Errorf("nodeUserCap(m9) = %d, want %d", got, defaultNodeUserCap)
	}
}
