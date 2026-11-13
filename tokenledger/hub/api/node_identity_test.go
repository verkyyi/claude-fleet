package api

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

// Task MPCX: the hub answers a node from the identity it enrolled with —
// endpoints.enrolled_host / enrolled_user — never from the host and login its
// latest usage push or heartbeat names.

// memberDeviceNode is a node a person enrolled through their own device's
// road (`fleet login`'s node pass) as login on host, connected with caps.
func memberDeviceNode(t *testing.T, h *harness, pid, host, login string, admin bool, caps ...string) *fleetNode {
	t.Helper()
	d := newDevice(t)
	d.scan(t, h, pid, host)
	code, out := d.loginNode(t, h, host, login)
	if code != 200 {
		t.Fatalf("node pass %s@%s: %d %v", login, host, code, out)
	}
	n := &fleetNode{token: out["token"].(string), id: out["endpoint_id"].(string)}
	n.tnode = dialAdminCaps(t, h, n.token, admin, caps...)
	beat(t, n.c, control.Proto, control.Heartbeat{Hostname: host, OSUser: login})
	waitFor(t, 3*time.Second, login+"@"+host+" on the roster", func() bool {
		r := h.srv.nodeRow(n.id)
		return r != nil && r.Hostname == host && r.OSUser == login
	})
	return n
}

// reReport has node n say it is login on host: on its usage push (ingest's
// TouchEndpoint) when ingest, and on its heartbeat.
func reReport(t *testing.T, h *harness, n *fleetNode, host, login string, ingest bool) {
	t.Helper()
	if ingest {
		ident := model.Identity{AccountUUID: "acct-" + n.id, Hostname: host, OSUser: login}
		if err := h.srv.Store.UpsertAccount(ident, "max", ""); err != nil {
			t.Fatal(err)
		}
		if _, _, err := h.srv.Store.TouchEndpoint(n.id, ident, "test", true, nil); err != nil {
			t.Fatal(err)
		}
	}
	beat(t, n.c, control.Proto, control.Heartbeat{Hostname: host, OSUser: login})
	waitFor(t, 3*time.Second, "the re-report on the roster", func() bool {
		r := h.srv.nodeRow(n.id)
		return r != nil && r.Hostname == host && r.OSUser == login
	})
}

func identityAudits(t *testing.T, h *harness) int {
	t.Helper()
	var n int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action = 'node_identity'`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// (1) A member's device node that re-reports another person's machine and
// login — on its usage push or only on its heartbeat — or the operator's
// unowned login, gets no peer certificate and no peer relay; one that
// enrolled under such a name gets none either. The legitimate equivalents —
// the same person's own logins — still do.
func TestNodeIdentityReReportGetsNoPeerCert(t *testing.T) {
	h, _, n := peerHarness(t)
	key := newUserKey(t)

	bob := memberDeviceNode(t, h, pBob, "bob-mbp", "bob", false)
	if st, g, raw := peerPost(t, h, bob.token, map[string]any{"target": "mac-c", "purpose": "view", "public_key": key}); st != 200 || g.Login != "bob" {
		t.Fatalf("bob's device → his own login on mac-c: HTTP %d login %q %s; want bob", st, g.Login, raw)
	}
	before := identityAudits(t, h)

	for _, tc := range []struct {
		name, host, login string
		ingest            bool
	}{
		{"alice@mac-e, push + heartbeat", "mac-e", "alice", true},
		{"the operator's unowned frank, push + heartbeat", "mac-e", "frank", true},
	} {
		reReport(t, h, bob, tc.host, tc.login, tc.ingest)
		if st, g, raw := peerPost(t, h, bob.token, map[string]any{"target": "mac-c", "purpose": "view", "public_key": key}); st != 403 {
			t.Errorf("%s: peer cert HTTP %d login %q %s; want 403", tc.name, st, g.Login, raw)
		}
		if _, st := peerRelayDial(t, h, bob.token, "mac-e-mac-c"); st != 403 {
			t.Errorf("%s: peer relay HTTP %d; want 403", tc.name, st)
		}
	}

	// Heartbeat only: a second device of Bob's says alice@mac-e on its beat.
	air := memberDeviceNode(t, h, pBob, "bob-air", "bob", false)
	reReport(t, h, air, "mac-e", "alice", false)
	if st, g, raw := peerPost(t, h, air.token, map[string]any{"target": "mac-c", "purpose": "view", "public_key": key}); st != 403 {
		t.Errorf("heartbeat re-report: peer cert HTTP %d login %q %s; want 403", st, g.Login, raw)
	}
	if _, st := peerRelayDial(t, h, air.token, "mac-e-mac-c"); st != 403 {
		t.Errorf("heartbeat re-report: peer relay HTTP %d; want 403", st)
	}
	// The enrollment decides who it is: still Bob's bob-air.
	if host, user := h.srv.peerSelf(mustEndpoint(t, h, air.id)); host != "bob-air" || user != "bob" {
		t.Errorf("peerSelf = %s@%s; want bob@bob-air", user, host)
	}
	if after := identityAudits(t, h); after <= before {
		t.Errorf("no node_identity audit row for a report that differs from the enrollment (%d → %d)", before, after)
	}

	// Enrolled under the name from the start: alice on (trusted) mac-e is
	// refused at the node pass; frank on a box of its own enrolls as Bob's
	// computer — it reaches Bob's own login, never the operator's frank.
	d := newDevice(t)
	d.scan(t, h, pBob, "mac-e")
	if code, out := d.loginNode(t, h, "mac-e", "alice"); code != http.StatusConflict {
		t.Errorf("a member's device as alice@mac-e: %d %v; want 409", code, out)
	}
	x := memberDeviceNode(t, h, pBob, "bob-box", "frank", false)
	if st, g, raw := peerPost(t, h, x.token, map[string]any{"target": "mac-c", "purpose": "view", "public_key": key}); st != 200 || g.Login != "bob" {
		t.Errorf("enrolled as frank@bob-box: peer cert HTTP %d login %q %s; want Bob's own bob", st, g.Login, raw)
	}

	// The legitimate shapes, unchanged: Alice's two logins, the operator's.
	if st, g, raw := peerPost(t, h, n["alice5"].token, map[string]any{"target": "mac-c", "purpose": "view", "public_key": key}); st != 200 || g.Login != "alice" {
		t.Fatalf("alice@mac-d → mac-c: HTTP %d login %q %s", st, g.Login, raw)
	}
	if st, g, raw := peerPost(t, h, n["verk5"].token, map[string]any{"target": "mac-c", "purpose": "view", "public_key": key}); st != 200 || g.Login != "frank" {
		t.Fatalf("frank@mac-d → mac-c: HTTP %d login %q %s", st, g.Login, raw)
	}
}

func mustEndpoint(t *testing.T, h *harness, id string) *store.Endpoint {
	t.Helper()
	ep, err := h.srv.Store.EndpointByID(id)
	if err != nil {
		t.Fatal(err)
	}
	return ep
}

// (2) A node that reports an admin login and says admin:true is no admin: not
// the refresh relay, not where account ops go — whether a member's device
// enrolled under the admin login or re-reported it later. The real admin seat
// the hub issued is both; an operator's admin login on a machine nobody
// trusted still opens logins, as before.
func TestNodeIdentityAdminIsTheEnrollments(t *testing.T) {
	h, _ := certHarness(t)
	h.srv.FleetAdmins = []string{"frank", "_fleetadmin"}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pBob, Hostname: "mac-e-mac-c", Login: "bob"}); code != 200 {
		t.Fatalf("adopt bob: HTTP %d", code)
	}
	now := time.Now()
	for _, m := range []string{"mac-a", "bob-mbp"} {
		if err := h.srv.Store.SetFleetSetting(trustKey(m), TrustTrusted, now); err != nil {
			t.Fatal(err)
		}
	}
	caps := []string{control.CapOAuthRefresh}

	// A member's device enrolled as the admin login frank.
	enrolled := memberDeviceNode(t, h, pBob, "bob-laptop", "frank", true, caps...)
	// A member's device enrolled as bob that re-reports frank on mac-a.
	moved := memberDeviceNode(t, h, pBob, "bob-mbp2", "bob", false)
	reReport(t, h, moved, "mac-a", "frank", true)
	moved.c.CloseNow()
	moved.tnode = dialAdminCaps(t, h, moved.token, true, caps...)
	beat(t, moved.c, control.Proto, control.Heartbeat{Hostname: "mac-a", OSUser: "frank"})
	for name, x := range map[string]*fleetNode{"enrolled as frank": enrolled, "re-reported frank": moved} {
		waitFor(t, 3*time.Second, name+" connected", func() bool { return h.srv.nodes.get(x.id) != nil })
		if c := h.srv.nodes.get(x.id); c.admin || c.canOAuthRefresh || c.accountNode() {
			t.Errorf("%s: admin=%v relay=%v account=%v; want none", name, c.admin, c.canOAuthRefresh, c.accountNode())
		}
	}
	if id, _, err := h.srv.OAuthRefreshNode(time.Now()); !errors.Is(err, credvault.ErrRefreshUnavailable) {
		t.Fatalf("refresh relay picked %s (%v); want none", id, err)
	}
	for _, host := range []string{"mac-a", "bob-laptop"} {
		if id, ok := h.srv.nodes.openerFor(host); ok {
			t.Errorf("account ops for %s go to %s", host, id)
		}
	}
	// The admin role account by a member's device: refused at enrollment.
	d := newDevice(t)
	d.scan(t, h, pBob, "bob-seat")
	if code, out := d.loginNode(t, h, "bob-seat", "_fleetadmin"); code != http.StatusConflict || out["code"] != "reserved_login" {
		t.Fatalf("a member's device as _fleetadmin: %d %v; want 409 reserved_login", code, out)
	}

	// The real seat: mac-a's machine program asks for it.
	mach := enrollAs(t, h, "mac-a-root", "mac-a", "root")
	st, seat, raw := adminTokenCall(t, h, mach, http.MethodPost, map[string]string{"login": "_fleetadmin"})
	if st != 200 {
		t.Fatalf("admin-token: %d %s", st, raw)
	}
	sc := dialAdminCaps(t, h, seat.Token, true, caps...)
	beat(t, sc.c, control.Proto, control.Heartbeat{Hostname: "mac-a", OSUser: "_fleetadmin"})
	waitFor(t, 3*time.Second, "the seat online", func() bool {
		id, _, err := h.srv.OAuthRefreshNode(time.Now())
		return err == nil && id == seat.EndpointID
	})
	if id, ok := h.srv.nodes.openerFor("mac-a"); !ok || id != seat.EndpointID {
		t.Fatalf("mac-a's account ops go to %q %v; want the seat %s", id, ok, seat.EndpointID)
	}
	// The operator's own admin login on a machine nobody trusted.
	frank := connectNode(t, h, "mac-b-frank", "mac-b", "frank", true)
	waitFor(t, 3*time.Second, "frank connected", func() bool { return h.srv.nodes.get(frank.id) != nil })
	if c := h.srv.nodes.get(frank.id); !c.admin {
		t.Fatalf("frank@mac-b admin=%v; want admin", c.admin)
	}
	if id, ok := h.srv.nodes.openerFor("mac-b"); !ok || id != frank.id {
		t.Fatalf("mac-b's account ops go to %q %v; want frank", id, ok)
	}
}

// (3) A node that reports root and another machine's name is not that
// machine's program: no entry door list / reach (nodeMachineHost) and no
// admin-seat token for it — nor is a member's device that enrolled as root.
// The real machine program still is, even running demoted under a pod's
// login.
func TestNodeIdentityMachineIsTheEnrollments(t *testing.T) {
	h, _ := certHarness(t)
	h.srv.FleetAdmins = []string{"_fleetadmin"}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pBob, Hostname: "mac-e-mac-c", Login: "bob"}); code != 200 {
		t.Fatalf("adopt bob: HTTP %d", code)
	}
	mach := enrollAs(t, h, "mac-a-root", "mac-a", "root")
	machHost := func(tok string) (string, int) {
		ep, err := h.srv.Store.EndpointByTokenHash(HashToken(tok))
		if err != nil {
			t.Fatal(err)
		}
		rec := httptest.NewRecorder()
		got := h.srv.nodeMachineHost(rec, httptest.NewRequest(http.MethodGet, "/", nil), ep)
		return got, rec.Code
	}

	impostor := memberDeviceNode(t, h, pBob, "bob-mbp", "bob", false)
	reReport(t, h, impostor, "mac-a", "root", true)
	impostor.c.CloseNow()
	impostor.tnode = dialAdminCaps(t, h, impostor.token, false, control.CapMachine)
	beat(t, impostor.c, control.Proto, control.Heartbeat{Hostname: "mac-a", OSUser: "root"})
	box := memberDeviceNode(t, h, pBob, "bob-box", "root", false)
	for name, tok := range map[string]string{"root@mac-a re-reported": impostor.token, "enrolled as root": box.token} {
		if host, code := machHost(tok); host != "" || code != http.StatusForbidden {
			t.Errorf("%s: machine host %q HTTP %d; want 403", name, host, code)
		}
		if st, _, raw := adminTokenCall(t, h, tok, http.MethodPost, map[string]string{"login": "_fleetadmin"}); st != http.StatusForbidden {
			t.Errorf("%s: admin-token HTTP %d %s; want 403", name, st, raw)
		}
	}
	if id, err := h.srv.Store.LiveEndpointOn("mac-a", "_fleetadmin"); err == nil {
		t.Fatalf("an admin seat %s was minted for mac-a", id)
	}

	// The real machine program: mac-a, and still mac-a when its link runs
	// demoted (a pod's login) and says machine.
	if host, code := machHost(mach); host != "mac-a" {
		t.Fatalf("mac-a's program: %q HTTP %d", host, code)
	}
	mc := dialAdminCaps(t, h, mach, false, control.CapMachine)
	beat(t, mc.c, control.Proto, control.Heartbeat{Hostname: "mac-a", OSUser: "u-pod"})
	waitFor(t, 3*time.Second, "the demoted beat", func() bool {
		r := h.srv.nodeRow("ep_mac-a-root")
		return r != nil && r.OSUser == "u-pod"
	})
	if host, code := machHost(mach); host != "mac-a" {
		t.Fatalf("mac-a's demoted program: %q HTTP %d", host, code)
	}
	if st, out, raw := adminTokenCall(t, h, mach, http.MethodPost, map[string]string{"login": "_fleetadmin"}); st != 200 || out.Machine != "mac-a" {
		t.Fatalf("mac-a's admin-token: %d %s", st, raw)
	}
}

// A code minted for one opened login enrolls that login only.
func TestNodeIdentityLoginCodeNamesItsLogin(t *testing.T) {
	h := newFleetHarness(t)
	now := time.Now()
	code, _ := MintJoinCode()
	if err := h.srv.Store.CreateJoinCodeFor(HashToken(code), "mac-a-carol", "fixed", "", "managed", "mac-a", now, time.Hour); err != nil {
		t.Fatal(err)
	}
	for _, as := range []string{"root", "frank"} {
		if c, raw := postJSON(t, h, "/v1/node/join", map[string]string{"code": code, "hostname": "mac-a", "os_user": as}); c != http.StatusForbidden {
			t.Fatalf("redeemed as %s: %d %s; want 403", as, c, raw)
		}
	}
	if c, raw := postJSON(t, h, "/v1/node/join", map[string]string{"code": code, "hostname": "mac-a", "os_user": "carol"}); c != 200 {
		t.Fatalf("redeemed as carol: %d %s", c, raw)
	}
}

// A machine name that moved after an operator's code enrolled the endpoint
// (the join named it mac-a; the agent reports its real hostname) keeps its
// report, as before — its login is still held to the enrollment; the same
// move to a trusted machine's name does not.
func TestNodeIdentityOperatorJoinKeepsItsHostname(t *testing.T) {
	h := newFleetHarness(t)
	now := time.Now()
	code, _ := MintJoinCode()
	if err := h.srv.Store.CreateJoinCode(HashToken(code), "", now, JoinCodeTTL); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.RedeemJoinCode(HashToken(code), now, "ep_op", "op", HashToken("tok-op"), "mac-a", "runner"); err != nil {
		t.Fatal(err)
	}
	ep := mustEndpoint(t, h, "ep_op")
	if id := h.srv.nodeSelfFrom(ep, "runnervm1", "runner"); id.Host != "runnervm1" || id.User != "runner" || id.drift() {
		t.Fatalf("renamed: %+v; want its report", id)
	}
	if id := h.srv.nodeSelfFrom(ep, "runnervm1", "frank"); id.User != "runner" || !id.UserDrift {
		t.Fatalf("another login: %+v; want runner, held", id)
	}
	if err := h.srv.Store.SetFleetSetting(trustKey("mac-z"), TrustTrusted, now); err != nil {
		t.Fatal(err)
	}
	if id := h.srv.nodeSelfFrom(ep, "mac-z", "runner"); id.Host != "mac-a" || !id.HostDrift {
		t.Fatalf("a trusted name it did not join as: %+v; want mac-a, held", id)
	}
}

// (4) Routing reads the same identity (task MPCX): a member's device node that
// re-reports another person's machine and login — with every relay
// capability — is never the link that person's SSH relay, entry relay, chat,
// terminal, service log, svc run or preview is carried over; the person's own
// link on that machine is. The operator-enrolled renamed host keeps its
// report (TestNodeIdentityOperatorJoinKeepsItsHostname) and is still routed
// to under it.
func TestNodeIdentityReReportIsNotRoutedTo(t *testing.T) {
	h, _, n := peerHarness(t)
	caps := []string{control.CapSSHRelay, control.CapEntryRelay, control.CapChat, control.CapTerm,
		control.CapServiceLog, control.CapSvcRun, control.CapPreview}
	relink := func(x *fleetNode, host, login string) {
		t.Helper()
		x.c.CloseNow()
		x.tnode = dialHello(t, h, x.token, control.Hello{HeartbeatMS: 5000, Capabilities: caps, AttachmentGeneration: "gen-1"})
		beat(t, x.c, control.Proto, control.Heartbeat{Hostname: host, OSUser: login})
		waitFor(t, 3*time.Second, login+"@"+host+" relinked", func() bool {
			c := h.srv.nodes.get(x.id)
			r := h.srv.nodeRow(x.id)
			return c != nil && c.canSSHRelay && r != nil && r.Hostname == host && r.OSUser == login
		})
	}
	alice := sshRelayIdentity{Principal: pAlice}

	bob := memberDeviceNode(t, h, pBob, "bob-mbp", "bob", false)
	reReport(t, h, bob, "mac-e", "alice", true)
	relink(bob, "mac-e", "alice")
	if c := h.srv.nodes.get(bob.id); c.hostname() != "bob-mbp" || c.user() != "bob" {
		t.Errorf("bob's device is routed to as %s@%s; want bob@bob-mbp", c.user(), c.hostname())
	}

	notBob := func(what, id string, err error) {
		t.Helper()
		if id == bob.id {
			t.Errorf("%s for alice@mac-e picked bob's device (%v)", what, err)
		}
	}
	pick := func() {
		t.Helper()
		id, _, err := h.srv.sshRelayNode(alice, "mac-e")
		notBob("ssh relay", id, err)
		id, _, err = h.srv.peerSSHRelayNode("mac-e", "alice")
		notBob("peer ssh relay", id, err)
		id, _, err = h.srv.entryRelayNode("mac-e", "alice")
		notBob("entry relay", id, err)
		id, _, err = h.srv.chatRelayNode("mac-e", "alice")
		notBob("chat", id, err)
		id, _, err = h.srv.termRelayNode("mac-e", "alice")
		notBob("terminal", id, err)
		id, _ = h.srv.svcLogLane("mac-e", "alice")
		notBob("service log", id, nil)
		for _, l := range h.srv.nodes.svcLanes(func(host, login string) bool { return host == "mac-e" && login == "alice" }) {
			notBob("svc lane", l.id, nil)
		}
		id, _, err = h.srv.previewNode(store.Preview{Endpoint: bob.id, Machine: "mac-e", Login: "alice", TokenHash: HashToken(bob.token)})
		notBob("preview", id, err)
	}
	// Alice's own link on mac-e is offline: nothing — bob's device is no stand-in.
	n["alice5"].c.CloseNow()
	waitFor(t, 3*time.Second, "alice's link gone", func() bool { return h.srv.nodes.get(n["alice5"].id) == nil })
	pick()
	if id, _, err := h.srv.chatRelayNode("mac-e", "alice"); err == nil {
		t.Errorf("chat for alice@mac-e with her link down: %s; want none", id)
	}

	// Alice's own link back: it is the one picked.
	relink(n["alice5"], "mac-e", "alice")
	pick()
	if id, _, err := h.srv.chatRelayNode("mac-e", "alice"); err != nil || id != n["alice5"].id {
		t.Errorf("chat for alice@mac-e: %s %v; want her own link %s", id, err, n["alice5"].id)
	}
	if id, _, err := h.srv.peerSSHRelayNode("mac-e", "alice"); err != nil || id != n["alice5"].id {
		t.Errorf("peer ssh relay for alice@mac-e: %s %v; want her own link %s", id, err, n["alice5"].id)
	}

	// Bob's device under its own name is still his.
	if id, _, err := h.srv.chatRelayNode("bob-mbp", "bob"); err != nil || id != bob.id {
		t.Errorf("chat for bob@bob-mbp: %s %v; want his device %s", id, err, bob.id)
	}

	// His laptop renamed to a name nothing else holds: its sessions are
	// listed under the new name, and it is routed to under it — as bob.
	reReport(t, h, bob, "bob-mbp-2", "bob", false)
	waitFor(t, 3*time.Second, "routed as bob@bob-mbp-2", func() bool {
		c := h.srv.nodes.get(bob.id)
		return c != nil && c.hostname() == "bob-mbp-2" && c.user() == "bob"
	})
	if id, _, err := h.srv.chatRelayNode("bob-mbp-2", "bob"); err != nil || id != bob.id {
		t.Errorf("chat for bob@bob-mbp-2: %s %v; want his device %s", id, err, bob.id)
	}
	// ... but a renamed laptop never takes another login with it.
	reReport(t, h, bob, "bob-mbp-2", "alice", false)
	waitFor(t, 3*time.Second, "the login held", func() bool {
		c := h.srv.nodes.get(bob.id)
		return c != nil && c.user() == "bob"
	})
	if id, _, err := h.srv.chatRelayNode("bob-mbp-2", "alice"); err == nil && id == bob.id {
		t.Errorf("chat for alice@bob-mbp-2 picked bob's device")
	}
}
