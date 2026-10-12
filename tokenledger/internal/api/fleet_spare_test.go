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

// spareFleet is four admin machines: m4 busy, m5 quiet (both separate
// credentials), m6 the same but 维护中, m7 (3 sessions) whose node does not
// separate credentials. Routes let /v1/fleet/home answer a machine.
func spareFleet(t *testing.T, h *harness) map[string]*fleetNode {
	t.Helper()
	h.srv.FleetAdmins = []string{"verkyyi"}
	nodes := map[string]*fleetNode{}
	for _, m := range []struct {
		host     string
		credsep  bool
		sessions int
	}{{"m4", true, 5}, {"m5", true, 1}, {"m6", true, 0}, {"m7", false, 3}} {
		var caps []string
		if m.credsep {
			caps = []string{control.CapCredsep}
		}
		n := connectCaps(t, h, m.host+"-op", m.host, "verkyyi", true, caps...)
		beatCount(t, n, m.host, "verkyyi", m.sessions)
		nodes[m.host] = n
	}
	if _, _, err := h.srv.enterMaintenance("m6", "drill", "test", time.Now()); err != nil {
		t.Fatal(err)
	}
	routes, err := ParseFleetRoutes(`[{"hostname":"m4","routes":[{"name":"public","host":"203.0.113.4"}]},
	  {"hostname":"m5","routes":[{"name":"public","host":"203.0.113.5"}]}]`)
	if err != nil {
		t.Fatal(err)
	}
	h.srv.FleetRoutes = routes
	waitFor(t, 3*time.Second, "the roster to carry every beat", func() bool {
		return h.srv.leastBusyMachine(time.Now()) == "m5"
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
	openSpares(t, nodes["m4"], 1, control.CredsepSeparated)
	m5 := openSpares(t, nodes["m5"], 1, control.CredsepSeparated)
	// 维护中 (m6) and a node that does not separate credentials (m7): none.
	noOp(t, nodes, "m6", "m7")
	waitFor(t, 3*time.Second, "both spares to be ready", func() bool {
		r := h.srv.spareReadyHosts()
		return r["m4"] == 1 && r["m5"] == 1
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
	if code != http.StatusOK || home.Machine == nil || home.Machine.Hostname != "m5" || home.Login != m5[0] {
		t.Fatalf("home: HTTP %d %s; want m5 under its spare login %s at once", code, body, m5[0])
	}
	if took > 3*time.Second {
		t.Fatalf("home took %v; want ≤ 3s", took)
	}
	// Mapped, not renamed: the person's login IS the spare's name.
	if pr, err := h.srv.Store.Principal(p); err != nil || pr.Login != m5[0] || pr.DisplayName == store.SpareFullName {
		t.Fatalf("principal = %+v, %v", pr, err)
	}
	if a := accountState(t, h, p, "m5"); a.State != store.AccountActive || a.Login != m5[0] {
		t.Fatalf("account = %+v", a)
	}
	// The spare taken is refilled on its own; the other machine's stays.
	_, op := expectAccountOp(t, nodes["m5"].tnode)
	if op.Op != control.AccountCreate || !strings.HasPrefix(op.Login, "fleetu") || op.Login == m5[0] {
		t.Fatalf("refill op = %+v", op)
	}
	noOp(t, nodes, "m4")
}

// The count is min(fleet.spare_max, the machine's login cap − the logins
// handed out), and a machine over it shrinks: the newest ready spares close.
func TestSpareCountFollowsTheMachinesRoom(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	setHubSetting(t, h.srv, NodeUserCapPrefix+"m4", "3")
	// Two logins already handed out on m4.
	for _, id := range []string{"gh:7001", "gh:7002"} {
		p, err := h.srv.Store.AdoptPrincipal(id, "u"+id[3:], "", time.Now())
		if err != nil {
			t.Fatal(err)
		}
		if err := h.srv.Store.AdoptAccount(p, "m4", time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	sparesOn(t, h, "5")
	openSpares(t, nodes["m4"], 1, control.CredsepSeparated) // 3 − 2 = 1
	openSpares(t, nodes["m5"], 5, control.CredsepSeparated) // min(5, 10 − 0)
	noOp(t, nodes, "m4")
	waitFor(t, 3*time.Second, "the spares to be ready", func() bool {
		r := h.srv.spareReadyHosts()
		return r["m4"] == 1 && r["m5"] == 5
	})

	var snap NodesSnapshot
	h.getJSON(t, "/v1/nodes", &snap)
	seen := false
	for _, m := range snap.Machines {
		if m.Hostname != "m4" {
			continue
		}
		seen = true
		if m.Spare == nil || *m.Spare != 1 || m.LoginsUsed == nil || *m.LoginsUsed != 2 || m.LoginCap == nil || *m.LoginCap != 3 {
			t.Fatalf("m4 = spare %v used %v cap %v; want 1 · 2 / 3", m.Spare, m.LoginsUsed, m.LoginCap)
		}
	}
	if !seen {
		t.Fatal("m4 is not on the operator's roster")
	}

	// The cap comes down: m5's newest spares close until it holds 2.
	setHubSetting(t, h.srv, SpareMaxKey, "2")
	h.srv.replenishSpares(time.Now(), true)
	h.srv.dispatchAccounts()
	for i := 0; i < 3; i++ {
		if _, op := expectAccountOp(t, nodes["m5"].tnode); op.Op != control.AccountRemove || !strings.HasPrefix(op.Login, "fleetu") {
			t.Fatalf("shrink op = %+v; want a remove of a spare", op)
		}
	}
	noOp(t, nodes, "m5")
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
	openSpares(t, nodes["m4"], 1, control.CredsepSeparated)
	openSpares(t, nodes["m5"], 1, "") // a node that did not say separated
	waitFor(t, 3*time.Second, "m5's spare to fail and m4's to be ready", func() bool {
		pic, _ := h.srv.sparePicture()
		return pic["m5"] != nil && pic["m5"].Failed && pic["m4"] != nil && pic["m4"].Ready == 1
	})
	if h.srv.replenishSpares(time.Now(), true) {
		t.Fatal("the refill queued again beside a failed spare")
	}
	listPerson(t, h, p, "")
	h.srv.onPrincipalSignIn(p, "")
	if a := accountState(t, h, p, "m4"); a.State != store.AccountActive || !strings.HasPrefix(a.Login, "fleetu") {
		t.Fatalf("account on m4 = %+v; want m4's separated spare (m5's is not handed out)", a)
	}
}

// A spare is nobody: no people list, no person's roster; the operator sees
// counts per machine and the rows apart in /v1/fleet/accounts.
func TestSpareIsInNoPeopleView(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	sparesOn(t, h, "1")
	openSpares(t, nodes["m4"], 1, control.CredsepSeparated)
	openSpares(t, nodes["m5"], 1, control.CredsepSeparated)
	waitFor(t, 3*time.Second, "both spares to be ready", func() bool {
		r := h.srv.spareReadyHosts()
		return r["m4"] == 1 && r["m5"] == 1
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
	expectAccountOp(t, nodes["m4"].tnode) // sent, never answered: creating
	expectAccountOp(t, nodes["m5"].tnode)

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
	_, op := expectAccountOp(t, nodes["m5"].tnode)
	if op.Op != control.AccountCreate || strings.HasPrefix(op.Login, "fleetu") || op.FullName == store.SpareFullName {
		t.Fatalf("op = %+v; want the person's own create", op)
	}
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
	if _, op := expectAccountOp(t, nodes["m5"].tnode); op.Login != "zhaoliu" {
		t.Fatalf("op = %+v; want the person's own create", op)
	}
}

func TestSpareSettings(t *testing.T) {
	for v, ok := range map[string]bool{"0": true, "5": true, "20": true, "21": false, "-1": false, "x": false} {
		if _, msg := checkSpareMax(nil, v); (msg == "") != ok {
			t.Errorf("%s=%q: refusal %q, want ok=%v", SpareMaxKey, v, msg, ok)
		}
	}
	if got := nodeUserCap("m4.lan", map[string]string{NodeUserCapPrefix + "m4": "3"}); got != 3 {
		t.Errorf("nodeUserCap(m4.lan) = %d, want 3", got)
	}
	if got := nodeUserCap("m9", nil); got != defaultNodeUserCap {
		t.Errorf("nodeUserCap(m9) = %d, want %d", got, defaultNodeUserCap)
	}
}
