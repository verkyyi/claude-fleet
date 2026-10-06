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
	h, m5, m4, f5, f4 := twoNodes(t)
	m5.beatLoad("m5", "verk", machineA, 5, 1, f5)
	m4.beatProbe("m4", "verk", machineB, nil, false, probe("CN", control.ProbeUnsupportedRegion), f4)
	waitProbe(t, h, "ep_m4", control.ProbeUnsupportedRegion, false)

	pl, err := h.srv.PickNode("", writeRepo)
	if err != nil || pl.Machine != "m5" || !strings.Contains(pl.Reason, "m4 excluded: compute off (出口地区 CN") {
		t.Fatalf("auto placement = %q %q %v; want m5, m4 excluded by region", pl.Machine, pl.Reason, err)
	}
	st, out := placeCall(t, h, h.tokens["m5"], map[string]any{"repo": writeRepo, "issue": 41,
		"worker_id": issueWID(f5.FleetID, 41), "node": "m4"})
	if e, _ := out["error"].(map[string]any); st != 503 || e["code"] != "NO_ELIGIBLE_NODE" {
		t.Fatalf("named place on m4 = %d %v; want NO_ELIGIBLE_NODE", st, out)
	}
	_, nodes := nodeStatuses(t, h)
	if nodes["m4"]["compute_off"] != true || nodes["m4"]["compute_closed"] != true ||
		!strings.Contains(nodes["m4"]["compute_why"].(string), "CN") {
		t.Fatalf("roster m4 = %v; want compute_off + compute_closed naming CN", nodes["m4"])
	}
	fs := computeFindings(t, h)
	if len(fs) != 1 || fs[0].Severity != "warning" || !strings.Contains(fs[0].Title, "verk@m4") || !strings.Contains(fs[0].Title, "CN") {
		t.Fatalf("compute_region findings = %+v; want one warning naming verk@m4 and CN", fs)
	}

	m4.beatProbe("m4", "verk", machineB, nil, false, probe("US", control.ProbeOK), f4)
	waitProbe(t, h, "ep_m4", control.ProbeOK, false)
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "m4" {
		t.Fatalf("back in a supported region: %q %v; want m4", pl.Machine, err)
	}
	if fs := computeFindings(t, h); len(fs) != 0 {
		t.Fatalf("alert after the region came back: %+v", fs)
	}
}

// 支持地区 + 可达, compute off, policy off → only a hint, never opened; the
// policy on opens it; a stale probe or an unreachable one does not.
func TestComputeAutoOpensOnlyByPolicy(t *testing.T) {
	h, m5, m4, f5, f4 := twoNodes(t)
	m5.beatLoad("m5", "verk", machineA, 5, 1, f5)
	m4.beatProbe("m4", "verk", machineB, computeOff(), false, probe("US", control.ProbeOK), f4)
	waitProbe(t, h, "ep_m4", control.ProbeOK, false)
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "m5" {
		t.Fatalf("policy off: %q %v; want m5 (an ok probe only hints)", pl.Machine, err)
	}
	if fs := computeFindings(t, h); len(fs) != 0 {
		t.Fatalf("a coordinate-only node is no alert: %+v", fs)
	}

	putSetting(t, h, ComputeAutoKey, "maybe", 400)
	putSetting(t, h, ComputeAutoKey, "on", 200)
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "m4" {
		t.Fatalf("compute_auto=on: %q %v; want m4 opened by policy", pl.Machine, err)
	}
	if _, nodes := nodeStatuses(t, h); nodes["m4"]["compute_auto"] != true {
		t.Fatalf("roster m4 = %v; want compute_auto", nodes["m4"])
	}

	stale := probe("US", control.ProbeOK)
	stale.TS = time.Now().Add(-3 * 24 * time.Hour)
	m4.beatProbe("m4", "verk", machineB, computeOff(), false, stale, f4)
	waitFor(t, 3*time.Second, "stale probe", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_m4", time.Now())
		return hb.Probe != nil && time.Since(hb.Probe.TS) > probeFreshFor
	})
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "m5" {
		t.Fatalf("stale probe: %q %v; want m5", pl.Machine, err)
	}
	m4.beatProbe("m4", "verk", machineB, computeOff(), false, probe("US", control.ProbeUnreachable), f4)
	waitProbe(t, h, "ep_m4", control.ProbeUnreachable, false)
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "m5" {
		t.Fatalf("unreachable probe: %q %v; want m5", pl.Machine, err)
	}
	// Policy on never opens a login in an unsupported region, and that
	// login asked for nothing, so it is no alert either.
	m4.beatProbe("m4", "verk", machineB, computeOff(), false, probe("CN", control.ProbeUnsupportedRegion), f4)
	waitProbe(t, h, "ep_m4", control.ProbeUnsupportedRegion, false)
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "m5" {
		t.Fatalf("region + policy: %q %v; want m5", pl.Machine, err)
	}
	if fs := computeFindings(t, h); len(fs) != 0 {
		t.Fatalf("a coordinate-only node in CN is no alert: %+v", fs)
	}
}

// An unreachable API never closes a login that asked to run — weather, not a
// rule; --force keeps a login open over its region and lands in fleet_audit
// once per link.
func TestComputeUnreachableAndForce(t *testing.T) {
	h, m5, m4, f5, f4 := twoNodes(t)
	m5.beatLoad("m5", "verk", machineA, 5, 1, f5)
	m4.beatProbe("m4", "verk", machineB, computeOn(), false, probe("US", control.ProbeUnreachable), f4)
	waitProbe(t, h, "ep_m4", control.ProbeUnreachable, false)
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "m4" {
		t.Fatalf("unreachable, compute on: %q %v; want m4 kept", pl.Machine, err)
	}

	for i := 0; i < 2; i++ {
		m4.beatProbe("m4", "verk", machineB, computeOn(), true, probe("CN", control.ProbeUnsupportedRegion), f4)
	}
	waitProbe(t, h, "ep_m4", control.ProbeUnsupportedRegion, true)
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "m4" {
		t.Fatalf("forced: %q %v; want m4", pl.Machine, err)
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
	m5 := connectWriteNode(t, h, "m5")
	m4 := connectWriteNodeHello(t, h, "m4", control.Hello{HeartbeatMS: 60000, AgentVersion: "test",
		Capabilities: []string{control.CapRead, control.CapWrite}, Compute: computeOff()})
	f5 := fakeFleet(t, machineA, "fleet-m5", writeRepo, "/u/verk/claude-fleet", 1)
	f4 := fakeFleet(t, machineB, "fleet-m4", writeRepo, "/u/verk/claude-fleet", 2)
	m5.beatLoad("m5", "verk", machineA, 5, 1, f5)
	m4.beatProbe("m4", "verk", machineB, computeOff(), false, nil, f4)
	waitFor(t, 3*time.Second, "both fleets registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "m5" {
		t.Fatalf("hello off: %q %v; want m5", pl.Machine, err)
	}
	m4.beatProbe("m4", "verk", machineB, computeOn(), false, nil, f4)
	waitFor(t, 3*time.Second, "m4 says compute on", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_m4", time.Now())
		return hb.Compute != nil && *hb.Compute
	})
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "m4" {
		t.Fatalf("beat said on: %q %v; want m4", pl.Machine, err)
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
