package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"html"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Whose login is whose (claude-fleet#1458): the person is gh:<GitHub ID>;
// the operator says whose login is whose in user.<id>.machine_login
// (claude-fleet#1986 — the only source since #2087); a mapped login is
// adopted where an agent runs as it, never created; an unmapped sign-in
// leaves no row.

// The people of these tests, by the logins the map gives them.
const (
	pYi    = "gh:2718137" // verkyyi
	pCao   = "gh:3001"    // 24haowan
	pHuang = "gh:3002"    // vincent
	pZhang = "gh:3003"    // in no map
)

// mapLogins records each person's machine login in the settings, as the
// operator's user.<id>.machine_login would — straight into the table, so no
// placement runs before the test asks for one.
func mapLogins(t *testing.T, s *Server, m map[string]string) {
	t.Helper()
	for pid, login := range m {
		setHubSetting(t, s, machineLoginSettingKey(strings.ToLower(pid)), login)
	}
}

// enterAs is what the GitHub callback runs once uid is through.
func enterAs(t *testing.T, h *harness, uid, name string) {
	t.Helper()
	listPerson(t, h, uid, "")
	h.srv.onPrincipalSignIn(uid, name)
}

func meFor(t *testing.T, h *harness, uid string) FleetMe {
	t.Helper()
	r, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/fleet/me", nil)
	r.AddCookie(personCookie(uid, ""))
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

// The acceptance line of #1458: the operator signs in, /v1/fleet/me names
// them, and their login `verkyyi` is active on the two machines whose
// agents run as it — recorded by adoption, with no create op ever sent to the
// admin node. A colleague mapped to a login that exists on ONE machine gets
// exactly that one.
func TestFleetMappedPersonIsAdoptedWhereTheLoginRunsNeverCreated(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	h.srv.FleetAdmins = []string{"verkyyi"}
	setHubSetting(t, h.srv, AutoAssignKey, "macmini,mini2") // must NOT apply to a mapped person
	mapLogins(t, h.srv, map[string]string{pYi: "verkyyi", pCao: "24haowan"})
	admin := connectNode(t, h, "m5-op", "macmini", "verkyyi", true)
	connectNode(t, h, "m5-24h", "macmini", "24haowan", false)
	m4admin := connectNode(t, h, "m4-op", "mini2", "verkyyi", true)
	waitFor(t, 3*time.Second, "three nodes", func() bool { return len(roster(t, h).Nodes) == 3 })

	enterAs(t, h, pYi, "verkyyi")
	me := meFor(t, h, pYi)
	if !me.Signed || me.Person != pYi || me.Principal == nil || me.Principal.ID != pYi ||
		me.Principal.Login != "verkyyi" || me.Principal.DisplayName != "verkyyi" {
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
	enterAs(t, h, pCao, "")
	p, err := h.srv.Store.Principal(pCao)
	if err != nil || p.Login != "24haowan" {
		t.Fatalf("caojian → %+v %v", p, err)
	}
	accts, _ := h.srv.Store.FleetAccounts(pCao)
	if len(accts) != 1 || accts[0].Hostname != "macmini" || accts[0].State != store.AccountActive {
		t.Fatalf("caojian's accounts = %+v, want 24haowan adopted on macmini only", accts)
	}
	// ...and only sees that machine's own login, never the operator's.
	_, body := asPerson(t, h, http.MethodGet, "/v1/nodes", pCao, nil)
	var snap NodesSnapshot
	json.Unmarshal(body, &snap)
	if len(snap.Nodes) != 1 || snap.Nodes[0].OSUser != "24haowan" || snap.Nodes[0].Hostname != "macmini" {
		t.Fatalf("caojian sees %+v", snap.Nodes)
	}

	// A machine that joins AFTER the sign-in is adopted at its hello.
	connectNode(t, h, "m6-op", "mini3", "verkyyi", true)
	waitState(t, h, pYi, "mini3", store.AccountActive)
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
	enablePeople(t, h)
	mapLogins(t, h.srv, map[string]string{pYi: "verkyyi"})
	connectNode(t, h, "m5-op", "macmini", "verkyyi", true)

	enterAs(t, h, pZhang, "zhangsan")
	me := meFor(t, h, pZhang)
	if !me.Signed || me.Person != pZhang || me.Principal != nil || len(me.Accounts) != 0 {
		t.Fatalf("/v1/fleet/me = %+v", me)
	}
	if ps, _ := h.srv.Store.Principals(); len(ps) != 0 {
		t.Fatalf("an unmapped sign-in minted %+v", ps)
	}
	_, body := asPerson(t, h, http.MethodGet, "/v1/nodes", pZhang, nil)
	var snap NodesSnapshot
	json.Unmarshal(body, &snap)
	if len(snap.Nodes) != 0 {
		t.Fatalf("zhangsan sees %+v", snap.Nodes)
	}
	// Nor another's machine, nor its role (claude-fleet#2795).
	if len(snap.Machines) != 0 {
		t.Fatalf("zhangsan sees machines %+v", snap.Machines)
	}
	if code, _ := asPerson(t, h, http.MethodGet, "/v1/fleet/accounts", pZhang, nil); code != http.StatusForbidden {
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

// Cleaning up a wrong identity: a principal with a create still queued for
// a node that never connected. `forget` drops the
// hub's record without sending anything; it refuses a row that reached a
// machine, so an active login cannot be forgotten into a ghost.
func TestFleetForgetDropsOnlyRowsThatNeverReachedAMachine(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice)
	h.srv.FleetAdmins = []string{"verkyyi"}

	// The bad data: a row minted for someone and a create queued on a
	// machine with no admin connected.
	if code := operatorPost(t, h, FleetAccountRequest{Action: "assign", PrincipalID: pZhang, Hostname: "mini2"}); code != 200 {
		t.Fatalf("assign: HTTP %d", code)
	}
	if a := accountState(t, h, pZhang, "mini2"); a.State != store.AccountPending {
		t.Fatalf("queued row = %+v", a)
	}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "forget", PrincipalID: pZhang}); code != 200 {
		t.Fatalf("forget: HTTP %d", code)
	}
	if _, err := h.srv.Store.Principal(pZhang); err == nil {
		t.Fatal("forget left the principal")
	}
	if as, _ := h.srv.Store.FleetAccounts(pZhang); len(as) != 0 {
		t.Fatalf("forget left %+v", as)
	}
	// Forgetting what is not there is a state error, not a success.
	if code := operatorPost(t, h, FleetAccountRequest{Action: "forget", PrincipalID: pZhang}); code != http.StatusBadRequest {
		t.Fatalf("forget of nobody: HTTP %d", code)
	}

	// An adopted (active) login refuses to be forgotten; `remove` is the
	// path that actually closes it. A pending row beside it can still go,
	// by hostname, leaving the active one.
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pAlice, Hostname: "macmini", Login: "alice"}); code != 200 {
		t.Fatalf("adopt: HTTP %d", code)
	}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "assign", PrincipalID: pAlice, Hostname: "mini2"}); code != 200 {
		t.Fatalf("assign: HTTP %d", code)
	}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "forget", PrincipalID: pAlice}); code != http.StatusConflict {
		t.Fatalf("forget with an active login: HTTP %d, want 409", code)
	}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "forget", PrincipalID: pAlice, Hostname: "mini2"}); code != 200 {
		t.Fatalf("forget pending row: HTTP %d", code)
	}
	as, _ := h.srv.Store.FleetAccounts(pAlice)
	if len(as) != 1 || as[0].Hostname != "macmini" || as[0].State != store.AccountActive {
		t.Fatalf("after forgetting mini2: %+v", as)
	}
	// A signed-in person can no more forget than assign.
	req, _ := json.Marshal(FleetAccountRequest{Action: "forget", PrincipalID: pAlice})
	if code, _ := asPerson(t, h, http.MethodPost, "/v1/fleet/accounts", pAlice, req); code != http.StatusForbidden {
		t.Fatalf("a person forgot an account: HTTP %d", code)
	}
}

// The map never changes a login the hub already minted for that person: a
// row from before the map (or from auto-assign) is reported, not overwritten.
func TestFleetMapRefusesToRenameAnExistingLogin(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	mapLogins(t, h.srv, map[string]string{pYi: "verkyyi"})
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pYi, Hostname: "mini2", Login: "yilianghui"}); code != 200 {
		t.Fatalf("adopt: HTTP %d", code)
	}
	connectNode(t, h, "m5-op", "macmini", "verkyyi", true)
	enterAs(t, h, pYi, "")
	p, _ := h.srv.Store.Principal(pYi)
	if p.Login != "yilianghui" {
		t.Fatalf("sign-in renamed the login: %+v", p)
	}
	if a := accountState(t, h, pYi, "macmini"); a.State != "" {
		t.Fatalf("a mismatched row was adopted onto macmini: %+v", a)
	}
}

// Nothing in this change touches a hub that sets no map: a sign-in with
// auto-assign still mints and queues as claude-fleet#1411 shipped it — under
// the GitHub username since claude-fleet#2069.
func TestFleetNoMapIsTheOldBehaviour(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	h.srv.FleetAdmins = []string{"verkyyi"}
	setHubSetting(t, h.srv, AutoAssignKey, "m4")
	admin := connectNode(t, h, "m4-op", "m4", "verkyyi", true)
	enterAs(t, h, pZhang, "张三")
	_, op := expectAccountOp(t, admin.tnode)
	if op.Op != control.AccountCreate || op.Login != "user3003" || op.FullName != "张三" {
		t.Fatalf("op = %+v", op)
	}
}

// asUID makes a request on uid's GitHub session cookie, carrying name — a
// browser that signed in earlier.
func asUID(t *testing.T, h *harness, method, path, uid, name string, body []byte) (int, []byte) {
	t.Helper()
	listPerson(t, h, uid, "")
	r, _ := http.NewRequest(method, h.http.URL+path, bytes.NewReader(body))
	r.AddCookie(personCookie(uid, name))
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b
}

// claude-fleet#1472: only the sign-in ran the placement, so a browser that
// signed in BEFORE the operator mapped them — its cookie still good — reached the `fleet login` confirmation, 连接 and the
// certificate with no row and was told "no active login on any machine yet".
// Each of those doors now places the person first; an unmapped person is
// still recorded nowhere by any of them.
func TestFleetCookieHolderIsPlacedAtTheDoorsThatNeedIt(t *testing.T) {
	h, _ := certHarness(t)
	h.srv.FleetAdmins = []string{"verkyyi"}
	mapLogins(t, h.srv, map[string]string{pYi: "verkyyi", pCao: "24haowan", pHuang: "vincent"})
	connectNode(t, h, "m5-op", "macmini", "verkyyi", true)
	connectNode(t, h, "m5-24h", "macmini", "24haowan", false)
	connectNode(t, h, "m5-v", "macmini", "vincent", false)
	waitFor(t, 3*time.Second, "three nodes", func() bool { return len(roster(t, h).Nodes) == 3 })
	for _, uid := range []string{pYi, pCao, pHuang} {
		if _, err := h.srv.Store.Principal(uid); !errors.Is(err, store.ErrNoPrincipal) {
			t.Fatalf("%s has a row before any door: %v", uid, err)
		}
	}

	// /fleet/login — the QR's page, opened by a browser already signed in.
	_, body := postJSON(t, h, "/v1/fleet/login/start", map[string]string{"public_key": newUserKey(t)})
	var st DeviceStart
	json.Unmarshal(body, &st)
	pc, raw := asUID(t, h, http.MethodGet, "/fleet/login?code="+st.UserCode, pYi, "易良辉", nil)
	page := html.UnescapeString(string(raw))
	if pc != 200 || strings.Contains(page, "issue yet") || !strings.Contains(page, ">Confirm</button>") || !strings.Contains(page, "verkyyi") {
		t.Fatalf("confirm page %d:\n%s", pc, page)
	}
	p, err := h.srv.Store.Principal(pYi)
	if err != nil || p.Login != "verkyyi" || p.DisplayName != "易良辉" {
		t.Fatalf("the page did not place them: %+v %v", p, err)
	}
	if a := accountState(t, h, pYi, "macmini"); a.State != store.AccountActive || a.Op != "adopt" {
		t.Fatalf("verkyyi on macmini = %+v", a)
	}
	pc, done := cookieForm(t, h, personCookie(pYi, "易良辉"), h.http.URL, url.Values{"code": {st.UserCode}, "action": {"approve"}})
	if pc != 200 || !strings.Contains(done, "valid until") {
		t.Fatalf("approve %d:\n%s", pc, done)
	}
	code, body := postJSON(t, h, "/v1/fleet/login/poll", map[string]string{"device_code": st.DeviceCode})
	var cr CertResponse
	json.Unmarshal(body, &cr)
	if code != 200 || strings.Join(cr.Principals, ",") != "verkyyi" || parseCert(t, cr.Certificate).KeyId != sshca.KeyIDPrefix+pYi {
		t.Fatalf("poll: %d %s", code, body)
	}

	// /connect and its data.
	h.srv.UI = fstest.MapFS{"connect.html": &fstest.MapFile{Data: []byte("<!doctype html><title>连接</title>")}}
	if code, b := asUID(t, h, http.MethodGet, "/connect", pCao, "曹健", nil); code != 200 || !strings.Contains(string(b), "连接") {
		t.Fatalf("/connect: %d %s", code, b)
	}
	if p, err := h.srv.Store.Principal(pCao); err != nil || p.Login != "24haowan" || p.DisplayName != "曹健" {
		t.Fatalf("/connect did not place them: %+v %v", p, err)
	}
	code, body = asUID(t, h, http.MethodGet, "/v1/fleet/connect", pCao, "", nil)
	var ci ConnectInfo
	json.Unmarshal(body, &ci)
	if code != 200 || !ci.Signed || ci.Login != "24haowan" || ci.Problem != "" || len(ci.Machines) != 1 || ci.Machines[0].Hostname != "macmini" {
		t.Fatalf("connect info %d %+v", code, ci)
	}

	// The paste-a-key door.
	req, _ := json.Marshal(map[string]string{"public_key": newUserKey(t)})
	code, body = asUID(t, h, http.MethodPost, "/v1/fleet/cert", pHuang, "黄永胜", req)
	cr = CertResponse{}
	json.Unmarshal(body, &cr)
	if code != 200 || strings.Join(cr.Principals, ",") != "vincent" {
		t.Fatalf("/v1/fleet/cert: %d %s", code, body)
	}

	// An unmapped person knocks on every door and is placed by none.
	_, body = postJSON(t, h, "/v1/fleet/login/start", map[string]string{"public_key": newUserKey(t)})
	json.Unmarshal(body, &st)
	if _, raw := asUID(t, h, http.MethodGet, "/fleet/login?code="+st.UserCode, pZhang, "张三", nil); !strings.Contains(string(raw), "issue yet") {
		t.Fatalf("zhangsan's confirm page:\n%s", raw)
	}
	if code, _ := asUID(t, h, http.MethodGet, "/connect", pZhang, "张三", nil); code != 200 {
		t.Fatalf("zhangsan /connect: %d", code)
	}
	code, body = asUID(t, h, http.MethodGet, "/v1/fleet/connect", pZhang, "张三", nil)
	ci = ConnectInfo{}
	json.Unmarshal(body, &ci)
	if code != 200 || ci.Login != "" || ci.Problem == "" || len(ci.Machines) != 0 {
		t.Fatalf("zhangsan's connect info %d %+v", code, ci)
	}
	if code, _ := asUID(t, h, http.MethodPost, "/v1/fleet/cert", pZhang, "张三", req); code != http.StatusConflict {
		t.Fatalf("zhangsan /v1/fleet/cert: %d, want 409", code)
	}
	if _, err := h.srv.Store.Principal(pZhang); !errors.Is(err, store.ErrNoPrincipal) {
		t.Fatalf("an unmapped person was placed: %v", err)
	}
	if ps, _ := h.srv.Store.Principals(); len(ps) != 4 { // Alice from the harness + three mapped people
		t.Fatalf("principals = %+v", ps)
	}
}
