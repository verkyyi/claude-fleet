package api

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Node-lost and lease-conflict alerts (claude-fleet#1630).

func openAlerts(t *testing.T, h *harness, kind string) []store.FleetAlert {
	t.Helper()
	all, err := h.srv.Store.FleetAlerts(0)
	if err != nil {
		t.Fatal(err)
	}
	var out []store.FleetAlert
	for _, a := range all {
		if a.Kind == kind && a.ClearedAt == nil {
			out = append(out, a)
		}
	}
	return out
}

// lastBeat is the one node's last heartbeat.
func lastBeat(t *testing.T, h *harness) time.Time {
	t.Helper()
	nodes, err := h.srv.Store.Nodes()
	if err != nil {
		t.Fatal(err)
	}
	if len(nodes) != 1 || nodes[0].LastHeartbeat == nil {
		t.Fatalf("want one node with a heartbeat, have %+v", nodes)
	}
	return *nodes[0].LastHeartbeat
}

// A node silent for 120 s gets one node_lost; its next beat clears it, and the
// row keeps both moments.
func TestNodeLostRaisedAfter120sAndClearedOnReturn(t *testing.T) {
	h := newFleetHarness(t)
	n := connectFakeNode(t, h, "m5", false)
	n.beat("m5", "verkyyi", machineA)
	// The connect stamps a heartbeat too; wait for the BEAT's (it names the
	// login), or the sweep below races it.
	waitFor(t, 3*time.Second, "m5 beat recorded", func() bool {
		ns, _ := h.srv.Store.Nodes()
		return len(ns) == 1 && ns[0].LastHeartbeat != nil && ns[0].OSUser == "verkyyi"
	})
	last := lastBeat(t, h)
	since := last.Add(-time.Hour)

	h.srv.NodeAlertTick(since, last.Add(119*time.Second))
	if a := openAlerts(t, h, store.AlertNodeLost); len(a) != 0 {
		t.Fatalf("node_lost after 119 s of silence: %+v", a)
	}
	at := last.Add(121 * time.Second)
	h.srv.NodeAlertTick(since, at)
	h.srv.NodeAlertTick(since, at.Add(15*time.Second)) // a second sweep adds no row
	lost := openAlerts(t, h, store.AlertNodeLost)
	if len(lost) != 1 || !lost[0].RaisedAt.Equal(at) {
		t.Fatalf("after 121 s: open node_lost = %+v, want one raised at %s", lost, at)
	}
	var d map[string]any
	_ = json.Unmarshal([]byte(lost[0].Detail), &d)
	if d["hostname"] == "" || d["os_user"] != "verkyyi" {
		t.Fatalf("node_lost detail does not name the machine: %s", lost[0].Detail)
	}

	n.beat("m5", "verkyyi", machineA)
	waitFor(t, 3*time.Second, "node_lost cleared by the next beat", func() bool {
		return len(openAlerts(t, h, store.AlertNodeLost)) == 0
	})
	all, _ := h.srv.Store.FleetAlerts(0)
	if len(all) != 1 || all[0].ClearedAt == nil {
		t.Fatalf("the cleared row must stay with its timestamps: %+v", all)
	}

	// Through the read tool too.
	out := getFleet(t, h, "/v1/fleet/fleet_alerts", 200)
	if rows, _ := out["alerts"].([]any); len(rows) != 1 || out["open"] != float64(0) {
		t.Fatalf("fleet_alerts = %v", out)
	}
}

// A hub that was itself down counts silence from its own start: nodes that
// could not beat to a dead hub are not all lost the moment it is back.
func TestNodeLostCountsFromHubStart(t *testing.T) {
	h := newFleetHarness(t)
	n := connectFakeNode(t, h, "m4", false)
	n.beat("m4", "verkyyi", machineB)
	waitFor(t, 3*time.Second, "m4 beat recorded", func() bool {
		ns, _ := h.srv.Store.Nodes()
		return len(ns) == 1 && ns[0].LastHeartbeat != nil && ns[0].OSUser == "verkyyi"
	})
	start := lastBeat(t, h).Add(10 * time.Minute) // the hub restarted 10 min later
	h.srv.NodeAlertTick(start, start.Add(60*time.Second))
	if a := openAlerts(t, h, store.AlertNodeLost); len(a) != 0 {
		t.Fatalf("node_lost 60 s after a hub restart: %+v", a)
	}
	h.srv.NodeAlertTick(start, start.Add(121*time.Second))
	if a := openAlerts(t, h, store.AlertNodeLost); len(a) != 1 {
		t.Fatalf("node_lost 121 s after a hub restart with no beat: %+v", a)
	}
}

// FLEET_NODE_LOST_ALERT_SECS sets the threshold; junk keeps the default.
func TestNodeLostAfterFromEnv(t *testing.T) {
	for v, want := range map[string]time.Duration{"": 120 * time.Second, "45": 45 * time.Second,
		"0": 120 * time.Second, "x": 120 * time.Second} {
		t.Setenv("FLEET_NODE_LOST_ALERT_SECS", v)
		if got := NodeLostAfterFromEnv(); got != want {
			t.Errorf("FLEET_NODE_LOST_ALERT_SECS=%q → %s, want %s", v, got, want)
		}
	}
}

// reconnect opens a NEW control connection for an enrolled lease node — what
// the agent does after a drop — and beats once with the given issues.
func (n *leaseNode) reconnect(t *testing.T, h *harness, issues ...int) {
	t.Helper()
	// The old link is gone first, as it is for an agent that reconnects.
	n.conn.CloseNow()
	c := dialNode(t, h, n.token)
	hello(t, c, control.Proto, 60000)
	n.fakeNode = &fakeNode{t: t, conn: c}
	n.show(t, issues...)
}

// The acceptance test: while m4 was away its issue's lease went to m5. m4
// comes back still running it → one lease_conflict naming both sides, and
// neither lease nor session changes. A conflict seen mid-connection is not a
// reconnect and raises nothing.
func TestLeaseConflictOnReconnect(t *testing.T) {
	h, m5, m4 := newLeasePair(t)
	if code, out := m5.acquire(t, h, 7, false); code != 200 {
		t.Fatalf("m5 acquire: %d %v", code, out)
	}
	m5.show(t, 7)

	m4.show(t, 7) // same connection: not a reconnect
	time.Sleep(200 * time.Millisecond)
	if a := openAlerts(t, h, store.AlertLeaseConflict); len(a) != 0 {
		t.Fatalf("lease_conflict raised on an ordinary beat: %+v", a)
	}

	m4.reconnect(t, h, 7)
	waitFor(t, 3*time.Second, "lease_conflict on m4's reconnect", func() bool {
		return len(openAlerts(t, h, store.AlertLeaseConflict)) == 1
	})
	a := openAlerts(t, h, store.AlertLeaseConflict)[0]
	if a.Subject != leaseRepo+"#7" {
		t.Fatalf("subject = %q", a.Subject)
	}
	var c leaseConflict
	if err := json.Unmarshal([]byte(a.Detail), &c); err != nil {
		t.Fatal(err)
	}
	if c.Holder.WorkerID != m5.wid(7) || c.Holder.Node != "verkyyi@m5" ||
		c.Reporter.WorkerID != m4.wid(7) || c.Reporter.Node != "verkyyi@m4" {
		t.Fatalf("conflict does not name both sides: %+v", c)
	}
	leases, _ := h.srv.Store.Leases(time.Now())
	if len(leases) != 1 || leases[0].WorkerID != m5.wid(7) {
		t.Fatalf("the lease moved: %+v", leases)
	}

	// A second reconnect with the same conflict adds no row.
	m4.reconnect(t, h, 7)
	time.Sleep(200 * time.Millisecond)
	if all, _ := h.srv.Store.FleetAlerts(0); len(all) != 1 {
		t.Fatalf("rows after a repeat reconnect = %d, want 1", len(all))
	}

	// m4's session ends: the sweep sees the two sides agree and clears it.
	m4.show(t)
	waitFor(t, 3*time.Second, "m4's empty beat registered", func() bool {
		return !reporterShows(mustFleets(t, h), c)
	})
	h.srv.NodeAlertTick(time.Now(), time.Now())
	if a := openAlerts(t, h, store.AlertLeaseConflict); len(a) != 0 {
		t.Fatalf("lease_conflict still open after m4 stopped showing #7: %+v", a)
	}
}

// A node reconnecting with the lease it holds itself is no conflict.
func TestLeaseNoConflictForOwnLease(t *testing.T) {
	h, _, m4 := newLeasePair(t)
	if code, out := m4.acquire(t, h, 9, false); code != 200 {
		t.Fatalf("m4 acquire: %d %v", code, out)
	}
	m4.reconnect(t, h, 9)
	time.Sleep(200 * time.Millisecond)
	if a := openAlerts(t, h, store.AlertLeaseConflict); len(a) != 0 {
		t.Fatalf("lease_conflict for the holder's own session: %+v", a)
	}
}

func mustFleets(t *testing.T, h *harness) []store.FleetRow {
	t.Helper()
	fs, err := h.srv.Store.Fleets()
	if err != nil {
		t.Fatal(err)
	}
	return fs
}
