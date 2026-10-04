package api

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Who a person is, and whose login is whose (claude-fleet#1458).
//
// The authorization service signs ONE `sub` per app — the role "staff" — so
// every colleague's ticket carries the same subject, and a hub that keyed the
// person on it filed everyone as one principal. The person is the ticket's
// `uid`; the operator says whose login is whose in CCQUOTA_FLEET_PRINCIPAL_LOGINS;
// a mapped login is adopted where an agent runs as it, never created; an
// unmapped sign-in leaves no row.

const staffSub = "ccquota-staff"

func enterAs(t *testing.T, h *harness, uid, name string) {
	t.Helper()
	resp := h.raw(t, "/enter?ticket="+mintTicketFor(t, "ccquota", staffSub, uid, name, time.Now().Add(time.Minute).Unix()), nil)
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("/enter as %q: HTTP %d", uid, resp.StatusCode)
	}
}

func meFor(t *testing.T, h *harness, resp *http.Response) FleetMe {
	t.Helper()
	c := sessionCookie(t, resp)
	if c == nil {
		t.Fatal("no session cookie")
	}
	r, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/fleet/me", nil)
	r.AddCookie(c)
	res, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var me FleetMe
	if err := json.NewDecoder(res.Body).Decode(&me); err != nil || res.StatusCode != 200 {
		t.Fatalf("/v1/fleet/me: HTTP %d %v", res.StatusCode, err)
	}
	return me
}

// The acceptance line of #1458: the operator signs in, /v1/fleet/me says
// `yilianghui`, and their login `verkyyi` is active on the two machines whose
// agents run as it — recorded by adoption, with no create op ever sent to the
// admin node. A colleague mapped to a login that exists on ONE machine gets
// exactly that one.
func TestFleetMappedPersonIsAdoptedWhereTheLoginRunsNeverCreated(t *testing.T) {
	h := newFleetHarness(t)
	enableSSO(h)
	h.srv.FleetAdmins = []string{"verkyyi"}
	h.srv.FleetAutoAssign = []string{"macmini", "mini2"} // must NOT apply to a mapped person
	h.srv.FleetPrincipalLogins = map[string]string{"yilianghui": "verkyyi", "caojian": "24haowan"}
	admin := connectNode(t, h, "m5-op", "macmini", "verkyyi", true)
	connectNode(t, h, "m5-24h", "macmini", "24haowan", false)
	m4admin := connectNode(t, h, "m4-op", "mini2", "verkyyi", true)
	waitFor(t, 3*time.Second, "three nodes", func() bool { return len(roster(t, h).Nodes) == 3 })

	resp := h.raw(t, "/enter?ticket="+mintTicketFor(t, "ccquota", staffSub, "yilianghui", "易良辉", time.Now().Add(time.Minute).Unix()), nil)
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("/enter: HTTP %d", resp.StatusCode)
	}
	me := meFor(t, h, resp)
	if !me.Signed || me.Person != "yilianghui" || me.Principal == nil || me.Principal.ID != "yilianghui" ||
		me.Principal.Login != "verkyyi" || me.Principal.DisplayName != "易良辉" {
		t.Fatalf("/v1/fleet/me = %+v", me)
	}
	hosts := map[string]string{}
	for _, a := range me.Accounts {
		hosts[a.Hostname] = a.State + "/" + a.Op
	}
	if len(hosts) != 2 || hosts["macmini"] != "active/adopt" || hosts["mini2"] != "active/adopt" {
		t.Fatalf("accounts = %v, want verkyyi adopted on macmini and mini2", hosts)
	}
	for name, n := range map[string]*fleetNode{"macmini admin": admin, "mini2 admin": m4admin} {
		if got, ok := readMsg(n.tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
			t.Fatalf("%s was sent an op for a mapped person: %+v", name, got)
		}
	}

	// A colleague whose login exists on one machine only.
	enterAs(t, h, "caojian", "")
	p, err := h.srv.Store.Principal("caojian")
	if err != nil || p.Login != "24haowan" {
		t.Fatalf("caojian → %+v %v", p, err)
	}
	accts, _ := h.srv.Store.FleetAccounts("caojian")
	if len(accts) != 1 || accts[0].Hostname != "macmini" || accts[0].State != store.AccountActive {
		t.Fatalf("caojian's accounts = %+v, want 24haowan adopted on macmini only", accts)
	}
	// ...and only sees that machine's own login, never the operator's.
	_, body := asPerson(t, h, http.MethodGet, "/v1/nodes", "caojian", nil)
	var snap NodesSnapshot
	json.Unmarshal(body, &snap)
	if len(snap.Nodes) != 1 || snap.Nodes[0].OSUser != "24haowan" || snap.Nodes[0].Hostname != "macmini" {
		t.Fatalf("caojian sees %+v", snap.Nodes)
	}

	// A machine that joins AFTER the sign-in is adopted at its hello.
	connectNode(t, h, "m6-op", "mini3", "verkyyi", true)
	waitState(t, h, "yilianghui", "mini3", store.AccountActive)
	// A machine joining as somebody else's login adopts nothing for anyone.
	connectNode(t, h, "m6-x", "mini3", "mallory", false)
	time.Sleep(100 * time.Millisecond)
	if as, _ := h.srv.Store.FleetAccounts(""); len(as) != 4 {
		t.Fatalf("accounts = %+v, want exactly 4", as)
	}

	// The operator's view lists two people and no create op anywhere.
	r, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/fleet/accounts", nil)
	r.Header.Set("Authorization", "Bearer "+viewerToken)
	res, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var view FleetAccountsView
	json.NewDecoder(res.Body).Decode(&view)
	if len(view.Principals) != 2 {
		t.Fatalf("principals = %+v", view.Principals)
	}
	for _, a := range view.Accounts {
		if a.State != store.AccountActive || a.Op != "adopt" {
			t.Fatalf("a non-adopt row: %+v", a)
		}
	}
}

// With no map entry and no auto-assign, a sign-in records nothing: no row,
// no minted login, no op — but the session still knows who it is, sees no
// machine, and cannot act as the operator.
func TestFleetUnmappedSignInLeavesNoRow(t *testing.T) {
	h := newFleetHarness(t)
	enableSSO(h)
	h.srv.FleetPrincipalLogins = map[string]string{"yilianghui": "verkyyi"}
	connectNode(t, h, "m5-op", "macmini", "verkyyi", true)

	resp := h.raw(t, "/enter?ticket="+mintTicketFor(t, "ccquota", staffSub, "zhangsan", "张三", time.Now().Add(time.Minute).Unix()), nil)
	me := meFor(t, h, resp)
	if !me.Signed || me.Person != "zhangsan" || me.Principal != nil || len(me.Accounts) != 0 {
		t.Fatalf("/v1/fleet/me = %+v", me)
	}
	if ps, _ := h.srv.Store.Principals(); len(ps) != 0 {
		t.Fatalf("an unmapped sign-in minted %+v", ps)
	}
	_, body := asPerson(t, h, http.MethodGet, "/v1/nodes", "zhangsan", nil)
	var snap NodesSnapshot
	json.Unmarshal(body, &snap)
	if len(snap.Nodes) != 0 {
		t.Fatalf("zhangsan sees %+v", snap.Nodes)
	}
	if code, _ := asPerson(t, h, http.MethodGet, "/v1/fleet/accounts", "zhangsan", nil); code != http.StatusForbidden {
		t.Fatalf("a person listed accounts: HTTP %d", code)
	}
	// The operator's door is not a person: /v1/fleet/me says so.
	r, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/fleet/me", nil)
	r.Header.Set("Authorization", "Bearer "+viewerToken)
	res, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var op FleetMe
	json.NewDecoder(res.Body).Decode(&op)
	if op.Signed || op.Person != "" || op.Principal != nil {
		t.Fatalf("operator's /v1/fleet/me = %+v", op)
	}
}

// The bug itself: a ticket with no `uid` names the role, and two colleagues
// exchanging such tickets are the SAME subject. The hub must not file that
// subject as a person — even when the map names people — and must say which
// subject it fell back to, so the misconfiguration (the issuer's
// AUTHZ_UID_APPS) is visible rather than everyone silently sharing one
// identity.
func TestFleetTicketWithoutUIDIsARoleNotAPerson(t *testing.T) {
	h := newFleetHarness(t)
	enableSSO(h)
	h.srv.FleetPrincipalLogins = map[string]string{"yilianghui": "verkyyi"}
	connectNode(t, h, "m5-op", "macmini", "verkyyi", true)

	for i := 0; i < 2; i++ {
		resp := h.raw(t, "/enter?ticket="+mintTicket(t, "ccquota", staffSub, time.Now().Add(time.Minute).Unix()), nil)
		me := meFor(t, h, resp)
		if !me.Signed || me.Person != staffSub || me.Principal != nil || len(me.Accounts) != 0 {
			t.Fatalf("/v1/fleet/me = %+v", me)
		}
	}
	if ps, _ := h.srv.Store.Principals(); len(ps) != 0 {
		t.Fatalf("the role subject was filed as a person: %+v", ps)
	}
	// Once the issuer names the person, the same subject becomes them.
	enterAs(t, h, "yilianghui", "")
	if p, err := h.srv.Store.Principal("yilianghui"); err != nil || p.Login != "verkyyi" {
		t.Fatalf("yilianghui → %+v %v", p, err)
	}
	if _, err := h.srv.Store.Principal(staffSub); err == nil {
		t.Fatal("the role subject got a row")
	}
}

// Cleaning up the wrong identity: a principal filed under the role, with a
// create still queued for a node that never connected. `forget` drops the
// hub's record without sending anything; it refuses a row that reached a
// machine, so an active login cannot be forgotten into a ghost.
func TestFleetForgetDropsOnlyRowsThatNeverReachedAMachine(t *testing.T) {
	h := newFleetHarness(t)
	enableSSO(h)
	h.srv.FleetAdmins = []string{"verkyyi"}

	// The bad data, as production had it: a row minted for the role and a
	// create queued on a machine with no admin connected.
	if code := operatorPost(t, h, FleetAccountRequest{Action: "assign", PrincipalID: staffSub, Hostname: "mini2"}); code != 200 {
		t.Fatalf("assign: HTTP %d", code)
	}
	if a := accountState(t, h, staffSub, "mini2"); a.State != store.AccountPending {
		t.Fatalf("queued row = %+v", a)
	}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "forget", PrincipalID: staffSub}); code != 200 {
		t.Fatalf("forget: HTTP %d", code)
	}
	if _, err := h.srv.Store.Principal(staffSub); err == nil {
		t.Fatal("forget left the principal")
	}
	if as, _ := h.srv.Store.FleetAccounts(staffSub); len(as) != 0 {
		t.Fatalf("forget left %+v", as)
	}
	// Forgetting what is not there is a state error, not a success.
	if code := operatorPost(t, h, FleetAccountRequest{Action: "forget", PrincipalID: staffSub}); code != http.StatusBadRequest {
		t.Fatalf("forget of nobody: HTTP %d", code)
	}

	// An adopted (active) login refuses to be forgotten; `remove` is the
	// path that actually closes it. A pending row beside it can still go,
	// by hostname, leaving the active one.
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: "Alice", Hostname: "macmini", Login: "alice"}); code != 200 {
		t.Fatalf("adopt: HTTP %d", code)
	}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "assign", PrincipalID: "Alice", Hostname: "mini2"}); code != 200 {
		t.Fatalf("assign: HTTP %d", code)
	}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "forget", PrincipalID: "Alice"}); code != http.StatusConflict {
		t.Fatalf("forget with an active login: HTTP %d, want 409", code)
	}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "forget", PrincipalID: "Alice", Hostname: "mini2"}); code != 200 {
		t.Fatalf("forget pending row: HTTP %d", code)
	}
	as, _ := h.srv.Store.FleetAccounts("Alice")
	if len(as) != 1 || as[0].Hostname != "macmini" || as[0].State != store.AccountActive {
		t.Fatalf("after forgetting mini2: %+v", as)
	}
	// A WeCom session can no more forget than assign.
	req, _ := json.Marshal(FleetAccountRequest{Action: "forget", PrincipalID: "Alice"})
	if code, _ := asPerson(t, h, http.MethodPost, "/v1/fleet/accounts", "Alice", req); code != http.StatusForbidden {
		t.Fatalf("a person forgot an account: HTTP %d", code)
	}
}

// The map never changes a login the hub already minted for that person: a
// row from before the map (or from auto-assign) is reported, not overwritten.
func TestFleetMapRefusesToRenameAnExistingLogin(t *testing.T) {
	h := newFleetHarness(t)
	enableSSO(h)
	h.srv.FleetPrincipalLogins = map[string]string{"yilianghui": "verkyyi"}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: "yilianghui", Hostname: "mini2", Login: "yilianghui"}); code != 200 {
		t.Fatalf("adopt: HTTP %d", code)
	}
	connectNode(t, h, "m5-op", "macmini", "verkyyi", true)
	enterAs(t, h, "yilianghui", "")
	p, _ := h.srv.Store.Principal("yilianghui")
	if p.Login != "yilianghui" {
		t.Fatalf("sign-in renamed the login: %+v", p)
	}
	if a := accountState(t, h, "yilianghui", "macmini"); a.State != "" {
		t.Fatalf("a mismatched row was adopted onto macmini: %+v", a)
	}
}

// Nothing in this change touches a hub that sets no map: a sign-in with
// auto-assign still mints and queues as claude-fleet#1411 shipped it.
func TestFleetNoMapIsTheOldBehaviour(t *testing.T) {
	h := newFleetHarness(t)
	enableSSO(h)
	h.srv.FleetAdmins = []string{"verkyyi"}
	h.srv.FleetAutoAssign = []string{"m4"}
	admin := connectNode(t, h, "m4-op", "m4", "verkyyi", true)
	enterAs(t, h, "zhangsan", "张三")
	_, op := expectAccountOp(t, admin.tnode)
	if op.Op != control.AccountCreate || op.Login != "zhangsan" || op.FullName != "张三" {
		t.Fatalf("op = %+v", op)
	}
}
