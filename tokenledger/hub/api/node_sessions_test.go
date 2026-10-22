package api

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func TestNodeSessionsSameHeartbeatAndLifecycle(t *testing.T) {
	h := newFleetHarness(t)
	now := time.Now().UTC()
	rows := json.RawMessage(`[{"worker_id":"f/w","key":"scratch-1","state":"done"}]`)
	hb := control.Heartbeat{Sessions: 1, FleetAt: &now, Fleets: []control.Fleet{{FleetID: "f", Name: "fleet", State: "running", Count: 1, Workers: rows}}}
	set := func(ep, host, login string, beat control.Heartbeat, at time.Time) {
		t.Helper()
		if err := h.srv.Store.NodeConnected(ep, host, login, "test", control.Proto, 5000, at); err != nil {
			t.Fatal(err)
		}
		raw, _ := json.Marshal(beat)
		if err := h.srv.Store.NodeHeartbeat(ep, host, login, ep+"-machine", control.Proto, string(raw), at); err != nil {
			t.Fatal(err)
		}
	}
	for _, ep := range []string{"live", "old", "mac"} {
		if err := h.srv.Store.Enroll(ep, ep, "hash-"+ep); err != nil {
			t.Fatal(err)
		}
	}
	set("live", "mini", "same-login", hb, now)
	// Deliberately newer registry data must not race ahead of the roster heartbeat.
	_, err := h.srv.Store.RecordFleetSnapshot("live", "mini", "same-login", "live-machine", []store.FleetReport{{FleetID: "f", Name: "fleet", State: "running", WorkerCount: 2, WorkersJSON: `[{"key":"new-1"},{"key":"new-2"}]`}}, now.Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	_, err = h.srv.Store.RecordFleetSnapshot("old", "mini", "same-login", "old-machine", []store.FleetReport{{FleetID: "old-f", Name: "fleet", State: "running", WorkerCount: 1, WorkersJSON: string(rows)}}, now.Add(-24*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.RetireEndpointAs("old", "operator", "retire", now); err != nil {
		t.Fatal(err)
	}
	check := func(current, pending, history int, unknown bool) *NodeDetail {
		t.Helper()
		d, err := h.srv.nodeDetail(now, "mini", nil)
		if err != nil {
			t.Fatal(err)
		}
		if len(d.Sessions) != current || len(d.PendingSessions) != pending || len(d.HistoricalSessions) != history {
			t.Fatalf("current/pending/history=%d/%d/%d", len(d.Sessions), len(d.PendingSessions), len(d.HistoricalSessions))
		}
		if unknown {
			if d.Machine.Sessions != nil {
				t.Fatalf("unknown reads as %v", *d.Machine.Sessions)
			}
		} else if d.Machine.Sessions == nil || *d.Machine.Sessions != current {
			t.Fatalf("count differs from rows: %v vs %d", d.Machine.Sessions, current)
		}
		return d
	}
	d := check(1, 0, 1, false)
	if d.Sessions[0].Worker["key"] != "scratch-1" {
		t.Fatal("detail used independent registry instead of heartbeat")
	}
	// A reused login's historical enrollment is visible only in admin history.
	mine, err := h.srv.nodeDetail(now, "mini", func(host, login string) bool { return host == "mini" && login == "same-login" })
	if err != nil || len(mine.HistoricalSessions) != 0 || len(mine.Sessions) != 1 {
		t.Fatalf("tenant history isolation: %+v %v", mine, err)
	}
	set("live", "mini", "same-login", hb, now.Add(-time.Minute))
	d = check(0, 2, 1, false)
	if d.PendingSessions[0].Availability != "lost" {
		t.Fatal("offline snapshot masquerades as current")
	}
	set("live", "mini", "same-login", hb, now)
	check(1, 0, 1, false)
	// Unknown is not zero; keep last known rows separately without inventing freshness.
	bad := hb
	bad.Fleets = append([]control.Fleet{}, hb.Fleets...)
	bad.Fleets[0].State = control.FleetStateUnknown
	bad.Fleets[0].Workers = nil
	bad.Sessions = 0
	set("live", "mini", "same-login", bad, now)
	d = check(0, 2, 1, true)
	if d.PendingSessions[0].Availability != "unknown" {
		t.Fatal("unreadable snapshot masquerades as current")
	}
	// A whole discovery failure is also unknown.
	bad = hb
	bad.FleetError = "discovery timed out"
	bad.Fleets = nil
	bad.Sessions = 0
	set("live", "mini", "same-login", bad, now)
	check(0, 2, 1, true)
	// Migration's empty source heartbeat must hide even a stale nonempty registry.
	empty := hb
	empty.Sessions = 0
	empty.Fleets = append([]control.Fleet{}, hb.Fleets...)
	empty.Fleets[0].Count = 0
	empty.Fleets[0].Workers = json.RawMessage(`[]`)
	set("live", "mini", "same-login", empty, now)
	check(0, 0, 1, false)
	dest := hb
	dest.Fleets = append([]control.Fleet{}, hb.Fleets...)
	dest.Fleets[0].FleetID = "mac-f"
	set("mac", "macbook", "owner", dest, now)
	d, err = h.srv.nodeDetail(now, "macbook", nil)
	if err != nil || len(d.Sessions) != 1 || d.Machine.Sessions == nil || *d.Machine.Sessions != 1 {
		t.Fatalf("destination: %+v %v", d, err)
	}
}
