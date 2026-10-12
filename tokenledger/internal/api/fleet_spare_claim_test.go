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
	macC := openSpares(t, nodes["mac-c"], 1, control.CredsepSeparated)
	macD := openSpares(t, nodes["mac-d"], 1, control.CredsepSeparated)
	readySpares(t, h, "mac-c", 1)
	readySpares(t, h, "mac-d", 1)
	if _, err := h.srv.Store.AdoptPrincipal(p, "lisi", "LiSi", time.Now()); err != nil {
		t.Fatal(err)
	}

	t0 := time.Now()
	a := assignAccount(t, h, FleetAccountRequest{PrincipalID: p, Hostname: "mac-d"})
	if took := time.Since(t0); took > 3*time.Second {
		t.Fatalf("assign took %v; want ≤ 3s", took)
	}
	if a.State != store.AccountActive || a.Login != macD[0] {
		t.Fatalf("account on mac-d = %+v; want active under the spare's %s in the same request", a, macD[0])
	}
	// Nothing for the person is sent: mac-d's next op is the refill's.
	if _, op := expectAccountOp(t, nodes["mac-d"].tnode); op.Op != control.AccountCreate ||
		!strings.HasPrefix(op.Login, "fleetu") || op.Login == macD[0] || op.FullName != store.SpareFullName {
		t.Fatalf("mac-d op = %+v; want only the refill's spare create", op)
	}
	// Their own name is unchanged; the spare's principal is gone.
	if pr, err := h.srv.Store.Principal(p); err != nil || pr.Login != "lisi" {
		t.Fatalf("principal = %+v, %v; want login lisi kept", pr, err)
	}
	if pr, err := h.srv.Store.PrincipalByLogin(macD[0]); err != nil || pr.ID != p {
		t.Fatalf("PrincipalByLogin(%s) = %+v, %v; want %s", macD[0], pr, err, p)
	}
	for _, sp := range mustSpares(t, h) {
		if sp.Login == macD[0] {
			t.Fatalf("the claimed spare is still a spare: %+v", sp)
		}
	}

	// A second machine: another spare, another name.
	b := assignAccount(t, h, FleetAccountRequest{PrincipalID: p, Hostname: "mac-c"})
	if b.State != store.AccountActive || b.Login != macC[0] || b.Login == a.Login {
		t.Fatalf("account on mac-c = %+v; want active under %s", b, macC[0])
	}
	// Every 「person → login there」 reads the account rows.
	for host, login := range map[string]string{"mac-d": macD[0], "mac-c": macC[0]} {
		if who, err := h.srv.Store.PrincipalForLogin(host, login); err != nil || who != p {
			t.Fatalf("PrincipalForLogin(%s, %s) = %q, %v; want %s", host, login, who, err, p)
		}
	}
	_, logins, _, err := h.srv.fleetLoginsOf(p)
	if err != nil || strings.Join(logins, ",") != strings.Join(sortedPair(macC[0], macD[0]), ",") {
		t.Fatalf("certificate logins = %v, %v; want both spares' names", logins, err)
	}
	loginOn, err := h.srv.homeLogins(p)
	if err != nil {
		t.Fatal(err)
	}
	if l, _ := loginOn("mac-d"); l != macD[0] {
		t.Fatalf("home login on mac-d = %q; want %s", l, macD[0])
	}
	if l, _ := loginOn("mac-c"); l != macC[0] {
		t.Fatalf("home login on mac-c = %q; want %s", l, macC[0])
	}

	// A login of theirs already there is left alone: no second spare.
	if c := assignAccount(t, h, FleetAccountRequest{PrincipalID: p, Hostname: "mac-d"}); c.Login != macD[0] {
		t.Fatalf("second assign on mac-d = %+v", c)
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
	openSpares(t, nodes["mac-c"], 1, control.CredsepSeparated)
	openSpares(t, nodes["mac-d"], 1, control.CredsepSeparated)
	readySpares(t, h, "mac-d", 1)
	if _, err := h.srv.Store.AdoptPrincipal("gh:6102", "wangwu", "", time.Now()); err != nil {
		t.Fatal(err)
	}
	a := assignAccount(t, h, FleetAccountRequest{PrincipalID: "gh:6102", Hostname: "mac-d", OwnName: true})
	if a.Login != "wangwu" || a.State == store.AccountActive {
		t.Fatalf("own_name account = %+v; want wangwu queued", a)
	}
	if _, op := expectAccountOp(t, nodes["mac-d"].tnode); op.Op != control.AccountCreate || op.Login != "wangwu" {
		t.Fatalf("op = %+v; want wangwu's own create", op)
	}
	if r := h.srv.spareReadyHosts(); r["mac-d"] != 1 {
		t.Fatalf("mac-d ready spares = %d; own_name must leave it", r["mac-d"])
	}

	// mac-c's one spare taken, none left: the next person gets their own name.
	if _, err := h.srv.Store.AdoptPrincipal("gh:6103", "zhaoliu", "", time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.AdoptPrincipal("gh:6104", "qianqi", "", time.Now()); err != nil {
		t.Fatal(err)
	}
	if a := assignAccount(t, h, FleetAccountRequest{PrincipalID: "gh:6103", Hostname: "mac-c"}); a.State != store.AccountActive {
		t.Fatalf("first assign on mac-c = %+v; want the spare", a)
	}
	b := assignAccount(t, h, FleetAccountRequest{PrincipalID: "gh:6104", Hostname: "mac-c"})
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
	if target("mac-c") != 2 || target("mac-d") != 2 {
		t.Fatalf("default target = %d / %d; want 2", target("mac-c"), target("mac-d"))
	}
	for _, n := range []int{1, 3, 0} {
		b, _ := json.Marshal(DesiredBody{Spares: &n})
		put("ep_mac-c-op", string(b))
		if got := target("mac-c"); got != n {
			t.Fatalf("desired spare_accounts %d (%s): target %d", n, b, got)
		}
		if got := target("mac-d"); got != 2 {
			t.Fatalf("mac-d (no desired state) target %d; want the default 2", got)
		}
	}
	// A desired state that does not name the key keeps the setting.
	put("ep_mac-c-op", `{"release":"abc123"}`)
	setHubSetting(t, h.srv, SpareMaxKey, "4")
	if target("mac-c") != 4 || target("mac-d") != 4 {
		t.Fatalf("fleet.spare_max 4: %d / %d", target("mac-c"), target("mac-d"))
	}
	// The cap still bounds it.
	put("ep_mac-c-op", `{"spare_accounts":9}`)
	setHubSetting(t, h.srv, NodeUserCapPrefix+"mac-c", "3")
	if got := target("mac-c"); got != 3 {
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
	openSpares(t, nodes["mac-d"], 3, control.CredsepSeparated)
	for i := 0; i < 3; i++ {
		m, op := expectAccountOp(t, nodes["mac-c"].tnode)
		word := control.CredsepSeparated
		if i == 0 {
			word = "" // not separated: failed
		}
		sendResult(t, nodes["mac-c"].c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true, Credsep: word})
	}
	readySpares(t, h, "mac-d", 3)
	readySpares(t, h, "mac-c", 2)
	for _, sp := range mustSpares(t, h) {
		if sp.Hostname == "mac-d" {
			if ok, err := h.srv.Store.MarkAccountSent(sp.PrincipalID, "mac-d", store.AccountActive, store.AccountResetting, "op-reset", "", time.Now()); err != nil || !ok {
				t.Fatalf("mark resetting: %v %v", ok, err)
			}
			break
		}
	}
	var snap NodesSnapshot
	h.getJSON(t, "/v1/nodes", &snap)
	want := map[string][3]int{"mac-c": {2, 0, 1}, "mac-d": {2, 1, 0}}
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
	noOp(t, nodes, "mac-c", "mac-d")
}

// A cluster stands on the roster as one place: its spares (a pod each, made
// by its node) are claimed and refilled exactly like a machine's.
func TestSpareClusterPlaceClaimAndRefill(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	h.srv.FleetAdmins = []string{"ivan"}
	const place = "fleet-workers"
	n := connectCaps(t, h, "cluster-op", place, "ivan", true, control.CapCredsep)
	beatCount(t, n, place, "ivan", 0)
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

	if _, err := h.srv.Store.AdoptPrincipal("gh:6201", "erin", "", time.Now()); err != nil {
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
