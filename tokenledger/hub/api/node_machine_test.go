package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

// One node program per machine (claude-fleet#2333, EPIC #2329 C5): one
// websocket carries every login of the machine, each still its own endpoint.

// machNode is a test machine link: one websocket, the messages it receives
// split by login. Writes are answered "accepted" and recorded per login, as
// writeNode does for a plain link.
type machNode struct {
	t  *testing.T
	c  *websocket.Conn
	mu sync.Mutex
	in map[string]chan control.Message
	// writes is every TypeWrite envelope received, by login.
	writes map[string][]map[string]any
}

// identify gives an enrolled endpoint the machine and login it reports, as a
// usage push would.
func identify(t *testing.T, h *harness, label, hostname, osUser string) {
	t.Helper()
	ident := model.Identity{AccountUUID: "acct-" + label, Hostname: hostname, OSUser: osUser}
	if err := h.srv.Store.UpsertAccount(ident, "max", ""); err != nil {
		t.Fatal(err)
	}
	if _, _, err := h.srv.Store.TouchEndpoint("ep_"+label, ident, "test", true, nil); err != nil {
		t.Fatal(err)
	}
}

func dialMachine(t *testing.T, h *harness, token string, caps ...string) *machNode {
	t.Helper()
	c := dialNode(t, h, token)
	off := false
	m, _ := control.New(control.TypeHello, control.Hello{HeartbeatMS: 60000, AgentVersion: "test",
		Capabilities: append([]string{control.CapMachine}, caps...), Compute: &off})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := wsjson.Write(ctx, c, m); err != nil {
		t.Fatal(err)
	}
	var reply control.Message
	if err := wsjson.Read(ctx, c, &reply); err != nil || reply.Type != control.TypeWelcome {
		t.Fatalf("machine hello: %v %+v", err, reply)
	}
	n := &machNode{t: t, c: c, in: map[string]chan control.Message{}, writes: map[string][]map[string]any{}}
	go n.serve()
	return n
}

func (n *machNode) inbox(login string) chan control.Message {
	n.mu.Lock()
	defer n.mu.Unlock()
	ch := n.in[login]
	if ch == nil {
		ch = make(chan control.Message, 64)
		n.in[login] = ch
	}
	return ch
}

func (n *machNode) serve() {
	for {
		var m control.Message
		if err := wsjson.Read(context.Background(), n.c, &m); err != nil {
			return
		}
		if m.Type == control.TypeWrite {
			var req control.Request
			_ = json.Unmarshal(m.Payload, &req)
			var env map[string]any
			_ = json.Unmarshal(req.Params, &env)
			n.mu.Lock()
			n.writes[m.Login] = append(n.writes[m.Login], env)
			n.mu.Unlock()
			raw, _ := json.Marshal(map[string]any{"operation_id": env["operation_id"], "fleet_id": env["fleet_id"],
				"action": env["action"], "status": "accepted", "result": nil})
			out, _ := control.New(control.TypeResult, control.Result{Result: raw})
			out.OpID, out.Login = m.OpID, m.Login
			_ = wsjson.Write(context.Background(), n.c, out)
			continue
		}
		n.inbox(m.Login) <- m
	}
}

func (n *machNode) count(login string) int {
	n.mu.Lock()
	defer n.mu.Unlock()
	return len(n.writes[login])
}

func (n *machNode) send(login string, m control.Message) {
	n.t.Helper()
	m.Login = login
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := wsjson.Write(ctx, n.c, m); err != nil {
		n.t.Fatal(err)
	}
}

// login says one login's hello on the link and returns the hub's answer.
func (n *machNode) login(login, token string, admin bool, caps ...string) control.Message {
	n.t.Helper()
	if admin {
		caps = append(caps, control.CapLoginJoin) // a current admin (claude-fleet#3032)
	}
	m, _ := control.New(control.TypeHello, control.Hello{HeartbeatMS: 60000, AgentVersion: "test",
		Admin: admin, Capabilities: caps, LoginToken: token})
	n.send(login, m)
	r, ok := readMsg(&tnode{in: n.inbox(login)}, 5*time.Second)
	if !ok {
		n.t.Fatalf("no answer to %s's hello", login)
	}
	return r
}

func (n *machNode) beat(login string, hb control.Heartbeat) {
	n.t.Helper()
	m, _ := control.New(control.TypeHeartbeat, hb)
	n.send(login, m)
}

// machineRig is mac-c as one machine link carrying alpha and beta, every
// endpoint identified as mac-c's. admins are the hub's admin logins (default
// alpha); an admin's hello says so.
func machineRig(t *testing.T, admins ...string) (*harness, *machNode) {
	t.Helper()
	h := newFleetHarness(t)
	if len(admins) == 0 {
		admins = []string{"alpha"}
	}
	h.srv.FleetAdmins = admins
	h.enroll(t, "mach")
	for _, l := range []string{"alpha", "beta"} {
		h.enroll(t, l)
		identify(t, h, l, "mac-c", l)
	}
	n := dialMachine(t, h, h.tokens["mach"])
	n.beat("", control.Heartbeat{Hostname: "mac-c", OSUser: "root", NCPU: 10, ObservedAt: time.Now()})
	// The beat is recorded off the link's reader: a login hello read before it
	// found the machine's host unknown and skipped the other-machine check
	// (claude-fleet#4679 — "dave with belongs to mac-d: answered welcome").
	waitFor(t, 3*time.Second, "the machine's host recorded", func() bool {
		ep, err := h.srv.Store.EndpointByID("ep_mach")
		return err == nil && h.srv.endpointHost(*ep) == "mac-c"
	})
	for _, l := range []string{"alpha", "beta"} {
		if r := n.login(l, h.tokens[l], hasString(admins, l), control.CapRead, control.CapWrite, control.CapMove); r.Type != control.TypeWelcome || r.Login != l {
			t.Fatalf("%s's hello answered %+v", l, r)
		}
	}
	return h, n
}

// The issue's 怎么算成功: one connection for the machine, its logins listed
// under it — each still an endpoint of its own.
func TestMachineLinkCarriesEveryLogin(t *testing.T) {
	h, n := machineRig(t)
	n.beat("alpha", control.Heartbeat{Hostname: "mac-c", OSUser: "alpha", NCPU: 10, ObservedAt: time.Now()})
	n.beat("beta", control.Heartbeat{Hostname: "mac-c", OSUser: "beta", NCPU: 10, ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, "both logins online", func() bool {
		on := 0
		for _, v := range roster(t, h).Nodes {
			if v.Status == "online" && (v.OSUser == "alpha" || v.OSUser == "beta") {
				on++
			}
		}
		return on == 2
	})
	snap := roster(t, h)
	for _, v := range snap.Nodes {
		switch v.EndpointID {
		case "ep_mach":
			if !v.MachineLink || v.Via != "" {
				t.Fatalf("machine row = %+v; want machine_link, no via", v)
			}
		case "ep_alpha", "ep_beta":
			if v.Via != "ep_mach" || v.MachineLink || !v.Connected {
				t.Fatalf("login row = %+v; want connected via ep_mach", v)
			}
		}
	}
	if len(snap.Machines) != 1 {
		t.Fatalf("machines = %+v; want mac-c alone", snap.Machines)
	}
	if m := snap.Machines[0]; m.Hostname != "mac-c" || m.Links != 1 || m.Logins != 2 || m.Online != 2 {
		t.Fatalf("mac-c = links %d logins %d online %d; want 1 link carrying 2 logins", m.Links, m.Logins, m.Online)
	}
	// The link itself is never somewhere to run sessions.
	hb, _, _ := h.srv.nodeStatusOf("ep_mach", time.Now())
	if cv := h.srv.computeOf("ep_mach", hb, nil, time.Now()); !cv.Off {
		t.Fatalf("the machine link reads compute on: %+v", cv)
	}

	// A login that says its hello again (its half restarted) gets a new lane
	// in place of the old one — and no LINK_CLOSED, which the node would
	// apply to the NEW lane and loop forever.
	old := h.srv.nodes.get("ep_alpha")
	if r := n.login("alpha", h.tokens["alpha"], true, control.CapRead, control.CapWrite); r.Type != control.TypeWelcome {
		t.Fatalf("alpha's second hello: %+v", r)
	}
	waitFor(t, 3*time.Second, "alpha on its new lane", func() bool {
		c := h.srv.nodes.get("ep_alpha")
		return c != nil && c != old && c.wire.machine() == "ep_mach"
	})
	if r, ok := readMsg(&tnode{in: n.inbox("alpha")}, 300*time.Millisecond); ok && r.Type == control.TypeError {
		t.Fatalf("a re-hello was answered %+v", r)
	}
}

// 会话: a session started on beta's fleet is written to beta — on the shared
// link, stamped beta — and nothing reaches alpha.
func TestMachineLinkSessionLandsOnItsLogin(t *testing.T) {
	// The operator's own starts land on the operator's logins: both, here.
	h, n := machineRig(t, "alpha", "beta")
	fa := fakeFleet(t, machineA, "fleet-alpha", "ivan/other", "/u/alpha/other", 1)
	fb := fakeFleet(t, machineB, "fleet-beta", writeRepo, "/u/beta/claude-fleet", 1)
	n.beat("alpha", control.Heartbeat{Hostname: "mac-c", OSUser: "alpha", MachineID: machineA, NCPU: 10,
		MemFreeBytes: 8 << 30, MemTotalBytes: 16 << 30, Fleets: []control.Fleet{fa}, ObservedAt: time.Now()})
	n.beat("beta", control.Heartbeat{Hostname: "mac-c", OSUser: "beta", MachineID: machineB, NCPU: 10,
		MemFreeBytes: 8 << 30, MemTotalBytes: 16 << 30, Fleets: []control.Fleet{fb}, ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, "both fleets registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	op := postFleet(t, h, "worker_start", map[string]any{"issue": 7, "repo": writeRepo, "idempotency_key": "m-7"}, 200)
	if op["fleet_id"] != fb.FleetID || op["status"] != "accepted" {
		t.Fatalf("worker_start = %v; want accepted on beta's fleet", op)
	}
	if n.count("beta") != 1 || n.count("alpha") != 0 || n.count("") != 0 {
		t.Fatalf("writes: beta=%d alpha=%d machine=%d; want 1 0 0", n.count("beta"), n.count("alpha"), n.count(""))
	}
	if env := n.writes["beta"][0]; env["action"] != "worker_start" || env["fleet_id"] != fb.FleetID {
		t.Fatalf("beta was sent %v", env)
	}
}

// 开号: an account op goes to the machine's admin login — alpha, on the link —
// never beta, and alpha's result on the link makes the account active.
func TestMachineLinkAccountCreateGoesToTheAdminLogin(t *testing.T) {
	h, n := machineRig(t)
	if code := operatorPost(t, h, FleetAccountRequest{Action: "assign", PrincipalID: "WangXiaoMing", Hostname: "mac-c"}); code != 200 {
		t.Fatalf("assign: HTTP %d", code)
	}
	m, op := expectAccountOp(t, &tnode{in: n.inbox("alpha")})
	if op.Op != control.AccountCreate || op.Login != "wangxiaoming" || m.Login != "alpha" {
		t.Fatalf("op = %+v on %q; want a create for wangxiaoming on alpha", op, m.Login)
	}
	if got, ok := readMsg(&tnode{in: n.inbox("beta")}, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("beta received %+v", got)
	}
	res, _ := control.New(control.TypeAccountResult, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true})
	res.OpID = m.OpID
	n.send("alpha", res)
	waitState(t, h, "WangXiaoMing", "mac-c", store.AccountActive)

	// beta answering alpha's op is refused as not the admin.
	res.OpID = "another"
	n.send("beta", res)
	for {
		r, ok := readMsg(&tnode{in: n.inbox("beta")}, 3*time.Second)
		if !ok {
			t.Fatal("beta's stray result was not refused")
		}
		if r.Type == control.TypeError && r.Error != nil && r.Error.Code == control.CodeNotAdmin {
			break
		}
	}
}

// 迁移: a session moved from mac-d to mac-c is written to the mac-c login that hosts
// the fleet — on its lane, stamped with its login.
func TestMachineLinkMoveLandsOnItsLogin(t *testing.T) {
	h := newFleetHarness(t)
	macD := connectWriteNodeCaps(t, h, h.enroll(t, "mac-d"), control.CapRead, control.CapWrite, control.CapMove)
	h.enroll(t, "mach")
	for _, l := range []string{"alpha", "frank"} {
		h.enroll(t, l)
		identify(t, h, l, "mac-c", l)
	}
	n := dialMachine(t, h, h.tokens["mach"])
	n.beat("", control.Heartbeat{Hostname: "mac-c", OSUser: "root", ObservedAt: time.Now()})
	for _, l := range []string{"alpha", "frank"} {
		if r := n.login(l, h.tokens[l], false, control.CapRead, control.CapWrite, control.CapMove); r.Type != control.TypeWelcome {
			t.Fatalf("%s: %+v", l, r)
		}
	}
	f5 := fakeFleet(t, machineA, "fleet-mac-d", writeRepo, "/u/frank/claude-fleet", 1)
	f4 := fakeFleet(t, machineB, "fleet-mac-c", writeRepo, "/u/frank/claude-fleet", 2)
	macD.beatLoad("mac-d", "frank", machineA, 10, 3, f5)
	n.beat("frank", control.Heartbeat{Hostname: "mac-c", OSUser: "frank", MachineID: machineB, Load1: 1, NCPU: 10,
		MemFreeBytes: 8 << 30, MemTotalBytes: 16 << 30, Sessions: 1, Fleets: []control.Fleet{f4}, ObservedAt: time.Now()})
	n.beat("alpha", control.Heartbeat{Hostname: "mac-c", OSUser: "alpha", NCPU: 10, ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, "both fleets registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	tok5 := h.tokens["mac-d"]
	wid5, wid4 := issueWID(f5.FleetID, 7), issueWID(f4.FleetID, 7)
	if st, out := leaseCall(t, h, tok5, map[string]any{"action": "acquire", "repo": writeRepo, "issue": 7, "worker_id": wid5}); st != 200 {
		t.Fatalf("mac-d's lease: %d %v", st, out)
	}
	bundle := uploadBundle(t, h, tok5, []byte("bundle"))
	st, out := moveCall(t, h, tok5, moveBody(wid5, bundle, "done"))
	if st != 200 || out["to_wid"] != wid4 {
		t.Fatalf("move = %d %v; want it sent to mac-c's frank as %s", st, out, wid4)
	}
	if n.count("frank") != 1 || n.count("alpha") != 0 || macD.count() != 0 {
		t.Fatalf("writes: frank=%d alpha=%d mac-d=%d; want 1 0 0", n.count("frank"), n.count("alpha"), macD.count())
	}
	if env := n.writes["frank"][0]; env["action"] != "worker_move_in" || env["fleet_id"] != f4.FleetID {
		t.Fatalf("frank was sent %v", env)
	}
	// Only the login the move is for may fetch its transcript.
	if st, _ := downloadBundle(t, h, h.tokens["alpha"], bundle); st != 404 {
		t.Fatalf("alpha fetched frank's bundle: %d", st)
	}
	if st, _ := downloadBundle(t, h, h.tokens["frank"], bundle); st != 200 {
		t.Fatalf("frank's download = %d", st)
	}
}

// BREAK-IT machine-agent-wrong-login: a login hello proven with another
// login's token, the machine's own token, or a token from another machine is
// refused WRONG_LOGIN — the login never comes online on this link — and a
// message for a login the link does not carry is refused, never routed.
func TestMachineLinkRefusesWrongLogin(t *testing.T) {
	h, n := machineRig(t)
	h.enroll(t, "carol")
	identify(t, h, "carol", "mac-c", "carol")
	h.enroll(t, "dave")
	identify(t, h, "dave", "mac-d", "dave")

	for _, c := range []struct{ login, token, why string }{
		{"carol", h.tokens["alpha"], "alpha's"},
		{"carol", h.tokens["mach"], "machine's token"},
		{"dave", h.tokens["dave"], "belongs to mac-d"},
		{"carol", "not-a-token", "unrecognised"},
		{"carol", "", "own node token"},
	} {
		r := n.login(c.login, c.token, false, control.CapRead, control.CapWrite)
		if r.Type != control.TypeError || r.Error == nil || r.Error.Code != control.CodeWrongLogin || r.Login != c.login ||
			!strings.Contains(r.Error.Message, c.why) {
			t.Fatalf("%s with %s: answered %+v; want WRONG_LOGIN naming %q", c.login, c.why, r, c.why)
		}
	}
	for _, v := range roster(t, h).Nodes {
		if (v.EndpointID == "ep_carol" || v.EndpointID == "ep_dave") && v.Connected {
			t.Fatalf("%s came online on a refused hello", v.EndpointID)
		}
	}
	if c := h.srv.nodes.get("ep_alpha"); c == nil || c.wire.machine() != "ep_mach" {
		t.Fatal("alpha's lane was disturbed by a refused hello")
	}
	// A message for a login with no lane on this link is refused.
	stray, _ := control.New(control.TypeResult, control.Result{})
	n.send("carol", stray)
	if r, ok := readMsg(&tnode{in: n.inbox("carol")}, 3*time.Second); !ok || r.Type != control.TypeError || r.Error.Code != control.CodeWrongLogin {
		t.Fatalf("a message for an unserved login answered %+v (ok=%v)", r, ok)
	}
	// The refusals are audited.
	rows, err := h.srv.Store.FleetAuditLog(50)
	if err != nil {
		t.Fatal(err)
	}
	refused := 0
	for _, a := range rows {
		if a.Action == "machine_login" && strings.HasPrefix(a.Outcome, "REFUSED") {
			refused++
		}
	}
	if refused < 4 {
		t.Fatalf("%d machine_login refusals audited; want one per refused hello", refused)
	}
}

// claude-fleet#2433: a login on a machine link is judged on compute exactly as
// its own link would be — its beat's explicit off plus a fresh ok probe stays
// 只协调 while fleet.compute_auto is off and opens by policy when it is on; a
// login with no probe stays off either way. The link itself never runs.
func TestMachineLinkLoginComputeFollowsItsProbe(t *testing.T) {
	h, n := machineRig(t)
	now := time.Now()
	off := false
	probe := &control.NodeProbe{Loc: "US", Anthropic: "reachable", OpenAI: "reachable", TS: now.Add(-23 * time.Hour), Verdict: control.ProbeOK}
	n.beat("alpha", control.Heartbeat{Hostname: "mac-c", OSUser: "alpha", NCPU: 10, ObservedAt: now, Compute: &off, Probe: probe})
	n.beat("beta", control.Heartbeat{Hostname: "mac-c", OSUser: "beta", NCPU: 10, ObservedAt: now, Compute: &off})
	waitFor(t, 3*time.Second, "alpha's beat with its probe recorded", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_alpha", time.Now())
		hb2, _, _ := h.srv.nodeStatusOf("ep_beta", time.Now())
		return hb.Probe != nil && hb.Compute != nil && hb2.Compute != nil
	})
	verdict := func(ep string, settings map[string]string) computeVerdict {
		hb, _, _ := h.srv.nodeStatusOf(ep, time.Now())
		return h.srv.computeOf(ep, hb, settings, time.Now())
	}
	if cv := verdict("ep_alpha", nil); !cv.Off || cv.Why != excludedComputeOff || cv.Probe == nil || cv.Probe.Verdict != control.ProbeOK {
		t.Fatalf("alpha, compute_auto off: %+v; want 只协调 with its ok probe carried", cv)
	}
	auto := map[string]string{ComputeAutoKey: "on"}
	if cv := verdict("ep_alpha", auto); cv.Off || !cv.Auto {
		t.Fatalf("alpha, compute_auto on: %+v; want opened by policy", cv)
	}
	if cv := verdict("ep_beta", auto); !cv.Off || cv.Why != excludedComputeOff {
		t.Fatalf("beta (no probe), compute_auto on: %+v; want 只协调", cv)
	}
	if cv := verdict("ep_mach", auto); !cv.Off {
		t.Fatalf("the machine link with compute_auto on: %+v; want never a place to run", cv)
	}
	// The same beat on alpha's own websocket would be judged the same.
	want := decideCompute(false, false, probe, true, time.Now())
	if got := verdict("ep_alpha", auto); got.Off != want.Off || got.Auto != want.Auto || got.Why != want.Why {
		t.Fatalf("machine-link verdict %+v != plain-link rule %+v", got, want)
	}
	// And the roster says it the way placement reads it.
	if err := h.srv.Store.SetFleetSetting(ComputeAutoKey, "on", time.Now()); err != nil {
		t.Fatal(err)
	}
	for _, v := range roster(t, h).Nodes {
		if v.EndpointID == "ep_alpha" && (v.ComputeOff || !v.ComputeAuto || v.Probe == nil) {
			t.Fatalf("alpha's roster row = %+v; want compute_auto, probe carried", v)
		}
	}
}

// A login its machine's node program serves re-registers (claude-fleet#2501):
// the hub does not hand out a token that would cut the machine's lane off;
// a reissue that happened anyway leaves the old token a grace, and past it the
// lane's refusal names the reissue and the fix.
func TestReissueKeepsTheMachineLane(t *testing.T) {
	h, n := machineRig(t)
	const fp = "SHA256:beta-device"
	code, _ := MintJoinCode()
	if err := h.srv.Store.LinkDeviceEndpoint(HashToken(code), fp, "ep_beta", time.Now()); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest("POST", control.LoginNodePath, nil)
	_, _, err := h.srv.deviceNode(req, fp, "mac-c", "beta", time.Now())
	var mm *machineManagedErr
	if !errors.As(err, &mm) || !strings.Contains(err.Error(), "account adopt beta --rejoin") || !strings.Contains(err.Error(), "mac-c") {
		t.Fatalf("reissue for a machine-served login: %v; want machine_managed naming mac-c and the fix", err)
	}
	if ep, err := h.srv.Store.EndpointByTokenHash(HashToken(h.tokens["beta"])); err != nil || ep.ID != "ep_beta" {
		t.Fatalf("the machine's token after a refused reissue: %v %v", ep, err)
	}

	// Reissued anyway (an old hub, another replica): the lane says its hello
	// again with the old token and is still let in, inside the grace.
	tok, _ := MintToken()
	if err := h.srv.Store.RotateEndpointToken("ep_beta", HashToken(tok), time.Now(), ReissueTokenGrace); err != nil {
		t.Fatal(err)
	}
	if r := n.login("beta", h.tokens["beta"], false, control.CapRead); r.Type != control.TypeWelcome {
		t.Fatalf("old token inside its grace: %+v; want welcome", r)
	}
	if err := h.srv.Store.EndReissueGrace("ep_beta"); err != nil {
		t.Fatal(err)
	}
	r := n.login("beta", h.tokens["beta"], false, control.CapRead)
	if r.Type != control.TypeError || r.Error == nil || r.Error.Code != control.CodeWrongLogin ||
		!strings.Contains(r.Error.Message, "unrecognised enrollment token for login beta") ||
		!strings.Contains(r.Error.Message, "re-registered") || !strings.Contains(r.Error.Message, "account adopt beta --rejoin") {
		t.Fatalf("old token past its grace: %+v; want WRONG_LOGIN naming the reissue and the fix", r)
	}
	// A token nobody ever held stays vague.
	if r := n.login("beta", "never-a-token", false, control.CapRead); r.Error == nil || strings.Contains(r.Error.Message, "re-registered") {
		t.Fatalf("unknown token: %+v; want the plain refusal", r)
	}
	// The machine link's beat names the refused login; the Machines card
	// carries it (令牌失效 · 需要 relogin).
	n.beat("", control.Heartbeat{Hostname: "mac-c", OSUser: "root", NCPU: 10, ObservedAt: time.Now(),
		LoginsRefused: map[string]string{"beta": r.Error.Message}})
	waitFor(t, 3*time.Second, "mac-c names beta refused", func() bool {
		ms := roster(t, h).Machines
		return len(ms) == 1 && strings.Contains(ms[0].LoginsRefused["beta"], "re-registered")
	})
}
