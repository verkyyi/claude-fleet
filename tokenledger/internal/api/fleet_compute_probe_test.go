package api

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/findings"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// 能不能跑 (claude-fleet#1720, EPIC #1718 C2): the probe and the team policy
// fleet.compute_auto, beside the login's own word (#1719).

func probe(loc, verdict string) *control.NodeProbe {
	return &control.NodeProbe{Loc: loc, Anthropic: "reachable", OpenAI: "reachable", TS: time.Now().UTC(),
		Verdict: verdict, Reason: "egress " + loc + ": " + verdict}
}

func computeOn() *bool { t := true; return &t }

// beatProbe is beatLoad with the heartbeat's compute fields and probe set.
func (n *writeNode) beatProbe(host, user, machine string, compute *bool, force bool, p *control.NodeProbe, fleets ...control.Fleet) {
	beat(n.t, n.conn, control.Proto, control.Heartbeat{Hostname: host, OSUser: user, MachineID: machine,
		Load1: 0.5, NCPU: 10, MemFreeBytes: 8 << 30, MemTotalBytes: 16 << 30, Sessions: 1,
		Fleets: fleets, Compute: compute, ComputeForce: force, Probe: p, ObservedAt: time.Now()})
}

func waitProbe(t *testing.T, h *harness, ep, verdict string, force bool) {
	t.Helper()
	waitFor(t, 3*time.Second, ep+" reports its probe", func() bool {
		hb, _, _ := h.srv.nodeStatusOf(ep, time.Now())
		return hb.Probe != nil && hb.Probe.Verdict == verdict && hb.ComputeForce == force
	})
}

func computeFindings(t *testing.T, h *harness) []findings.Finding {
	t.Helper()
	in, err := h.srv.GatherNow(store.AllAccounts)
	if err != nil {
		t.Fatal(err)
	}
	var out []findings.Finding
	for _, f := range findings.Now(in) {
		if f.Kind == "compute_region" {
			out = append(out, f)
		}
	}
	return out
}

// 境内地区 → unsupported_region: a login that asked to run (here: a node from
// before #1719, no compute word at all) is closed — never placed, auto or
// named — the roster says why, and the compute_region finding raises the
// alert. Back in a supported region it runs again and the alert clears.
func TestComputeRegionClosesAndAlerts(t *testing.T) {
	h, macD, macC, f5, f4 := twoNodes(t)
	macD.beatLoad("mac-d", "frank", machineA, 5, 1, f5)
	waitLoad(t, h, "mac-d", 5)
	macC.beatProbe("mac-c", "frank", machineB, nil, false, probe("CN", control.ProbeUnsupportedRegion), f4)
	waitProbe(t, h, "ep_mac-c", control.ProbeUnsupportedRegion, false)

	pl, err := h.srv.PickNode("", writeRepo)
	if err != nil || pl.Machine != "mac-d" || !strings.Contains(pl.Reason, "mac-c excluded: compute off (出口地区 CN") {
		t.Fatalf("auto placement = %q %q %v; want mac-d, mac-c excluded by region", pl.Machine, pl.Reason, err)
	}
	st, out := placeCall(t, h, h.tokens["mac-d"], map[string]any{"repo": writeRepo, "issue": 41,
		"worker_id": issueWID(f5.FleetID, 41), "node": "mac-c"})
	if e, _ := out["error"].(map[string]any); st != 503 || e["code"] != "NO_ELIGIBLE_NODE" {
		t.Fatalf("named place on mac-c = %d %v; want NO_ELIGIBLE_NODE", st, out)
	}
	_, nodes := nodeStatuses(t, h)
	if nodes["mac-c"]["compute_off"] != true || nodes["mac-c"]["compute_closed"] != true ||
		!strings.Contains(nodes["mac-c"]["compute_why"].(string), "CN") {
		t.Fatalf("roster mac-c = %v; want compute_off + compute_closed naming CN", nodes["mac-c"])
	}
	fs := computeFindings(t, h)
	if len(fs) != 1 || fs[0].Severity != "warning" || !strings.Contains(fs[0].Title, "frank@mac-c") || !strings.Contains(fs[0].Title, "CN") {
		t.Fatalf("compute_region findings = %+v; want one warning naming frank@mac-c and CN", fs)
	}

	macC.beatProbe("mac-c", "frank", machineB, nil, false, probe("US", control.ProbeOK), f4)
	waitProbe(t, h, "ep_mac-c", control.ProbeOK, false)
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-c" {
		t.Fatalf("back in a supported region: %q %v; want mac-c", pl.Machine, err)
	}
	if fs := computeFindings(t, h); len(fs) != 0 {
		t.Fatalf("alert after the region came back: %+v", fs)
	}
}

// 支持地区 + 可达, compute off, policy off → only a hint, never opened; the
// policy on opens it; a stale probe or an unreachable one does not.
func TestComputeAutoOpensOnlyByPolicy(t *testing.T) {
	h, macD, macC, f5, f4 := twoNodes(t)
	macD.beatLoad("mac-d", "frank", machineA, 5, 1, f5)
	waitLoad(t, h, "mac-d", 5)
	macC.beatProbe("mac-c", "frank", machineB, computeOff(), false, probe("US", control.ProbeOK), f4)
	waitProbe(t, h, "ep_mac-c", control.ProbeOK, false)
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-d" {
		t.Fatalf("policy off: %q %v; want mac-d (an ok probe only hints)", pl.Machine, err)
	}
	if fs := computeFindings(t, h); len(fs) != 0 {
		t.Fatalf("a coordinate-only node is no alert: %+v", fs)
	}

	putSetting(t, h, ComputeAutoKey, "maybe", 400)
	putSetting(t, h, ComputeAutoKey, "on", 200)
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-c" {
		t.Fatalf("compute_auto=on: %q %v; want mac-c opened by policy", pl.Machine, err)
	}
	if _, nodes := nodeStatuses(t, h); nodes["mac-c"]["compute_auto"] != true {
		t.Fatalf("roster mac-c = %v; want compute_auto", nodes["mac-c"])
	}

	stale := probe("US", control.ProbeOK)
	stale.TS = time.Now().Add(-3 * 24 * time.Hour)
	macC.beatProbe("mac-c", "frank", machineB, computeOff(), false, stale, f4)
	waitFor(t, 3*time.Second, "stale probe", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_mac-c", time.Now())
		return hb.Probe != nil && time.Since(hb.Probe.TS) > probeFreshFor
	})
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-d" {
		t.Fatalf("stale probe: %q %v; want mac-d", pl.Machine, err)
	}
	macC.beatProbe("mac-c", "frank", machineB, computeOff(), false, probe("US", control.ProbeUnreachable), f4)
	waitProbe(t, h, "ep_mac-c", control.ProbeUnreachable, false)
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-d" {
		t.Fatalf("unreachable probe: %q %v; want mac-d", pl.Machine, err)
	}
	// Policy on never opens a login in an unsupported region, and that
	// login asked for nothing, so it is no alert either.
	macC.beatProbe("mac-c", "frank", machineB, computeOff(), false, probe("CN", control.ProbeUnsupportedRegion), f4)
	waitProbe(t, h, "ep_mac-c", control.ProbeUnsupportedRegion, false)
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-d" {
		t.Fatalf("region + policy: %q %v; want mac-d", pl.Machine, err)
	}
	if fs := computeFindings(t, h); len(fs) != 0 {
		t.Fatalf("a coordinate-only node in CN is no alert: %+v", fs)
	}
}

// An unreachable API never closes a login that asked to run — weather, not a
// rule; --force keeps a login open over its region and lands in fleet_audit
// once per link.
func TestComputeUnreachableAndForce(t *testing.T) {
	h, macD, macC, f5, f4 := twoNodes(t)
	macD.beatLoad("mac-d", "frank", machineA, 5, 1, f5)
	waitLoad(t, h, "mac-d", 5)
	macC.beatProbe("mac-c", "frank", machineB, computeOn(), false, probe("US", control.ProbeUnreachable), f4)
	waitProbe(t, h, "ep_mac-c", control.ProbeUnreachable, false)
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-c" {
		t.Fatalf("unreachable, compute on: %q %v; want mac-c kept", pl.Machine, err)
	}

	for i := 0; i < 2; i++ {
		macC.beatProbe("mac-c", "frank", machineB, computeOn(), true, probe("CN", control.ProbeUnsupportedRegion), f4)
	}
	waitProbe(t, h, "ep_mac-c", control.ProbeUnsupportedRegion, true)
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-c" {
		t.Fatalf("forced: %q %v; want mac-c", pl.Machine, err)
	}
	if fs := computeFindings(t, h); len(fs) != 0 {
		t.Fatalf("a forced login is no alert: %+v", fs)
	}
	var n int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action = 'compute_force' AND outcome LIKE '%unsupported_region%'`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("compute_force audit rows = %d %v; want exactly 1", n, err)
	}
}

// `fleet node compute on` with no reconnect: the hello said off, a beat that
// says compute=true opens the login.
func TestComputeBeatOverridesHello(t *testing.T) {
	h := newFleetHarness(t)
	macD := connectWriteNode(t, h, "mac-d")
	macC := connectWriteNodeHello(t, h, "mac-c", control.Hello{HeartbeatMS: 60000, AgentVersion: "test",
		Capabilities: []string{control.CapRead, control.CapWrite}, Compute: computeOff()})
	f5 := fakeFleet(t, machineA, "fleet-mac-d", writeRepo, "/u/frank/claude-fleet", 1)
	f4 := fakeFleet(t, machineB, "fleet-mac-c", writeRepo, "/u/frank/claude-fleet", 2)
	macD.beatLoad("mac-d", "frank", machineA, 5, 1, f5)
	waitLoad(t, h, "mac-d", 5)
	macC.beatProbe("mac-c", "frank", machineB, computeOff(), false, nil, f4)
	waitFor(t, 3*time.Second, "both fleets registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-d" {
		t.Fatalf("hello off: %q %v; want mac-d", pl.Machine, err)
	}
	macC.beatProbe("mac-c", "frank", machineB, computeOn(), false, nil, f4)
	waitFor(t, 3*time.Second, "mac-c says compute on", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_mac-c", time.Now())
		return hb.Compute != nil && *hb.Compute
	})
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-c" {
		t.Fatalf("beat said on: %q %v; want mac-c", pl.Machine, err)
	}
}

// The rule itself, every row.
func TestDecideCompute(t *testing.T) {
	now := time.Now()
	ok, cn, down := probe("US", control.ProbeOK), probe("CN", control.ProbeUnsupportedRegion), probe("US", control.ProbeUnreachable)
	for _, c := range []struct {
		name                  string
		claimOn, force, auto  bool
		p                     *control.NodeProbe
		off, autoOpen, closed bool
	}{
		{"no probe, on (#1719)", true, false, false, nil, false, false, false},
		{"no probe, off (#1719)", false, false, true, nil, true, false, false},
		{"ok, off, policy off", false, false, false, ok, true, false, false},
		{"ok, off, policy on", false, false, true, ok, false, true, false},
		{"region, on", true, false, false, cn, true, false, true},
		{"region, off", false, false, true, cn, true, false, false},
		{"region, forced", true, true, false, cn, false, false, false},
		{"unreachable, on", true, false, false, down, false, false, false},
		{"unreachable, off, policy on", false, false, true, down, true, false, false},
	} {
		v := decideCompute(c.claimOn, c.force, c.p, c.auto, now)
		if v.Off != c.off || v.Auto != c.autoOpen || v.Closed != c.closed {
			t.Errorf("%s: %+v", c.name, v)
		}
	}
}

// connectWriteNodeHello is connectWriteNode saying the given hello.
func connectWriteNodeHello(t *testing.T, h *harness, label string, hello control.Hello) *writeNode {
	t.Helper()
	c := dialNode(t, h, h.enroll(t, label))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	m, _ := control.New(control.TypeHello, hello)
	if err := wsjson.Write(ctx, c, m); err != nil {
		t.Fatal(err)
	}
	var reply control.Message
	if err := wsjson.Read(ctx, c, &reply); err != nil || reply.Type != control.TypeWelcome {
		t.Fatalf("hello: %v %+v", err, reply)
	}
	n := &writeNode{t: t, conn: c, answer: accepted}
	go n.serve()
	return n
}

// TestComputeRelayRoute (claude-fleet#3364): a login whose sessions go through
// the relay is judged by the probe's relay verdict — this machine's CN egress
// does not close it; a relay in an unsupported region does, and says the route.
// A direct probe reads exactly as before.
func TestComputeRelayRoute(t *testing.T) {
	now := time.Now()
	relayOK := &control.NodeProbe{Loc: "SG", LocLocal: "CN", Route: "relay", Verdict: control.ProbeOK, TS: now}
	if v := decideCompute(true, false, relayOK, false, now); v.Off || v.Closed {
		t.Fatalf("relay ok, local CN: closed: %+v", v)
	}
	relayHK := &control.NodeProbe{Loc: "HK", LocLocal: "CN", Route: "relay", Verdict: control.ProbeUnsupportedRegion, TS: now}
	v := decideCompute(true, false, relayHK, false, now)
	if !v.Off || !v.Closed || v.Why != "compute off (出口地区 HK via relay (local CN) 不在 Claude / OpenAI 支持范围)" {
		t.Fatalf("relay HK: %+v", v)
	}
	if got := probeLoc(relayHK); got != "HK via relay (local CN)" {
		t.Fatalf("finding loc: %q", got)
	}
	direct := &control.NodeProbe{Loc: "CN", Route: "direct", Verdict: control.ProbeUnsupportedRegion, TS: now}
	if v := decideCompute(true, false, direct, false, now); v.Why != "compute off (出口地区 CN 不在 Claude / OpenAI 支持范围)" || probeLoc(direct) != "CN" {
		t.Fatalf("direct: %+v %q", v, probeLoc(direct))
	}
	old := &control.NodeProbe{Verdict: control.ProbeUnsupportedRegion, TS: now}
	if v := decideCompute(true, false, old, false, now); v.Why != "compute off (出口地区 未知 不在 Claude / OpenAI 支持范围)" || probeLoc(old) != "" {
		t.Fatalf("no route, no loc: %+v", v)
	}
}
