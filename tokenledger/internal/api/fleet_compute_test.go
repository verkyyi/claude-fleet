package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
)

// 只协调 (claude-fleet#1719, EPIC #1718 C1): a login started with
// CCQUOTA_FLEET_COMPUTE=0 heartbeats, holds its identity and certificates, and
// is never placed on nor leased an account.

func computeOff() *bool { f := false; return &f }

// beatCompute is beatLoad with the heartbeat's Compute set.
func (n *writeNode) beatCompute(host, user, machine string, load1 float64, compute *bool, fleets ...control.Fleet) {
	beat(n.t, n.conn, control.Proto, control.Heartbeat{Hostname: host, OSUser: user, MachineID: machine,
		Load1: load1, NCPU: 10, MemFreeBytes: 8 << 30, MemTotalBytes: 16 << 30, Sessions: 1,
		Fleets: fleets, Compute: compute, ObservedAt: time.Now()})
}

// The degenerate case: no node says anything about compute — the roster
// carries no compute_off key and placement is what it always was.
func TestComputeUnsetAddsNothing(t *testing.T) {
	h, _, _, _, _ := twoNodes(t)
	machines, nodes := nodeStatuses(t, h)
	for _, host := range []string{"mac-d", "mac-c"} {
		if _, has := machines[host]["compute_off"]; has {
			t.Fatalf("%s machine carries compute_off with nothing set: %v", host, machines[host])
		}
		if _, has := nodes[host]["compute_off"]; has {
			t.Fatalf("%s node carries compute_off with nothing set: %v", host, nodes[host])
		}
	}
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-c" {
		t.Fatalf("placement with nothing set: %q %v; want mac-c", pl.Machine, err)
	}
}

// A heartbeat saying compute=false takes the login out of placement — auto
// and named — and the roster says 只协调; compute back on puts it back.
func TestComputeOffNodeIsNeverPlaced(t *testing.T) {
	h, macD, macC, f5, f4 := twoNodes(t)
	// mac-c is the better machine; only compute=0 can keep work off it.
	macD.beatLoad("mac-d", "frank", machineA, 5, 1, f5)
	macC.beatCompute("mac-c", "frank", machineB, 0.5, computeOff(), f4)
	waitFor(t, 3*time.Second, "mac-c reports compute off", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_mac-c", time.Now())
		return !control.ComputeOn(hb.Compute)
	})
	waitLoad(t, h, "mac-d", 5)
	pl, err := h.srv.PickNode("", writeRepo)
	if err != nil || pl.Machine != "mac-d" || !strings.Contains(pl.Reason, "mac-c excluded: "+excludedComputeOff) {
		t.Fatalf("auto placement = %q %q %v; want mac-d with mac-c excluded as compute off", pl.Machine, pl.Reason, err)
	}
	st, out := placeCall(t, h, h.tokens["mac-d"], map[string]any{"repo": writeRepo, "issue": 31,
		"worker_id": issueWID(f5.FleetID, 31), "node": "mac-c"})
	e, _ := out["error"].(map[string]any)
	if st != 503 || e["code"] != "NO_ELIGIBLE_NODE" || !strings.Contains(e["message"].(string), "compute off") {
		t.Fatalf("named place on mac-c = %d %v; want NO_ELIGIBLE_NODE naming compute off", st, out)
	}
	if macC.count() != 0 {
		t.Fatalf("mac-c got %d writes; want none", macC.count())
	}
	machines, nodes := nodeStatuses(t, h)
	if nodes["mac-c"]["compute_off"] != true || machines["mac-c"]["compute_off"] != true {
		t.Fatalf("roster: machine %v node %v; want compute_off on mac-c", machines["mac-c"], nodes["mac-c"])
	}
	if _, has := nodes["mac-d"]["compute_off"]; has {
		t.Fatalf("mac-d node carries compute_off: %v", nodes["mac-d"])
	}

	macC.beatCompute("mac-c", "frank", machineB, 0.5, nil, f4)
	waitFor(t, 3*time.Second, "mac-c compute back on", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_mac-c", time.Now())
		return control.ComputeOn(hb.Compute)
	})
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-c" {
		t.Fatalf("after compute on: %q %v; want mac-c", pl.Machine, err)
	}
}

// The hello alone is enough: a login that said compute=false at connect is
// out even while its heartbeats say nothing.
func TestComputeOffHelloIsHonoured(t *testing.T) {
	h := newFleetHarness(t)
	macD := connectWriteNode(t, h, "mac-d")
	c := dialNode(t, h, h.enroll(t, "mac-c"))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	m, _ := control.New(control.TypeHello, control.Hello{HeartbeatMS: 60000, AgentVersion: "test",
		Capabilities: []string{control.CapRead, control.CapWrite}, Compute: computeOff()})
	if err := wsjson.Write(ctx, c, m); err != nil {
		t.Fatal(err)
	}
	var reply control.Message
	if err := wsjson.Read(ctx, c, &reply); err != nil || reply.Type != control.TypeWelcome {
		t.Fatalf("hello: %v %+v", err, reply)
	}
	macC := &writeNode{t: t, conn: c, answer: accepted}
	go macC.serve()
	f5 := fakeFleet(t, machineA, "fleet-mac-d", writeRepo, "/u/frank/claude-fleet", 1)
	f4 := fakeFleet(t, machineB, "fleet-mac-c", writeRepo, "/u/frank/claude-fleet", 2)
	macD.beatLoad("mac-d", "frank", machineA, 5, 1, f5)
	macC.beatLoad("mac-c", "frank", machineB, 0.5, 1, f4)
	waitFor(t, 3*time.Second, "both fleets registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-d" {
		t.Fatalf("placement = %q %v; want mac-d (mac-c's hello said compute off)", pl.Machine, err)
	}
	if _, nodes := nodeStatuses(t, h); nodes["mac-c"]["compute_off"] != true {
		t.Fatalf("roster node mac-c = %v; want compute_off", nodes["mac-c"])
	}
}

// A login that only coordinates borrows no account: its lease is refused
// (and audited) while it says compute=false, and answered again once it no
// longer does.
func TestComputeOffNodeCannotLease(t *testing.T) {
	h, tok, _ := newVaultHarness(t)
	putCred(t, h, credvault.Claude, "main", credvault.Secret{RefreshToken: "rt"})
	if code, _, _ := lease(t, h, tok); code != http.StatusOK {
		t.Fatalf("before compute off: %d", code)
	}
	ep, err := h.srv.Store.EndpointByTokenHash(HashToken(tok))
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.NodeConnected(ep.ID, "mac-c", "alice", "test", control.Proto, 60000, time.Now()); err != nil {
		t.Fatal(err)
	}
	setBeat := func(compute *bool) {
		raw, _ := json.Marshal(control.Heartbeat{Hostname: "mac-c", OSUser: "alice", Compute: compute, Credsep: control.CredsepSeparated, ObservedAt: time.Now()})
		if err := h.srv.Store.NodeHeartbeat(ep.ID, "mac-c", "alice", "", control.Proto, string(raw), time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	setBeat(computeOff())
	code, _, refusal := lease(t, h, tok)
	if code != http.StatusForbidden || refusal["error"] != LeaseComputeOff {
		t.Fatalf("compute off: %d %v; want 403 %s", code, refusal, LeaseComputeOff)
	}
	setBeat(nil)
	if code, _, refusal := lease(t, h, tok); code != http.StatusOK {
		t.Fatalf("compute back on: %d %v", code, refusal)
	}
}

// claude-fleet#2661: a 只协调 exclusion says which report carried the off —
// the beat's time and agent build — and, when the login's link keeps changing
// hands (two agents of one login, each with its own word), how often.
func TestComputeOffReasonNamesItsSource(t *testing.T) {
	h, macD, macC, f5, f4 := twoNodes(t)
	at := time.Date(2026, 10, 9, 15, 11, 2, 0, time.UTC)
	macD.beatLoad("mac-d", "frank", machineA, 5, 1, f5)
	beat(t, macC.conn, control.Proto, control.Heartbeat{Hostname: "mac-c", OSUser: "frank", MachineID: machineB,
		Load1: 0.5, NCPU: 10, MemFreeBytes: 8 << 30, MemTotalBytes: 16 << 30, Sessions: 1,
		Fleets: []control.Fleet{f4}, Compute: computeOff(), ObservedAt: at, AgentVersion: "v-stale"})
	waitFor(t, 3*time.Second, "mac-c reports compute off", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_mac-c", time.Now())
		return !control.ComputeOn(hb.Compute)
	})
	waitLoad(t, h, "mac-d", 5)
	pl, err := h.srv.PickNode("", writeRepo)
	want := "mac-c excluded: " + excludedComputeOff + " · reported 15:11:02Z by agent v-stale heartbeat"
	if err != nil || pl.Machine != "mac-d" || !strings.Contains(pl.Reason, want) {
		t.Fatalf("placement = %q %q %v; want mac-d with %q", pl.Machine, pl.Reason, err, want)
	}
	if strings.Contains(pl.Reason, "被顶替") {
		t.Fatalf("one link, never displaced: %q", pl.Reason)
	}
	// A second agent of the same login takes the link: the reason counts it.
	m4b := connectWriteNodeTok(t, h, h.tokens["mac-c"])
	beat(t, m4b.conn, control.Proto, control.Heartbeat{Hostname: "mac-c", OSUser: "frank", MachineID: machineB,
		Load1: 0.5, NCPU: 10, MemFreeBytes: 8 << 30, MemTotalBytes: 16 << 30, Sessions: 1,
		Fleets: []control.Fleet{f4}, Compute: computeOff(), ObservedAt: at, AgentVersion: "v-stale"})
	waitFor(t, 3*time.Second, "the link changed hands", func() bool {
		return h.srv.nodes.supersededSince("ep_mac-c", time.Now()) == 1
	})
	pl, err = h.srv.PickNode("", writeRepo)
	if err != nil || !strings.Contains(pl.Reason, "被顶替 1 次") {
		t.Fatalf("placement = %q %v; want the displaced link counted", pl.Reason, err)
	}
}

// The source names the hello when only the hello said off.
func TestComputeOffReasonHello(t *testing.T) {
	if got := reportedBy("hello", time.Date(2026, 10, 9, 15, 0, 1, 0, time.UTC), "1.2.3"); got != "reported 15:00:01Z by agent 1.2.3 hello" {
		t.Fatalf("reportedBy = %q", got)
	}
	if got := reportedBy("heartbeat", time.Time{}, ""); got != "reported heartbeat" {
		t.Fatalf("reportedBy with nothing known = %q", got)
	}
	v := computeVerdict{Off: true, Why: excludedComputeOff}
	if v.Reason() != excludedComputeOff {
		t.Fatalf("no source: Reason %q, want Why alone", v.Reason())
	}
}
