package api

import (
	"encoding/json"
	"math"
	"testing"
	"time"
)

func TestLive_RatesComeFromConsecutiveReports(t *testing.T) {
	l := NewLive()

	// A single report carries running totals and cannot express a rate.
	l.Report("ep1", "web-01", []LiveSession{{SessionID: "s1", InputTokens: 1000, CostUSD: 1.0}})
	snap := l.Snapshot()
	if snap.TokensPerMin != 0 {
		t.Errorf("tokens/min = %v from one report; a rate needs two", snap.TokensPerMin)
	}

	// Backdate the stored report so the second one is a measurable interval later.
	l.mu.Lock()
	l.sessions["s1"].SeenAt = time.Now().UTC().Add(-time.Minute)
	l.mu.Unlock()

	l.Report("ep1", "web-01", []LiveSession{{SessionID: "s1", InputTokens: 4000, CostUSD: 2.0}})
	snap = l.Snapshot()
	if math.Abs(snap.TokensPerMin-3000) > 100 {
		t.Errorf("tokens/min = %v, want ~3000", snap.TokensPerMin)
	}
	if math.Abs(snap.USDPerHour-60) > 3 {
		t.Errorf("$/hour = %v, want ~60 ($1 in a minute)", snap.USDPerHour)
	}
}

// A session that restarts reports LOWER totals than before. Treating that as a
// negative rate would show the fleet earning tokens back.
func TestLive_CountersGoingBackwardsDoNotProduceNegativeRates(t *testing.T) {
	l := NewLive()
	l.Report("ep1", "web-01", []LiveSession{{SessionID: "s1", InputTokens: 9000, CostUSD: 9}})
	l.mu.Lock()
	l.sessions["s1"].SeenAt = time.Now().UTC().Add(-time.Minute)
	l.mu.Unlock()
	l.Report("ep1", "web-01", []LiveSession{{SessionID: "s1", InputTokens: 10, CostUSD: 0.01}})

	snap := l.Snapshot()
	if snap.TokensPerMin < 0 || snap.USDPerHour < 0 {
		t.Fatalf("negative rates from a restarted session: %+v", snap)
	}
}

// A finished session must leave the live view rather than sit there implying
// work that is not happening.
func TestLive_StaleSessionsExpire(t *testing.T) {
	l := NewLive()
	l.Report("ep1", "web-01", []LiveSession{{SessionID: "gone", InputTokens: 5}})
	l.mu.Lock()
	l.sessions["gone"].SeenAt = time.Now().UTC().Add(-2 * activeWindow)
	l.mu.Unlock()

	if snap := l.Snapshot(); snap.ActiveSessions != 0 {
		t.Fatalf("active = %d, want 0 for a session last seen %v ago", snap.ActiveSessions, 2*activeWindow)
	}
}

func TestLive_AggregatesAcrossEndpoints(t *testing.T) {
	l := NewLive()
	l.Report("ep1", "web-01", []LiveSession{{SessionID: "a"}, {SessionID: "b"}})
	l.Report("ep2", "laptop", []LiveSession{{SessionID: "c"}})

	snap := l.Snapshot()
	if snap.ActiveSessions != 3 {
		t.Errorf("sessions = %d, want 3", snap.ActiveSessions)
	}
	if snap.Endpoints != 2 {
		t.Errorf("endpoints = %d, want 2", snap.Endpoints)
	}
	if snap.Note == "" {
		t.Error("the live view must say it is not the stored totals")
	}
}

// Busiest first: the point of the view is spotting what is burning right now.
func TestLive_SortedByBurnRate(t *testing.T) {
	l := NewLive()
	l.Report("ep1", "e", []LiveSession{{SessionID: "slow"}, {SessionID: "fast"}})
	l.mu.Lock()
	for _, s := range l.sessions {
		s.SeenAt = time.Now().UTC().Add(-time.Minute)
	}
	l.mu.Unlock()
	l.Report("ep1", "e", []LiveSession{
		{SessionID: "slow", InputTokens: 100},
		{SessionID: "fast", InputTokens: 100000},
	})

	snap := l.Snapshot()
	if snap.Sessions[0].SessionID != "fast" {
		t.Fatalf("first session = %q, want the fastest burner", snap.Sessions[0].SessionID)
	}
}

// A subscriber that stops reading must not wedge the agents reporting in.
func TestLive_SlowSubscriberDoesNotBlockReports(t *testing.T) {
	l := NewLive()
	ch := l.subscribe()
	defer l.unsubscribe(ch)

	done := make(chan struct{})
	go func() {
		for i := 0; i < 50; i++ {
			l.Report("ep1", "e", []LiveSession{{SessionID: "s"}})
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("reports blocked on a subscriber that never read")
	}
}

func TestLive_SnapshotSerialises(t *testing.T) {
	l := NewLive()
	l.Report("ep1", "web-01", []LiveSession{{SessionID: "s", Model: "Opus 5", CostUSD: 1.5}})
	b, err := json.Marshal(l.Snapshot())
	if err != nil {
		t.Fatal(err)
	}
	var back Snapshot
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatal(err)
	}
	if len(back.Sessions) != 1 || back.Sessions[0].Model != "Opus 5" {
		t.Fatalf("round trip lost data: %+v", back)
	}
}
