package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#2263 (EPIC #2259 C4): every host machine keeps a login opened
// ahead of a newcomer, so their first sign-in is ready at once; the one taken
// is refilled, a machine 维护中 gets none, and a spare is nobody in the
// people views. Off (fleet.spare_accounts 0) adds nothing.

// sparesOpened turns spares on, runs the refill, and answers every create it
// sends with OK — the machines' spares are ready. It returns the spare login
// on each machine that got one.
func sparesOpened(t *testing.T, h *harness, nodes map[string]*fleetNode, hosts ...string) map[string]string {
	t.Helper()
	setHubSetting(t, h.srv, SpareAccountsKey, "1")
	if !h.srv.replenishSpares(time.Now(), true) {
		t.Fatal("the refill queued nothing")
	}
	h.srv.dispatchAccounts()
	logins := map[string]string{}
	for _, host := range hosts {
		m, op := expectAccountOp(t, nodes[host].tnode)
		if op.Op != control.AccountCreate || !strings.HasPrefix(op.Login, "fl") || op.FullName != store.SpareFullName {
			t.Fatalf("%s: op = %+v; want a create of a spare fl…", host, op)
		}
		sendResult(t, nodes[host].c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true})
		logins[host] = op.Login
	}
	waitFor(t, 3*time.Second, "every spare to be ready", func() bool {
		return len(h.srv.spareReadyHosts()) == len(hosts)
	})
	return logins
}

func TestSpareHandedToANewcomerAndRefilled(t *testing.T) {
	h := newFleetHarness(t)
	const p = "gh:6001"
	enablePeople(t, h)
	nodes := leastBusyFleet(t, h)
	setHubSetting(t, h.srv, AutoAssignKey, "least-busy")
	routes, err := ParseFleetRoutes(`[{"hostname":"m4","routes":[{"name":"public","host":"203.0.113.4"}]},
	  {"hostname":"m5","routes":[{"name":"public","host":"203.0.113.5"}]}]`)
	if err != nil {
		t.Fatal(err)
	}
	h.srv.FleetRoutes = routes
	spares := sparesOpened(t, h, nodes, "m4", "m5")
	// 维护中 (m6) and a machine with no admin node (m7) get none.
	for _, host := range []string{"m6", "m7"} {
		if got, ok := readMsg(nodes[host].tnode, 200*time.Millisecond); ok && got.Type == control.TypeAccountOp {
			t.Fatalf("%s was sent %+v", host, got)
		}
	}

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
	if code != http.StatusOK || home.Machine == nil || home.Machine.Hostname != "m5" || home.Login != spares["m5"] {
		t.Fatalf("home: HTTP %d %s; want m5 under its spare login at once", code, body)
	}
	if took > 3*time.Second {
		t.Fatalf("home took %v; want ≤ 3s", took)
	}
	a := accountState(t, h, p, "m5")
	if a.State != store.AccountActive || a.Login != spares["m5"] {
		t.Fatalf("account = %+v; want m5's spare %s, active", a, spares["m5"])
	}
	if pr, err := h.srv.Store.Principal(p); err != nil || pr.Login != spares["m5"] || pr.DisplayName == store.SpareFullName || pr.DisplayName == "" {
		t.Fatalf("principal = %+v, %v", pr, err)
	}
	if st := h.srv.accountStateOf(p, time.Now()); st != nil {
		t.Fatalf("account state = %+v; want none (active)", st)
	}

	// The spare taken is refilled on its own; the other machine's stays.
	_, op := expectAccountOp(t, nodes["m5"].tnode)
	if op.Op != control.AccountCreate || !strings.HasPrefix(op.Login, "fl") || op.Login == spares["m5"] {
		t.Fatalf("refill op = %+v", op)
	}
	if got, ok := readMsg(nodes["m4"].tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("m4 (spare still there) was sent %+v", got)
	}
}

// A spare is nobody: no people list, no person's roster; the operator sees
// a count per machine and the rows apart in /v1/fleet/accounts.
func TestSpareIsInNoPeopleView(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := leastBusyFleet(t, h)
	sparesOpened(t, h, nodes, "m4", "m5")

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

	var snap NodesSnapshot
	h.getJSON(t, "/v1/nodes", &snap)
	for _, m := range snap.Machines {
		want := map[string]int{"m4": 1, "m5": 1}[m.Hostname]
		if m.Spare == nil || *m.Spare != want {
			t.Fatalf("operator roster %s spare = %v; want %d", m.Hostname, m.Spare, want)
		}
	}
	const p = "gh:6002"
	listPerson(t, h, p, "")
	_, body := asUID(t, h, http.MethodGet, "/v1/nodes", p, "", nil)
	if strings.Contains(string(body), `"spare"`) {
		t.Fatalf("a person's roster carries spare: %s", body)
	}
}

// spare-login-empty (docs/BREAK-IT.md): no spare ready (the refill still
// running) ⇒ the newcomer's login is opened as before, and every door says
// 「正在开」 with its ETA — never a silent wait, never a half-ready spare.
func TestSpareEmptyFallsBackToOpening(t *testing.T) {
	h := newFleetHarness(t)
	const p = "gh:6003"
	enablePeople(t, h)
	nodes := leastBusyFleet(t, h)
	setHubSetting(t, h.srv, AutoAssignKey, "least-busy")
	setHubSetting(t, h.srv, SpareAccountsKey, "1")
	h.srv.replenishSpares(time.Now(), true)
	h.srv.dispatchAccounts()
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
	if op.Op != control.AccountCreate || strings.HasPrefix(op.Login, "fl") || op.FullName == store.SpareFullName {
		t.Fatalf("op = %+v; want the person's own create", op)
	}
}

// A failed spare stops the refill on that machine until the operator looks:
// a create that failed once would fail on every beat.
func TestSpareFailedIsNotRetried(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := leastBusyFleet(t, h)
	setHubSetting(t, h.srv, SpareAccountsKey, "1")
	h.srv.replenishSpares(time.Now(), true)
	h.srv.dispatchAccounts()
	m, op := expectAccountOp(t, nodes["m5"].tnode)
	sendResult(t, nodes["m5"].c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, Exit: 1, Detail: "boom"})
	expectAccountOp(t, nodes["m4"].tnode)
	waitFor(t, 3*time.Second, "the spare to fail", func() bool {
		_, _, failed, _ := h.srv.spareCounts()
		return failed["m5"]
	})
	if h.srv.replenishSpares(time.Now(), true) {
		t.Fatal("the refill queued again beside a failed spare")
	}
}

// Off (the default): nothing is created or claimed, and no answer changes.
func TestSpareOffAddsNothing(t *testing.T) {
	h := newFleetHarness(t)
	const p = "gh:6004"
	enablePeople(t, h)
	nodes := leastBusyFleet(t, h)
	setHubSetting(t, h.srv, AutoAssignKey, "least-busy")
	if h.srv.replenishSpares(time.Now(), true) {
		t.Fatal("spares off, yet the refill queued one")
	}
	var snap NodesSnapshot
	h.getJSON(t, "/v1/nodes", &snap)
	for _, m := range snap.Machines {
		if m.Spare != nil {
			t.Fatalf("spares off, yet %s carries spare %d", m.Hostname, *m.Spare)
		}
	}
	listPerson(t, h, p, "ZhaoLiu")
	h.srv.onPrincipalSignIn(p, "ZhaoLiu")
	if _, op := expectAccountOp(t, nodes["m5"].tnode); op.Login != "zhaoliu" {
		t.Fatalf("op = %+v; want the person's own create", op)
	}
}

func TestSpareAccountsSetting(t *testing.T) {
	for v, ok := range map[string]bool{"0": true, "1": true, "3": true, "4": false, "-1": false, "x": false} {
		if _, msg := checkSpareAccounts(nil, v); (msg == "") != ok {
			t.Errorf("%s=%q: refusal %q, want ok=%v", SpareAccountsKey, v, msg, ok)
		}
	}
}
