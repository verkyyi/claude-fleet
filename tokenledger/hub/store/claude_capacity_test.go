package store

import (
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

func TestClaudeQuotaEqualTimeConflict(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "fixture", "ep-1")
	now := time.Now().UTC().Truncate(time.Second)
	snap := &model.LimitsSnapshot{AccountUUID: "fixture", EndpointID: "ep-1", ObservedAt: now, RawJSON: `{"seven_day":{"utilization":0}}`}
	for i := 0; i < 2; i++ {
		if err := s.InsertLimits(snap); err != nil {
			t.Fatal(err)
		}
	}
	if raw, at, err := s.ClaudeCapacityRaw("fixture"); err != nil || string(raw) != snap.RawJSON || !at.Equal(now) {
		t.Fatal(string(raw), at, err)
	}
	snap.RawJSON = `{"seven_day":{"utilization":100}}`
	if err := s.InsertLimits(snap); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.ClaudeCapacityRaw("fixture"); err == nil {
		t.Fatal("conflicting simultaneous observations were ordered arbitrarily")
	}
}
