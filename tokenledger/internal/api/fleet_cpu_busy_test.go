package api

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// beatBusy is beatLoad with a CPU-busy reading and the machine's own ceiling.
func (n *writeNode) beatBusy(host, user, machine string, load1, busy, own float64, fleets ...control.Fleet) {
	beat(n.t, n.conn, control.Proto, control.Heartbeat{Hostname: host, OSUser: user, MachineID: machine,
		Load1: load1, NCPU: 10, MemFreeBytes: 8 << 30, MemTotalBytes: 16 << 30, Sessions: 1,
		CPUBusy: &busy, MaxCPUBusy: own, Fleets: fleets, ObservedAt: time.Now()})
}

func waitBusy(t *testing.T, h *harness, host string, busy float64) {
	t.Helper()
	waitFor(t, 3*time.Second, host+" reports cpu busy", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_"+host, time.Now())
		return hb.CPUBusy != nil && *hb.CPUBusy == busy
	})
}

// claude-fleet#2882 完成判据: a machine at load 2/core whose CPUs are half idle
// takes the session; one whose CPUs are 90% busy is out, and says so in
// CPU terms with the load beside it.
func TestPlaceGatesOnCPUBusyNotLoad(t *testing.T) {
	h, macD, macC, f5, f4 := twoNodes(t)
	macD.beatBusy("mac-d", "frank", machineA, 20, 0.5, 0, f5)
	macC.beatBusy("mac-c", "frank", machineB, 1, 0.9, 0, f4)
	waitBusy(t, h, "mac-d", 0.5)
	waitBusy(t, h, "mac-c", 0.9)
	pl, err := h.srv.PickNode("", writeRepo)
	if err != nil || pl.Machine != "mac-d" {
		t.Fatalf("placement = %q %v; want mac-d (load 2/core, CPU 50%% busy)", pl.Machine, err)
	}
	if !strings.Contains(pl.Reason, "mac-c excluded: CPU busy 90% > 80% (load 0.10/core)") || !strings.Contains(pl.Reason, "CPU busy 50%") {
		t.Fatalf("reason = %q", pl.Reason)
	}

	// The machine's own ceiling (machine.env FLEET_MAX_CPU_BUSY) wins over
	// the hub's: mac-c at 90% under its 95% is a candidate again, and the
	// idler-scored one.
	macC.beatBusy("mac-c", "frank", machineB, 1, 0.9, 0.95, f4)
	waitFor(t, 3*time.Second, "mac-c reports its ceiling", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_mac-c", time.Now())
		return hb.MaxCPUBusy == 0.95
	})
	pl, err = h.srv.PickNode("", writeRepo)
	if err != nil {
		t.Fatalf("with mac-c's own ceiling: %v", err)
	}
	for _, c := range pl.Candidates {
		if !c.Eligible {
			t.Fatalf("%s excluded under its own ceiling: %s", c.Machine, c.Excluded)
		}
		if c.Machine == "mac-c" && c.CPUBusyMax != 0.95 {
			t.Fatalf("mac-c judged against %v, want 0.95", c.CPUBusyMax)
		}
	}
}

// claude-fleet#2882: the refusal names every machine — the busy candidates, and
// a host where the caller has no login (mid-update, saying so).
func TestRefusalListsEveryMachine(t *testing.T) {
	h, macD, macC, f5, f4 := twoNodes(t)
	m6 := connectWriteNode(t, h, "m6")
	beat(t, m6.conn, control.Proto, control.Heartbeat{Hostname: "m6", OSUser: "erin", MachineID: "machine-m6",
		Load1: 1, NCPU: 10, MemFreeBytes: 8 << 30, MemTotalBytes: 16 << 30,
		Versions: &control.Versions{Update: &control.UpdateState{Phase: "switching"}}, ObservedAt: time.Now()})
	macD.beatBusy("mac-d", "frank", machineA, 20, 0.85, 0, f5)
	macC.beatBusy("mac-c", "frank", machineB, 20, 0.95, 0, f4)
	waitBusy(t, h, "mac-d", 0.85)
	waitBusy(t, h, "mac-c", 0.95)
	waitFor(t, 3*time.Second, "m6 heard", func() bool {
		_, st, ok := h.srv.nodeStatusOf("ep_m6", time.Now())
		return ok && st == "online"
	})
	_, err := h.srv.PickNode("", writeRepo)
	if err == nil {
		t.Fatal("placement succeeded with every CPU over the ceiling")
	}
	msg := err.Error()
	for _, want := range []string{"mac-d: CPU busy 85% > 80% (load 2.00/core)", "mac-c: CPU busy 95% > 80%", "m6: 没有你的登录；正在更新（switching）"} {
		if !strings.Contains(msg, want) {
			t.Fatalf("refusal %q lacks %q", msg, want)
		}
	}
}

func TestCPUVerdict(t *testing.T) {
	f := func(v float64) *float64 { return &v }
	if out, eq := cpuVerdict(nil, 0, f(1.0)); out != "load 1.00/core > 0.8" || *eq != 1.0 {
		t.Fatalf("no busy reading: %q %v — the old load rule, byte for byte", out, eq)
	}
	if out, eq := cpuVerdict(nil, 0, nil); out != "" || eq != nil {
		t.Fatalf("nothing read: %q %v", out, eq)
	}
	if out, eq := cpuVerdict(f(0.4), 0, f(2.4)); out != "" || *eq != 0.4 {
		t.Fatalf("40%% busy at load 2.4/core: %q %v; want room, scored 0.4", out, *eq)
	}
	if out, _ := cpuVerdict(f(0.7), 0.6, nil); out != "CPU busy 70% > 60%" {
		t.Fatalf("own ceiling: %q", out)
	}
	if cpuCeiling(1.5) != maxCPUBusy || cpuCeiling(0) != maxCPUBusy || cpuCeiling(0.5) != 0.5 {
		t.Fatal("cpuCeiling")
	}
}
