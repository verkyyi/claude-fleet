package store

import (
	"testing"
	"time"
)

// Report backlog is settled explicitly by the retirement dispatcher, never
// silently expired by another endpoint's periodic TTL sweep. Messages still expire.
func TestReportBacklogExcludedFromRelayTTL(t *testing.T) {
	s := newStore(t)
	if err := s.ensureFleetRelays(); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	for _, tc := range []struct{ id, kind, payload string }{
		{"delegated", "child_report", `{"report_delegation":{"target":"supervisor"}}`},
		{"ordinary", "child_report", `{}`},
		{"message", "message", `{}`},
	} {
		r := FleetRelay{ID: tc.id, Kind: tc.kind, Payload: tc.payload, FromWID: "child", ToWID: "parent",
			FromEndpoint: "source", TargetEndpoint: "target", Created: now.Add(-48 * time.Hour), Updated: now}
		for i := 0; i < 2; i++ {
			inserted, err := s.InsertFleetRelay(r)
			if err != nil || inserted != (i == 0) {
				t.Fatalf("insert/replay %s: inserted=%v err=%v", tc.id, inserted, err)
			}
		}
	}
	n, err := s.ExpireFleetRelays(time.Hour, now)
	if err != nil || n != 1 {
		t.Fatalf("expiry: n=%d err=%v", n, err)
	}
	rows, err := s.PendingFleetRelays("target")
	if err != nil || len(rows) != 2 || rows[0].ID != "delegated" || rows[1].ID != "ordinary" {
		t.Fatalf("retained: %+v %v", rows, err)
	}
	if err := s.FinishFleetRelay("delegated", RelayDelivered, "", now); err != nil {
		t.Fatal(err)
	}
	if err := s.FinishFleetRelay("delegated", RelayFailed, "late replay", now); err != nil {
		t.Fatal(err)
	}
	r, err := s.FleetRelay("delegated")
	if err != nil || r.Status != RelayDelivered {
		t.Fatalf("settled replay: %+v %v", r, err)
	}
}
