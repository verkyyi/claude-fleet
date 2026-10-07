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
	for _, host := range []string{"m5", "m4"} {
		if _, has := machines[host]["compute_off"]; has {
			t.Fatalf("%s machine carries compute_off with nothing set: %v", host, machines[host])
		}
		if _, has := nodes[host]["compute_off"]; has {
			t.Fatalf("%s node carries compute_off with nothing set: %v", host, nodes[host])
		}
	}
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "m4" {
		t.Fatalf("placement with nothing set: %q %v; want m4", pl.Machine, err)
	}
}

// A heartbeat saying compute=false takes the login out of placement — auto
// and named — and the roster says 只协调; compute back on puts it back.
func TestComputeOffNodeIsNeverPlaced(t *testing.T) {
	h, m5, m4, f5, f4 := twoNodes(t)
	// m4 is the better machine; only compute=0 can keep work off it.
	m5.beatLoad("m5", "verk", machineA, 5, 1, f5)
	m4.beatCompute("m4", "verk", machineB, 0.5, computeOff(), f4)
	waitFor(t, 3*time.Second, "m4 reports compute off", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_m4", time.Now())
		return !control.ComputeOn(hb.Compute)
	})
	waitLoad(t, h, "m5", 5)
	pl, err := h.srv.PickNode("", writeRepo)
	if err != nil || pl.Machine != "m5" || !strings.Contains(pl.Reason, "m4 excluded: "+excludedComputeOff) {
		t.Fatalf("auto placement = %q %q %v; want m5 with m4 excluded as compute off", pl.Machine, pl.Reason, err)
	}
	st, out := placeCall(t, h, h.tokens["m5"], map[string]any{"repo": writeRepo, "issue": 31,
		"worker_id": issueWID(f5.FleetID, 31), "node": "m4"})
	e, _ := out["error"].(map[string]any)
	if st != 503 || e["code"] != "NO_ELIGIBLE_NODE" || !strings.Contains(e["message"].(string), "compute off") {
		t.Fatalf("named place on m4 = %d %v; want NO_ELIGIBLE_NODE naming compute off", st, out)
	}
	if m4.count() != 0 {
		t.Fatalf("m4 got %d writes; want none", m4.count())
	}
	machines, nodes := nodeStatuses(t, h)
	if nodes["m4"]["compute_off"] != true || machines["m4"]["compute_off"] != true {
		t.Fatalf("roster: machine %v node %v; want compute_off on m4", machines["m4"], nodes["m4"])
	}
	if _, has := nodes["m5"]["compute_off"]; has {
		t.Fatalf("m5 node carries compute_off: %v", nodes["m5"])
	}

	m4.beatCompute("m4", "verk", machineB, 0.5, nil, f4)
	waitFor(t, 3*time.Second, "m4 compute back on", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_m4", time.Now())
		return control.ComputeOn(hb.Compute)
	})
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "m4" {
		t.Fatalf("after compute on: %q %v; want m4", pl.Machine, err)
	}
}

// The hello alone is enough: a login that said compute=false at connect is
// out even while its heartbeats say nothing.
func TestComputeOffHelloIsHonoured(t *testing.T) {
	h := newFleetHarness(t)
	m5 := connectWriteNode(t, h, "m5")
	c := dialNode(t, h, h.enroll(t, "m4"))
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
	m4 := &writeNode{t: t, conn: c, answer: accepted}
	go m4.serve()
	f5 := fakeFleet(t, machineA, "fleet-m5", writeRepo, "/u/verk/claude-fleet", 1)
	f4 := fakeFleet(t, machineB, "fleet-m4", writeRepo, "/u/verk/claude-fleet", 2)
	m5.beatLoad("m5", "verk", machineA, 5, 1, f5)
	m4.beatLoad("m4", "verk", machineB, 0.5, 1, f4)
	waitFor(t, 3*time.Second, "both fleets registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "m5" {
		t.Fatalf("placement = %q %v; want m5 (m4's hello said compute off)", pl.Machine, err)
	}
	if _, nodes := nodeStatuses(t, h); nodes["m4"]["compute_off"] != true {
		t.Fatalf("roster node m4 = %v; want compute_off", nodes["m4"])
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
	if err := h.srv.Store.NodeConnected(ep.ID, "m4", "alice", "test", control.Proto, 60000, time.Now()); err != nil {
		t.Fatal(err)
	}
	setBeat := func(compute *bool) {
		raw, _ := json.Marshal(control.Heartbeat{Hostname: "m4", OSUser: "alice", Compute: compute, ObservedAt: time.Now()})
		if err := h.srv.Store.NodeHeartbeat(ep.ID, "m4", "alice", "", control.Proto, string(raw), time.Now()); err != nil {
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
