package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// fleetNode is one test node: enrolled as (hostname, osUser), connected,
// welcomed and with one heartbeat in.
type fleetNode struct {
	*tnode
	token string
	id    string
}

// tnode is a test node's connection with a background reader: a read whose
// context expires closes a coder/websocket connection, so "nothing arrives"
// is asked of the channel, never of the socket.
type tnode struct {
	c  *websocket.Conn
	in chan control.Message
}

func connectNode(t *testing.T, h *harness, label, hostname, osUser string, admin bool) *fleetNode {
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
	n.tnode = dialAdmin(t, h, tok, admin)
	beat(t, n.c, control.Proto, control.Heartbeat{Hostname: hostname, OSUser: osUser})
	return n
}

func dialAdmin(t *testing.T, h *harness, tok string, admin bool) *tnode {
	t.Helper()
	return dialAdminCaps(t, h, tok, admin)
}

// dialAdminCaps is dialAdmin with the hello listing caps.
func dialAdminCaps(t *testing.T, h *harness, tok string, admin bool, caps ...string) *tnode {
	t.Helper()
	c := dialNode(t, h, tok)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	m, _ := control.New(control.TypeHello, control.Hello{HeartbeatMS: 5000, Admin: admin, Capabilities: caps})
	if err := wsjson.Write(ctx, c, m); err != nil {
		t.Fatal(err)
	}
	var reply control.Message
	if err := wsjson.Read(ctx, c, &reply); err != nil || reply.Type != control.TypeWelcome {
		t.Fatalf("hello: %v %+v", err, reply)
	}
	n := &tnode{c: c, in: make(chan control.Message, 16)}
	go func() {
		defer close(n.in)
		for {
			var m control.Message
			if err := wsjson.Read(context.Background(), c, &m); err != nil {
				return
			}
			n.in <- m
		}
	}()
	return n
}

// readMsg returns the next message, or ok=false when none comes in d.
func readMsg(n *tnode, d time.Duration) (control.Message, bool) {
	select {
	case m, ok := <-n.in:
		return m, ok
	case <-time.After(d):
		return control.Message{}, false
	}
}

// expectAccountOp waits for the next account op, skipping acks.
func expectAccountOp(t *testing.T, n *tnode) (control.Message, control.AccountOp) {
	t.Helper()
	m, ok := readMsg(n, 5*time.Second)
	for ok && m.Type == control.TypeAck {
		m, ok = readMsg(n, 5*time.Second)
	}
	if !ok || m.Type != control.TypeAccountOp {
		t.Fatalf("admin node got %+v (ok=%v), want an account_op", m, ok)
	}
	var op control.AccountOp
	if err := json.Unmarshal(m.Payload, &op); err != nil {
		t.Fatal(err)
	}
	return m, op
}

func sendResult(t *testing.T, c *websocket.Conn, opID string, res control.AccountResult) {
	t.Helper()
	m, _ := control.New(control.TypeAccountResult, res)
	m.OpID = opID
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := wsjson.Write(ctx, c, m); err != nil {
		t.Fatal(err)
	}
}

func accountState(t *testing.T, h *harness, principal, host string) store.FleetAccount {
	t.Helper()
	as, err := h.srv.Store.FleetAccounts(principal)
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range as {
		if a.Hostname == host {
			return a
		}
	}
	return store.FleetAccount{}
}

func waitState(t *testing.T, h *harness, principal, host, want string) store.FleetAccount {
	t.Helper()
	var a store.FleetAccount
	waitFor(t, 3*time.Second, principal+"@"+host+" to be "+want, func() bool {
		a = accountState(t, h, principal, host)
		return a.State == want
	})
	return a
}

// operatorPost changes accounts with the shared viewer token.
func operatorPost(t *testing.T, h *harness, req FleetAccountRequest) int {
	t.Helper()
	body, _ := json.Marshal(req)
	r, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/fleet/accounts", bytes.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)
	return resp.StatusCode
}

// asPerson makes a request with principal's GitHub session cookie.
func asPerson(t *testing.T, h *harness, method, path, principal string, body []byte) (int, []byte) {
	t.Helper()
	listPerson(t, h, principal, "")
	r, _ := http.NewRequest(method, h.http.URL+path, bytes.NewReader(body))
	r.AddCookie(personCookie(principal, ""))
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b
}

// Hub side of "only see your own": two people with a login each on m4; each
// one's roster shows their own login and never the other's, and neither can
// assign themselves anything.
func TestFleetPrincipalSeesOnlyOwnNodes(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice, pBob, pCarol)
	for _, p := range [][2]string{{pAlice, "alice"}, {pBob, "bob"}} {
		if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: p[0], Hostname: "m4", Login: p[1]}); code != 200 {
			t.Fatalf("adopt %s: HTTP %d", p[0], code)
		}
	}
	connectNode(t, h, "m4-alice", "m4", "alice", false)
	connectNode(t, h, "m4-bob", "m4", "bob", false)
	connectNode(t, h, "m4-op", "m4", "verkyyi", false)
	waitFor(t, 3*time.Second, "three nodes", func() bool { return len(roster(t, h).Nodes) == 3 })

	for sub, want := range map[string]string{pAlice: "alice", pBob: "bob"} {
		code, body := asPerson(t, h, http.MethodGet, "/v1/nodes", sub, nil)
		if code != 200 {
			t.Fatalf("%s /v1/nodes: HTTP %d", sub, code)
		}
		var snap NodesSnapshot
		json.Unmarshal(body, &snap)
		if len(snap.Nodes) != 1 || snap.Nodes[0].OSUser != want {
			t.Fatalf("%s sees %+v; want only %s's own node", sub, snap.Nodes, want)
		}
		if len(snap.Machines) != 1 || snap.Machines[0].Logins != 1 {
			t.Fatalf("%s's machine view counts other people's logins: %+v", sub, snap.Machines)
		}

		code, body = asPerson(t, h, http.MethodGet, "/v1/fleet/me", sub, nil)
		var me FleetMe
		json.Unmarshal(body, &me)
		if code != 200 || me.Principal == nil || me.Principal.Login != want || len(me.Accounts) != 1 {
			t.Fatalf("%s /v1/fleet/me = %d %s", sub, code, body)
		}

		req, _ := json.Marshal(FleetAccountRequest{Action: "adopt", PrincipalID: sub, Hostname: "m5", Login: want})
		if code, _ := asPerson(t, h, http.MethodPost, "/v1/fleet/accounts", sub, req); code != http.StatusForbidden {
			t.Fatalf("%s changed accounts with a GitHub session: HTTP %d, want 403", sub, code)
		}
		if code, _ := asPerson(t, h, http.MethodGet, "/v1/fleet/accounts", sub, nil); code != http.StatusForbidden {
			t.Fatalf("%s listed everyone's accounts: HTTP %d, want 403", sub, code)
		}
	}
	// A signed-in person with no account sees no node at all.
	_, body := asPerson(t, h, http.MethodGet, "/v1/nodes", pCarol, nil)
	var snap NodesSnapshot
	json.Unmarshal(body, &snap)
	if len(snap.Nodes) != 0 {
		t.Fatalf("a person with no account sees %+v", snap.Nodes)
	}
	// The operator still sees everything.
	if n := len(roster(t, h).Nodes); n != 3 {
		t.Fatalf("operator sees %d nodes, want 3", n)
	}
}

// An assignment goes to the machine's admin node only — never to another
// login on the same machine that merely claims to be one — with the fixed op,
// and its result makes the account active.
func TestFleetAssignGoesToAdminNodeOnly(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.FleetAdmins = []string{"verkyyi"}
	admin := connectNode(t, h, "m4-op", "m4", "verkyyi", true)
	impostor := connectNode(t, h, "m4-mallory", "m4", "mallory", true)
	other := connectNode(t, h, "m5-op", "m5", "verkyyi", true)

	if code := operatorPost(t, h, FleetAccountRequest{Action: "assign", PrincipalID: "WangXiaoMing", Hostname: "m4"}); code != 200 {
		t.Fatalf("assign: HTTP %d", code)
	}
	m, op := expectAccountOp(t, admin.tnode)
	if op.Op != control.AccountCreate || op.Login != "wangxiaoming" || op.FullName != "WangXiaoMing" || m.Proto != control.Proto {
		t.Fatalf("op = %+v", op)
	}
	for name, n := range map[string]*fleetNode{"impostor": impostor, "other machine": other} {
		if got, ok := readMsg(n.tnode, 300*time.Millisecond); ok {
			t.Fatalf("%s node received %+v", name, got)
		}
	}
	if a := accountState(t, h, "WangXiaoMing", "m4"); a.State != store.AccountCreating || a.OpID != m.OpID {
		t.Fatalf("after send: %+v", a)
	}

	// A result from a node that is not the admin is refused and changes nothing.
	sendResult(t, impostor.c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true})
	if r, ok := readMsg(impostor.tnode, 3*time.Second); !ok || r.Type != control.TypeError || r.Error.Code != control.CodeNotAdmin {
		t.Fatalf("impostor's result answered with %+v", r)
	}
	if a := accountState(t, h, "WangXiaoMing", "m4"); a.State != store.AccountCreating {
		t.Fatalf("impostor's result moved the account: %+v", a)
	}

	sendResult(t, admin.c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true})
	if ack, ok := readMsg(admin.tnode, 3*time.Second); !ok || ack.Type != control.TypeAck || ack.OpID != m.OpID {
		t.Fatalf("result answered with %+v", ack)
	}
	waitState(t, h, "WangXiaoMing", "m4", store.AccountActive)

	// The roster says which node is the admin.
	for _, n := range roster(t, h).Nodes {
		if want := n.OSUser == "verkyyi"; n.Admin != want {
			t.Fatalf("node %s@%s admin=%v, want %v", n.OSUser, n.Hostname, n.Admin, want)
		}
	}

	// Assigning again never re-runs a creation that worked.
	operatorPost(t, h, FleetAccountRequest{Action: "assign", PrincipalID: "WangXiaoMing", Hostname: "m4"})
	if got, ok := readMsg(admin.tnode, 300*time.Millisecond); ok {
		t.Fatalf("a second assign re-sent %+v", got)
	}

	// Removal is the other fixed op.
	if code := operatorPost(t, h, FleetAccountRequest{Action: "remove", PrincipalID: "WangXiaoMing", Hostname: "m4"}); code != 200 {
		t.Fatalf("remove: HTTP %d", code)
	}
	m, op = expectAccountOp(t, admin.tnode)
	if op.Op != control.AccountRemove || op.Login != "wangxiaoming" {
		t.Fatalf("remove op = %+v", op)
	}
	sendResult(t, admin.c, m.OpID, control.AccountResult{Op: control.AccountRemove, Login: op.Login, OK: true})
	waitState(t, h, "WangXiaoMing", "m4", store.AccountRemoved)
}

// The success criterion's path: a person's first GitHub sign-in queues their
// login on the auto-assigned machine and the admin node gets it at once. A link
// that drops mid-op leaves it unknown; when the node is back the hub asks it
// again under the SAME op_id (claude-fleet#2918 — the node answers from its
// book, never running it twice), and the node's answer settles it.
func TestFleetFirstSignInProvisionsAutoAssigned(t *testing.T) {
	h := newFleetHarness(t)
	const pZhang = "gh:2001" // their login is their GitHub username, user2001 (claude-fleet#2069)
	enablePeople(t, h, pZhang)
	h.srv.FleetAdmins = []string{"verkyyi"}
	setHubSetting(t, h.srv, AutoAssignKey, "m4")
	admin := connectNode(t, h, "m4-op", "m4", "verkyyi", true)

	// What the GitHub callback runs once the person is through.
	enter := func() { h.srv.onPrincipalSignIn(pZhang, "zhangsan") }
	enter()
	m, op := expectAccountOp(t, admin.tnode)
	if op.Op != control.AccountCreate || op.Login != "user2001" {
		t.Fatalf("op = %+v", op)
	}

	admin.c.Close(websocket.StatusGoingAway, "link lost")
	a := waitState(t, h, pZhang, "m4", store.AccountUnknown)
	if a.OpID != m.OpID {
		t.Fatalf("unknown row lost its op_id: %+v", a)
	}

	// Back: the hub asks again, once, under the same op_id...
	c := dialAdmin(t, h, admin.token, true)
	beat(t, c.c, control.Proto, control.Heartbeat{Hostname: "m4", OSUser: "verkyyi"})
	m2, op2 := expectAccountOp(t, c)
	if m2.OpID != m.OpID || op2.Op != control.AccountCreate || op2.Login != op.Login {
		t.Fatalf("asked again with %s %+v; want op %s, the same create", m2.OpID, op2, m.OpID)
	}
	beat(t, c.c, control.Proto, control.Heartbeat{Hostname: "m4", OSUser: "verkyyi"})
	if got, ok := readMsg(c, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("asked again on every beat: %+v", got)
	}
	// ...and the node's answer settles it.
	sendResult(t, c.c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true})
	waitState(t, h, pZhang, "m4", store.AccountActive)

	// A second sign-in queues nothing.
	enter()
	if got, ok := readMsg(c, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("a second sign-in re-provisioned: %+v", got)
	}
}

// An op unknown past accountUnknownGiveUp is failed, saying why — never
// unknown for good, the newcomer's 「正在为你开机器」 climbing with no end
// (claude-fleet#2918).
func TestFleetUnknownOpFailsAfterGiveUp(t *testing.T) {
	h := newFleetHarness(t)
	const pZhang = "gh:2001"
	enablePeople(t, h, pZhang)
	h.srv.FleetAdmins = []string{"verkyyi"}
	setHubSetting(t, h.srv, AutoAssignKey, "m4")
	admin := connectNode(t, h, "m4-op", "m4", "verkyyi", true)
	h.srv.onPrincipalSignIn(pZhang, "zhangsan")
	expectAccountOp(t, admin.tnode)
	a := waitState(t, h, pZhang, "m4", store.AccountCreating)
	if err := h.srv.Store.LoseAccountOps(a.EndpointID, time.Now().Add(-accountUnknownGiveUp-time.Minute)); err != nil {
		t.Fatal(err)
	}
	h.srv.dispatchAccounts()
	a = waitState(t, h, pZhang, "m4", store.AccountFailed)
	if !strings.Contains(a.Detail, "no answer from m4 in 30 min") || !strings.Contains(a.Detail, "control channel closed") {
		t.Fatalf("detail = %q; want why it failed", a.Detail)
	}
	if got, ok := readMsg(admin.tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("an op given up on was asked again: %+v", got)
	}
}

// An auto-assigned newcomer sees the login they hold a certificate for
// (claude-fleet#2096): with no admin mapping, their scope is the minted login,
// never noLogin — before, the cert said gh2001 and the list showed nothing.
func TestFleetAutoAssignedLoginIsTheirScope(t *testing.T) {
	h := newFleetHarness(t)
	const p = "gh:2001"
	enablePeople(t, h, p)
	h.srv.FleetAdmins = []string{"verkyyi"}
	setHubSetting(t, h.srv, AutoAssignKey, "m4")
	admin := connectNode(t, h, "m4-op", "m4", "verkyyi", true)
	if got, err := h.srv.machineLoginOf(p); err != nil || got != "" {
		t.Fatalf("before any sign-in: machineLoginOf = %q, %v; want \"\"", got, err)
	}
	h.srv.onPrincipalSignIn(p, "zhangsan")
	m, op := expectAccountOp(t, admin.tnode)
	sendResult(t, admin.c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true})
	waitState(t, h, p, "m4", store.AccountActive)
	_, certLogins, _, err := h.srv.fleetLoginsOf(p)
	if err != nil || len(certLogins) != 1 {
		t.Fatalf("fleetLoginsOf = %v, %v", certLogins, err)
	}
	if got, err := h.srv.machineLoginOf(p); err != nil || got != certLogins[0] {
		t.Fatalf("machineLoginOf = %q, %v; want the certificate's login %q", got, err, certLogins[0])
	}
	// An admin mapping still wins over the minted login.
	u, err := h.srv.Store.HubUserByID(2001)
	if err != nil || u == nil {
		t.Fatalf("HubUserByID: %v, %v", u, err)
	}
	u.MachineLogin = "zhang"
	if err := h.srv.Store.UpsertHubUser(*u); err != nil {
		t.Fatal(err)
	}
	if got, _ := h.srv.machineLoginOf(p); got != "zhang" {
		t.Fatalf("with a mapping: machineLoginOf = %q; want zhang", got)
	}
}

// "Already exists" is never success: the name may be someone else's login.
// The operator retries or adopts.
func TestFleetExistingLoginIsFailedNotActive(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.FleetAdmins = []string{"verkyyi"}
	admin := connectNode(t, h, "m4-op", "m4", "verkyyi", true)
	operatorPost(t, h, FleetAccountRequest{Action: "assign", PrincipalID: "lisi", Hostname: "m4"})
	m, op := expectAccountOp(t, admin.tnode)
	sendResult(t, admin.c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, Exit: 3, Exists: true})
	waitState(t, h, "lisi", "m4", store.AccountFailed)

	if code := operatorPost(t, h, FleetAccountRequest{Action: "retry", PrincipalID: "lisi", Hostname: "m4"}); code != 200 {
		t.Fatalf("retry: HTTP %d", code)
	}
	m2, _ := expectAccountOp(t, admin.tnode)
	if m2.OpID == m.OpID {
		t.Fatal("a retry reused the old op_id")
	}
}

// A node that refuses an op (not an admin on its own side) fails it.
func TestFleetNodeRefusalFailsTheOp(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.FleetAdmins = []string{"verkyyi"}
	admin := connectNode(t, h, "m4-op", "m4", "verkyyi", true)
	operatorPost(t, h, FleetAccountRequest{Action: "assign", PrincipalID: "lisi", Hostname: "m4"})
	m, _ := expectAccountOp(t, admin.tnode)
	refusal := control.Message{Type: control.TypeError, OpID: m.OpID, Proto: control.Proto,
		Error: &control.Error{Code: control.CodeNotAdmin, Message: "not started as admin"}}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	wsjson.Write(ctx, admin.c, refusal)
	a := waitState(t, h, "lisi", "m4", store.AccountFailed)
	if a.Detail == "" {
		t.Fatal("a refusal left no reason")
	}
}

// Off, none of it exists.
func TestFleetAccountsOffAddsNothing(t *testing.T) {
	h := newHarness(t)
	if _, err := h.srv.Store.Principals(); err == nil {
		t.Fatal("fleet_principals exists although the fleet module is off")
	}
}

func TestLoginBase(t *testing.T) {
	for in, want := range map[string]string{
		"ZhangSan":                "zhangsan",
		"zhang.san-01":            "zhangsan01",
		"007":                     "u007",
		"张三":                      "u0",
		"averyveryverylonguserid": "averyveryverylon",
	} {
		if got := store.LoginBase(in, control.MaxLoginLen); got != want || !control.ValidLogin(got) {
			t.Errorf("LoginBase(%q) = %q (valid=%v), want %q", in, got, control.ValidLogin(got), want)
		}
	}
}

// Two people whose userids reduce to the same stem get distinct logins.
func TestPrincipalLoginsAreUnique(t *testing.T) {
	h := newFleetHarness(t)
	now := time.Now()
	a, err := h.srv.Store.EnsurePrincipal("Zhang.San", "", control.MaxLoginLen, control.ValidLogin, now)
	if err != nil {
		t.Fatal(err)
	}
	b, err := h.srv.Store.EnsurePrincipal("zhangsan", "", control.MaxLoginLen, control.ValidLogin, now)
	if err != nil {
		t.Fatal(err)
	}
	again, _ := h.srv.Store.EnsurePrincipal("Zhang.San", "", control.MaxLoginLen, control.ValidLogin, now)
	if a.Login != "zhangsan" || b.Login != "zhangsan2" || again.Login != a.Login {
		t.Fatalf("logins %q %q %q", a.Login, b.Login, again.Login)
	}
	// A reserved name is skipped like a taken one.
	r, err := h.srv.Store.EnsurePrincipal("root", "", control.MaxLoginLen, control.ValidLogin, now)
	if err != nil || r.Login != "root2" {
		t.Fatalf("root -> %+v %v", r, err)
	}
}

// An adopted digit-leading login (`24haowan`) can be opened on a second machine:
// assign queues it marked existing, and the node gets the same login. With no
// active copy elsewhere the assign is a 400 on the spot and leaves no row
// (claude-fleet#2105).
func TestFleetAssignExistingDigitLogin(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.FleetAdmins = []string{"verkyyi"}
	m5 := connectNode(t, h, "m5-op", "m5", "verkyyi", true)
	const pCao = "gh:2987262"

	// Adopted nowhere yet: nothing to copy.
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pCao, Hostname: "m4", Login: "24haowan"}); code != 200 {
		t.Fatalf("adopt: HTTP %d", code)
	}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "remove", PrincipalID: pCao, Hostname: "m4"}); code != 200 {
		t.Fatalf("remove: HTTP %d", code)
	}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "assign", PrincipalID: pCao, Hostname: "m5"}); code != http.StatusBadRequest {
		t.Fatalf("assign with no active copy: HTTP %d, want 400", code)
	}
	if as, _ := h.srv.Store.FleetAccounts(pCao); len(as) != 1 || as[0].Hostname != "m4" {
		t.Fatalf("a refused assign left rows: %+v", as)
	}
	if got, ok := readMsg(m5.tnode, 300*time.Millisecond); ok {
		t.Fatalf("a refused assign sent %+v", got)
	}

	// Active on m4: m5 gets a create of the same login, marked existing.
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pCao, Hostname: "m4", Login: "24haowan"}); code != 200 {
		t.Fatalf("re-adopt: HTTP %d", code)
	}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "assign", PrincipalID: pCao, Hostname: "m5"}); code != 200 {
		t.Fatalf("assign: HTTP %d", code)
	}
	m, op := expectAccountOp(t, m5.tnode)
	if op.Op != control.AccountCreate || op.Login != "24haowan" || !op.Existing {
		t.Fatalf("op = %+v; want create 24haowan existing", op)
	}
	sendResult(t, m5.c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true})
	waitState(t, h, pCao, "m5", store.AccountActive)
}

// A minted login is never marked existing.
func TestFleetAssignMintedLoginNotExisting(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.FleetAdmins = []string{"verkyyi"}
	admin := connectNode(t, h, "m4-op", "m4", "verkyyi", true)
	operatorPost(t, h, FleetAccountRequest{Action: "assign", PrincipalID: "lisi", Hostname: "m4"})
	if _, op := expectAccountOp(t, admin.tnode); op.Existing {
		t.Fatalf("minted login marked existing: %+v", op)
	}
}

// claude-fleet#2210: the operator's own login on a machine is the admin one
// (verkyyi, passwordless sudo). relogin moves their row there to a fresh
// standard login and queues its create on the admin node — never a remove of
// the old one — and adopt of the old login undoes it without running anything.
func TestFleetReloginCreatesNewLeavesOld(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.FleetAdmins = []string{"verkyyi"}
	admin := connectNode(t, h, "m5-op", "m5", "verkyyi", true)
	const pid = "gh:2718137"
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pid, Hostname: "m5", Login: "verkyyi"}); code != 200 {
		t.Fatalf("adopt: HTTP %d", code)
	}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pid, Hostname: "m4", Login: "verkyyi"}); code != 200 {
		t.Fatalf("adopt m4: HTTP %d", code)
	}

	// Refused: an admin login, an invalid name, the same name, a machine with no row.
	for name, req := range map[string]FleetAccountRequest{
		"admin login": {Action: "relogin", PrincipalID: pid, Hostname: "m5", Login: "verkyyi"},
		"bad name":    {Action: "relogin", PrincipalID: pid, Hostname: "m5", Login: "9dev"},
		"reserved":    {Action: "relogin", PrincipalID: pid, Hostname: "m5", Login: "admin"},
		"no row":      {Action: "relogin", PrincipalID: pid, Hostname: "m9", Login: "verkydev"},
		"no host":     {Action: "relogin", PrincipalID: pid, Login: "verkydev"},
	} {
		if code := operatorPost(t, h, req); code == 200 {
			t.Fatalf("%s: relogin accepted", name)
		}
	}
	if got, ok := readMsg(admin.tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("a refused relogin sent %+v", got)
	}

	if code := operatorPost(t, h, FleetAccountRequest{Action: "relogin", PrincipalID: pid, Hostname: "m5", Login: "verkydev"}); code != 200 {
		t.Fatalf("relogin: HTTP %d", code)
	}
	m, op := expectAccountOp(t, admin.tnode)
	if op.Op != control.AccountCreate || op.Login != "verkydev" {
		t.Fatalf("relogin op = %+v", op)
	}
	// While in flight a second relogin refuses.
	if code := operatorPost(t, h, FleetAccountRequest{Action: "relogin", PrincipalID: pid, Hostname: "m5", Login: "verkyabc"}); code != http.StatusConflict {
		t.Fatalf("relogin in flight: HTTP %d, want 409", code)
	}
	sendResult(t, admin.c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true})
	a := waitState(t, h, pid, "m5", store.AccountActive)
	if a.Login != "verkydev" {
		t.Fatalf("after relogin m5 = %+v", a)
	}
	// The other machine and the person's record are untouched.
	if b := accountState(t, h, pid, "m4"); b.Login != "verkyyi" || b.State != store.AccountActive {
		t.Fatalf("m4 moved: %+v", b)
	}
	if p, err := h.srv.Store.Principal(pid); err != nil || p.Login != "verkyyi" {
		t.Fatalf("principal = %+v, %v", p, err)
	}
	if got, ok := readMsg(admin.tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("relogin sent a second op %+v", got)
	}

	// A relogin whose create failed late (claude-fleet#2210: the admin then
	// finished it by hand) is settled by adopting the row's own new login;
	// a name the row does not carry refuses.
	if code := operatorPost(t, h, FleetAccountRequest{Action: "relogin", PrincipalID: pid, Hostname: "m4", Login: "verky"}); code != 200 {
		t.Fatalf("relogin m4: HTTP %d", code)
	}
	m4 := connectNode(t, h, "m4-op", "m4", "verkyyi", true)
	m, op = expectAccountOp(t, m4.tnode)
	sendResult(t, m4.c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: false, Exit: 1, Detail: "FAILED at step 7b"})
	waitState(t, h, pid, "m4", store.AccountFailed)
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pid, Hostname: "m4", Login: "verkyx"}); code == 200 {
		t.Fatalf("adopt of a login the row does not carry accepted")
	}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pid, Hostname: "m4", Login: "verky"}); code != 200 {
		t.Fatalf("adopt the relogin: HTTP %d", code)
	}
	if b := accountState(t, h, pid, "m4"); b.Login != "verky" || b.State != store.AccountActive {
		t.Fatalf("after adopting the relogin m4 = %+v", b)
	}
	if p, err := h.srv.Store.Principal(pid); err != nil || p.Login != "verkyyi" {
		t.Fatalf("principal moved: %+v, %v", p, err)
	}

	// Undo: adopt the old login back, nothing run.
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pid, Hostname: "m5", Login: "verkyyi"}); code != 200 {
		t.Fatalf("undo adopt: HTTP %d", code)
	}
	if a := accountState(t, h, pid, "m5"); a.Login != "verkyyi" || a.State != store.AccountActive {
		t.Fatalf("after undo m5 = %+v", a)
	}
	if got, ok := readMsg(admin.tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("undo sent %+v", got)
	}
}
