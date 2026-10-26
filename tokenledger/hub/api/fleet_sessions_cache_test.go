package api

import (
	"net/http/httptest"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// Every read after a committed action or heartbeat sees it without a TTL wait,
// including a write received by another replica with no local broadcast.
func TestSessionListImmediateChanges(t *testing.T) {
	h := newFleetHarness(t)
	node := connectFakeNode(t, h, "mac-c", false)
	fleet := fakeFleet(t, machineB, "fleet-b", "", "", 1)
	node.beat("mac-c", "bob", machineB, fleet)
	waitFor(t, 3*time.Second, "fleet snapshot", func() bool { fs, _ := h.srv.Store.Fleets(); return len(fs) > 0 })
	req := httptest.NewRequest("GET", "/v1/fleet/fleet_sessions", nil)
	if _, err := h.srv.FleetSessions(req); err != nil {
		t.Fatal(err)
	}
	for _, state := range []string{"working", "done", "needs"} {
		raw := `[{"worker_id":"fleet/worker","key":"scratch-1","name":"renamed","state":"` + state + `"}]`
		if err := h.srv.Store.UpdateFleetWorkers(fleet.FleetID, "running", 1, raw, time.Now()); err != nil {
			t.Fatal(err)
		}
		body, err := h.srv.FleetSessions(req)
		if err != nil {
			t.Fatal(err)
		}
		rows := body["sessions"].([]FleetSession)
		if len(rows) != 1 || rows[0].Worker["state"] != state || rows[0].Worker["name"] != "renamed" {
			t.Fatalf("stale action/status: %v", rows)
		}
	}
	if err := h.srv.Store.UpdateFleetWorkers(fleet.FleetID, "running", 0, "[]", time.Now()); err != nil {
		t.Fatal(err)
	}
	body, err := h.srv.FleetSessions(req)
	if err != nil || len(body["sessions"].([]FleetSession)) != 0 {
		t.Fatalf("closed row retained: %v %v", body, err)
	}
	// No database write occurs between these two reads. Expiry of a heartbeat
	// must be visible on the first read after its existing deadline, within 3s.
	deadline := time.Now().Add(time.Second)
	beatAt := deadline.Add(-time.Duration(60000*lostAfterBeats) * time.Millisecond)
	if err := h.srv.Store.NodeHeartbeat("ep_mac-c", "mac-c", "bob", machineB, control.Proto, `{"hostname":"mac-c"}`, beatAt); err != nil {
		t.Fatal(err)
	}
	body, err = h.srv.FleetSessions(req)
	if err != nil || body["nodes"].([]FleetNode)[0].Availability != "online" {
		t.Fatalf("initial availability: %v %v", body, err)
	}
	time.Sleep(time.Until(deadline) + 20*time.Millisecond)
	body, err = h.srv.FleetSessions(req)
	if err != nil || body["nodes"].([]FleetNode)[0].Availability != "lost" {
		t.Fatalf("clock-only state retained by cache: %v %v", body, err)
	}
}

func TestSessionListHideUndoImmediate(t *testing.T) {
	s := historyCacheServer(t)
	m := historyCacheRecord(t, s, "operator", 81, "")
	req := httptest.NewRequest("GET", "/v1/fleet/fleet_sessions", nil)
	visible := func() bool {
		t.Helper()
		body, err := s.FleetSessions(req)
		if err != nil {
			t.Fatal(err)
		}
		for _, r := range body["board"].(*Board).Rows {
			if r.History != nil && r.History.ID == m.ID {
				return true
			}
		}
		return false
	}
	if !visible() {
		t.Fatal("closed history missing")
	}
	if err := s.Store.HideHistory(m, "operator", false, true, time.Now(), s.historyMirrorSession); err != nil {
		t.Fatal(err)
	}
	if visible() {
		t.Fatal("hide waited for cache")
	}
	if err := s.Store.HideHistory(m, "operator", true, true, time.Now(), s.historyMirrorSession); err != nil {
		t.Fatal(err)
	}
	if !visible() {
		t.Fatal("undo waited for cache")
	}
}
