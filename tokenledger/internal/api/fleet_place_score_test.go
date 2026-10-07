package api

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
)

// Placement scores load alone (claude-fleet#1994): account quota is shared by
// every machine, so it is shown and never scored; load is the tighter of CPU
// and memory idle; the free-memory floor is relative; memory pressure at warn
// excludes; and no machine has a default cap.

// beatMem sends one login's beat with the given load and memory, and waits
// for it to land.
func beatMem(t *testing.T, h *harness, n *writeNode, host, machine string, load1 float64, free, total uint64, pressure, sessions int, f control.Fleet) {
	t.Helper()
	beat(t, n.conn, control.Proto, control.Heartbeat{Hostname: host, OSUser: "verk", MachineID: machine,
		Load1: load1, NCPU: 10, MemFreeBytes: free, MemTotalBytes: total, MemPressure: pressure,
		Sessions: sessions, Fleets: []control.Fleet{f}, ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, host+"'s beat landed", func() bool {
		got, _, _ := h.srv.nodeStatusOf("ep_"+host, time.Now())
		return got.Load1 == load1 && got.MemFreeBytes == free && got.MemPressure == pressure
	})
}

// judgeAll runs judge over every fleet row, with accounts as given.
func judgeAll(t *testing.T, h *harness, accounts map[string]string) map[string]Candidate {
	t.Helper()
	rows, err := h.srv.Store.Fleets()
	if err != nil {
		t.Fatal(err)
	}
	settings, err := h.srv.Store.FleetSettings()
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]Candidate{}
	for _, r := range rows {
		out[r.Hostname] = h.srv.judge(r, settings, accounts, time.Now())
	}
	return out
}

func TestLoadScore(t *testing.T) {
	f := func(x float64) *float64 { return &x }
	for _, tc := range []struct {
		name        string
		load        *float64
		free, total uint64
		want        float64
	}{
		{"cpu tighter", f(0.4), 48 << 30, 64 << 30, 0.5},
		{"memory tighter", f(0.08), 4 << 30, 16 << 30, 0.25},
		{"over the load bound clamps", f(1.6), 8 << 30, 16 << 30, 0},
		{"unknown load is middling", nil, 60 << 30, 64 << 30, 0.5},
		{"unknown memory is middling", f(0), 0, 0, 0.5},
	} {
		if got := loadScore(tc.load, tc.free, tc.total); got < tc.want-1e-9 || got > tc.want+1e-9 {
			t.Errorf("%s: loadScore = %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestMemFloorIsRelative(t *testing.T) {
	if got := memFloor(16 << 30); got != 2<<30 {
		t.Errorf("16 GiB machine floor = %v, want 2 GiB", got)
	}
	if got := memFloor(64 << 30); got != 0.1*(64<<30) {
		t.Errorf("64 GiB machine floor = %v, want 6.4 GiB", got)
	}
}

// Same load, very different account use: the same score, and the reason no
// longer names the account — the quota is still shown on the candidate.
func TestPlacementQuotaNotScored(t *testing.T) {
	h, m5, m4, f5, f4 := twoNodes(t)
	beatMem(t, h, m5, "m5", machineA, 2, 32<<30, 64<<30, 1, 3, f5)
	beatMem(t, h, m4, "m4", machineB, 2, 32<<30, 64<<30, 1, 3, f4)
	reset := time.Now().UTC().Add(time.Hour)
	for acct, util := range map[string]float64{"acct-busy": 95, "acct-idle": 5} {
		if err := h.srv.Store.InsertLimits(&model.LimitsSnapshot{AccountUUID: acct, ObservedAt: time.Now().UTC(),
			FiveHour: model.Window{Utilization: util, ResetsAt: &reset}, SevenDay: model.Window{Utilization: util / 2}}); err != nil {
			t.Fatal(err)
		}
	}
	c := judgeAll(t, h, map[string]string{"ep_m5": "acct-busy", "ep_m4": "acct-idle"})
	if c["m5"].QuotaUsedPct == nil || *c["m5"].QuotaUsedPct != 95 || c["m4"].QuotaUsedPct == nil || *c["m4"].QuotaUsedPct != 5 {
		t.Fatalf("quota not shown: m5 %v m4 %v", c["m5"].QuotaUsedPct, c["m4"].QuotaUsedPct)
	}
	if !c["m5"].Eligible || !c["m4"].Eligible || c["m5"].Score != c["m4"].Score {
		t.Fatalf("same load, different quota: m5 %+v, m4 %+v; want the same score", c["m5"], c["m4"])
	}
	if r := placementReason(c["m4"], []Candidate{c["m4"], c["m5"]}); strings.Contains(r, "account") {
		t.Fatalf("reason %q still names the account", r)
	}
}

// CPU idle but memory tight loses to a machine busier on CPU with memory to
// spare: the issue's own case (m4 0.42/core, 1.6 of 16 GiB vs m5 0.26/core,
// 34 of 64 GiB) — here m4 is held just above its 2 GiB floor.
func TestPlacementMemoryTightLoses(t *testing.T) {
	h, m5, m4, f5, f4 := twoNodes(t)
	beatMem(t, h, m5, "m5", machineA, 4, 34<<30, 64<<30, 1, 7, f5) // 0.40/core → cpu 0.5, mem 0.53
	beatMem(t, h, m4, "m4", machineB, 0, 3<<30, 16<<30, 1, 1, f4)  // idle cpu, mem 0.19
	c := judgeAll(t, h, nil)
	if !c["m4"].Eligible || !c["m5"].Eligible || c["m4"].Score >= c["m5"].Score {
		t.Fatalf("m4 %+v vs m5 %+v; want both eligible, m4 scored lower", c["m4"], c["m5"])
	}
	st, out := placeCall(t, h, h.tokens["m4"], map[string]any{"repo": writeRepo, "issue": 31, "worker_id": issueWID(f4.FleetID, 31)})
	if pl, _ := out["placement"].(map[string]any); st != 200 || pl["machine"] != "m5" {
		t.Fatalf("place = %d %v; want m5", st, out)
	}
}

// Below max(2 GiB, 10% of total) free is out: 5 GiB of 64 is under 6.4.
func TestPlacementBelowMemFloorExcluded(t *testing.T) {
	h, m5, m4, f5, f4 := twoNodes(t)
	beatMem(t, h, m5, "m5", machineA, 0, 5<<30, 64<<30, 1, 1, f5)
	beatMem(t, h, m4, "m4", machineB, 0, 1800<<20, 16<<30, 1, 1, f4)
	c := judgeAll(t, h, nil)
	if c["m5"].Eligible || !strings.Contains(c["m5"].Excluded, "free memory 5.0 GiB < 6.4 GiB") {
		t.Fatalf("m5 = %+v; want excluded under its 6.4 GiB floor", c["m5"])
	}
	if c["m4"].Eligible || !strings.Contains(c["m4"].Excluded, "< 2.0 GiB") {
		t.Fatalf("m4 = %+v; want excluded under the 2 GiB floor", c["m4"])
	}
}

// Memory pressure at warn excludes a machine whatever its free memory; an
// agent that does not report it (0) is never excluded for it.
func TestPlacementMemPressureExcluded(t *testing.T) {
	h, m5, m4, f5, f4 := twoNodes(t)
	beatMem(t, h, m5, "m5", machineA, 0, 40<<30, 64<<30, 2, 1, f5)
	beatMem(t, h, m4, "m4", machineB, 0, 8<<30, 16<<30, 0, 1, f4)
	c := judgeAll(t, h, nil)
	if c["m5"].Eligible || c["m5"].Excluded != "memory pressure warn" {
		t.Fatalf("m5 = %+v; want excluded on memory pressure", c["m5"])
	}
	if !c["m4"].Eligible {
		t.Fatalf("m4 = %+v; an unreported pressure must not exclude", c["m4"])
	}
	beatMem(t, h, m5, "m5", machineA, 0, 40<<30, 64<<30, 4, 1, f5)
	if c := judgeAll(t, h, nil); c["m5"].Excluded != "memory pressure critical" {
		t.Fatalf("m5 = %+v; want excluded on critical pressure", c["m5"])
	}
}

// No machine carries a default cap: m4 at 22 sessions is still a candidate,
// and the settings' effective view lists no node cap.
func TestPlacementNoDefaultNodeCap(t *testing.T) {
	h, _, m4, _, f4 := twoNodes(t)
	beatMem(t, h, m4, "m4", machineB, 0, 8<<30, 16<<30, 1, 22, f4)
	c := judgeAll(t, h, nil)
	if c["m4"].Cap != nil || !c["m4"].Eligible {
		t.Fatalf("m4 = %+v; want no cap, eligible", c["m4"])
	}
	if _, ok := h.srv.nodeCap("m4", map[string]string{}); ok {
		t.Fatal("m4 has a default cap")
	}
	eff := getFleet(t, h, "/v1/fleet/settings", 200)["effective"].(map[string]any)
	for k := range eff {
		if strings.HasPrefix(k, NodeCapPrefix) {
			t.Fatalf("effective settings carry %s with nothing set", k)
		}
	}
}
