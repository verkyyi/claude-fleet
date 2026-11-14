package api

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"database/sql/driver"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

// --- task MPCX, third round: names matched literally, devices bound to their
// person, the identity caches' cost and freshness ---

// countingDriver wraps the SQLite driver and records every statement any
// store opened through it prepares — what a road costs, measured.
type countingDriver struct {
	inner driver.Driver
	mu    sync.Mutex
	on    atomic.Bool
	stmts []string
}

func (d *countingDriver) Open(name string) (driver.Conn, error) {
	c, err := d.inner.Open(name)
	if err != nil {
		return nil, err
	}
	return &countingConn{Conn: c, d: d}, nil
}

func (d *countingDriver) record(q string) {
	if d.on.Load() {
		d.mu.Lock()
		d.stmts = append(d.stmts, strings.Join(strings.Fields(q), " "))
		d.mu.Unlock()
	}
}

// measure runs f and answers the statements it prepared (nil, f run all the
// same, for a nil driver: the Postgres leg).
func (d *countingDriver) measure(f func()) []string {
	if d == nil {
		f()
		return nil
	}
	d.mu.Lock()
	d.stmts = nil
	d.mu.Unlock()
	d.on.Store(true)
	f()
	d.on.Store(false)
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]string(nil), d.stmts...)
}

type countingConn struct {
	driver.Conn
	d *countingDriver
}

func (c *countingConn) Prepare(q string) (driver.Stmt, error) {
	c.d.record(q)
	return c.Conn.Prepare(q)
}

func (c *countingConn) PrepareContext(ctx context.Context, q string) (driver.Stmt, error) {
	c.d.record(q)
	if p, ok := c.Conn.(driver.ConnPrepareContext); ok {
		return p.PrepareContext(ctx, q)
	}
	return c.Conn.Prepare(q)
}

func (c *countingConn) BeginTx(ctx context.Context, o driver.TxOptions) (driver.Tx, error) {
	if b, ok := c.Conn.(driver.ConnBeginTx); ok {
		return b.BeginTx(ctx, o)
	}
	return c.Conn.Begin() //nolint:staticcheck // the inner driver's fallback
}

var (
	countingOnce sync.Once
	counting     *countingDriver
)

// countedHarness is bobHarness on a store whose statements are counted; on
// the Postgres leg the store is not wrapped and the driver is nil — the roads
// still run, only the counts are SQLite's.
func countedHarness(t *testing.T) (*harness, *countingDriver) {
	t.Helper()
	if os.Getenv("CCQUOTA_DB_URL") != "" {
		return bobHarness(t), nil
	}
	countingOnce.Do(func() {
		db, err := sql.Open("sqlite", ":memory:")
		if err != nil {
			t.Fatal(err)
		}
		counting = &countingDriver{inner: db.Driver()}
		_ = db.Close()
		sql.Register("sqlite-mpcx-counted", counting)
	})
	prev := store.SQLiteDriver
	store.SQLiteDriver = "sqlite-mpcx-counted"
	defer func() { store.SQLiteDriver = prev }()
	return bobHarness(t), counting
}

// Every name a lookup is given is matched literally: `%` and `_` in a
// reported or enrolled name widen nothing — the seat lookup, the "another
// endpoint enrolled as it" reads and the opened-login read.
func TestNodeIdentityNamesMatchLiterally(t *testing.T) {
	h := bobHarness(t)
	h.srv.FleetAdmins = []string{"_fleetadmin"}
	enrollAs(t, h, "macxa-root", "macxa", "root")
	enrollAs(t, h, "mac-q-carol", "mac.q", "carol") // a dotted enrolled name
	req := httptest.NewRequest(http.MethodPost, "/", nil)
	if _, err := h.srv.issueAdminToken(req, "mac.q", "_fleetadmin", "", time.Now()); err != nil {
		t.Fatal(err)
	}
	st := h.srv.Store
	for _, name := range []string{"%", "_", "mac_a", "ma%", `mac\`} {
		if ok, err := st.EnrolledByAnother("nobody", name); err != nil || ok {
			t.Errorf("EnrolledByAnother(%q) = %v %v; want no", name, ok, err)
		}
		if ok, err := st.MachineProgramEnrolledAs("nobody", name); err != nil || ok {
			t.Errorf("MachineProgramEnrolledAs(%q) = %v %v; want no", name, ok, err)
		}
		if ok, err := st.LoginEnrolledOn(name, "carol"); err != nil || ok {
			t.Errorf("LoginEnrolledOn(%q, carol) = %v %v; want no", name, ok, err)
		}
		if id, err := st.LiveSeatOn(name, "_fleetadmin"); err == nil {
			t.Errorf("LiveSeatOn(%q) = %s; want none", name, id)
		}
	}
	// ... and the real names still match.
	if ok, _ := st.EnrolledByAnother("nobody", "macxa"); !ok {
		t.Errorf("EnrolledByAnother(macxa) = no")
	}
	if ok, _ := st.LoginEnrolledOn("mac", "carol"); !ok {
		t.Errorf("LoginEnrolledOn(mac, carol) — mac.q's first label — = no")
	}
}

// Two people's devices — and one person's two computers — reporting the same
// machine and login each get a node of their own, under a name of their own,
// bound to their own person; each person's chat reaches only their own; no
// one is refused because another device used the name first. A signed node
// pass is answered once; a refusal (the admin role account) creates nothing.
func TestNodeIdentityDevicesSharingANameEachTheirOwn(t *testing.T) {
	h := bobHarness(t)
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pCarol, Hostname: "mac-e", Login: "carol"}); code != 200 {
		t.Fatalf("adopt carol: HTTP %d", code)
	}
	type dev struct {
		pid, ep, host string
		n             *fleetNode
	}
	var devs []dev
	for _, pid := range []string{pBob, pCarol, pBob} {
		d := newDevice(t)
		d.scan(t, h, pid, "MacBook-Pro")
		code, out := d.loginNode(t, h, "MacBook-Pro", "sam")
		if code != 200 {
			t.Fatalf("%s's device as sam@MacBook-Pro: %d %v; want a node", pid, code, out)
		}
		ep := out["endpoint_id"].(string)
		et, _ := h.srv.Store.EndpointTrustOf(ep)
		n := &fleetNode{token: out["token"].(string), id: ep}
		n.tnode = dialHello(t, h, n.token, control.Hello{HeartbeatMS: 5000, Capabilities: []string{control.CapChat}})
		beat(t, n.c, control.Proto, control.Heartbeat{Hostname: "MacBook-Pro", OSUser: "sam"})
		devs = append(devs, dev{pid, ep, et.EnrolledHost, n})
	}
	seen := map[string]bool{}
	for _, d := range devs {
		if seen[strings.ToLower(d.host)] {
			t.Fatalf("two devices enrolled as %s", d.host)
		}
		seen[strings.ToLower(d.host)] = true
		if who, err := h.srv.principalOnNode(d.ep, d.host, "sam"); err != nil || who != d.pid {
			t.Errorf("%s: node of %q (%v); want %s", d.host, who, err, d.pid)
		}
		waitFor(t, 3*time.Second, d.host+" routed", func() bool {
			c := h.srv.nodes.get(d.ep)
			return c != nil && strings.EqualFold(c.hostname(), d.host)
		})
		if id, _, err := h.srv.chatRelayNode(d.host, "sam"); err != nil || id != d.ep {
			t.Errorf("chat for sam@%s: %s %v; want %s", d.host, id, err, d.ep)
		}
	}
	// The first device of Bob's still answers to Bob after his second.
	if who, _ := h.srv.principalOnNode(devs[0].ep, devs[0].host, "sam"); who != pBob {
		t.Errorf("bob's first computer after his second: %q", who)
	}

	// Replay: the same signed request twice.
	d := newDevice(t)
	d.scan(t, h, pBob, "bob-r")
	ts := d.nextTS()
	body := map[string]any{"public_key": d.pub, "ts": ts, "hostname": "bob-r", "os_user": "bob",
		"sig": sshsig(t, d.signer, control.LoginNodeSigNamespace, []byte(control.LoginNodeSigMessage(ts)))}
	if c, raw := postJSON(t, h, control.LoginNodePath, body); c != 200 {
		t.Fatalf("first: %d %s", c, raw)
	}
	if c, raw := postJSON(t, h, control.LoginNodePath, body); c != http.StatusUnauthorized {
		t.Fatalf("replayed: %d %s; want 401", c, raw)
	}

	// A refusal creates nothing and moves no identity.
	var before int
	_ = h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM endpoints`).Scan(&before)
	gen := h.srv.Store.IdentityGen()
	r := newDevice(t)
	r.scan(t, h, pBob, "bob-seat")
	gen = h.srv.Store.IdentityGen() // the scan registers the device
	if c, _ := r.loginNode(t, h, "bob-seat", "_fleetadmin"); c != http.StatusConflict {
		t.Fatalf("the admin role account: %d; want 409", c)
	}
	var after int
	_ = h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM endpoints`).Scan(&after)
	if after != before || h.srv.Store.IdentityGen() != gen {
		t.Errorf("a refused node pass: endpoints %d → %d, identity generation moved %v", before, after, h.srv.Store.IdentityGen() != gen)
	}
}

// A service that ships usage with no login and no machine: its reports never
// move the identity generation, and its enrollment is frozen as a service —
// a later report of root makes it no machine program.
func TestNodeIdentityServiceShipperIsQuiet(t *testing.T) {
	h := bobHarness(t)
	tok := h.enroll(t, "growth-shipper")
	_ = tok
	ep := "ep_growth-shipper"
	ident := model.Identity{AccountUUID: "acct-shipper", Source: model.SourceClaude}
	if err := h.srv.Store.UpsertAccount(ident, "max", ""); err != nil {
		t.Fatal(err)
	}
	if _, _, err := h.srv.Store.TouchEndpoint(ep, ident, "test", true, nil); err != nil {
		t.Fatal(err)
	}
	gen := h.srv.Store.IdentityGen()
	for i := 0; i < 5; i++ {
		if _, _, err := h.srv.Store.TouchEndpoint(ep, ident, "test", true, nil); err != nil {
			t.Fatal(err)
		}
	}
	if g := h.srv.Store.IdentityGen(); g != gen {
		t.Errorf("five shipper reports moved the identity generation %d → %d", gen, g)
	}
	if _, _, err := h.srv.Store.TouchEndpoint(ep, model.Identity{AccountUUID: "acct-shipper", Hostname: "mac-z", OSUser: "root"}, "test", true, nil); err != nil {
		t.Fatal(err)
	}
	if id := h.srv.nodeSelfFrom(mustEndpoint(t, h, ep), "mac-z", "root"); id.Machine || id.machineByLegacy(true) || id.User == "root" {
		t.Errorf("a shipper reporting root later: %+v; want no machine program", id)
	}
}

// What the identity costs, counted: a warm read of a node's identity — a
// device reporting root included — issues no statement; the worker map read
// for a relay link scans the roster once (availability), not again for the
// link's own identity; a machine program's heartbeat with
// a fleet costs at most heartbeatStmtBudget statements in all.
func TestNodeIdentityCountedCost(t *testing.T) {
	h, cnt := countedHarness(t)
	mach := enrollAs(t, h, "mac-a-root", "mac-a", "root")
	dev := memberDeviceNode(t, h, pBob, "bob-ctr", "", false) // a device run as root
	epM, epD := mustEndpoint(t, h, "ep_mac-a-root"), mustEndpoint(t, h, dev.id)
	h.srv.nodeSelfFrom(epM, "mac-a", "root")
	h.srv.nodeSelfFrom(epD, "bob-ctr", "root")
	if q := cnt.measure(func() {
		h.srv.nodeSelfFrom(epM, "mac-a", "root")
		h.srv.nodeSelfFrom(epD, "bob-ctr", "root")
	}); len(q) != 0 {
		t.Errorf("warm identity reads issued %d statements: %v", len(q), q)
	}

	mc := dialHello(t, h, mach, control.Hello{HeartbeatMS: 5000, Capabilities: []string{control.CapMachine, control.CapRelay}})
	f := fakeFleet(t, machineA, "fleet-mac-a", "o/r", "/a", 1)
	hb := control.Heartbeat{Hostname: "mac-a", OSUser: "root", MachineID: machineA, Fleets: []control.Fleet{f}, ObservedAt: time.Now()}
	beat(t, mc.c, control.Proto, hb)
	waitFor(t, 3*time.Second, "the fleet", func() bool { _, err := h.srv.Store.Fleet(f.FleetID); return err == nil })
	nc := h.srv.nodes.get("ep_mac-a-root")
	// workerMap reads the roster once for availability; the link's own
	// identity comes from the link, never a second roster scan.
	// Background readers (the push channel) can only add statements: the
	// fewest of a few runs is the road's own.
	fewest := -1
	for i := 0; i < 5; i++ {
		q := cnt.measure(func() { nc.workersAt.Store(0); h.srv.pushWorkers(*epM, nc) })
		if n := countStmt(q, "status_json FROM nodes"); fewest < 0 || n < fewest {
			fewest = n
		}
	}
	if fewest > 1 {
		t.Errorf("the worker map scanned the roster %d times", fewest)
	}
	const beats = 5
	q := cnt.measure(func() {
		for i := 0; i < beats; i++ {
			hb.ObservedAt = time.Now()
			beat(t, mc.c, control.Proto, hb)
			time.Sleep(150 * time.Millisecond)
		}
	})
	if cnt == nil {
		return // the Postgres leg ran the roads; the counts are SQLite's
	}
	per := len(q) / beats
	t.Logf("statements per machine-program heartbeat (one fleet, warm): %d", per)
	if per > heartbeatStmtBudget {
		t.Errorf("%d statements per heartbeat; want at most %d: %v", per, heartbeatStmtBudget, q)
	}
	if n := countStmt(q, "FROM endpoints WHERE endpoint_id"); n > beats*2 {
		t.Errorf("identity reads on warm beats: %d over %d beats", n, beats)
	}
}

// heartbeatStmtBudget: a machine program's warm heartbeat with one fleet, all
// statements included (roster row, stamps, registry snapshot, leases).
const heartbeatStmtBudget = 24

func hasStmt(q []string, sub string) bool { return countStmt(q, sub) > 0 }

func countStmt(q []string, sub string) int {
	n := 0
	for _, s := range q {
		if strings.Contains(s, sub) {
			n++
		}
	}
	return n
}

// The identity caches stay bounded and forget a node whose link closed.
func TestNodeIdentityCacheBounded(t *testing.T) {
	h := bobHarness(t)
	ep := mustEndpoint(t, h, "ep_"+strings.TrimPrefix(enrollAsID(t, h, "mac-a-root", "mac-a", "root"), "ep_"))
	for i := 0; i < identCacheMax+50; i++ {
		e := *ep
		e.ID = fmt.Sprintf("ep_ghost_%d", i)
		h.srv.identStore(e.ID, "h", "u", h.srv.Store.IdentityGen(), nodeIdent{})
	}
	n := 0
	h.srv.identCache.Range(func(_, _ any) bool { n++; return true })
	if n > identCacheMax {
		t.Errorf("identity cache map holds %d; want at most %d", n, identCacheMax)
	}
}

func enrollAsID(t *testing.T, h *harness, label, host, login string) string {
	t.Helper()
	enrollAs(t, h, label, host, login)
	return "ep_" + label
}

// Writes the generation used to miss move it now, and the security-relevant
// negatives are immediate: an account opened on a machine is a login its
// program speaks for at once; an admin's demotion makes their linked computer
// a member's device at once.
func TestNodeIdentityCacheFollowsAccountsAndRoles(t *testing.T) {
	h := bobHarness(t)
	enrollAs(t, h, "mac-a-root", "mac-a", "root")
	ep := mustEndpoint(t, h, "ep_mac-a-root")
	if id := h.srv.nodeSelfFrom(ep, "mac-a", "carol"); id.User != "root" {
		t.Fatalf("before carol's account: %s", id.User)
	}
	if err := h.srv.changeAccount(FleetAccountRequest{Action: "adopt", PrincipalID: pCarol, Hostname: "mac-a", Login: "carol"}, "test"); err != nil {
		t.Fatal(err)
	}
	if id := h.srv.nodeSelfFrom(ep, "mac-a", "carol"); id.User != "carol" {
		t.Errorf("after carol's account on mac-a: %s; want carol at once", id.User)
	}

	h.srv.Admins = append(h.srv.Admins, pCarol)
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pCarol, Hostname: "mac-e", Login: "carol"}); code != 200 {
		t.Fatalf("adopt carol: %d", code)
	}
	cd := memberDeviceNode(t, h, pCarol, "carol-mbp", "carol", false)
	if h.srv.memberDevice(cd.id) {
		t.Fatalf("an admin's device read as a member's")
	}
	// Demote her once nothing of hers is being served (the list is the
	// server's configuration, read by every link).
	cd.c.CloseNow()
	waitFor(t, 3*time.Second, "carol's link gone", func() bool { return h.srv.nodes.get(cd.id) == nil })
	h.srv.Admins = h.srv.Admins[:len(h.srv.Admins)-1]
	if !h.srv.memberDevice(cd.id) {
		t.Errorf("after carol's demotion her device is still read as an admin's")
	}
}

// A device login the door, entry relay and peer certificates do not serve is
// said on the node pass; the node is still its person's.
func TestNodeIdentityDeviceLoginEntryNote(t *testing.T) {
	h := bobHarness(t)
	d := newDevice(t)
	d.scan(t, h, pBob, "bob-jd")
	code, out := d.loginNode(t, h, "bob-jd", "John_Doe")
	if code != 200 {
		t.Fatalf("John_Doe: %d %v", code, out)
	}
	if note, _ := out["entry_note"].(string); !strings.Contains(note, "John_Doe") {
		t.Errorf("John_Doe's node pass says nothing of SSH entry: %v", out)
	}
	if who, err := h.srv.principalOnNode(out["endpoint_id"].(string), "bob-jd", "John_Doe"); err != nil || who != pBob {
		t.Errorf("John_Doe's node: %q %v; want Bob's", who, err)
	}
	c2, out2 := newDeviceScanned(t, h, pBob, "bob-ok").loginNode(t, h, "bob-ok", "bob")
	if c2 != 200 || out2["entry_note"] != nil {
		t.Errorf("an ordinary login carries an entry note: %d %v", c2, out2)
	}
	_ = json.Valid
}

func newDeviceScanned(t *testing.T, h *harness, pid, host string) *device {
	t.Helper()
	d := newDevice(t)
	d.scan(t, h, pid, host)
	return d
}

// grindDevice generates device keys until one's fingerprint gives the 4-hex
// suffix want (deviceHosts' first suffix) — what a member could do offline.
func grindDevice(t *testing.T, want string) *device {
	t.Helper()
	for i := 0; i < 1<<20; i++ {
		d := newDevice(t)
		sum := sha256.Sum256([]byte(d.fp))
		if hex.EncodeToString(sum[:2]) == want {
			return d
		}
	}
	t.Fatalf("no key ground for %s", want)
	return nil
}

func enrolledHostOf(t *testing.T, h *harness, ep string) string {
	t.Helper()
	et, err := h.srv.Store.EndpointTrustOf(ep)
	if err != nil {
		t.Fatal(err)
	}
	return et.EnrolledHost
}

// A ground fingerprint never buys another device's suffixed name: the final
// name is checked like the reported one and the next, longer suffix is taken.
// And should two links ever share a machine and login (an older hub's rows),
// a person's chat, terminal, entry and SSH relays pick only their own
// person's device — with the owner offline, none — and a device never takes
// a trusted name another endpoint enrolled as.
func TestNodeIdentityGroundSuffixBuysNothing(t *testing.T) {
	h := bobHarness(t)
	memberDeviceNode(t, h, pBob, "mbp", "bob", false) // Bob takes mbp
	ad := newDevice(t)
	ad.scan(t, h, pAlice, "mbp")
	code, out := ad.loginNode(t, h, "mbp", "alice")
	if code != 200 {
		t.Fatalf("alice's device: %d %v", code, out)
	}
	alice := &fleetNode{token: out["token"].(string), id: out["endpoint_id"].(string)}
	aliceHost := enrolledHostOf(t, h, alice.id)
	if !strings.HasPrefix(aliceHost, "mbp-") || len(aliceHost) != len("mbp-")+4 {
		t.Fatalf("alice's device enrolled as %q; want mbp-<4 hex>", aliceHost)
	}

	g := grindDevice(t, aliceHost[len("mbp-"):])
	g.scan(t, h, pBob, "mbp")
	code, out = g.loginNode(t, h, "mbp", "alice")
	if code != 200 {
		t.Fatalf("bob's ground device: %d %v", code, out)
	}
	bobG := out["endpoint_id"].(string)
	if got := enrolledHostOf(t, h, bobG); strings.EqualFold(got, aliceHost) {
		t.Errorf("bob's ground key enrolled as alice's %s", got)
	}

	// An older hub's duplicate: force Bob's ground node onto Alice's name.
	if _, err := h.srv.Store.DB().Exec(`UPDATE endpoints SET enrolled_host = ? WHERE endpoint_id = ?`, aliceHost, bobG); err != nil {
		t.Fatal(err)
	}
	h.srv.Store.TouchIdentity()
	caps := []string{control.CapChat, control.CapTerm, control.CapSSHRelay, control.CapEntryRelay}
	bc := dialHello(t, h, out["token"].(string), control.Hello{HeartbeatMS: 5000, Capabilities: caps})
	beat(t, bc.c, control.Proto, control.Heartbeat{Hostname: "mbp", OSUser: "alice"})
	waitFor(t, 3*time.Second, "bob's ground link as alice@"+aliceHost, func() bool {
		c := h.srv.nodes.get(bobG)
		return c != nil && c.hostname() == aliceHost && c.user() == "alice"
	})
	if who := h.srv.loginOwner(aliceHost, "alice"); who != pAlice {
		t.Fatalf("owner of alice@%s = %q", aliceHost, who)
	}
	for name, pick := range map[string]func() (string, *nodeConn, error){
		"chat":     func() (string, *nodeConn, error) { return h.srv.chatRelayNode(aliceHost, "alice") },
		"terminal": func() (string, *nodeConn, error) { return h.srv.termRelayNode(aliceHost, "alice") },
		"entry":    func() (string, *nodeConn, error) { return h.srv.entryRelayNode(aliceHost, "alice") },
		"peer ssh": func() (string, *nodeConn, error) { return h.srv.peerSSHRelayNode(aliceHost, "alice") },
		"ssh relay": func() (string, *nodeConn, error) {
			return h.srv.sshRelayNode(sshRelayIdentity{Principal: pAlice}, aliceHost)
		},
	} {
		if id, _, err := pick(); err == nil && id == bobG {
			t.Errorf("%s for alice@%s (her node offline) picked bob's device", name, aliceHost)
		}
	}
	// Alice's view of her machine never lists Bob's device's fleet.
	f := fakeFleet(t, machineC, "fleet-g", "o/r", "/g", 1)
	beat(t, bc.c, control.Proto, control.Heartbeat{Hostname: "mbp", OSUser: "alice", MachineID: machineC,
		Fleets: []control.Fleet{f}, ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, "the ground fleet", func() bool { _, err := h.srv.Store.Fleet(f.FleetID); return err == nil })
	scope := func(host, user string) bool { return strings.EqualFold(host, aliceHost) && user == "alice" }
	_, rows, err := h.srv.visibleFleets(fleetPrincipal{Actor: pAlice, Person: pAlice, scope: scope}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rows {
		if r.EndpointID == bobG {
			t.Errorf("alice's view lists bob's device's fleet")
		}
	}

	// Trust: Carol (an admin) has a device whose name the operator trusts; a
	// member's device enrolled under that same name inherits nothing.
	h.srv.Admins = append(h.srv.Admins, pCarol)
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pCarol, Hostname: "mac-e", Login: "carol"}); code != 200 {
		t.Fatalf("adopt carol: %d", code)
	}
	cd := memberDeviceNode(t, h, pCarol, "carol-mini", "carol", false)
	trustMachines(t, h, "carol-mini")
	mb := memberDeviceNode(t, h, pBob, "bob-mini", "bob", false)
	if _, err := h.srv.Store.DB().Exec(`UPDATE endpoints SET enrolled_host = 'carol-mini' WHERE endpoint_id = ?`, mb.id); err != nil {
		t.Fatal(err)
	}
	h.srv.Store.TouchIdentity()
	settings, _ := h.srv.trustSettings(time.Now())
	if tr, src := h.srv.endpointTrust(mb.id, "carol-mini", settings); tr == TrustTrusted {
		t.Errorf("a member's device on carol-mini's name: %s (%s); want untrusted", tr, src)
	}
	_ = cd
}

// Two devices enrolling under one reported name at the same moment end on two
// names — the store refuses the second at the insert, atomically.
func TestNodeIdentityConcurrentDeviceNames(t *testing.T) {
	h := bobHarness(t)
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pCarol, Hostname: "mac-e", Login: "carol"}); code != 200 {
		t.Fatalf("adopt carol: %d", code)
	}
	for round := 0; round < 5; round++ {
		name := fmt.Sprintf("race-%d", round)
		devs := []*device{newDeviceScanned(t, h, pBob, name), newDeviceScanned(t, h, pCarol, name)}
		logins := []string{"bob", "carol"}
		eps := make([]string, 2)
		var wg sync.WaitGroup
		for i := range devs {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				code, out := devs[i].loginNode(t, h, name, logins[i])
				if code == 200 {
					eps[i], _ = out["endpoint_id"].(string)
				}
			}(i)
		}
		wg.Wait()
		if eps[0] == "" || eps[1] == "" {
			t.Fatalf("round %d: a device got no node: %v", round, eps)
		}
		if a, b := enrolledHostOf(t, h, eps[0]), enrolledHostOf(t, h, eps[1]); strings.EqualFold(a, b) {
			t.Fatalf("round %d: both devices enrolled as %s", round, a)
		}
	}
}

// Small rules: a replayed node pass says so; a seat is matched by the full
// enrolled name (mac-a.home's program never takes mac-a.office's seat).
func TestNodeIdentityReplayCodeAndFullSeatName(t *testing.T) {
	h := bobHarness(t)
	h.srv.FleetAdmins = []string{"_fleetadmin"}
	d := newDeviceScanned(t, h, pBob, "bob-r2")
	ts := d.nextTS()
	body := map[string]any{"public_key": d.pub, "ts": ts, "hostname": "bob-r2", "os_user": "bob",
		"sig": sshsig(t, d.signer, control.LoginNodeSigNamespace, []byte(control.LoginNodeSigMessage(ts)))}
	postJSON(t, h, control.LoginNodePath, body)
	c, raw := postJSON(t, h, control.LoginNodePath, body)
	var out map[string]any
	_ = json.Unmarshal(raw, &out)
	if c != http.StatusUnauthorized || out["code"] != "request_replayed" {
		t.Errorf("replayed: %d %v; want 401 request_replayed", c, out)
	}

	office, _ := h.srv.issueAdminToken(httptest.NewRequest(http.MethodPost, "/", nil), "mac-a.office", "_fleetadmin", "", time.Now())
	home := enrollAs(t, h, "mac-a-home-root", "mac-a.home", "root")
	st, seat, raw2 := adminTokenCall(t, h, home, http.MethodPost, map[string]string{"login": "_fleetadmin"})
	if st != 200 || seat.EndpointID == office.EndpointID {
		t.Errorf("mac-a.home's program: %d %+v %s; want a seat of its own, never mac-a.office's", st, seat, raw2)
	}
}
