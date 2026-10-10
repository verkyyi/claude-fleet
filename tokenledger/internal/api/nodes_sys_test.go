package api

import (
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// claude-fleet#2798: every part of a beat says when it was read, and the
// machine's load is the newest timed reading any heard row carries — the
// machine link's included — so a login whose fleet read is slow, or a lane the
// hub refused, never leaves the machine with no load. An older node (no sys_at)
// still counts, as 时间未知.
func TestMachineLoadIsTheNewestTimedReadingOfAnyRow(t *testing.T) {
	h, n := machineRig(t)
	// alpha is an older agent: a load and no time. Untimed rows are ordered by
	// their heartbeat, kept to the second — one past the rig's own link beat.
	time.Sleep(1100 * time.Millisecond)
	n.beat("alpha", control.Heartbeat{Hostname: "m4", OSUser: "alpha", NCPU: 10, Load1: 3, ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, "alpha's untimed load", func() bool {
		ms := roster(t, h).Machines
		return len(ms) == 1 && ms[0].Load1 == 3
	})
	if m := roster(t, h).Machines[0]; m.SysAt != nil || m.Versions != nil {
		t.Fatalf("an older node's load must read 时间未知, not fresh: %+v", m)
	}

	// The machine link reads the kernel on its own clock and carries versions.
	sysAt := time.Now().UTC().Truncate(time.Second)
	verAt := sysAt.Add(-time.Minute)
	n.beat("", control.Heartbeat{Hostname: "m4", OSUser: "root", NCPU: 10, Load1: 2, MemTotalBytes: 16 << 30,
		ObservedAt: time.Now(), SysAt: &sysAt, VersionsAt: &verAt,
		Versions: &control.Versions{Runtime: "abc123", Actual: map[string]string{"claude": "2.1.295"},
			Want: map[string]string{"claude": "2.1.295"}, Update: &control.UpdateState{Result: "current", Phase: "idle"}}})
	waitFor(t, 3*time.Second, "the link's timed load", func() bool {
		ms := roster(t, h).Machines
		return len(ms) == 1 && ms[0].Load1 == 2
	})
	m := roster(t, h).Machines[0]
	if m.SysAt == nil || !m.SysAt.Equal(sysAt) || m.MemTotal != 16<<30 {
		t.Fatalf("m4 = load %v at %v mem %d; want the link's reading at %v", m.Load1, m.SysAt, m.MemTotal, sysAt)
	}
	if m.Versions == nil || m.Versions.Runtime != "abc123" || m.VersionsAt == nil || !m.VersionsAt.Equal(verAt) {
		t.Fatalf("m4 versions = %+v at %v", m.Versions, m.VersionsAt)
	}

	// A newer UNTIMED beat does not beat a timed reading.
	n.beat("alpha", control.Heartbeat{Hostname: "m4", OSUser: "alpha", NCPU: 10, Load1: 9, ObservedAt: time.Now()})
	time.Sleep(200 * time.Millisecond)
	if m := roster(t, h).Machines[0]; m.Load1 != 2 {
		t.Fatalf("an untimed beat replaced a timed load: %v", m.Load1)
	}

	// beta reads its fleets late (fleet_at old) but its load fresh: the
	// machine takes beta's load, the row says how old each half is.
	newer := sysAt.Add(5 * time.Second)
	fleetAt := sysAt.Add(-30 * time.Second)
	n.beat("beta", control.Heartbeat{Hostname: "m4", OSUser: "beta", NCPU: 10, Load1: 4, ObservedAt: time.Now(),
		SysAt: &newer, FleetAt: &fleetAt, SysUnread: nil})
	waitFor(t, 3*time.Second, "beta's newer load", func() bool { return roster(t, h).Machines[0].Load1 == 4 })
	for _, v := range roster(t, h).Nodes {
		if v.OSUser != "beta" {
			continue
		}
		if v.FleetAt == nil || !v.FleetAt.Equal(fleetAt) || v.SysAt == nil || !v.SysAt.Equal(newer) {
			t.Fatalf("beta's row: sys_at %v fleet_at %v; want %v / %v", v.SysAt, v.FleetAt, newer, fleetAt)
		}
	}

	// 共同约定 1: a person who holds alpha on m4 gets the machine's load (the
	// link's row, never theirs to see, still feeds it) — and nobody's rows but
	// their own; a stranger gets no m4 at all.
	newest := newer.Add(5 * time.Second)
	n.beat("", control.Heartbeat{Hostname: "m4", OSUser: "root", NCPU: 10, Load1: 1, ObservedAt: time.Now(), SysAt: &newest})
	alphaOnly := func(host, login string) bool { return host == "m4" && login == "alpha" }
	waitFor(t, 3*time.Second, "alpha sees the link's load", func() bool {
		snap, err := h.srv.nodesWhere(time.Now(), alphaOnly)
		return err == nil && len(snap.Machines) == 1 && snap.Machines[0].Load1 == 1
	})
	snap, _ := h.srv.nodesWhere(time.Now(), alphaOnly)
	if snap.Machines[0].SysAt == nil || !snap.Machines[0].SysAt.Equal(newest) {
		t.Fatalf("alpha's m4 sys_at = %v; want %v", snap.Machines[0].SysAt, newest)
	}
	for _, v := range snap.Nodes {
		if v.OSUser != "alpha" {
			t.Fatalf("alpha sees %s's row", v.OSUser)
		}
	}
	if snap, _ := h.srv.nodesWhere(time.Now(), func(string, string) bool { return false }); len(snap.Machines) != 0 {
		t.Fatalf("a stranger sees %+v", snap.Machines)
	}
}

// A load the node could not read (sys_unread) is passed on as 读不到 and is no
// point on the load trend.
func TestUnreadLoadIsSaidAndKeptOffTheTrend(t *testing.T) {
	h, n := machineRig(t)
	at := time.Now().UTC()
	n.beat("", control.Heartbeat{Hostname: "m4", OSUser: "root", NCPU: 10, Load1: 5, ObservedAt: time.Now(), SysAt: &at})
	waitFor(t, 3*time.Second, "m4's load", func() bool {
		ms := roster(t, h).Machines
		return len(ms) == 1 && ms[0].Load1 == 5
	})
	later := at.Add(time.Second)
	n.beat("", control.Heartbeat{Hostname: "m4", OSUser: "root", NCPU: 10, ObservedAt: time.Now(),
		SysAt: &later, SysUnread: []string{"load"}})
	waitFor(t, 3*time.Second, "m4 says 读不到", func() bool {
		ms := roster(t, h).Machines
		return len(ms) == 1 && len(ms[0].SysUnread) == 1
	})
	m := roster(t, h).Machines[0]
	if m.SysUnread[0] != "load" || m.Load1 != 0 {
		t.Fatalf("m4 = load %v unread %v", m.Load1, m.SysUnread)
	}
	// The trend's newest point is still the last load that WAS read (5/10),
	// not a zero the node could not read.
	if l := len(m.LoadHist); l == 0 || m.LoadHist[l-1] != 0.5 {
		t.Fatalf("load trend = %v; want it to end at 0.5", m.LoadHist)
	}
}
