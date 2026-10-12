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

// claude-fleet#3501 (EPIC #3500 C9, with #3502): a person the hub already
// records is handed a ready spare too — the operator's assign makes the login
// active in the same request, nothing sent to the machine, the login the
// spare's fleetu<N> while their own name stays theirs elsewhere; own_name
// opens their own name instead. Each place (a machine, or a cluster standing
// as one roster place) keeps its desired state's spare_accounts, else
// fleet.spare_max (default 2); the roster counts ready, resetting and failed
// spares apart.

// readySpares waits until host holds n ready spares.
func readySpares(t *testing.T, h *harness, host string, n int) {
	t.Helper()
	waitFor(t, 3*time.Second, host+"'s spares to be ready", func() bool {
		return h.srv.spareReadyHosts()[host] == n
	})
}

// assignAccount is the operator's POST /v1/fleet/accounts.
func assignAccount(t *testing.T, h *harness, req FleetAccountRequest) store.FleetAccount {
	t.Helper()
	req.Action = "assign"
	code, out := h.post(t, "/v1/fleet/accounts", req)
	if code != http.StatusOK {
		t.Fatalf("assign %s on %s: HTTP %d %v", req.PrincipalID, req.Hostname, code, out)
	}
	return accountState(t, h, req.PrincipalID, req.Hostname)
}

func TestSpareHandedToARecordedPerson(t *testing.T) {
	h := newFleetHarness(t)
	const p = "gh:6101"
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	sparesOn(t, h, "1")
	m4 := openSpares(t, nodes["m4"], 1, control.CredsepSeparated)
	m5 := openSpares(t, nodes["m5"], 1, control.CredsepSeparated)
	readySpares(t, h, "m4", 1)
	readySpares(t, h, "m5", 1)
	if _, err := h.srv.Store.AdoptPrincipal(p, "lisi", "LiSi", time.Now()); err != nil {
		t.Fatal(err)
	}

	t0 := time.Now()
	a := assignAccount(t, h, FleetAccountRequest{PrincipalID: p, Hostname: "m5"})
	if took := time.Since(t0); took > 3*time.Second {
		t.Fatalf("assign took %v; want ≤ 3s", took)
	}
	if a.State != store.AccountActive || a.Login != m5[0] {
		t.Fatalf("account on m5 = %+v; want active under the spare's %s in the same request", a)
	}
	// Nothing for the person is sent: m5's next op is the refill's.
	if _, op := expectAccountOp(t, nodes["m5"].tnode); op.Op != control.AccountCreate ||
		!strings.HasPrefix(op.Login, "fleetu") || op.Login == m5[0] || op.FullName != store.SpareFullName {
		t.Fatalf("m5 op = %+v; want only the refill's spare create", op)
	}
	// Their own name is unchanged; the spare's principal is gone.
	if pr, err := h.srv.Store.Principal(p); err != nil || pr.Login != "lisi" {
		t.Fatalf("principal = %+v, %v; want login lisi kept", pr, err)
	}
	if pr, err := h.srv.Store.PrincipalByLogin(m5[0]); err != nil || pr.ID != p {
		t.Fatalf("PrincipalByLogin(%s) = %+v, %v; want %s", m5[0], pr, err, p)
	}
	for _, sp := range mustSpares(t, h) {
		if sp.Login == m5[0] {
			t.Fatalf("the claimed spare is still a spare: %+v", sp)
		}
	}

	// A second machine: another spare, another name.
	b := assignAccount(t, h, FleetAccountRequest{PrincipalID: p, Hostname: "m4"})
	if b.State != store.AccountActive || b.Login != m4[0] || b.Login == a.Login {
		t.Fatalf("account on m4 = %+v; want active under %s", b, m4[0])
	}
	// Every 「person → login there」 reads the account rows.
	for host, login := range map[string]string{"m5": m5[0], "m4": m4[0]} {
		if who, err := h.srv.Store.PrincipalForLogin(host, login); err != nil || who != p {
			t.Fatalf("PrincipalForLogin(%s, %s) = %q, %v; want %s", host, login, who, err, p)
		}
	}
	_, logins, _, err := h.srv.fleetLoginsOf(p)
	if err != nil || strings.Join(logins, ",") != strings.Join(sortedPair(m4[0], m5[0]), ",") {
		t.Fatalf("certificate logins = %v, %v; want both spares' names", logins, err)
	}
	loginOn, err := h.srv.homeLogins(p)
	if err != nil {
		t.Fatal(err)
	}
	if l, _ := loginOn("m5"); l != m5[0] {
		t.Fatalf("home login on m5 = %q; want %s", l, m5[0])
	}
	if l, _ := loginOn("m4"); l != m4[0] {
		t.Fatalf("home login on m4 = %q; want %s", l, m4[0])
	}

	// A login of theirs already there is left alone: no second spare.
	if c := assignAccount(t, h, FleetAccountRequest{PrincipalID: p, Hostname: "m5"}); c.Login != m5[0] {
		t.Fatalf("second assign on m5 = %+v", c)
	}
}

func sortedPair(a, b string) []string {
	if a > b {
		return []string{b, a}
	}
	return []string{a, b}
}

func mustSpares(t *testing.T, h *harness) []store.FleetAccount {
	t.Helper()
	sp, err := h.srv.Store.SpareAccounts()
	if err != nil {
		t.Fatal(err)
	}
	return sp
}

// own_name skips a ready spare and opens the person's own name; no spare
// ready opens it too.
func TestSpareOwnNameAndNoneReady(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	sparesOn(t, h, "1")
	openSpares(t, nodes["m4"], 1, control.CredsepSeparated)
	openSpares(t, nodes["m5"], 1, control.CredsepSeparated)
	readySpares(t, h, "m5", 1)
	if _, err := h.srv.Store.AdoptPrincipal("gh:6102", "wangwu", "", time.Now()); err != nil {
		t.Fatal(err)
	}
	a := assignAccount(t, h, FleetAccountRequest{PrincipalID: "gh:6102", Hostname: "m5", OwnName: true})
	if a.Login != "wangwu" || a.State == store.AccountActive {
		t.Fatalf("own_name account = %+v; want wangwu queued", a)
	}
	if _, op := expectAccountOp(t, nodes["m5"].tnode); op.Op != control.AccountCreate || op.Login != "wangwu" {
		t.Fatalf("op = %+v; want wangwu's own create", op)
	}
	if r := h.srv.spareReadyHosts(); r["m5"] != 1 {
		t.Fatalf("m5 ready spares = %d; own_name must leave it", r["m5"])
	}

	// m4's one spare taken, none left: the next person gets their own name.
	if _, err := h.srv.Store.AdoptPrincipal("gh:6103", "zhaoliu", "", time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.AdoptPrincipal("gh:6104", "qianqi", "", time.Now()); err != nil {
		t.Fatal(err)
	}
	if a := assignAccount(t, h, FleetAccountRequest{PrincipalID: "gh:6103", Hostname: "m4"}); a.State != store.AccountActive {
		t.Fatalf("first assign on m4 = %+v; want the spare", a)
	}
	b := assignAccount(t, h, FleetAccountRequest{PrincipalID: "gh:6104", Hostname: "m4"})
	if b.Login != "qianqi" || b.State == store.AccountActive {
		t.Fatalf("assign with no spare ready = %+v; want qianqi queued", b)
	}
}

// The target is the place's desired spare_accounts when written (0 too), else
// fleet.spare_max (default 2), never past the login cap's room.
func TestSpareTargetFollowsDesiredState(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	spareFleet(t, h)
	setHubSetting(t, h.srv, SparesKey, "on")
	target := func(host string) int {
		t.Helper()
		pic, err := h.srv.sparePicture(host)
		if err != nil {
			t.Fatal(err)
		}
		return pic[host].Target
	}
	put := func(ep, body string) {
		t.Helper()
		if _, err := h.srv.Store.PutDesired(ep, body, "test", -1, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	if target("m4") != 2 || target("m5") != 2 {
		t.Fatalf("default target = %d / %d; want 2", target("m4"), target("m5"))
	}
	for _, n := range []int{1, 3, 0} {
		b, _ := json.Marshal(DesiredBody{Spares: &n})
		put("ep_m4-op", string(b))
		if got := target("m4"); got != n {
			t.Fatalf("desired spare_accounts %d (%s): target %d", n, b, got)
		}
		if got := target("m5"); got != 2 {
			t.Fatalf("m5 (no desired state) target %d; want the default 2", got)
		}
	}
	// A desired state that does not name the key keeps the setting.
	put("ep_m4-op", `{"release":"abc123"}`)
	setHubSetting(t, h.srv, SpareMaxKey, "4")
	if target("m4") != 4 || target("m5") != 4 {
		t.Fatalf("fleet.spare_max 4: %d / %d", target("m4"), target("m5"))
	}
	// The cap still bounds it.
	put("ep_m4-op", `{"spare_accounts":9}`)
	setHubSetting(t, h.srv, NodeUserCapPrefix+"m4", "3")
	if got := target("m4"); got != 3 {
		t.Fatalf("desired 9 under a cap of 3: target %d", got)
	}
}

// Resetting and failed spares are counted apart, never ready, and held (no
// refill beside them).
func TestSpareRosterCountsResettingAndFailed(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	sparesOn(t, h, "3")
	openSpares(t, nodes["m5"], 3, control.CredsepSeparated)
	for i := 0; i < 3; i++ {
		m, op := expectAccountOp(t, nodes["m4"].tnode)
		word := control.CredsepSeparated
		if i == 0 {
			word = "" // not separated: failed
		}
		sendResult(t, nodes["m4"].c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true, Credsep: word})
	}
	readySpares(t, h, "m5", 3)
	readySpares(t, h, "m4", 2)
	for _, sp := range mustSpares(t, h) {
		if sp.Hostname == "m5" {
			if ok, err := h.srv.Store.MarkAccountSent(sp.PrincipalID, "m5", store.AccountActive, store.AccountResetting, "op-reset", "", time.Now()); err != nil || !ok {
				t.Fatalf("mark resetting: %v %v", ok, err)
			}
			break
		}
	}
	var snap NodesSnapshot
	h.getJSON(t, "/v1/nodes", &snap)
	want := map[string][3]int{"m4": {2, 0, 1}, "m5": {2, 1, 0}}
	for _, m := range snap.Machines {
		w, ok := want[m.Hostname]
		if !ok {
			continue
		}
		delete(want, m.Hostname)
		if m.Spare == nil || m.SpareResetting == nil || m.SpareFailed == nil || m.SpareTarget == nil ||
			[3]int{*m.Spare, *m.SpareResetting, *m.SpareFailed} != w || *m.SpareTarget != 3 {
			t.Fatalf("%s = spare %v resetting %v failed %v target %v; want %v / 3", m.Hostname, m.Spare, m.SpareResetting, m.SpareFailed, m.SpareTarget, w)
		}
	}
	if len(want) != 0 {
		t.Fatalf("not on the roster: %v", want)
	}
	h.srv.replenishSpares(time.Now(), true)
	h.srv.dispatchAccounts()
	noOp(t, nodes, "m4", "m5")
}

// A cluster stands on the roster as one place: its spares (a pod each, made
// by its node) are claimed and refilled exactly like a machine's.
func TestSpareClusterPlaceClaimAndRefill(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	h.srv.FleetAdmins = []string{"verkyyi"}
	const place = "fleet-workers"
	n := connectCaps(t, h, "cluster-op", place, "verkyyi", true, control.CapCredsep)
	beatCount(t, n, place, "verkyyi", 0)
	waitFor(t, 3*time.Second, "the cluster to be a fit place", func() bool {
		for _, fit := range h.srv.spareFitMachines(time.Now()) {
			if fit == place {
				return true
			}
		}
		return false
	})
	setHubSetting(t, h.srv, SparesKey, "on") // no fleet.spare_max: the default 2
	h.srv.replenishSpares(time.Now(), true)
	h.srv.dispatchAccounts()
	pods := openSpares(t, n, 2, control.CredsepSeparated)
	readySpares(t, h, place, 2)

	if _, err := h.srv.Store.AdoptPrincipal("gh:6201", "arvin", "", time.Now()); err != nil {
		t.Fatal(err)
	}
	a := assignAccount(t, h, FleetAccountRequest{PrincipalID: "gh:6201", Hostname: place})
	if a.State != store.AccountActive || (a.Login != pods[0] && a.Login != pods[1]) {
		t.Fatalf("cluster account = %+v; want one of %v, active", a, pods)
	}
	_, op := expectAccountOp(t, n.tnode)
	if op.Op != control.AccountCreate || op.FullName != store.SpareFullName || op.Login == pods[0] || op.Login == pods[1] {
		t.Fatalf("refill op = %+v; want one new spare", op)
	}
	if got, ok := readMsg(n.tnode, 250*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("the cluster was sent more than the one refill: %+v", got)
	}
}

func TestDesiredSparesKeepsZero(t *testing.T) {
	zero := 0
	b, _ := json.Marshal(DesiredBody{Spares: &zero})
	if !strings.Contains(string(b), `"spare_accounts":0`) {
		t.Fatalf("desired body %s drops a written 0", b)
	}
	b, _ = json.Marshal(DesiredBody{})
	if strings.Contains(string(b), "spare_accounts") {
		t.Fatalf("desired body %s writes an unset count", b)
	}
	big := 33
	if (DesiredBody{Spares: &big}).validate() == nil {
		t.Fatal("spare_accounts 33 accepted")
	}
}
