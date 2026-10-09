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

// claude-fleet#2069 (EPIC #2140 C1): a newcomer's first sign-in opens their
// login on its own — fleet.auto_assign=least-busy picks the machine, the
// GitHub username is the login — and every door the client reads says
// 「正在开」 until it is active.

// beatCount sends one heartbeat carrying a session count.
func beatCount(t *testing.T, n *fleetNode, host, osUser string, sessions int) {
	t.Helper()
	beat(t, n.c, control.Proto, control.Heartbeat{Hostname: host, OSUser: osUser, Sessions: sessions, NCPU: 8})
}

// leastBusyFleet is three admin machines and a non-admin one: m4 busy, m5
// quiet, m6 idle but 维护中, m7 idle with no admin node to open a login.
func leastBusyFleet(t *testing.T, h *harness) map[string]*fleetNode {
	t.Helper()
	h.srv.FleetAdmins = []string{"verkyyi"}
	nodes := map[string]*fleetNode{}
	for _, m := range []struct {
		host     string
		admin    bool
		sessions int
	}{{"m4", true, 5}, {"m5", true, 1}, {"m6", true, 0}, {"m7", false, 0}} {
		user := "verkyyi"
		if !m.admin {
			user = "someone"
		}
		n := connectNode(t, h, m.host+"-op", m.host, user, m.admin)
		beatCount(t, n, m.host, user, m.sessions)
		nodes[m.host] = n
	}
	if _, _, err := h.srv.enterMaintenance("m6", "drill", "test", time.Now()); err != nil {
		t.Fatal(err)
	}
	waitFor(t, 3*time.Second, "the roster to carry every beat", func() bool {
		return h.srv.leastBusyMachine(time.Now()) == "m5"
	})
	return nodes
}

func TestAutoAssignLeastBusyPicksTheQuietMachine(t *testing.T) {
	h := newFleetHarness(t)
	const p = "gh:4004"
	enablePeople(t, h)
	nodes := leastBusyFleet(t, h)
	setHubSetting(t, h.srv, AutoAssignKey, "least-busy")

	listPerson(t, h, p, "LiSi")
	h.srv.onPrincipalSignIn(p, "LiSi")
	_, op := expectAccountOp(t, nodes["m5"].tnode)
	if op.Op != control.AccountCreate || op.Login != "lisi" {
		t.Fatalf("op = %+v; want a create of lisi (the GitHub username) on m5", op)
	}
	for _, host := range []string{"m4", "m6"} {
		if got, ok := readMsg(nodes[host].tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
			t.Fatalf("%s was sent %+v", host, got)
		}
	}
	if a := accountState(t, h, p, "m5"); a.Login != "lisi" {
		t.Fatalf("account = %+v", a)
	}
}

// No machine fit (every one busy elsewhere, 维护中, or without an admin):
// nothing is queued, no row is minted — and the person is told who to ask.
func TestAutoAssignLeastBusyNoneFit(t *testing.T) {
	h := newFleetHarness(t)
	const p = "gh:4005"
	enablePeople(t, h)
	h.srv.FleetAdmins = []string{"verkyyi"}
	n := connectNode(t, h, "m7-op", "m7", "someone", false)
	beatCount(t, n, "m7", "someone", 0)
	setHubSetting(t, h.srv, AutoAssignKey, "least-busy")
	listPerson(t, h, p, "")
	h.srv.onPrincipalSignIn(p, "")
	if _, err := h.srv.Store.Principal(p); err == nil {
		t.Fatal("a principal row was minted with nowhere to open it")
	}
	st := h.srv.accountStateOf(p, time.Now())
	if st == nil || st.State != "none" || st.Ask != "verkyyi" {
		t.Fatalf("account state = %+v; want none, ask verkyyi", st)
	}
}

// The username is the login only when nobody has it: a roster login, an
// admin, a mapped login, another person's login, a system name, or a name a
// node would refuse — each falls back to gh<id>.
func TestAutoAssignUsernameFallsBack(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	h.srv.FleetAdmins = []string{"verkyyi"}
	admin := connectNode(t, h, "m4-op", "m4", "verkyyi", true)
	connectNode(t, h, "m4-wang", "m4", "wangwu", false)
	setHubSetting(t, h.srv, AutoAssignKey, "m4")
	if _, err := h.srv.Store.AdoptPrincipal("CaoJian", "caojian", "曹健", time.Now()); err != nil {
		t.Fatal(err)
	}
	for i, c := range []struct{ username, want string }{
		{"wangwu", "gh5001"},                // an OS login a machine already has
		{"verkyyi", "gh5002"},               // the admin's own
		{"caojian", "gh5003"},               // another principal's login
		{"root", "gh5004"},                  // a system name
		{"li-si", "gh5005"},                 // not a login a node makes
		{"averyveryverylongname", "gh5006"}, // longer than 16
		{"Zhao6", "zhao6"},                  // fine: lowercased
	} {
		p := "gh:" + []string{"5001", "5002", "5003", "5004", "5005", "5006", "5007"}[i]
		listPerson(t, h, p, c.username)
		h.srv.onPrincipalSignIn(p, c.username)
		_, op := expectAccountOp(t, admin.tnode)
		if op.Login != c.want {
			t.Errorf("username %q: login %q, want %q", c.username, op.Login, c.want)
		}
	}
}

// Every door the client reads says 「正在开」 while the create runs, and
// nothing once the login is active — the answer before, byte for byte.
func TestAccountOpeningOnEveryDoor(t *testing.T) {
	h := newFleetHarness(t)
	const p = "gh:4006"
	enablePeople(t, h)
	nodes := leastBusyFleet(t, h)
	setHubSetting(t, h.srv, AutoAssignKey, "least-busy")

	// The first look at /v1/nodes runs the placement itself (no sign-in
	// callback needed): the person is opening on m5 at once.
	code, body := asUID(t, h, http.MethodGet, "/v1/nodes", p, "", nil)
	if code != http.StatusOK {
		t.Fatalf("/v1/nodes: HTTP %d %s", code, body)
	}
	var snap NodesSnapshot
	if err := json.Unmarshal(body, &snap); err != nil {
		t.Fatal(err)
	}
	if snap.Account == nil || snap.Account.State != "opening" || snap.Account.Machine != "m5" || snap.Account.EtaS < 5 {
		t.Fatalf("/v1/nodes account = %+v", snap.Account)
	}
	m, op := expectAccountOp(t, nodes["m5"].tnode)

	code, body = asUID(t, h, http.MethodGet, control.HomePath, p, "", nil)
	var home map[string]any
	_ = json.Unmarshal(body, &home)
	if code != http.StatusServiceUnavailable || home["code"] != "opening" || home["state"] != "opening" {
		t.Fatalf("home while opening: HTTP %d %s", code, body)
	}
	if eta, _ := home["eta_s"].(float64); eta < 5 {
		t.Fatalf("home eta_s = %v", home["eta_s"])
	}

	sendResult(t, nodes["m5"].c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true})
	waitState(t, h, p, "m5", store.AccountActive)
	code, body = asUID(t, h, http.MethodGet, "/v1/nodes", p, "", nil)
	snap = NodesSnapshot{}
	if err := json.Unmarshal(body, &snap); err != nil || code != http.StatusOK {
		t.Fatalf("/v1/nodes after: HTTP %d %v", code, err)
	}
	if snap.Account != nil {
		t.Fatalf("an active person still gets account = %+v", snap.Account)
	}
	if st := h.srv.accountStateOf("", time.Now()); st != nil {
		t.Fatalf("the operator got account = %+v", st)
	}
}

// fleet.auto_assign off: the person is told nothing is coming and who to
// ask; no placement is run on their behalf.
func TestAccountStateWithAutoAssignOff(t *testing.T) {
	h := newFleetHarness(t)
	const p = "gh:4007"
	enablePeople(t, h)
	nodes := leastBusyFleet(t, h)
	code, body := asUID(t, h, http.MethodGet, "/v1/nodes", p, "", nil)
	var snap NodesSnapshot
	if err := json.Unmarshal(body, &snap); err != nil || code != http.StatusOK {
		t.Fatalf("/v1/nodes: HTTP %d %v", code, err)
	}
	if snap.Account == nil || snap.Account.State != "none" || snap.Account.Ask != "verkyyi" {
		t.Fatalf("account = %+v; want none, ask verkyyi", snap.Account)
	}
	if got, ok := readMsg(nodes["m5"].tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("a placement ran with auto-assign off: %+v", got)
	}
}

// Opening never reads 「about 5s」 forever (claude-fleet#2696): the ETA is the
// machine's own measured median (openingETA before it has opened any), and a
// create nobody can finish — no answer in openingGiveUp, or unsent with no
// admin node of its machine connected — reads failed, saying why.
func TestOpeningHasAnHonestETAAndAnEnd(t *testing.T) {
	h, nodes, inv := drillOnFleet(t)
	m, op := expectAccountOp(t, nodes["m4"].tnode)
	if got := h.srv.openingETAFor("m4"); got != openingETA {
		t.Fatalf("eta with no history = %d; want %d", got, openingETA)
	}
	now := time.Now()
	if st := h.srv.accountStateOf(inv.PersonID, now); st == nil || st.State != "opening" || st.EtaS < openingETA-60 {
		t.Fatalf("account = %+v; want opening, eta about %d s", st, openingETA)
	}
	late := now.Add(openingETA*time.Second + time.Minute)
	if st := h.srv.accountStateOf(inv.PersonID, late); st == nil || st.State != "opening" || st.EtaS < 60 {
		t.Fatalf("late account = %+v; want opening with the time left until it gives up, never 5 s", st)
	}
	st := h.srv.accountStateOf(inv.PersonID, now.Add(openingGiveUp+time.Minute))
	if st == nil || st.State != "failed" || !strings.Contains(st.Why, "no answer from m4") || st.Ask == "" {
		t.Fatalf("stuck account = %+v; want failed: no answer from m4, and who to ask", st)
	}
	sendResult(t, nodes["m4"].c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true})
	waitState(t, h, inv.PersonID, "m4", store.AccountActive)
	if got := h.srv.openingETAFor("m4"); got != 60 {
		t.Fatalf("eta after a fast create = %d; want the 60 s floor", got)
	}

	ghost := store.FleetAccount{Hostname: "ghost", State: store.AccountPending, RequestedAt: now.Add(-openingNoAdmin - time.Minute)}
	if why := h.srv.openingStuck(ghost, now); !strings.Contains(why, "no admin node of ghost") {
		t.Fatalf("pending with no admin node: why = %q", why)
	}
	ghost.RequestedAt = now
	if why := h.srv.openingStuck(ghost, now); why != "" {
		t.Fatalf("a fresh pending create is stuck already: %q", why)
	}
}
