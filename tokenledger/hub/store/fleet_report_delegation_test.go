package store

import (
	"testing"
	"time"
)

// A supervisor being offline is not authority to hand routine reports back to
// the person. The existing durable relay retains these until the exact target
// takes them. Ordinary reports and messages keep their existing expiry policy.
func TestDelegatedReportSurvivesRelayTTL(t *testing.T) {
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
	if err != nil || n != 2 {
		t.Fatalf("expiry: n=%d err=%v", n, err)
	}
	rows, err := s.PendingFleetRelays("target")
	if err != nil || len(rows) != 1 || rows[0].ID != "delegated" {
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
