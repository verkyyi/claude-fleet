package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
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
	// A member's device as root gets no node at all (task MPCX: a login the
	// hub cannot record as the person's is no node pass).
	boxDev := newDevice(t)
	boxDev.scan(t, h, pBob, "bob-box")
	if code, out := boxDev.loginNode(t, h, "bob-box", "root"); code != http.StatusConflict {
		t.Errorf("a member's device as root: %d %v; want 409", code, out)
	}
	for name, tok := range map[string]string{"root@mac-a re-reported": impostor.token} {
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

// --- the device road, the registry row, operator, ownerless, trust, leases,
// usage (task MPCX, second round) ---

// A device road refuses a login it cannot record: none named (or none left
// once sanitized), on the login road and the scan alike. An endpoint a device
// road enrolled that never stamped a login — an older hub's — is never a
// machine's program by its link or its report, and its first report never
// stamps root on it. A machine's program asks for its own machine's seat only,
// whatever name it reports.
func TestNodeIdentityDeviceRoadNeedsALogin(t *testing.T) {
	h := bobHarness(t)
	h.srv.FleetAdmins = []string{"_fleetadmin"}

	d := newDevice(t)
	d.scan(t, h, pBob, "bob-mbp")
	for _, login := range []string{"", "..."} {
		if code, out := d.loginNode(t, h, "bob-mbp", login); code != http.StatusConflict || out["code"] != "no_login" {
			t.Errorf("node pass with login %q: %d %v; want 409 no_login", login, code, out)
		}
	}
	// The scan road: `fleet node join` naming no login gets no node.
	code, body := postJSON(t, h, "/v1/fleet/login/start", map[string]string{
		"public_key": newUserKey(t), "device_name": "bob-box", "purpose": "node", "os_user": ""})
	if code != 200 {
		t.Fatalf("start: %d %s", code, body)
	}
	var st DeviceStart
	_ = json.Unmarshal(body, &st)
	personForm(t, h, pBob, h.http.URL, url.Values{"code": {st.UserCode}, "action": {"approve"}, "node_ack": {"1"}})
	code, body = postJSON(t, h, "/v1/fleet/login/poll", map[string]string{"device_code": st.DeviceCode})
	var cr CertResponse
	_ = json.Unmarshal(body, &cr)
	if code == 200 && cr.Node != nil {
		t.Errorf("a scan with no login: node %+v; want none", cr.Node)
	}

	// An older hub's device endpoint that never said a login.
	mach := enrollAs(t, h, "mac-a-root", "mac-a", "root")
	legacy := memberDeviceNode(t, h, pBob, "bob-air", "bob", false)
	legacy.c.CloseNow()
	waitFor(t, 3*time.Second, "the device's link gone", func() bool { return h.srv.nodes.get(legacy.id) == nil })
	// The old link's last beat may still be landing: clear until it stays clear.
	waitFor(t, 5*time.Second, "the login cleared for good", func() bool {
		for _, q := range []string{`UPDATE endpoints SET enrolled_user = '', os_user = '' WHERE endpoint_id = ?`,
			`UPDATE nodes SET os_user = '' WHERE endpoint_id = ?`} {
			if _, err := h.srv.Store.DB().Exec(q, legacy.id); err != nil {
				t.Fatal(err)
			}
		}
		time.Sleep(150 * time.Millisecond)
		et, err := h.srv.Store.EndpointTrustOf(legacy.id)
		return err == nil && et.EnrolledUser == ""
	})
	legacy.tnode = dialAdminCaps(t, h, legacy.token, false, control.CapMachine, control.CapLoginJoin)
	beat(t, legacy.c, control.Proto, control.Heartbeat{Hostname: "bob-air"})
	waitFor(t, 3*time.Second, "the legacy link", func() bool { return h.srv.nodes.get(legacy.id) != nil })
	waitFor(t, 3*time.Second, "its login-less beat", func() bool {
		r := h.srv.nodeRow(legacy.id)
		return r != nil && r.OSUser == ""
	})
	if et, err := h.srv.Store.EndpointTrustOf(legacy.id); err != nil || et.EnrolledUser != "" {
		t.Fatalf("the fixture: enrolled_user %q (%v); want none", et.EnrolledUser, err)
	}
	rec := httptest.NewRecorder()
	if host := h.srv.nodeMachineHost(rec, httptest.NewRequest(http.MethodGet, "/", nil), mustEndpoint(t, h, legacy.id)); host != "" || rec.Code != http.StatusForbidden {
		t.Errorf("an unstamped device endpoint's machine link: machine host %q HTTP %d; want 403", host, rec.Code)
	}
	if st, out, raw := adminTokenCall(t, h, legacy.token, http.MethodPost, map[string]string{"login": "_fleetadmin"}); st != http.StatusForbidden {
		t.Errorf("an unstamped device endpoint: admin-token %d %+v %s; want 403", st, out, raw)
	}
	if c := h.srv.nodes.get(legacy.id); c != nil && c.machineOpener {
		t.Errorf("an unstamped device endpoint opens logins")
	}
	// Its first report of root does not stamp it.
	beat(t, legacy.c, control.Proto, control.Heartbeat{Hostname: "bob-air", OSUser: "root"})
	waitFor(t, 3*time.Second, "the root beat", func() bool {
		r := h.srv.nodeRow(legacy.id)
		return r != nil && r.OSUser == "root"
	})
	if et, err := h.srv.Store.EndpointTrustOf(legacy.id); err != nil || et.EnrolledUser == "root" {
		t.Errorf("a device endpoint's first report stamped %q (%v); want root never", et.EnrolledUser, err)
	}

	// A machine's program reporting another machine's name asks for its own seat.
	mc := dialAdminCaps(t, h, mach, false, control.CapMachine)
	beat(t, mc.c, control.Proto, control.Heartbeat{Hostname: "mac-b", OSUser: "root"})
	waitFor(t, 3*time.Second, "mac-a's program reports mac-b", func() bool {
		r := h.srv.nodeRow("ep_mac-a-root")
		return r != nil && r.Hostname == "mac-b"
	})
	if st, out, raw := adminTokenCall(t, h, mach, http.MethodPost, map[string]string{"login": "_fleetadmin"}); st != 200 || out.Machine != "mac-a" {
		t.Fatalf("mac-a's program reporting mac-b: admin-token %d machine %q %s; want mac-a's seat", st, out.Machine, raw)
	}
	if _, err := h.srv.Store.LiveEndpointOn("mac-b", "_fleetadmin"); err == nil {
		t.Fatalf("a seat was issued on mac-b")
	}
}

// bobHarness is certHarness with Bob holding login bob on mac-e-mac-c — an
// active login somewhere, so his devices get node passes.
func bobHarness(t *testing.T) *harness {
	t.Helper()
	h, _ := certHarness(t)
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pBob, Hostname: "mac-e-mac-c", Login: "bob"}); code != 200 {
		t.Fatalf("adopt bob: HTTP %d", code)
	}
	return h
}

// fleetBeat has node n beat as login@host with one fleet on machine.
func fleetBeat(t *testing.T, n *fleetNode, host, login, machine string, f control.Fleet) {
	t.Helper()
	beat(t, n.c, control.Proto, control.Heartbeat{Hostname: host, OSUser: login, MachineID: machine,
		Fleets: []control.Fleet{f}, ObservedAt: time.Now()})
}

// The registry row names the machine and login the hub holds the node to: a
// member's device re-reporting another person's machine and login registers
// its fleet as itself, and that row moves none of their passes, tickets,
// relays or views. A machine id is the reporter's own word: another node's
// moves its fleets nowhere — the same login re-enrolled on the same machine
// takes it over.
func TestNodeIdentityRegistryRowIsHeld(t *testing.T) {
	h, _, n := peerHarness(t)
	bob := memberDeviceNode(t, h, pBob, "bob-mbp", "bob", false)

	fb := fakeFleet(t, machineC, "fleet-bob", "o/r", "/c", 3)
	fleetBeat(t, bob, "mac-e", "alice", machineC, fb)
	var row store.FleetRow
	waitFor(t, 3*time.Second, "bob's fleet registered", func() bool {
		r, err := h.srv.Store.Fleet(fb.FleetID)
		row = r
		return err == nil
	})
	if row.Hostname != "bob-mbp" || row.OSUser != "bob" {
		t.Fatalf("bob's device's fleet row = %s@%s; want bob@bob-mbp", row.OSUser, row.Hostname)
	}
	if h.srv.relayOwner(bob.id, row.Hostname, row.OSUser, h.srv.activeAccounts()) == "person:"+pAlice {
		t.Fatalf("bob's device's fleet relays as alice")
	}

	// alice5 holds machineA; bob's device then reports it.
	fa := fakeFleet(t, machineA, "fleet-alice", "o/r", "/a", 1)
	fleetBeat(t, n["alice5"], "mac-e", "alice", machineA, fa)
	waitFor(t, 3*time.Second, "alice's fleet registered", func() bool {
		r, err := h.srv.Store.Fleet(fa.FleetID)
		return err == nil && r.EndpointID == n["alice5"].id
	})
	steal := fakeFleet(t, machineA, "fleet-x", "o/r", "/x", 2)
	fleetBeat(t, bob, "bob-mbp", "bob", machineA, steal)
	beat(t, bob.c, control.Proto, control.Heartbeat{Hostname: "bob-mbp", OSUser: "bob"})
	time.Sleep(300 * time.Millisecond)
	if r, err := h.srv.Store.Fleet(fa.FleetID); err != nil || r.EndpointID != n["alice5"].id {
		t.Fatalf("alice's fleet now reports through %s (%v); want alice5", r.EndpointID, err)
	}
	if _, err := h.srv.Store.Fleet(steal.FleetID); err == nil {
		t.Fatalf("bob's device registered a fleet under alice's machine id")
	}

	// The same login on the same machine, enrolled anew: it takes the id over.
	again := connectNode(t, h, "alice5b", "mac-e", "alice", false)
	fleetBeat(t, again, "mac-e", "alice", machineA, fa)
	waitFor(t, 3*time.Second, "the re-enrolled node takes its machine id", func() bool {
		r, err := h.srv.Store.Fleet(fa.FleetID)
		return err == nil && r.EndpointID == again.id
	})
}

// "operator" is the endpoint's as well as the login's: a member's device
// enrolled under an admin login's name — or on a hub that names no admins —
// is never the operator's; the operator's own node is.
func TestNodeIdentityDeviceIsNeverOperator(t *testing.T) {
	h := bobHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	dev := memberDeviceNode(t, h, pBob, "bob-laptop", "frank", false)
	op := connectNode(t, h, "mac-b-frank", "mac-b", "frank", false)
	waitFor(t, 3*time.Second, "frank connected", func() bool { return h.srv.nodes.get(op.id) != nil })
	if got := h.srv.workerRecordOwner(mustEndpoint(t, h, dev.id)); got == "operator" {
		t.Errorf("a member's device enrolled as frank: owner %q; want not the operator", got)
	}
	if got := h.srv.workerRecordOwner(mustEndpoint(t, h, op.id)); got != "operator" {
		t.Errorf("the operator's frank@mac-b: owner %q; want operator", got)
	}
	h.srv.FleetAdmins = nil
	if got := h.srv.workerRecordOwner(mustEndpoint(t, h, dev.id)); got == "operator" {
		t.Errorf("no admins named: a member's device's owner %q; want not the operator", got)
	}
	if got := h.srv.workerRecordOwner(mustEndpoint(t, h, op.id)); got != "operator" {
		t.Errorf("no admins named: the operator's node's owner %q; want operator", got)
	}
}

// A device's node is its person's or nothing: a login the hub cannot record
// as theirs (another person's, root) gets no node pass; a device endpoint no
// person owns (an older hub's) places nothing and holds no client lease as the
// operator. The operator's own ownerless node still does both.
func TestNodeIdentityOwnerlessNodeActsForNoOne(t *testing.T) {
	h := bobHarness(t)
	memberDeviceNode(t, h, pAlice, "alice-box", "alice", false)
	d := newDevice(t)
	d.scan(t, h, pBob, "alice-box")
	if code, out := d.loginNode(t, h, "alice-box", "alice"); code != http.StatusConflict || out["code"] != "login_not_recorded" {
		t.Errorf("bob's device as alice@alice-box: %d %v; want 409 login_not_recorded", code, out)
	}
	if id, err := h.srv.Store.DeviceNodeEndpoint(d.fp); err == nil {
		t.Errorf("a refused node pass left endpoint %s behind", id)
	}
	r := newDevice(t)
	r.scan(t, h, pBob, "bob-box")
	if code, out := r.loginNode(t, h, "bob-box", "root"); code != http.StatusConflict {
		t.Errorf("bob's device as root: %d %v; want 409", code, out)
	}

	dev := memberDeviceNode(t, h, pBob, "bob-mbp", "bob", false)
	if _, err := h.srv.Store.DB().Exec(`DELETE FROM fleet_accounts WHERE endpoint_id = ?`, dev.id); err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.nodePrincipal(mustEndpoint(t, h, dev.id), store.FleetRow{}); err == nil {
		t.Errorf("an ownerless device endpoint places as the operator")
	}
	if resp, raw := getWithToken(t, h, "/v1/node/client", dev.token); resp.StatusCode != http.StatusForbidden {
		t.Errorf("an ownerless device endpoint's client lease: %d %s; want 403", resp.StatusCode, raw)
	}
	op := connectNode(t, h, "mac-b-frank", "mac-b", "frank", false)
	if p, err := h.srv.nodePrincipal(mustEndpoint(t, h, op.id), store.FleetRow{}); err != nil || p.Person != "" {
		t.Errorf("the operator's ownerless node: %+v %v; want its grant", p, err)
	}
	if resp, raw := getWithToken(t, h, "/v1/node/client", op.token); resp.StatusCode != 200 {
		t.Errorf("the operator's ownerless node's client lease: %d %s; want 200", resp.StatusCode, raw)
	}
}

// A member's device never takes its machine name's trust — not when the
// operator trusts that name after the device enrolled under it. An endpoint
// the operator's code enrolled as that machine does.
func TestNodeIdentityDeviceTakesNoMachineTrust(t *testing.T) {
	h := bobHarness(t)
	dev := memberDeviceNode(t, h, pBob, "bob-box", "bob", false)
	enrollAs(t, h, "bob-box-carol", "bob-box", "carol")
	settings, err := h.srv.trustSettings(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if tr, _ := h.srv.endpointTrust(dev.id, "bob-box", settings); tr != TrustUntrusted {
		t.Fatalf("before any trust word: %s", tr)
	}
	if err := h.srv.Store.SetFleetSetting(trustKey("bob-box"), TrustTrusted, time.Now()); err != nil {
		t.Fatal(err)
	}
	settings, _ = h.srv.trustSettings(time.Now())
	if tr, src := h.srv.endpointTrust(dev.id, "bob-box", settings); tr != TrustUntrusted || src != TrustSourceDevice {
		t.Errorf("a member's device after its name was trusted: %s (%s); want untrusted (device)", tr, src)
	}
	if tr, _ := h.srv.endpointTrust("ep_bob-box-carol", "bob-box", settings); tr != TrustTrusted {
		t.Errorf("the operator-enrolled endpoint on bob-box: %s; want trusted", tr)
	}
}

// --force takes back only a lease of the same person (or the same node, or
// the operator's own node's); a conflict over another person's lease says it
// is held and until when — not whose session, machine or login.
func TestNodeLeaseForceStaysInTheFamily(t *testing.T) {
	h, macD, _ := newLeasePair(t)
	enablePeople(t, h, pAlice, pBob)
	h.srv.FleetAdmins = []string{"frank"}
	macB := newLeaseNode(t, h, "mac-b", machineC)
	// Bob's node: login bobl on mac-x.
	const machineX = "44444444-4444-4444-8444-444444444444"
	fx := connectFakeNode(t, h, "mac-x", true)
	f := fakeFleet(t, machineX, "fleet-mac-x", leaseRepo, "/Users/x/mac-x")
	fx.beat("mac-x", "bobl", machineX, f)
	waitFor(t, 3*time.Second, "mac-x fleet registered", func() bool {
		_, err := h.srv.Store.Fleet(f.FleetID)
		return err == nil
	})
	macX := &leaseNode{fakeNode: fx, host: "mac-x", machine: machineX, token: h.tokens["mac-x"], fleet: f.FleetID}
	for _, a := range [][3]string{{"mac-d", "ivan", pAlice}, {"mac-b", "ivan", pAlice}, {"mac-x", "bobl", pBob}} {
		if err := h.srv.changeAccount(FleetAccountRequest{Action: "adopt", PrincipalID: a[2], Hostname: a[0], Login: a[1]}, "test"); err != nil {
			t.Fatalf("adopt %s on %s: %v", a[1], a[0], err)
		}
	}
	if st, out := macD.acquire(t, h, 5, false); st != 200 {
		t.Fatalf("alice on mac-d: %d %v", st, out)
	}
	macD.show(t, 5)
	for _, force := range []bool{false, true} {
		st, out := macX.acquire(t, h, 5, force)
		if st != http.StatusConflict {
			t.Fatalf("bob (force=%v): %d %v; want 409", force, st, out)
		}
		hv, _ := out["holder"].(map[string]any)
		if hv["node"] != "-" || hv["worker_id"] != "-" || hv["hostname"] != "" || hv["os_user"] != "" {
			t.Errorf("bob (force=%v) is told %v about alice's lease; want only that it is held", force, hv)
		}
	}
	if st, out := macB.acquire(t, h, 5, true); st != 200 || out["displaced"] == nil {
		t.Fatalf("alice's own mac-b with --force: %d %v; want her lease back", st, out)
	}
	if st, out := macD.acquire(t, h, 5, false); st != http.StatusConflict || holderNode(out) != "mac-b" {
		t.Fatalf("alice's mac-d: %d %v; want held by her mac-b, named", st, out)
	}
}

// Usage is put under the login the node enrolled as, whatever login its push
// names.
func TestNodeIdentityUsageUnderTheEnrolledLogin(t *testing.T) {
	h := bobHarness(t)
	dev := memberDeviceNode(t, h, pBob, "bob-mbp", "bob", false)
	batch := &model.Batch{AgentVersion: "test", AccountOrigin: model.OriginLogin,
		Identity: model.Identity{AccountUUID: "acct-bob-usage", Hostname: "mac-e", OSUser: "alice", Source: model.SourceClaude},
		Events:   []model.UsageEvent{{MessageUUID: "m-usage-1", TS: time.Now().UTC(), Model: "x", OutputTokens: 1}}}
	if _, err := h.srv.ingest(mustEndpoint(t, h, dev.id), batch); err != nil {
		t.Fatal(err)
	}
	var login string
	if err := h.srv.Store.DB().QueryRow(`SELECT os_user FROM usage_events WHERE message_uuid = 'm-usage-1'`).Scan(&login); err != nil {
		t.Fatal(err)
	}
	if login != "bob" {
		t.Fatalf("usage recorded under %q; want bob", login)
	}
}
