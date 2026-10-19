package api

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

// Placement scores load alone (claude-fleet#1994): account quota is shared by
// every machine, so it is shown and never scored; load is the tighter of CPU
// and memory idle; the free-memory floor is relative; memory pressure at warn
// excludes; and no machine has a default cap.

// beatMem sends one login's beat with the given load and memory, and waits
// for it to land.
func beatMem(t *testing.T, h *harness, n *writeNode, host, machine string, load1 float64, free, total uint64, pressure, sessions int, f control.Fleet) {
	t.Helper()
	beat(t, n.conn, control.Proto, control.Heartbeat{Hostname: host, OSUser: "frank", MachineID: machine,
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
		out[r.Hostname] = h.srv.judge(r, settings, accounts, "", time.Now())
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
	h, macD, macC, f5, f4 := twoNodes(t)
	beatMem(t, h, macD, "mac-d", machineA, 2, 32<<30, 64<<30, 1, 3, f5)
	beatMem(t, h, macC, "mac-c", machineB, 2, 32<<30, 64<<30, 1, 3, f4)
	reset := time.Now().UTC().Add(time.Hour)
	for acct, util := range map[string]float64{"acct-busy": 95, "acct-idle": 5} {
		if err := h.srv.Store.InsertLimits(&model.LimitsSnapshot{AccountUUID: acct, ObservedAt: time.Now().UTC(),
			FiveHour: model.Window{Utilization: util, ResetsAt: &reset}, SevenDay: model.Window{Utilization: util / 2}}); err != nil {
			t.Fatal(err)
		}
	}
	c := judgeAll(t, h, map[string]string{"ep_mac-d": "acct-busy", "ep_mac-c": "acct-idle"})
	if c["mac-d"].QuotaUsedPct == nil || *c["mac-d"].QuotaUsedPct != 95 || c["mac-c"].QuotaUsedPct == nil || *c["mac-c"].QuotaUsedPct != 5 {
		t.Fatalf("quota not shown: mac-d %v mac-c %v", c["mac-d"].QuotaUsedPct, c["mac-c"].QuotaUsedPct)
	}
	if !c["mac-d"].Eligible || !c["mac-c"].Eligible || c["mac-d"].Score != c["mac-c"].Score {
		t.Fatalf("same load, different quota: mac-d %+v, mac-c %+v; want the same score", c["mac-d"], c["mac-c"])
	}
	if r := placementReason(c["mac-c"], []Candidate{c["mac-c"], c["mac-d"]}); strings.Contains(r, "account") {
		t.Fatalf("reason %q still names the account", r)
	}
}

// CPU idle but memory tight loses to a machine busier on CPU with memory to
// spare: the issue's own case (mac-c 0.42/core, 1.6 of 16 GiB vs mac-d 0.26/core,
// 34 of 64 GiB) — here mac-c is held just above its 2 GiB floor.
func TestPlacementMemoryTightLoses(t *testing.T) {
	h, macD, macC, f5, f4 := twoNodes(t)
	beatMem(t, h, macD, "mac-d", machineA, 4, 34<<30, 64<<30, 1, 7, f5) // 0.40/core → cpu 0.5, mem 0.53
	beatMem(t, h, macC, "mac-c", machineB, 0, 3<<30, 16<<30, 1, 1, f4)  // idle cpu, mem 0.19
	c := judgeAll(t, h, nil)
	if !c["mac-c"].Eligible || !c["mac-d"].Eligible || c["mac-c"].Score >= c["mac-d"].Score {
		t.Fatalf("mac-c %+v vs mac-d %+v; want both eligible, mac-c scored lower", c["mac-c"], c["mac-d"])
	}
	st, out := placeCall(t, h, h.tokens["mac-c"], map[string]any{"repo": writeRepo, "issue": 31, "worker_id": issueWID(f4.FleetID, 31)})
	if pl, _ := out["placement"].(map[string]any); st != 200 || pl["machine"] != "mac-d" {
		t.Fatalf("place = %d %v; want mac-d", st, out)
	}
}

// Below max(2 GiB, 10% of total) free is out: 5 GiB of 64 is under 6.4.
func TestPlacementBelowMemFloorExcluded(t *testing.T) {
	h, macD, macC, f5, f4 := twoNodes(t)
	beatMem(t, h, macD, "mac-d", machineA, 0, 5<<30, 64<<30, 1, 1, f5)
	beatMem(t, h, macC, "mac-c", machineB, 0, 1800<<20, 16<<30, 1, 1, f4)
	c := judgeAll(t, h, nil)
	if c["mac-d"].Eligible || !strings.Contains(c["mac-d"].Excluded, "free memory 5.0 GiB < 6.4 GiB") {
		t.Fatalf("mac-d = %+v; want excluded under its 6.4 GiB floor", c["mac-d"])
	}
	if c["mac-c"].Eligible || !strings.Contains(c["mac-c"].Excluded, "< 2.0 GiB") {
		t.Fatalf("mac-c = %+v; want excluded under the 2 GiB floor", c["mac-c"])
	}
}

// Memory pressure at warn excludes a machine whatever its free memory; an
// agent that does not report it (0) is never excluded for it.
func TestPlacementMemPressureExcluded(t *testing.T) {
	h, macD, macC, f5, f4 := twoNodes(t)
	beatMem(t, h, macD, "mac-d", machineA, 0, 40<<30, 64<<30, 2, 1, f5)
	beatMem(t, h, macC, "mac-c", machineB, 0, 8<<30, 16<<30, 0, 1, f4)
	c := judgeAll(t, h, nil)
	if c["mac-d"].Eligible || c["mac-d"].Excluded != "memory pressure warn" {
		t.Fatalf("mac-d = %+v; want excluded on memory pressure", c["mac-d"])
	}
	if !c["mac-c"].Eligible {
		t.Fatalf("mac-c = %+v; an unreported pressure must not exclude", c["mac-c"])
	}
	beatMem(t, h, macD, "mac-d", machineA, 0, 40<<30, 64<<30, 4, 1, f5)
	if c := judgeAll(t, h, nil); c["mac-d"].Excluded != "memory pressure critical" {
		t.Fatalf("mac-d = %+v; want excluded on critical pressure", c["mac-d"])
	}
}

// No machine carries a default cap: mac-c at 22 sessions is still a candidate,
// and the settings' effective view lists no node cap.
func TestPlacementNoDefaultNodeCap(t *testing.T) {
	h, _, macC, _, f4 := twoNodes(t)
	beatMem(t, h, macC, "mac-c", machineB, 0, 8<<30, 16<<30, 1, 22, f4)
	c := judgeAll(t, h, nil)
	if c["mac-c"].Cap != nil || !c["mac-c"].Eligible {
		t.Fatalf("mac-c = %+v; want no cap, eligible", c["mac-c"])
	}
	if _, ok := h.srv.nodeCap("mac-c", map[string]string{}); ok {
		t.Fatal("mac-c has a default cap")
	}
	eff := getFleet(t, h, "/v1/fleet/settings", 200)["effective"].(map[string]any)
	for k := range eff {
		if strings.HasPrefix(k, NodeCapPrefix) {
			t.Fatalf("effective settings carry %s with nothing set", k)
		}
	}
}

// The load ceiling a hub starts with (claude-fleet#2267): a positive number
// moves it, anything else leaves 0.8.
func TestLoadCeilingFromEnv(t *testing.T) {
	for v, want := range map[string]float64{"": 0.8, "3": 3, " 1.5 ": 1.5, "0": 0.8, "-2": 0.8, "x": 0.8, "Inf": 0.8, "NaN": 0.8} {
		if got := loadCeiling(v, 0.8); got != want {
			t.Errorf("loadCeiling(%q) = %v; want %v", v, got, want)
		}
	}
}
