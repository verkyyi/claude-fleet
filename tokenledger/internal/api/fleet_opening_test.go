package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
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

// leastBusyFleet is three admin machines and a non-admin one: mac-c busy, mac-d
// quiet, m6 idle but 维护中, m7 idle with no admin node to open a login.
func leastBusyFleet(t *testing.T, h *harness) map[string]*fleetNode {
	t.Helper()
	h.srv.FleetAdmins = []string{"ivan"}
	nodes := map[string]*fleetNode{}
	for _, m := range []struct {
		host     string
		admin    bool
		sessions int
	}{{"mac-c", true, 5}, {"mac-d", true, 1}, {"m6", true, 0}, {"m7", false, 0}} {
		user := "ivan"
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
		return h.srv.leastBusyMachine(time.Now()) == "mac-d"
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
	_, op := expectAccountOp(t, nodes["mac-d"].tnode)
	if op.Op != control.AccountCreate || op.Login != "lisi" {
		t.Fatalf("op = %+v; want a create of lisi (the GitHub username) on mac-d", op)
	}
	for _, host := range []string{"mac-c", "m6"} {
		if got, ok := readMsg(nodes[host].tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
			t.Fatalf("%s was sent %+v", host, got)
		}
	}
	if a := accountState(t, h, p, "mac-d"); a.Login != "lisi" {
		t.Fatalf("account = %+v", a)
	}
}

// No machine fit (every one busy elsewhere, 维护中, or without an admin):
// nothing is queued, no row is minted — and the person is told who to ask.
func TestAutoAssignLeastBusyNoneFit(t *testing.T) {
	h := newFleetHarness(t)
	const p = "gh:4005"
	enablePeople(t, h)
	h.srv.FleetAdmins = []string{"ivan"}
	n := connectNode(t, h, "m7-op", "m7", "someone", false)
	beatCount(t, n, "m7", "someone", 0)
	setHubSetting(t, h.srv, AutoAssignKey, "least-busy")
	listPerson(t, h, p, "")
	h.srv.onPrincipalSignIn(p, "")
	if _, err := h.srv.Store.Principal(p); err == nil {
		t.Fatal("a principal row was minted with nowhere to open it")
	}
	st := h.srv.accountStateOf(p, time.Now())
	if st == nil || st.State != "none" || st.Ask != "ivan" {
		t.Fatalf("account state = %+v; want none, ask ivan", st)
	}
	// No machine has an admin node online (claude-fleet#2997: the sweep had
	// booted the admin login's own agent out): said, never a bare none.
	if st.Why != noLoginOpener {
		t.Fatalf("why = %q; want %q", st.Why, noLoginOpener)
	}
	if _, err := h.srv.pickNode(fleetPrincipal{Person: p}, "", "auto", "", time.Now()); err == nil || !strings.Contains(err.Error(), noLoginOpener) {
		t.Fatalf("placement = %v; want it to say %q", err, noLoginOpener)
	}
}

// The username is the login only when nobody has it: a roster login, an
// admin, a mapped login, another person's login, a system name, or a name a
// node would refuse — each falls back to gh<id>.
func TestAutoAssignUsernameFallsBack(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	h.srv.FleetAdmins = []string{"ivan"}
	admin := connectNode(t, h, "mac-c-op", "mac-c", "ivan", true)
	connectNode(t, h, "mac-c-wang", "mac-c", "wangwu", false)
	setHubSetting(t, h.srv, AutoAssignKey, "mac-c")
	if _, err := h.srv.Store.AdoptPrincipal("CaoJian", "caojian", "曹健", time.Now()); err != nil {
		t.Fatal(err)
	}
	for i, c := range []struct{ username, want string }{
		{"wangwu", "gh5001"},                // an OS login a machine already has
		{"ivan", "gh5002"},                  // the admin's own
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
	// callback needed): the person is opening on mac-d at once.
	code, body := asUID(t, h, http.MethodGet, "/v1/nodes", p, "", nil)
	if code != http.StatusOK {
		t.Fatalf("/v1/nodes: HTTP %d %s", code, body)
	}
	var snap NodesSnapshot
	if err := json.Unmarshal(body, &snap); err != nil {
		t.Fatal(err)
	}
	if snap.Account == nil || snap.Account.State != "opening" || snap.Account.Machine != "mac-d" || snap.Account.EtaS < 5 {
		t.Fatalf("/v1/nodes account = %+v", snap.Account)
	}
	m, op := expectAccountOp(t, nodes["mac-d"].tnode)

	code, body = asUID(t, h, http.MethodGet, control.HomePath, p, "", nil)
	var home map[string]any
	_ = json.Unmarshal(body, &home)
	if code != http.StatusServiceUnavailable || home["code"] != "opening" || home["state"] != "opening" {
		t.Fatalf("home while opening: HTTP %d %s", code, body)
	}
	if eta, _ := home["eta_s"].(float64); eta < 5 {
		t.Fatalf("home eta_s = %v", home["eta_s"])
	}

	sendResult(t, nodes["mac-d"].c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true})
	waitState(t, h, p, "mac-d", store.AccountActive)
	// Opened is not yet placeable (claude-fleet#2941): until the login's own
	// node reports its fleet the doors still say opening.
	if st := h.srv.accountStateOf(p, time.Now()); st == nil || st.State != "opening" || st.Stage != "fleet" || st.Machine != "mac-d" {
		t.Fatalf("opened, no fleet yet: account = %+v; want opening (stage fleet) on mac-d", st)
	}
	loginReportsFleet(t, h, "mac-d", op.Login, machineA)
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
	if snap.Account == nil || snap.Account.State != "none" || snap.Account.Ask != "ivan" {
		t.Fatalf("account = %+v; want none, ask ivan", snap.Account)
	}
	if got, ok := readMsg(nodes["mac-d"].tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("a placement ran with auto-assign off: %+v", got)
	}
}

// Opening never reads 「about 5s」 forever (claude-fleet#2696): the ETA is the
// machine's own measured median (openingETA before it has opened any), and a
// create nobody can finish — no answer in openingGiveUp, or unsent with no
// admin node of its machine connected — reads failed, saying why.
func TestOpeningHasAnHonestETAAndAnEnd(t *testing.T) {
	h, nodes, inv := drillOnFleet(t)
	m, op := expectAccountOp(t, nodes["mac-c"].tnode)
	if got := h.srv.openingETAFor("mac-c"); got != openingETA {
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
	if st == nil || st.State != "failed" || !strings.Contains(st.Why, "no answer from mac-c") || st.Ask == "" {
		t.Fatalf("stuck account = %+v; want failed: no answer from mac-c, and who to ask", st)
	}
	sendResult(t, nodes["mac-c"].c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true})
	waitState(t, h, inv.PersonID, "mac-c", store.AccountActive)
	if got := h.srv.openingETAFor("mac-c"); got != 60 {
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

// The ETA is one countdown (claude-fleet#2728): it starts at the machine's
// estimate and never goes up — past the estimate it used to jump to the time
// left until the give-up, so the drill read 313 s and then 858 s.
func TestOpeningETANeverClimbs(t *testing.T) {
	for _, est := range []int{60, openingETA, int(openingGiveUp.Seconds()), 5000} {
		prev := openingETALeft(est, 0)
		want := est
		if max := int(openingGiveUp.Seconds()); want > max {
			want = max
		}
		if prev != want {
			t.Fatalf("est %d: eta at the start = %d; want %d", est, prev, want)
		}
		for took := time.Duration(0); took <= openingGiveUp+time.Minute; took += 10 * time.Second {
			got := openingETALeft(est, took)
			if got > prev {
				t.Fatalf("est %d: eta climbed from %d to %d at %s", est, prev, got, took)
			}
			if got < 5 {
				t.Fatalf("est %d: eta %d below the 5 s floor at %s", est, got, took)
			}
			prev = got
		}
		if prev != 5 {
			t.Fatalf("est %d: eta at the give-up = %d; want the 5 s floor", est, prev)
		}
	}
	// The drill's own numbers: a machine with no history (8 min), 167 s in,
	// then 342 s in — the second reading is the smaller one now.
	if a, b := openingETALeft(openingETA, 167*time.Second), openingETALeft(openingETA, 342*time.Second); b >= a {
		t.Fatalf("eta at 167 s = %d, at 342 s = %d; want it to go down", a, b)
	}
}

// loginReportsFleet connects login's own node on host and has it report a
// fleet, then waits for the registry to carry it (claude-fleet#2941).
func loginReportsFleet(t *testing.T, h *harness, host, login, machine string) {
	t.Helper()
	n := connectNode(t, h, host+"-"+login, host, login, false)
	beat(t, n.c, control.Proto, control.Heartbeat{Hostname: host, OSUser: login, MachineID: machine,
		Fleets: []control.Fleet{fakeFleet(t, machine, "fleet", "o/r", "/Users/"+login+"/r")}, ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, login+"@"+host+"'s fleet to be registered", func() bool {
		return h.srv.loginsWithFleet()[[2]string{host, login}]
	})
}

// A login the node opened but whose fleet never reports (claude-fleet#2941,
// the 10th C9 drill: mac-f said create ok, its fleet ran, the hub went on
// saying 「mac-f: 没有你的登录」 and the client waited for nothing): the
// doors say opening (stage fleet) for openingSettle, then failed naming the
// missing step; a refused placement names the login instead of 没有你的登录;
// once its fleet reports the person reads as anyone with a login.
func TestOpenedLoginWithoutFleetIsNotDone(t *testing.T) {
	h, nodes, inv := drillOnFleet(t)
	m, op := expectAccountOp(t, nodes["mac-c"].tnode)
	sendResult(t, nodes["mac-c"].c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true})
	waitState(t, h, inv.PersonID, "mac-c", store.AccountActive)

	now := time.Now()
	st := h.srv.accountStateOf(inv.PersonID, now)
	if st == nil || st.State != "opening" || st.Stage != "fleet" || st.Login != op.Login || st.EtaS < 5 || st.EtaS > openingSettleETA {
		t.Fatalf("opened, no fleet: account = %+v; want opening, stage fleet, eta ≤ %d", st, openingSettleETA)
	}
	notes := h.srv.openingNotes(inv.PersonID)
	if !strings.Contains(notes["mac-c"], op.Login) || !strings.Contains(notes["mac-c"], "fleet 还没报上来") {
		t.Fatalf("placement note for mac-c = %q; want the opened login named", notes["mac-c"])
	}
	st = h.srv.accountStateOf(inv.PersonID, now.Add(openingSettle+time.Minute))
	if st == nil || st.State != "failed" || !strings.Contains(st.Why, "never connected") || st.Ask == "" {
		t.Fatalf("past the settle: account = %+v; want failed: its node never connected, and who to ask", st)
	}

	// Its node connects but cannot read its fleet: the why says so.
	n := connectNode(t, h, "mac-c-"+op.Login+"-first", "mac-c", op.Login, false)
	beat(t, n.c, control.Proto, control.Heartbeat{Hostname: "mac-c", OSUser: op.Login, FleetError: "fleet-control: no fleet.conf", ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, "the login's beat to land", func() bool {
		st := h.srv.accountStateOf(inv.PersonID, time.Now().Add(openingSettle+time.Minute))
		return st != nil && strings.Contains(st.Why, "no fleet.conf")
	})

	loginReportsFleet(t, h, "mac-c", op.Login, machineB)
	if st := h.srv.accountStateOf(inv.PersonID, time.Now().Add(openingSettle+time.Minute)); st != nil {
		t.Fatalf("its fleet reported, yet account = %+v", st)
	}
	if notes := h.srv.openingNotes(inv.PersonID); notes["mac-c"] != "" {
		t.Fatalf("its fleet reported, yet the placement note = %q", notes["mac-c"])
	}
}

// A create far past what its machine usually takes reads failed before the
// 20-minute give-up (claude-fleet#2941): 3 × the machine's median, never
// sooner than openingOverFloor; the countdown reaches its floor there.
func TestOpeningPastItsOwnETAFails(t *testing.T) {
	if got := openingOver(60); got != openingOverFloor {
		t.Fatalf("over(60 s) = %s; want the floor %s", got, openingOverFloor)
	}
	if got := openingOver(300); got != 15*time.Minute {
		t.Fatalf("over(300 s) = %s; want 15m", got)
	}
	if got := openingOver(openingETA); got != openingGiveUp {
		t.Fatalf("over(%d s) = %s; want the give-up %s", openingETA, got, openingGiveUp)
	}
	if got := openingETALeft(60, openingOverFloor); got != 5 {
		t.Fatalf("eta at the floor = %d; want 5", got)
	}

	h, nodes, inv := drillOnFleet(t)
	m, op := expectAccountOp(t, nodes["mac-c"].tnode)
	// mac-c has opened one before, in a minute: its median is the 60 s floor.
	sendResult(t, nodes["mac-c"].c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true})
	waitState(t, h, inv.PersonID, "mac-c", store.AccountActive)
	if got := h.srv.openingETAFor("mac-c"); got != 60 {
		t.Fatalf("eta = %d; want 60", got)
	}
	slow := store.FleetAccount{Hostname: "mac-c", Login: "slow", State: store.AccountCreating, RequestedAt: time.Now().Add(-openingOverFloor - time.Minute)}
	if why := h.srv.openingStuck(slow, time.Now()); !strings.Contains(why, "usually takes about 1 min") {
		t.Fatalf("a create past 3 × its machine's median: why = %q", why)
	}
	slow.RequestedAt = time.Now().Add(-openingOverFloor + time.Minute)
	if why := h.srv.openingStuck(slow, time.Now()); why != "" {
		t.Fatalf("a create inside the floor is stuck already: %q", why)
	}
}
